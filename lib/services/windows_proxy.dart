import 'dart:ffi';
import 'dart:io';

/// Snapshot of the current user's WinINET ("system proxy") settings —
/// exactly what Settings → Network → Proxy shows: ProxyEnable (0/1),
/// ProxyServer (host:port, or http=...;https=...) and ProxyOverride
/// (bypass list), under
/// HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings.
class ProxyState {
  const ProxyState({
    this.enabled = false,
    this.server,
    this.overrideList,
  });

  /// Direct connection: manual proxy off, nothing configured.
  static const direct = ProxyState();

  final bool enabled;
  final String? server;
  final String? overrideList;
}

/// Owns the Windows **system proxy** for the lifetime of a VoidrauVPN session,
/// so the app's on/off state actually controls the proxy flow:
///
///  * SOCKS5 proxy mode (and the non-elevated device-VPN fallback) →
///    the system proxy is pointed at `127.0.0.1:<port>` automatically.
///  * device VPN with a live TUN adapter → the system proxy is turned
///    **off**: every app must ride the TUN adapter directly, and a stale
///    manual proxy would let WinINET apps (browsers) shortcut the tunnel
///    through the raw SOCKS listener.
///  * disconnect → whatever settings the user had before VoidrauVPN are
///    restored exactly. When no snapshot exists (previous run hard-killed),
///    at minimum any proxy still pointing at our own listener is removed.
///
/// Writes go through `reg.exe` against HKCU only — no elevation needed —
/// and every change is announced to running apps through WinINet
/// `InternetSetOption` (SETTINGS_CHANGED + REFRESH), the same broadcast the
/// Control Panel performs, so browsers pick the change up immediately
/// instead of keeping their cached proxy until restart.
class WindowsSystemProxy {
  WindowsSystemProxy._();

  static final WindowsSystemProxy instance = WindowsSystemProxy._();

  static const String _key =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  // wininet.h
  static const int _optionSettingsChanged = 39;
  static const int _optionRefresh = 37;

  ProxyState? _original;

  /// Optional sink for log lines (the engine wires this to its log stream,
  /// which the UI's live log already shows).
  void Function(String line)? onLog;

  void _log(String line) {
    final sink = onLog;
    if (sink != null) sink(line);
  }

  /// Reads the current system proxy settings. Never throws.
  Future<ProxyState> read() async {
    try {
      final r = await Process.run('reg', ['query', _key]);
      return parseRegQuery('${r.stdout}');
    } catch (_) {
      return ProxyState.direct;
    }
  }

  /// Parses `reg query <Internet Settings>` output.
  ///
  /// Tolerates localized type names (REG_DWORD / DWORD / …) and DWORD
  /// values written as hex (`0x1`) or decimal (`1`). Returns
  /// [ProxyState.direct] for a missing key or unrecognized output.
  static ProxyState parseRegQuery(String text) {
    bool? enabled;
    String? server;
    String? overrideList;
    for (final rawLine in text.split('\n')) {
      // "    ProxyServer    REG_SZ    127.0.0.1:1819"
      final m =
          RegExp(r'^\s+([A-Za-z0-9_]+)\s+\S+\s+(.+?)\s*$').firstMatch(rawLine);
      if (m == null) continue;
      switch (m.group(1)) {
        case 'ProxyEnable':
          final v = m.group(2)!.trim();
          final hex = v.startsWith('0x') || v.startsWith('0X');
          enabled =
              int.tryParse(hex ? v.substring(2) : v, radix: hex ? 16 : 10) ==
              1;
        case 'ProxyServer':
          server = m.group(2)!.trim();
        case 'ProxyOverride':
          overrideList = m.group(2)!.trim();
      }
    }
    return ProxyState(
      enabled: enabled ?? false,
      server: server,
      overrideList: overrideList,
    );
  }

  /// The state VoidrauVPN applies while its proxy mode is connected: point the
  /// system proxy at our own loopback listener, keeping loopback direct.
  ///
  /// The `socks=` prefix is load-bearing: a bare `host:port` ProxyServer
  /// value means an **HTTP** proxy to WinINET, and browsers would send
  /// HTTP CONNECT to a SOCKS5 listener and fail every page. The core's
  /// listener speaks SOCKS5 (its HTTP CONNECT listener is a separate,
  /// opt-in port), so the value must name the protocol.
  static ProxyState loopback(int port) => ProxyState(
        enabled: true,
        server: 'socks=127.0.0.1:$port',
        overrideList: '127.0.0.1;localhost;<local>',
      );

  /// Points the system proxy at the VoidrauVPN loopback listener [port].
  /// Returns whether the write was verified (see [apply]).
  Future<bool> enableOurs(int port) => apply(loopback(port));

  /// Turns the system proxy off entirely (direct connection).
  Future<bool> clearOurs() => apply(ProxyState.direct);

  /// Writes [state] to the registry, announces the change to WinINet, and
  /// **verifies** it by reading the settings back.
  ///
  /// The verification is the point: `reg.exe` failures used to be
  /// swallowed here, so the engine published "connected — system proxy
  /// on" over a machine whose traffic was never captured at all (the
  /// exact leak where every site shows the user's real IP while the app
  /// shows the tunnel exit). Callers that claim capture must check the
  /// returned value; failures are also logged, never thrown.
  Future<bool> apply(ProxyState state) async {
    try {
      // Adds must succeed; deletes are best-effort (deleting a value that
      // is already absent exits non-zero, which is the desired end state
      // anyway) — the read-back below is the authority either way.
      final adds = <ProcessResult>[
        await _regAdd('ProxyEnable', 'REG_DWORD', state.enabled ? '1' : '0'),
        if (state.server != null)
          await _regAdd('ProxyServer', 'REG_SZ', state.server!),
        if (state.overrideList != null)
          await _regAdd('ProxyOverride', 'REG_SZ', state.overrideList!),
      ];
      if (state.server == null) await _regDel('ProxyServer');
      if (state.overrideList == null) await _regDel('ProxyOverride');
      final failed = adds.where((r) => r.exitCode != 0).toList();
      if (failed.isNotEmpty) {
        _log('system proxy write failed: '
            '${failed.map((r) => '${r.stdout}${r.stderr}'.trim()).join(' | ')}');
        return false;
      }
      _announce();
      final back = await read();
      // When disabled, a remembered-but-inert ProxyServer value is
      // harmless (Windows ignores it while ProxyEnable is 0, and restore
      // writes it back on purpose), so only the enable flag is judged.
      final verified = back.enabled == state.enabled &&
          (!state.enabled ||
              state.server == null ||
              back.server == state.server);
      _log(state.enabled
          ? 'system proxy → ${state.server}${verified ? '' : ' (read-back mismatch: enabled=${back.enabled} server=${back.server})'}'
          : 'system proxy → off${verified ? '' : ' (read-back mismatch: still enabled)'}');
      return verified;
    } catch (e) {
      _log('system proxy change failed: $e');
      return false;
    }
  }

  // `reg` is launched WITHOUT a shell on purpose: the data values can carry
  // characters that cmd.exe would eat (the bypass list contains `<local>`),
  // and an argument vector straight into CreateProcess is quote-free.
  Future<ProcessResult> _regAdd(String value, String type, String data) {
    return Process.run(
      'reg',
      ['add', _key, '/v', value, '/t', type, '/d', data, '/f'],
    );
  }

  Future<ProcessResult> _regDel(String value) {
    return Process.run('reg', ['delete', _key, '/v', value, '/f']);
  }

  /// One-shot snapshot of whatever the user had before this session.
  Future<void> rememberOriginal() async {
    if (_original != null) return;
    _original = await read();
    _log(_original!.enabled
        ? 'system proxy snapshot: ${_original!.server}'
        : 'system proxy snapshot: off');
  }

  /// Undoes this session's proxy changes on disconnect:
  ///
  ///  * with a snapshot → restore it exactly (your own manual proxy, or
  ///    plain "off");
  ///  * without one (the previous run was hard-closed) → remove only a
  ///    proxy that still points at our own listener [ourPort]; the user's
  ///    own proxy on a different port is left untouched.
  Future<void> restore({int? ourPort}) async {
    final s = _original;
    _original = null;
    if (s != null) {
      await apply(s);
      return;
    }
    if (ourPort == null) return;
    final cur = await read();
    if (cur.enabled && pointsAt(cur.server, ourPort)) {
      await clearOurs();
    }
  }

  /// True when any entry of a (possibly `http=...;https=...`) proxy server
  /// string is exactly our own loopback listener.
  static bool pointsAt(String? server, int port) {
    for (final raw in (server ?? '').split(';')) {
      var e = raw.trim();
      if (e.isEmpty) continue;
      final eq = e.indexOf('=');
      if (eq > 0) e = e.substring(eq + 1); // strip a scheme= prefix
      if (e == '127.0.0.1:$port') return true;
    }
    return false;
  }

  /// Makes running apps re-read their proxy settings — the same WinINet
  /// broadcast the Control Panel performs after a proxy change. Without it
  /// Chrome & co. keep their cached (dead) proxy until restart.
  void _announce() {
    try {
      final wininet = DynamicLibrary.open('wininet.dll');
      final setOption = wininet.lookupFunction<
          Int32 Function(IntPtr, Int32, IntPtr, Int32),
          int Function(int, int, int, int)>(
        'InternetSetOption',
      );
      setOption(0, _optionSettingsChanged, 0, 0);
      setOption(0, _optionRefresh, 0, 0);
    } catch (_) {
      // Not on Windows (or the call is unavailable): the registry write
      // above is still authoritative for everything that re-reads it.
    }
  }
}
