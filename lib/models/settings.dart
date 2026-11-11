enum ConnectionMode { vpn, proxy }

enum Protocol { smart, masque, wg, gool, mim }

enum ScanMode { turbo, balanced, thorough, stealth, ironclad }

/// Which exit country a finished tunnel must have before the app accepts it.
///
/// The tunnel core picks its own gateway, so the choice happens on the client:
/// after the core reports `connected`, the exit IP is looked up and the tunnel
/// is torn down and re-dialled when the country does not match. Core 2.3.0 can
/// also be told the same rule up front (`AETHER_EXIT_LOC`), which is what
/// [VpnSettings.coreExitLoc] switches on — the core then refuses to open the
/// proxy on a tunnel that lands in the wrong country, so far fewer re-dials are
/// needed here.
enum ExitFilter {
  /// Whatever exit the core finds is accepted.
  off,

  /// Any country except [VpnSettings.exitBlocked] (Iran by default).
  nonIran,

  /// [VpnSettings.exitPreferred] first (Germany by default), any other
  /// non-blocked country accepted as a second choice.
  preferred,
}

enum IpVersion { v4, v6, dual }

enum MasqueTransport { h3, h2 }

enum ThemeChoice { system, dark, light }

enum LanguageChoice { system, en, fa }

enum SplitMode { off, include, exclude }

enum OrbStyle { classic, mercury }

/// How much of the machine's resources the tunnel core may use.
///
/// The core picks a tier on its own from the CPU count and the installed RAM
/// (`sysprofile`): a 4-core phone gets the *medium* tier — a 1 MiB TCP window,
/// which is roughly 9 MB/s on a 110 ms round trip. On a good WARP gateway that
/// is the ceiling the user feels as "the VPN is slow", so the profile can be
/// raised by hand.
enum PerfProfile {
  /// Fewest buffers: for very old phones, or when battery matters more.
  eco,

  /// Let the core detect the machine (default).
  auto,

  /// The core's own high tier, forced on: a 2 MiB TCP window, unlimited scan
  /// concurrency, big UDP socket buffers and the wide HTTP/2 windows.
  turbo,

  /// Turbo with double the netstack buffers. More memory per connection, so it
  /// is the option to pick when a fast line still feels capped.
  extreme,
}

/// A second hop that carries the tunnel itself.
///
/// Aether 2.3.0 ships Psiphon and Tor inside the core. In a country where WARP
/// endpoints answer but the handshake is being probed, "the tunnel through
/// Psiphon"/"through Tor" is the difference between a working connection and a
/// dead one — and it is a checkbox here instead of a second app.
///
/// This is only the *second* hop: it always rides on top of a protocol
/// (WARP underneath). Plain Psiphon/Tor with no WARP at all is the separate
/// [StandaloneMode]. Whether the 2.4.0 core still ships them is NOT verified
/// in this repository — the only version-scoped statement here is the 2.3.0
/// one above, so the standalone-hop check in core_args.dart treats the
/// standalone modes as verified on 2.3.0 only, and the UI must say so instead
/// of claiming they work on 2.4.0.
enum SecondHop {
  /// No second hop.
  off,

  /// Psiphon carries the tunnel (Psiphon inside the tunnel path, WARP exit).
  psiphon,

  /// The tunnel is dialled *through* Psiphon, so the network never sees WARP.
  psiphonReverse,

  /// Tor carries the tunnel.
  tor,

  /// The tunnel is dialled through Tor.
  torReverse,
}

/// A top-level mode with no WARP underneath: plain Psiphon or plain Tor on
/// the same proxy port. Independent of [SecondHop] — the two are separate
/// selectors in the UI writing separate fields — and when a standalone mode
/// is chosen it wins over any second hop (see CoreLaunch: a standalone
/// connection has nothing underneath to carry a second hop through).
enum StandaloneMode {
  /// Normal: the chosen protocol, plus whatever [SecondHop] is set.
  standard,

  /// Plain Psiphon on the same proxy port — no WARP at all.
  psiphonOnly,

  /// Plain Tor on the same proxy port.
  torOnly,
}

/// Second engine beside Aether: Xray-core (Android only for now).
///
/// `off` means "Aether as today" — every Xray mode is opt-in, separately
/// disableable, and exactly one tunnel runs at a time. MASQUE already lives
/// in Aether, so Xray does not re-implement it here.
enum XrayMode {
  /// Aether (default, unchanged behaviour).
  off,

  /// VLESS over WebSocket + TLS through the user's own Cloudflare Worker.
  worker,

  /// WireGuard to Cloudflare WARP (own registered account, no Worker).
  warp,

  /// Direct connections with TLS fragmentation + UDP noise only.
  /// No MITM, no domain fronting, no CA install — deliberately not implemented.
  serverless,
}

/// Variant inside an Xray mode. Worker: normal / fragment. WARP: normal /
/// obfuscated (UDP noise over the WireGuard transport).
enum XrayVariant { normal, fragment, obfuscated }

/// One user-entered chain proxy: a share link the user pasted, nothing
/// bundled with the app. The link itself may carry credentials, so it is
/// stored with the settings the user entered — never shipped, never logged.
class ChainProxy {
  const ChainProxy({required this.id, required this.name, required this.link});

  final String id;
  final String name;

  /// The share link as entered (vless://, vmess://, trojan://, ss://,
  /// socks://, http://, wireguard://, hysteria2://) or a WireGuard config
  /// converted to a wireguard:// link.
  final String link;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'link': link};

  /// True when the link is a UDP-only proxy (WireGuard / Hysteria2): it can
  /// only ride on WARP, never through the TCP-only Worker relay.
  static bool isUdpLink(String link) {
    final scheme = link.trim().split('://').first.toLowerCase();
    return scheme == 'wireguard' ||
        scheme == 'wg' ||
        scheme == 'hysteria2' ||
        scheme == 'hy2';
  }

  static ChainProxy? parse(Object? v) {
    if (v is! Map) return null;
    final id = '${v['id'] ?? ''}';
    final link = '${v['link'] ?? ''}';
    if (id.isEmpty || link.isEmpty) return null;
    return ChainProxy(id: id, name: '${v['name'] ?? id}', link: link);
  }
}

class VpnSettings {
  VpnSettings({
    this.mode = ConnectionMode.vpn,
    this.protocol = Protocol.wg,
    this.scan = ScanMode.turbo,
    this.ipVersion = IpVersion.dual,
    this.transport = MasqueTransport.h3,
    this.obfuscation = 'auto',
    this.endpoint = '',
    this.quickReconnect = true,
    this.fragment = false,
    this.autoConnect = false,
    this.killSwitch = true,
    this.privateDns = true,
    this.lanShare = false,
    this.bypassLan = true,
    this.ipv6Tunnel = false,
    this.splitMode = SplitMode.off,
    this.splitApps = const [],
    this.routeDirect = const [],
    this.routeBlock = const [],
    this.theme = ThemeChoice.dark,
    this.language = LanguageChoice.system,
    this.autoUpdate = true,
    this.autoDownload = false,
    this.notifications = true,
    this.watchdog = true,
    this.orbStyle = OrbStyle.mercury,
    // The out-of-the-box rule is "any IP but Iran" (README, exit_filter_test):
    // an unknown stored name must never silently disable the filter either.
    this.exitFilter = ExitFilter.off,
    this.exitRulePaused = false,
    this.exitPreferred = const ['DE'],
    this.exitBlocked = const ['IR'],
    this.exitAskAfter = 180,
    this.exitMaxTries = 8,
    this.coreExitLoc = true,
    this.perf = PerfProfile.auto,
    this.perfRxKb = 0,
    this.perfTxKb = 0,
    this.quicV2 = true,
    this.ech = false,
    this.secondHop = SecondHop.off,
    this.standaloneMode = StandaloneMode.standard,
    this.psiphonRegion = '',
    this.psiphonCdn = false,
    this.hopHttp = false,
    this.torCountry = '',
    this.httpProxy = false,
    this.socksPort = 1819,
    this.keepalive = 5,
    this.tunMtu = 1500,
    this.coreMtu = 0,
    this.stallTimeout = 90,
    this.tcpConnectSecs = 15,
    this.tcpKeepaliveSecs = 60,
    this.halfCloseSecs = 30,
    this.logLevel = 'info',
    // ── Xray engine (Android only; off = Aether as today) ───────────────
    this.xrayMode = XrayMode.off,
    this.xrayVariant = XrayVariant.normal,
    this.workerDomain = '',
    this.workerScriptName = 'voidrau',
    this.workerAccountId = '',
    this.workerDeployed = false,
    this.workerFallback = '',
    this.workerProxyIps = const [],
    this.warpRegistered = false,
    this.warpEndpoints = const [],
    this.serverlessFragment = true,
    this.serverlessNoise = true,
    this.xrayChainProxies = const [],
    this.xrayChainExitId = '',
  });

  ConnectionMode mode;
  Protocol protocol;
  ScanMode scan;
  IpVersion ipVersion;
  MasqueTransport transport;
  String obfuscation;
  String endpoint;
  bool quickReconnect;
  bool fragment;
  bool autoConnect;
  bool killSwitch;
  bool privateDns;
  bool lanShare;
  bool bypassLan;
  bool ipv6Tunnel;
  SplitMode splitMode;

  /// Package names (Android) or executable paths the split rule applies to.
  List<String> splitApps;

  /// Destinations the core must dial *outside* the tunnel, in its own rule
  /// syntax (`example.com`, `full:example.com`, `keyword:ads`, `regexp:^ad[0-9]`,
  /// `10.0.0.0/8`, `port:25`, `private`).
  List<String> routeDirect;

  /// Destinations the core must refuse outright.
  List<String> routeBlock;

  ThemeChoice theme;
  LanguageChoice language;
  bool autoUpdate;
  bool autoDownload;
  bool notifications;
  bool watchdog;
  OrbStyle orbStyle;

  /// Exit-country rule applied after the tunnel is up.
  ExitFilter exitFilter;

  /// True while the one-tap "connect with the Iran IP" answer is in force.
  ///
  /// The rule itself is kept — [exitFilter], [exitPreferred] and [exitBlocked]
  /// are untouched — but it is not enforced and not handed to the core, so the
  /// user gets the exit that is actually reachable on this line. Pressing
  /// "search again" clears this flag, and with it the rule is back exactly as
  /// it was: choosing the local exit once must never cost the user the rule.
  bool exitRulePaused;

  /// ISO-3166 alpha-2 codes wanted first by [ExitFilter.preferred].
  List<String> exitPreferred;

  /// ISO-3166 alpha-2 codes that are never accepted while a filter runs.
  List<String> exitBlocked;

  /// Seconds of exit searching before the app asks what to do next.
  int exitAskAfter;

  /// Re-dials tolerated while searching for a matching exit.
  int exitMaxTries;

  /// Hand the exit rule to the core as well (`AETHER_EXIT_LOC`), so a tunnel
  /// that lands in a blocked country never reaches the SOCKS listener and the
  /// app does not have to tear it down and dial again.
  bool coreExitLoc;

  /// How much of the machine the core may use; see [PerfProfile].
  PerfProfile perf;

  /// Explicit netstack TCP buffers in KiB (`AETHER_NETSTACK_TCP_RX/TX`).
  /// 0 means "whatever [perf] implies". These are the window each connection
  /// advertises, so they are the ceiling on a single stream's speed.
  int perfRxKb;
  int perfTxKb;

  /// QUIC v2 opener (core 2.3.0): one v2-shaped packet before the v1 handshake
  /// so filters that only know v1 let the flow through.
  bool quicV2;

  /// Fetch an Encrypted Client Hello config and hide the SNI (`AETHER_ECH`).
  bool ech;

  /// Second hop carrying the tunnel (Psiphon / Tor), see [SecondHop].
  SecondHop secondHop;

  /// Top-level standalone mode (plain Psiphon/Tor, no WARP), see
  /// [StandaloneMode]. Independent of [secondHop]: the two are separate
  /// selectors writing separate fields.
  StandaloneMode standaloneMode;

  /// True when the connection is a standalone Psiphon-only or Tor-only mode
  /// (plain Psiphon/Tor on the proxy port, no WARP) rather than a protocol
  /// with a second hop. See [SecondHop] for the 2.4.0 verification caveat.
  bool get isStandaloneHop => standaloneMode != StandaloneMode.standard;

  /// True when a second hop carries the tunnel.
  bool get hasSecondHop => secondHop != SecondHop.off;

  /// Country the Psiphon exit should be in, e.g. `DE`. Empty = any.
  String psiphonRegion;

  /// Limit Psiphon to fronted meek through a CDN.
  bool psiphonCdn;

  /// Also serve the second hop as an HTTP CONNECT proxy, for apps that cannot
  /// speak SOCKS5 (shared by the Psiphon and Tor hops).
  bool hopHttp;

  /// Country handed to bridgedb when Tor needs bridges, e.g. `ir`.
  String torCountry;

  /// Extra HTTP CONNECT listener next to the SOCKS5 one, for apps that only
  /// speak HTTP proxies.
  bool httpProxy;

  int socksPort;
  int keepalive;

  /// MTU of the local TUN device — the size apps may segment at before the
  /// bridge sees the packet. This side is terminated inside the bridge, so it
  /// is independent of the tunnel's own MTU and a larger value only means fewer
  /// packets to move (8500 is what hev-socks5-tunnel itself defaults to).
  int tunMtu;

  /// Inner MTU handed to the core (`AETHER_MASQUE_MTU`, 576–1500).
  /// 0 = automatic: the core picks 1280 for QUIC (a datagram has to fit) and
  /// 1500 on the TCP carrier, which is what a hand-picked value used to break.
  int coreMtu;

  int stallTimeout;

  /// Connection timeouts inside the tunnel (`AETHER_TCP_*`). Lower means a
  /// dead destination fails over faster; higher means a slow one still gets in.
  int tcpConnectSecs;
  int tcpKeepaliveSecs;
  int halfCloseSecs;

  String logLevel;

  // ── Xray engine (Android only) ─────────────────────────────────────────
  //
  // Secrets live OUTSIDE this object: the Cloudflare API token, the Worker
  // VLESS UUID and the WARP private key are kept in secure storage
  // (see SecureStore) and never in SharedPreferences, logs or git.
  // What is stored here is only what the UI needs to show: domains, ids,
  // flags and the user's own chain-proxy links.

  /// Which engine a connect takes. [XrayMode.off] = Aether, unchanged.
  XrayMode xrayMode;

  /// Variant of the chosen Xray mode (fragment / obfuscated).
  XrayVariant xrayVariant;

  /// The user's own deployed Worker host, e.g. `voidrau-abc.workers.dev`
  /// or a custom domain attached to it. Empty = not deployed yet.
  String workerDomain;

  /// Worker script name on the user's Cloudflare account.
  String workerScriptName;

  /// Cloudflare account id the Worker was deployed to (not a secret).
  String workerAccountId;

  /// True once a deploy has succeeded (the wizard sets this).
  bool workerDeployed;

  /// Optional fallback site the Worker serves for plain HTTP requests.
  String workerFallback;

  /// Optional proxy IPs the Worker retries through for Cloudflare-hosted
  /// targets. Entered by the user; empty is valid.
  List<String> workerProxyIps;

  /// True once a WARP account has been registered on this device.
  bool warpRegistered;

  /// WARP endpoints offered at registration (host:port list).
  List<String> warpEndpoints;

  /// Serverless: split the TLS ClientHello into fragments.
  bool serverlessFragment;

  /// Serverless: send UDP noise packets (QUIC-shaped).
  bool serverlessNoise;

  /// Xray chain proxies the user entered (share links), in list order.
  /// Renamed from the old `chainProxies`: these belong to Xray only and
  /// have nothing to do with the Aether second hop ([SecondHop]).
  List<ChainProxy> xrayChainProxies;

  /// Id of the Xray chain proxy used as the exit, or '' for "first usable".
  String xrayChainExitId;

  /// The Xray chain proxy chosen as the exit for [mode], or the first one the
  /// mode can carry. UDP-only proxies (WireGuard / Hysteria2) can only ride
  /// on WARP — the Worker relays TCP only. Serverless is direct by
  /// definition and never takes a chain exit, so it always returns null.
  ChainProxy? xrayChainExitFor(XrayMode mode) {
    if (mode == XrayMode.serverless) return null;
    final usable = xrayChainProxies
        .where((c) => !ChainProxy.isUdpLink(c.link) || mode == XrayMode.warp)
        .toList();
    if (usable.isEmpty) return null;
    for (final c in usable) {
      if (c.id == xrayChainExitId) return c;
    }
    return usable.first;
  }

  /// What the core is actually given for `AETHER_PERF_PROFILE`, or null when
  /// the core should detect the machine itself.
  String? get perfToken => switch (perf) {
        PerfProfile.eco => 'low',
        PerfProfile.auto => null,
        PerfProfile.turbo || PerfProfile.extreme => 'high',
      };

  /// Netstack TCP receive window in bytes. Clamped to what the core accepts
  /// (16 KiB – 64 MiB); [PerfProfile] supplies the default.
  int get netstackRxBytes {
    final kb = perfRxKb > 0
        ? perfRxKb
        : switch (perf) {
            PerfProfile.eco => 256,
            PerfProfile.auto => 0,
            PerfProfile.turbo => 2048,
            PerfProfile.extreme => 4096,
          };
    if (kb <= 0) return 0;
    return _clampBuf(kb * 1024);
  }

  /// Netstack TCP send buffer in bytes, same rules as [netstackRxBytes].
  int get netstackTxBytes {
    final kb = perfTxKb > 0
        ? perfTxKb
        : switch (perf) {
            PerfProfile.eco => 128,
            PerfProfile.auto => 0,
            PerfProfile.turbo => 512,
            PerfProfile.extreme => 1024,
          };
    if (kb <= 0) return 0;
    return _clampBuf(kb * 1024);
  }

  static int _clampBuf(int bytes) {
    const lo = 16 * 1024;
    const hi = 64 * 1024 * 1024;
    if (bytes < lo) return lo;
    if (bytes > hi) return hi;
    return bytes;
  }

  /// MTU the TUN device is created with. 1280 is the floor IPv6 requires and
  /// 9000 is the largest jumbo frame worth offering; the default of 1500 keeps
  /// the bridge from splitting every normal packet.
  int get deviceMtu {
    final v = tunMtu;
    if (v < 1280) return 1280;
    if (v > 9000) return 9000;
    return v;
  }

  /// `AETHER_MASQUE_MTU` only when the user overrode it: the core's own pick is
  /// protocol aware (1280 for QUIC, 1500 for the TCP carrier), while the old
  /// fixed 1400 was both too big for QUIC and too small for HTTP/2.
  int get coreMtuOverride {
    if (coreMtu <= 0) return 0;
    if (coreMtu < 576) return 576;
    if (coreMtu > 1500) return 1500;
    return coreMtu;
  }

  /// The tunnel core always listens on loopback. LAN sharing is an authenticated
  /// relay on Android and `--bind 0.0.0.0` on Windows.
  String get socksBind => '127.0.0.1:$socksPort';

  /// The HTTP CONNECT listener sits one port above SOCKS5, and only exists when
  /// [httpProxy] is on.
  String get httpBind => '127.0.0.1:$httpProxyPort';

  int get httpProxyPort {
    final p = socksPort + 1;
    return (p > 1024 && p < 65535) ? p : 1820;
  }

  /// Port the second hop's own proxy listens on: above both of ours, so the
  /// SOCKS5 listener, the extra HTTP listener and the hop never collide.
  int get hopPort {
    final p = socksPort + 2;
    return (p > 1024 && p < 65535) ? p : 1821;
  }

  /// Port the second hop's HTTP listener uses when [hopHttp] is on.
  int get hopHttpPort {
    final p = socksPort + 3;
    return (p > 1024 && p < 65535) ? p : 1822;
  }

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'protocol': protocol.name,
        'scan': scan.name,
        'ipVersion': ipVersion.name,
        'transport': transport.name,
        'obfuscation': obfuscation,
        'endpoint': endpoint,
        'quickReconnect': quickReconnect,
        'fragment': fragment,
        'autoConnect': autoConnect,
        'killSwitch': killSwitch,
        'privateDns': privateDns,
        'lanShare': lanShare,
        'bypassLan': bypassLan,
        'ipv6Tunnel': ipv6Tunnel,
        'splitMode': splitMode.name,
        'splitApps': splitApps,
        'routeDirect': routeDirect,
        'routeBlock': routeBlock,
        'theme': theme.name,
        'language': language.name,
        'autoUpdate': autoUpdate,
        'autoDownload': autoDownload,
        'notifications': notifications,
        'watchdog': watchdog,
        'orbStyle': orbStyle.name,
        'exitFilter': exitFilter.name,
        'exitRulePaused': exitRulePaused,
        'exitPreferred': exitPreferred,
        'exitBlocked': exitBlocked,
        'exitAskAfter': exitAskAfter,
        'exitMaxTries': exitMaxTries,
        'coreExitLoc': coreExitLoc,
        'perf': perf.name,
        'perfRxKb': perfRxKb,
        'perfTxKb': perfTxKb,
        'quicV2': quicV2,
        'ech': ech,
        'secondHop': secondHop.name,
        'standaloneMode': standaloneMode.name,
        'psiphonRegion': psiphonRegion,
        'psiphonCdn': psiphonCdn,
        'hopHttp': hopHttp,
        'torCountry': torCountry,
        'httpProxy': httpProxy,
        'socksPort': socksPort,
        'keepalive': keepalive,
        'tunMtu': tunMtu,
        'coreMtu': coreMtu,
        'stallTimeout': stallTimeout,
        'tcpConnectSecs': tcpConnectSecs,
        'tcpKeepaliveSecs': tcpKeepaliveSecs,
        'halfCloseSecs': halfCloseSecs,
        'logLevel': logLevel,
        'xrayMode': xrayMode.name,
        'xrayVariant': xrayVariant.name,
        'workerDomain': workerDomain,
        'workerScriptName': workerScriptName,
        'workerAccountId': workerAccountId,
        'workerDeployed': workerDeployed,
        'workerFallback': workerFallback,
        'workerProxyIps': workerProxyIps,
        'warpRegistered': warpRegistered,
        'warpEndpoints': warpEndpoints,
        'serverlessFragment': serverlessFragment,
        'serverlessNoise': serverlessNoise,
        'xrayChainProxies': xrayChainProxies.map((c) => c.toJson()).toList(),
        'xrayChainExitId': xrayChainExitId,
      };

  /// Normalises a stored country list: upper-case ISO-3166 alpha-2 codes only,
  /// duplicates dropped, and an unusable value falls back to [fallback] so a
  /// hand-edited preference can never disable the filter by accident.
  static List<String> codes(Object? raw, List<String> fallback) {
    if (raw is! List) return List<String>.from(fallback);
    final out = <String>[];
    for (final e in raw) {
      final c = '$e'.trim().toUpperCase();
      if (c.length == 2 && !out.contains(c)) out.add(c);
    }
    return out.isEmpty ? List<String>.from(fallback) : out;
  }

  /// A stored string list (rules, package names): trimmed, de-duplicated and
  /// with the empties dropped. Never falls back — an empty list is a valid
  /// answer here, unlike a country list.
  static List<String> lines(Object? raw) {
    if (raw is! List) return <String>[];
    final out = <String>[];
    for (final e in raw) {
      final v = '$e'.trim();
      if (v.isNotEmpty && !out.contains(v)) out.add(v);
    }
    return out;
  }

  static int _int(Object? v, int fallback) {
    if (v is int) return v;
    final parsed = int.tryParse('$v');
    return parsed ?? fallback;
  }

  factory VpnSettings.fromJson(Map<String, dynamic> json) {
    T parse<T extends Enum>(List<T> values, String key, T fallback) {
      final name = json[key]?.toString();
      return values.firstWhere((e) => e.name == name, orElse: () => fallback);
    }

    int num(String key, int fallback) => _int(json[key], fallback);

    // MIGRATION (old single `chain` value): builds before the split stored
    // one `chain` name covering both concepts. Map it onto the two new
    // fields so an existing user's saved mode survives the upgrade:
    // psiphon/tor (+reverse) -> second hop, psiphonOnly/torOnly ->
    // standalone mode, off -> both off/standard. New keys, when present,
    // always win over the legacy value.
    var legacyHop = SecondHop.off;
    var legacyStandalone = StandaloneMode.standard;
    final legacyChain = json['chain']?.toString();
    if (legacyChain == 'psiphon') {
      legacyHop = SecondHop.psiphon;
    } else if (legacyChain == 'psiphonReverse') {
      legacyHop = SecondHop.psiphonReverse;
    } else if (legacyChain == 'tor') {
      legacyHop = SecondHop.tor;
    } else if (legacyChain == 'torReverse') {
      legacyHop = SecondHop.torReverse;
    } else if (legacyChain == 'psiphonOnly') {
      legacyStandalone = StandaloneMode.psiphonOnly;
    } else if (legacyChain == 'torOnly') {
      legacyStandalone = StandaloneMode.torOnly;
    }
    final secondHop = json.containsKey('secondHop')
        ? parse(SecondHop.values, 'secondHop', SecondHop.off)
        : legacyHop;
    final standaloneMode = json.containsKey('standaloneMode')
        ? parse(
            StandaloneMode.values, 'standaloneMode', StandaloneMode.standard)
        : legacyStandalone;
    // MIGRATION (old Xray proxy keys): `chainProxies` / `chainExitId` were
    // renamed to `xrayChainProxies` / `xrayChainExitId`; read the old keys
    // when the new ones are absent so saved proxies survive.
    final xrayChainProxiesJson =
        json['xrayChainProxies'] ?? json['chainProxies'];
    final xrayChainExitIdJson = json['xrayChainExitId'] ?? json['chainExitId'];

    return VpnSettings(
      mode: parse(ConnectionMode.values, 'mode', ConnectionMode.vpn),
      protocol: parse(Protocol.values, 'protocol', Protocol.smart),
      scan: parse(ScanMode.values, 'scan', ScanMode.turbo),
      ipVersion: parse(IpVersion.values, 'ipVersion', IpVersion.dual),
      transport: parse(MasqueTransport.values, 'transport', MasqueTransport.h3),
      obfuscation: json['obfuscation']?.toString() ?? 'auto',
      endpoint: json['endpoint']?.toString() ?? '',
      quickReconnect: json['quickReconnect'] != false,
      fragment: json['fragment'] == true,
      autoConnect: json['autoConnect'] == true,
      killSwitch: json['killSwitch'] != false,
      privateDns: json['privateDns'] != false,
      lanShare: json['lanShare'] == true,
      bypassLan: json['bypassLan'] != false,
      ipv6Tunnel: json['ipv6Tunnel'] == true,
      splitMode: parse(SplitMode.values, 'splitMode', SplitMode.off),
      splitApps: lines(json['splitApps']),
      routeDirect: lines(json['routeDirect']),
      routeBlock: lines(json['routeBlock']),
      theme: parse(ThemeChoice.values, 'theme', ThemeChoice.dark),
      language: parse(LanguageChoice.values, 'language', LanguageChoice.system),
      autoUpdate: json['autoUpdate'] != false,
      autoDownload: json['autoDownload'] == true,
      notifications: json['notifications'] != false,
      watchdog: json['watchdog'] != false,
      orbStyle: parse(OrbStyle.values, 'orbStyle', OrbStyle.mercury),
      exitFilter: parse(ExitFilter.values, 'exitFilter', ExitFilter.off),
      exitRulePaused: json['exitRulePaused'] == true,
      exitPreferred: codes(json['exitPreferred'], const ['DE']),
      exitBlocked: codes(json['exitBlocked'], const ['IR']),
      exitAskAfter: num('exitAskAfter', 180),
      exitMaxTries: num('exitMaxTries', 8),
      coreExitLoc: json['coreExitLoc'] != false,
      perf: parse(PerfProfile.values, 'perf', PerfProfile.auto),
      perfRxKb: num('perfRxKb', 0),
      perfTxKb: num('perfTxKb', 0),
      quicV2: json['quicV2'] != false,
      ech: json['ech'] == true,
      secondHop: secondHop,
      standaloneMode: standaloneMode,
      psiphonRegion: json['psiphonRegion']?.toString() ?? '',
      psiphonCdn: json['psiphonCdn'] == true,
      // `psiphonHttp` is what an older build stored for the same switch.
      hopHttp: json['hopHttp'] == true || json['psiphonHttp'] == true,
      torCountry: json['torCountry']?.toString() ?? '',
      httpProxy: json['httpProxy'] == true,
      socksPort: num('socksPort', 1819),
      keepalive: num('keepalive', 5),
      // A stored device MTU from an older build (1400, or a per-protocol cap)
      // is kept: only a missing value takes the new default.
      tunMtu: num('tunMtu', 1500),
      coreMtu: num('coreMtu', 0),
      stallTimeout: num('stallTimeout', 90),
      tcpConnectSecs: num('tcpConnectSecs', 15),
      tcpKeepaliveSecs: num('tcpKeepaliveSecs', 60),
      halfCloseSecs: num('halfCloseSecs', 30),
      logLevel: json['logLevel']?.toString() ?? 'info',
      xrayMode: parse(XrayMode.values, 'xrayMode', XrayMode.off),
      xrayVariant: parse(XrayVariant.values, 'xrayVariant', XrayVariant.normal),
      workerDomain: json['workerDomain']?.toString() ?? '',
      workerScriptName: json['workerScriptName']?.toString() ?? 'voidrau',
      workerAccountId: json['workerAccountId']?.toString() ?? '',
      workerDeployed: json['workerDeployed'] == true,
      workerFallback: json['workerFallback']?.toString() ?? '',
      workerProxyIps: lines(json['workerProxyIps']),
      warpRegistered: json['warpRegistered'] == true,
      warpEndpoints: lines(json['warpEndpoints']),
      serverlessFragment: json['serverlessFragment'] != false,
      serverlessNoise: json['serverlessNoise'] != false,
      xrayChainProxies: (xrayChainProxiesJson is List
          ? xrayChainProxiesJson
              .map(ChainProxy.parse)
              .whereType<ChainProxy>()
              .toList()
          : const <ChainProxy>[]),
      xrayChainExitId: xrayChainExitIdJson?.toString() ?? '',
    );
  }

  VpnSettings copyWithProtocol(Protocol p) {
    final copy = VpnSettings.fromJson(toJson());
    copy.protocol = p;
    return copy;
  }
}
