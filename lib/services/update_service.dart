import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_info.dart';
import '../models/engine_state.dart';

/// Checks GitHub Releases internally to know when a new build exists,
/// but never exposes the repository link to the user — all UI surfaces
/// point to the Telegram channel [AppInfo.telegramUrl].
///
/// The result drives a *mandatory* update: any release newer than the running
/// build takes the app out of service, so every failure mode is reported
/// explicitly through [UpdateInfo.checkFailed] instead of silently looking
/// "up to date" — a network blip must never be mistaken for a green light.
class UpdateService {
  static const owner = AppInfo.owner;
  static const repo = AppInfo.repo;
  static final latestUri =
      Uri.parse('https://api.github.com/repos/$owner/$repo/releases/latest');
  // Internal fallback — but UI will always show Telegram URL instead.
  static const githubHtml = AppInfo.releasesUrl;
  static const telegramUrl = AppInfo.telegramUrl;
  static final _allowedHost = 'github.com';
  static final _allowedPrefix =
      'https://github.com/$owner/$repo/releases/download/';
  static final _objectsPrefix = 'https://objects.githubusercontent.com/';

  Future<UpdateInfo> check({Duration timeout = const Duration(seconds: 20)}) async {
    final info = await PackageInfo.fromPlatform();
    final current = info.version.isEmpty ? AppInfo.version : info.version;
    try {
      final res = await http.get(
        latestUri,
        headers: {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'VoidrauVPN/$current',
        },
      ).timeout(timeout);
      if (res.statusCode == 404) {
        // No release published yet: nothing to enforce.
        return UpdateInfo(current: current, latest: current, htmlUrl: telegramUrl);
      }
      if (res.statusCode != 200) {
        throw HttpException('GitHub ${res.statusCode}');
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = (json['tag_name'] ?? '').toString();
      final latest = tag.startsWith('v') ? tag.substring(1) : tag;
      final notes = (json['body'] ?? '').toString();
      // We read html_url from GitHub but we deliberately expose Telegram URL to the user.
      // The GitHub page is only for internal version detection.
      String? apk;
      String? exe;
      String? apkSha;
      String? exeSha;
      String? sumsUrl;
      final assets = <String, String>{};
      final digests = <String, String>{};
      for (final asset in (json['assets'] as List? ?? const [])) {
        final map = Map<String, dynamic>.from(asset as Map);
        final name = '${map['name']}';
        final url = '${map['browser_download_url']}';
        if (!_allowedUrl(url)) continue;
        assets[name.toLowerCase()] = url;
        final digest = '${map['digest'] ?? ''}'.replaceFirst('sha256:', '');
        if (digest.length == 64) digests[name.toLowerCase()] = digest;
        if (name.toLowerCase() == 'sha256sums.txt') sumsUrl = url;
        if (name.toLowerCase().endsWith('.apk') &&
            name.toLowerCase().contains('universal')) {
          apk = url;
          if (digest.length == 64) apkSha = digest;
        }
        if (name.toLowerCase().endsWith('.apk') && apk == null) {
          apk = url;
          if (digest.length == 64) apkSha = digest;
        }
        if (name.toLowerCase().contains('installer') &&
            name.toLowerCase().endsWith('.exe')) {
          exe = url;
          if (digest.length == 64) exeSha = digest;
        }
        if (name.toLowerCase().endsWith('.exe') &&
            name.toLowerCase().contains('windows') &&
            exe == null) {
          exe = url;
          if (digest.length == 64) exeSha = digest;
        }
      }
      if (sumsUrl != null && (apkSha == null || exeSha == null)) {
        final sums = await _loadSums(sumsUrl);
        apkSha ??= _sumFor(sums, assets, apk);
        exeSha ??= _sumFor(sums, assets, exe);
      }
      return UpdateInfo(
        current: current,
        latest: latest.isEmpty ? current : latest,
        notes: notes,
        apkUrl: apk,
        exeUrl: exe,
        apkSha256: apkSha,
        exeSha256: exeSha,
        // IMPORTANT: show Telegram channel to user, not GitHub link
        htmlUrl: telegramUrl,
        available: _isNewer(latest, current),
      );
    } catch (_) {
      return UpdateInfo(
        current: current,
        latest: current,
        htmlUrl: telegramUrl,
        checkFailed: true,
      );
    }
  }

  Future<Map<String, String>> _loadSums(String url) async {
    try {
      final res = await http.get(Uri.parse(url), headers: {
        'User-Agent': 'VoidrauVPN/${AppInfo.version}',
      }).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return {};
      return parseSha256Sums(res.body);
    } catch (_) {
      return {};
    }
  }

  static String? _sumFor(
    Map<String, String> sums,
    Map<String, String> assets,
    String? url,
  ) {
    if (url == null) return null;
    final name = url.split('/').last.toLowerCase();
    return sums[name];
  }

  static Map<String, String> parseSha256Sums(String body) {
    final map = <String, String>{};
    for (final line in body.split(RegExp(r'\r?\n'))) {
      final m = RegExp(r'^([a-fA-F0-9]{64})\s+\*?(.+)$').firstMatch(line.trim());
      if (m != null) {
        map[m.group(2)!.split(RegExp(r'[/\\]')).last.toLowerCase()] =
            m.group(1)!.toLowerCase();
      }
    }
    return map;
  }

  static bool _allowedUrl(String url) {
    final u = url.toLowerCase();
    // GitHub downloads must be https; a plaintext http:// URL can be swapped
    // by an on-path attacker before we hash-verify.
    if (u.startsWith(_allowedPrefix.toLowerCase())) {
      return _allowedPrefix.toLowerCase().startsWith('https://') ||
          Uri.tryParse(url)?.scheme == 'https';
    }
    if (u.startsWith(_objectsPrefix)) {
      return Uri.tryParse(url)?.scheme == 'https';
    }
    final parsed = Uri.tryParse(url);
    return parsed != null &&
        parsed.scheme == 'https' &&
        parsed.host == _allowedHost &&
        parsed.path.contains('/$owner/$repo/');
  }

  Future<File> download({
    required String url,
    String? expectedSha256,
    required void Function(double progress) onProgress,
  }) async {
    if (!_allowedUrl(url)) {
      throw const HttpException('update URL is not from this repository');
    }
    final dir = await getTemporaryDirectory();
    final name = url.split('/').last;
    final file = File(p.join(dir.path, name));
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'VoidrauVPN/${AppInfo.version}');
      final res = await req.close();
      if (res.statusCode != 200) {
        throw HttpException('download ${res.statusCode}');
      }
      final total = res.contentLength;
      final sink = file.openWrite();
      var got = 0;
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) onProgress(got / total);
        }
        await sink.close();
      } catch (_) {
        // Never leave a partial download or a leaked IOSink behind: a later
        // run must not trust a half-written file.
        await sink.close();
        if (await file.exists()) await file.delete();
        rethrow;
      }
      // Verify whenever a digest is provided; fail closed when it is absent
      // so a compromised manifest can never push unverified binaries.
      if (expectedSha256 == null || expectedSha256.length != 64) {
        await file.delete();
        throw const FileSystemException(
            'refusing to install update without a valid sha-256 digest');
      }
      {
        final hash = sha256.convert(await file.readAsBytes()).toString();
        if (hash.toLowerCase() != expectedSha256.toLowerCase()) {
          await file.delete();
          throw const FileSystemException('SHA-256 mismatch');
        }
      }
      onProgress(1);
      return file;
    } finally {
      client.close(force: true);
    }
  }

  static bool isNewer(String latest, String current) => _isNewer(latest, current);

  static bool _isNewer(String latest, String current) {
    List<int> parts(String v) => v
        .split(RegExp(r'[^0-9]+'))
        .where((e) => e.isNotEmpty)
        .map(int.parse)
        .toList();
    final a = parts(latest);
    final b = parts(current);
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }
}
