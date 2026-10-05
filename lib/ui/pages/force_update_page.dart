import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../../services/links.dart';
import '../../services/vpn_controller.dart';
import '../../theme/voidrau_theme.dart';
import '../widgets/telegram_button.dart';

/// Replaces the whole app once a newer release exists.
///
/// Nothing here can be dismissed into the normal UI: no tunnel is started on an
/// outdated build, and the only way forward is installing the new version from
/// the official Telegram channel where it is published with its notes.
/// No repository link is shown anywhere.
class ForceUpdatePage extends StatelessWidget {
  const ForceUpdatePage({super.key, required this.controller});
  final VpnController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.s;
    final target = c.blockedVersion.isEmpty ? s.latestVersion : c.blockedVersion;
    final notes = c.blockedNotes.trim();
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          children: [
            Center(
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Image.asset('assets/branding/icon.png',
                        width: 84, height: 84),
                  ),
                  const SizedBox(height: 12),
                  Text(s.appName,
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w800)),
                  Text('v${c.runningVersion}',
                      style: const TextStyle(color: VoidrauColors.muted)),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0x33FF5D67),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: VoidrauColors.coral),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.gpp_bad_outlined,
                          color: VoidrauColors.coral),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          s.updateRequiredTitle,
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 16),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    s.updateRequiredHeadline,
                    style: const TextStyle(
                        color: VoidrauColors.coral,
                        fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  Text(s.updateRequiredBody,
                      style: const TextStyle(height: 1.6)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _pill(s.currentVersion, 'v${c.runningVersion}'),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.arrow_forward,
                            size: 16, color: VoidrauColors.muted),
                      ),
                      _pill(s.latestVersion, 'v$target',
                          highlight: true),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text(s.updateRequiredTelegramLead,
                style: const TextStyle(height: 1.6)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: VoidrauColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: VoidrauColors.cyan.withValues(alpha: 0.5)),
              ),
              child: Row(
                children: [
                  TelegramButton(
                    size: 40,
                    onPressed: () => Links.openTelegram(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          AppInfo.telegramHandle,
                          style: TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 16),
                        ),
                        Text(
                          AppInfo.telegramUrl.replaceFirst('https://', ''),
                          style: const TextStyle(
                              color: VoidrauColors.muted, fontSize: 12),
                        ),
                        const SizedBox(height: 4),
                        SelectableText(
                          s.isFa
                              ? 'آیدی کانال: ${AppInfo.telegramHandle}'
                              : 'Channel ID: ${AppInfo.telegramHandle}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _step('1', s.updateStep1),
            _step('2', s.updateStep2),
            _step('3', s.updateStep3),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => Links.openTelegram(),
              icon: const Icon(Icons.send_rounded),
              label: Text('${s.openTelegram} · ${AppInfo.telegramHandle}'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => Links.openTelegram(),
              icon: const Icon(Icons.send_rounded),
              label: Text(s.isFa
                  ? 'دانلود از کانال تلگرام ${AppInfo.telegramHandle}'
                  : 'Download from Telegram ${AppInfo.telegramHandle}'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
              ),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: () => c.refreshUpdate(force: true),
              icon: const Icon(Icons.refresh),
              label: Text(s.checkAgain),
            ),
            const SizedBox(height: 8),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(s.releaseNotes,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(maxHeight: 260),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: VoidrauColors.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: VoidrauColors.line),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    notes,
                    style: const TextStyle(height: 1.55, fontSize: 12.5),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (c.releaseCheckFailed)
              Text(
                s.updateFailed,
                style: const TextStyle(color: VoidrauColors.coral, fontSize: 12),
              ),
            Text(
              s.updatedToContinue,
              style: const TextStyle(color: VoidrauColors.muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            SelectableText(
              s.isFa
                  ? 'برای دریافت نسخه جدید به کانال تلگرام مراجعه کنید:\n${AppInfo.telegramHandle}\n${AppInfo.telegramUrl}'
                  : 'Get the new build from the Telegram channel:\n${AppInfo.telegramHandle}\n${AppInfo.telegramUrl}',
              style: const TextStyle(
                  color: VoidrauColors.muted, fontSize: 12, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pill(String label, String value, {bool highlight = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: highlight ? const Color(0x3327D7F2) : VoidrauColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: highlight ? VoidrauColors.cyan : VoidrauColors.line),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: highlight ? VoidrauColors.cyan : null,
        ),
      ),
    );
  }

  Widget _step(String index, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: VoidrauColors.cyan,
            child: Text(
              index,
              style: const TextStyle(
                  fontSize: 12,
                  color: Colors.black,
                  fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: const TextStyle(height: 1.5)),
          ),
        ],
      ),
    );
  }
}
