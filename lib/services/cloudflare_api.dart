import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

/// Deploys the user's OWN Cloudflare Worker from `worker/worker.js`, using
/// the user's own API token.
///
/// The token is passed in by the caller (it lives in secure storage — see
/// SecureStore) and is never written to code, logs or git. No Worker URL,
/// domain, key or UUID is hardcoded anywhere: every one of those comes from
/// the user's own account and the wizard's own inputs.
///
/// The deploy flow (same shape as BPB-VPN's `cloudflare_api.dart`, GPLv3 —
/// re-implemented here in our own code; see README/CHANGELOG):
///   1. pick an account,
///   2. make sure the account has a workers.dev subdomain,
///   3. upload `worker/worker.js` with its one ENV binding (base64 JSON
///      `{v, id, pips, fb}` — the VLESS UUID, proxy IPs and fallback site),
///   4. enable the workers.dev subdomain for the script.
class CloudflareException implements Exception {
  final String message;
  const CloudflareException(this.message);

  @override
  String toString() => message;
}

class CfAccount {
  final String id;
  final String name;
  const CfAccount(this.id, this.name);
}

/// A finished deploy: where the Worker answers, and on which account.
class WorkerDeploy {
  final String accountId;
  final String scriptName;
  final String domain;
  const WorkerDeploy({
    required this.accountId,
    required this.scriptName,
    required this.domain,
  });
}

class CloudflareApi {
  static const _base = 'https://api.cloudflare.com/client/v4';

  /// The bundled worker script, as shipped in the app (see pubspec assets).
  static const workerAsset = 'worker/worker.js';

  /// The bundled worker's version, bumped with every change to
  /// worker/worker.js; deployments older than [minWorkerVersion] are
  /// redeployed automatically, the rest offer an update.
  static const workerVersion = 1;
  static const minWorkerVersion = 1;

  /// The worker's only binding (plain text): base64 of a JSON object,
  /// see [encodeEnv].
  static const envVar = 'ENV';

  /// ENV's value: `{v, id, pips, fb}` as JSON, base64.
  static String encodeEnv({
    required String uuid,
    required List<String> proxyIps,
    required String fallbackUrl,
  }) =>
      base64.encode(
        utf8.encode(
          jsonEncode({'v': 1, 'id': uuid, 'pips': proxyIps, 'fb': fallbackUrl}),
        ),
      );

  /// Token creation page with the permissions pre-selected (Workers Scripts:
  /// Edit, Pages: Edit, DNS: Edit, User Details: Read).
  static String tokenCreationUrl() {
    final permissions = jsonEncode([
      {'key': 'workers_scripts', 'type': 'edit'},
      {'key': 'page', 'type': 'edit'},
      {'key': 'dns', 'type': 'edit'},
      {'key': 'user_details', 'type': 'read'},
    ]);
    return Uri.https('dash.cloudflare.com', '/profile/api-tokens', {
      'permissionGroupKeys': permissions,
      'accountId': '*',
      'zoneId': 'all',
      'name': 'VoidrauVPN',
    }).toString();
  }

  /// Extracts the API token from pasted text.
  ///
  /// Cloudflare only accepts `[A-Za-z0-9_-]` in a Bearer token (anything else
  /// is error 6003/6111), so every other character is dropped. Long `cfut_`
  /// tokens copied across two lines are joined back together, and invisible
  /// characters and quotes disappear. For a pasted
  /// `curl ... "Authorization: Bearer <token>"` command only the part after
  /// "Bearer" is used. Throws for a Global API Key, which cannot be used as
  /// a Bearer token.
  static String normalizeToken(String input) {
    var text = input;
    final bearer = text.toLowerCase().lastIndexOf('bearer');
    if (bearer >= 0) {
      text = text.substring(bearer + 6).trimLeft();
      final quote = text.indexOf(RegExp('["\']'));
      if (quote > 0) text = text.substring(0, quote);
    }
    final token = text.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    if (token.isEmpty) throw const CloudflareException('Enter your API token');
    if (RegExp(r'^[0-9a-f]{37}$').hasMatch(token)) {
      throw const CloudflareException(
        'This looks like the Global API Key. Create an API token instead '
        '(use the button above).',
      );
    }
    if (token.length < 30) {
      throw const CloudflareException(
        "That doesn't look like a Cloudflare API token. Copy the token itself.",
      );
    }
    return token;
  }

  final String token;
  final http.Client _client;

  CloudflareApi(String token, {http.Client? client})
      : token = normalizeToken(token),
        _client = client ?? http.Client();

  void close() => _client.close();

  Map<String, String> get _auth => {'Authorization': 'Bearer $token'};

  Future<dynamic> _send(
    String method,
    String path, {
    Object? json,
    String? body,
    String? contentType,
  }) async {
    final request = http.Request(method, Uri.parse('$_base$path'))
      ..headers.addAll(_auth);
    if (json != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(json);
    } else if (body != null) {
      request.headers['Content-Type'] = contentType ?? 'text/plain';
      request.body = body;
    }
    return _decode(
      await http.Response.fromStream(
        await _client.send(request).timeout(const Duration(seconds: 30)),
      ),
    );
  }

  Future<dynamic> _sendMultipart(
    String method,
    String path,
    void Function(http.MultipartRequest) build,
  ) async {
    final request = http.MultipartRequest(method, Uri.parse('$_base$path'))
      ..headers.addAll(_auth);
    build(request);
    return _decode(
      await http.Response.fromStream(
        await _client.send(request).timeout(const Duration(seconds: 90)),
      ),
    );
  }

  dynamic _decode(http.Response response) {
    Map<String, dynamic>? data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      // Not JSON; handled below.
    }
    if (data != null && data['success'] == true) return data['result'];
    // Some endpoints (e.g. deleting a Workers custom domain) answer 2xx with
    // an empty body.
    if (data == null && response.statusCode >= 200 && response.statusCode < 300) {
      return null;
    }
    String describe(Map e) {
      final chain = (e['error_chain'] as List? ?? const [])
          .whereType<Map>()
          .map(describe)
          .join(', ');
      return '${e['message']}${e['code'] != null ? ' (${e['code']})' : ''}'
          '${chain.isNotEmpty ? ': $chain' : ''}';
    }

    final errors = (data?['errors'] as List? ?? const [])
        .whereType<Map>()
        .map(describe)
        .join('; ');
    throw CloudflareException(
      errors.isNotEmpty ? errors : 'Cloudflare API error ${response.statusCode}',
    );
  }

  /// Email of the token's user (needs User Details: Read), or '' when not
  /// available.
  Future<String> userEmail() async {
    try {
      final result = await _send('GET', '/user') as Map;
      return '${result['email'] ?? ''}';
    } on CloudflareException {
      return '';
    }
  }

  Future<List<CfAccount>> accounts() async {
    final result = await _send('GET', '/accounts?per_page=50') as List;
    return result
        .whereType<Map>()
        .map((a) => CfAccount('${a['id']}', '${a['name']}'))
        .toList();
  }

  /// Returns the account's workers.dev subdomain, registering a random one
  /// when it has none yet.
  Future<String> ensureSubdomain(String accountId) async {
    try {
      final result =
          await _send('GET', '/accounts/$accountId/workers/subdomain') as Map;
      final sub = '${result['subdomain'] ?? ''}';
      if (sub.isNotEmpty) return sub;
    } on CloudflareException catch (e) {
      if (!e.message.contains('10007')) rethrow; // 10007: no subdomain yet
    }
    final name = _randomName(10);
    final result = await _send(
      'PUT',
      '/accounts/$accountId/workers/subdomain',
      json: {'subdomain': name},
    ) as Map;
    return '${result['subdomain']}';
  }

  /// Uploads the worker script with its ENV binding (replacing every other
  /// binding).
  Future<void> uploadScript(
    String accountId,
    String scriptName,
    String env,
  ) async {
    final script = await rootBundle.loadString(workerAsset);
    final metadata = {
      'main_module': 'worker.js',
      'compatibility_date': _currentCompatibilityDate(),
      'bindings': [
        {'type': 'plain_text', 'name': envVar, 'text': env},
      ],
    };
    await _sendMultipart(
      'PUT',
      '/accounts/$accountId/workers/scripts/$scriptName',
      (r) {
        r.files
          ..add(
            http.MultipartFile.fromString(
              'metadata',
              jsonEncode(metadata),
              contentType: MediaType('application', 'json'),
            ),
          )
          ..add(
            http.MultipartFile.fromString(
              'worker.js',
              script,
              filename: 'worker.js',
              contentType: MediaType('application', 'javascript+module'),
            ),
          );
      },
    );
  }

  Future<void> enableWorkersDev(String accountId, String scriptName) =>
      _send(
        'POST',
        '/accounts/$accountId/workers/scripts/$scriptName/subdomain',
        json: {'enabled': true, 'previews_enabled': false},
      );

  /// Full deploy: upload the script with its ENV binding, enable the
  /// workers.dev subdomain, and return the host the Worker answers on.
  /// When [customDomain] is given, the Worker is also attached to it (the
  /// domain's zone must be on the same account).
  Future<WorkerDeploy> deployWorker({
    required String accountId,
    required String scriptName,
    required String env,
    String? customDomain,
  }) async {
    await uploadScript(accountId, scriptName, env);
    final subdomain = await ensureSubdomain(accountId);
    await enableWorkersDev(accountId, scriptName);
    var domain = '$scriptName.$subdomain.workers.dev';
    final custom = customDomain?.trim() ?? '';
    if (custom.isNotEmpty) {
      await _attachWorkerDomain(accountId, scriptName, custom);
      domain = custom;
    }
    return WorkerDeploy(
      accountId: accountId,
      scriptName: scriptName,
      domain: domain,
    );
  }

  /// Routes [hostname] to the worker. The hostname's zone must be on the same
  /// account. Only needs "Workers Scripts: Edit". The zone is passed by name,
  /// trying the hostname's parent domains (longest first), so no zone-read
  /// permission is needed.
  Future<void> _attachWorkerDomain(
    String accountId,
    String scriptName,
    String hostname,
  ) async {
    CloudflareException? lastError;
    for (final zoneName in _zoneCandidates(hostname)) {
      try {
        await _send(
          'PUT',
          '/accounts/$accountId/workers/domains',
          json: {
            'hostname': hostname,
            'service': scriptName,
            'zone_name': zoneName,
          },
        );
        return;
      } on CloudflareException catch (e) {
        if (_isAuthError(e)) rethrow;
        lastError = e;
      }
    }
    throw CloudflareException(
      'Could not attach $hostname: ${lastError?.message ?? 'no matching zone'}. '
      'The domain must be a zone on this Cloudflare account.',
    );
  }

  static bool _isAuthError(CloudflareException e) =>
      e.message.contains('10001') ||
      e.message.contains('9109') ||
      e.message.contains('403');

  static List<String> _zoneCandidates(String hostname) {
    final parts = hostname.split('.');
    final out = <String>[];
    for (var i = 0; i < parts.length - 1; i++) {
      out.add(parts.sublist(i).join('.'));
    }
    return out;
  }

  static String _randomName(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)])
        .join();
  }

  static String _currentCompatibilityDate() {
    final now = DateTime.now().toUtc();
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '${now.year}-$m-$d';
  }
}
