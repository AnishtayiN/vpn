import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/settings.dart';
import 'chain_proxy.dart';
import 'warp.dart';
import 'windows_tun.dart';

/// Xray-core beside Aether: the second engine of VoidrauVPN.
///
/// Android runs it in-process (gomobile `xray.aar`, TUN fd handed over by
/// the VpnService). Windows runs the official `xray.exe` as a child
/// process exposing the same SOCKS5 inbound, with the existing WinTUN
/// bridges / system proxy in front of it (`WindowsEngine.startCaptureOnly`)
/// — the mirror of how `aether.exe` is driven there. iOS keeps Aether
/// exactly as today — the Xray modes are hidden there (see
/// [XrayEngine.supported] and the settings UI).
/// One tunnel at a time: starting Xray while Aether runs is the controller's
/// job to prevent, and [XrayEngine.start] refuses to start twice.
///
/// What each mode does (and does not do):
/// * [XrayMode.worker] — VLESS over WebSocket + TLS through the user's OWN
///   Cloudflare Worker (deployed by the setup wizard). TCP only: a UDP chain
///   proxy cannot ride on it.
/// * [XrayMode.warp] — WireGuard to Cloudflare WARP with the account
///   registered on this device. No Worker needed. UDP chain proxies ride here.
/// * [XrayMode.serverless] — direct connections with TLS fragmentation and
///   UDP noise only. NO MITM, NO domain fronting, NO CA install — those are
///   deliberately not implemented.
/// * MASQUE is NOT duplicated here: Aether already has it.
///
/// The config shape follows Xray-core's JSON format (xtls/xray-core, MPL-2.0)
/// and the `finalmask` fragment/noise layout BPB-VPN uses against the same
/// core (GPLv3 — adapted logic, own code; see README/CHANGELOG).
class XrayEngine {
  /// Channel the Android native side answers on: the same `nimbus.vpn/engine`
  /// channel Aether uses, with its own `startXray` / `stopXray` / `xrayStatus`
  /// methods (see NimbusPlugin.kt → XrayCoreManager.kt, the
  /// CoreManager-equivalent). Until the native side ships the compiled
  /// `xray.aar`, every call answers with a `xray_unavailable` error instead
  /// of crashing.
  static const _channel = MethodChannel('nimbus.vpn/engine');

  /// True where the Xray engine exists: Android (gomobile build) and
  /// Windows (`xray.exe` sidecar). iOS has no Xray build.
  static bool get supported => Platform.isAndroid || Platform.isWindows;

  /// Throws [UnsupportedError] on iOS, so a caller can never start an
  /// Xray mode where no Xray binary exists.
  static void requireSupported() {
    if (!supported) {
      throw UnsupportedError(
        'Xray modes are not available on iOS; Aether handles this platform.',
      );
    }
  }

  bool _running = false;
  bool get isRunning => _running;

  /// Optional sink for the Windows core's log lines (the controller
  /// wires this to the same live log the Aether core feeds).
  void Function(String line)? onLog;

  /// Windows: fired when `xray.exe` exits without [stop] being called —
  /// the controller engages the kill switch so the TUN/proxy capture
  /// that outlives the core fails closed instead of leaking.
  void Function()? onUnexpectedExit;

  // ── Windows child process ──────────────────────────────────────────
  Process? _proc;
  bool _procExited = false;
  String? _version;
  String _lastError = '';

  /// Where `xray.exe` lives: next to the app exe in an install, the dev
  /// sidecar dir in a source run — the same resolution the Aether core
  /// uses. Null when neither exists (a broken/old install).
  static File? windowsBinary() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final installed = File(p.join(exeDir, 'xray.exe'));
    if (installed.existsSync()) return installed;
    final sidecar = File(p.join(
        Directory.current.path, 'third_party', 'windows', 'xray.exe'));
    if (sidecar.existsSync()) return sidecar;
    return null;
  }

  /// Per-user writable dir for the generated config (mirrors
  /// `WindowsEngine.runtimeDir` — the config carries the Worker UUID /
  /// WARP keys, so it must never sit next to the exe under Program
  /// Files, and it is deleted on stop).
  static String get _windowsRuntimeDir {
    final base = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    final dir = Directory(p.join(base, 'VoidrauVPN'));
    dir.createSync(recursive: true);
    return dir.path;
  }

  String get _configPath => p.join(_windowsRuntimeDir, 'xray.json');

  /// Starts Xray from a config built by [XrayConfigBuilder]. On Android,
  /// when [vpnMode] is true the native side opens its own VpnService
  /// first and hands Xray the TUN file descriptor (proxy mode passes no
  /// TUN). On Windows the core is spawned as `xray.exe run -c <config>`
  /// and device capture is the caller's next step
  /// (`PlatformEngine.startCaptureOnly`) — [vpnMode] only records the
  /// intent there. Throws when the platform has no Xray build.
  Future<void> start(
    String configJson, {
    bool vpnMode = true,
  }) async {
    requireSupported();
    if (_running) return;
    if (Platform.isWindows) {
      await _startWindows(configJson);
      return;
    }
    try {
      await _channel.invokeMethod('startXray', {
        'config': configJson,
        'mode': vpnMode ? 'vpn' : 'proxy',
      });
      _running = true;
    } on PlatformException catch (e) {
      throw StateError('Xray did not start: ${e.message ?? e.code}');
    }
  }

  Future<void> _startWindows(String configJson) async {
    final exe = windowsBinary();
    if (exe == null) {
      throw StateError(
          'xray.exe not found — reinstall VoidrauVPN (the Xray core is missing)');
    }
    // The generated config routes on `geoip:private`; without the asset
    // files xray refuses the config at startup. Name the missing piece
    // instead of surfacing a raw core error.
    for (final asset in ['geoip.dat', 'geosite.dat']) {
      if (!File(p.join(exe.parent.path, asset)).existsSync()) {
        throw StateError(
            '$asset not found next to xray.exe — reinstall VoidrauVPN');
      }
    }
    await File(_configPath).writeAsString(configJson);
    _procExited = false;
    _lastError = '';
    _proc = await Process.start(
      exe.path,
      ['run', '-c', _configPath],
      workingDirectory: exe.parent.path,
      environment: {
        ...Platform.environment,
        // Geo assets live next to the exe; the config lives in the
        // runtime dir, so point Xray at the assets explicitly.
        'XRAY_LOCATION_ASSET': exe.parent.path,
      },
    );
    _running = true;
    final proc = _proc!;
    void onChunk(String chunk) {
      for (final line in chunk.split(RegExp(r'\r?\n'))) {
        final t = line.trim();
        if (t.isEmpty) continue;
        onLog?.call('xray: $t');
        if (t.toLowerCase().contains('error') ||
            t.toLowerCase().contains('failed')) {
          _lastError = t;
        }
      }
    }

    proc.stdout.transform(utf8.decoder).listen(onChunk);
    proc.stderr.transform(utf8.decoder).listen(onChunk);
    unawaited(proc.exitCode.then((code) {
      if (identical(_proc, proc)) {
        _procExited = true;
        _running = false;
        onLog?.call('xray: core exited ($code)');
        onUnexpectedExit?.call();
      }
    }));
  }

  Future<void> stop() async {
    if (Platform.isWindows) {
      final proc = _proc;
      _proc = null;
      _running = false;
      if (proc != null) {
        // Same teardown as the Aether core: graceful signal, a short
        // wait, then a tree-kill (xray spawns no helpers today, but the
        // tree form is the safe default), then sigkill.
        try {
          proc.kill(ProcessSignal.sigterm);
        } catch (_) {}
        try {
          await proc.exitCode.timeout(const Duration(milliseconds: 800));
        } catch (_) {}
        try {
          await Process.run('taskkill', ProcessSweep.taskkillArgs(proc.pid));
        } catch (_) {}
        try {
          proc.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
      try {
        await File(_configPath).delete();
      } catch (_) {}
      return;
    }
    if (!_running && !supported) return;
    try {
      await _channel.invokeMethod('stopXray');
    } on PlatformException {
      // Stopping a dead engine is not an error worth surfacing.
    } finally {
      _running = false;
    }
  }

  /// Status map: `{'running': bool, 'version': String}`. Empty when the
  /// platform has no Xray build. On Windows, `running` tracks the child
  /// process and `version` is read once from `xray.exe version`.
  Future<Map<String, dynamic>> status() async {
    if (!supported) return const {'running': false};
    if (Platform.isWindows) {
      return {
        'running': _proc != null && !_procExited,
        'version': await _windowsVersion(),
        if (_lastError.isNotEmpty) 'error': _lastError,
      };
    }
    try {
      final map = await _channel.invokeMethod<Map>('xrayStatus');
      return Map<String, dynamic>.from(map ?? {});
    } on PlatformException {
      return const {'running': false};
    }
  }

  Future<String> _windowsVersion() async {
    final cached = _version;
    if (cached != null) return cached;
    final exe = windowsBinary();
    if (exe == null) return _version = '';
    try {
      final r = await Process.run(exe.path, ['version']);
      // "Xray 26.10.31 (Xray, Penetrates Everything.) ..."
      final m = RegExp(r'Xray\s+([\d.]+)').firstMatch('${r.stdout}');
      return _version = m?.group(1) ?? '';
    } catch (_) {
      return _version = '';
    }
  }
}

/// Builds the Xray JSON config for one connection.
///
/// The config is pure data — no secrets are logged, and the UUID / WARP keys
/// arrive as arguments from secure storage, never from a hardcoded value.
class XrayConfigBuilder {
  /// Local SOCKS inbound the app's own probes and proxy mode use. It rides on
  /// the same port as Aether's SOCKS listener so the dashboard, the leak
  /// check and the exit probe work unchanged — but only one engine runs, so
  /// the port is never shared at the same time.
  static int socksPort(VpnSettings settings) => settings.socksPort;

  /// Full config for [settings.xrayMode]. Throws [StateError] with a
  /// human-readable reason when something the mode needs is missing (no
  /// Worker deployed, no WARP account, no usable chain proxy).
  static Map<String, dynamic> build(
    VpnSettings settings, {
    String? workerUuid,
    WarpAccount? warpAccount,
    ChainProxy? exitProxy,
  }) {
    final mode = settings.xrayMode;
    if (mode == XrayMode.off) {
      throw StateError('Xray mode is off — Aether handles this connection.');
    }
    final outbounds = <Map<String, dynamic>>[];
    switch (mode) {
      case XrayMode.worker:
        final domain = settings.workerDomain.trim();
        final uuid = (workerUuid ?? '').trim();
        if (domain.isEmpty || !settings.workerDeployed) {
          throw StateError(
            'Deploy your Worker first (Setup wizard) before using Worker mode.',
          );
        }
        if (uuid.isEmpty) {
          throw StateError('Worker UUID is missing — redeploy the Worker.');
        }
        outbounds.add(
          workerOutbound(domain, uuid, settings.xrayVariant, settings),
        );
      case XrayMode.warp:
        final account = warpAccount;
        if (account == null || !settings.warpRegistered) {
          throw StateError(
            'Register a WARP account first (Setup wizard) before using WARP.',
          );
        }
        final endpoints = settings.warpEndpoints;
        if (endpoints.isEmpty) {
          throw StateError('No WARP endpoints — register the account again.');
        }
        outbounds.add(
          warpOutbound(account, endpoints.first, settings.xrayVariant),
        );
      case XrayMode.serverless:
        outbounds.addAll(
          serverlessOutbounds(
            fragment: settings.serverlessFragment,
            noise: settings.serverlessNoise,
          ),
        );
      case XrayMode.off:
        throw StateError('Xray mode is off.');
    }

    // Optional chain exit: the chosen proxy carries the traffic, dialled
    // through the main connection. UDP proxies only ride on WARP.
    final exit = exitProxy ?? settings.xrayChainExitFor(mode);
    final hasChain = exit != null && mode != XrayMode.serverless;
    if (hasChain) {
      // The chain outbound must dial *through* the main (`proxy`) outbound,
      // not direct — otherwise the chain proxy would bypass the tunnel and
      // the Worker/WARP hop would carry nothing. Xray's sockopt dialerProxy
      // names the outbound to dial through.
      final exitOutbound = chainProxyOutbound(exit.link);
      final stream = Map<String, dynamic>.from(
        exitOutbound['streamSettings'] as Map<String, dynamic>? ?? {},
      );
      final sockopt = Map<String, dynamic>.from(
        stream['sockopt'] as Map<String, dynamic>? ?? {},
      );
      sockopt['dialerProxy'] = 'proxy';
      stream['sockopt'] = sockopt;
      exitOutbound['streamSettings'] = stream;
      outbounds.add(exitOutbound);
    }

    return {
      'log': {'loglevel': _logLevel(settings.logLevel)},
      'inbounds': [
        {
          'tag': 'socks-in',
          'protocol': 'socks',
          'listen': '127.0.0.1',
          'port': settings.socksPort,
          'settings': {'udp': true, 'auth': 'noauth'},
          'sniffing': {
            'enabled': true,
            'destOverride': ['http', 'tls']
          },
        },
      ],
      'outbounds': [
        ...outbounds,
        // The main outbound is always tagged `proxy`, whatever the mode.
        // (worker/warp build it with that tag; serverless builds it too.)
        {'protocol': 'freedom', 'tag': 'direct'},
        {'protocol': 'blackhole', 'tag': 'block'},
      ],
      'routing': {
        'domainStrategy': 'IPIfNonMatch',
        'rules': [
          {
            'type': 'field',
            'ip': ['geoip:private'],
            'outboundTag': 'direct',
          },
          if (hasChain) {'type': 'field', 'outboundTag': 'exit'},
          {'type': 'field', 'outboundTag': 'proxy'},
        ],
      },
      'dns': {
        'servers': ['https://1.1.1.1/dns-query', '1.1.1.1'],
      },
    };
  }

  static String _logLevel(String level) => switch (level) {
        'error' || 'warn' || 'info' || 'debug' || 'trace' => level,
        _ => 'info',
      };

  /// VLESS over WebSocket + TLS to the user's Worker. `fragment` splits the
  /// TLS ClientHello (finalmask); `normal` does not.
  static Map<String, dynamic> workerOutbound(
    String domain,
    String uuid,
    XrayVariant variant,
    VpnSettings settings,
  ) {
    final fragment = variant == XrayVariant.fragment;
    return {
      'protocol': 'vless',
      'settings': {
        'address': domain,
        'port': 443,
        'id': uuid,
        'encryption': 'none',
      },
      'streamSettings': {
        'network': 'ws',
        'wsSettings': {'host': domain, 'path': '/?ed=2048'},
        'security': 'tls',
        'tlsSettings': {
          'serverName': domain,
          'fingerprint': 'chrome',
          'alpn': ['http/1.1'],
        },
        'sockopt': {
          'domainStrategy': 'UseIP',
          'happyEyeballs': {
            'tryDelayMs': 250,
            'prioritizeIPv6': false,
            'interleave': 2,
            'maxConcurrentTry': 4,
          },
        },
        if (fragment) 'finalmask': defaultFragmentMask(),
      },
      'tag': 'proxy',
    };
  }

  /// WireGuard to WARP. `obfuscated` adds UDP noise over the transport
  /// (finalmask); `normal` is the plain WireGuard handshake.
  static Map<String, dynamic> warpOutbound(
    WarpAccount account,
    String endpoint,
    XrayVariant variant,
  ) {
    return {
      'protocol': 'wireguard',
      'settings': {
        'address': ['172.16.0.2/32', account.ipv6],
        'mtu': 1280,
        'peers': [
          {
            'endpoint': endpoint,
            'publicKey': account.publicKey,
            'keepAlive': 5,
          },
        ],
        'reserved': account.reserved,
        'secretKey': account.privateKey,
      },
      if (variant == XrayVariant.obfuscated)
        'streamSettings': {
          'finalmask': defaultNoiseMask(),
          'sockopt': {'domainStrategy': 'UseIP'},
        },
      'tag': 'proxy',
    };
  }

  /// Serverless: freedom outbounds. The main `proxy` outbound carries TCP
  /// with TLS fragmentation; `http-fragment` splits single-packet HTTP; and
  /// `udp-noise` carries QUIC-shaped UDP with noise packets. No server, no
  /// MITM, no CA — the traffic goes direct, only masked.
  static List<Map<String, dynamic>> serverlessOutbounds({
    required bool fragment,
    required bool noise,
  }) {
    return [
      {
        'protocol': 'freedom',
        'streamSettings': {
          'sockopt': {'domainStrategy': 'UseIPv4'},
          if (fragment) 'finalmask': defaultFragmentMask(),
        },
        'tag': 'proxy',
      },
      if (fragment)
        {
          'protocol': 'freedom',
          'streamSettings': {
            'sockopt': {'domainStrategy': 'UseIPv4'},
            'finalmask': {
              'tcp': [
                {
                  'type': 'fragment',
                  'settings': {
                    'packets': '1-1',
                    'lengths': ['100-200'],
                    'delays': ['1'],
                  },
                },
              ],
            },
          },
          'tag': 'http-fragment',
        },
      if (noise)
        {
          'protocol': 'freedom',
          'streamSettings': {
            'sockopt': {'domainStrategy': 'UseIPv4'},
            'finalmask': defaultNoiseMask(),
          },
          'tag': 'udp-noise',
        },
    ];
  }

  /// Default TLS-fragment mask: split the ClientHello (`tlshello`) into
  /// 100–200 byte pieces, 1 ms apart. Same defaults BPB ships.
  static Map<String, dynamic> defaultFragmentMask() => {
        'tcp': [
          {
            'type': 'fragment',
            'settings': {
              'packets': 'tlshello',
              'lengths': ['100-200'],
              'delays': ['1'],
            },
          },
        ],
      };

  /// Default UDP-noise mask: random 30–60 byte packets, 10–30 ms apart,
  /// reset every 30–60 s. Same defaults BPB ships.
  static Map<String, dynamic> defaultNoiseMask() => {
        'udp': [
          {
            'type': 'noise',
            'settings': {
              'reset': '30-60',
              'noise': [
                {'rand': '30-60', 'randRange': '0-255', 'delay': '10-30'},
              ],
            },
          },
        ],
      };

  /// The config as a JSON string, ready for the native side.
  static String buildJson(
    VpnSettings settings, {
    String? workerUuid,
    WarpAccount? warpAccount,
    ChainProxy? exitProxy,
  }) =>
      jsonEncode(
        build(
          settings,
          workerUuid: workerUuid,
          warpAccount: warpAccount,
          exitProxy: exitProxy,
        ),
      );
}
