import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/services/vpn_controller.dart';

void main() {
  group('watchdog backoff', () {
    test('the first retry is quick', () {
      expect(VpnController.watchdogDelay(1), const Duration(seconds: 2));
    });

    test('delays double each attempt', () {
      expect(VpnController.watchdogDelay(2), const Duration(seconds: 4));
      expect(VpnController.watchdogDelay(3), const Duration(seconds: 8));
      expect(VpnController.watchdogDelay(4), const Duration(seconds: 16));
    });

    test('the delay is capped so a dead network is not hammered forever',
        () {
      expect(VpnController.watchdogDelay(5), const Duration(seconds: 32));
      expect(VpnController.watchdogDelay(6), const Duration(seconds: 32));
      expect(VpnController.watchdogDelay(20), const Duration(seconds: 32));
    });

    test('nonsense attempt counts still give the quick first retry', () {
      expect(VpnController.watchdogDelay(0), const Duration(seconds: 2));
      expect(VpnController.watchdogDelay(-3), const Duration(seconds: 2));
    });

    test('the retry budget stays bounded', () {
      expect(VpnController.watchdogMaxTries, 5);
      // The whole worst-case wait across the budget stays under two minutes:
      // 2 + 4 + 8 + 16 + 32 = 62 s of waiting, plus the dials themselves.
      var total = Duration.zero;
      for (var i = 1; i <= VpnController.watchdogMaxTries; i++) {
        total += VpnController.watchdogDelay(i);
      }
      expect(total, const Duration(seconds: 62));
    });
  });
}
