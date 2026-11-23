import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One real ping measurement for one exit country: the round trip the
/// dashboard probe actually measured while a tunnel was exiting there.
class CountryPing {
  const CountryPing({required this.ms, required this.at});

  /// Round trip in milliseconds, as measured through the tunnel.
  final int ms;

  /// When the measurement was taken.
  final DateTime at;
}

/// The last real ping measured for each exit country, persisted across
/// restarts.
///
/// This app has no per-country servers to ping before connecting — the core
/// picks its own gateway and the exit country is only known once a tunnel is
/// up — so the only honest per-country latency is the one measured on a real
/// connection that actually exited there. The country picker shows these
/// last measurements (and "—" where none exists yet) instead of inventing a
/// number for a country the app has never carried traffic through.
///
/// A measurement is recorded only where the probe returns the exit country
/// and the round trip together (see `SocksProbe.exitInfo`), so a ping can
/// never be filed under the wrong country's flag.
class CountryPingStore {
  static const String _key = 'countryPings';

  final Map<String, CountryPing> _byCode = {};

  /// The last measurement for [code] (any case), or null when this country
  /// has never been measured — the picker shows that as unavailable.
  CountryPing? of(String code) => _byCode[code.trim().toUpperCase()];

  /// All recorded measurements, keyed by upper-case ISO code.
  Map<String, CountryPing> get all => Map.unmodifiable(_byCode);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _byCode.clear();
      json.forEach((code, v) {
        if (v is Map) {
          final ms = int.tryParse('${v['ms'] ?? ''}');
          final atMs = int.tryParse('${v['at'] ?? ''}');
          if (ms != null && ms > 0 && atMs != null) {
            _byCode[code.toUpperCase()] = CountryPing(
              ms: ms,
              at: DateTime.fromMillisecondsSinceEpoch(atMs),
            );
          }
        }
      });
    } catch (_) {
      // A corrupt store must never block boot: the picker just shows "—".
      _byCode.clear();
    }
  }

  /// Files a real measurement under its exit country and persists it.
  /// Non-positive pings and empty codes are dropped — a failed probe is
  /// recorded as nothing, never as a number.
  Future<void> record(String code, int ms, {DateTime? at}) async {
    final c = code.trim().toUpperCase();
    if (c.length != 2 || ms <= 0) return;
    _byCode[c] = CountryPing(ms: ms, at: at ?? DateTime.now());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode({
        for (final e in _byCode.entries)
          e.key: {'ms': e.value.ms, 'at': e.value.at.millisecondsSinceEpoch},
      }),
    );
  }
}
