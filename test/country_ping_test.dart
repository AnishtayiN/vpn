import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voidrauvpn/services/country_ping.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('country ping store', () {
    test('an unmeasured country is unavailable, never a number', () async {
      final store = CountryPingStore();
      await store.load();
      expect(store.of('DE'), isNull);
      expect(store.all, isEmpty);
    });

    test('a recorded measurement is readable, any case', () async {
      final store = CountryPingStore();
      await store.record('de', 87);
      expect(store.of('DE')?.ms, 87);
      expect(store.of('de')?.ms, 87);
      expect(store.of('NL'), isNull);
    });

    test('measurements survive a reload (persisted)', () async {
      final first = CountryPingStore();
      await first.record('DE', 92);
      await first.record('NL', 140);

      final second = CountryPingStore();
      await second.load();
      expect(second.of('DE')?.ms, 92);
      expect(second.of('NL')?.ms, 140);
      expect(second.all.length, 2);
    });

    test('a newer measurement replaces the older one', () async {
      final store = CountryPingStore();
      await store.record('DE', 200);
      await store.record('DE', 85);
      expect(store.of('DE')?.ms, 85);
      expect(store.all.length, 1);
    });

    test('failed or junk measurements are dropped, not filed', () async {
      final store = CountryPingStore();
      await store.record('DE', 0);
      await store.record('DE', -5);
      await store.record('', 100);
      await store.record('Germany', 100);
      await store.record('D', 100);
      expect(store.all, isEmpty);
    });

    test('a corrupt stored value loads as empty instead of throwing',
        () async {
      SharedPreferences.setMockInitialValues({'countryPings': 'not json'});
      final store = CountryPingStore();
      await store.load();
      expect(store.all, isEmpty);
      expect(store.of('DE'), isNull);
    });
  });
}
