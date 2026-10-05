import 'dart:io';

/// The userspace bridge that carries the SOCKS5 stream into the WinTUN device.
///
/// VoidrauVPN ships more than one on purpose, because a single bridge cannot cover
/// every Windows the app claims to support (8.1 → 11):
///
/// * [tun2socks] — the current xjasonlyu/tun2socks release. It is a **Go**
///   binary and Go ≥ 1.21 requires Windows 10+; on Windows 8.1 the process
///   dies before it can create the adapter.
/// * [tun2socksLegacy] — tun2socks v2.5.1, the last release built with
///   **Go 1.20**, which still runs on Windows 7/8/8.1.
/// * [hev] — the C build of heiher/hev-socks5-tunnel (the same bridge the
///   Android side uses). No Go runtime, so no OS floor above what WinTUN
///   itself needs.
///
/// Every bridge needs `wintun.dll` next to it.
enum TunBackend {
  tun2socks('tun2socks.exe', 'tun2socks'),
  tun2socksLegacy('tun2socks-legacy.exe', 'tun2socks legacy (Go 1.20)'),
  hev('hev-socks5-tunnel.exe', 'hev-socks5-tunnel');

  const TunBackend(this.fileName, this.label);

  /// File name as staged next to `voidrauvpn.exe` (see `scripts/fetch_cores.sh`).
  final String fileName;

  /// Human-readable name for logs and the diagnostics page.
  final String label;
}

/// Windows version facts that decide which bridge to try first.
class WindowsBuild {
  const WindowsBuild(this.build);

  /// `CurrentBuild`: 7601 = Windows 7 SP1, 9200 = 8, 9600 = 8.1,
  /// 10240+ = 10, 22000+ = 11.
  final int build;

  static const unknown = WindowsBuild(0);

  bool get isKnown => build > 0;

  /// Go ≥ 1.21 (what current tun2socks releases are built with) requires
  /// Windows 10 / Server 2016 or newer.
  bool get supportsGoRuntime => build >= 10240;

  String get label {
    if (build <= 0) return 'unknown Windows';
    if (build >= 22000) return 'Windows 11 (build $build)';
    if (build >= 10240) return 'Windows 10 (build $build)';
    if (build >= 9600) return 'Windows 8.1 (build $build)';
    if (build >= 9200) return 'Windows 8 (build $build)';
    if (build >= 7600) return 'Windows 7 (build $build)';
    return 'Windows (build $build)';
  }

  /// `reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuild`
  ///
  /// Works on every supported Windows and is not localized.
  static int parseRegQuery(String text) {
    final m = RegExp(r'CurrentBuild\s+REG_SZ\s+(\d+)').firstMatch(text);
    if (m != null) return int.tryParse(m.group(1)!) ?? 0;
    // Older builds report CurrentBuildNumber instead.
    final n = RegExp(r'CurrentBuildNumber\s+REG_SZ\s+(\d+)').firstMatch(text);
    if (n != null) return int.tryParse(n.group(1)!) ?? 0;
    return 0;
  }

  /// `cmd /c ver` → `Microsoft Windows [Version 6.3.9600]`.
  static int parseVer(String text) {
    final m = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(text);
    if (m == null) return 0;
    return int.tryParse(m.group(3)!) ?? 0;
  }

  static Future<WindowsBuild> detect() async {
    const key = r'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion';
    try {
      final r = await Process.run('reg', ['query', key]);
      final b = parseRegQuery('${r.stdout}');
      if (b > 0) return WindowsBuild(b);
    } catch (_) {}
    try {
      final r = await Process.run('cmd', ['/c', 'ver']);
      final b = parseVer('${r.stdout}');
      if (b > 0) return WindowsBuild(b);
    } catch (_) {}
    return unknown;
  }
}

/// One row of `netsh interface ipv4 show interfaces`.
class NetInterface {
  const NetInterface({required this.index, required this.name, this.state = ''});

  /// `Idx` column — what `route add ... if <idx>` and `netsh ... interface=`
  /// need. Names are not stable ("Voidrau 2"), indexes are.
  final int index;
  final String name;
  final String state;

  @override
  String toString() => '#$index $name${state.isEmpty ? '' : ' ($state)'}';
}

/// One row of the IPv4 routing table as `route print` prints it:
///
/// ```
/// Active Routes:
/// Network Destination        Netmask          Gateway       Interface  Metric
///           0.0.0.0          0.0.0.0      192.168.1.1     192.168.1.5      25
///           0.0.0.0          0.0.0.0         On-link       198.18.0.1       5
/// ```
///
/// The Gateway column is the only one that can hold free text: Windows prints
/// the localized word “On-link” for a directly attached route — and a route
/// whose gateway is the interface's *own* address (the pattern every TUN VPN
/// uses for its default route) is stored and printed exactly that way. A
/// check that expects an IP in the Gateway column misses the route right
/// after `route add` reported success, which is how a working tunnel ended up
/// reported as “accepted but not in the table” (seen on Windows 8.1).
class RouteLine {
  const RouteLine({
    required this.destination,
    required this.mask,
    required this.gateway,
    required this.interfaceAddress,
    this.metric = 0,
  });

  final String destination;
  final String mask;

  /// Dotted IPv4 — or the localized on-link word (“On-link” in English,
  /// «روی پیوند» in Persian, …).
  final String gateway;

  /// The interface's own address — always a dotted IPv4.
  final String interfaceAddress;
  final int metric;

  bool get isOnLink => !ipPattern.hasMatch(gateway);

  static final ipPattern = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$');

  @override
  String toString() =>
      '$destination/$mask gw=$gateway if=$interfaceAddress m=$metric';
}

/// Parsing helpers for the `netsh` / `route` text output VoidrauVPN has to read on
/// Windows. Kept free of `Process` calls so they are unit-testable anywhere.
class Netsh {
  /// `Idx  Met  MTU  State  Name`. The header is localized, the columns are
  /// not, and the name comes last so it may contain spaces ("Voidrau 2", or
  /// "Loopback Pseudo-Interface 1"). States can contain spaces too ("hardware
  /// not present"), so the split is on the column padding, not on single
  /// spaces.
  static List<NetInterface> parseInterfaces(String text) {
    final rows = <NetInterface>[];
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final m = RegExp(r'^(\d+)\s+(\d+)\s+(\d+)\s+(.*)$').firstMatch(line);
      if (m == null) continue;
      final idx = int.tryParse(m.group(1)!);
      if (idx == null) continue;
      final rest = m.group(4)!.trim();
      final parts = rest.split(RegExp(r'\s{2,}'));
      String state;
      String name;
      if (parts.length >= 2) {
        state = parts.first.trim();
        name = parts.sublist(1).join('  ').trim();
      } else {
        // No padding left to split on: first token is the state, rest the name.
        final single = RegExp(r'^(\S+)\s+(.+)$').firstMatch(rest);
        if (single == null) continue;
        state = single.group(1)!;
        name = single.group(2)!.trim();
      }
      if (name.isEmpty) continue;
      rows.add(NetInterface(index: idx, name: name, state: state));
    }
    return rows;
  }

  /// The adapter WinTUN actually created.
  ///
  /// Windows appends " 2", " 3"… when an interface of the same name is still
  /// registered (a previous session that was hard-killed, or the pointless
  /// `admin=disable` the old code left behind). Assuming the name is exactly
  /// [wanted] made VoidrauVPN configure a dead adapter and then report a routing
  /// failure nobody could act on.
  static NetInterface? findAdapter(List<NetInterface> interfaces, String wanted) {
    for (final i in interfaces) {
      if (i.name.toLowerCase() == wanted.toLowerCase()) return i;
    }
    final numbered = RegExp('^${RegExp.escape(wanted)}\\s+\\d+\$',
        caseSensitive: false);
    for (final i in interfaces) {
      if (numbered.hasMatch(i.name)) return i;
    }
    return null;
  }

  /// Parses the IPv4 route rows of `route print` (full or filtered) into
  /// [RouteLine]s.
  ///
  /// Everything that is not a route row — the interface list, the `===`
  /// separators, the localized section headers, the IPv6 table (different
  /// column order) — is skipped structurally, so the parser works on every
  /// locale and on old builds alike. Columns are padded with at least two
  /// spaces; a localized on-link word may contain a single space, which must
  /// not split the column, so the split is on two-or-more spaces only.
  static List<RouteLine> parseRouteLines(String text) {
    final rows = <RouteLine>[];
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final tokens = raw.trim().split(RegExp(r'\s{2,}'));
      if (tokens.length < 4) continue;
      if (!RouteLine.ipPattern.hasMatch(tokens[0])) continue;
      if (!RouteLine.ipPattern.hasMatch(tokens[1])) continue;
      final metric = int.tryParse(tokens.last);
      if (metric == null) continue;
      final iface = tokens[tokens.length - 2];
      if (!RouteLine.ipPattern.hasMatch(iface)) continue;
      final gateway =
          tokens.sublist(2, tokens.length - 2).join(' ').trim();
      if (gateway.isEmpty) continue;
      rows.add(RouteLine(
        destination: tokens[0],
        mask: tokens[1],
        gateway: gateway,
        interfaceAddress: iface,
        metric: metric,
      ));
    }
    return rows;
  }

  /// True when `route print` shows a default route that goes through the
  /// tunnel — whether Windows stored it with the tunnel address as gateway
  /// or normalized it to an on-link route (its Gateway column then shows a
  /// localized word instead of an IP; see [RouteLine]).
  static bool hasDefaultRoute(String routePrint, String tunIp) {
    for (final row in parseRouteLines(routePrint)) {
      if (row.destination != '0.0.0.0' || row.mask != '0.0.0.0') continue;
      if (row.interfaceAddress == tunIp) return true;
      if (row.gateway == tunIp) return true;
    }
    return false;
  }

  /// The machine's real default gateway, read from `route print`.
  /// Ignores a tunnel gateway so a reconnect after a crash does not capture
  /// our own 198.18.x address as "the" upstream. On-link default routes carry
  /// no usable upstream and are skipped.
  static String? parseGateway(String routePrint, {String? ignore}) {
    for (final row in parseRouteLines(routePrint)) {
      if (row.destination != '0.0.0.0' || row.mask != '0.0.0.0') continue;
      if (!RouteLine.ipPattern.hasMatch(row.gateway)) continue;
      if (row.gateway == ignore) continue;
      if (row.gateway.startsWith('198.18.')) continue;
      return row.gateway;
    }
    return null;
  }
}

/// Process elevation ("is this instance really running as Administrator?").
class Elevation {
  /// `whoami /groups` prints the integrity-level SID: `S-1-16-12288` (High)
  /// for an elevated process, `S-1-16-16384` (System) for a service. SIDs are
  /// the same on every language, and unlike `net session` this does not
  /// depend on the LanmanServer ("Server") service being started — on PCs
  /// where that service is disabled the old check reported *not elevated*
  /// forever, even from a real Administrator prompt.
  static bool parseWhoamiGroups(String text) {
    final t = text.toLowerCase();
    return t.contains('s-1-16-12288') || t.contains('s-1-16-16384');
  }

  /// A `whoami` that runs and shows Medium integrity is authoritative: the
  /// process is *not* elevated, no second opinion needed.
  static Future<bool> check() async {
    try {
      final r = await Process.run('whoami', ['/groups']);
      if (r.exitCode == 0) return parseWhoamiGroups('${r.stdout}');
    } catch (_) {}
    try {
      final r = await Process.run('net', ['session']);
      return r.exitCode == 0;
    } catch (_) {}
    return false;
  }
}

/// Which bridge to try, in which order.
class TunPlan {
  /// [available] is what is actually present next to `voidrauvpn.exe`.
  ///
  /// On Windows 10+ the current Go bridge goes first (the routing code was
  /// written against it); below Windows 10 it goes **last**, because a
  /// Go ≥ 1.21 binary cannot even start there and burning 20 s on it is how
  /// the user ends up staring at "adapter never appeared".
  static List<TunBackend> order({
    required WindowsBuild build,
    required Iterable<TunBackend> available,
  }) {
    final list = available.toList();
    if (list.length < 2) return list;
    list.sort((a, b) => _rank(a, build).compareTo(_rank(b, build)));
    return list;
  }

  static int _rank(TunBackend backend, WindowsBuild build) {
    if (!build.isKnown) {
      // Unknown version: try the modern bridge, then the legacy one, then hev.
      return switch (backend) {
        TunBackend.tun2socks => 0,
        TunBackend.tun2socksLegacy => 1,
        TunBackend.hev => 2,
      };
    }
    if (build.supportsGoRuntime) {
      return switch (backend) {
        TunBackend.tun2socks => 0,
        TunBackend.hev => 1,
        TunBackend.tun2socksLegacy => 2,
      };
    }
    // Windows 8.1/8/7: the Go 1.20 build first, then the C bridge, and the
    // modern Go build only as a last resort.
    return switch (backend) {
      TunBackend.tun2socksLegacy => 0,
      TunBackend.hev => 1,
      TunBackend.tun2socks => 2,
    };
  }
}

/// `hev-socks5-tunnel` is configured by a YAML file, not by flags.
class HevConfig {
  /// Deliberately **no** `tunnel.ipv4`: hev would stamp a /32 on the adapter
  /// and then fight with the `netsh ... set address` (/30) that the routing
  /// code needs. VoidrauVPN owns address, DNS and routes for every bridge, so the
  /// two bridges stay interchangeable.
  static String yaml({
    required String adapterName,
    required int mtu,
    required int socksPort,
    bool ipv6 = false,
    String logLevel = 'info',

    /// Speed profile: the bridge moves the packets, so the buffers it splices
    /// through decide how much of the line the rest of the stack can use. The
    /// core's own tier (`AETHER_PERF_PROFILE=high`) cannot help with traffic the
    /// bridge has not handed over yet, which is why the same numbers are applied
    /// here.
    bool fast = false,
  }) {
    final tcpBuffer = fast ? 131072 : 65536;
    // The TCP splice buffer lives on the worker's own stack (upstream's rule:
    // size + 20480), and the old fixed 32768 with a 65536 buffer was an
    // overflow waiting to happen.
    final stack = 20480 + tcpBuffer;
    final udpRecv = fast ? 1048576 : 524288;
    final b = StringBuffer()
      ..writeln('misc:')
      ..writeln('  task-stack-size: $stack')
      ..writeln('  tcp-buffer-size: $tcpBuffer')
      ..writeln('  udp-recv-buffer-size: $udpRecv')
      ..writeln('  max-session-count: 0')
      ..writeln('  connect-timeout: 15000')
      ..writeln('  limit-nofile: 65535')
      ..writeln('  log-level: $logLevel')
      ..writeln('tunnel:')
      ..writeln("  name: '$adapterName'")
      ..writeln('  mtu: $mtu')
      ..writeln("  icmp: 'reply'");
    if (ipv6) b.writeln("  ipv6: 'fc00::1'");
    b
      ..writeln('socks5:')
      ..writeln("  address: '127.0.0.1'")
      ..writeln('  port: $socksPort')
      ..writeln("  udp: 'udp'");
    return b.toString();
  }
}

/// Why a bridge could not bring the device up — the text the user sees, so it
/// has to say something they can act on.
class TunFailure {
  const TunFailure(this.backend, this.reason);

  final TunBackend backend;
  final String reason;

  @override
  String toString() => '${backend.fileName}: $reason';
}

/// Exit statuses that mean "this binary cannot run here" rather than "the
/// network is down". Turned into plain language in the failure message.
class ExitCodes {
  /// `STATUS_ILLEGAL_INSTRUCTION` — what a GOAMD64=v3 build does on a CPU
  /// without AVX2 (most pre-2013 hardware, i.e. most Windows 8.1 PCs).
  static const illegalInstruction = 0xC000001D;

  /// `STATUS_DLL_NOT_FOUND` / `STATUS_ENTRYPOINT_NOT_FOUND` — a runtime DLL
  /// (msys-2.0.dll for hev) or an API the OS does not have.
  static const dllNotFound = 0xC0000135;
  static const entrypointNotFound = 0xC0000139;

  /// Dart reports a Windows exit status as a signed 32-bit int.
  static int normalize(int code) => code.toUnsigned(32);

  static String? describe(int code) {
    switch (normalize(code)) {
      case illegalInstruction:
        return 'illegal instruction — this build needs a newer CPU (AVX2)';
      case dllNotFound:
        return 'a required DLL is missing next to the executable';
      case entrypointNotFound:
        return 'an API this build needs does not exist on this Windows';
      default:
        return null;
    }
  }
}
