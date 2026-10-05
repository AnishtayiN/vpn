import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/engine_state.dart';
import '../../theme/voidrau_theme.dart';

class OrbButton extends StatefulWidget {
  const OrbButton({
    super.key,
    required this.phase,
    required this.label,
    required this.hint,
    required this.onTap,
    this.mercury = true,
  });

  final EnginePhase phase;
  final String label;
  final String hint;
  final VoidCallback onTap;
  final bool mercury;

  @override
  State<OrbButton> createState() => _OrbButtonState();
}

class _OrbButtonState extends State<OrbButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void initState() {
    super.initState();
    _updateAnimation();
  }

  @override
  void didUpdateWidget(covariant OrbButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phase != widget.phase) _updateAnimation();
  }

  /// The idle glow should not run forever: repeat() only while the phase is
  /// visually live (busy or connected); disconnected/error freeze the last
  /// frame, which saves battery on the always-on home screen.
  void _updateAnimation() {
    final live = widget.phase != EnginePhase.disconnected &&
        widget.phase != EnginePhase.error;
    if (live) {
      _c.repeat();
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = widget.phase == EnginePhase.connected;
    final busy = widget.phase == EnginePhase.connecting ||
        widget.phase == EnginePhase.scanning ||
        widget.phase == EnginePhase.reconnecting ||
        widget.phase == EnginePhase.preparing;
    final error = widget.phase == EnginePhase.error;

    final colors = error
        ? const [Color(0xFFFF6B74), Color(0xFF761527)]
        : connected
            ? const [Color(0xFF2AE5F5), Color(0xFF0867E8), Color(0xFF082E83)]
            : busy
                ? const [VoidrauColors.cyan, VoidrauColors.violet, VoidrauColors.blue]
                : const [Color(0xFFFF7680), Color(0xFF9D152C)];

    final inner = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          connected ? Icons.shield : Icons.power_settings_new,
          size: 42,
          color: Colors.white,
        ),
        const SizedBox(height: 10),
        Text(
          widget.label,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 20,
            letterSpacing: 1.4,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          widget.hint,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.78),
            fontSize: 13,
          ),
        ),
      ],
    );

    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return GestureDetector(
          onTap: widget.onTap,
          child: SizedBox(
            width: 250,
            height: 250,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(
                  colors: [...colors, colors.first],
                  transform: busy
                      ? GradientRotation(_c.value * 6.283)
                      : const GradientRotation(-0.6),
                ),
                boxShadow: [
                  BoxShadow(
                    color: (connected ? VoidrauColors.cyan : VoidrauColors.coral)
                        .withValues(alpha: 0.35),
                    blurRadius: 42,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: widget.mercury
                          ? [
                              colors[(_c.value * colors.length).floor() %
                                  colors.length],
                              colors.last,
                              colors.first,
                            ]
                          : colors,
                    ),
                  ),
                  child: widget.mercury
                      ? CustomPaint(
                          painter: _MercuryPainter(t: _c.value, colors: colors),
                          child: inner,
                        )
                      : inner,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MercuryPainter extends CustomPainter {
  _MercuryPainter({required this.t, required this.colors});

  final double t;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.shortestSide / 2;
    final highlight = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.35, -0.4),
        colors: [
          Colors.white.withValues(alpha: 0.35),
          colors.first.withValues(alpha: 0.12),
          Colors.transparent,
        ],
      ).createShader(Rect.fromCircle(center: c, radius: r));
    canvas.drawCircle(c, r, highlight);
    final blob = Paint()
      ..color = colors.last.withValues(alpha: 0.28)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);
    canvas.drawCircle(
      Offset(
        c.dx + math.sin(t * math.pi * 2) * r * 0.22,
        c.dy + math.cos(t * math.pi * 2.4) * r * 0.18,
      ),
      r * 0.46,
      blob,
    );
    final blob2 = Paint()
      ..color = colors.first.withValues(alpha: 0.22)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);
    canvas.drawCircle(
      Offset(
        c.dx + math.cos(t * math.pi * 2.7) * r * 0.2,
        c.dy + math.sin(t * math.pi * 1.7) * r * 0.16,
      ),
      r * 0.32,
      blob2,
    );
  }

  @override
  bool shouldRepaint(covariant _MercuryPainter old) =>
      old.t != t || old.colors != colors;
}
