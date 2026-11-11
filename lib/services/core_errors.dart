import '../l10n/strings.dart';

/// Turns a raw tunnel-core failure into something the user can act on.
///
/// The core speaks English and names its own options (`--psiphon-only`,
/// `AETHER_TOR_PT`); the Connect page shows this text as the status line,
/// so an untranslated one-liner reads as a dead end. Known signatures get a
/// Persian explanation (and the English equivalent when the UI is English);
/// anything unknown passes through unchanged — a mapped message must never
/// hide a failure the map does not understand. The full raw line stays in
/// the Diagnostics logs either way.
String friendlyCoreError(String raw, S s) {
  final lower = raw.toLowerCase();
  if (lower.contains('psiphon needs the psiphon-tunnel-core')) {
    return s.errPsiphonMissing;
  }
  if (lower.contains('nothing here can speak obfs4')) {
    return s.errTorNoTransports;
  }
  if (lower.contains('can never be reached through tor') ||
      lower.contains('wireguard endpoints answer on udp alone')) {
    return s.errReverseWg;
  }
  if (lower.contains('psiphon did not come up in time') ||
      lower.contains('tor did not come up in time')) {
    return s.errHopSlow;
  }
  if (lower.contains('socks5 listener did not start')) {
    return s.errSocksTimeout;
  }
  if (lower.contains('real traffic validation failed') ||
      lower.contains('tunnel carries no traffic') ||
      lower.contains('gateway cannot carry traffic')) {
    return s.errNoTraffic;
  }
  if (lower.contains('tunnel core exited')) {
    return s.errCoreExited;
  }
  return raw;
}
