import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../app_info.dart';

/// Client for the VoidrauVPN license backend (Cloudflare Worker).
///
/// The Worker exposes:
///   GET  /api/license?key=XXXX          → { ok, plan, expiresAt, telegram }
///   POST /api/trial {telegramId, key?}  → { ok, key, expiresAt } (24h trial)
///   GET  /api/status?key=XXXX           → same shape as /license
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
    defaultValue: 'https://voidrau-license.anishtayin.workers.dev',
  );

  static const _prefKey = 'license.key';
  static const _prefExpires = 'license.expiresAt';
  static const _prefCheckedAt = 'license.checkedAt';
  static const _prefPlan = 'license.plan';
  static const _gracePeriod = Duration(hours: 72);

  String? _key;
  DateTime? _expiresAt;
  DateTime? _checkedAt;
  String? _plan;
  bool _loaded = false;
  String? _lastError;

  String? get key => _key;
  String? get plan => _plan;
  String? get lastError => _lastError;
  DateTime? get expiresAt => _expiresAt;

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

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _key = prefs.getString(_prefKey);
    final exp = prefs.getString(_prefExpires);
    _expiresAt = exp == null ? null : DateTime.tryParse(exp)?.toUtc();
    final chk = prefs.getString(_prefCheckedAt);
    _checkedAt = chk == null ? null : DateTime.tryParse(chk)?.toUtc();
    _plan = prefs.getString(_prefPlan);
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
  }

  /// Verify a key against the backend. Returns true when the license is valid.
  Future<bool> check({String? keyOverride}) async {
    final k = (keyOverride ?? _key)?.trim();
    _lastError = null;
    if (k == null || k.isEmpty) {
      _lastError = 'no-key';
      return false;
    }
    try {
      final res = await http
          .get(
            Uri.parse('$apiBase/api/license?key=${Uri.encodeComponent(k)}'),
            headers: {'User-Agent': 'VoidrauVPN/${AppInfo.version}'},
          )
          .timeout(const Duration(seconds: 15));
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
            _key = null;
            _expiresAt = null;
            _plan = null;
            _checkedAt = null;
            await _save();
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
              ? DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true)
              : DateTime.tryParse(exp.toString())?.toUtc());
      _checkedAt = DateTime.now().toUtc();
      await _save();
      return isActive;
    } catch (e) {
      _lastError = 'network';
      // Offline: fall back to the cached state (grace period decides).
      return isActive;
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
    _key = null;
    _expiresAt = null;
    _checkedAt = null;
    _plan = null;
    await _save();
  }
}
