import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_info.dart';
import '../../data/jalali.dart';
import '../../l10n/strings.dart';
import '../../services/license_service.dart';
import '../../services/links.dart';
import '../../theme/voidrau_theme.dart';

/// Pre-entry gate: the app's features are unreachable until a valid (or
/// graced) license exists. Trials get a read-only experience message; only
/// a purchased key unlocks the app (user request).
class LicenseGatePage extends StatefulWidget {
  const LicenseGatePage({super.key, required this.onUnlocked});
  final VoidCallback onUnlocked;

  @override
  State<LicenseGatePage> createState() => _LicenseGatePageState();
}

class _LicenseGatePageState extends State<LicenseGatePage> {
  final _keyController = TextEditingController();
  bool _busy = false;
  String? _message;
  SessionLimitError? _limitError;

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  S get s => S(Localizations.localeOf(context).languageCode);

  Future<void> _activate({String? explicitKey}) async {
    final rawKey = explicitKey ?? _keyController.text.trim();
    final key = LicenseService.extractKey(rawKey) ?? rawKey;
    if (key.isEmpty) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final ok = await LicenseService.instance.check(keyOverride: key);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _limitError = LicenseService.instance.lastLimitError;
      _message = ok
          ? null
          : (_limitError != null
              ? null
              : LicenseService.instance.lastError == 'session-revoked'
                  ? s.sessionRevoked
                  : s.licenseBadKey);
    });
    if (ok) widget.onUnlocked();
  }

  /// Remove one active device, then retry this activation with the same key.
  Future<void> _removeSessionAndRetry(LicenseSession session) async {
    setState(() => _busy = true);
    final removed =
        await LicenseService.instance.revokeSession(session.id);
    if (!mounted) return;
    if (!removed) {
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.sessionsDeleteFailed)),
      );
      return;
    }
    setState(() => _limitError = null);
    await _activate();
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text?.trim() ?? '';
      final extracted = LicenseService.extractKey(text);
      if (extracted != null && extracted.isNotEmpty) {
        _keyController.text = extracted;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                s.isFa
                    ? 'کد لایسنس پیدا و جای‌گذاری شد: $extracted'
                    : 'License key detected: $extracted',
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        await _activate(explicitKey: extracted);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                s.isFa
                    ? 'کد لایسنس معتبری در کلیپ‌بورد یافت نشد (فرمت: VDRV-XXXX-XXXX-XXXX)'
                    : 'No valid key found in clipboard (format: VDRV-XXXX-XXXX-XXXX)',
              ),
            ),
          );
        }
      }
    } catch (_) {}
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    final ok = await LicenseService.instance.check();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) widget.onUnlocked();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Image.asset(
                      'assets/branding/icon.png',
                      width: 80,
                      height: 80,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  s.isFa ? '🔐 فعال‌سازی لایسنس VoidrauVPN' : '🔐 Activate VoidrauVPN',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 10),
                Text(
                  s.isFa
                      ? 'برای استفاده از شبکه و اتصال، کد لایسنس خود را وارد نمایید.\n'
                          'تست رایگان ۲۴ ساعته و خرید لایسنس از طریق ربات تلگرام انجام می‌شود.'
                      : 'Enter your license key to connect.\n'
                          'Free 24h trial and licenses are available via the Telegram bot.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: VoidrauColors.muted,
                    fontSize: 13.5,
                    height: 1.55,
                  ),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _keyController,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: InputDecoration(
                    hintText: 'VDRV-XXXX-XXXX-XXXX',
                    filled: true,
                    fillColor: VoidrauColors.surface,
                    prefixIcon: const Icon(Icons.vpn_key_rounded, size: 20),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onSubmitted: (_) => _activate(),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _pasteFromClipboard,
                        icon: const Icon(Icons.content_paste_rounded, size: 18),
                        label: Text(
                          s.isFa ? 'چسباندن از حافظه' : 'Paste from clipboard',
                        ),
                      ),
                    ),
                  ],
                ),
                if (_message != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: VoidrauColors.coral.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: VoidrauColors.coral.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Text(
                      _message!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: VoidrauColors.coral,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
                if (_message == null &&
                    _limitError == null &&
                    LicenseService.instance.lastError == 'session-revoked') ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: VoidrauColors.coral.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: VoidrauColors.coral.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Text(
                      s.sessionRevoked,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: VoidrauColors.coral,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
                if (_limitError != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: VoidrauColors.coral.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: VoidrauColors.coral.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          s.sessionLimitTitle,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          s.sessionsActiveCount(
                            _limitError!.activeCount,
                            _limitError!.maxUsers,
                          ),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: VoidrauColors.muted,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          s.sessionLimitBody,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: VoidrauColors.muted,
                            fontSize: 13,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 10),
                        ..._limitError!.sessions.map((session) {
                          final seen = session.lastSeenDate;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(
                              children: [
                                const Icon(Icons.devices_rounded, size: 18),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        session.displayName,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 13),
                                      ),
                                      if (seen != null)
                                        Text(
                                          '${s.sessionsLastActive} ${JalaliDate.fromDateTime(seen.toLocal()).formatReadable()}',
                                          style: const TextStyle(
                                            color: VoidrauColors.muted,
                                            fontSize: 12,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _removeSessionAndRetry(session),
                                  child: Text(s.sessionsDelete),
                                ),
                              ],
                            ),
                          );
                        }),
                        const SizedBox(height: 4),
                        OutlinedButton.icon(
                          onPressed: () =>
                              Links.open(AppInfo.botStartUrl('sessions')),
                          icon: const Icon(Icons.telegram, size: 18),
                          label: Text(s.sessionsManageInBot),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          s.sessionLimitRetry,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: VoidrauColors.muted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy ? null : () => _activate(),
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.arrow_forward_rounded, size: 18),
                  label: Text(
                    _busy
                        ? (s.isFa ? 'در حال بررسی…' : 'Checking…')
                        : (s.isFa ? 'ورود به برنامه' : 'Enter application'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _busy ? null : _refresh,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(
                    s.isFa ? 'بررسی دوباره آخرین لایسنس' : 'Re-check stored license',
                  ),
                ),
                const SizedBox(height: 14),
                const Divider(),
                const SizedBox(height: 14),
                FilledButton.tonalIcon(
                  onPressed: () => Links.openBot(),
                  icon: const Icon(Icons.smart_button_rounded, size: 20),
                  label: Text(
                    s.isFa
                        ? 'دریافت تست رایگان یا خرید از ربات'
                        : 'Get Free Trial / Buy in Bot',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => Links.openTelegram(),
                  icon: const Icon(Icons.telegram, size: 20),
                  label: Text(
                    '${s.telegram} (${AppInfo.telegramHandle})',
                    style: const TextStyle(color: VoidrauColors.muted),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
