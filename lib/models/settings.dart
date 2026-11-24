import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/proxy_uri.dart';

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
/// Aether 2.3.0 and 2.4.0 both ship Psiphon and Tor inside the core, with
/// their helper binaries (`pt/psiphon-tunnel-core`, `pt/lyrebird`) staged
/// beside it by `scripts/fetch_cores.sh` — verified from the 2.4.0 release
/// notes, the tarball contents, the binary's own strings and a live
/// `aether --help` run (see `CoreLaunch.standaloneHopVerified`). In a
/// country where WARP endpoints answer but the handshake is being probed,
/// "the tunnel through Psiphon"/"through Tor" is the difference between a
/// working connection and a dead one — and it is a checkbox here instead
/// of a second app.
///
/// This is only the *second* hop: it always rides on top of a protocol
/// (WARP underneath). Plain Psiphon/Tor with no WARP at all is the separate
/// [StandaloneMode]. A reverse hop only speaks TCP, so the core runs it over
/// MASQUE on HTTP/2 and refuses WireGuard — [CoreLaunch.smartVariant]
/// rewrites that combination instead of sending it.
enum SecondHop {
  /// No second hop.
  off,

  /// Psiphon carries the device traffic: the hop listens on its own port
  /// ([hopPort]) and dials out through the tunnel, so the final exit is
  /// Psiphon's — not WARP's. (An older comment said "WARP exit" here; that
  /// described the bug, not the topology: the app used to send all traffic
  /// to the tunnel's own listener and the hop sat idle.)
  psiphon,

  /// The tunnel is dialled *through* Psiphon, so the network never sees WARP.
  psiphonReverse,

  /// Tor carries the device traffic: same shape as [psiphon] — the hop
  /// listens on [hopPort] and dials out through the tunnel, so the final
  /// exit is Tor's.
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
/// bundled with the app.
///
/// The full link may carry credentials (trojan/shadowsocks/SOCKS passwords,
/// VLESS/Vmess UUIDs, WireGuard private keys), so it is NEVER written to
/// the settings JSON: [link] lives only in memory and in secure storage
/// (see [VpnSettings.saveChainSecrets], keyed by proxy id). What the
/// settings JSON keeps is the non-secret descriptor — [protocol], [server]
/// and [port] — so the UI can still tell a WireGuard proxy from a VLESS
/// one and [VpnSettings.xrayChainExitFor] can still apply the UDP-only
/// rule before the link has been hydrated from secure storage.
class ChainProxy {
  const ChainProxy({
    required this.id,
    required this.name,
    required this.link,
    this.protocol = '',
    this.server = '',
    this.port = 0,
  });

  final String id;
  final String name;

  /// The share link as entered (vless://, vmess://, trojan://, ss://,
  /// socks://, http://, wireguard://, hysteria2://) or a WireGuard config
  /// converted to a wireguard:// link. In-memory only — never persisted
  /// (see [toJson]).
  final String link;

  /// Non-secret descriptor, derived from [link] when it is known and
  /// persisted in the settings JSON instead of the link. Empty until the
  /// link is parsed (old-format blobs) or hydrated (new-format blobs).
  final String protocol;
  final String server;
  final int port;

  /// The settings-JSON form: id, name and the non-secret descriptor only.
  /// The raw link and every secret it carries are excluded by design.
  Map<String, dynamic> toJson() {
    final meta = link.isNotEmpty
        ? _metaOf(link)
        : (protocol: protocol, server: server, port: port);
    return {
      'id': id,
      'name': name,
      'meta': {
        'protocol': meta.protocol,
        'server': meta.server,
        'port': meta.port,
      },
    };
  }

  /// Non-secret descriptor of [link] (protocol, server, port). Never
  /// throws: an unparseable link yields an empty descriptor, and the link
  /// itself is still saved to secure storage by [VpnSettings.saveChainSecrets].
  static ({String protocol, String server, int port}) _metaOf(String link) {
    try {
      final p = ProxyUri.parse(link);
      return (protocol: p.protocol, server: p.server, port: p.port);
    } catch (_) {
      try {
        final uri = Uri.parse(link.trim());
        return (
          protocol: uri.scheme.toLowerCase(),
          server: uri.host,
          port: uri.hasPort ? uri.port : 0,
        );
      } catch (_) {
        return (protocol: '', server: '', port: 0);
      }
    }
  }

  /// True when this proxy is UDP-only (WireGuard / Hysteria2): it can only
  /// ride on WARP, never through the TCP-only Worker relay. Uses the live
  /// link when present, otherwise the persisted non-secret descriptor.
  bool get isUdp {
    if (link.isNotEmpty) return isUdpLink(link);
    return protocol == 'wireguard' || protocol == 'hysteria2';
  }

  /// `host:port` (an IPv6 host in brackets), from the persisted descriptor.
  /// Empty when nothing is known yet.
  String get displayAddress {
    if (server.isEmpty) return '';
    return '${server.contains(':') ? '[$server]' : server}:$port';
  }

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
    if (id.isEmpty) return null;
    final name = '${v['name'] ?? id}';
    // Old format: the raw link is stored in the blob. It is kept in memory
    // so the connection keeps working this session; the load migration
    // (see VpnSettings.fromJson) moves it into secure storage and re-saves
    // the stripped form.
    final link = '${v['link'] ?? ''}';
    if (link.isNotEmpty) {
      final meta = _metaOf(link);
      return ChainProxy(
        id: id,
        name: name,
        link: link,
        protocol: meta.protocol,
        server: meta.server,
        port: meta.port,
      );
    }
    // New format: only the non-secret descriptor is stored; the link
    // itself is hydrated from secure storage after load.
    final meta = v['meta'];
    if (meta is Map) {
      return ChainProxy(
        id: id,
        name: name,
        link: '',
        protocol: '${meta['protocol'] ?? ''}',
        server: '${meta['server'] ?? ''}',
        port: meta['port'] is int
            ? meta['port'] as int
            : int.tryParse('${meta['port'] ?? 0}') ?? 0,
      );
    }
    return null;
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
    this.language = LanguageChoice.fa,
    this.autoUpdate = true,
    this.autoDownload = false,
    this.notifications = true,
    this.watchdog = true,
    this.orbStyle = OrbStyle.mercury,
    // The out-of-the-box rule is "off" (any country): the exit filter is
    // opt-in from the Config page. (An older comment claimed the default was
    // "any IP but Iran" — that was the *recommended* rule, never the default.)
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
    this.psiphonCdn = false,
    this.hopHttp = false,
    this.torCountry = '',
    // Region fields go through their setters (see below): only a 2-letter
    // ISO code survives, anything else becomes '' (automatic).
    String psiphonRegion = '',
    String torExitCountry = '',
    this.torExitStrict = true,
    this.torFastExit = false,
    this.httpProxy = false,
    this.socksPort = 1819,
    this.keepalive = 5,
    this.tunMtu = 1400,
    this.tunMtuMigrated = true,
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
  })  : _psiphonRegion = regionCode(psiphonRegion),
        _torExitCountry = regionCode(torExitCountry);

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
  ///
  /// Only a 2-letter ISO-3166 alpha-2 code survives (upper-cased): the
  /// setter and [regionCode] collapse anything else — a full name
  /// (`Germany`), a 3-letter code, junk — to `''`, so a mistyped region can
  /// never silently disable the feature the way the old free-text field did.
  String _psiphonRegion = '';
  String get psiphonRegion => _psiphonRegion;
  set psiphonRegion(String v) => _psiphonRegion = regionCode(v);

  /// Limit Psiphon to fronted meek through a CDN.
  bool psiphonCdn;

  /// Also serve the second hop as an HTTP CONNECT proxy, for apps that cannot
  /// speak SOCKS5 (shared by the Psiphon and Tor hops).
  bool hopHttp;

  /// Country handed to bridgedb when Tor needs bridges, e.g. `ir`.
  String torCountry;

  /// Country the Tor exit must be in, e.g. `DE`. Empty = automatic.
  ///
  /// This is the *exit* country — not [torCountry], which only picks the
  /// country BridgeDB hands bridges out for. Tor has no core-side exit
  /// control in aether (no `ExitNodes` variable, no control port the app can
  /// reach), so a picked country is enforced by the exit-country search
  /// instead: the effective rule becomes "preferred = [this country]" (see
  /// [effectiveExitFilter]) and the connect loop re-dials until the exit
  /// lands there. That is slow — Tor bootstrap takes a minute or two per
  /// attempt — and the UI must say so instead of promising instant switching.
  String _torExitCountry = '';
  String get torExitCountry => _torExitCountry;
  set torExitCountry(String v) => _torExitCountry = regionCode(v);

  /// Strict Tor exit: only the picked [torExitCountry] counts. False means
  /// "prefer it" — the country is accepted explicitly and anything else
  /// still has to clear the blocked list (the plain `preferred` semantics).
  /// True whenever a country is picked from the picker.
  bool torExitStrict;

  /// Fast Tor exits: prefer the nearby, well-provisioned list
  /// (DE NL CH AT FR SE PL GB) instead of any exit. Only meaningful while
  /// [torExitCountry] is empty — a picked country always wins.
  bool torFastExit;

  /// A single 2-letter ISO-3166 alpha-2 code (upper-case) or `''` for
  /// automatic. Anything else collapses to `''`.
  static String regionCode(Object? raw) {
    final c = '$raw'.trim().toUpperCase();
    if (c.length != 2) return '';
    for (final u in c.codeUnits) {
      if (u < 65 || u > 90) return '';
    }
    return c;
  }

  /// True when Psiphon is in this connection's path (standalone
  /// Psiphon-only, or a Psiphon second hop) — the same rule
  /// `CoreLaunch.isPsiphon` applies, restated here so settings never
  /// imports the core launcher.
  bool get hasPsiphonHop =>
      standaloneMode == StandaloneMode.psiphonOnly ||
      (standaloneMode == StandaloneMode.standard &&
          (secondHop == SecondHop.psiphon ||
              secondHop == SecondHop.psiphonReverse));

  /// True when Tor is in this connection's path — same rule as
  /// `CoreLaunch.isTor`, restated here for the same reason.
  bool get hasTorHop =>
      standaloneMode == StandaloneMode.torOnly ||
      (standaloneMode == StandaloneMode.standard &&
          (secondHop == SecondHop.tor || secondHop == SecondHop.torReverse));

  /// True when a second hop *carries the device traffic* (chain): the hop
  /// listens on its own port ([hopPort]) and dials out through the tunnel,
  /// so the final exit is the hop's. Standalone modes are not chain (the hop
  /// IS the main listener there) and reverse hops are not chain (the tunnel
  /// is dialled through the hop and the exit stays WARP).
  bool get isChainHop =>
      standaloneMode == StandaloneMode.standard &&
      (secondHop == SecondHop.psiphon || secondHop == SecondHop.tor);

  /// True when the tunnel is dialled *through* Psiphon/Tor (reverse): the
  /// final exit stays WARP — the hop only carries the tunnel. The exit
  /// pickers must not present a country as the egress in this mode.
  bool get isReverseHop =>
      standaloneMode == StandaloneMode.standard &&
      (secondHop == SecondHop.psiphonReverse ||
          secondHop == SecondHop.torReverse);

  /// 'Psiphon' when Psiphon is in the path, 'Tor' when Tor is, else ''.
  /// The name the topology captions and the reverse note are built with.
  String get hopName {
    if (hasPsiphonHop) return 'Psiphon';
    if (hasTorHop) return 'Tor';
    return '';
  }

  /// The SOCKS listener device traffic must go through: the hop's own
  /// listener in chain mode (the hop dials out through the tunnel, so the
  /// final exit is the hop's), otherwise the tunnel's own listener. The
  /// TUN bridge, the system proxy and the exit probe all use this port —
  /// pointing any of them at [socksPort] in chain mode is the bug that left
  /// the hop idle while traffic exited via WARP.
  int get devicePort => isChainHop ? hopPort : socksPort;

  /// The exit rule actually enforced for this connection.
  ///
  /// The user's [exitFilter], except that a picked Tor exit country
  /// overrides it while Tor is in the path: Tor has no core-side exit
  /// control, so the only enforcement is the exit-country search, and the
  /// search needs a rule to enforce. The override is scoped to Tor
  /// connections — picking a Tor country must not change what a plain WARP
  /// tunnel accepts — and it never touches the stored [exitFilter],
  /// [exitPreferred] or [exitBlocked]: clearing the Tor country restores
  /// the user's own rule exactly, so the picker and the filter UI can never
  /// fight each other.
  ExitFilter get effectiveExitFilter {
    if (!hasTorHop) return exitFilter;
    if (torExitCountry.isNotEmpty || torFastExit) {
      return ExitFilter.preferred;
    }
    return exitFilter;
  }

  /// Preferred list under the effective rule: the picked Tor country (or
  /// the fast-exit list) while the Tor override is in force, else the
  /// user's own list.
  List<String> get effectiveExitPreferred {
    if (!hasTorHop) return exitPreferred;
    if (torExitCountry.isNotEmpty) return [torExitCountry];
    if (torFastExit) {
      return const ['DE', 'NL', 'CH', 'AT', 'FR', 'SE', 'PL', 'GB'];
    }
    return exitPreferred;
  }

  /// Blocked list under the effective rule: always the user's list — a
  /// picked Tor country never lets a blocked exit back in.
  List<String> get effectiveExitBlocked => exitBlocked;

  /// True when the Tor country override is the rule in force.
  bool get torExitEnforced => hasTorHop && torExitCountry.isNotEmpty;

  /// True when the fast-exit list is the rule in force.
  bool get torFastExitEnforced =>
      hasTorHop && torExitCountry.isEmpty && torFastExit;

  /// Extra HTTP CONNECT listener next to the SOCKS5 one, for apps that only
  /// speak HTTP proxies.
  bool httpProxy;

  int socksPort;
  int keepalive;

  /// MTU of the local TUN device — the size apps may segment at before the
  /// bridge sees the packet. TCP is terminated inside the bridge, so for TCP
  /// this side is independent of the tunnel's own MTU; UDP is not: datagrams
  /// (QUIC, DNS) are forwarded as-is through SOCKS and then encapsulated by
  /// the core (WireGuard/MASQUE), so a TUN MTU equal to the physical MTU
  /// lets apps emit datagrams that no longer fit once encapsulated and
  /// blackhole when path-MTU signalling does not flow (Google's QUIC-heavy
  /// traffic is the visible victim). 1400 leaves headroom for the SOCKS +
  /// core encapsulation while staying close to the physical MTU.
  int tunMtu;

  /// One-time marker for the 1500 -> 1400 default migration in [fromJson]:
  /// a stored 1500 from a pre-1.8.1 build is the old shipped default (it was
  /// persisted by every install), not a deliberate pick, so it takes the new
  /// default once; the marker then keeps a deliberate 1500 set afterwards.
  bool tunMtuMigrated;

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
  // Chain-proxy links are secrets too (finding 8): the full link lives in
  // secure storage keyed by proxy id (see [saveChainSecrets]) and only the
  // non-secret descriptor (protocol/server/port) is stored here, so the
  // UI can still show a proxy without its credentials.
  // What is stored here is only what the UI needs to show: domains, ids,
  // flags and the chain proxies' non-secret descriptors.

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
        .where((c) => !c.isUdp || mode == XrayMode.warp)
        .toList();
    if (usable.isEmpty) return null;
    for (final c in usable) {
      if (c.id == xrayChainExitId) return c;
    }
    return usable.first;
  }

  // ── Chain-proxy secrets (finding 8) ───────────────────────────────────
  //
  // A chain-proxy link embeds its credentials (password, UUID, WireGuard
  // private key, preshared key, Hysteria2 auth) in a per-format shape —
  // base64 JSON for vmess, base64 userinfo for shadowsocks — so the
  // secret fields cannot be split out and rebuilt reliably. The whole
  // link is therefore stored verbatim in secure storage, keyed by proxy
  // id; the settings JSON keeps only the non-secret descriptor (see
  // [ChainProxy.toJson]). The value in secure storage is the complete
  // link, i.e. it contains the password / private key; the settings blob
  // contains none of it.
  static const _chainStorage = FlutterSecureStorage(
    // No encryptedSharedPreferences parameter: in v10 it is deprecated and
    // ignored (data auto-migrates to the custom ciphers on first access),
    // and v11 removes it.
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );
  static String _chainSecretKey(String id) => 'chainproxy.$id';
  static const _chainSecretPrefix = 'chainproxy.';

  /// Writes every in-memory chain-proxy link to secure storage (keyed by
  /// proxy id) and deletes the stored secrets of proxies that are no
  /// longer in the list. Called by `VpnController.persist()` before the
  /// stripped settings JSON is written, so adding a proxy saves its
  /// secret and removing one does not leave the secret behind. Never
  /// throws: secure storage may be unavailable (no keystore, unit tests)
  /// and that must never break saving the rest of the settings.
  static Future<void> saveChainSecrets(List<ChainProxy> proxies) async {
    for (final p in proxies) {
      if (p.link.isEmpty) continue;
      try {
        await _chainStorage.write(key: _chainSecretKey(p.id), value: p.link);
      } catch (_) {}
    }
    try {
      final all = await _chainStorage.readAll();
      final keep = {for (final p in proxies) _chainSecretKey(p.id)};
      for (final key in all.keys) {
        if (key.startsWith(_chainSecretPrefix) && !keep.contains(key)) {
          try {
            await _chainStorage.delete(key: key);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Fills in the in-memory links of proxies loaded from a new-format
  /// blob (descriptor only) from secure storage. Returns true when at
  /// least one link was restored. Never throws.
  static Future<bool> hydrateChainProxies(VpnSettings settings) async {
    var changed = false;
    final list = settings.xrayChainProxies;
    for (var i = 0; i < list.length; i++) {
      final p = list[i];
      if (p.link.isNotEmpty) continue;
      try {
        final link = await _chainStorage.read(key: _chainSecretKey(p.id));
        if (link != null && link.isNotEmpty) {
          list[i] = ChainProxy(
            id: p.id,
            name: p.name,
            link: link,
            protocol: p.protocol,
            server: p.server,
            port: p.port,
          );
          changed = true;
        }
      } catch (_) {}
    }
    return changed;
  }

  /// Load migration for chain proxies (finding 8), run fire-and-forget
  /// from [fromJson]: an old blob's raw links are moved into secure
  /// storage, new-format proxies get their links hydrated, and the stored
  /// blob is re-saved in the stripped form — but only when the blob on
  /// disk is still the one that was loaded (same proxy ids in the same
  /// order), so a newer save is never clobbered. Never throws.
  static Future<void> _migrateChainProxiesOnLoad(
      VpnSettings settings) async {
    try {
      await saveChainSecrets(settings.xrayChainProxies);
      await hydrateChainProxies(settings);
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('settings');
      if (raw == null) return;
      final stored = jsonDecode(raw);
      if (stored is! Map<String, dynamic>) return;
      final list = stored['xrayChainProxies'] ?? stored['chainProxies'];
      if (list is! List) return;
      final hasLinks = list.any((e) =>
          e is Map &&
          e['link'] is String &&
          (e['link'] as String).isNotEmpty);
      if (!hasLinks) return;
      final storedIds = [
        for (final e in list)
          if (e is Map) '${e['id'] ?? ''}',
      ];
      final loadedIds = [for (final p in settings.xrayChainProxies) p.id];
      if (storedIds.length != loadedIds.length) return;
      for (var i = 0; i < storedIds.length; i++) {
        if (storedIds[i] != loadedIds[i]) return;
      }
      stored['xrayChainProxies'] = [
        for (final p in settings.xrayChainProxies) p.toJson(),
      ];
      stored.remove('chainProxies');
      await prefs.setString('settings', jsonEncode(stored));
    } catch (_) {}
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
  /// 9000 is the largest jumbo frame worth offering; the default of 1400
  /// keeps UDP datagrams small enough to survive SOCKS + core encapsulation
  /// (see [tunMtu]).
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
        'torExitCountry': torExitCountry,
        'torExitStrict': torExitStrict,
        'torFastExit': torFastExit,
        'httpProxy': httpProxy,
        'socksPort': socksPort,
        'keepalive': keepalive,
        'tunMtu': tunMtu,
        'tunMtuMigrated': tunMtuMigrated,
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
    // MIGRATION (TUN MTU default 1500 -> 1400): every pre-1.8.1 install
    // persisted the then-default 1500, which lets UDP datagrams (QUIC/DNS)
    // blackhole once SOCKS + core encapsulation is added. A stored 1500
    // without the marker is that old default, not a deliberate pick, so it
    // takes the new default once; the marker (written back by toJson) keeps
    // a deliberate 1500 chosen afterwards.
    final storedTunMtu = num('tunMtu', 1400);
    final tunMtuMigrated = json['tunMtuMigrated'] == true;
    final effectiveTunMtu =
        (!tunMtuMigrated && storedTunMtu == 1500) ? 1400 : storedTunMtu;

    final xrayChainProxies = (xrayChainProxiesJson is List
        ? xrayChainProxiesJson
            .map(ChainProxy.parse)
            .whereType<ChainProxy>()
            .toList()
        : const <ChainProxy>[]);
    final settings = VpnSettings(
      mode: parse(ConnectionMode.values, 'mode', ConnectionMode.vpn),
      protocol: parse(Protocol.values, 'protocol', Protocol.wg),
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
      language: parse(LanguageChoice.values, 'language', LanguageChoice.fa),
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
      psiphonRegion: regionCode(json['psiphonRegion']),
      psiphonCdn: json['psiphonCdn'] == true,
      // `psiphonHttp` is what an older build stored for the same switch.
      hopHttp: json['hopHttp'] == true || json['psiphonHttp'] == true,
      torCountry: json['torCountry']?.toString() ?? '',
      torExitCountry: regionCode(json['torExitCountry']),
      torExitStrict: json['torExitStrict'] != false,
      torFastExit: json['torFastExit'] == true,
      httpProxy: json['httpProxy'] == true,
      socksPort: num('socksPort', 1819),
      keepalive: num('keepalive', 5),
      tunMtu: effectiveTunMtu,
      tunMtuMigrated: true,
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
      xrayChainProxies: xrayChainProxies,
      xrayChainExitId: xrayChainExitIdJson?.toString() ?? '',
    );
    // MIGRATION (finding 8): when the loaded blob held chain proxies —
    // raw links from an older build, or descriptors whose links live in
    // secure storage — move the secrets and re-save the stripped blob in
    // the background. The in-memory links are already usable, so the
    // connection keeps working while the migration runs.
    if (xrayChainProxies.isNotEmpty) {
      unawaited(_migrateChainProxiesOnLoad(settings));
    }
    return settings;
  }

  VpnSettings copyWithProtocol(Protocol p) {
    final copy = VpnSettings.fromJson(toJson());
    copy.protocol = p;
    return copy;
  }
}
