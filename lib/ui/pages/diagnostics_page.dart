import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_info.dart';
import '../../data/countries.dart';
import '../../l10n/strings.dart';
import '../../models/engine_state.dart';
import '../../models/settings.dart';
import '../../services/core_args.dart';
import '../../services/socks_probe.dart';
import '../../services/split.dart';
import '../../services/vpn_controller.dart';
import '../../theme/voidrau_theme.dart';

class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key, required this.controller});
  final VpnController controller;

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  /// m11: the log console auto-scrolls to the newest line and can be
  /// filtered to errors only. The controller is listened to so the scroll
  /// happens when a line lands, not only when the page rebuilds.
  final _logScroll = ScrollController();
  bool _errorsOnly = false;
  int _lastLogCount = 0;

  @override
  void initState() {
    super.initState();
    _lastLogCount = widget.controller.logs.length;
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _logScroll.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    final logs = widget.controller.logs;
    if (logs.length == _lastLogCount) return;
    _lastLogCount = logs.length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  /// A log line counts as an error when it says so in either language.
  static bool _isError(String text) {
    final lower = text.toLowerCase();
    return lower.contains('error') ||
        lower.contains('fail') ||
        lower.contains('خطا') ||
        lower.contains('ناموفق') ||
        lower.contains('stalled') ||
        lower.contains('timeout');
  }

  List<LogLine> get _visibleLogs {
    final logs = widget.controller.logs;
    if (!_errorsOnly) return logs;
    return logs.where((l) => _isError(l.text)).toList();
  }

  void _copyReport(BuildContext context, VpnController c, S s) {
    final snap = c.snapshot;
    final tun = c.tunInfo;
    final buffer = StringBuffer();
    buffer.writeln('=== VoidrauVPN Diagnostic Report ===');
    buffer.writeln('App Version: ${AppInfo.version}');
    buffer.writeln('Tunnel Core: ${AppInfo.core}');
    buffer.writeln(
        'Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    buffer.writeln('Status: ${snap.phase.name}');
    buffer.writeln('Protocol: ${snap.protocol}');
    buffer.writeln('Exit IP: ${snap.ip} (${snap.country})');
    buffer.writeln('Location: ${snap.location}');
    buffer.writeln('Ping: ${snap.pingMs ?? "—"} ms');
    buffer.writeln(
        'Device MTU: ${c.settings.deviceMtu} | Core MTU: ${c.settings.coreMtuOverride}');
    buffer.writeln('Perf Profile: ${c.settings.perf.name}');
    buffer.writeln('SOCKS5: ${c.settings.socksBind}');
    if (Platform.isWindows) {
      buffer.writeln('WinTUN Adapter: ${tun["adapter"] ?? "—"}');
      buffer.writeln('WinTUN Backend: ${tun["backend"] ?? "—"}');
      buffer.writeln('Elevated: ${tun["elevated"] ?? "—"}');
    }
    buffer.writeln(
        'Download: ${_fmt(snap.downloadBytes)} | Upload: ${_fmt(snap.uploadBytes)}');
    buffer.writeln('\n--- Recent Logs (${c.logs.length}) ---');
    final recent =
        c.logs.length > 30 ? c.logs.sublist(c.logs.length - 30) : c.logs;
    for (final l in recent) {
      buffer.writeln('[${l.at.toIso8601String()}] ${l.text}');
    }
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(s.diagReportCopied)));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
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
                      SnackBar(content: Text(s.testConnectionOk(r.pingMs))),
                    );
                  }
                } catch (e) {
                  c.log('trace failed: $e');
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(s.testConnectionFailed)),
                    );
                  }
                }
              },
              child: Text(s.testConnection),
            ),
            OutlinedButton(onPressed: c.recover, child: Text(s.recover)),
            FilledButton.tonalIcon(
              onPressed: () => _copyReport(context, c, s),
              icon: const Icon(Icons.assignment_outlined, size: 18),
              label: Text(s.copyDiagReport),
            ),
            if (c.needsElevation)
              FilledButton.icon(
                onPressed: c.restartAsAdmin,
                icon: const Icon(Icons.shield_outlined),
                label: Text(s.restartAsAdmin),
              ),
            IconButton(
              tooltip: s.copyLogs,
              onPressed: () {
                Clipboard.setData(
                  ClipboardData(text: c.logs.map((e) => e.text).join('\n')),
                );
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(s.copied)));
              },
              icon: const Icon(Icons.copy),
            ),
            IconButton(
              tooltip: s.clearLogs,
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
          _cell(s.tunnel, s.phaseLabel(snap.phase.name)),
          _cell(
            Platform.isWindows ? s.tunAdapter : s.tun,
            snap.phase == EnginePhase.connected
                ? (Platform.isWindows ? (tun['adapter'] ?? '—') : s.appName)
                : '—',
          ),
          if (Platform.isWindows) ...[
            _cell(s.tunBackend, tun['backend'] ?? '—'),
            _cell(s.elevated, tun['elevated'] == 'true' ? s.yes : s.no),
            _cell(s.windowsVersion, tun['windows'] ?? '—'),
          ],
          _cell(
            'MTU',
            s.mtuSummary(c.settings.deviceMtu, c.settings.coreMtuOverride),
          ),
          _cell(s.perfProfile, _perfLabel(s, c.settings.perf)),
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
          _cell(s.secondHop, _hopLabel(s, c.settings)),
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
          _cell(
            s.exitFilter,
            c.exitRulePaused
                ? '${c.exitFilterLabel} · ${s.exitPausedTitle}'
                : c.exitFilterLabel,
          ),
          if (c.exitFilterActive) _cell(s.scanning, c.exitSearchStatus),
          _cell(s.ping, snap.pingMs == null ? '—' : '${snap.pingMs} ms'),
          _cell(s.location, snap.location.isEmpty ? '—' : snap.location),
          _cell(s.coreVersion, AppInfo.core),
          _cell(s.httpProxy,
              c.settings.httpProxy ? c.settings.httpBind : s.off),
          _cell('SOCKS5', c.settings.socksBind),
          _cell(s.download, _fmt(snap.downloadBytes)),
          _cell(s.upload, _fmt(snap.uploadBytes)),
          _cell(s.endpoint, snap.endpoint.isEmpty ? s.endpointAuto : snap.endpoint),
        ]),
        const SizedBox(height: 16),
        _leakCard(c, s),
        const SizedBox(height: 16),
        Row(
          children: [
            Text(s.logs,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(width: 12),
            ChoiceChip(
              label: Text(s.logFilterAll),
              selected: !_errorsOnly,
              onSelected: (_) => setState(() => _errorsOnly = false),
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: Text(s.logFilterErrors),
              selected: _errorsOnly,
              onSelected: (_) => setState(() => _errorsOnly = true),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          height: 360,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: VoidrauTheme.lineOf(context)),
          ),
          child: ListView.builder(
            controller: _logScroll,
            itemCount: _visibleLogs.length,
            itemBuilder: (context, i) {
              final line = _visibleLogs[i];
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
        color: VoidrauTheme.surfaceOf(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: VoidrauTheme.lineOf(context)),
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

  Widget _leakCard(VpnController c, S s) {
    final connected = c.snapshot.phase == EnginePhase.connected;
    final verdict = c.leakBypassed
        ? (
            Icons.report_gmailerrorred_outlined,
            s.leakBypassed,
            VoidrauColors.coral
          )
        : c.leakTunnelIp.isNotEmpty
            ? (Icons.verified_outlined, s.leakOk, VoidrauColors.cyan)
            : (!connected
                ? (
                    Icons.info_outline,
                    s.leakNoTunnel,
                    VoidrauTheme.mutedOf(context)
                  )
                : (
                    Icons.hourglass_empty,
                    s.leakCheckHelp,
                    VoidrauTheme.mutedOf(context)
                  ));
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VoidrauTheme.surfaceOf(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: VoidrauTheme.lineOf(context)),
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
                  style: TextStyle(
                      color: VoidrauTheme.mutedOf(context), fontSize: 12)),
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
        color: VoidrauTheme.surfaceOf(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: VoidrauTheme.lineOf(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(k,
              style: TextStyle(
                  color: VoidrauTheme.mutedOf(context), fontSize: 11)),
          const SizedBox(height: 4),
          Text(v,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  /// m5: the perf profile and the second hop as localised labels, not raw
  /// enum names.
  String _perfLabel(S s, PerfProfile p) => switch (p) {
        PerfProfile.eco => s.perfEco,
        PerfProfile.auto => s.perfAuto,
        PerfProfile.turbo => s.perfTurbo,
        PerfProfile.extreme => s.perfExtreme,
      };

  String _hopLabel(S s, VpnSettings st) {
    String hop(SecondHop h) => switch (h) {
          SecondHop.off => s.hopOff,
          SecondHop.psiphon => s.hopPsiphon,
          SecondHop.psiphonReverse => s.hopPsiphonReverse,
          SecondHop.tor => s.hopTor,
          SecondHop.torReverse => s.hopTorReverse,
        };
    if (st.isStandaloneHop) {
      final mode = st.standaloneMode == StandaloneMode.psiphonOnly
          ? s.hopPsiphonOnly
          : s.hopTorOnly;
      return st.hasSecondHop ? '$mode + ${hop(st.secondHop)}' : mode;
    }
    return hop(st.secondHop);
  }

  /// m10: byte counts formatted like the Connect page (1.2 MB, not 1234567).
  static String _fmt(int bytes) {
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

  String _hhmmss(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}
