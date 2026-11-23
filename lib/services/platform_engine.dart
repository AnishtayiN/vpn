import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/engine_state.dart';
import '../models/settings.dart';
import 'core_args.dart';
import 'socks_probe.dart';
import 'split.dart';
import 'windows_killswitch.dart';
import 'windows_proxy.dart';
import 'windows_tun.dart';

class PlatformEngine {
  // Shared by the Android plugin and overlays/ios/Runner/VPNPlugin.swift.
  static const _channel = MethodChannel('nimbus.vpn/engine');
  static const _events = EventChannel('nimbus.vpn/events');

  Stream<Map<String, dynamic>> events() {
    return _events.receiveBroadcastStream().map((event) {
      if (event is Map) return Map<String, dynamic>.from(event);
      return jsonDecode('$event') as Map<String, dynamic>;
    });
  }

  Future<bool> prepareVpn() async {
    if (!Platform.isAndroid && !Platform.isIOS) return true;
    final ok = await _channel.invokeMethod<bool>('prepareVpn');
    return ok ?? false;
  }

  Future<void> start(VpnSettings settings, {Protocol? protocol}) {
    final proto = protocol ?? settings.protocol;
    final cfg = {
      ...settings.toJson(),
      // The native side drives the core through environment variables only
      // (its documented contract); it knows its own config/temp paths.
      'env': CoreLaunch.environmentLines(
        settings,
        override: protocol,
        configPath: 'aether.toml',
      ),
      'protocol': (proto == Protocol.smart ? Protocol.masque : proto).name,
      'transport': settings.transport.name,
      'socksPort': settings.socksPort,
      // The SOCKS listener device traffic goes through: the hop's own
      // listener in chain mode, else the tunnel's. The native side routes
      // the TUN bridge (and the LAN share) at this port and validates
      // traffic through it; the core's own listener stays on socksPort.
      // iOS ignores this key — IosPolicy forces hops off there, so the
      // device port is always the SOCKS port and no Swift change is needed.
      'devicePort': settings.devicePort,
      'tunMtu': settings.deviceMtu,
      'killSwitch': settings.killSwitch,
      'bypassLan': settings.bypassLan,
    };
    if (Platform.isAndroid || Platform.isIOS) {
      return _channel.invokeMethod('start', cfg);
    }
    if (Platform.isWindows) {
      return WindowsEngine.instance.start(settings, protocol: protocol);
    }
    throw UnsupportedError('Unsupported platform');
  }

  /// [keepBlock] (Windows only): a recovery teardown that must keep the
  /// kill-switch block (and the dead-listener proxy) in place while the
  /// watchdog re-dials. User disconnects always pass false.
  Future<void> stop({bool keepBlock = false}) {
    if (Platform.isAndroid || Platform.isIOS) {
      return _channel.invokeMethod('stop');
    }
    if (Platform.isWindows) {
      return WindowsEngine.instance.stop(keepBlock: keepBlock);
    }
    return Future.value();
  }

  /// Windows: engage the kill-switch block now (used when the Xray core
  /// dies unexpectedly — the Aether core's own exit handler engages it
  /// inside the engine). No-op off Windows / when not armed.
  Future<void> engageKillSwitch() async {
    if (Platform.isWindows) return WindowsEngine.instance.engageKillSwitch();
  }

  Future<Map<String, dynamic>> status() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final map = await _channel.invokeMethod<Map>('status');
      return Map<String, dynamic>.from(map ?? {});
    }
    if (Platform.isWindows) return WindowsEngine.instance.statusMap();
    return {'phase': 'disconnected'};
  }

  Future<List<Map<String, String>>> installedApps() async {
    if (!Platform.isAndroid) return const [];
    final raw = await _channel.invokeMethod<List>('listApps');
    return (raw ?? const [])
        .map((e) => Map<String, String>.from(e as Map))
        .toList();
  }

  Future<void> recoverNetwork() async {
    if (Platform.isWindows) return WindowsEngine.instance.recover();
    if (Platform.isAndroid || Platform.isIOS) {
      await _channel.invokeMethod('recover');
    }
  }

  /// Windows Xray path: the Xray core (spawned by `XrayEngine`) already
  /// serves a proven SOCKS5 listener; this puts the same device capture
  /// (WinTUN + egress gate, or the verified system proxy) in front of it
  /// that the Aether path uses. No-op off Windows.
  Future<void> startCaptureOnly(VpnSettings settings) async {
    if (Platform.isWindows) {
      return WindowsEngine.instance.startCaptureOnly(settings);
    }
  }

  /// Windows self-heal: undo a kill-switch block left behind by a
  /// hard-killed run. No-op off Windows.
  Future<void> sweepKillSwitch() async {
    if (Platform.isWindows) return WindowsEngine.instance.sweepKillSwitch();
  }

  Future<void> installUpdate(String path) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod('installApk', {'path': path});
      return;
    }
    if (Platform.isWindows) {
      await Process.start(path, const [], runInShell: true);
    }
  }

  Future<void> openBatterySettings() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod('openBattery');
    }
  }

  Future<void> openSystemVpnSettings() async {
    if (Platform.isAndroid || Platform.isIOS) {
      await _channel.invokeMethod('openVpnSettings');
    }
  }

  Future<bool> isElevated() async {
    if (Platform.isAndroid) return true;
    if (Platform.isWindows) return WindowsEngine.instance.isAdmin();
    return false;
  }

  Future<bool> isWifi() async {
    if (!Platform.isAndroid) return true;
    final ok = await _channel.invokeMethod<bool>('isWifi');
    return ok ?? true;
  }

  Future<bool> verifyApk(String path) async {
    if (!Platform.isAndroid) return true;
    final ok = await _channel.invokeMethod<bool>('verifyApk', {'path': path});
    return ok ?? false;
  }

  Future<void> saveNativePrefs(VpnSettings settings, {bool blocked = false}) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('savePrefs', {
      'autoConnect': settings.autoConnect,
      'lanShare': settings.lanShare,
      // A retired build must not be able to tunnel through a Quick Settings
      // tile or the boot receiver, which never go through the UI.
      'blocked': blocked,
    });
  }
}

/// Windows: spawns the tunnel core (`aether.exe`) with env-only config,
/// waits for a real SOCKS5 handshake, proves the data plane, then puts a
/// WinTUN full-device tunnel in front when running elevated — trying whichever
/// bridge (tun2socks, its Go 1.20 legacy build, or hev-socks5-tunnel) can
/// actually run on this Windows, and proving the device carries traffic before
/// calling it a VPN. See `windows_tun.dart` for why there is more than one.
class WindowsEngine {
  WindowsEngine._() {
    // Proxy changes are visible in the same live log as the core's output.
    WindowsSystemProxy.instance.onLog = (line) => _logs.add(line);
  }

  static final instance = WindowsEngine._();

  Process? _core;
  Process? _tun;
  final _logs = StreamController<String>.broadcast();
  EnginePhase phase = EnginePhase.disconnected;
  String message = '';
  String endpoint = '';
  String protocol = '';
  String lastError = '';
  String? _originalGw;
  int _socksPort = 1819;

  /// The SOCKS listener device traffic goes through: the hop's own listener
  /// in chain mode, else the tunnel's. The core's listener stays on
  /// [_socksPort] (the hop's upstream); everything the *device* uses — the
  /// traffic proof, the system proxy, the TUN bridge — uses this port.
  int _devicePort = 1819;
  bool _bypassLan = true;
  final _bypass = <String>{};
  final _lanBypass = <String>[];
  final _rangeRoutes = <String>[];
  String _runDir = '';

  /// The core's own traffic counters, parsed from its `--stats` line
  /// (`[=] up 1.2 MiB down 8.0 MiB uptime 00:01:31`). Windows has no bridge
  /// stats API, so this is the only byte source the dashboard has there.
  int downloadBytes = 0;
  int uploadBytes = 0;

  /// WinTUN adapter name we ask for. Windows may hand back "Voidrau 2" when a
  /// stale interface of that name is still registered, so the *real* name and
  /// index are discovered after the bridge starts and used from then on.
  static const String adapterBase = 'Voidrau';

  /// Adapter names used by earlier builds; cleaned up during network recovery so
  /// an upgraded install never leaves a dead interface behind.
  static const List<String> legacyAdapterBases = ['Nimbus', 'VoidrauVPN'];
  static const String tunIp = '198.18.0.1';
  static const String tunMask = '255.255.255.252';

  // Diagnostics: what the device VPN is actually running on, and — when it is
  // not — exactly why. Shown on the Diagnostics page.
  String tunBackend = '';
  String tunAdapter = '';
  int tunIndex = -1;
  String tunError = '';
  bool? _elevated;
  WindowsBuild _winBuild = WindowsBuild.unknown;
  final _tunTail = <String>[];
  int? _tunExit;
  List<String>? _defaultRouteDelete;

  /// The machine has a global IPv6 default route (detected per start).
  /// When true, TUN mode must capture or block IPv6 — an IPv4-only TUN
  /// leaves dual-stack traffic on the physical line while every IPv4
  /// probe stays green.
  bool _hasIpv6Default = false;

  /// We installed a `::/0` route via the TUN adapter this session and
  /// owe its removal on teardown.
  bool _ipv6RouteInstalled = false;

  /// Kill switch ("Fail closed"): armed from settings at start; engaged
  /// when the tunnel drops unexpectedly, disengaged on a proven
  /// reconnect, a user disconnect, or the startup sweep. See
  /// `windows_killswitch.dart`.
  WindowsKillSwitch? _ks;
  bool _killSwitchEnabled = false;

  /// True while [stop] is tearing down on purpose — the process-exit
  /// handlers must not mistake our own teardown for a tunnel drop and
  /// engage the kill switch against a user disconnect.
  bool _stopping = false;

  /// HEV mapdns is active for this session (hev bridge + chain hop):
  /// adapter DNS is the mapdns listener and the fake-IP network is
  /// routed into the TUN. See [HevConfig].
  bool _mapDnsActive = false;

  /// We installed the mapdns fake-IP route (`240.0.0.0/4`) this session
  /// and owe its removal on teardown.
  bool _fakeIpRoute = false;

  /// Extra upstream IPs to bypass before the default route goes in —
  /// the Xray path's worker/WARP endpoints, whose dials must not enter
  /// the TUN they feed. Empty on the Aether path.
  List<String> _extraBypassIps = const [];

  WindowsKillSwitch get _killSwitch => _ks ??=
      WindowsKillSwitch(stateDir: runtimeDir, onLog: _logLine);

  Stream<String> get logs => _logs.stream;

  Map<String, dynamic> statusMap() => {
        'phase': phase.name,
        'message': message,
        'endpoint': endpoint,
        'protocol': protocol,
        'tunBackend': tunBackend,
        'download': downloadBytes,
        'upload': uploadBytes,
      };

  /// Elevation cannot change for the lifetime of a process, so the (cheap but
  /// still process-spawning) check runs once.
  ///
  /// It reads the integrity level from `whoami /groups` instead of `net
  /// session`: `net session` fails on any PC where the LanmanServer service is
  /// stopped or disabled, which used to make VoidrauVPN tell a real Administrator
  /// to "restart as Administrator" forever.
  Future<bool> isAdmin() async {
    final cached = _elevated;
    if (cached != null) return cached;
    final elevated = await Elevation.check();
    _elevated = elevated;
    return elevated;
  }

  /// Windows version, detected once (registry, `cmd /c ver` as fallback).
  Future<WindowsBuild> windowsBuild() async {
    if (!_winBuild.isKnown) _winBuild = await WindowsBuild.detect();
    return _winBuild;
  }

  /// Diagnostics snapshot for the UI.
  Map<String, String> tunInfo() => {
        'elevated': '${_elevated ?? false}',
        'windows': _winBuild.label,
        'backend': tunBackend.isEmpty ? '—' : tunBackend,
        'adapter': tunAdapter.isEmpty ? '—' : '$tunAdapter (#$tunIndex)',
        'error': tunError.isEmpty ? '—' : tunError,
      };

  /// Relaunches VoidrauVPN through the UAC prompt and closes this instance, so
  /// "run as Administrator for full VPN" is one tap instead of: find the exe,
  /// close the app, right-click, run as administrator, connect again.
  Future<bool> restartElevated() async {
    final exe = Platform.resolvedExecutable;
    final script = "Start-Process -FilePath '${exe.replaceAll("'", "''")}' -Verb RunAs";
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ]);
      if (r.exitCode != 0) {
        _logLine('elevation refused or failed: ${r.stderr}'.trim());
        return false;
      }
    } catch (e) {
      _logLine('elevation refused or failed: $e');
      return false;
    }
    // The elevated instance is coming up: leave the network exactly as we
    // found it and get out of its way (it needs the SOCKS port).
    await stop();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    exit(0);
  }

  /// Per-user writable working directory for the core. The identity files
  /// (aether.toml, aether-masque.toml, lastconn) must live here: writing them
  /// next to the exe under Program Files fails for non-admin users and the
  /// core then dies on startup — the classic "connect spins forever".
  String get runtimeDir {
    if (_runDir.isNotEmpty) return _runDir;
    final base = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    final dir = Directory(p.join(base, 'VoidrauVPN'));
    dir.createSync(recursive: true);
    _runDir = dir.path;
    return _runDir;
  }

  Future<void> start(VpnSettings settings, {Protocol? protocol}) async {
    _killSwitchEnabled = settings.killSwitch;
    _extraBypassIps = const [];
    // A restart during recovery keeps the kill-switch block (and the
    // system proxy) in place: tearing capture down first is exactly the
    // leak window the kill switch exists to close. A fresh connect with
    // nothing engaged is unaffected either way.
    await stop(keepBlock: settings.killSwitch);
    final proto = protocol ?? settings.protocol;
    final protoName = proto == Protocol.smart ? 'masque' : proto.name;
    this.protocol = protoName;
    lastError = '';
    phase = EnginePhase.scanning;
    message = 'Starting tunnel core';
    _emit();

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final coreFile = File(p.join(exeDir, 'aether.exe'));
    if (!coreFile.existsSync()) {
      // Fall back to the sidecar directory used in development.
      final sidecar = File(p.join(Directory.current.path, 'third_party',
          'windows', 'aether.exe'));
      if (!sidecar.existsSync()) {
        throw FileSystemException('aether.exe not found', coreFile.path);
      }
    }

    _socksPort = settings.socksPort;
    _devicePort = settings.devicePort;
    _bypassLan = settings.bypassLan;
    downloadBytes = 0;
    uploadBytes = 0;
    _bypass.clear();
    _lanBypass.clear();
    _rangeRoutes.clear();

    final env = CoreLaunch.environment(
      settings,
      override: proto,
      configPath: p.join(runtimeDir, 'aether.toml'),
    );
    // Psiphon/Tor helper binaries: fetch_cores.sh stages them in pt/ beside
    // aether.exe. The core finds ./pt on its own only when its working
    // directory is the exe dir — ours is runtimeDir — so point at them
    // explicitly when they are there. Without them Psiphon dies at startup
    // and Tor can only use plain bridges.
    final ptDir = coreFile.existsSync()
        ? p.join(exeDir, 'pt')
        : p.join(Directory.current.path, 'third_party', 'windows', 'pt');
    final psiphonBin = File(p.join(ptDir, 'psiphon-tunnel-core.exe'));
    if (psiphonBin.existsSync()) {
      env['AETHER_PSIPHON_BIN'] = psiphonBin.path;
    }
    final lyrebirdBin = File(p.join(ptDir, 'lyrebird.exe'));
    if (lyrebirdBin.existsSync()) {
      env['AETHER_TOR_PT'] = 'obfs4=${lyrebirdBin.path}';
      env['AETHER_TOR_PT_DIR'] = ptDir;
    }
    final corePath = coreFile.existsSync()
        ? coreFile.path
        : p.join(Directory.current.path, 'third_party', 'windows',
            'aether.exe');
    // Heal a machine already stuck with an orphaned helper (crash,
    // force-close, or an older build): a leftover psiphon holds the
    // BoltDB datastore lock in runtimeDir and the new core's psiphon
    // would time out opening it. stop() above only knows about *this*
    // process's core; the sweep is path-scoped to this install.
    await _sweepLeftoverHelpers();
    _coreExited = false;
    _core = await Process.start(
      corePath,
      const [], // env-only configuration (the core's contract)
      workingDirectory: runtimeDir,
      environment: {...Platform.environment, ...env},
    );
    _core!.stdout.transform(utf8.decoder).listen(_onLog);
    _core!.stderr.transform(utf8.decoder).listen(_onLog);
    _core!.exitCode.then((code) {
      _coreExited = true;
      if (phase == EnginePhase.connected ||
          phase == EnginePhase.connecting ||
          phase == EnginePhase.scanning) {
        phase = EnginePhase.error;
        message = lastError.isEmpty ? 'Tunnel core exited ($code)' : lastError;
        _emit();
        // Unexpected drop: block device traffic until the watchdog's
        // reconnect proves capture again (or the user disconnects).
        unawaited(engageKillSwitch());
      }
    });

    // A standalone Psiphon/Tor mode or a reverse hop is a slow starter
    // (Psiphon gets up to 180 s, Tor's bootstrap plus bridges a minute or
    // two); the plain 90 s SOCKS wait would cut it off mid-bootstrap.
    final slowHop = CoreLaunch.isSlowHop(settings);
    final ready = await _waitSocks(
        slowHop ? const Duration(seconds: 240) : const Duration(seconds: 90));
    if (!ready) {
      lastError = lastError.isEmpty
          ? 'SOCKS5 listener did not start (gateway scan found nothing)'
          : lastError;
      phase = EnginePhase.error;
      message = lastError;
      _emit();
      await stop(keepBlock: _killSwitchEnabled);
      return;
    }

    // Proving traffic is the difference between "connected" and "the core
    // opened a listener for a tunnel that carries nothing" (the reference
    // proven-data-plane gate). In chain mode the proof goes through the
    // HOP's listener: the tunnel alone proves nothing about the device
    // path, and a hop that never serves must fail the connect here — with
    // its own name on the error — instead of publishing "connected" on a
    // WARP exit.
    phase = EnginePhase.connecting;
    message = 'Verifying the tunnel';
    _emit();
    try {
      // A slow hop needs more than the default two 10 s probes: its first
      // traffic can legitimately take minutes.
      await SocksProbe.prove(
        port: _devicePort,
        attempts: slowHop ? 6 : 2,
        timeout: slowHop
            ? const Duration(seconds: 30)
            : const Duration(seconds: 10),
      );
    } catch (e) {
      // The core's listener already answered (_waitSocks passed), so in
      // chain mode a failed proof means the hop never served — not a dead
      // tunnel. Name it, so the user does not retry the wrong thing.
      final chainHop = CoreLaunch.isChainHop(settings);
      lastError = chainHop
          ? '${CoreLaunch.isPsiphon(settings) ? 'Psiphon' : 'Tor'} second hop did not start in time'
          : 'tunnel carries no traffic';
      phase = EnginePhase.error;
      message = chainHop ? lastError : '$e';
      _emit();
      await stop(keepBlock: _killSwitchEnabled);
      return;
    }

    await _capture(settings, exeDir);
  }

  /// Device capture for a SOCKS5 listener that is already proven — the
  /// Xray-on-Windows path (`XrayEngine` spawns xray.exe, the controller
  /// proves its SOCKS, then this puts the WinTUN/proxy capture in front
  /// of it). Xray serves device traffic on its own SOCKS port, so the
  /// device port is the SOCKS port here (no hop listener exists).
  Future<void> startCaptureOnly(VpnSettings settings) async {
    _killSwitchEnabled = settings.killSwitch;
    _socksPort = settings.socksPort;
    _devicePort = settings.socksPort;
    _bypassLan = settings.bypassLan;
    _extraBypassIps = await _resolveBypassIps(settings);
    phase = EnginePhase.connecting;
    message = 'Verifying the tunnel';
    _emit();
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    // Serverless dials direct by design (freedom outbound): behind a TUN
    // its own sockets would loop back into itself, because Windows has
    // no per-process tunnel exclusion like Android's UID rule. Proxy
    // capture is the honest equivalent — apps ride the SOCKS, Xray's
    // own dials stay direct.
    final forceProxy = settings.xrayMode == XrayMode.serverless &&
        settings.mode == ConnectionMode.vpn;
    if (forceProxy) {
      _logLine('Xray serverless on Windows uses proxy capture — a TUN '
          'would loop its direct dials back into itself');
    }
    await _capture(settings, exeDir, forceProxy: forceProxy);
  }

  /// Upstream IPs the Xray core will dial that must bypass the TUN:
  /// the worker domain's addresses (Worker mode) and the WARP endpoint
  /// IPs (WARP mode). Resolved with the system resolver at connect
  /// time; Cloudflare anycast answers are stable per-PoP in practice.
  Future<List<String>> _resolveBypassIps(VpnSettings settings) async {
    final ips = <String>{};
    if (settings.xrayMode == XrayMode.worker) {
      final domain = settings.workerDomain.trim();
      if (domain.isNotEmpty) {
        try {
          for (final a in await InternetAddress.lookup(domain)) {
            if (a.type == InternetAddressType.IPv4) ips.add(a.address);
          }
        } catch (e) {
          _logLine('xray worker resolve failed ($domain): $e');
        }
      }
    }
    if (settings.xrayMode == XrayMode.warp) {
      final ipRe = RegExp(r'(\d{1,3}(?:\.\d{1,3}){3})');
      for (final ep in settings.warpEndpoints) {
        final m = ipRe.firstMatch(ep);
        if (m != null) ips.add(m.group(1)!);
      }
    }
    if (ips.isNotEmpty) {
      _logLine('xray upstreams bypass the TUN: ${ips.join(', ')}');
    }
    return ips.toList();
  }

  /// The capture half of a connect, shared by the Aether path ([start],
  /// after its SOCKS proof) and the Xray path ([startCaptureOnly]):
  /// system-proxy snapshot, then proxy mode, the non-elevated proxy
  /// fallback, or the full WinTUN device VPN with its egress gate.
  ///
  /// The tunnel is proven. From here on the Windows system proxy follows
  /// the app's on/off state: snapshot whatever the user had, then take it
  /// (proxy mode) or give it back (device VPN — with a stale manual proxy
  /// active, WinINET apps would shortcut the tunnel through the raw SOCKS
  /// listener, so a full device VPN must run proxy-free).
  Future<void> _capture(VpnSettings settings, String exeDir,
      {bool forceProxy = false}) async {
    final proxy = WindowsSystemProxy.instance;
    await proxy.rememberOriginal();

    _hasIpv6Default = await _detectIpv6Default();
    if (_hasIpv6Default) {
      _logLine('IPv6 default route present on this machine');
    }

    if (settings.mode == ConnectionMode.proxy || forceProxy) {
      final proxyOk = await proxy.enableOurs(_devicePort);
      if (_hasIpv6Default) {
        _logLine('IPv6 default route present — proxy mode does not '
            'capture IPv6; use device VPN mode for full capture');
      }
      // Capture verified: the recovery block (if any) has done its job.
      if (proxyOk) await _killSwitch.disengage();
      phase = EnginePhase.connected;
      // The SOCKS listener itself is proven (prove() above), so proxy
      // mode stays connected even when the system-proxy write fails —
      // but the message must not claim a capture that never landed.
      message = proxyOk
          ? 'SOCKS5 127.0.0.1:$_devicePort — system proxy on'
          : 'SOCKS5 127.0.0.1:$_devicePort — system proxy could not be '
              'set; point apps at it manually';
      if (!proxyOk) tunError = 'system proxy could not be set';
      _emit();
      return;
    }

    final admin = await isAdmin();
    final win = await windowsBuild();
    if (!admin) {
      // Honest degradation: no TUN without elevation, so the system proxy
      // is what keeps the machine tunneled. Tell the user exactly what to
      // do instead of silently lying about a TUN.
      tunError = 'not running as Administrator — WinTUN needs elevation';
      await _proxyFallback(
        message:
            'SOCKS5 127.0.0.1:$_devicePort (system proxy) — tap "Run as Administrator" for full device VPN',
      );
      return;
    }
    final directRules =
        SplitRules.coreDirectEntries(settings, windows: true);
    final dropped = SplitRules.normalize(settings.routeDirect).length -
        directRules.length;
    if (dropped > 0) {
      _logLine(
          'split tunneling: $dropped name-based rule(s) are Android-only — '
          'Windows needs an address (a route cannot name a domain)');
    }
    if (directRules.isNotEmpty) {
      _logLine('split tunneling: direct ${directRules.join(', ')}');
    }

    // The line's own address, measured before any capture exists: the
    // reference the egress gate below compares the device path against.
    // Best effort — a filtered line may not answer a direct probe at
    // all, and the gate then requires an exact match with the tunnel
    // exit instead of the not-the-raw-line test.
    String? rawIp;
    try {
      rawIp = (await SocksProbe.rawInfo()).ip;
      _logLine('raw line address: $rawIp');
    } catch (_) {}

    final ok = await _startTun(exeDir, settings);
    if (!ok) {
      await _proxyFallback(
        message: lastError.isEmpty
            ? 'SOCKS5 127.0.0.1:$_devicePort (device VPN unavailable, system proxy on)'
            : '$lastError — system proxy on',
      );
      return;
    }
    // Full device tunnel: every app rides the TUN adapter directly, so the
    // system proxy goes back to off — no proxy to set, everything through
    // the VPN device.
    if (!await proxy.clearOurs()) {
      _logLine('warning: could not clear the system proxy — WinINET apps '
          'may shortcut the TUN through a stale proxy');
    }
    // Routes now point into the TUN, so capture no longer depends on the
    // firewall block — and the egress probe below must not be filtered
    // by it. Disengage; a gate failure re-engages before the fallback.
    await _killSwitch.disengage();

    // Egress gate: an adapter that exists and a default route that is
    // installed are not the same thing as traffic that leaves through the
    // tunnel. A TUN whose default route loses the metric race (or points
    // nowhere) keeps every SOCKS probe green while the machine's own
    // traffic goes direct — the UI shows the tunnel exit, every site
    // shows the user's real IP. So measure the egress of the device path
    // itself and compare it with the tunnel exit and the raw line address
    // before claiming a system VPN. A leak (or an unverifiable egress)
    // tears the TUN down and degrades to the verified system proxy
    // instead of publishing "connected" over an uncaptured machine.
    String? tunFail;
    String deviceIp = '';
    try {
      deviceIp = (await SocksProbe.deviceExit()).ip;
    } catch (e) {
      tunFail = 'adapter came up but carried no traffic: $e';
    }
    if (tunFail == null) {
      String? tunnelIp;
      try {
        tunnelIp = (await SocksProbe.exitInfo(port: _devicePort)).ip;
      } catch (_) {}
      final verdict = EgressCheck.evaluate(
          deviceIp: deviceIp, tunnelIp: tunnelIp, rawIp: rawIp);
      _logLine('device egress $deviceIp, tunnel exit ${tunnelIp ?? '?'}, '
          'raw line ${rawIp ?? '?'} → $verdict');
      if (!EgressCheck.ok(verdict)) {
        _logLine(
            'default routes: ${_defaultRouteSnapshot(await _routeTable())}');
        tunFail = verdict == EgressVerdict.leaked
            ? 'device traffic bypasses the tunnel '
                '(egress $deviceIp is the raw line address)'
            : 'device egress could not be verified (egress $deviceIp)';
      }
    }
    if (tunFail != null) {
      _logLine('device VPN egress gate failed: $tunFail');
      await _removeRoutes();
      await _killTun();
      await _awaitAdapterGone();
      tunBackend = '';
      tunError = tunFail;
      // The TUN is gone and nothing captures yet: if the kill switch is
      // armed, block again until the proxy fallback lands (it disengages
      // on success).
      if (_killSwitchEnabled) await engageKillSwitch();
      await _proxyFallback(
        message:
            'device VPN did not carry traffic on ${win.label} — SOCKS5 system proxy on',
      );
      return;
    }

    phase = EnginePhase.connected;
    message = 'System VPN active — $tunBackend';
    _emit();
  }

  /// The honest degradation when no TUN captures the device: the system
  /// proxy, *verified*. When even that cannot be set, nothing captures
  /// traffic — claiming "connected" then is exactly the leak where every
  /// site shows the user's real IP under a green UI — so the connect
  /// fails loudly instead of publishing a capture that never landed.
  Future<void> _proxyFallback({required String message}) async {
    if (_hasIpv6Default) {
      _logLine('IPv6 default route present — the system proxy does not '
          'capture IPv6; run as Administrator for full device VPN');
    }
    final proxyOk = await WindowsSystemProxy.instance.enableOurs(_devicePort);
    if (!proxyOk) {
      lastError = 'could not set the system proxy — traffic is not protected';
      tunError = lastError;
      phase = EnginePhase.error;
      this.message = lastError;
      _emit();
      await stop(keepBlock: _killSwitchEnabled);
      return;
    }
    // The verified proxy captures WinINET traffic again — recovery over.
    await _killSwitch.disengage();
    phase = EnginePhase.connected;
    this.message = message;
    _emit();
  }

  /// Tears the session down. [keepBlock] is the recovery variant: the
  /// kill-switch block (and a system proxy still pointing at the dead
  /// listener) stay in place so traffic cannot leak direct while the
  /// watchdog re-dials — the next proven capture disengages them. A
  /// user disconnect always passes false.
  Future<void> stop({bool keepBlock = false}) async {
    _stopping = true;
    if (phase == EnginePhase.connected ||
        phase == EnginePhase.connecting ||
        phase == EnginePhase.scanning ||
        phase == EnginePhase.reconnecting) {
      phase = EnginePhase.disconnecting;
      _emit();
    }
    final core = _core;
    _core = null;

    // Routes go first: while the default route still points at the TUN,
    // killing the bridge would leave the machine with no way out at all.
    await _removeRoutes(forgetUpstreams: true);
    await _killTun();
    // Kill the core *and its helpers*. Dart's kill reaches only the core
    // process itself; the psiphon/lyrebird children it spawned would
    // orphan and keep the BoltDB datastore lock in runtimeDir, breaking
    // every later launch ("psiphon stopped before it was ready"). So:
    // graceful signal first, a short wait for a cooperative exit, then a
    // tree-kill while the parent is still there to walk, then the
    // path-scoped sweep for anything already orphaned.
    try {
      core?.kill(ProcessSignal.sigterm);
    } catch (_) {}
    if (core != null) {
      try {
        await core.exitCode.timeout(const Duration(milliseconds: 800));
      } catch (_) {}
      try {
        await Process.run('taskkill', ProcessSweep.taskkillArgs(core.pid));
      } catch (e) {
        _logLine('core tree-kill failed: $e');
      }
      try {
        core.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
    await _sweepLeftoverHelpers();
    await _awaitAdapterGone();
    if (!keepBlock) {
      // User disconnect (or recovery): the block has served its purpose.
      await _killSwitch.disengage();
      // Disconnect means proxy flow stops too: hand the system proxy back to
      // whatever it was before VoidrauVPN, so the machine is left direct (or with
      // the user's own proxy) instead of pointing at a dead listener.
      await WindowsSystemProxy.instance.restore(ourPort: _devicePort);
    }
    // keepBlock: the proxy stays pointed at the dead listener on purpose —
    // WinINET apps fail closed while the watchdog re-dials, exactly like
    // Android's TUN staying up across core restarts.
    _mapDnsActive = false;
    tunBackend = '';
    tunAdapter = '';
    tunIndex = -1;
    phase = EnginePhase.disconnected;
    message = '';
    endpoint = '';
    _stopping = false;
    _emit();
  }

  /// Engages the kill-switch block when armed. Needs Administrator —
  /// in TUN mode the process is elevated by definition; without it the
  /// block cannot be installed and the log says so (proxy mode still
  /// fails closed for WinINET apps via the dead listener).
  Future<void> engageKillSwitch() async {
    if (!_killSwitchEnabled || _stopping) return;
    if (!await isAdmin()) {
      _logLine('kill switch: needs Administrator — traffic is NOT '
          'firewall-blocked (proxy capture only)');
      return;
    }
    await _killSwitch.engage(_killSwitchExePaths());
  }

  /// Executables the kill switch lets through so the tunnel can
  /// re-dial while everything else is blocked: this install's cores
  /// (the same path-scoped list the orphan sweep uses).
  List<String> _killSwitchExePaths() => _helperExePaths();

  /// Startup / recovery sweep for a kill-switch block left behind by a
  /// hard-killed run (see [WindowsKillSwitch.sweep]).
  Future<void> sweepKillSwitch() => _killSwitch.sweep();

  /// Full paths of this install's core and pt helpers — the exact
  /// executables the orphan sweep may stop. Mirrors the resolution in
  /// [start] (installed layout first, dev sidecar as fallback).
  List<String> _helperExePaths() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final installed = File(p.join(exeDir, 'aether.exe')).existsSync();
    final corePath = installed
        ? p.join(exeDir, 'aether.exe')
        : p.join(
            Directory.current.path, 'third_party', 'windows', 'aether.exe');
    final ptDir = installed
        ? p.join(exeDir, 'pt')
        : p.join(Directory.current.path, 'third_party', 'windows', 'pt');
    return [
      corePath,
      p.join(ptDir, 'psiphon-tunnel-core.exe'),
      p.join(ptDir, 'lyrebird.exe'),
      // The Xray core is a sibling sidecar: an orphaned xray.exe would
      // hold the SOCKS port against the next launch exactly like an
      // orphaned psiphon holds its datastore.
      installed
          ? p.join(exeDir, 'xray.exe')
          : p.join(Directory.current.path, 'third_party', 'windows',
              'xray.exe'),
    ];
  }

  /// Stops leftover core/helper processes from *this* install whose
  /// parent is already gone (crash, force-close, or an older build's
  /// orphan). An orphaned psiphon keeps the BoltDB datastore lock in
  /// [runtimeDir], so without this sweep every later launch dies with
  /// "psiphon stopped before it was ready". Path-scoped only (see
  /// [ProcessSweep]); every failure is logged, never thrown.
  Future<void> _sweepLeftoverHelpers() async {
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        ProcessSweep.sweepScript(_helperExePaths()),
      ]);
      final out = '${r.stdout}'.trim();
      if (out.isNotEmpty) {
        for (final line in out.split('\n')) {
          _logLine('leftover helper stopped: ${line.trim()}');
        }
      }
      if (r.exitCode != 0) {
        _logLine('helper sweep exited ${r.exitCode}: ${r.stderr}'.trim());
      }
    } catch (e) {
      _logLine('helper sweep failed: $e');
    }
  }

  /// Terminates the TUN bridge. The WinTUN adapter is owned by the process, so
  /// closing it removes the adapter — no `netsh ... admin=disable` needed (that
  /// is what left a stale "Voidrau" interface behind and made the next session
  /// land on "Voidrau 2").
  Future<void> _killTun() async {
    final tun = _tun;
    _tun = null;
    _tunExit = null;
    if (tun == null) return;
    try {
      tun.kill(ProcessSignal.sigterm);
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 400));
    try {
      tun.kill(ProcessSignal.sigkill);
    } catch (_) {}
    try {
      await tun.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// Confirms the adapter is really gone, so the next connect can reuse the
  /// name "Voidrau" instead of being handed "Voidrau 2" by Windows.
  Future<void> _awaitAdapterGone() async {
    final name = tunAdapter.isEmpty ? adapterBase : tunAdapter;
    tunAdapter = '';
    tunIndex = -1;
    for (var i = 0; i < 8; i++) {
      final rows = await _interfaces();
      if (Netsh.findAdapter(rows, name) == null) return;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    _logLine('WinTUN adapter "$name" is still registered after the bridge exited');
  }

  Future<List<NetInterface>> _interfaces() async {
    try {
      final r = await Process.run(
          'netsh', ['interface', 'ipv4', 'show', 'interfaces']);
      return Netsh.parseInterfaces('${r.stdout}');
    } catch (_) {
      return const [];
    }
  }

  Future<void> recover() async {
    await stop();
    await Process.run('ipconfig', ['/flushdns']);
    // A run that was hard-killed can leave the adapter registered. Only then
    // do we take it down — by index, because the name may be "Voidrau 2".
    final live = await _interfaces();
    final stale = Netsh.findAdapter(live, adapterBase) ??
        legacyAdapterBases
            .map((legacy) => Netsh.findAdapter(live, legacy))
            .firstWhere((a) => a != null, orElse: () => null);
    if (stale != null) {
      _logLine('removing leftover adapter ${stale.name} (#${stale.index})');
      await Process.run('netsh',
          ['interface', 'set', 'interface', '${stale.index}', 'admin=disable']);
    }
  }

  bool _coreExited = false;

  /// Waits for the SOCKS5 listener to answer a real method-selection
  /// greeting, failing fast when the core exits (bad flags, unwritable
  /// identity path, no route) instead of hanging the whole budget.
  Future<bool> _waitSocks(Duration budget) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      if (_core == null || _coreExited) return false;
      final ok = await SocksProbe.handshake(
          port: _socksPort, timeout: const Duration(seconds: 2));
      if (ok) return true;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return false;
  }

  void _onLog(String chunk) {
    for (final line in chunk.split(RegExp(r'\r?\n'))) {
      if (line.trim().isEmpty) continue;
      _logs.add(line);
      final ip = _extractIp(line);
      if (ip != null) {
        endpoint = ip;
        _bypass.add(ip);
      }
      final counters = CoreStats.parse(line);
      if (counters != null) {
        downloadBytes = counters.downBytes;
        uploadBytes = counters.upBytes;
      }
      final lower = line.toLowerCase();
      if (lower.contains('error') ||
          lower.contains('failed') ||
          lower.contains('refused')) {
        lastError = line;
      }
      if (lower.contains('scan') ||
          lower.contains('hunting') ||
          lower.contains('identity ready')) {
        // Never demote an error state: a buffered "scan" line after a core
        // exit must not hide the failure (endless-spinner regression).
        if (phase != EnginePhase.connected && phase != EnginePhase.error) {
          phase = EnginePhase.scanning;
        }
      }
      if (lower.contains('reconnect')) {
        // Guarded like the other transitions: any log line merely *containing*
        // the word must not demote a fully connected (or failed) tunnel.
        if (phase != EnginePhase.connected && phase != EnginePhase.error) {
          phase = EnginePhase.reconnecting;
        }
      }
      if (lower.contains('validated') || lower.contains('handshake')) {
        if (phase != EnginePhase.connected && phase != EnginePhase.error) {
          phase = EnginePhase.connecting;
        }
      }
      _emit();
    }
  }

  static final _ipRe = RegExp(r'\b(\d{1,3}(?:\.\d{1,3}){3})(?::\d+)?\b');

  String? _extractIp(String line) {
    if (!RegExp(r'peer|endpoint|gateway|connected|using', caseSensitive: false)
        .hasMatch(line)) {
      return null;
    }
    final m = _ipRe.firstMatch(line);
    if (m == null) return null;
    final ip = m.group(1)!;
    if (ip.startsWith('127.') || ip.startsWith('198.18.') || ip == '0.0.0.0') {
      return null;
    }
    return ip;
  }

  Future<void> _captureGateway() async {
    final r = await Process.run('route', ['print']);
    // Never capture our own tunnel address: after a crash the default route can
    // still point at 198.18.0.1, and "bypass the upstream through that" is a
    // routing loop with no way out.
    final gw = Netsh.parseGateway('${r.stdout}', ignore: tunIp);
    if (gw != null) _originalGw = gw;
  }

  /// Brings up the WinTUN device: pick a bridge that can actually run on this
  /// Windows, wait for the adapter, then configure address, DNS and routes.
  ///
  /// The old version hard-coded one bridge (`tun2socks.exe`) and one failure
  /// sentence ("WinTUN adapter never appeared"). That message hid the two
  /// reasons it really happens: the bridge process died on the spot (a Go
  /// build that needs Windows 10+, or a GOAMD64=v3 build that needs an AVX2
  /// CPU), or Windows registered the adapter under a different name. Both are
  /// now detected, reported and — where possible — retried with another bridge.
  Future<bool> _startTun(String dir, VpnSettings settings) async {
    final win = await windowsBuild();
    await _captureGateway();
    tunBackend = '';
    tunAdapter = '';
    tunIndex = -1;
    tunError = '';
    _mapDnsActive = false;

    // The installed layout keeps every bridge next to `voidrauvpn.exe`; a
    // development run keeps them in `third_party/windows`.
    final dirs = <String>[
      dir,
      p.join(Directory.current.path, 'third_party', 'windows'),
    ];
    File? find(String name) {
      for (final d in dirs) {
        final f = File(p.join(d, name));
        if (f.existsSync()) return f;
      }
      return null;
    }

    final wintun = find('wintun.dll');
    final bridges = <TunBackend, File>{
      for (final b in TunBackend.values)
        if (find(b.fileName) != null) b: find(b.fileName)!,
    };
    final missing = <String>[
      if (wintun == null) 'wintun.dll',
      ...TunBackend.values
          .where((b) => !bridges.containsKey(b))
          .map((b) => b.fileName),
    ];
    if (wintun == null || bridges.isEmpty) {
      lastError = 'device VPN files missing (${missing.join(', ')}) — '
          'reinstall VoidrauVPN; running SOCKS5 only';
      tunError = lastError;
      _logLine(lastError);
      return false;
    }
    if (missing.isNotEmpty) {
      _logLine('device VPN: not installed → ${missing.join(', ')}');
    }

    final failures = <TunFailure>[];
    // A chain hop (Psiphon/Tor last) makes the device egress TCP-only:
    // only hev's mapdns can carry DNS there, so hev goes first.
    final chainHop = CoreLaunch.isChainHop(settings);
    for (final backend in TunPlan.order(
        build: win, available: bridges.keys, preferMapDns: chainHop)) {
      _logLine('device VPN: trying ${backend.label} on ${win.label}');
      final attempt =
          await _tryTun(backend, bridges[backend]!, wintun, settings);
      if (attempt.ok) {
        tunBackend = backend.label;
        _logLine(
            'device VPN: $backend.label up on "$tunAdapter" (#$tunIndex)');
        return true;
      }
      failures.add(TunFailure(backend, attempt.reason));
      _logLine('device VPN: ${backend.label} failed — ${attempt.reason}');
      await _removeRoutes();
      await _killTun();
      await _awaitAdapterGone();
      // A netsh/route refusal is not this bridge's fault: no other bridge will
      // get past it either, so stop instead of burning another 20 s.
      if (attempt.fatal) break;
    }

    final why = failures.map((f) => '$f').join(' | ');
    lastError = 'device VPN unavailable (${win.label}) — $why';
    tunError = lastError;
    return false;
  }

  Future<_TunAttempt> _tryTun(
    TunBackend backend,
    File exe,
    File wintun,
    VpnSettings settings,
  ) async {
    _tunTail.clear();
    _tunExit = null;

    // Every bridge loads wintun.dll from its own directory, and the MSYS build
    // of hev also needs msys-2.0.dll there. Fail fast with a reason the user
    // can act on instead of waiting 20 s for an adapter that cannot appear.
    final here = exe.parent.path;
    final localWintun = File(p.join(here, 'wintun.dll'));
    if (!localWintun.existsSync()) {
      try {
        wintun.copySync(localWintun.path);
      } catch (e) {
        return _TunAttempt.fail('wintun.dll is not next to ${exe.path}: $e');
      }
    }
    if (backend == TunBackend.hev &&
        !File(p.join(here, 'msys-2.0.dll')).existsSync()) {
      return _TunAttempt.fail(
          'msys-2.0.dll is missing next to ${exe.path} (MSYS runtime)');
    }

    final List<String> args;
    if (backend == TunBackend.hev) {
      // hev is configured by a YAML file. It creates the WinTUN adapter named
      // below and sets the MTU; address, DNS and routes stay ours so that both
      // bridges are configured identically.
      final cfg = File(p.join(runtimeDir, 'hev.yml'));
      try {
        await cfg.writeAsString(HevConfig.yaml(
          adapterName: adapterBase,
          mtu: settings.deviceMtu,
          socksPort: _devicePort,
          ipv6: settings.ipv6Tunnel,
          mapDns: CoreLaunch.isChainHop(settings),
          logLevel: settings.logLevel,
          fast: settings.perfToken == 'high',
        ));
      } catch (e) {
        return _TunAttempt.fail('cannot write ${cfg.path}: $e');
      }
      args = [cfg.path];
    } else {
      args = [
        '-device',
        'tun://$adapterBase',
        '-proxy',
        'socks5://127.0.0.1:$_devicePort',
        '-loglevel',
        'info',
      ];
      // The Go bridge's gVisor stack keeps a fixed, small TCP window unless it
      // is told otherwise, and a fixed window divided by the round trip is the
      // ceiling on every download. Auto-tuning lets the stack grow the window
      // while the connection can use it and keeps memory small when it cannot —
      // a floor *and* a ceiling fix, for one flag.
      if (settings.perfToken == 'high') {
        args.addAll([
          // Receive windows grow with what the connection can use...
          '-tcp-auto-tuning=true',
          // ...and the send buffer (uploads) starts at 1 MiB instead of the
          // netstack default, which is what a high round trip makes small.
          '-tcp-sndbuf=1MiB',
        ]);
      }
    }

    try {
      _tun = await Process.start(exe.path, args, workingDirectory: here);
    } catch (e) {
      return _TunAttempt.fail('cannot start ${exe.path}: $e');
    }
    final proc = _tun!;
    proc.stdout.transform(utf8.decoder).listen(_onTunLog);
    proc.stderr.transform(utf8.decoder).listen(_onTunLog);
    unawaited(proc.exitCode.then((code) {
      // Only this attempt's process may report an exit code: a bridge that is
      // still shutting down from the previous attempt would otherwise make the
      // next one look like it died on the spot.
      if (identical(_tun, proc)) _tunExit = code;
      _onTunLog('${backend.fileName} exited ($code)');
      // A bridge that dies under a live session takes the adapter (and
      // its routes) with it — the machine is direct again. Fail the
      // session loudly and engage the kill switch; the watchdog's
      // reconnect rebuilds capture.
      if (phase == EnginePhase.connected && !_stopping) {
        phase = EnginePhase.error;
        message = 'TUN bridge exited ($code)';
        _emit();
        unawaited(engageKillSwitch());
      }
    }));

    // Wait for the WinTUN adapter to materialise; do not assume 2 seconds, and
    // stop waiting the moment the bridge dies so the real reason survives.
    NetInterface? adapter;
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      adapter = Netsh.findAdapter(await _interfaces(), adapterBase);
      if (adapter != null) break;
      final exit = _tunExit;
      if (exit != null) return _TunAttempt.fail(_exitReason(exit));
    }
    if (adapter == null) {
      final exit = _tunExit;
      if (exit != null) return _TunAttempt.fail(_exitReason(exit));
      final tail = _tunTail.isEmpty ? 'no output' : _tunTail.last;
      return _TunAttempt.fail(
          'WinTUN adapter "$adapterBase" never appeared within 20 s (bridge still running, last: $tail)');
    }
    tunAdapter = adapter.name;
    tunIndex = adapter.index;

    // Hop-DNS: only hev can carry DNS through a TCP-only chain hop
    // (mapdns). The adapter DNS and the fake-IP route below key off
    // this flag; with tun2socks the limit is stated in the log instead
    // of silently shipping dead DNS.
    _mapDnsActive =
        backend == TunBackend.hev && CoreLaunch.isChainHop(settings);
    if (_mapDnsActive) {
      _logLine('DNS via HEV mapdns (TCP-only hop in path)');
    } else if (CoreLaunch.isChainHop(settings)) {
      _logLine('${backend.label} has no mapdns — DNS over UDP cannot '
          'ride the TCP-only hop; the hev bridge is preferred in chain mode');
    }

    final cfg = await _configureAdapter(settings);
    if (cfg != null) return cfg;

    // Upstreams must be bypassed *before* the default route goes in.
    await _bypassUpstreams(settings);
    final route = await _installDefaultRoute();
    if (route != null) {
      return _TunAttempt.fail('default route install failed: $route',
          fatal: true);
    }
    if (_mapDnsActive) {
      // Fake-IP destinations must reach the bridge: 240.0.0.0/4 via the
      // TUN adapter (mirrors Android's addRoute(MAPDNS_NETWORK, 4)).
      final fake = await Process.run('route', [
        'add', HevConfig.mapDnsNetwork, 'mask', HevConfig.mapDnsNetmask,
        tunIp, 'if', '$tunIndex',
      ]);
      if (fake.exitCode == 0) {
        _fakeIpRoute = true;
      } else {
        _logLine('mapdns fake-IP route failed: ${_out(fake)} — '
            'fake-IP destinations will not reach the bridge');
      }
    }
    await _bypassLanRoutes();
    await _bypassDirectRoutes(settings);
    final v6 = await _installIpv6Route(settings);
    if (v6 != null) {
      return _TunAttempt.fail('IPv6 route install failed: $v6', fatal: true);
    }
    return _TunAttempt.success();
  }

  /// Address, MTU and DNS on the adapter. Returns null on success, or the
  /// failure to report. Retried briefly: the adapter is listed by netsh a
  /// moment before it accepts configuration.
  Future<_TunAttempt?> _configureAdapter(VpnSettings settings) async {
    ProcessResult? addr;
    for (var i = 0; i < 4; i++) {
      addr = await _netsh([
        'interface', 'ipv4', 'set', 'address',
        'name=@if@',
        'source=static',
        'addr=$tunIp',
        'mask=$tunMask',
      ]);
      if (addr.exitCode == 0) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (addr == null || addr.exitCode != 0) {
      return _TunAttempt.fail(
          'netsh set address on "$tunAdapter" failed: ${_out(addr)}',
          fatal: true);
    }

    // Best effort: a wrong MTU costs performance, not connectivity.
    final mtu = await _netsh([
      'interface', 'ipv4', 'set', 'subinterface',
      '@if@',
      'mtu=${settings.deviceMtu}',
      'store=persistent',
    ]);
    if (mtu.exitCode != 0) _logLine('netsh set mtu: ${_out(mtu)}');

    // With mapdns active the adapter's only resolver is the bridge's
    // fake-IP listener — a real secondary resolver would answer with
    // real IPs and bypass the domain-name CONNECTs mapdns exists for.
    final dns = await _netsh([
      'interface', 'ipv4', 'set', 'dns', 'name=@if@', 'static',
      _mapDnsActive ? HevConfig.mapDnsAddress : '1.1.1.1',
    ]);
    if (dns.exitCode != 0) _logLine('netsh set dns: ${_out(dns)}');
    if (!_mapDnsActive) {
      final dns2 = await _netsh([
        'interface', 'ipv4', 'add', 'dns',
        'name=@if@',
        '1.0.0.1',
        'index=2',
      ]);
      if (dns2.exitCode != 0) _logLine('netsh add dns: ${_out(dns2)}');
    }
    return null;
  }

  /// Sends a netsh sub-command to the tunnel adapter, trying the interface
  /// index first (digits survive Windows command-line quoting) and the real
  /// adapter name second ("Voidrau 2" contains a space).
  Future<ProcessResult> _netsh(List<String> argv) async {
    ProcessResult? last;
    for (final target in ['$tunIndex', tunAdapter]) {
      if (target.isEmpty || target == '-1') continue;
      last = await Process.run(
          'netsh', argv.map((a) => a.replaceAll('@if@', target)).toList());
      if (last.exitCode == 0) return last;
    }
    return last ?? ProcessResult(0, 1, '', 'netsh was not run');
  }

  static String _out(ProcessResult? r) =>
      r == null ? 'no result' : '${r.stdout}${r.stderr}'.trim();

  /// The full routing table as `route print` prints it — the view every
  /// route verification below relies on. The full form works on every build;
  /// the filtered `route print 0.0.0.0` variant is one moving part we do not
  /// need.
  Future<String> _routeTable() async {
    try {
      final r = await Process.run('route', ['print']);
      return '${r.stdout}';
    } catch (_) {
      return '';
    }
  }

  /// True when the machine has a global IPv6 default route (`route
  /// print -6` shows `::/0`). Best effort: a failure to even ask means
  /// "unknown", treated as absent so a tooling hiccup cannot block a
  /// connect on a machine with no IPv6 to leak.
  Future<bool> _detectIpv6Default() async {
    try {
      final r = await Process.run('route', ['print', '-6']);
      return Netsh.hasIpv6DefaultRoute('${r.stdout}');
    } catch (_) {
      return false;
    }
  }

  /// Captures IPv6 for TUN mode: an on-link `::/0` via the TUN adapter.
  ///
  /// With the IPv6 tunnel setting on, the adapter also gets the `fc00::1`
  /// address the bridge config already names (hev stamps it itself; for
  /// tun2socks netsh does it here, best effort). With the setting off,
  /// the route still goes in — into a bridge with no IPv6 egress — so
  /// IPv6 fails closed inside the tunnel instead of leaking direct while
  /// the UI claims a full device VPN. Returns null on success (or when
  /// there is no IPv6 default to capture), or the failure to report.
  Future<String?> _installIpv6Route(VpnSettings settings) async {
    if (!_hasIpv6Default) return null;
    if (settings.ipv6Tunnel) {
      try {
        await Process.run('netsh', [
          'interface', 'ipv6', 'set', 'address',
          'interface=$tunIndex', 'address=fc00::1',
        ]);
      } catch (_) {}
    }
    try {
      final r = await Process.run('netsh', [
        'interface', 'ipv6', 'add', 'route',
        'prefix=::/0', 'interface=$tunIndex', 'metric=5',
      ]);
      if (r.exitCode != 0) return _out(r);
    } catch (e) {
      return '$e';
    }
    _ipv6RouteInstalled = true;
    _logLine(settings.ipv6Tunnel
        ? 'IPv6 default route → TUN (IPv6 tunnel on)'
        : 'IPv6 default route → TUN (blocked: IPv6 tunnel off, fail closed)');
    return null;
  }

  /// One-line summary of whatever default routes the table currently holds —
  /// what gets appended to a failed install so the next "not in the table"
  /// is diagnosable from the log instead of invisible.
  String _defaultRouteSnapshot(String table) {
    final defaults = Netsh.parseRouteLines(table)
        .where((l) => l.destination == '0.0.0.0' && l.mask == '0.0.0.0')
        .map((l) => '${l.gateway}→${l.interfaceAddress} (m${l.metric})')
        .toList();
    return defaults.isEmpty ? 'no default route at all' : defaults.join(', ');
  }

  /// Installs the default route through the tunnel.
  ///
  /// The accepted form differs per bridge and per Windows: with a /30 on the
  /// adapter the tunnel IP is a valid on-link next hop, while an on-link route
  /// pinned to the interface index (`if <idx>`, gateway 0.0.0.0) is what the
  /// hev bridge documents. Try them in order and remember the winner so
  /// disconnect can remove exactly that route — `route delete 0.0.0.0` without
  /// a next hop would delete the machine's own default route too.
  ///
  /// The verification must not assume the route is printed the way it was
  /// requested: Windows normalizes a gateway that is the adapter's *own*
  /// address into an on-link route, whose Gateway column is a localized word
  /// ("On-link") instead of an IP. A check that only matches IPs reports a
  /// successfully installed route as "not in the table" — which is exactly
  /// how a working Windows 8.1 tunnel turned into "device VPN unavailable".
  Future<String?> _installDefaultRoute() async {
    final attempts = <String>[];
    final candidates = <_RouteForm>[
      _RouteForm(
        ['route', 'add', '0.0.0.0', 'mask', '0.0.0.0', tunIp, 'metric', '5', 'if', '$tunIndex'],
        ['route', 'delete', '0.0.0.0', 'mask', '0.0.0.0', tunIp, 'if', '$tunIndex'],
      ),
      _RouteForm(
        ['route', 'add', '0.0.0.0', 'mask', '0.0.0.0', '0.0.0.0', 'metric', '5', 'if', '$tunIndex'],
        ['route', 'delete', '0.0.0.0', 'mask', '0.0.0.0', '0.0.0.0', 'if', '$tunIndex'],
      ),
      const _RouteForm(
        ['route', 'add', '0.0.0.0', 'mask', '0.0.0.0', tunIp, 'metric', '5'],
        ['route', 'delete', '0.0.0.0', 'mask', '0.0.0.0', tunIp],
      ),
      _RouteForm(
        ['netsh', 'interface', 'ipv4', 'add', 'route', 'prefix=0.0.0.0/0', 'interface=$tunIndex', 'nexthop=$tunIp', 'metric=5'],
        ['netsh', 'interface', 'ipv4', 'delete', 'route', 'prefix=0.0.0.0/0', 'interface=$tunIndex'],
      ),
      _RouteForm(
        ['netsh', 'interface', 'ipv4', 'add', 'route', 'prefix=0.0.0.0/0', 'interface=$tunIndex'],
        ['netsh', 'interface', 'ipv4', 'delete', 'route', 'prefix=0.0.0.0/0', 'interface=$tunIndex'],
      ),
      // Some netsh builds resolve the interface by name where the index
      // comes up short (and a name still resolves when the adapter was
      // handed out as "Voidrau 2" — its index is exactly what we have).
      if (tunAdapter.isNotEmpty) ...[
        _RouteForm(
          ['netsh', 'interface', 'ipv4', 'add', 'route', 'prefix=0.0.0.0/0', 'interface=$tunAdapter', 'nexthop=$tunIp', 'metric=5'],
          ['netsh', 'interface', 'ipv4', 'delete', 'route', 'prefix=0.0.0.0/0', 'interface=$tunAdapter'],
        ),
        _RouteForm(
          ['netsh', 'interface', 'ipv4', 'add', 'route', 'prefix=0.0.0.0/0', 'interface=$tunAdapter'],
          ['netsh', 'interface', 'ipv4', 'delete', 'route', 'prefix=0.0.0.0/0', 'interface=$tunAdapter'],
        ),
      ],
    ];

    for (final form in candidates) {
      if (form.add.contains('-1')) continue; // no interface index known
      final r = await Process.run(form.add.first, form.add.sublist(1));
      if (r.exitCode == 0) {
        _logLine('default route: ${form.add.join(' ')}');
        // Trust but verify — against the full table, the way a human would:
        // some Windows builds publish the route under an on-link spelling
        // (Gateway column shows a localized word, not an IP) and the
        // verification used to be blind to that.
        final check = await _routeTable();
        if (Netsh.hasDefaultRoute(check, tunIp)) {
          _defaultRouteDelete = form.delete;
          return null;
        }
        // The command was accepted yet nothing is in the table: undo it
        // before trying the next form so we never end up with two default
        // routes through the tunnel.
        await Process.run(form.delete.first, form.delete.sublist(1));
        attempts.add('${form.add.join(' ')} → accepted but not in the table');
        continue;
      }
      attempts.add('${form.add.join(' ')} → ${_out(r)}');
    }
    final snapshot =
        _defaultRouteSnapshot(await _routeTable());
    return attempts.isEmpty
        ? 'no route command was tried'
        : '${attempts.join(' || ')} [table: $snapshot]';
  }

  Future<void> _bypassLanRoutes() async {
    final gw = _originalGw;
    if (!_bypassLan || gw == null) return;
    const lan = [
      ['10.0.0.0', '255.0.0.0'],
      ['172.16.0.0', '255.240.0.0'],
      ['192.168.0.0', '255.255.0.0'],
    ];
    for (final row in lan) {
      await Process.run('route', ['add', row[0], 'mask', row[1], gw]);
      _lanBypass.add(row[0]);
    }
  }

  /// Installs the routes that make the "direct" split rules work on Windows.
  ///
  /// A rule alone changes nothing there: the core's own socket still leaves
  /// through the adapter, which hands the packet back to the core. Only an
  /// address-level rule can be honoured, and only because the routing table can
  /// be told to send that network out of the physical gateway instead — the same
  /// mechanism the LAN bypass uses. Name-based rules stay Android-only on
  /// purpose (see [SplitRules.coreDirectEntries]).
  Future<void> _bypassDirectRoutes(VpnSettings settings) async {
    final gw = _originalGw;
    final routes = SplitRules.windowsBypassRoutes(settings);
    if (routes.isEmpty || gw == null) return;
    for (final row in routes) {
      if (_lanBypass.contains(row[0])) continue;
      await Process.run('route', ['add', row[0], 'mask', row[1], gw]);
      _lanBypass.add(row[0]);
      _logLine('split tunneling: ${row[0]}/${row[1]} bypasses the tunnel');
    }
  }

  /// Deletes the default route through the tunnel and *proves it is gone*.
  ///
  /// The form-specific delete can miss how Windows actually stored the route:
  /// a route requested with the tunnel address as gateway is stored (and
  /// printed) as an on-link route, whose Gateway column shows the localized
  /// "On-link" word — `route delete 0.0.0.0 mask 0.0.0.0 198.18.0.1` does not
  /// match it, just as a delete that names 0.0.0.0 does not match a stored
  /// gateway. Left behind, such a route points the machine's only default at
  /// a dead tunnel, so every spelling is tried until the table is clean.
  /// None of them can touch the user's real default route: they all name
  /// either our tunnel address or our adapter.
  Future<void> _removeTunDefaultRoute() async {
    final del = _defaultRouteDelete;
    _defaultRouteDelete = null;
    if (del != null) {
      final r = await Process.run(del.first, del.sublist(1));
      if (r.exitCode != 0) _logLine('default route delete: ${_out(r)}');
    }
    // A crashed run may leave a route behind with no remembered delete, and
    // the index is only known once the adapter is still around to ask for.
    if (tunIndex < 0) {
      final adapter = Netsh.findAdapter(await _interfaces(), adapterBase);
      if (adapter != null) tunIndex = adapter.index;
    }
    for (var pass = 0; pass < 3; pass++) {
      if (!Netsh.hasDefaultRoute(await _routeTable(), tunIp)) return;
      final trys = <List<String>>[
        if (tunIndex >= 0)
          ['route', 'delete', '0.0.0.0', 'mask', '0.0.0.0', '0.0.0.0', 'if', '$tunIndex'],
        ['route', 'delete', '0.0.0.0', 'mask', '0.0.0.0', tunIp],
        if (tunIndex >= 0)
          ['netsh', 'interface', 'ipv4', 'delete', 'route', 'prefix=0.0.0.0/0', 'interface=$tunIndex'],
        if (tunAdapter.isNotEmpty)
          ['netsh', 'interface', 'ipv4', 'delete', 'route', 'prefix=0.0.0.0/0', 'interface=$tunAdapter'],
      ];
      var removed = false;
      for (final t in trys) {
        final r = await Process.run(t.first, t.sublist(1));
        if (r.exitCode == 0) removed = true;
      }
      if (!removed) {
        _logLine('default route through the tunnel survives deletion — '
            'the adapter teardown will drop it');
        return;
      }
    }
    _logLine('default route through the tunnel still in the table after '
        'cleanup — the adapter teardown will drop it');
  }

  /// Removes everything this session added to the routing table.
  ///
  /// [forgetUpstreams] is only true on a real disconnect. Between two bridge
  /// attempts the upstream addresses stay known: re-adding the default route
  /// without the matching bypass routes would send the core's own connection
  /// into the tunnel — a routing loop, not a VPN.
  Future<void> _removeRoutes({bool forgetUpstreams = false}) async {
    if (_fakeIpRoute) {
      _fakeIpRoute = false;
      try {
        await Process.run('route', ['delete', HevConfig.mapDnsNetwork]);
      } catch (_) {}
    }
    if (_ipv6RouteInstalled) {
      _ipv6RouteInstalled = false;
      if (tunIndex >= 0) {
        try {
          await Process.run('netsh', [
            'interface', 'ipv6', 'delete', 'route',
            'prefix=::/0', 'interface=$tunIndex',
          ]);
        } catch (_) {}
      }
    }
    await _removeTunDefaultRoute();
    for (final dest in _rangeRoutes) {
      await Process.run('route', ['delete', dest]);
    }
    if (_originalGw != null) {
      for (final ip in _bypass) {
        await Process.run('route', ['delete', ip]);
      }
    }
    for (final ip in _lanBypass) {
      await Process.run('route', ['delete', ip]);
    }
    if (forgetUpstreams) _bypass.clear();
    _lanBypass.clear();
    _rangeRoutes.clear();
  }

  /// Bypass the tunnel's own upstreams before the default route goes in —
  /// missing one is the difference between a tunnel and a routing loop. The
  /// ranges are the full WARP candidate space the core can scan
  /// (the core's connectivity prober), collapsed into the documented /20
  /// ingress blocks.
  Future<void> _bypassUpstreams(VpnSettings settings) async {
    const warpRanges = [
      ['162.159.192.0', '255.255.240.0'], // 162.159.192-207, every MASQUE CIDR
      ['188.114.96.0', '255.255.240.0'], // 188.114.96-111
      ['162.159.36.0', '255.255.255.0'],
      ['162.159.46.0', '255.255.255.0'],
    ];
    final custom = settings.endpoint.trim();
    if (custom.isNotEmpty) {
      final ip = RegExp(r'(\d{1,3}(?:\.\d{1,3}){3})').firstMatch(custom);
      if (ip != null) _bypass.add(ip.group(1)!);
    }
    // Xray path: the worker/WARP upstreams resolved at capture time.
    _bypass.addAll(_extraBypassIps);
    final gw = _originalGw;
    if (gw == null) {
      _logLine('no upstream gateway found — WARP ranges are not bypassed');
      return;
    }
    for (final ip in _bypass) {
      await Process.run(
          'route', ['add', ip, 'mask', '255.255.255.255', gw]);
    }
    _rangeRoutes.clear();
    for (final row in warpRanges) {
      await Process.run('route', ['add', row[0], 'mask', row[1], gw]);
      _rangeRoutes.add(row[0]);
    }
  }

  void _onTunLog(String chunk) {
    for (final line in chunk.split(RegExp(r'\r?\n'))) {
      final t = line.trim();
      if (t.isEmpty) continue;
      _tunTail.add(t);
      if (_tunTail.length > 6) _tunTail.removeAt(0);
      _onLog(t);
    }
  }

  /// Turns a bridge's exit status into something a person can act on.
  String _exitReason(int code) {
    final unsigned = ExitCodes.normalize(code);
    final hint = ExitCodes.describe(unsigned);
    final tail = _tunTail.where((l) => !l.contains('exited (')).toList();
    final buf = StringBuffer('exited 0x${unsigned.toRadixString(16)}');
    if (hint != null) buf.write(' — $hint');
    if (tail.isNotEmpty) buf.write(' [${tail.last}]');
    return buf.toString();
  }

  void _logLine(String line) => _logs.add(line);

  void _emit() {
    // Status is polled from WindowsEngine.instance.statusMap via controller.
  }
}

/// One command pair: how the default route was installed, and how to undo
/// exactly that.
class _RouteForm {
  const _RouteForm(this.add, this.delete);
  final List<String> add;
  final List<String> delete;
}

/// Outcome of one TUN bridge attempt. [fatal] means the failure is not the
/// bridge's fault (netsh/route refused), so another bridge cannot help.
class _TunAttempt {
  const _TunAttempt(this.ok, this.reason, {this.fatal = false});

  factory _TunAttempt.success() => const _TunAttempt(true, '');
  factory _TunAttempt.fail(String reason, {bool fatal = false}) =>
      _TunAttempt(false, reason, fatal: fatal);

  final bool ok;
  final String reason;
  final bool fatal;
}
