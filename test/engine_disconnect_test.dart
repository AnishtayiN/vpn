import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/models/engine_state.dart' as engine_state;
import 'package:voidrauvpn/services/platform_engine.dart';
import 'package:voidrauvpn/services/windows_proxy.dart';

/// Tests for the user-disconnect proxy-restore path (finding 1):
/// `disconnect()` → `engine.stop()` → `WindowsSystemProxy.restore()`.
///
/// The top of the chain, `VpnController.disconnect()`, cannot be driven
/// here: the controller's `engine` is the `PlatformEngine` facade, whose
/// `stop()` is a no-op off Windows — the Windows engine is only reached
/// through `Platform.isWindows`. So this file tests the chain from the
/// Windows engine down, which is the part that actually touches the
/// proxy: `WindowsEngine.stop()` must consume the on-disk proxy snapshot
/// a hard-killed run left behind, and must *not* restore while
/// `keepBlock` is set (recovery teardown keeps the dead-listener proxy in
/// place so traffic fails closed while the watchdog re-dials).
///
/// The registry write itself is Windows-only (`reg.exe` does not exist on
/// the test host, so `apply()` fails closed); the snapshot consumption is
/// what is asserted. The full controller-level path is listed as not-done.
void main() {
  group('WindowsEngine.stop() restores the system proxy', () {
    late Directory dir;
    late String? savedStateDir;
    final proxy = WindowsSystemProxy.instance;

    setUp(() async {
      savedStateDir = proxy.stateDir;
      dir = await Directory.systemTemp.createTemp('engine-stop-test');
      // The engine singleton's constructor points the proxy stateDir at
      // the engine runtime dir — force construction first, then redirect
      // it at the temp dir, or the redirect would be overwritten.
      expect(WindowsEngine.instance.phase,
          engine_state.EnginePhase.disconnected);
      proxy.stateDir = dir.path;
    });

    tearDown(() async {
      proxy.stateDir = savedStateDir;
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    File snapshotFile() =>
        File('${dir.path}${Platform.pathSeparator}proxy.snapshot');

    Future<void> plantSnapshot() async {
      await snapshotFile().writeAsString(jsonEncode(const ProxyState(
        enabled: true,
        server: 'socks=127.0.0.1:1821',
        overrideList: '127.0.0.1;localhost;<local>',
      ).toJson()));
    }

    test('stop() consumes a leftover proxy snapshot', () async {
      await plantSnapshot();
      expect(await snapshotFile().exists(), isTrue);
      await WindowsEngine.instance.stop();
      expect(await snapshotFile().exists(), isFalse);
      expect(WindowsEngine.instance.phase, engine_state.EnginePhase.disconnected);
    });

    test('stop(keepBlock: true) leaves the snapshot in place', () async {
      await plantSnapshot();
      await WindowsEngine.instance.stop(keepBlock: true);
      expect(await snapshotFile().exists(), isTrue);
      expect(WindowsEngine.instance.phase, engine_state.EnginePhase.disconnected);
      // The next plain stop — the user disconnect — restores it.
      await WindowsEngine.instance.stop();
      expect(await snapshotFile().exists(), isFalse);
    });

    test('stop() with no snapshot is a no-op, not a crash', () async {
      expect(await snapshotFile().exists(), isFalse);
      await WindowsEngine.instance.stop();
      expect(WindowsEngine.instance.phase, engine_state.EnginePhase.disconnected);
    });
  });
}
