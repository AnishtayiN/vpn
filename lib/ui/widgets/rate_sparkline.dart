import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/voidrau_theme.dart';

/// Rolling down/up history: two lines on a shared scale, so a glance says
/// whether the tunnel is idle, busy, or saturated.
///
/// Cyan is download, coral is upload — the same pairing the Speed page has
/// always used, now shared with the Connect page's hero card so the two
/// graphs can never drift apart in colour or scale.
class RateSparkline extends StatelessWidget {
  const RateSparkline({
    super.key,
    required this.down,
    required this.up,
    this.height = 46,
  });

  /// Download rates (bytes/s), oldest first.
  final List<double> down;

  /// Upload rates (bytes/s), oldest first.
  final List<double> up;

  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _SparkPainter(
          down,
          up,
          gridColor: VoidrauTheme.lineOf(context),
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.down, this.up, {required this.gridColor});
  final List<double> down;
  final List<double> up;

  /// Theme-aware grid colour (the painter itself has no BuildContext).
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - 0.5),
        Offset(size.width, size.height - 0.5), grid);
    var peak = 0.0;
    for (final v in [...down, ...up]) {
      peak = math.max(peak, v);
    }
    if (peak <= 0) return;
    _line(canvas, size, down, peak, VoidrauColors.cyan);
    _line(canvas, size, up, peak, VoidrauColors.coral);
  }

  void _line(Canvas canvas, Size size, List<double> values, double peak,
      Color color) {
    if (values.length < 2) return;
    final step = size.width / (values.length - 1);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final y = size.height - (values[i] / peak) * (size.height - 4) - 2;
      final x = i * step;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter old) {
    if (old.gridColor != gridColor) return true;
    if (old.down.length != down.length || old.up.length != up.length) {
      return true;
    }
    if (down.isEmpty && up.isEmpty) return false;
    final lastDownOld = old.down.isEmpty ? 0 : old.down.last;
    final lastUpOld = old.up.isEmpty ? 0 : old.up.last;
    final lastDown = down.isEmpty ? 0 : down.last;
    final lastUp = up.isEmpty ? 0 : up.last;
    return lastDownOld != lastDown || lastUpOld != lastUp;
  }
}
