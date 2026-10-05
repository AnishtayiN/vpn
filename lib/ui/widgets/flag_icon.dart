import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../data/countries.dart';
import '../../theme/voidrau_theme.dart';

/// Paints the flag of an exit country.
///
/// Everything is drawn from primitives — no image assets, no plugins — so the
/// same flag looks the same on Android and on Windows, where flag emoji render
/// as two letters. Unknown / anonymised codes fall back to a neutral globe
/// badge instead of a wrong flag.
class FlagIcon extends StatelessWidget {
  const FlagIcon({
    super.key,
    required this.countryCode,
    this.height = 20,
    this.radius = 3,
    this.showBorder = true,
  });

  static const double aspect = 1.5;

  final String? countryCode;
  final double height;
  final double radius;
  final bool showBorder;

  @override
  Widget build(BuildContext context) {
    final country = countryFlag(countryCode);
    final w = height * aspect;
    return Semantics(
      label: countryLabel(countryCode, fa: false),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: CustomPaint(
          size: Size(w, height),
          painter: _FlagPainter(country?.design, showBorder: showBorder),
        ),
      ),
    );
  }
}

class _FlagPainter extends CustomPainter {
  _FlagPainter(this.design, {required this.showBorder});

  final FlagDesign? design;
  final bool showBorder;

  static const _unknownBg = Color(0xFF223044);
  static const _border = Color(0x66000000);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final design = this.design;
    if (design == null) {
      _paintUnknown(canvas, rect);
    } else {
      canvas.save();
      canvas.clipRect(rect);
      _paintDesign(canvas, rect, design);
      canvas.restore();
    }
    if (showBorder) {
      canvas.drawRect(
        rect.deflate(0.4),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = _border,
      );
    }
  }

  void _paintUnknown(Canvas canvas, Rect rect) {
    canvas.drawRect(rect, Paint()..color = _unknownBg);
    final c = rect.center;
    final r = rect.height * 0.28;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = rect.height * 0.07
      ..color = VoidrauColors.muted;
    canvas.drawCircle(c, r, line);
    canvas.drawLine(Offset(c.dx - r, c.dy), Offset(c.dx + r, c.dy), line);
    final ellipse = Rect.fromCenter(
        center: c, width: r * 1.1, height: r * 2);
    canvas.drawOval(ellipse, line);
  }

  void _paintDesign(Canvas canvas, Rect rect, FlagDesign d) {
    switch (d.kind) {
      case FlagKind.hBands:
        _bands(canvas, rect, d.colors, d.weights, vertical: false);
      case FlagKind.vBands:
        _bands(canvas, rect, d.colors, d.weights, vertical: true);
      case FlagKind.nordic:
        _nordic(canvas, rect, d);
      case FlagKind.cross:
        canvas.drawRect(rect, _fill(d.colors[0]));
        _crossBars(canvas, rect,
            color: d.colors[1], thickness: rect.height * 0.18, inset: 0);
      case FlagKind.crossDiag:
        canvas.drawRect(rect, _fill(d.colors[0]));
        _saltire(canvas, rect, d.colors[1], rect.height * 0.2);
      case FlagKind.disc:
        canvas.drawRect(rect, _fill(d.colors[0]));
        canvas.drawCircle(rect.center, rect.height * 0.3, _fill(d.colors[1]));
      case FlagKind.discSplit:
        canvas.drawRect(rect, _fill(d.colors[0]));
        final r = rect.height * 0.3;
        final c = rect.center;
        canvas.save();
        canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r)));
        canvas.drawRect(
            Rect.fromLTRB(c.dx - r, c.dy - r, c.dx + r, c.dy),
            _fill(d.colors[1]));
        canvas.drawRect(
            Rect.fromLTRB(c.dx - r, c.dy, c.dx + r, c.dy + r),
            _fill(d.colors[2]));
        canvas.restore();
      case FlagKind.stripesUs:
        _unitedStates(canvas, rect, d);
      case FlagKind.jack:
        _unionJack(canvas, rect);
      case FlagKind.jackCanton:
        canvas.drawRect(rect, _fill(d.colors[0]));
        final canton = Rect.fromLTWH(0, 0, rect.width * 0.5, rect.height * 0.5);
        canvas.save();
        canvas.clipRect(canton);
        _unionJack(canvas, canton);
        canvas.restore();
        _starsCanton(canvas, canton, d.emblemColor, count: math.max(1, d.stars));
      case FlagKind.canton:
        _bands(canvas, rect, d.colors.sublist(1), null, vertical: false);
        canvas.drawRect(
          Rect.fromLTWH(0, 0, rect.width * 0.42, rect.height * 0.5),
          _fill(d.colors[0]),
        );
      case FlagKind.barLeft:
        final bands = d.colors.sublist(0, d.colors.length - 1);
        _bands(canvas, rect, bands, null, vertical: false);
        canvas.drawRect(
          Rect.fromLTWH(0, 0, rect.width * 0.3, rect.height),
          _fill(d.colors.last),
        );
      case FlagKind.hoistTriangle:
        final bands = d.colors.sublist(0, d.colors.length - 1);
        _bands(canvas, rect, bands, null, vertical: false);
        final tri = Path()
          ..moveTo(0, 0)
          ..lineTo(rect.width * 0.42, rect.height / 2)
          ..lineTo(0, rect.height)
          ..close();
        canvas.drawPath(tri, _fill(d.colors.last));
      case FlagKind.diagBand:
        _diagonal(canvas, rect, d);
      case FlagKind.quarters:
        _quarters(canvas, rect, d);
      case FlagKind.rhombus:
        canvas.drawRect(rect, _fill(d.colors[0]));
        final rh = Path()
          ..moveTo(rect.width / 2, rect.height * 0.08)
          ..lineTo(rect.width * 0.94, rect.height / 2)
          ..lineTo(rect.width / 2, rect.height * 0.92)
          ..lineTo(rect.width * 0.06, rect.height / 2)
          ..close();
        canvas.drawPath(rh, _fill(d.colors[1]));
        if (d.colors.length > 2) {
          canvas.drawCircle(
              rect.center, rect.height * 0.23, _fill(d.colors[2]));
        }
      case FlagKind.solid:
        canvas.drawRect(rect, _fill(d.colors[0]));
    }
    _emblem(canvas, rect, d);
  }

  // ── primitives ────────────────────────────────────────────────────────────

  Paint _fill(int rgb) => Paint()
    ..style = PaintingStyle.fill
    ..isAntiAlias = true
    ..color = Color(0xFF000000 | rgb);

  void _bands(
    Canvas canvas,
    Rect rect,
    List<int> colors,
    List<double>? weights, {
    required bool vertical,
  }) {
    if (colors.isEmpty) return;
    final raw = (weights != null && weights.length == colors.length)
        ? weights
        : List<double>.filled(colors.length, 1);
    final total = raw.fold<double>(0, (a, b) => a + b);
    var offset = 0.0;
    for (var i = 0; i < colors.length; i++) {
      final span = (vertical ? rect.width : rect.height) * raw[i] / total;
      final r = vertical
          ? Rect.fromLTWH(rect.left + offset, rect.top, span + 0.4, rect.height)
          : Rect.fromLTWH(rect.left, rect.top + offset, rect.width, span + 0.4);
      canvas.drawRect(r, _fill(colors[i]));
      offset += span;
    }
  }

  void _nordic(Canvas canvas, Rect rect, FlagDesign d) {
    canvas.drawRect(rect, _fill(d.colors[0]));
    final thickness = rect.height * 0.22;
    final cx = rect.left + rect.width * 0.36;
    canvas.drawRect(
      Rect.fromLTRB(cx - thickness / 2, rect.top, cx + thickness / 2, rect.bottom),
      _fill(d.colors[1]),
    );
    canvas.drawRect(
      Rect.fromLTRB(rect.left, rect.center.dy - thickness / 2, rect.right,
          rect.center.dy + thickness / 2),
      _fill(d.colors[1]),
    );
    if (d.colors.length > 2) {
      final inner = thickness * 0.45;
      canvas.drawRect(
        Rect.fromLTRB(
            cx - inner / 2, rect.top, cx + inner / 2, rect.bottom),
        _fill(d.colors[2]),
      );
      canvas.drawRect(
        Rect.fromLTRB(rect.left, rect.center.dy - inner / 2, rect.right,
            rect.center.dy + inner / 2),
        _fill(d.colors[2]),
      );
    }
  }

  void _crossBars(Canvas canvas, Rect rect,
      {required int color, required double thickness, double inset = 0}) {
    final paint = _fill(color);
    final vx = thickness * rect.height / rect.width;
    final cx = rect.center.dx;
    final cy = rect.center.dy;
    canvas.drawRect(
      Rect.fromLTRB(cx - vx / 2, rect.top + inset, cx + vx / 2,
          rect.bottom - inset),
      paint,
    );
    canvas.drawRect(
      Rect.fromLTRB(rect.left + inset, cy - thickness / 2, rect.right - inset,
          cy + thickness / 2),
      paint,
    );
  }

  void _saltire(Canvas canvas, Rect rect, int color, double thickness) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..isAntiAlias = true
      ..color = Color(0xFF000000 | color);
    canvas.drawLine(rect.topLeft, rect.bottomRight, paint);
    canvas.drawLine(rect.topRight, rect.bottomLeft, paint);
  }

  void _diagonal(Canvas canvas, Rect rect, FlagDesign d) {
    // colours: [upper-left, band, lower-right]
    final t = rect.height * 0.3;
    canvas.drawRect(rect, _fill(d.colors[1]));
    final upper = Path()
      ..moveTo(0, 0)
      ..lineTo(rect.width, 0)
      ..lineTo(rect.width, -t / 2)
      ..lineTo(0, rect.height - t / 2)
      ..close();
    final lower = Path()
      ..moveTo(0, rect.height + t / 2)
      ..lineTo(rect.width, t / 2)
      ..lineTo(rect.width, rect.height)
      ..lineTo(0, rect.height)
      ..close();
    canvas.save();
    canvas.clipPath(upper);
    canvas.drawRect(rect, _fill(d.colors[0]));
    canvas.restore();
    canvas.save();
    canvas.clipPath(lower);
    canvas.drawRect(rect, _fill(d.colors[2]));
    canvas.restore();
  }

  void _quarters(Canvas canvas, Rect rect, FlagDesign d) {
    final half = Rect.fromLTWH(0, 0, rect.width / 2, rect.height / 2);
    canvas.drawRect(half, _fill(d.colors[0]));
    canvas.drawRect(half.shift(Offset(rect.width / 2, 0)), _fill(d.colors[1]));
    canvas.drawRect(half.shift(Offset(0, rect.height / 2)), _fill(d.colors[2]));
    canvas.drawRect(
        half.shift(Offset(rect.width / 2, rect.height / 2)), _fill(d.colors[3]));
    final cross = d.crossColor;
    if (cross != null) {
      if (d.crossDiagonal) {
        _saltire(canvas, rect, cross, rect.height * 0.16);
      } else {
        _crossBars(canvas, rect, color: cross, thickness: rect.height * 0.18);
      }
    }
  }

  void _unitedStates(Canvas canvas, Rect rect, FlagDesign d) {
    final stripeH = rect.height / 13;
    for (var i = 0; i < 13; i++) {
      canvas.drawRect(
        Rect.fromLTWH(0, i * stripeH, rect.width, stripeH + 0.4),
        _fill(i.isEven ? d.colors[0] : d.colors[1]),
      );
    }
    final canton = Rect.fromLTWH(0, 0, rect.width * 0.42, stripeH * 7);
    canvas.drawRect(canton, _fill(d.colors[2]));
    _starsCanton(canvas, canton, 0xFFFFFF, count: 50);
  }

  void _unionJack(Canvas canvas, Rect rect) {
    canvas.drawRect(rect, _fill(0x012169));
    _saltire(canvas, rect, 0xFFFFFF, rect.height * 0.28);
    _saltire(canvas, rect, 0xC8102E, rect.height * 0.12);
    _crossBars(canvas, rect,
        color: 0xFFFFFF, thickness: rect.height * 0.3);
    _crossBars(canvas, rect, color: 0xC8102E, thickness: rect.height * 0.16);
  }

  /// Stars inside [area]: a dense field for the US canton, otherwise a small
  /// constellation for flags like Australia or New Zealand.
  void _starsCanton(Canvas canvas, Rect area, int color,
      {required int count}) {
    final paint = _fill(color);
    if (count > 20) {
      const rows = 9;
      for (var row = 0; row < rows; row++) {
        final n = row.isEven ? 6 : 5;
        for (var i = 0; i < n; i++) {
          final dx = area.left + area.width * (i + 0.5 + (row.isOdd ? 0.5 : 0)) / 6;
          final dy = area.top + area.height * (row + 0.5) / rows;
          canvas.drawCircle(Offset(dx, dy), area.height * 0.028, paint);
        }
      }
      return;
    }
    for (var i = 0; i < count; i++) {
      final dx = area.left + area.width * (0.3 + 0.22 * (i % 3));
      final dy = area.top + area.height * (0.35 + 0.24 * (i ~/ 3));
      _star(canvas, Offset(dx, dy), area.height * 0.1, paint);
    }
  }

  void _star(Canvas canvas, Offset center, double r, Paint paint) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final rad = i.isEven ? r : r * 0.42;
      final a = -math.pi / 2 + i * math.pi / 5;
      final p = Offset(center.dx + rad * math.cos(a), center.dy + rad * math.sin(a));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  // ── emblems ───────────────────────────────────────────────────────────────

  void _emblem(Canvas canvas, Rect rect, FlagDesign d) {
    if (d.emblem == Emblem.none) return;
    final paint = _fill(d.emblemColor);
    var center = rect.center;
    var r = rect.height * 0.24;
    switch (d.kind) {
      case FlagKind.canton:
        center = Offset(rect.width * 0.21, rect.height * 0.25);
        r = rect.height * 0.12;
      case FlagKind.jackCanton:
        return; // stars are painted with the canton
      case FlagKind.barLeft:
        center = Offset(rect.width * 0.55, rect.center.dy);
      case FlagKind.hoistTriangle:
        center = Offset(rect.width * 0.5, rect.center.dy);
      default:
        break;
    }
    switch (d.emblem) {
      case Emblem.none:
        break;
      case Emblem.crest:
        _crest(canvas, center, r, paint);
      case Emblem.cross:
        // Small centred plus (Greece's canton cross).
        final arm = r * 0.95;
        final bar = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.8, r * 0.3)
          ..strokeCap = StrokeCap.square
          ..color = Color(0xFF000000 | d.emblemColor);
        canvas.drawLine(center.translate(0, -arm), center.translate(0, arm), bar);
        canvas.drawLine(center.translate(-arm, 0), center.translate(arm, 0), bar);
      case Emblem.star:
        _star(canvas, center, r, paint);
      case Emblem.starRow:
        final n = math.max(1, d.stars);
        final spread = rect.width * 0.3;
        for (var i = 0; i < n; i++) {
          final t = n == 1 ? 0.5 : i / (n - 1);
          final dx = center.dx - spread / 2 + spread * t;
          final dy = center.dy + math.sin(math.pi * t) * -rect.height * 0.06;
          _star(canvas, Offset(dx, dy), rect.height * 0.09, paint);
        }
      case Emblem.crescent:
        _crescent(canvas, center, r, paint);
      case Emblem.crescentStar:
        _crescent(canvas, center.translate(-r * 0.35, 0), r, paint);
        _star(canvas, center.translate(r * 0.95, 0), r * 0.45, paint);
      case Emblem.disc:
        canvas.drawCircle(center, r * 1.1, paint);
      case Emblem.ring:
        canvas.drawCircle(
          center,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = rect.height * 0.05
            ..color = Color(0xFF000000 | d.emblemColor),
        );
      case Emblem.sun:
        canvas.drawCircle(center, r * 0.75, paint);
        final ray = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = rect.height * 0.045
          ..color = Color(0xFF000000 | d.emblemColor);
        for (var i = 0; i < 8; i++) {
          final a = i * math.pi / 4;
          canvas.drawLine(
            center + Offset(math.cos(a), math.sin(a)) * r * 0.95,
            center + Offset(math.cos(a), math.sin(a)) * r * 1.5,
            ray,
          );
        }
      case Emblem.hexagram:
        final stroke = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = rect.height * 0.035
          ..color = Color(0xFF000000 | d.emblemColor);
        canvas.drawPath(_polygon(center, r, 3, math.pi / 2), stroke);
        canvas.drawPath(_polygon(center, r, 3, -math.pi / 2), stroke);
      case Emblem.chakra:
        final stroke = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = rect.height * 0.035
          ..color = Color(0xFF000000 | d.emblemColor);
        canvas.drawCircle(center, r * 0.85, stroke);
        for (var i = 0; i < 12; i++) {
          final a = i * math.pi / 6;
          canvas.drawLine(
            center + Offset(math.cos(a), math.sin(a)) * r * 0.2,
            center + Offset(math.cos(a), math.sin(a)) * r * 0.8,
            stroke,
          );
        }
      case Emblem.leaf:
        _star(canvas, center, r, paint);
        canvas.drawRect(
          Rect.fromCenter(
              center: center.translate(0, r * 1.05),
              width: r * 0.18,
              height: r * 0.7),
          paint,
        );
      case Emblem.iranEmblem:
        _iranEmblem(canvas, center, r, paint);
      case Emblem.script:
        canvas.drawRect(
          Rect.fromCenter(
              center: center.translate(0, r * 0.75),
              width: r * 2.1,
              height: rect.height * 0.045),
          paint,
        );
        for (var i = -1; i <= 1; i++) {
          canvas.drawRect(
            Rect.fromCenter(
                center: center.translate(i * r * 0.65, -r * 0.25),
                width: r * 0.5,
                height: rect.height * 0.05),
            paint,
          );
        }
    }
  }

  void _crest(Canvas canvas, Offset center, double r, Paint paint) {
    final path = Path()
      ..moveTo(center.dx - r * 0.7, center.dy - r * 0.85)
      ..lineTo(center.dx + r * 0.7, center.dy - r * 0.85)
      ..quadraticBezierTo(center.dx + r * 0.7, center.dy + r * 0.5,
          center.dx, center.dy + r * 0.95)
      ..quadraticBezierTo(center.dx - r * 0.7, center.dy + r * 0.5,
          center.dx - r * 0.7, center.dy - r * 0.85)
      ..close();
    canvas.drawPath(path, paint);
  }

  void _crescent(Canvas canvas, Offset center, double r, Paint paint) {
    final outer = Path()
      ..addOval(Rect.fromCircle(center: center, radius: r));
    final inner = Path()
      ..addOval(Rect.fromCircle(
          center: center.translate(r * 0.42, 0), radius: r * 0.92));
    canvas.drawPath(
      Path.combine(ui.PathOperation.difference, outer, inner),
      paint,
    );
  }

  void _iranEmblem(Canvas canvas, Offset center, double r, Paint paint) {
    // Stylised stand-in for the emblem: a central tulip stroke with two
    // symmetric wings, plus the "bowl" stroke underneath.
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.8, r * 0.16)
      ..strokeCap = StrokeCap.round
      ..color = paint.color;
    canvas.drawLine(center.translate(0, -r * 0.9), center.translate(0, r * 0.5), stroke);
    for (final s in [-1.0, 1.0]) {
      final p = Path()
        ..moveTo(center.dx + s * r * 0.75, center.dy - r * 0.15)
        ..quadraticBezierTo(center.dx + s * r * 0.35, center.dy - r * 0.95,
            center.dx + s * r * 0.12, center.dy - r * 0.85);
      canvas.drawPath(p, stroke);
      final hook = Path()
        ..moveTo(center.dx + s * r * 0.72, center.dy - r * 0.2)
        ..quadraticBezierTo(center.dx + s * r * 0.55, center.dy + r * 0.5,
            center.dx + s * r * 0.18, center.dy + r * 0.62);
      canvas.drawPath(hook, stroke);
    }
    final bowl = Path()
      ..moveTo(center.dx - r * 0.82, center.dy + r * 0.55)
      ..quadraticBezierTo(center.dx, center.dy + r * 1.05,
          center.dx + r * 0.82, center.dy + r * 0.55);
    canvas.drawPath(bowl, stroke);
  }

  Path _polygon(Offset center, double r, int sides, double startAngle) {
    final path = Path();
    for (var i = 0; i < sides; i++) {
      final a = startAngle + i * 2 * math.pi / sides;
      final p = Offset(center.dx + r * math.cos(a), center.dy + r * math.sin(a));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path..close();
  }

  @override
  bool shouldRepaint(covariant _FlagPainter old) =>
      old.design != design || old.showBorder != showBorder;
}
