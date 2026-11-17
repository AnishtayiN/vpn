import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.dart';
import '../../services/license_service.dart';
import '../../services/links.dart';
import '../../theme/voidrau_theme.dart';
import '../../app_info.dart';
import 'sessions_page.dart';

/// License screen: shows remaining time, lets the user enter a key,
/// request a 24h trial (via the Telegram bot) and open the buy/referral chat.
class VoidrauLicensePage extends StatefulWidget {
  const VoidrauLicensePage({super.key, required this.onChanged});
  final VoidCallback onChanged;

  @override
  State<VoidrauLicensePage> createState() => _LicensePageState();
}

class _LicensePageState extends State<VoidrauLicensePage> {
  final _keyController = TextEditingController();
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  S get s => S(Localizations.localeOf(context).languageCode);

  Future<void> _activate({String? explicitKey}) async {
    final rawKey = explicitKey ?? _keyController.text.trim();
    final key = LicenseService.extractKey(rawKey) ?? rawKey;
    // m13: an empty key used to return silently — say what is missing.
    if (key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.licenseEnterKey)),
      );
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    final ok = await LicenseService.instance.check(keyOverride: key);
    if (!mounted) return;
    setState(() {
      _busy = false;
      // M4: an offline failure is not an invalid key — check() returns false
      // with lastError == 'network' when there is no connection at all.
      _message = ok
          ? s.licenseOk
          : (LicenseService.instance.lastError == 'network'
              ? s.licenseNoInternet
              : s.licenseBadKey);
    });
    if (ok) {
      _keyController.clear();
      widget.onChanged();
    }
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
                    ? 'کد لایسنس جای‌گذاری شد: $extracted'
                    : 'License key pasted: $extracted',
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
                    ? 'کد معتبری در کلیپ‌بورد پیدا نشد'
                    : 'No valid license key found in clipboard',
              ),
            ),
          );
        }
      }
    } catch (_) {}
  }

  Future<void> _trial() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    await Links.openChecked(
        context, AppInfo.botStartUrl('trial'), s.linkOpenFailed);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _buy() async {
    await Links.openChecked(
        context, AppInfo.botStartUrl('buy'), s.linkOpenFailed);
  }

  Future<void> _referral() async {
    await Links.openChecked(
        context, AppInfo.botStartUrl('ref'), s.linkOpenFailed);
  }

  String _planLabel(String p) {
    switch (p) {
      case 'paid':
      case 'admin':
        return s.isFa ? 'خریداری‌شده ویژه ⭐️' : 'Paid Premium';
      case 'trial':
        return s.isFa ? 'تست رایگان موقت 🎁' : 'Free Trial';
      default:
        return p;
    }
  }

  Future<void> _recheck() async {
    setState(() => _busy = true);
    await LicenseService.instance.check();
    if (mounted) {
      setState(() => _busy = false);
      widget.onChanged();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            s.isFa
                ? 'وضعیت لایسنس با موفقیت بررسی شد'
                : 'License status updated',
          ),
        ),
      );
    }
  }

  void _copyKey(String key) {
    Clipboard.setData(ClipboardData(text: key));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          s.isFa ? 'کد لایسنس کپی شد' : 'License key copied',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lic = LicenseService.instance;
    final active = lic.isActive;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: active
                  ? VoidrauColors.cyan.withValues(alpha: 0.3)
                  : VoidrauTheme.lineOf(context),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  active ? Icons.verified_rounded : Icons.lock_outline_rounded,
                  size: 48,
                  color: active
                      ? VoidrauColors.cyan
                      : VoidrauTheme.mutedOf(context),
                ),
                const SizedBox(height: 12),
                Text(
                  active ? s.licenseActiveTitle : s.licenseInactiveTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                if (active && lic.remaining > Duration.zero) ...[
                  Builder(
                    builder: (context) {
                      final total = lic.plan == 'trial'
                          ? const Duration(hours: 24)
                          : const Duration(days: 30);
                      final fraction =
                          (lic.remaining.inSeconds / total.inSeconds)
                              .clamp(0.0, 1.0);
                      return SizedBox(
                        width: 148,
                        height: 148,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              width: 148,
                              height: 148,
                              child: CircularProgressIndicator(
                                value: fraction,
                                strokeWidth: 9,
                                backgroundColor:
                                    VoidrauTheme.lineOf(context),
                                valueColor:
                                    const AlwaysStoppedAnimation<Color>(
                                        VoidrauColors.cyan),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    lic.formatRemaining(fa: s.isFa),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w900,
                                      color: VoidrauColors.cyan,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${s.isFa ? 'تاریخ انقضا:' : 'Expiry:'} ${lic.formatExpiry(fa: s.isFa)}',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: VoidrauTheme.mutedOf(context),
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  if (lic.plan != null) ...[
                    const SizedBox(height: 8),
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: VoidrauColors.cyan.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: VoidrauColors.cyan.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Text(
                          _planLabel(lic.plan!),
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: VoidrauColors.cyan,
                          ),
                        ),
                      ),
                    ),
                  ],
                  // m15: until the Worker reports a cap, the page must not
                  // assert "1 of 1" — show the active count with an unknown
                  // limit instead.
                  const SizedBox(height: 12),
                  if (lic.maxUsers != null) ...[
                    Row(
                      children: [
                        Text(
                          s.licenseDevicesUsed,
                          style: TextStyle(
                            color: VoidrauTheme.mutedOf(context),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${lic.sessions.length} / ${lic.maxUsers!}',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: lic.maxUsers! > 0
                            ? (lic.sessions.length / lic.maxUsers!)
                                .clamp(0.0, 1.0)
                            : 0,
                        minHeight: 8,
                        backgroundColor: VoidrauTheme.lineOf(context),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                            VoidrauColors.cyan),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      s.sessionsUpToDevices(lic.maxUsers!),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: VoidrauTheme.mutedOf(context),
                        fontSize: 12,
                      ),
                    ),
                  ] else
                    Text(
                      s.sessionsActiveUnknown(lic.sessions.length),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: VoidrauTheme.mutedOf(context),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  // Improvement 7: inline sessions preview with one-tap
                  // remove (confirm dialog first, same as the Sessions page).
                  // The separate Sessions page keeps working unchanged.
                  if (lic.sessions.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        s.licenseSessionsPreview,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 14),
                      ),
                    ),
                    const SizedBox(height: 4),
                    ...lic.sessions.take(3).map(
                          (sess) => ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              sess.platform == 'android'
                                  ? Icons.phone_android_rounded
                                  : sess.platform == 'windows'
                                      ? Icons.computer_rounded
                                      : Icons.devices_rounded,
                              size: 20,
                              color: VoidrauTheme.mutedOf(context),
                            ),
                            title: Text(
                              sess.displayNameFor(fa: s.isFa),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13.5),
                            ),
                            subtitle: Text(
                              sess.platformLabelFor(fa: s.isFa),
                              style: TextStyle(
                                  color: VoidrauTheme.mutedOf(context),
                                  fontSize: 12),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline_rounded,
                                  size: 20),
                              tooltip: s.sessionsDelete,
                              constraints: const BoxConstraints(
                                  minWidth: 48, minHeight: 48),
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title:
                                        Text(s.sessionsDeleteTitle),
                                    content: Text(s.sessionsDeleteBody(
                                        sess.displayNameFor(fa: s.isFa))),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(ctx).pop(false),
                                        child: Text(s.cancel),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.of(ctx).pop(true),
                                        child: Text(s.sessionsDelete),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm != true || !mounted) return;
                                final ok = await LicenseService.instance
                                    .revokeSession(sess.id);
                                if (!context.mounted) return;
                                setState(() {});
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(ok
                                        ? s.sessionsDeleted
                                        : s.sessionsDeleteFailed),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                    if (lic.sessions.length > 3)
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton(
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const SessionsPage()),
                            );
                          },
                          child: Text(s.sessionsTitle),
                        ),
                      ),
                  ],
                  if (lic.key != null) ...[
                    const SizedBox(height: 12),
                    InkWell(
                      onTap: () => _copyKey(lic.key!),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: VoidrauTheme.surfaceOf(context),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: VoidrauTheme.lineOf(context)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.key_rounded,
                                size: 16,
                                color: VoidrauTheme.mutedOf(context)),
                            const SizedBox(width: 8),
                            Text(
                              lic.key!,
                              style: const TextStyle(
                                fontFamily: 'Consolas',
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(Icons.copy_rounded,
                                size: 15,
                                color: VoidrauTheme.mutedOf(context)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ] else
                  Text(
                    s.licenseInactiveBody,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: VoidrauTheme.mutedOf(context),
                      height: 1.5,
                      fontSize: 13.5,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Action buttons
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: _busy ? null : _recheck,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(s.licenseRecheck),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: _buy,
                icon: const Icon(Icons.shopping_cart_outlined, size: 18),
                label: Text(s.licenseBuy),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: _busy ? null : _trial,
          icon: const Icon(Icons.card_giftcard_rounded, size: 18),
          label: Text(s.licenseTrial),
        ),
        if (lic.key != null) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SessionsPage()),
              );
            },
            icon: const Icon(Icons.devices_rounded, size: 18),
            label: Text(s.sessionsTitle),
          ),
        ],

        const SizedBox(height: 20),
        const Divider(),
        const SizedBox(height: 12),

        Text(
          s.licenseKeyLabel,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _keyController,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Consolas',
            letterSpacing: 1.1,
            fontWeight: FontWeight.w600,
          ),
          decoration: InputDecoration(
            hintText: 'VDRV-XXXX-XXXX-XXXX',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
          onSubmitted: (_) => _activate(),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _pasteFromClipboard,
                icon: const Icon(Icons.content_paste_rounded, size: 16),
                label: Text(s.isFa ? 'چسباندن' : 'Paste'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: _busy ? null : () => _activate(),
                child: _busy
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                          Text(s.checking),
                        ],
                      )
                    : Text(s.licenseActivate),
              ),
            ),
          ],
        ),
        if (_message != null) ...[
          const SizedBox(height: 10),
          Text(
            _message!,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _message == s.licenseOk
                  ? VoidrauColors.cyan
                  : VoidrauColors.coral,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],

        const SizedBox(height: 20),
        // Referral link
        OutlinedButton.icon(
          onPressed: _referral,
          icon: const Icon(Icons.group_add_rounded, size: 18),
          label: Text(s.licenseReferral),
        ),
        if (lic.key != null) ...[
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: () async {
              await LicenseService.instance.signOut();
              if (!mounted) return;
              widget.onChanged();
              setState(() {});
            },
            icon: const Icon(Icons.logout, size: 18, color: VoidrauColors.coral),
            label: Text(
              s.licenseSignOut,
              style: const TextStyle(color: VoidrauColors.coral),
            ),
          ),
        ],
      ],
    );
  }
}
