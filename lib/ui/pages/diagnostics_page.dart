import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_info.dart';
import '../../data/countries.dart';
import '../../l10n/strings.dart';
import '../../models/engine_state.dart';
import '../../services/core_args.dart';
import '../../services/socks_probe.dart';
import '../../services/split.dart';
import '../../services/vpn_controller.dart';
import '../../theme/voidrau_theme.dart';

class DiagnosticsPage extends StatelessWidget {
  const DiagnosticsPage({super.key, required this.controller});
  final VpnController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.s;
    final snap = c.snapshot;
    final tun = c.tunInfo;
    final tunBlocked = tun['error'] ?? '—';
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonal(
              onPressed: () async {
                try {
                  final r = await SocksProbe.cloudflareTrace(
                    port: c.settings.socksPort,
                  );
                  c.log('trace ping ${r.pingMs} ms');
                  for (final line in r.body.split('\n')) {
                    if (line.trim().isNotEmpty) c.log(line.trim());
                  }
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('OK ${r.pingMs} ms')),
                    );
                  }
                } catch (e) {
                  c.log('trace failed: $e');
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text('$e')));
                  }
                }
              },
              child: Text(s.testConnection),
            ),
            OutlinedButton(onPressed: c.recover, child: Text(s.recover)),
            if (c.needsElevation)
              FilledButton.icon(
                onPressed: c.restartAsAdmin,
                icon: const Icon(Icons.shield_outlined),
                label: Text(s.restartAsAdmin),
              ),
            IconButton(
              onPressed: () {
                Clipboard.setData(
                  ClipboardData(text: c.logs.map((e) => e.text).join('\n')),
                );
              },
              icon: const Icon(Icons.copy),
            ),
            IconButton(
              onPressed: c.clearLogs,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        if (c.needsElevation) ...[
          const SizedBox(height: 12),
          _note(Icons.info_outline, s.deviceVpnHint),
        ],
        if (tunBlocked != '—' && tunBlocked.isNotEmpty) ...[
          const SizedBox(height: 12),
          _note(Icons.report_gmailerrorred_outlined,
              '${s.tunBlocked}: $tunBlocked'),
        ],
        const SizedBox(height: 12),
        _grid([
          _cell(s.protocol, snap.protocol.isEmpty ? '—' : snap.protocol),
          _cell(s.tunnel, snap.phase.name),
          _cell(
            Platform.isWindows ? s.tunAdapter : s.tun,
            snap.phase == EnginePhase.connected
                // Windows: the adapter name and index we really got ("Voidrau 2"
                // happens), or '—' when only SOCKS5 is up. Android: VpnService.
                ? (Platform.isWindows
                    ? (tun['adapter'] ?? '—')
                    : s.appName)
                : '—',
          ),
          // Windows-only facts: on Android the VpnService owns the device.
          if (Platform.isWindows) ...[
            _cell(s.tunBackend, tun['backend'] ?? '—'),
            _cell(s.elevated, tun['elevated'] == 'true' ? s.yes : s.no),
            _cell(s.windowsVersion, tun['windows'] ?? '—'),
          ],
          _cell(
            'MTU',
            s.mtuSummary(c.settings.deviceMtu, c.settings.coreMtuOverride),
          ),
          _cell(s.perfProfile, c.settings.perf.name),
          _cell(s.exitLock, CoreLaunch.exitLoc(c.settings) ?? s.off),
          _cell(
            s.splitTitle,
            SplitRules.summary(c.settings,
                    fa: s.isFa, android: Platform.isAndroid)
                .isEmpty
                ? s.splitNone
                : SplitRules.summary(c.settings,
                    fa: s.isFa, android: Platform.isAndroid),
          ),
          _cell(s.secondHop, c.settings.chain.name),
          // What the tunnel is moving right now, next to the totals below.
          _cell(
            s.liveSpeed,
            '${s.download} ${_rate(c.rate.downBytesPerSec)}  ·  '
            '${s.upload} ${_rate(c.rate.upBytesPerSec)}',
          ),
          _cell(s.exitIp, snap.ip.isEmpty ? '—' : snap.ip),
          _cell(
            s.exitCountry,
            snap.country.isEmpty
                ? '—'
                : '${countryLabel(snap.country, fa: s.isFa)} (${snap.country.toUpperCase()})',
          ),
          // The rule the controller is enforcing, plus how far the current
          // search has got — so a long "scanning" phase explains itself.
          _cell(
            s.exitFilter,
            c.exitRulePaused
                ? '${c.exitFilterLabel} · ${s.exitPausedTitle}'
                : c.exitFilterLabel,
          ),
          if (c.exitFilterActive)
            _cell(s.scanning, c.exitSearchStatus),
          _cell(s.ping, snap.pingMs == null ? '—' : '${snap.pingMs} ms'),
          _cell(s.location, snap.location.isEmpty ? '—' : snap.location),
          _cell(s.coreVersion, AppInfo.core),
          _cell(s.httpProxy,
              c.settings.httpProxy ? c.settings.httpBind : s.off),
          _cell('SOCKS5', c.settings.socksBind),
          _cell(s.download, '${snap.downloadBytes}'),
          _cell(s.upload, '${snap.uploadBytes}'),
          _cell(s.endpoint, snap.endpoint.isEmpty ? 'auto' : snap.endpoint),
        ]),
        const SizedBox(height: 16),
        _leakCard(c, s),
        const SizedBox(height: 16),
        Text(s.logs, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Container(
          height: 360,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: VoidrauColors.line),
          ),
          child: ListView.builder(
            itemCount: c.logs.length,
            itemBuilder: (context, i) {
              final line = c.logs[i];
              return Text(
                '[${_hhmmss(line.at)}] ${line.text}',
                style: const TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 12,
                  height: 1.35,
                  color: Color(0xFFB8D4C8),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _grid(List<Widget> cells) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 2.4,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: cells,
    );
  }

  Widget _note(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: VoidrauColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: VoidrauColors.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: VoidrauColors.cyan),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  /// The one test that answers "is the tunnel really carrying my traffic?" —
  /// the raw line's public address next to the tunnel's.
  Widget _leakCard(VpnController c, S s) {
    final connected = c.snapshot.phase == EnginePhase.connected;
    final verdict = c.leakBypassed
        ? (Icons.report_gmailerrorred_outlined, s.leakBypassed, VoidrauColors.coral)
        : c.leakTunnelIp.isNotEmpty
            ? (Icons.verified_outlined, s.leakOk, VoidrauColors.cyan)
            : (!connected
                ? (Icons.info_outline, s.leakNoTunnel, VoidrauColors.muted)
                : (Icons.hourglass_empty, s.leakCheckHelp, VoidrauColors.muted));
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VoidrauColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: VoidrauColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.travel_explore,
                  color: VoidrauColors.cyan, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(s.leakCheck,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              TextButton(
                onPressed: c.leakChecking ? null : c.runLeakCheck,
                child: Text(c.leakChecking ? s.leakRunning : s.leakRun),
              ),
            ],
          ),
          _cell(
            s.leakRaw,
            c.leakRawIp.isEmpty
                ? '—'
                : '${c.leakRawIp} (${c.leakRawCountry.isEmpty ? '??' : c.leakRawCountry})',
          ),
          _cell(
            s.leakThrough,
            c.leakTunnelIp.isEmpty
                ? (connected ? '—' : s.splitNone)
                : '${c.leakTunnelIp} (${c.leakTunnelCountry.isEmpty ? '??' : c.leakTunnelCountry})',
          ),
          if (c.leakError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(s.leakFailed,
                  style: const TextStyle(
                      color: VoidrauColors.muted, fontSize: 12)),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(verdict.$1, size: 16, color: verdict.$3),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(verdict.$2,
                      style: TextStyle(color: verdict.$3, fontSize: 12)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// `12.4 MB/s`, `640 KB/s` or `0 B/s`.
  static String _rate(double bytesPerSec) {
    if (bytesPerSec < 1024) return '${bytesPerSec.round()} B/s';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/s';
    }
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  Widget _cell(String k, String v) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: VoidrauColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: VoidrauColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(k, style: const TextStyle(color: VoidrauColors.muted, fontSize: 11)),
          const SizedBox(height: 4),
          Text(v,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  String _hhmmss(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}
