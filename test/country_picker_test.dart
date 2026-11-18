import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/models/settings.dart';
import 'package:voidrauvpn/services/core_args.dart';
import 'package:voidrauvpn/services/vpn_controller.dart';

void main() {
  group('exit-country code normalisation', () {
    test('psiphonRegion keeps only a 2-letter ISO code, upper-cased', () {
      expect(VpnSettings(psiphonRegion: 'de').psiphonRegion, 'DE');
      expect(VpnSettings(psiphonRegion: ' DE ').psiphonRegion, 'DE');
      expect(VpnSettings(psiphonRegion: '').psiphonRegion, '');
      // The old free-text field passed these through and the core silently
      // ignored them; now they all become "automatic".
      expect(VpnSettings(psiphonRegion: 'Germany').psiphonRegion, '');
      expect(VpnSettings(psiphonRegion: 'IRAN').psiphonRegion, '');
      expect(VpnSettings(psiphonRegion: 'iran').psiphonRegion, '');
      expect(VpnSettings(psiphonRegion: 'D').psiphonRegion, '');
      expect(VpnSettings(psiphonRegion: 'DEU').psiphonRegion, '');
      expect(VpnSettings(psiphonRegion: 'D1').psiphonRegion, '');
    });

    test('a stored region is normalised on load, never trusted verbatim', () {
      final dirty = VpnSettings.fromJson({'psiphonRegion': 'germany'});
      expect(dirty.psiphonRegion, '');
      expect(VpnSettings.fromJson({'psiphonRegion': 'nl'}).psiphonRegion,
          'NL');
      expect(VpnSettings.fromJson({'psiphonRegion': 42}).psiphonRegion, '');
    });

    test('torExitCountry is validated exactly like psiphonRegion', () {
      expect(VpnSettings(torExitCountry: 'nl').torExitCountry, 'NL');
      expect(VpnSettings(torExitCountry: 'Netherlands').torExitCountry, '');
      expect(VpnSettings.fromJson({'torExitCountry': 'fr'}).torExitCountry,
          'FR');
      expect(VpnSettings.fromJson({'torExitCountry': 'france'}).torExitCountry,
          '');
    });

    test('tor exit flags roundtrip', () {
      final s = VpnSettings(
        torExitCountry: 'de',
        torExitStrict: false,
        torFastExit: true,
      );
      final copy = VpnSettings.fromJson(s.toJson());
      expect(copy.torExitCountry, 'DE');
      expect(copy.torExitStrict, isFalse);
      expect(copy.torFastExit, isTrue);
      // Defaults: strict on, fast off.
      final fresh = VpnSettings.fromJson({});
      expect(fresh.torExitStrict, isTrue);
      expect(fresh.torFastExit, isFalse);
      expect(fresh.torExitCountry, '');
    });

    test('torCountry (BridgeDB) is untouched by the exit picker', () {
      final s = VpnSettings(torCountry: 'IR', torExitCountry: 'DE');
      expect(s.torCountry, 'IR');
      expect(s.torExitCountry, 'DE');
      final copy = VpnSettings.fromJson(s.toJson());
      expect(copy.torCountry, 'IR');
      expect(copy.torExitCountry, 'DE');
    });
  });

  group('Tor exit override of the effective rule', () {
    test('a pinned Tor country becomes the preferred rule, Tor only', () {
      final tor = VpnSettings(
        secondHop: SecondHop.tor,
        torExitCountry: 'DE',
      );
      expect(tor.torExitEnforced, isTrue);
      expect(tor.effectiveExitFilter, ExitFilter.preferred);
      expect(tor.effectiveExitPreferred, ['DE']);
      // The stored filter is untouched — the picker never fights the UI.
      expect(tor.exitFilter, ExitFilter.off);
      expect(tor.exitPreferred, ['DE']);

      // Same pin, no Tor hop: the stored rule stands.
      final plain = VpnSettings(torExitCountry: 'DE');
      expect(plain.torExitEnforced, isFalse);
      expect(plain.effectiveExitFilter, ExitFilter.off);
    });

    test('fast-exit mode prefers the UAC fast list on Tor hops', () {
      final tor = VpnSettings(
        standaloneMode: StandaloneMode.torOnly,
        torFastExit: true,
      );
      expect(tor.torFastExitEnforced, isTrue);
      expect(tor.effectiveExitFilter, ExitFilter.preferred);
      expect(tor.effectiveExitPreferred,
          ['DE', 'NL', 'CH', 'AT', 'FR', 'SE', 'PL', 'GB']);
      // A pinned country wins over fast mode.
      final pinned = VpnSettings(
        standaloneMode: StandaloneMode.torOnly,
        torFastExit: true,
        torExitCountry: 'FR',
      );
      expect(pinned.effectiveExitPreferred, ['FR']);
    });

    test('the override flows into the core env — except in chain mode', () {
      // Reverse: the exit IS the tunnel's, so the core enforces the
      // allow-list against the right egress.
      final reverseEnv = CoreLaunch.environment(
        VpnSettings(
          secondHop: SecondHop.torReverse,
          torExitCountry: 'de',
          torCountry: 'IR',
        ),
        configPath: '/tmp/aether.toml',
      );
      expect(reverseEnv['AETHER_EXIT_LOC'], 'DE');
      // BridgeDB still gets its own country, unchanged.
      expect(reverseEnv['AETHER_TOR_COUNTRY'], 'ir');

      // Chain: the core's check reads the trace through the TUNNEL stack
      // (the WARP egress), while the device exit is the hop's — enforcing
      // the allow-list there would kill a tunnel whose hop exit is exactly
      // what was asked for. The client-side search enforces it instead.
      final chainEnv = CoreLaunch.environment(
        VpnSettings(
          secondHop: SecondHop.tor,
          torExitCountry: 'de',
          torCountry: 'IR',
        ),
        configPath: '/tmp/aether.toml',
      );
      expect(chainEnv.containsKey('AETHER_EXIT_LOC'), isFalse);
      // The hop itself is still configured exactly as before.
      expect(chainEnv['AETHER_TOR'], 'chain');
      expect(chainEnv['AETHER_TOR_BIND'], '127.0.0.1:1821');
      expect(chainEnv['AETHER_TOR_COUNTRY'], 'ir');
    });
  });

  group('matchesExitFilter with a pinned Tor country', () {
    test('strict mode accepts only the pinned country', () {
      final s = VpnSettings(
        secondHop: SecondHop.tor,
        torExitCountry: 'DE',
        torExitStrict: true,
      );
      expect(VpnController.matchesExitFilter('DE', s), isTrue);
      expect(VpnController.matchesExitFilter('NL', s), isFalse);
      expect(VpnController.matchesExitFilter('IR', s), isFalse);
      // An unknown exit is still accepted — rejecting it would re-dial
      // forever on lookups that answer nothing.
      expect(VpnController.matchesExitFilter('', s), isTrue);
      expect(VpnController.matchesExitFilter(null, s), isTrue);
    });

    test('non-strict mode falls back to the preferred rule', () {
      final s = VpnSettings(
        secondHop: SecondHop.tor,
        torExitCountry: 'DE',
        torExitStrict: false,
        exitPreferred: const ['DE'],
        exitBlocked: const ['IR'],
      );
      expect(VpnController.matchesExitFilter('DE', s), isTrue);
      expect(VpnController.matchesExitFilter('NL', s), isTrue);
      expect(VpnController.matchesExitFilter('IR', s), isFalse);
    });
  });
}
