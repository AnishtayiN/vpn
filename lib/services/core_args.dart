import 'dart:io' show Platform;

import '../models/settings.dart';
import 'split.dart';

/// Builds the tunnel-core launch configuration.
///
/// The core is driven **only through environment variables** and never through
/// CLI flags; that is its documented configuration contract, and env-only
/// keeps the Android and Windows launchers behaviourally identical.
///
/// The list below tracks Aether 2.3.0 (`aether --help`, `Docs/DOCS.en.md`):
/// transports, the QUIC v2 opener, ECH, the exit lock, traffic counters, the
/// performance profile, the Psiphon/Tor chains and the routing rules.
class CoreLaunch {
  static const coreVersion = '2.1.0';

  /// Obfuscation profile given to the core. The core accepts
  /// off|light|balanced|aggressive (plus aliases like gfw/firewall); anything
  /// unknown falls back to its "firewall" preset, so unrecognised values are
  /// harmless, but we always send a documented value.
  static String noizeFor(Protocol protocol, String obfuscation) {
    const known = {'off', 'light', 'balanced', 'aggressive', 'gfw', 'firewall'};
    if (known.contains(obfuscation)) return obfuscation;
    return 'balanced';
  }

  static String _ipToken(IpVersion v) => switch (v) {
        IpVersion.v4 => 'v4',
        IpVersion.v6 => 'v6',
        IpVersion.dual => 'both',
      };

  static Protocol _effective(VpnSettings s, Protocol? override) {
    final p = override ?? s.protocol;
    return p == Protocol.smart ? Protocol.masque : p;
  }

  static bool _masqueFamily(Protocol p) =>
      p == Protocol.masque || p == Protocol.mim;

  /// Value for `AETHER_EXIT_LOC`, or null when the core should not enforce the
  /// rule itself.
  ///
  /// The core parses **either** an allow-list (`DE,SE`) **or** a deny-list
  /// (`!IR,RU`) — a `!` anywhere else is dropped, so the two are never mixed
  /// here. *Any IP but Iran* is a deny-list; *preferred country* is an
  /// allow-list of the wanted countries with the blocked ones removed first,
  /// and a deny-list when that leaves nothing (clearing the preferred list must
  /// never let a blocked exit in — the same rule the client-side filter
  /// applies after the tunnel is up).
  static String? exitLoc(VpnSettings s) {
    if (!s.coreExitLoc || s.exitRulePaused) return null;
    final blocked = s.exitBlocked.map((e) => e.toUpperCase()).toList();
    final wanted = s.exitPreferred.map((e) => e.toUpperCase()).toList();
    switch (s.exitFilter) {
      case ExitFilter.off:
        return null;
      case ExitFilter.nonIran:
        return blocked.isEmpty ? null : '!${blocked.join(',')}';
      case ExitFilter.preferred:
        final allow = wanted.where((c) => !blocked.contains(c)).toList();
        if (allow.isNotEmpty) return allow.join(',');
        return blocked.isEmpty ? null : '!${blocked.join(',')}';
    }
  }

  /// How often the core re-checks the exit country, in seconds.
  static const int exitLocSecs = 60;

  /// Routing rules that send a destination out of the physical interface
  /// instead of the tunnel — the domain/IP half of split tunneling.
  static List<String> directRules(VpnSettings s) => s.routeDirect;

  /// Destinations refused outright.
  static List<String> blockRules(VpnSettings s) => s.routeBlock;

  /// Whether a chain mode needs Tor's pluggable transports next to the binary.
  static bool isTor(ChainMode c) =>
      c == ChainMode.tor || c == ChainMode.torReverse || c == ChainMode.torOnly;

  static bool isPsiphon(ChainMode c) =>
      c == ChainMode.psiphon ||
      c == ChainMode.psiphonReverse ||
      c == ChainMode.psiphonOnly;

  static String? _chainToken(ChainMode c) {
    switch (c) {
      case ChainMode.off:
        return null;
      case ChainMode.psiphon:
      case ChainMode.tor:
        return 'chain';
      case ChainMode.psiphonReverse:
      case ChainMode.torReverse:
        return 'reverse';
      case ChainMode.psiphonOnly:
      case ChainMode.torOnly:
        return 'only';
    }
  }

  /// The environment the core runs with:
  ///   AETHER_PROTOCOL / SCAN / IP / NOIZE / SOCKS / CONFIG / QUICK_RECONNECT /
  ///   LOG_LEVEL, then transport-specific keys, the exit lock, the performance
  ///   profile, the optional second hop and the routing rules.
  /// (The `AETHER_*` names are the core's own interface and must stay.)
  static Map<String, String> environment(
    VpnSettings settings, {
    Protocol? override,

    /// Absolute path of the identity file the core may write (aether.toml).
    /// Must live in a per-user writable directory — never next to the exe
    /// (Program Files is read-only for normal users and a failed identity
    /// write is the most common "spins forever" cause on Windows).
    required String configPath,
    String? tmpDir,
    /// Directory the core may use for Tor state and its own files. Defaults to
    /// the config file's directory.
    String? stateDir,

    /// Windows has no firewall mark, so a "direct" destination only leaves the
    /// tunnel when the launcher also installed a bypass route for its address.
    /// Callers pass false on Android, where the core is excluded from the VPN
    /// and can dial any destination directly. Defaults to the real platform so
    /// production behaviour is unchanged.
    bool? windowsMode,
  }) {
    final proto = _effective(settings, override);
    final bind = settings.lanShare && Platform.isWindows
        ? '0.0.0.0:${settings.socksPort}'
        : settings.socksBind;
    final env = <String, String>{
      'AETHER_PROTOCOL': proto.name,
      'AETHER_SCAN': settings.scan.name,
      'AETHER_IP': _ipToken(settings.ipVersion),
      'AETHER_NOIZE': noizeFor(proto, settings.obfuscation),
      'AETHER_SOCKS': bind,
      'AETHER_CONFIG': configPath,
      'AETHER_QUICK_RECONNECT': settings.quickReconnect ? '1' : '0',
      'AETHER_LOG_LEVEL': switch (settings.logLevel) {
        'error' || 'warn' || 'info' || 'debug' || 'trace' => settings.logLevel,
        _ => 'info',
      },
      // Traffic counters: they feed the live rate meter on the dashboard, and
      // they are the only byte counts Windows has (Android reads the bridge's
      // own counters through the JNI surface).
      'AETHER_STATS': '1',
      'AETHER_STATS_SECS': '5',
    };
    if (_masqueFamily(proto)) {
      env['AETHER_MASQUE_HTTP2'] =
          settings.transport == MasqueTransport.h2 ? '1' : '0';
      final mtu = settings.coreMtuOverride;
      if (mtu > 0) env['AETHER_MASQUE_MTU'] = '$mtu';
      if (settings.transport == MasqueTransport.h2 && settings.fragment) {
        env['AETHER_MASQUE_H2_FRAGMENT'] = '1';
      }
    } else {
      env['AETHER_WG_KEEPALIVE'] = '${settings.keepalive}';
    }
    final peer = settings.endpoint.trim();
    if (peer.isNotEmpty) {
      if (_masqueFamily(proto)) {
        env['AETHER_PEER'] = peer;
      } else {
        env['AETHER_WG_PEER'] = peer;
      }
    }

    // ── speed ──────────────────────────────────────────────────────────────
    final perf = settings.perfToken;
    if (perf != null) env['AETHER_PERF_PROFILE'] = perf;
    final rx = settings.netstackRxBytes;
    final tx = settings.netstackTxBytes;
    if (rx > 0) env['AETHER_NETSTACK_TCP_RX'] = '$rx';
    if (tx > 0) env['AETHER_NETSTACK_TCP_TX'] = '$tx';
    if (settings.tcpConnectSecs > 0) {
      env['AETHER_TCP_CONNECT_SECS'] = '${settings.tcpConnectSecs}';
    }
    if (settings.tcpKeepaliveSecs > 0) {
      env['AETHER_TCP_KEEPALIVE_SECS'] = '${settings.tcpKeepaliveSecs}';
    }
    if (settings.halfCloseSecs > 0) {
      env['AETHER_HALF_CLOSE_SECS'] = '${settings.halfCloseSecs}';
    }

    // ── censorship workarounds ────────────────────────────────────────────
    if (!settings.quicV2) env['AETHER_QUIC_V2'] = '0';
    if (settings.ech) env['AETHER_ECH'] = 'auto';

    // ── exit country, enforced by the core ────────────────────────────────
    final loc = exitLoc(settings);
    if (loc != null) {
      env['AETHER_EXIT_LOC'] = loc;
      env['AETHER_EXIT_LOC_SECS'] = '$exitLocSecs';
    }

    // ── split tunneling by destination (works on every platform) ─────────
    final direct =
        SplitRules.coreDirectEntries(settings, windows: windowsMode ?? Platform.isWindows);
    final block = SplitRules.normalize(blockRules(settings));
    if (direct.isNotEmpty) env['AETHER_ROUTE_DIRECT'] = direct.join(',');
    if (block.isNotEmpty) env['AETHER_ROUTE_BLOCK'] = block.join(',');

    // ── extra listener for apps that cannot speak SOCKS5 ──────────────────
    if (settings.httpProxy) env['AETHER_HTTP_PROXY'] = settings.httpBind;

    // ── second hop: Psiphon / Tor inside the core ─────────────────────────
    final hop = _chainToken(settings.chain);
    if (hop != null) {
      // Both chains serve their own proxy on the same default port; pin it two
      // above ours so it can never collide with the extra HTTP listener.
      final chainBind = '127.0.0.1:${settings.hopPort}';
      if (isPsiphon(settings.chain)) {
        env['AETHER_PSIPHON'] = hop;
        env['AETHER_PSIPHON_BIND'] = chainBind;
        final region = settings.psiphonRegion.trim().toUpperCase();
        if (region.isNotEmpty) env['AETHER_PSIPHON_REGION'] = region;
        env['AETHER_PSIPHON_MODE'] = settings.psiphonCdn ? 'cdn' : 'direct';
        if (settings.hopHttp) {
          // The hop's own HTTP listener would collide with the tunnel's, so a
          // dedicated port is reserved for it.
          env['AETHER_PSIPHON_HTTP'] = '127.0.0.1:${settings.hopHttpPort}';
        }
      } else {
        env['AETHER_TOR'] = hop;
        env['AETHER_TOR_BIND'] = chainBind;
        final country = settings.torCountry.trim().toLowerCase();
        if (country.isNotEmpty) env['AETHER_TOR_COUNTRY'] = country;
        if (settings.hopHttp) {
          env['AETHER_TOR_HTTP'] = '127.0.0.1:${settings.hopHttpPort}';
        }
      }
      // Tor keeps its directory cache (and its pluggable transports) beside the
      // identity file instead of inside the read-only app bundle.
      final dir = stateDir ?? configPath;
      final slash = dir.lastIndexOf(RegExp(r'[/\\]'));
      if (slash > 0) {
        env['AETHER_TOR_DIR'] = '${dir.substring(0, slash)}/aether-tor';
        env['AETHER_PSIPHON_DIR'] =
            '${dir.substring(0, slash)}/aether-psiphon';
      }
    }

    if (tmpDir != null && tmpDir.isNotEmpty) env['TMPDIR'] = tmpDir;
    return env;
  }

  /// Serialised "KEY=VALUE" list for passing through the Android intent.
  static List<String> environmentLines(
    VpnSettings settings, {
    Protocol? override,
    required String configPath,
    String? tmpDir,
    String? stateDir,
  }) {
    return environment(
      settings,
      override: override,
      configPath: configPath,
      tmpDir: tmpDir,
      stateDir: stateDir,
    ).entries.map((e) {
      // Env is re-parsed line-by-line inside the Android service; a newline in
      // a value would inject an extra KEY=VALUE pair.
      final v = e.value.replaceAll(RegExp(r'[\r\n]'), ' ');
      final k = e.key.replaceAll(RegExp(r'[\r\n]'), ' ');
      return '$k=$v';
    }).toList();
  }

  /// Smart Connect ladder. masque appears twice: the first attempt keeps the
  /// chosen carrier and the second forces HTTP/2, because networks that drop
  /// QUIC outright only pass the TCP 443 carrier. The native Android service
  /// also races h3→h2 on its own inside the first attempt; running the h2
  /// attempt again later is harmless.
  static List<Protocol> smartLadder(VpnSettings settings) {
    if (settings.protocol != Protocol.smart) {
      return [settings.protocol];
    }
    return const [
      Protocol.masque,
      Protocol.masque,
      Protocol.wg,
      Protocol.gool,
      Protocol.mim,
    ];
  }

  /// The settings for ladder entry [index]: the chosen protocol plus the
  /// escalation Smart Connect adds after an attempt has failed.
  ///
  /// The failures have an order, and so has the answer to them:
  ///
  /// * **pass 2** rides the **HTTP/2 carrier** (TCP 443) — what a network that
  ///   drops QUIC or UDP 443 lets through — with the ClientHello **fragmented**
  ///   and **ECH** asked for, because a carrier that inspects TLS is matching on
  ///   the server name, and that is exactly what those two hide;
  /// * **later passes** keep ECH on for the MASQUE family: an open QUIC path is
  ///   not worth much if the handshake behind it is being fingerprinted;
  /// * once the whole ladder has been walked (the exit search does that), the
  ///   carrier is flipped on every other pass — a different carrier means a
  ///   different gateway pool, which is the only lever the client has for
  ///   landing in another country.
  ///
  /// [index] is the rung of the *whole search*, not of this pass: the exit
  /// search hands in `epoch * ladder.length + i`, so index 5 of a five-rung
  /// ladder is the first rung of the second pass, and the flip has something to
  /// alternate against.
  static VpnSettings smartVariant(
    VpnSettings base, {
    required int index,
    required List<Protocol> ladder,
    required Protocol proto,
    String? endpoint,
  }) {
    final variant = base.copyWithProtocol(proto);
    final masque = proto == Protocol.masque || proto == Protocol.mim;
    if (base.protocol == Protocol.smart && ladder.length > 1) {
      // The second rung of every pass carries the hidden handshake: it is the
      // rung that runs after the plain QUIC attempt has already failed.
      if (index % ladder.length == 1) {
        variant.transport = MasqueTransport.h2;
        variant.fragment = true;
        variant.ech = true;
      } else if (index > 0 && masque) {
        variant.ech = true;
      }
      // Past the first pass the carrier alternates, rung by rung, so a network
      // that keeps landing the tunnel in a country the user filtered out gets a
      // different gateway pool to choose from. Only the MASQUE family has a
      // carrier to flip; WireGuard does not.
      if (masque && index >= ladder.length && index.isOdd) {
        variant.transport = variant.transport == MasqueTransport.h3
            ? MasqueTransport.h2
            : MasqueTransport.h3;
        if (variant.transport == MasqueTransport.h2) variant.fragment = true;
      }
    }
    if (endpoint != null && endpoint.isNotEmpty) variant.endpoint = endpoint;
    return variant;
  }
}

/// Snapshot of the core's own traffic counters, parsed from its `--stats` line:
///
/// ```
/// [=] up 1.2 MiB down 8.0 MiB uptime 00:01:31
/// ```
///
/// Windows has no other byte counter (the Android bridge reports its own
/// through the JNI surface), and the same lines double as the live rate meter.
class CoreStats {
  const CoreStats({
    required this.upBytes,
    required this.downBytes,
    this.uptime = Duration.zero,
  });

  final int upBytes;
  final int downBytes;
  final Duration uptime;

  static final _line = RegExp(
    r'\[\=\]\s*up\s+(\S+\s*\S*)\s+down\s+(\S+\s*\S*)\s+uptime\s+(\S+)',
  );

  /// Parses one log line; null when it is not a stats report.
  static CoreStats? parse(String line) {
    final m = _line.firstMatch(line);
    if (m == null) return null;
    final up = bytes(m.group(1));
    final down = bytes(m.group(2));
    if (up == null || down == null) return null;
    return CoreStats(
      upBytes: up,
      downBytes: down,
      uptime: duration(m.group(3) ?? ''),
    );
  }

  /// `"1.2 MiB"`, `"832 KiB"` or `"512 B"` → bytes.
  static int? bytes(String? text) {
    final t = (text ?? '').trim();
    if (t.isEmpty) return null;
    final m = RegExp(r'^([0-9]+(?:\.[0-9]+)?)\s*([A-Za-z]*)$').firstMatch(t);
    if (m == null) return null;
    final value = double.tryParse(m.group(1)!);
    if (value == null) return null;
    final unit = m.group(2)!.toUpperCase();
    final factor = switch (unit) {
      '' || 'B' => 1,
      'K' || 'KB' || 'KIB' => 1024,
      'M' || 'MB' || 'MIB' => 1024 * 1024,
      'G' || 'GB' || 'GIB' => 1024 * 1024 * 1024,
      'T' || 'TB' || 'TIB' => 1024 * 1024 * 1024 * 1024,
      _ => 0,
    };
    if (factor == 0) return null;
    return (value * factor).round();
  }

  /// `00:01:31` or `1d 01:01:01` → a duration.
  static Duration duration(String text) {
    final t = text.trim();
    var days = 0;
    var rest = t;
    final d = RegExp(r'^(\d+)d\s+(.*)$').firstMatch(t);
    if (d != null) {
      days = int.tryParse(d.group(1)!) ?? 0;
      rest = d.group(2)!;
    }
    final parts = rest.split(':');
    if (parts.length != 3) return Duration(days: days);
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    final s = int.tryParse(parts[2]) ?? 0;
    return Duration(days: days, hours: h, minutes: m, seconds: s);
  }
}
