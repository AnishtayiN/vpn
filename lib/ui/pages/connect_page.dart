import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/countries.dart';
import '../../l10n/strings.dart';
import '../../models/engine_state.dart';
import '../../models/settings.dart';
import '../../services/links.dart';
import '../../services/split.dart';
import '../../services/vpn_controller.dart';
import '../../theme/voidrau_theme.dart';
import '../widgets/country_picker.dart';
import '../widgets/flag_icon.dart';
import '../widgets/orb_button.dart';

class ConnectPage extends StatelessWidget {
  const ConnectPage({super.key, required this.controller});
  final VpnController controller;

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

    return Column(
      children: [
        if (c.update?.available == true) _updateBar(context, c, s),
        if (connected) _ExitIpCard(controller: c),
        Expanded(
          child: Center(
            child: OrbButton(
              phase: snap.phase,
              label: label,
              hint: snap.phase == EnginePhase.disconnected ? s.tapToSecure : title,
              mercury: c.settings.orbStyle == OrbStyle.mercury,
              onTap: c.toggle,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: snap.phase == EnginePhase.connected
                ? const Color(0x3327D7F2)
                : snap.phase == EnginePhase.error
                    ? const Color(0x33FF5D67)
                    : VoidrauColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: VoidrauColors.line),
          ),
          child: Text(
            title,
            style: TextStyle(
              color: snap.phase == EnginePhase.connected
                  ? VoidrauColors.cyan
                  : snap.phase == EnginePhase.error
                      ? VoidrauColors.coral
                      : VoidrauColors.muted,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        // While the exit-country rule is on, the status line reports the search
        // (which countries have already been rejected, which attempt this is)
        // instead of a generic "scanning".
        Text(
          snap.isActive && c.exitFilterActive && c.exitSearchStatus.isNotEmpty
              ? c.exitSearchStatus
              : (snap.message.isEmpty
                  ? s.socksHint(c.settings.socksPort)
                  : snap.message),
          textAlign: TextAlign.center,
          style: const TextStyle(color: VoidrauColors.muted),
        ),
        if (!connected)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: ExitFilterBadge(controller: c),
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
                      color: VoidrauColors.coral, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  s.exitPausedBody,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: VoidrauColors.muted, fontSize: 12),
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
        if (snap.connectedAt != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '${s.duration}: ${_uptime(snap.connectedAt!)}',
              style: const TextStyle(color: VoidrauColors.muted, fontSize: 12),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
          child: Row(
            children: [
              // Live rate while the tunnel moves traffic, the total otherwise:
              // a running number is what tells the user the tunnel is actually
              // carrying their download.
              _metric(
                s.download,
                connected && c.rate.downBytesPerSec > 512
                    ? '${_rate(c.rate.downBytesPerSec)}\n${_fmt(snap.downloadBytes)}'
                    : _fmt(snap.downloadBytes),
              ),
              _metric(s.ping, snap.pingMs == null ? '—' : '${snap.pingMs} ms'),
              _metric(
                s.upload,
                connected && c.rate.upBytesPerSec > 512
                    ? '${_rate(c.rate.upBytesPerSec)}\n${_fmt(snap.uploadBytes)}'
                    : _fmt(snap.uploadBytes),
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
              style: const TextStyle(color: VoidrauColors.cyan, fontSize: 11.5),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Text(
            connected
                ? s.freeNote
                : (snap.isActive ? s.detecting : s.freeNote),
            textAlign: TextAlign.center,
            style: const TextStyle(color: VoidrauColors.muted, fontSize: 13),
          ),
        ),
      ],
    );
  }

  /// A newer release exists: this build can no longer connect, and the only
  /// route to a working app is the Telegram channel.
  Widget _updateBar(BuildContext context, VpnController c, S s) {
    return Material(
      color: const Color(0xFF163149),
      child: InkWell(
        onTap: () => Links.openTelegram(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(
            children: [
              Row(
                children: [
                  const Icon(Icons.system_update_alt, color: VoidrauColors.cyan),
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

  Widget _metric(String k, String v) {
    return Expanded(
      child: Column(
        children: [
          Text(k, style: const TextStyle(color: VoidrauColors.muted, fontSize: 12)),
          const SizedBox(height: 4),
          Text(v,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  /// `12.4 MB/s`, `640 KB/s`, `812 B/s`.
  String _rate(double bytesPerSec) {
    if (bytesPerSec < 1024) return '${bytesPerSec.round()} B/s';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/s';
    }
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

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

  String _uptime(DateTime start) {
    final d = DateTime.now().difference(start);
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final sec = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$sec';
  }
}

/// The "where am I?" card shown once the tunnel is up: the flag of the country
/// the exit IP belongs to, the exit IP itself (the IP websites see), the
/// datacenter hint and the round-trip time. Tapping it copies the IP.
class _ExitIpCard extends StatelessWidget {
  const _ExitIpCard({required this.controller});
  final VpnController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.s;
    final snap = c.snapshot;
    final code = snap.country.trim().toUpperCase();
    final name = countryLabel(code, fa: s.isFa);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Material(
        color: VoidrauColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: snap.ip.isEmpty
              ? null
              : () {
                  Clipboard.setData(ClipboardData(text: snap.ip));
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(s.ipCopied)));
                },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: VoidrauColors.line),
            ),
            child: Row(
              children: [
                FlagIcon(
                  countryCode: code.isEmpty ? null : code,
                  height: 30,
                  radius: 5,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isEmpty ? s.detecting : name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 15),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          const Icon(Icons.public,
                              size: 13, color: VoidrauColors.muted),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              snap.ip.isEmpty ? s.detecting : snap.ip,
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
                            Text(
                              '· ${snap.location}',
                              style: const TextStyle(
                                  color: VoidrauColors.muted, fontSize: 12),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      s.exitIp,
                      style: const TextStyle(
                          color: VoidrauColors.muted, fontSize: 10),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      snap.pingMs == null ? '—' : '${snap.pingMs} ms',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                    const SizedBox(height: 4),
                    const Icon(Icons.copy,
                        size: 13, color: VoidrauColors.muted),
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
