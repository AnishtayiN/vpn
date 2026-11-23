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

  group('rate history (the home-card graph)', () {
    test('the baseline reading records nothing', () {
      final meter = RateMeter();
      meter.update(1000, 500, at: DateTime(2026, 1, 1, 0, 0, 0));
      expect(meter.downHistory, isEmpty);
      expect(meter.upHistory, isEmpty);
    });

    test('each computed rate is appended, oldest first', () {
      final meter = RateMeter();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      meter.update(0, 0, at: t0);
      meter.update(2048, 1024, at: t0.add(const Duration(seconds: 1)));
      meter.update(6144, 1024, at: t0.add(const Duration(seconds: 2)));
      expect(meter.downHistory.length, 2);
      expect(meter.downHistory.first, closeTo(2048, 1));
      // Second sample is the smoothed rate, above the first.
      expect(meter.downHistory.last, greaterThan(meter.downHistory.first));
      expect(meter.upHistory.length, 2);
    });

    test('a backwards counter records the drop to zero', () {
      final meter = RateMeter();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      meter.update(0, 0, at: t0);
      meter.update(1024 * 1024, 0, at: t0.add(const Duration(seconds: 1)));
      meter.update(0, 0, at: t0.add(const Duration(seconds: 2)));
      expect(meter.downHistory.last, 0);
    });

    test('history is capped and reset clears it', () {
      final meter = RateMeter();
      var t = DateTime(2026, 1, 1, 0, 0, 0);
      meter.update(0, 0, at: t);
      for (var i = 1; i <= RateMeter.historyLength + 10; i++) {
        t = t.add(const Duration(seconds: 1));
        meter.update(i * 1024, 0, at: t);
      }
      expect(meter.downHistory.length, RateMeter.historyLength);
      meter.reset();
      expect(meter.downHistory, isEmpty);
      expect(meter.upHistory, isEmpty);
    });
  });
}
