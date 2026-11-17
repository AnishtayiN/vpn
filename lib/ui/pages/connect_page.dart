import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/countries.dart';
import '../../l10n/strings.dart';
import '../../models/engine_state.dart';
import '../../models/settings.dart';
import '../../services/split.dart';
import '../../services/vpn_controller.dart';
import '../../theme/voidrau_theme.dart';
import '../widgets/country_picker.dart';
import '../widgets/flag_icon.dart';
import '../widgets/mode_cards.dart';
import '../widgets/orb_button.dart';

class ConnectPage extends StatelessWidget {
  const ConnectPage({super.key, required this.controller, this.onShowDiagnostics});
  final VpnController controller;

  /// Opens the Diagnostics page (the shell owns navigation).
  final VoidCallback? onShowDiagnostics;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.s;
    final snap = c.snapshot;
    String label;
    switch (snap.phase) {
      case EnginePhase.connected:
        label = s.disconnect;
      case EnginePhase.disconnected:
      case EnginePhase.error:
        label = s.connect;
      case EnginePhase.disconnecting:
        label = s.disconnecting.toUpperCase();
      default:
        label = s.connecting.toUpperCase();
    }
    // M1: while a license re-check is actually running, the orb says so
    // instead of hanging on a stale label with no feedback.
    if (c.licenseChecking) label = s.checking;
    String title;
    switch (snap.phase) {
      case EnginePhase.connected:
        title = s.active;
      case EnginePhase.error:
        title = s.error;
      case EnginePhase.scanning:
        title = s.scanning;
      case EnginePhase.reconnecting:
        title = s.reconnecting;
      case EnginePhase.disconnecting:
        title = s.disconnecting;
      case EnginePhase.connecting:
      case EnginePhase.preparing:
        title = s.connecting;
      case EnginePhase.disconnected:
        title = s.ready;
    }
    final connected = snap.phase == EnginePhase.connected;
    // C2: a responsive orb diameter — at most 250, shrinking on narrow
    // screens, landscape, and large text scales so the page never overflows.
    final orbSize =
        math.min(250.0, MediaQuery.sizeOf(context).width * 0.62);

    return SingleChildScrollView(
      child: Column(
        children: [
          if (c.update?.available == true) _updateBar(context, c, s),
          if (connected) _HeroCard(controller: c),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: OrbButton(
              phase: snap.phase,
              label: label,
              hint: snap.phase == EnginePhase.disconnected
                  ? s.tapToSecure
                  : title,
              mercury: c.settings.orbStyle == OrbStyle.mercury,
              size: orbSize,
              onTap: c.toggle,
            ),
          ),
          // Improvement 9: the status pill and the title cross-fade when the
          // phase changes instead of snapping to the new text.
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Container(
              key: ValueKey(snap.phase),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: snap.phase == EnginePhase.connected
                    ? const Color(0x3327D7F2)
                    : snap.phase == EnginePhase.error
                        ? const Color(0x33FF5D67)
                        : VoidrauTheme.surfaceOf(context),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: VoidrauTheme.lineOf(context)),
              ),
              child: Text(
                title,
                style: TextStyle(
                  color: snap.phase == EnginePhase.connected
                      ? VoidrauColors.cyan
                      : snap.phase == EnginePhase.error
                          ? VoidrauColors.coral
                          : VoidrauTheme.mutedOf(context),
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Text(
              title,
              key: ValueKey(snap.phase),
              style:
                  const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 6),
          // While the exit-country rule is on, the status line reports the search
          // (which countries have already been rejected, which attempt this is)
          // instead of a generic "scanning".
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              snap.isActive &&
                      c.exitFilterActive &&
                      c.exitSearchStatus.isNotEmpty
                  ? c.exitSearchStatus
                  : (snap.message.isEmpty
                      ? s.socksHint(c.settings.socksPort)
                      : snap.message),
              textAlign: TextAlign.center,
              style: TextStyle(color: VoidrauTheme.mutedOf(context)),
            ),
          ),
          // A failed connect names its cause in the status line above; the
          // full core log lives in Diagnostics — one tap away, not buried.
          if (snap.phase == EnginePhase.error && onShowDiagnostics != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextButton.icon(
                onPressed: onShowDiagnostics,
                icon: const Icon(Icons.bug_report_outlined, size: 18),
                label: Text(s.showDiagnostics),
              ),
            ),
          // One line that says which tunnel the orb is about to dial — engine
          // plus mode — so the user never has to reconcile the three pickers
          // (protocol, standalone mode, Xray mode) in their head.
          if (!connected)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _modeSummary(c, s),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: VoidrauColors.cyan,
                    fontWeight: FontWeight.w600,
                    fontSize: 12),
              ),
            ),
          // The exit rule only applies to Aether: while Xray is the selected
          // engine the badge would describe a rule no tunnel enforces.
          if (!connected && !c.useXray)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ExitFilterBadge(controller: c),
            ),
          // Standalone Psiphon-only / Tor-only mode, when selected: the mode
          // itself is already in the summary line above, so only the notes
          // that change behaviour stay here — Tor is the heaviest mode, and
          // both hops are slow starters.
          if (c.standaloneHopActive && !c.useXray)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                children: [
                  if (c.settings.standaloneMode == StandaloneMode.torOnly)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        s.standaloneTorHeavy,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: VoidrauTheme.mutedOf(context), fontSize: 12),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      s.standaloneSlow,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: VoidrauTheme.mutedOf(context), fontSize: 12),
                    ),
                  ),
                  if (c.standaloneHopUnverified)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        s.standaloneUnverified,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: VoidrauColors.coral, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          // Xray engine (Android only): mode cards, shared with Config and
          // Settings (improvement 4) — one widget, one definition.
          if (Platform.isAndroid && !connected)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.xrayTitle,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  XrayModeCards(
                    mode: c.settings.xrayMode,
                    onChanged: (mode) {
                      c.settings.xrayMode = mode;
                      c.persist();
                    },
                  ),
                ],
              ),
            ),
          // The one-tap "connect with the Iran IP" answer used to be permanent:
          // the rule was switched off and forgotten, which is how a user ends up
          // with "only the local IP connects". It is a pause now, and this is
          // where it is both shown and lifted.
          if (c.exitRulePaused)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Column(
                children: [
                  Text(
                    s.exitPausedTitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: VoidrauColors.coral,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    s.exitPausedBody,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: VoidrauTheme.mutedOf(context), fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    onPressed: c.busy ? null : c.resumeExitRule,
                    icon: const Icon(Icons.travel_explore, size: 18),
                    label: Text(s.exitResume),
                  ),
                ],
              ),
            ),
          // Device VPN was asked for but this instance is not elevated: one tap
          // does the UAC relaunch instead of leaving the user to find the exe,
          // close the app and right-click it.
          if (c.needsElevation)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton.tonalIcon(
                onPressed: c.restartAsAdmin,
                icon: const Icon(Icons.shield_outlined, size: 18),
                label: Text(s.restartAsAdmin),
              ),
            ),
          TextButton(
            onPressed: () {
              Clipboard.setData(
                ClipboardData(text: '127.0.0.1:${c.settings.socksPort}'),
              );
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(s.copied)));
            },
            child: Text(s.copyProxy),
          ),
          // M7: fixed two-line metrics — live rate on line one, running total
          // on line two ('—' when idle). The height never changes as the rate
          // crosses 512 B/s, so the bottom of the page stops jumping.
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
            child: Row(
              children: [
                _metric(
                  context,
                  s.download,
                  connected && c.rate.downBytesPerSec > 0
                      ? _rate(c.rate.downBytesPerSec)
                      : '—',
                  _fmt(snap.downloadBytes),
                ),
                _metric(
                  context,
                  s.upload,
                  connected && c.rate.upBytesPerSec > 0
                      ? _rate(c.rate.upBytesPerSec)
                      : '—',
                  _fmt(snap.uploadBytes),
                ),
              ],
            ),
          ),
          if (SplitRules.summary(c.settings,
                  fa: s.isFa, android: Platform.isAndroid)
              .isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${s.splitTitle}: '
                '${SplitRules.summary(c.settings, fa: s.isFa, android: Platform.isAndroid)}',
                style:
                    const TextStyle(color: VoidrauColors.cyan, fontSize: 11.5),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Text(
              connected
                  ? s.freeNote
                  : (snap.isActive ? s.detecting : s.freeNote),
              textAlign: TextAlign.center,
              style:
                  TextStyle(color: VoidrauTheme.mutedOf(context), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  /// A newer release exists: this build can no longer connect, and the only
  /// route to a working app is the Telegram channel.
  Widget _updateBar(BuildContext context, VpnController c, S s) {
    return Material(
      color: const Color(0xFF163149),
      child: InkWell(
        onTap: () => c.downloadUpdate(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(
            children: [
              Row(
                children: [
                  const Icon(Icons.system_update_alt,
                      color: VoidrauColors.cyan),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${s.updateAvailable}: v${c.blockedVersion}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    c.downloading ? s.downloading : s.downloadFromChannel,
                    style: const TextStyle(color: VoidrauColors.cyan),
                  ),
                ],
              ),
              if (c.downloading)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: LinearProgressIndicator(value: c.downloadProgress),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Fixed two-line metric (M7): label, live rate, running total.
  Widget _metric(
      BuildContext context, String label, String rateLine, String totalLine) {
    return Expanded(
      child: Column(
        children: [
          Text(label,
              style: TextStyle(
                  color: VoidrauTheme.mutedOf(context), fontSize: 12)),
          const SizedBox(height: 4),
          Text(rateLine,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(totalLine,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  /// `12.4 MB/s`, `640 KB/s`, `812 B/s`.
  String _rate(double bytesPerSec) => _rateStatic(bytesPerSec);

  String _fmt(int bytes) {
    if (bytes <= 0) return '—';
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 10 || i == 0 ? 0 : 1)} ${units[i]}';
  }

}

// Shared byte/rate/uptime formatting used by both the page and the hero
// card (they are separate widgets, so the helpers are top-level).
String _rateStatic(double bytesPerSec) {
  if (bytesPerSec < 1024) return '${bytesPerSec.round()} B/s';
  if (bytesPerSec < 1024 * 1024) {
    return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/s';
  }
  return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
}

/// The single "which tunnel runs" line: engine plus mode, in one sentence.
/// A standalone mode wins over any second hop (the hop is ignored there),
/// so the hop is only named in Standard mode; a reverse hop forces MASQUE
/// over HTTP/2 in the core, so the protocol shown is the one that runs.
String _modeSummary(VpnController c, S s) {
  final st = c.settings;
  if (c.useXray) {
    final mode = switch (st.xrayMode) {
      XrayMode.worker => s.xrayWorker,
      XrayMode.warp => s.xrayWarp,
      XrayMode.serverless => s.xrayServerless,
      XrayMode.off => s.xrayOff,
    };
    return s.connectionModeLine('Xray', mode);
  }
  if (st.standaloneMode == StandaloneMode.psiphonOnly) {
    return s.connectionModeLine('Aether', s.hopPsiphonOnly);
  }
  if (st.standaloneMode == StandaloneMode.torOnly) {
    return s.connectionModeLine('Aether', s.hopTorOnly);
  }
  final protocol = switch (st.protocol) {
    Protocol.smart => 'Smart',
    Protocol.masque => 'MASQUE',
    Protocol.wg => 'WireGuard',
    Protocol.gool => 'gool',
    Protocol.mim => 'MASQUE×2',
  };
  final hop = switch (st.secondHop) {
    SecondHop.off => '',
    SecondHop.psiphon => s.hopPsiphon,
    SecondHop.psiphonReverse => s.hopPsiphonReverse,
    SecondHop.tor => s.hopTor,
    SecondHop.torReverse => s.hopTorReverse,
  };
  final mode = hop.isEmpty ? protocol : '$protocol + $hop';
  return s.connectionModeLine('Aether', mode);
}

/// Ping quality, same thresholds as the Speed page (<70 excellent, <130 good,
/// <220 fair, else poor). The gauge bar is ping/300 clamped, so a 300 ms+
/// ping fills the bar in the poor colour.
({Color color, double fraction}) _pingQuality(int? pingMs) {
  if (pingMs == null) return (color: Colors.grey, fraction: 0);
  final fraction = (pingMs / 300).clamp(0.05, 1.0);
  if (pingMs < 70) return (color: VoidrauColors.cyan, fraction: fraction);
  if (pingMs < 130) return (color: const Color(0xFF4ADE80), fraction: fraction);
  if (pingMs < 220) return (color: const Color(0xFFFBBF24), fraction: fraction);
  return (color: VoidrauColors.coral, fraction: fraction);
}

/// Improvement 3 — the connected hero card: the exit-IP card, the live
/// up/down and the ticking uptime merged into one card. Ping lives HERE and
/// nowhere else on this page any more (it used to appear in the exit card,
/// the metrics row and the speed page header).
///
/// While the exit is still being detected the card shows a pulsing skeleton
/// (improvement 9) instead of an empty flag and dashes.
class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.controller});
  final VpnController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.s;
    final snap = c.snapshot;
    final code = snap.country.trim().toUpperCase();
    final name = countryLabel(code, fa: s.isFa);
    final detecting = snap.ip.isEmpty;
    final ping = _pingQuality(snap.pingMs);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Material(
        color: VoidrauTheme.surfaceOf(context),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: detecting
              ? null
              : () {
                  Clipboard.setData(ClipboardData(text: snap.ip));
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(s.ipCopied)));
                },
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: VoidrauTheme.lineOf(context)),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    if (detecting)
                      const _SkeletonBox(width: 44, height: 32, radius: 6)
                    else
                      FlagIcon(
                        countryCode: code.isEmpty ? null : code,
                        height: 32,
                        radius: 6,
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (detecting) ...[
                            const _SkeletonBox(width: 120, height: 16),
                            const SizedBox(height: 6),
                            const _SkeletonBox(width: 160, height: 12),
                          ] else ...[
                            Text(
                              name.isEmpty ? s.detecting : name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800, fontSize: 17),
                            ),
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    snap.ip,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontFamily: 'Consolas',
                                      fontSize: 13,
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                ),
                                if (snap.location.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      snap.location,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: VoidrauTheme.mutedOf(context),
                                          fontSize: 12),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          s.exitIp,
                          style: TextStyle(
                              color: VoidrauTheme.mutedOf(context),
                              fontSize: 10),
                        ),
                        const SizedBox(height: 4),
                        if (detecting)
                          const _SkeletonBox(width: 56, height: 14)
                        else ...[
                          Text(
                            snap.pingMs == null ? '—' : '${snap.pingMs} ms',
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                                color: ping.color),
                          ),
                          const SizedBox(height: 5),
                          SizedBox(
                            width: 64,
                            height: 5,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: LinearProgressIndicator(
                                value: ping.fraction,
                                backgroundColor:
                                    VoidrauTheme.lineOf(context),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                    ping.color),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    // 48 dp copy target (improvement 12).
                    IconButton(
                      onPressed: detecting
                          ? null
                          : () {
                              Clipboard.setData(
                                  ClipboardData(text: snap.ip));
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(s.ipCopied)));
                            },
                      icon: const Icon(Icons.copy, size: 18),
                      tooltip: s.ipCopied,
                      constraints: const BoxConstraints(
                          minWidth: 48, minHeight: 48),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Divider(
                    height: 1, color: VoidrauTheme.lineOf(context)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _HeroStat(
                        icon: Icons.arrow_downward,
                        label: s.download,
                        value: detecting
                            ? '—'
                            : '${_rateStatic(c.rate.downBytesPerSec)} · ${_fmtStatic(snap.downloadBytes)}',
                      ),
                    ),
                    Expanded(
                      child: _HeroStat(
                        icon: Icons.arrow_upward,
                        label: s.upload,
                        value: detecting
                            ? '—'
                            : '${_rateStatic(c.rate.upBytesPerSec)} · ${_fmtStatic(snap.uploadBytes)}',
                      ),
                    ),
                    Expanded(
                      child: _HeroStat(
                        icon: Icons.timer_outlined,
                        label: s.duration,
                        // m24: only this text rebuilds on the 1 s tick.
                        valueWidget: snap.connectedAt == null
                            ? null
                            : ValueListenableBuilder<int>(
                                valueListenable: c.uptimeTick,
                                builder: (context, _, __) => Text(
                                  _uptimeStatic(snap.connectedAt!),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13),
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({
    required this.icon,
    required this.label,
    this.value,
    this.valueWidget,
  });

  final IconData icon;
  final String label;
  final String? value;
  final Widget? valueWidget;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 13, color: VoidrauTheme.mutedOf(context)),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    color: VoidrauTheme.mutedOf(context), fontSize: 11)),
          ],
        ),
        const SizedBox(height: 4),
        valueWidget ??
            Text(value ?? '—',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
      ],
    );
  }
}

/// Pulsing skeleton block while the exit is being detected (improvement 9).
class _SkeletonBox extends StatefulWidget {
  const _SkeletonBox(
      {required this.width, required this.height, this.radius = 4});

  final double width;
  final double height;
  final double radius;

  @override
  State<_SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<_SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: VoidrauTheme.mutedOf(context)
              .withValues(alpha: 0.12 + 0.12 * _c.value),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      ),
    );
  }
}

String _fmtStatic(int bytes) {
  if (bytes <= 0) return '—';
  const units = ['B', 'KB', 'MB', 'GB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 10 || i == 0 ? 0 : 1)} ${units[i]}';
}

String _uptimeStatic(DateTime start) {
  final d = DateTime.now().difference(start);
  final h = d.inHours.toString().padLeft(2, '0');
  final m = (d.inMinutes % 60).toString().padLeft(2, '0');
  final sec = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$h:$m:$sec';
}
