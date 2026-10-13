import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/license_service.dart';
import '../../services/links.dart';
import '../../theme/voidrau_theme.dart';
import '../../app_info.dart';

/// License screen: shows remaining time, lets the user enter a key,
/// request a 24h trial (via the Telegram bot) and open the buy/referral chat.
class VoidrauLicensePage extends StatefulWidget {
  const VoidrauLicensePage({super.key, required this.onChanged});
  final VoidCallback onChanged;

  @override
  State<VoidrauLicensePage> createState() => _LicensePageState();
}

class _LicensePageState extends State<LicensePage> {
  final _keyController = TextEditingController();
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  S get s => S(Localizations.localeOf(context).languageCode);

  String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    if (d.inDays > 0) return '${d.inDays}d ${two(d.inHours % 24)}h';
    if (d.inHours > 0) return '${d.inHours}h ${two(d.inMinutes % 60)}m';
    return '${d.inMinutes}m';
  }

  Future<void> _activate() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final ok = await LicenseService.instance.check(keyOverride: key);
    setState(() {
      _busy = false;
      _message = ok ? s.licenseOk : s.licenseBadKey;
    });
    if (ok) {
      _keyController.clear();
      widget.onChanged();
    }
  }

  Future<void> _trial() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    // The trial is issued by the Telegram bot: opening the bot with the
    // deep-link starts the flow there (anti-abuse: one trial per telegram id).
    await Links.open('https://t.me/${AppInfo.botHandle.replaceFirst('@', '')}?start=trial');
    setState(() => _busy = false);
  }

  Future<void> _buy() async {
    await Links.open('https://t.me/${AppInfo.botHandle.replaceFirst('@', '')}?start=buy');
  }

  @override
  Widget build(BuildContext context) {
    final lic = LicenseService.instance;
    final active = lic.isActive;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  active ? Icons.verified_rounded : Icons.lock_outline_rounded,
                  size: 44,
                  color: active ? VoidrauColors.cyan : VoidrauColors.muted,
                ),
                const SizedBox(height: 12),
                Text(
                  active ? s.licenseActiveTitle : s.licenseInactiveTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                if (active && lic.remaining > Duration.zero) ...[
                  Text(
                    '${s.licenseRemaining}: ${_fmt(lic.remaining)}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: VoidrauColors.cyan),
                  ),
                  if (lic.plan != null)
                    Text(
                      '${s.licensePlan}: ${lic.plan}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: VoidrauColors.muted),
                    ),
                ] else
                  Text(
                    s.licenseInactiveBody,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: VoidrauColors.muted),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Get trial — goes through the bot (tracks referral + anti-abuse).
        FilledButton.icon(
          onPressed: _busy ? null : _trial,
          icon: const Icon(Icons.timer_outlined),
          label: Text(s.licenseTrial),
        ),
        const SizedBox(height: 10),
        // Buy — the bot handles payment, referral credit and key delivery.
        FilledButton.tonalIcon(
          onPressed: _buy,
          icon: const Icon(Icons.shopping_cart_outlined),
          label: Text(s.licenseBuy),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _keyController,
          decoration: InputDecoration(
            labelText: s.licenseKeyLabel,
            hintText: 'VDRV-XXXX-XXXX-XXXX',
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => _activate(),
        ),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: _busy ? null : _activate,
          child: Text(s.licenseActivate),
        ),
        if (_message != null) ...[
          const SizedBox(height: 10),
          Text(_message!, textAlign: TextAlign.center),
        ],
        const SizedBox(height: 24),
        if (lic.key != null)
          TextButton.icon(
            onPressed: () async {
              await LicenseService.instance.signOut();
              widget.onChanged();
              setState(() {});
            },
            icon: const Icon(Icons.logout),
            label: Text(s.licenseSignOut),
          ),
        // Referral: the bot generates the user's personal link & tracks credit.
        TextButton.icon(
          onPressed: _buy,
          icon: const Icon(Icons.share),
          label: Text(s.licenseReferral),
        ),
      ],
    );
  }
}
