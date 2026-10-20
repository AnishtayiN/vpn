import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/data/jalali.dart';
import 'package:voidrauvpn/services/license_service.dart';

void main() {
  group('JalaliDate conversions', () {
    test('converts gregorian date to accurate Jalali date', () {
      final date = DateTime(2026, 10, 20);
      final j = JalaliDate.fromDateTime(date);
      expect(j.year, 1405);
      expect(j.month, 7);
      expect(j.day, 28);
      expect(j.format(), '1405/07/28');
      expect(j.formatReadable(persianDigits: false), '28 مهر 1405');
      expect(j.formatReadable(persianDigits: true), '۲۸ مهر ۱۴۰۵');
    });

    test('converts Nowruz (start of year)', () {
      final date = DateTime(2026, 3, 21);
      final j = JalaliDate.fromDateTime(date);
      expect(j.year, 1405);
      expect(j.month, 1);
      expect(j.day, 1);
      expect(j.format(), '1405/01/01');
    });

    test('toPersianDigits converts digits correctly', () {
      expect(JalaliDate.toPersianDigits('0123456789'), '۰۱۲۳۴۵۶۷۸۹');
      expect(JalaliDate.toPersianDigits('VDRV-1234'), 'VDRV-۱۲۳۴');
    });
  });

  group('LicenseService key extractor', () {
    test('extracts clean key', () {
      const key = 'VDRV-A1B2-C3D4-E5F6';
      expect(LicenseService.extractKey(key), key);
    });

    test('extracts key from surrounding persian text', () {
      const text = 'کد لایسنس شما: VDRV-88AA-BB99-CC11 موفق باشید';
      expect(LicenseService.extractKey(text), 'VDRV-88AA-BB99-CC11');
    });

    test('extracts lowercase key and normalizes to uppercase', () {
      const text = 'vdrv-1234-abcd-ef00';
      expect(LicenseService.extractKey(text), 'VDRV-1234-ABCD-EF00');
    });

    test('returns null for invalid strings', () {
      expect(LicenseService.extractKey(''), null);
      expect(LicenseService.extractKey(null), null);
      expect(LicenseService.extractKey('hello world'), null);
      expect(LicenseService.extractKey('VDRV-TOO-SHORT'), null);
    });
  });
}
