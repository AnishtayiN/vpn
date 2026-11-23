import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'license_service.dart';

/// Server-driven app config (`GET /api/config` on the license Worker):
/// the small values that should not need a new release — an announcement
/// banner, a changelog override for the "what's new" notice, the list of
/// releases whose changes are core-only, and simple feature flags.
///
/// Deliberately NOT a server list and never keys: the worker sanitizes
/// to this shape on write and read, and [RemoteConfig.fromJson] ignores
/// everything else again here. Every failure mode fails open to the
/// built-in defaults ([RemoteConfig.empty]) — a config outage must never
/// change how the tunnel behaves.
class RemoteConfig {
  const RemoteConfig({
    this.announcement,
    this.announcementId,
    this.changelog,
    this.coreOnlyVersions = const [],
    this.flags = const {},
  });

  static const empty = RemoteConfig();

  /// Banner text for the connect page (null = no banner).
  final String? announcement;

  /// Stable id for the announcement, so dismissing it stays dismissed
  /// across launches. Falls back to a hash of the text.
  final String? announcementId;

  /// Overrides the release-notes text in the "what's new" notice.
  final String? changelog;

  /// Releases (e.g. `1.9.1`) whose changes are confined to the tunnel
  /// core files: Windows refreshes just those files instead of running
  /// the installer (see `core_update.dart`).
  final List<String> coreOnlyVersions;

  /// Simple boolean feature flags.
  final Map<String, bool> flags;

  bool flag(String name, {bool defaultValue = false}) =>
      flags[name] ?? defaultValue;

  bool isCoreOnly(String? version) =>
      version != null && coreOnlyVersions.contains(version);

  /// Dismissal identity for the current announcement: the server id
  /// when given, else a short hash of the text (a changed text is a new
  /// announcement and shows again).
  String? get announcementKey {
    final text = announcement;
    if (text == null || text.isEmpty) return null;
    final id = announcementId;
    if (id != null && id.isNotEmpty) return id;
    return sha256.convert(utf8.encode(text)).toString().substring(0, 16);
  }

  /// Tolerant parse: wrong types are dropped, never thrown — the
  /// server is trusted for *values*, not for shape.
  factory RemoteConfig.fromJson(Map<String, dynamic> json) {
    String? str(String key, int max) {
      final v = json[key];
      if (v is! String) return null;
      final t = v.trim();
      if (t.isEmpty) return null;
      return t.length > max ? t.substring(0, max) : t;
    }

    final versions = <String>[];
    final rawVersions = json['coreOnlyVersions'];
    if (rawVersions is List) {
      for (final v in rawVersions) {
        if (v is String && RegExp(r'^\d+\.\d+\.\d+$').hasMatch(v.trim())) {
          versions.add(v.trim());
        }
        if (versions.length >= 20) break;
      }
    }

    final flags = <String, bool>{};
    final rawFlags = json['flags'];
    if (rawFlags is Map) {
      for (final e in rawFlags.entries) {
        if (flags.length >= 20) break;
        if (e.value is bool &&
            RegExp(r'^[a-zA-Z0-9_.-]{1,40}$').hasMatch('${e.key}')) {
          flags['${e.key}'] = e.value as bool;
        }
      }
    }

    return RemoteConfig(
      announcement: str('announcement', 500),
      announcementId: str('announcementId', 64),
      changelog: str('changelog', 4000),
      coreOnlyVersions: versions,
      flags: flags,
    );
  }

  Map<String, dynamic> toJson() => {
        if (announcement != null) 'announcement': announcement,
        if (announcementId != null) 'announcementId': announcementId,
        if (changelog != null) 'changelog': changelog,
        if (coreOnlyVersions.isNotEmpty)
          'coreOnlyVersions': coreOnlyVersions,
        if (flags.isNotEmpty) 'flags': flags,
      };
}

/// Fetches and caches [RemoteConfig]. The cache is loaded synchronously
/// at boot (so the banner/flags work offline from the first frame) and
/// refreshed in the background when older than [ttl].
class RemoteConfigService {
  RemoteConfigService._();
  static final RemoteConfigService instance = RemoteConfigService._();

  static const _prefJson = 'remoteConfig.json';
  static const _prefAt = 'remoteConfig.at';
  static const ttl = Duration(hours: 1);

  RemoteConfig _current = RemoteConfig.empty;
  RemoteConfig get current => _current;

  /// Loads the cached copy (no network). Call once at boot.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefJson);
      if (raw == null || raw.isEmpty) return;
      _current =
          RemoteConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      _current = RemoteConfig.empty;
    }
  }

  /// Refreshes from the Worker when the cache is stale (or [force]).
  /// Returns true when the effective config changed. Never throws.
  Future<bool> refresh({bool force = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!force) {
        final at = prefs.getInt(_prefAt) ?? 0;
        final age = DateTime.now().millisecondsSinceEpoch - at;
        if (age < ttl.inMilliseconds) return false;
      }
      final res = await http
          .get(Uri.parse('${LicenseService.apiBase}/api/config'),
              headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return false;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final cfg = body['config'];
      if (cfg is! Map) return false;
      final next = RemoteConfig.fromJson(Map<String, dynamic>.from(cfg));
      final changed =
          jsonEncode(next.toJson()) != jsonEncode(_current.toJson());
      _current = next;
      await prefs.setString(_prefJson, jsonEncode(next.toJson()));
      await prefs.setInt(_prefAt, DateTime.now().millisecondsSinceEpoch);
      return changed;
    } catch (_) {
      return false;
    }
  }
}
