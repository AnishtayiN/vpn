import 'package:flutter/material.dart';
// flutter_test re-exports its own EnginePhase (test binding lifecycle), which
// would collide with the app's tunnel phase of the same name.
import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:voidrauvpn/data/countries.dart';
import 'package:voidrauvpn/models/engine_state.dart';
import 'package:voidrauvpn/models/settings.dart';
import 'package:voidrauvpn/services/vpn_controller.dart';
import 'package:voidrauvpn/ui/widgets/country_picker.dart';

void main() {
  group('exit country defaults', () {
    test('a fresh install wants a foreign exit, Germany first', () {
      final s = VpnSettings();
      // "any IP but Iran" is the out-of-the-box rule, and Germany is the
      // country the user asked to land in when it is available.
      expect(s.exitFilter, ExitFilter.nonIran);
      expect(s.exitPreferred, ['DE']);
      expect(s.exitBlocked, ['IR']);
      // The search asks what to do after three minutes.
      expect(s.exitAskAfter, 180);
      expect(s.exitMaxTries, greaterThan(1));
    });

    test('settings roundtrip keeps the exit rule', () {
      final s = VpnSettings(
        exitFilter: ExitFilter.preferred,
        exitPreferred: const ['DE', 'NL'],
        exitBlocked: const ['IR'],
        exitAskAfter: 120,
        exitMaxTries: 4,
      );
      final copy = VpnSettings.fromJson(s.toJson());
      expect(copy.exitFilter, ExitFilter.preferred);
      expect(copy.exitPreferred, ['DE', 'NL']);
      expect(copy.exitBlocked, ['IR']);
      expect(copy.exitAskAfter, 120);
      expect(copy.exitMaxTries, 4);
    });

    test('a stored list is normalised, never trusted verbatim', () {
      final dirty = VpnSettings.fromJson({
        'exitFilter': 'preferred',
        'exitPreferred': ['de', 'nl', 'DE', 'xyz', '', 'iran'],
        'exitBlocked': 'not-a-list',
        'exitAskAfter': '240',
      });
      expect(dirty.exitPreferred, ['DE', 'NL']);
      // An unusable blocked list falls back to the default instead of
      // silently disabling the filter.
      expect(dirty.exitBlocked, ['IR']);
      expect(dirty.exitAskAfter, 240);
    });

    test('an unknown filter name falls back to the safe default', () {
      expect(VpnSettings.fromJson({'exitFilter': 'nonsense'}).exitFilter,
          ExitFilter.nonIran);
    });
  });

  group('matchesExitFilter', () {
    VpnSettings rule(
      ExitFilter f, {
      List<String> want = const ['DE'],
      List<String> blocked = const ['IR'],
    }) =>
        VpnSettings(exitFilter: f, exitPreferred: want, exitBlocked: blocked);

    test('off accepts everything', () {
      final s = rule(ExitFilter.off);
      expect(VpnController.matchesExitFilter('IR', s), isTrue);
      expect(VpnController.matchesExitFilter('DE', s), isTrue);
    });

    test('nonIran rejects Iran and accepts anywhere else', () {
      final s = rule(ExitFilter.nonIran);
      expect(VpnController.matchesExitFilter('IR', s), isFalse);
      expect(VpnController.matchesExitFilter('ir', s), isFalse);
      expect(VpnController.matchesExitFilter('DE', s), isTrue);
      expect(VpnController.matchesExitFilter('NL', s), isTrue);
      expect(VpnController.matchesExitFilter('US', s), isTrue);
      expect(VpnController.matchesExitFilter('TR', s), isTrue);
    });

    test('preferred takes Germany, then any country but Iran', () {
      final s = rule(ExitFilter.preferred);
      expect(VpnController.matchesExitFilter('DE', s), isTrue);
      expect(VpnController.matchesExitFilter('NL', s), isTrue);
      expect(VpnController.matchesExitFilter('IR', s), isFalse);
    });

    test('preferred with several countries accepts each of them', () {
      final s = rule(ExitFilter.preferred, want: const ['DE', 'NL', 'FR']);
      for (final c in ['DE', 'NL', 'FR']) {
        expect(VpnController.matchesExitFilter(c, s), isTrue, reason: c);
      }
      expect(VpnController.matchesExitFilter('IR', s), isFalse);
      expect(VpnController.matchesExitFilter('SE', s), isTrue);
    });

    test('an emptied preferred list still keeps the blocked country out', () {
      final s = rule(ExitFilter.preferred, want: const []);
      expect(VpnController.matchesExitFilter('NL', s), isTrue);
      expect(VpnController.matchesExitFilter('DE', s), isTrue);
      expect(VpnController.matchesExitFilter('IR', s), isFalse);
    });

    test('an unknown or anonymised exit is accepted, not re-dialled forever',
        () {
      final s = rule(ExitFilter.nonIran);
      // A geo lookup that answers nothing must not become an endless loop.
      expect(VpnController.matchesExitFilter('', s), isTrue);
      expect(VpnController.matchesExitFilter(null, s), isTrue);
      expect(VpnController.matchesExitFilter('XX', s), isTrue);
      expect(VpnController.matchesExitFilter('T1', s), isTrue);
    });

    test('every preferred or blocked default is a country the UI can draw', () {
      final s = VpnSettings();
      for (final code in [...s.exitPreferred, ...s.exitBlocked]) {
        expect(countryFlag(code), isNotNull, reason: code);
      }
    });
  });

  group('usablePeer', () {
    test('accepts addresses, rejects colo codes', () {
      expect(usablePeer('162.159.192.1:443'), isTrue);
      expect(usablePeer('example.com:443'), isTrue);
      expect(usablePeer('[2606:4700::1]:443'), isTrue);
      // A trace answers colo=FRA; that is not something the core can dial.
      expect(usablePeer('FRA'), isFalse);
      expect(usablePeer('IAD'), isFalse);
      expect(usablePeer('IR'), isFalse);
      expect(usablePeer(''), isFalse);
      expect(usablePeer(null), isFalse);
    });
  });

  group('snapshot exit facts', () {
    test('clearExit drops the previous tunnel\'s country', () {
      const snap = EngineSnapshot(
        phase: EnginePhase.connected,
        ip: '5.123.45.67',
        country: 'IR',
        location: 'THR',
      );
      final cleared = snap.copyWith(
        phase: EnginePhase.scanning,
        clearExit: true,
        clearConnectedAt: true,
      );
      expect(cleared.ip, isEmpty);
      expect(cleared.country, isEmpty);
      expect(cleared.location, isEmpty);
      expect(cleared.connectedAt, isNull);
      // Without the flag the facts are kept, which is what the stats poller
      // relies on when a lookup answers only part of the picture.
      expect(snap.copyWith(phase: EnginePhase.scanning).country, 'IR');
    });
  });

  group('CountryPickerRow', () {
    testWidgets('marks the chosen countries and toggles on tap',
        (tester) async {
      List<String>? changed;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CountryPickerRow(
              selected: const ['DE'],
              onChanged: (v) => changed = v,
            ),
          ),
        ),
      );
      expect(find.text('Germany'), findsOneWidget);
      // Tapping an unselected country adds it…
      await tester.tap(find.text('Netherlands'));
      expect(changed, ['DE', 'NL']);
      // …tapping a selected one removes it.
      await tester.tap(find.text('Germany'));
      expect(changed, isEmpty);
    });

    testWidgets('Persian labels come from the country table', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Directionality(
              textDirection: TextDirection.rtl,
              child: CountryPickerRow(
                selected: const ['DE'],
                fa: true,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('آلمان'), findsOneWidget);
    });
  });
}
