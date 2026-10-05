import 'package:flutter_test/flutter_test.dart';

import 'package:voidrauvpn/services/exit_pin.dart';

void main() {
  test('pin roundtrips through json', () {
    final pin = ExitPin(
      endpoint: '162.159.192.1:443',
      protocol: 'wg',
      country: 'DE',
      network: '',
      savedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    final back = ExitPin.fromJson(pin.toJson());
    expect(back, isNotNull);
    expect(back!.endpoint, pin.endpoint);
    expect(back.protocol, pin.protocol);
    expect(back.fresh, isTrue);
  });

  test('a stale pin is not fresh', () {
    final pin = ExitPin(
      endpoint: '162.159.192.1:443',
      protocol: 'wg',
      country: 'DE',
      network: '',
      savedAtMs: DateTime.now().millisecondsSinceEpoch -
          ExitPin.maxAgeMs -
          60000,
    );
    expect(pin.fresh, isFalse);
  });

  test('malformed json yields null, never throws', () {
    expect(ExitPin.fromJson({'protocol': 'wg'}), isNull);
    expect(ExitPin.fromJson({'endpoint': '', 'protocol': 'wg'}), isNull);
  });
}
