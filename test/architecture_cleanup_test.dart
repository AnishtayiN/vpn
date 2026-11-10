import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/models/settings.dart';
import 'package:voidrauvpn/services/core_args.dart';
import 'package:voidrauvpn/services/ios_policy.dart';
import 'package:voidrauvpn/services/vpn_controller.dart';

/// Architecture clean-up (§6 of the architecture audit):
/// one reconnect routing point, the split of the old single `chain` value
/// into [SecondHop] + [StandaloneMode] (with migration), and the Xray
/// proxy rename. The controller's actual dial (`reconnect()` → connect /
/// connectXray) needs a tunnel and platform channels, so it is covered by
/// the pure routing decision ([VpnController.useXrayFor]) here plus a grep
/// check that no reconnect path still dials `connect()` directly — the
/// only direct `connect()` calls left are the three Aether-only exit-rule
/// helpers, each marked as such in the code.
void main() {
  group('unified reconnect routing', () {
    test('Xray is chosen only when a mode is set and the engine exists', () {
      expect(VpnController.useXrayFor(XrayMode.off, supported: true), isFalse);
      expect(
          VpnController.useXrayFor(XrayMode.worker, supported: true), isTrue);
      expect(VpnController.useXrayFor(XrayMode.warp, supported: true), isTrue);
      expect(VpnController.useXrayFor(XrayMode.serverless, supported: true),
          isTrue);
      // No Xray binary on this platform (Windows/iOS): Aether, even with a
      // stale mode stored from another device.
      expect(
          VpnController.useXrayFor(XrayMode.worker, supported: false), isFalse);
      expect(
          VpnController.useXrayFor(XrayMode.warp, supported: false), isFalse);
    });

    test('the controller routes on the same decision', () {
      // flutter test runs on Linux, where XrayEngine.supported is false,
      // so useXray is false even with a mode selected — the point is that
      // the getter and the pure function agree, never diverge.
      final c = VpnController();
      c.settings = VpnSettings(xrayMode: XrayMode.worker);
      expect(c.useXray, isFalse);
      expect(c.useXray,
          VpnController.useXrayFor(c.settings.xrayMode, supported: false));
      c.settings = VpnSettings(xrayMode: XrayMode.off);
      expect(c.useXray, isFalse);
    });
  });

  group('split migration: old persisted `chain` values survive', () {
    VpnSettings fromLegacy(String chain) =>
        VpnSettings.fromJson({'chain': chain});

    test('second-hop values map to SecondHop, standalone stays standard', () {
      expect(fromLegacy('psiphon').secondHop, SecondHop.psiphon);
      expect(fromLegacy('psiphon').standaloneMode, StandaloneMode.standard);
      expect(fromLegacy('psiphonReverse').secondHop, SecondHop.psiphonReverse);
      expect(fromLegacy('tor').secondHop, SecondHop.tor);
      expect(fromLegacy('torReverse').secondHop, SecondHop.torReverse);
      expect(fromLegacy('tor').standaloneMode, StandaloneMode.standard);
    });

    test('standalone values map to StandaloneMode, second hop stays off', () {
      final psiphon = fromLegacy('psiphonOnly');
      expect(psiphon.standaloneMode, StandaloneMode.psiphonOnly);
      expect(psiphon.secondHop, SecondHop.off);
      final tor = fromLegacy('torOnly');
      expect(tor.standaloneMode, StandaloneMode.torOnly);
      expect(tor.secondHop, SecondHop.off);
    });

    test('off and unknown values reset to off/standard, never crash', () {
      expect(fromLegacy('off').secondHop, SecondHop.off);
      expect(fromLegacy('off').standaloneMode, StandaloneMode.standard);
      expect(fromLegacy('bogus').secondHop, SecondHop.off);
      expect(fromLegacy('bogus').standaloneMode, StandaloneMode.standard);
      expect(VpnSettings.fromJson({}).secondHop, SecondHop.off);
      expect(VpnSettings.fromJson({}).standaloneMode, StandaloneMode.standard);
    });

    test('new keys win over a legacy `chain` value when both are stored', () {
      final st = VpnSettings.fromJson({
        'chain': 'torOnly',
        'secondHop': 'psiphon',
        'standaloneMode': 'standard',
      });
      expect(st.secondHop, SecondHop.psiphon);
      expect(st.standaloneMode, StandaloneMode.standard);
    });

    test('toJson writes only the new keys, never the old `chain` key', () {
      final json = VpnSettings(
        secondHop: SecondHop.tor,
        standaloneMode: StandaloneMode.psiphonOnly,
      ).toJson();
      expect(json.containsKey('chain'), isFalse);
      expect(json['secondHop'], 'tor');
      expect(json['standaloneMode'], 'psiphonOnly');
      // And the round-trip is stable.
      final loaded = VpnSettings.fromJson(json);
      expect(loaded.secondHop, SecondHop.tor);
      expect(loaded.standaloneMode, StandaloneMode.psiphonOnly);
    });

    test('old Xray proxy keys migrate to the new names', () {
      final loaded = VpnSettings.fromJson({
        'chainProxies': [
          {'id': 'a', 'name': 'x', 'link': 'vless://example'},
        ],
        'chainExitId': 'a',
      });
      expect(loaded.xrayChainProxies.length, 1);
      expect(loaded.xrayChainProxies.first.link, 'vless://example');
      expect(loaded.xrayChainExitId, 'a');
      final json = loaded.toJson();
      expect(json.containsKey('chainProxies'), isFalse);
      expect(json.containsKey('chainExitId'), isFalse);
      expect((json['xrayChainProxies'] as List).length, 1);
      expect(json['xrayChainExitId'], 'a');
    });
  });

  group('standalone / second-hop separation', () {
    test('the two fields are independent in the model', () {
      final st = VpnSettings(
        secondHop: SecondHop.psiphon,
        standaloneMode: StandaloneMode.torOnly,
      );
      expect(st.hasSecondHop, isTrue);
      expect(st.isStandaloneHop, isTrue);
      final plain = VpnSettings(secondHop: SecondHop.torReverse);
      expect(plain.hasSecondHop, isTrue);
      expect(plain.isStandaloneHop, isFalse);
      expect(VpnSettings().hasSecondHop, isFalse);
      expect(VpnSettings().isStandaloneHop, isFalse);
    });

    test('standalone wins over a second hop in the core env', () {
      // Both set at once (possible now that they are separate fields):
      // the standalone mode is the connection, the second hop is ignored.
      final e = CoreLaunch.environment(
        VpnSettings(
          secondHop: SecondHop.psiphon,
          standaloneMode: StandaloneMode.torOnly,
          torCountry: 'IR',
        ),
        configPath: 'aether.toml',
      );
      expect(e['AETHER_TOR'], 'only');
      expect(e.containsKey('AETHER_PSIPHON'), isFalse);
      expect(
          CoreLaunch.isTor(VpnSettings(
            secondHop: SecondHop.psiphon,
            standaloneMode: StandaloneMode.torOnly,
          )),
          isTrue);
      expect(
          CoreLaunch.isPsiphon(VpnSettings(
            secondHop: SecondHop.psiphon,
            standaloneMode: StandaloneMode.torOnly,
          )),
          isFalse);
    });

    test('a second hop alone still maps to its own family', () {
      expect(
          CoreLaunch.isPsiphon(
              VpnSettings(secondHop: SecondHop.psiphonReverse)),
          isTrue);
      expect(CoreLaunch.isTor(VpnSettings(secondHop: SecondHop.tor)), isTrue);
      expect(CoreLaunch.isPsiphon(VpnSettings()), isFalse);
      expect(CoreLaunch.isTor(VpnSettings()), isFalse);
    });
  });

  group('IosPolicy zeroes the Xray mode too', () {
    test('xrayMode, secondHop and standaloneMode are all reset', () {
      final st = VpnSettings(
        xrayMode: XrayMode.worker,
        secondHop: SecondHop.psiphon,
        standaloneMode: StandaloneMode.psiphonOnly,
      );
      IosPolicy.normalize(st);
      expect(st.xrayMode, XrayMode.off);
      expect(st.secondHop, SecondHop.off);
      expect(st.standaloneMode, StandaloneMode.standard);
    });
  });

  group('renamed Xray chain proxies', () {
    test('xrayChainExitFor picks the chosen proxy, never on serverless', () {
      const link = 'vless://uuid@host:443?x=y#n';
      final st = VpnSettings(
        xrayChainProxies: const [
          ChainProxy(id: 'a', name: 'x', link: link),
        ],
        xrayChainExitId: 'a',
      );
      expect(st.xrayChainExitFor(XrayMode.worker)?.id, 'a');
      expect(st.xrayChainExitFor(XrayMode.warp)?.id, 'a');
      expect(st.xrayChainExitFor(XrayMode.serverless), isNull);
    });
  });
}
