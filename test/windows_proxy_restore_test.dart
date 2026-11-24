import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/models/settings.dart';
import 'package:voidrauvpn/services/windows_proxy.dart';

/// Tests for the system-proxy restore path (finding 1): the on-disk
/// snapshot lifecycle, the no-snapshot fallback, the PAC snapshot, and the
/// port the boot self-heal must heal (the *device* port, not the SOCKS
/// port).
///
/// The actual registry writes are Windows-only and cannot run on the test
/// host: `reg.exe` does not exist here, so `apply()` fails closed and
/// returns false. What *is* testable here is everything around the write —
/// snapshot persistence, snapshot consumption/deletion, corrupt-snapshot
/// handling, and the fallback's port matching (pure, already covered by
/// `pointsAt` in windows_proxy_test.dart). The real `reg` write path is
/// listed as not-done in the report.
void main() {
  group('ProxyState with PAC (finding 20)', () {
    test('parseRegQuery reads AutoConfigURL', () {
      const text = '''
    ProxyEnable    REG_DWORD    0x1
    ProxyServer    REG_SZ    127.0.0.1:1819
    AutoConfigURL    REG_SZ    http://pac.example.com/proxy.pac
''';
      final s = WindowsSystemProxy.parseRegQuery(text);
      expect(s.enabled, isTrue);
      expect(s.server, '127.0.0.1:1819');
      expect(s.autoConfigUrl, 'http://pac.example.com/proxy.pac');
    });

    test('a PAC-only machine (proxy off) still snapshots its PAC URL', () {
      const text = '''
    ProxyEnable    REG_DWORD    0x0
    AutoConfigURL    REG_SZ    http://pac.example.com/proxy.pac
''';
      final s = WindowsSystemProxy.parseRegQuery(text);
      expect(s.enabled, isFalse);
      expect(s.autoConfigUrl, 'http://pac.example.com/proxy.pac');
    });

    test('ProxyState round-trips the PAC URL through JSON', () {
      const s = ProxyState(
        enabled: true,
        server: 'socks=127.0.0.1:1819',
        overrideList: '127.0.0.1;localhost;<local>',
        autoConfigUrl: 'http://pac.example.com/proxy.pac',
      );
      final back = ProxyState.fromJson(
          jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(back.enabled, isTrue);
      expect(back.server, 'socks=127.0.0.1:1819');
      expect(back.overrideList, '127.0.0.1;localhost;<local>');
      expect(back.autoConfigUrl, 'http://pac.example.com/proxy.pac');
    });

    test('fromJson is tolerant: corrupt values read as direct', () {
      final s = ProxyState.fromJson({
        'enabled': 'yes',
        'server': 42,
        'autoConfigUrl': '',
      });
      expect(s.enabled, isFalse);
      expect(s.server, isNull);
      expect(s.autoConfigUrl, isNull);
      final empty = ProxyState.fromJson({});
      expect(empty.enabled, isFalse);
      expect(empty.server, isNull);
      expect(empty.overrideList, isNull);
      expect(empty.autoConfigUrl, isNull);
    });
  });

  group('restore() snapshot lifecycle', () {
    late Directory dir;
    late String? savedStateDir;
    final proxy = WindowsSystemProxy.instance;

    setUp(() async {
      savedStateDir = proxy.stateDir;
      dir = await Directory.systemTemp.createTemp('proxy-restore-test');
      proxy.stateDir = dir.path;
      // Clear any in-memory snapshot left by an earlier test.
      await proxy.restore();
    });

    tearDown(() async {
      await proxy.restore();
      proxy.stateDir = savedStateDir;
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    File snapshotFile() =>
        File('${dir.path}${Platform.pathSeparator}proxy.snapshot');

    test('rememberOriginal persists the snapshot to disk', () async {
      await proxy.rememberOriginal();
      expect(await snapshotFile().exists(), isTrue);
      final saved = ProxyState.fromJson(
          jsonDecode(await snapshotFile().readAsString())
              as Map<String, dynamic>);
      // On the test host there is no registry, so the snapshot is "direct".
      expect(saved.enabled, isFalse);
      expect(saved.server, isNull);
    });

    test('restore() consumes the in-memory snapshot and deletes the file',
        () async {
      await proxy.rememberOriginal();
      expect(await snapshotFile().exists(), isTrue);
      await proxy.restore();
      expect(await snapshotFile().exists(), isFalse);
      // A second restore is a no-op, not a crash.
      await proxy.restore();
    });

    test('restore() honours a disk snapshot left by a hard-killed run',
        () async {
      // Plant the file directly, as a previous run that died before it
      // could restore would have left it — no in-memory snapshot exists.
      await snapshotFile().writeAsString(jsonEncode(const ProxyState(
        enabled: true,
        server: 'socks=127.0.0.1:1821',
        overrideList: '127.0.0.1;localhost;<local>',
        autoConfigUrl: 'http://pac.example.com/proxy.pac',
      ).toJson()));
      await proxy.restore();
      expect(await snapshotFile().exists(), isFalse);
    });

    test('restore() deletes a corrupt disk snapshot instead of retrying it',
        () async {
      await snapshotFile().writeAsString('this is not json {{{');
      await proxy.restore();
      expect(await snapshotFile().exists(), isFalse);
      // And the next boot does not trip over it either.
      await proxy.restore();
    });

    test('restore() with no snapshot at all is a silent no-op', () async {
      expect(await snapshotFile().exists(), isFalse);
      await proxy.restore(ourPort: 1819, ourPorts: {1820, 1821, 1822});
      await proxy.restore();
    });

    test('restore() with no stateDir configured is a silent no-op',
        () async {
      proxy.stateDir = null;
      await proxy.restore(ourPort: 1819);
      proxy.stateDir = dir.path;
    });
  });

  group('the boot self-heal must heal the device port (finding 1)', () {
    test('in chain mode the device port is the hop port, not socksPort',
        () {
      final chain = VpnSettings(secondHop: SecondHop.psiphon);
      expect(chain.isChainHop, isTrue);
      expect(chain.devicePort, chain.hopPort);
      expect(chain.devicePort, 1821);
      expect(chain.devicePort, isNot(chain.socksPort));
    });

    test('without a second hop the device port is the SOCKS port', () {
      final plain = VpnSettings();
      expect(plain.isChainHop, isFalse);
      expect(plain.devicePort, plain.socksPort);
      expect(plain.devicePort, 1819);
    });

    test('the boot heal covers every loopback port the app can set', () {
      // vpn_controller.boot() passes devicePort plus socks/http/hop ports
      // as ourPorts; the set must contain the chain-mode device port or a
      // leftover proxy at 127.0.0.1:1821 survives a restart.
      final s = VpnSettings(secondHop: SecondHop.tor);
      final healPorts = {
        s.devicePort,
        s.socksPort,
        s.httpProxyPort,
        s.hopPort,
        s.hopHttpPort,
      };
      expect(healPorts, containsAll([1819, 1820, 1821, 1822]));
      // Four distinct ports: in chain mode devicePort *is* hopPort, so
      // the five arguments collapse to four values — the heal set must
      // still contain the chain-mode device port 1821.
      expect(healPorts.length, 4);
    });
  });
}
