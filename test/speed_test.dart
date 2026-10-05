import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/services/speed.dart';

void main() {
  group('rate meter', () {
    test('the first reading is a baseline, not a rate', () {
      final meter = RateMeter();
      expect(meter.hasSample, isFalse);
      meter.update(1000, 500, at: DateTime(2026, 1, 1, 0, 0, 0));
      expect(meter.hasSample, isTrue);
      expect(meter.downBytesPerSec, 0);
      expect(meter.upBytesPerSec, 0);
    });

    test('a delta over time becomes bytes per second', () {
      final meter = RateMeter();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      meter.update(0, 0, at: t0);
      // 4 MiB in two seconds = 2 MiB/s.
      meter.update(4 * 1024 * 1024, 1024, at: t0.add(const Duration(seconds: 2)));
      expect(meter.downBytesPerSec, closeTo(2 * 1024 * 1024, 1));
      expect(meter.upBytesPerSec, closeTo(512, 1));
    });

    test('a burst is smoothed, not passed through', () {
      final meter = RateMeter(halfLife: const Duration(seconds: 4));
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      meter.update(0, 0, at: t0);
      meter.update(2 * 1024 * 1024, 0, at: t0.add(const Duration(seconds: 2)));
      final first = meter.downBytesPerSec;
      // Ten times the data in the same window: the reported rate must rise,
      // but nowhere near the instantaneous value.
      meter.update(22 * 1024 * 1024, 0,
          at: t0.add(const Duration(seconds: 4)));
      final instant = 10 * 1024 * 1024;
      expect(meter.downBytesPerSec, greaterThan(first));
      expect(meter.downBytesPerSec, lessThan(instant / 2));
    });

    test('a counter that went backwards is a new session', () {
      final meter = RateMeter();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      meter.update(0, 0, at: t0);
      meter.update(1024 * 1024, 0, at: t0.add(const Duration(seconds: 1)));
      expect(meter.downBytesPerSec, greaterThan(0));
      // The tunnel restarted: the counters start over instead of the meter
      // reporting a negative rate.
      meter.update(0, 0, at: t0.add(const Duration(seconds: 2)));
      expect(meter.downBytesPerSec, 0);
      expect(meter.upBytesPerSec, 0);
    });

    test('reset clears the history', () {
      final meter = RateMeter();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      meter.update(0, 0, at: t0);
      meter.update(2048, 0, at: t0.add(const Duration(seconds: 1)));
      meter.reset();
      expect(meter.hasSample, isFalse);
      expect(meter.downBytesPerSec, 0);
    });

    test('the meter is the only thing this file provides', () {
      // The download test that used to live here is gone on purpose: the app
      // must make the tunnel faster, not measure it. The dashboard reads this
      // meter while the user's own traffic is running.
      expect(RateMeter().downBytesPerSec, 0);
    });
  });
}
