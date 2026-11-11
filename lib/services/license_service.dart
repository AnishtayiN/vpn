import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../app_info.dart';
import '../data/jalali.dart';

/// Client for the VoidrauVPN license backend (Cloudflare Worker).
///
/// The Worker exposes:
///   GET  /api/license?key=XXXX&deviceId=...&deviceName=...&platform=...&appVersion=...
///        → { ok, plan, expiresAt, serverTime, remainingSeconds, isPaid,
///            maxUsers, activeSessions, sessionId, sessionActive, sessions }
///   POST /api/trial {telegramId}        → { ok, key, expiresAt, serverTime } (trial)
///   GET  /api/status?key=XXXX&deviceId=... → same shape as /license + sessionActive
///   GET  /api/health                    → { ok, service, time }
///   POST /api/sessions/revoke {key, sessionId, deviceId} → { ok, sessions }
///   POST /api/sessions/revoke-all {key, deviceId, keepSessionId?}
///        → { ok, sessions }
///
/// Every activation registers one *session* for this device. A license plan
/// allows up to [maxUsers] concurrent sessions; a further device gets
/// HTTP 409 `session-limit` until one session is removed (from the app or
/// from the bot). A session removed elsewhere is detected on the next
/// [check]: [sessionActive] becomes false and the stored key is cleared so
/// the user lands back on the license screen.
///
/// The Telegram bot (same Worker) hands out keys and the buy/referral flow.
/// Everything is time-based: a license is a key + expiry timestamp. Offline
/// grace: the last successful check is cached locally for up to 72h so a
/// temporary outage never locks out a paying user.
class LicenseService {
  LicenseService._();
  static final LicenseService instance = LicenseService._();

  static const apiBase = String.fromEnvironment(
    'VOIDRAU_LICENSE_API',
    defaultValue: 'https://voidrau.massagetoanishtayin.workers.dev',
  );

  static const _prefKey = 'license.key';
  static const _prefExpires = 'license.expiresAt';
  static const _prefCheckedAt = 'license.checkedAt';
  static const _prefPlan = 'license.plan';
  static const _prefMaxUsers = 'license.maxUsers';
  static const _prefSessionId = 'license.sessionId';
  static const _gracePeriod = Duration(hours: 72);

  /// Secure-storage key for the stable per-device id (see [generateDeviceId]).
  static const deviceIdStorageKey = 'device.id';

  static const _deviceStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  /// A session is stale (shown as inactive, never auto-deleted) after 30
  /// days without activity.
  static const staleSessionAfter = Duration(days: 30);

  String? _key;
  DateTime? _expiresAt;
  DateTime? _checkedAt;
  String? _plan;
  bool _loaded = false;
  String? _lastError;

  int? _maxUsers;
  List<LicenseSession> _sessions = const [];
  String? _sessionId;
  bool? _sessionActive;
  SessionLimitError? _lastLimitError;
  String? _deviceId;

  String? get key => _key;
  String? get plan => _plan;

  /// Paid licenses unlock configuration; trials/referrals stay read-only.
  bool get isPaid => (_plan == 'paid' || _plan == 'admin') && isActive;
  String? get lastError => _lastError;
  DateTime? get expiresAt => _expiresAt;

  /// Maximum concurrent devices allowed by the current plan (null = unknown,
  /// e.g. the Worker has not reported it yet; treat as 1 for display).
  int? get maxUsers => _maxUsers;

  /// Sessions reported by the last successful license check.
  List<LicenseSession> get sessions => List.unmodifiable(_sessions);

  /// Id of this device's session, as reported by the Worker.
  String? get sessionId => _sessionId;

  /// Whether this device's session still exists server-side. Null means the
  /// Worker did not report it (older Worker / offline cache) — unknown, not
  /// revoked.
  bool? get sessionActive => _sessionActive;

  /// Structured 409 session-limit error from the last failed [check], if
  /// any. The UI shows the active devices from here instead of a plain
  /// error string.
  SessionLimitError? get lastLimitError => _lastLimitError;

  /// Stable id of this device, once resolved (null until the first check).
  String? get deviceId => _deviceId;

  /// Human device name, e.g. "Android 12". Only what the OS reports — never
  /// a precise phone model (unavailable without a new package).
  String get deviceName =>
      formatDeviceName(Platform.operatingSystem, Platform.operatingSystemVersion);

  /// Platform token sent to the Worker: android | windows | ios | linux...
  String get platform => Platform.operatingSystem;

  /// Resolves the stable device id, generating + storing it once.
  /// Overridable for tests ([deviceIdProvider]).
  Future<String> Function() deviceIdProvider = _defaultDeviceIdProvider;

  static Future<String> _defaultDeviceIdProvider() async {
    final existing = await _deviceStorage.read(key: deviceIdStorageKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = generateDeviceId();
    await _deviceStorage.write(key: deviceIdStorageKey, value: id);
    return id;
  }

  /// Generates a stable device id: 16 random bytes as 32 lowercase hex
  /// chars. No new dependency — `crypto` is already in pubspec.
  static String generateDeviceId() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    return sha256.convert(bytes).toString().substring(0, 32);
  }

  /// Builds the display name from OS tokens, e.g. ("android", "12") →
  /// "Android 12". Pure, so it is unit-testable.
  static String formatDeviceName(String os, String version) {
    final name = os.isEmpty
        ? os
        : '${os[0].toUpperCase()}${os.substring(1)}';
    final v = version.trim();
    return v.isEmpty ? name : '$name $v';
  }

  /// Parses one session object from a Worker response. Missing fields are
  /// tolerated (the 409 summary omits deviceId/firstSeen/appVersion).
  static LicenseSession? parseSession(dynamic raw) {
    if (raw is! Map<String, dynamic>) return null;
    final id = raw['id'] as String?;
    if (id == null || id.isEmpty) return null;
    int? asInt(dynamic v) => v is num ? v.toInt() : int.tryParse('$v');
    return LicenseSession(
      id: id,
      deviceId: raw['deviceId'] as String?,
      name: (raw['name'] as String?) ?? '',
      platform: (raw['platform'] as String?) ?? '',
      appVersion: (raw['appVersion'] as String?) ?? '',
      firstSeen: asInt(raw['firstSeen']),
      lastSeen: asInt(raw['lastSeen']),
    );
  }

  /// Parses the sessions array of a Worker response (empty on bad input).
  static List<LicenseSession> parseSessions(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .map(parseSession)
        .whereType<LicenseSession>()
        .toList(growable: false);
  }

  /// Parses a 409 session-limit body into a structured error (null when the
  /// body is not a session-limit error).
  static SessionLimitError? parseLimitError(
      Map<String, dynamic> data, int statusCode) {
    if (statusCode != 409) return null;
    if (data['error'] != 'session-limit') return null;
    final max = data['maxUsers'];
    return SessionLimitError(
      maxUsers: max is num ? max.toInt() : 1,
      activeCount: data['activeCount'] is num
          ? (data['activeCount'] as num).toInt()
          : parseSessions(data['sessions']).length,
      sessions: parseSessions(data['sessions']),
    );
  }

  bool get isActive {
    if (_key == null || _expiresAt == null) return false;
    final now = DateTime.now().toUtc();
    if (now.isBefore(_expiresAt!)) return true;
    // Expired — allow the offline grace window since the last *successful*
    // server check, so outages don't lock people out.
    final checked = _checkedAt;
    if (checked != null && now.difference(checked) < _gracePeriod) return true;
    return false;
  }

  Duration get remaining {
    final e = _expiresAt;
    if (e == null) return Duration.zero;
    final d = e.difference(DateTime.now().toUtc());
    return d.isNegative ? Duration.zero : d;
  }

  /// Formatted expiry date string (Persian Jalali or Gregorian).
  String formatExpiry({bool fa = true, bool verbose = true}) {
    final exp = _expiresAt;
    if (exp == null) return '—';
    final local = exp.toLocal();
    if (fa) {
      final j = JalaliDate.fromDateTime(local);
      return verbose ? j.formatReadable() : j.format();
    }
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  /// Formats remaining time nicely in Persian or English.
  String formatRemaining({bool fa = true}) {
    final d = remaining;
    if (d <= Duration.zero) {
      return fa ? 'منقضی شده' : 'Expired';
    }
    String two(int n) => n.toString().padLeft(2, '0');
    if (fa) {
      if (d.inDays > 0) {
        final hours = d.inHours % 24;
        return JalaliDate.toPersianDigits(
            hours > 0 ? '${d.inDays} روز و $hours ساعت' : '${d.inDays} روز');
      }
      if (d.inHours > 0) {
        final mins = d.inMinutes % 60;
        return JalaliDate.toPersianDigits(
            mins > 0 ? '${d.inHours} ساعت و $mins دقیقه' : '${d.inHours} ساعت');
      }
      return JalaliDate.toPersianDigits('${d.inMinutes} دقیقه');
    } else {
      if (d.inDays > 0) return '${d.inDays}d ${two(d.inHours % 24)}h';
      if (d.inHours > 0) return '${d.inHours}h ${two(d.inMinutes % 60)}m';
      return '${d.inMinutes}m';
    }
  }

  /// Extracts a valid license key `VDRV-XXXX-XXXX-XXXX` from any raw text.
  static String? extractKey(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    final regex = RegExp(
      r'VDRV-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}',
      caseSensitive: false,
    );
    final match = regex.firstMatch(text);
    return match?.group(0)?.toUpperCase();
  }

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _key = prefs.getString(_prefKey);
    final exp = prefs.getString(_prefExpires);
    _expiresAt = exp == null ? null : DateTime.tryParse(exp)?.toUtc();
    final chk = prefs.getString(_prefCheckedAt);
    _checkedAt = chk == null ? null : DateTime.tryParse(chk)?.toUtc();
    _plan = prefs.getString(_prefPlan);
    _maxUsers = prefs.getInt(_prefMaxUsers);
    _sessionId = prefs.getString(_prefSessionId);
    _loaded = true;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    if (_key == null) {
      await prefs.remove(_prefKey);
    } else {
      await prefs.setString(_prefKey, _key!);
    }
    if (_expiresAt == null) {
      await prefs.remove(_prefExpires);
    } else {
      await prefs.setString(_prefExpires, _expiresAt!.toIso8601String());
    }
    if (_checkedAt == null) {
      await prefs.remove(_prefCheckedAt);
    } else {
      await prefs.setString(_prefCheckedAt, _checkedAt!.toIso8601String());
    }
    if (_plan == null) {
      await prefs.remove(_prefPlan);
    } else {
      await prefs.setString(_prefPlan, _plan!);
    }
    if (_maxUsers == null) {
      await prefs.remove(_prefMaxUsers);
    } else {
      await prefs.setInt(_prefMaxUsers, _maxUsers!);
    }
    if (_sessionId == null) {
      await prefs.remove(_prefSessionId);
    } else {
      await prefs.setString(_prefSessionId, _sessionId!);
    }
  }

  Future<void> _clearStoredLicense() async {
    _key = null;
    _expiresAt = null;
    _plan = null;
    _checkedAt = null;
    _maxUsers = null;
    _sessions = const [];
    _sessionId = null;
    _sessionActive = null;
    _lastLimitError = null;
    await _save();
  }

  /// Applies the session fields of a successful license/status response.
  /// Returns false when the response says this device's session no longer
  /// exists (revoked elsewhere).
  bool _applySessionFields(Map<String, dynamic> data, String? deviceId) {
    final max = data['maxUsers'];
    if (max is num) _maxUsers = max.toInt();
    if (data['sessions'] != null) {
      _sessions = parseSessions(data['sessions']);
    }
    final sid = data['sessionId'];
    if (sid is String && sid.isNotEmpty) _sessionId = sid;
    final active = data['sessionActive'];
    if (active is bool) {
      _sessionActive = active;
    } else if (deviceId != null && _sessions.isNotEmpty) {
      // Older Worker responses carry no sessionActive flag: derive it from
      // the sessions list — if our device is not among them, we were removed.
      final mine = _sessions.any((s) =>
          (s.id.isNotEmpty && s.id == _sessionId) ||
          (s.deviceId != null && s.deviceId == deviceId));
      _sessionActive = mine;
    } else {
      _sessionActive = null;
    }
    return _sessionActive != false;
  }

  /// Verify a key against the backend. Returns true when the license is valid.
  ///
  /// Sends this device's id, name, platform and app version so the Worker
  /// registers/refreshes the session. On HTTP 409 the structured
  /// [lastLimitError] holds the active sessions for the UI. When the
  /// Worker's response says this device's session was revoked, the stored
  /// key is cleared and `lastError` is 'session-revoked'.
  Future<bool> check({String? keyOverride, http.Client? client}) async {
    final rawKey = (keyOverride ?? _key)?.trim();
    _lastError = null;
    _lastLimitError = null;
    final k = extractKey(rawKey) ?? rawKey;
    if (k == null || k.isEmpty) {
      _lastError = 'no-key';
      return false;
    }
    String? deviceId;
    try {
      deviceId = _deviceId ??= await deviceIdProvider();
    } catch (_) {
      // Secure storage unavailable: fall back to the legacy request without
      // a device id instead of blocking activation.
      deviceId = null;
    }
    final httpClient = client ?? http.Client();
    try {
      final query = <String, String>{'key': k};
      if (deviceId != null) {
        query['deviceId'] = deviceId;
        query['deviceName'] = deviceName;
        query['platform'] = platform;
        query['appVersion'] = AppInfo.version;
      }
      final res = await httpClient
          .get(
            Uri.parse('$apiBase/api/license').replace(queryParameters: query),
            headers: {'User-Agent': 'VoidrauVPN/${AppInfo.version}'},
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 409) {
        Map<String, dynamic> data = const {};
        try {
          final parsed = jsonDecode(res.body);
          if (parsed is Map<String, dynamic>) data = parsed;
        } catch (_) {}
        _lastLimitError = parseLimitError(data, res.statusCode);
        _lastError = 'session-limit';
        return false;
      }
      if (res.statusCode != 200) {
        _lastError = 'server-${res.statusCode}';
        return false;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['ok'] != true) {
        _lastError = (data['error'] as String?) ?? 'invalid';
        // Only wipe the stored key if we checked *that* key and it is
        // genuinely rejected — a network error must never log someone out.
        if (keyOverride != null || _key == k) {
          if (_lastError == 'invalid' || _lastError == 'revoked') {
            await _clearStoredLicense();
          }
        }
        return false;
      }
      _key = k;
      _plan = data['plan'] as String?;
      final exp = data['expiresAt'];
      _expiresAt = exp == null
          ? null
          : (exp is num
              ? DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000,
                  isUtc: true)
              : DateTime.tryParse(exp.toString())?.toUtc());
      _checkedAt = DateTime.now().toUtc();
      if (!_applySessionFields(data, deviceId)) {
        _lastError = 'session-revoked';
        await _clearStoredLicense();
        return false;
      }
      await _save();
      return isActive;
    } catch (e) {
      _lastError = 'network';
      // Offline: fall back to the cached state (grace period decides).
      return isActive;
    } finally {
      if (client == null) httpClient.close();
    }
  }

  /// Removes one session of this license. Returns true on success and
  /// refreshes [sessions] from the Worker's response.
  Future<bool> revokeSession(String sessionId, {http.Client? client}) async {
    _lastError = null;
    final k = _key;
    if (k == null || k.isEmpty) {
      _lastError = 'no-key';
      return false;
    }
    String? deviceId;
    try {
      deviceId = _deviceId ??= await deviceIdProvider();
    } catch (_) {
      deviceId = null;
    }
    if (deviceId == null) {
      _lastError = 'no-device';
      return false;
    }
    final httpClient = client ?? http.Client();
    try {
      final res = await httpClient
          .post(
            Uri.parse('$apiBase/api/sessions/revoke'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(
                {'key': k, 'sessionId': sessionId, 'deviceId': deviceId}),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        _lastError = 'server-${res.statusCode}';
        return false;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['ok'] != true) {
        _lastError = (data['error'] as String?) ?? 'revoke-failed';
        return false;
      }
      if (data['sessions'] != null) {
        _sessions = parseSessions(data['sessions']);
      } else {
        _sessions = _sessions.where((s) => s.id != sessionId).toList();
      }
      return true;
    } catch (_) {
      _lastError = 'network';
      return false;
    } finally {
      if (client == null) httpClient.close();
    }
  }

  /// Removes all sessions except this device's (when [keepCurrent] is true).
  /// Returns true on success and refreshes [sessions] from the response.
  Future<bool> revokeAllSessions(
      {bool keepCurrent = true, http.Client? client}) async {
    _lastError = null;
    final k = _key;
    if (k == null || k.isEmpty) {
      _lastError = 'no-key';
      return false;
    }
    String? deviceId;
    try {
      deviceId = _deviceId ??= await deviceIdProvider();
    } catch (_) {
      deviceId = null;
    }
    if (deviceId == null) {
      _lastError = 'no-device';
      return false;
    }
    final httpClient = client ?? http.Client();
    try {
      final body = <String, dynamic>{'key': k, 'deviceId': deviceId};
      if (keepCurrent && _sessionId != null) {
        body['keepSessionId'] = _sessionId;
      }
      final res = await httpClient
          .post(
            Uri.parse('$apiBase/api/sessions/revoke-all'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        _lastError = 'server-${res.statusCode}';
        return false;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['ok'] != true) {
        _lastError = (data['error'] as String?) ?? 'revoke-failed';
        return false;
      }
      if (data['sessions'] != null) {
        _sessions = parseSessions(data['sessions']);
      } else if (keepCurrent) {
        _sessions = _sessions
            .where((s) => s.id == _sessionId || s.deviceId == deviceId)
            .toList();
      } else {
        _sessions = const [];
      }
      return true;
    } catch (_) {
      _lastError = 'network';
      return false;
    } finally {
      if (client == null) httpClient.close();
    }
  }

  /// Ask the backend for a free trial key tied to this install.
  Future<String?> requestTrial(String telegramId) async {
    _lastError = null;
    try {
      final res = await http
          .post(
            Uri.parse('$apiBase/api/trial'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'telegramId': telegramId}),
          )
          .timeout(const Duration(seconds: 15));
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['ok'] != true) {
        _lastError = (data['error'] as String?) ?? 'trial-failed';
        return null;
      }
      return data['key'] as String?;
    } catch (_) {
      _lastError = 'network';
      return null;
    }
  }

  Future<void> signOut() async {
    await _clearStoredLicense();
  }
}

/// One active device session on a license, as reported by the Worker.
class LicenseSession {
  const LicenseSession({
    required this.id,
    this.deviceId,
    required this.name,
    required this.platform,
    required this.appVersion,
    this.firstSeen,
    this.lastSeen,
  });

  /// Worker session id (`ses_<hex>`).
  final String id;

  /// Stable device id; absent in the short 409 summary.
  final String? deviceId;

  /// Human device name, e.g. "Android 12".
  final String name;

  /// `android` | `windows` | `ios`.
  final String platform;

  /// App version that registered the session, e.g. "1.5.3".
  final String appVersion;

  /// Unix seconds of first / last activity (null when not reported).
  final int? firstSeen;
  final int? lastSeen;

  /// Last activity as a [DateTime], or null when unreported.
  DateTime? get lastSeenDate => lastSeen == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(lastSeen! * 1000, isUtc: true);

  /// True when the session has been quiet for over 30 days. Shown as
  /// inactive; never auto-deleted.
  bool get isStale {
    final seen = lastSeenDate;
    if (seen == null) return false;
    return DateTime.now().toUtc().difference(seen) >
        LicenseService.staleSessionAfter;
  }

  /// Display name, falling back to the platform when the Worker sent none.
  String get displayName {
    if (name.isNotEmpty) return name;
    if (platform.isEmpty) return 'دستگاه ناشناس';
    return LicenseService.formatDeviceName(platform, '');
  }

  /// Platform icon name for the UI.
  String get platformLabel {
    switch (platform) {
      case 'android':
        return 'اندروید';
      case 'windows':
        return 'ویندوز';
      case 'ios':
        return 'آیفون';
      default:
        return platform.isEmpty ? 'نامشخص' : platform;
    }
  }
}

/// Structured HTTP 409 `session-limit` error: the plan's device cap plus the
/// currently active sessions, so the UI can offer removing one.
class SessionLimitError {
  const SessionLimitError({
    required this.maxUsers,
    required this.activeCount,
    required this.sessions,
  });

  final int maxUsers;
  final int activeCount;
  final List<LicenseSession> sessions;
}
