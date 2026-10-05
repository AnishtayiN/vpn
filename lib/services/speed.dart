import 'dart:math' as math;

/// Turns the monotonic byte counters the engines publish (Android's TUN bridge
/// through JNI, the core's own `--stats` line on Windows) into a live rate.
///
/// This is the number the dashboard shows while a download runs — the tunnel
/// saying how much it is actually carrying.
///
/// The counters arrive every couple of seconds, so the rate is smoothed with an
/// exponential average: without it the number jumps between zero and twice its
/// real value as each sample lands.
class RateMeter {
  RateMeter({this.halfLife = const Duration(seconds: 4)});

  /// Time constant of the smoothing.
  final Duration halfLife;

  int? _lastDown;
  int? _lastUp;
  DateTime? _at;
  double _down = 0;
  double _up = 0;

  double get downBytesPerSec => _down;
  double get upBytesPerSec => _up;

  bool get hasSample => _at != null;

  /// Feeds a new absolute reading. A counter that went *backwards* is a fresh
  /// session (the tunnel restarted), so the meter resets instead of reporting a
  /// negative rate.
  void update(int downBytes, int upBytes, {DateTime? at}) {
    final now = at ?? DateTime.now();
    final lastDown = _lastDown;
    final lastUp = _lastUp;
    final lastAt = _at;
    _lastDown = downBytes;
    _lastUp = upBytes;
    _at = now;
    if (lastAt == null || lastDown == null || lastUp == null) return;
    if (downBytes < lastDown || upBytes < lastUp) {
      _down = 0;
      _up = 0;
      return;
    }
    final seconds = now.difference(lastAt).inMilliseconds / 1000.0;
    if (seconds <= 0) return;
    final instantDown = (downBytes - lastDown) / seconds;
    final instantUp = (upBytes - lastUp) / seconds;
    final half = halfLife.inMilliseconds / 1000.0;
    final alpha =
        half <= 0 ? 1.0 : 1 - math.pow(0.5, seconds / half).toDouble();
    _down = _down == 0 ? instantDown : _down + alpha * (instantDown - _down);
    _up = _up == 0 ? instantUp : _up + alpha * (instantUp - _up);
  }

  void reset() {
    _lastDown = null;
    _lastUp = null;
    _at = null;
    _down = 0;
    _up = 0;
  }
}
