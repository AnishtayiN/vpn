import 'package:flutter/material.dart';

import '../../app_info.dart';

/// The circular Telegram button in the top bar, wired to the official channel.
///
/// The paper-plane mark is drawn instead of shipping a brand asset, which keeps
/// the package free of third-party artwork.
class TelegramButton extends StatelessWidget {
  const TelegramButton({
    super.key,
    this.size = 36,
    this.onPressed,
    this.tooltip,
  });

  final double size;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '${AppInfo.telegramHandle} · Telegram',
      child: InkResponse(
        radius: size * 0.7,
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: SizedBox(
            width: size,
            height: size,
            child: CustomPaint(painter: _TelegramPainter()),
          ),
        ),
      ),
    );
  }
}

class _TelegramPainter extends CustomPainter {
  static final _plane = Path()
    ..moveTo(0.08, 0.86)
    ..lineTo(0.95, 0.50)
    ..lineTo(0.08, 0.14)
    ..lineTo(0.08, 0.42)
    ..lineTo(0.62, 0.50)
    ..lineTo(0.08, 0.58)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final circle = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF2AABEE), Color(0xFF1769FF)],
      ).createShader(rect);
    canvas.drawCircle(rect.center, size.width / 2, circle);

    canvas.save();
    canvas.translate(rect.width * 0.22, rect.height * 0.22);
    canvas.scale(rect.width * 0.56, rect.height * 0.56);
    canvas.drawPath(
      _plane,
      Paint()
        ..color = Colors.white
        ..isAntiAlias = true,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
