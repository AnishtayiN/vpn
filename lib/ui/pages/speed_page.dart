import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../models/engine_state.dart';
import '../../models/settings.dart';
import '../../services/vpn_controller.dart';
import '../../theme/voidrau_theme.dart';

/// Where a "slow VPN" complaint gets fixed.
///
/// Three quarters of the answer live in the core: the tier it detects from the
/// CPU and RAM sets the TCP window each connection advertises, and that window
/// divided by the round trip is the ceiling on a download. The rest is the
/// packet size the device sends and a handful of timeouts. Everything here is
/// applied on the next dial, and the page says so instead of pretending a
/// running tunnel changed underneath the user.
class SpeedPage extends StatefulWidget {
  const SpeedPage({super.key, required this.controller});
  final VpnController controller;

  @override
  State<SpeedPage> createState() => _SpeedPageState();
}

class _SpeedPageState extends State<SpeedPage> {
  final List<double> _down = [];
  final List<double> _up = [];
  static const int _history = 48;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sample);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sample);
    super.dispose();
  }

  void _sample() {
    final rate = widget.controller.rate;
    if (!rate.hasSample) return;
    _down.add(rate.downBytesPerSec);
    _up.add(rate.upBytesPerSec);
    if (_down.length > _history) _down.removeAt(0);
    if (_up.length > _history) _up.removeAt(0);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final s = c.s;
    final st = c.settings;
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 40),
          children: [
            Text(s.speedTitle,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(s.speedHelp,
                style: const TextStyle(color: VoidrauColors.muted, height: 1.45)),
            const SizedBox(height: 16),
            _traffic(c, s),
            const SizedBox(height: 18),
            _profile(c, s, st),
            const SizedBox(height: 18),
            _packets(c, s, st),
            const SizedBox(height: 18),
            _switches(c, s, st),
          ],
        );
      },
    );
  }

  // ── live meter ───────────────────────────────────────────────────────────

  Widget _traffic(VpnController c, S s) {
    final rate = c.rate;
    final connected = c.snapshot.phase == EnginePhase.connected;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(s.liveSpeed,
                  style: const TextStyle(
                      color: VoidrauColors.muted, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(connected ? s.active : s.ready,
                  style: TextStyle(
                    fontSize: 12,
                    color: connected ? VoidrauColors.cyan : VoidrauColors.muted,
                  )),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _big(
                  '↓',
                  _rate(rate.downBytesPerSec),
                  '${s.download} · ${_bytes(c.snapshot.downloadBytes)}',
                  VoidrauColors.cyan,
                ),
              ),
              Expanded(
                child: _big(
                  '↑',
                  _rate(rate.upBytesPerSec),
                  '${s.upload} · ${_bytes(c.snapshot.uploadBytes)}',
                  VoidrauColors.coral,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 46,
            child: CustomPaint(
              painter: _SparkPainter(_down, _up),
              size: Size.infinite,
            ),
          ),
        ],
      ),
    );
  }

  Widget _big(String arrow, String value, String caption, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$arrow $value',
          style: TextStyle(
              fontSize: 22, fontWeight: FontWeight.w800, color: color),
        ),
        const SizedBox(height: 2),
        Text(caption,
            style: const TextStyle(fontSize: 11, color: VoidrauColors.muted)),
      ],
    );
  }

  // ── performance profile ──────────────────────────────────────────────────

  Widget _profile(VpnController c, S s, VpnSettings st) {
    final descriptions = {
      PerfProfile.eco: s.perfEcoHelp,
      PerfProfile.auto: s.perfAutoHelp,
      PerfProfile.turbo: s.perfTurboHelp,
      PerfProfile.extreme: s.perfExtremeHelp,
    };
    final labels = {
      PerfProfile.eco: s.perfEco,
      PerfProfile.auto: s.perfAuto,
      PerfProfile.turbo: s.perfTurbo,
      PerfProfile.extreme: s.perfExtreme,
    };
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.speed_rounded, color: VoidrauColors.cyan, size: 20),
          const SizedBox(height: 8),
          // An iOS packet-tunnel extension cannot use the big buffers, and the
          // native side pins the tier there: offering the choice would be a lie.
          if (Platform.isIOS)
            Text(s.perfIosNote,
                style: const TextStyle(color: VoidrauColors.muted, height: 1.4))
          else ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: PerfProfile.values
                  .map((p) => ChoiceChip(
                        label: Text(labels[p]!),
                        selected: st.perf == p,
                        onSelected: (_) async {
                          await c.setPerf(p);
                          if (c.snapshot.phase == EnginePhase.connected) {
                            c.notifyToast(s.perfApplied);
                          }
                        },
                      ))
                  .toList(),
            ),
            const SizedBox(height: 10),
            Text(descriptions[st.perf]!,
                style: const TextStyle(color: VoidrauColors.muted, height: 1.4)),
          ],
          if (c.snapshot.phase == EnginePhase.connected)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: FilledButton.tonalIcon(
                onPressed: c.busy ? null : c.applyAndReconnect,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(s.applyNow),
              ),
            ),
        ],
      ),
    );
  }

  // ── MTU + TCP ────────────────────────────────────────────────────────────

  Widget _packets(VpnController c, S s, VpnSettings st) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.straighten_rounded,
              color: VoidrauColors.cyan, size: 20),
          const SizedBox(height: 8),
          _number(c, s, 'MTU', st.deviceMtu, s.mtuHelp, (v) {
            st.tunMtu = v;
          }, min: 1280, max: 9000),
          _number(c, s, s.coreMtuLabel, st.coreMtu, s.coreMtuHelp, (v) {
            st.coreMtu = v;
          }, min: 0, max: 1500),
          const Divider(height: 24),
          Text(s.tcpTuning,
              style: const TextStyle(
                  color: VoidrauColors.muted, fontWeight: FontWeight.w600)),
          _number(c, s, s.tcpConnect, st.tcpConnectSecs, null, (v) {
            st.tcpConnectSecs = v;
          }, min: 5, max: 120),
          _number(c, s, s.tcpKeepalive, st.tcpKeepaliveSecs, null, (v) {
            st.tcpKeepaliveSecs = v;
          }, min: 10, max: 600),
          _number(c, s, s.halfClose, st.halfCloseSecs, null, (v) {
            st.halfCloseSecs = v;
          }, min: 5, max: 300),
        ],
      ),
    );
  }

  Widget _switches(VpnController c, S s, VpnSettings st) {
    return _card(
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: st.quicV2,
            title: Text(s.quicV2),
            subtitle: Text(s.quicV2Help),
            onChanged: (v) {
              st.quicV2 = v;
              c.persist();
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: st.ech,
            title: Text(s.ech),
            subtitle: Text(s.echHelp),
            onChanged: (v) {
              st.ech = v;
              c.persist();
            },
          ),
        ],
      ),
    );
  }

  // ── helpers ──────────────────────────────────────────────────────────────

  Widget _number(
    VpnController c,
    S s,
    String label,
    int value,
    String? help,
    ValueChanged<int> onChanged, {
    required int min,
    required int max,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: TextFormField(
        initialValue: '$value',
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: label,
          helperText: help,
          helperMaxLines: 3,
          isDense: true,
          filled: true,
          fillColor: VoidrauColors.surface,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onChanged: (v) {
          final n = int.tryParse(v.trim());
          if (n == null) return;
          onChanged(n.clamp(min, max));
        },
        onFieldSubmitted: (_) => c.persist(),
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VoidrauColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: VoidrauColors.line),
      ),
      child: child,
    );
  }

  static String _rate(double bytesPerSec) {
    if (bytesPerSec < 1024) return '${bytesPerSec.round()} B/s';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  static String _bytes(int bytes) {
    if (bytes <= 0) return '0';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 10 || i == 0 ? 0 : 1)} ${units[i]}';
  }
}

/// Rolling down/up history: two filled lines on a shared scale, so a glance says
/// whether the tunnel is idle, busy, or saturated.
class _SparkPainter extends CustomPainter {
  _SparkPainter(this.down, this.up);
  final List<double> down;
  final List<double> up;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = VoidrauColors.line
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
