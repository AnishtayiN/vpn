import 'package:flutter/material.dart';

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

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  S get s => S(Localizations.localeOf(context).languageCode);

  Future<void> _activate() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final ok = await LicenseService.instance.check(keyOverride: key);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = ok ? null : s.licenseBadKey;
    });
    if (ok) widget.onUnlocked();
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
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.lock_outline_rounded,
                    size: 56, color: VoidrauColors.cyan),
                const SizedBox(height: 16),
                const Text(
                  '🔒 برنامه قفل است',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  'برای ورود، لایسنس خریداری‌شده را وارد کنید.\n'
                  'تست رایگان و رفرال فقط امکان اتصال موقت می‌دهد و تنظیمات قفل است.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: VoidrauColors.muted, height: 1.5),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _keyController,
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: 'VDRV-XXXX-XXXX-XXXX',
                    filled: true,
                    fillColor: VoidrauColors.surface,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onSubmitted: (_) => _activate(),
                ),
                if (_message != null) ...[
                  const SizedBox(height: 8),
                  Text(_message!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: VoidrauColors.coral)),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _activate,
                  child: Text(_busy ? '...' : 'ورود به برنامه'),
                ),
                TextButton(
                  onPressed: _busy ? null : _refresh,
                  child: const Text('بررسی دوباره لایسنس'),
                ),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: () => Links.openBot(),
                  icon: const Icon(Icons.smart_button_rounded, size: 18),
                  label: const Text('خرید / تست رایگان از ربات'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
