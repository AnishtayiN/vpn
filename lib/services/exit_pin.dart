// Exit-pin cache — AetherGUI-style endpoint reuse for the exit search.
//
// The problem: the core picks its own gateway, so every connect is a fresh
// gamble on the exit country. When the search finally lands a non-IR exit,
// that gateway pair is thrown away and the next connect gambles again.
//
// The fix (same shape as Aethon's gool-endpoints.json): when a tunnel is
// accepted, remember the endpoint+protocol that produced it. The next search
// *starts* from that pin — same probes, never a shortcut — and a pin that
// comes back rejected (wrong country) or fails to connect is invalidated at
// once instead of being retried until the stall timeout.
//
// Storage is one JSON record in SharedPreferences, keyed by network so a pin
// picked on Wi-Fi is not replayed on mobile data (different path, different
// gateway pool — Aethon learned this the hard way: cache hit rate zero).
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One accepted tunnel's dial facts.
class ExitPin {
  ExitPin({
    required this.endpoint,
    required this.protocol,
    required this.country,
    required this.network,
    required this.savedAtMs,
  });

  final String endpoint;
  final String protocol;
  final String country;
  final String network;
  final int savedAtMs;

  /// Cloudflare rotates edge capacity; a pin older than six hours is more
  /// likely slow than absent, so the search ignores it and scans fresh.
  static const maxAgeMs = 6 * 60 * 60 * 1000;

  bool get fresh =>
      endpoint.isNotEmpty &&
      DateTime.now().millisecondsSinceEpoch - savedAtMs < maxAgeMs;

  Map<String, dynamic> toJson() => {
        'endpoint': endpoint,
        'protocol': protocol,
        'country': country,
        'network': network,
        'savedAtMs': savedAtMs,
      };

  static ExitPin? fromJson(Map<String, dynamic> json) {
    final endpoint = '${json['endpoint'] ?? ''}'.trim();
    final protocol = '${json['protocol'] ?? ''}'.trim();
    if (endpoint.isEmpty || protocol.isEmpty) return null;
    final saved = json['savedAtMs'];
    return ExitPin(
      endpoint: endpoint,
      protocol: protocol,
      country: '${json['country'] ?? ''}'.trim(),
      network: '${json['network'] ?? ''}'.trim(),
      savedAtMs: saved is int ? saved : 0,
    );
  }
}

/// Which network the device is on right now, as a coarse fingerprint.
/// Interface names differ per platform; the carrier/wifi split is what matters.
Future<String> currentNetworkKind() async {
  // Platform.networkInterfaces would need connectivity_plus; keep this
  // dependency-free: the controller passes what it knows. Android reports
  // through the engine event stream; elsewhere an empty kind is fine (the pin
  // just applies to every network — the pre-Aethon behaviour, still better
  // than no pin at all).
  return '';
}

/// Loads the stored pin for [network]; null when absent, stale, or for a
/// different network.
Future<ExitPin?> loadExitPin(String network) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('exitPin');
    if (raw == null || raw.isEmpty) return null;
    final pin = ExitPin.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    if (pin == null) return null;
    if (!pin.fresh) {
      await prefs.remove('exitPin');
      return null;
    }
    if (pin.network.isNotEmpty && network.isNotEmpty && pin.network != network) {
      return null;
    }
    return pin;
  } catch (_) {
    return null;
  }
}

/// Stores [pin] for the accepted tunnel. Called only after the exit probe has
/// *verified* the country — a listener that merely opened is not a pin.
Future<void> storeExitPin(ExitPin pin) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('exitPin', jsonEncode(pin.toJson()));
  } catch (_) {
    // A failed write costs one extra scan next time; never fatal.
  }
}

/// Removes the pin. Called when a pinned dial connects into a blocked country
/// (the gateway is no longer good) or when the tunnel dies outright.
Future<void> invalidateExitPin() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('exitPin');
  } catch (_) {}
}
