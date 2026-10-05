import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../../services/links.dart';
import '../../services/vpn_controller.dart';
import '../../theme/voidrau_theme.dart';
import '../widgets/telegram_button.dart';

/// About screen: the app and the official Telegram channel.
/// No repository link is shown — all releases are on Telegram.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key, required this.controller});
  final VpnController controller;

  @override
  Widget build(BuildContext context) {
    final s = controller.s;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
      children: [
        Center(
          child: Column(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Image.asset('assets/branding/icon.png', width: 96, height: 96),
              ),
              const SizedBox(height: 12),
              Text(s.appName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              Text(
                'v${controller.update?.current ?? AppInfo.version} · ${s.aboutCore} ${AppInfo.core}',
                style: const TextStyle(color: VoidrauColors.muted),
              ),
              const SizedBox(height: 8),
              Text(s.freeNote,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: VoidrauColors.muted)),
            ],
          ),
        ),
        const SizedBox(height: 28),

        // ── the application ──
        Text(s.aboutApp, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(s.aboutAppCredit,
            style: const TextStyle(color: VoidrauColors.muted, height: 1.45)),
        const Divider(height: 28),

        // ── the official channel ──
        Text(s.aboutChannel, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(s.aboutChannelCredit,
            style: const TextStyle(color: VoidrauColors.muted, height: 1.45)),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: TelegramButton(size: 32, onPressed: () => Links.openTelegram()),
          title: const Text(AppInfo.telegramHandle,
              style: TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(AppInfo.telegramUrl.replaceFirst('https://', '')),
          onTap: () => Links.openTelegram(),
          trailing: const Icon(Icons.open_in_new, size: 16),
        ),
        const SizedBox(height: 8),
        Text(
          Platform.isIOS
              ? (s.isFa
                  ? 'نصب و به‌روزرسانی iOS از طریق TestFlight یا App Store انجام می‌شود.'
                  : 'iOS installation and updates are managed by TestFlight or the App Store.')
              : s.isFa
              ? 'تمام نسخه‌های جدید، فایل نصبی و توضیحات انتشار فقط در کانال تلگرام منتشر می‌شود: ${AppInfo.telegramHandle}'
              : 'All new builds, installers and release notes are published only on the Telegram channel: ${AppInfo.telegramHandle}',
          style: const TextStyle(color: VoidrauColors.muted, height: 1.45, fontSize: 12),
        ),
        const Divider(height: 28),

        if (Platform.isIOS) ...[
          Text(s.isFa ? 'حریم خصوصی VPN' : 'VPN privacy',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(s.isFa
              ? 'ترافیک از تونل Cloudflare WARP عبور می‌کند؛ سرویس‌دهنده آدرس IP و درخواست‌های اتصال شما را دریافت می‌کند. کلیدهای اتصال در فضای خصوصی افزونه و تنظیمات روی دستگاه نگه‌داری می‌شوند. تست اتصال با Cloudflare، Mozilla و Google و تشخیص IP با Cloudflare و در صورت نیاز ip-api انجام می‌شود. این بررسی‌ها IP خروجی شما را به مقصد می‌فرستند. گزارش‌ها در حافظهٔ اپ هستند مگر آن‌ها را کپی و به اشتراک بگذارید. این اپ وابستگی رسمی به Cloudflare ندارد.'
              : 'Traffic uses Cloudflare WARP; the provider receives your IP and connection requests. Connection keys are stored in the extension’s private container and preferences on-device. Connectivity checks contact Cloudflare, Mozilla and Google; exit-IP checks contact Cloudflare and, if needed, ip-api. Those checks reveal your exit IP to their recipients. App diagnostics stay in memory unless you copy/share them. This app is not affiliated with Cloudflare.',
              style: const TextStyle(color: VoidrauColors.muted, height: 1.45)),
          const Divider(height: 28),
        ],
        TextButton.icon(
          onPressed: () => showLicensePage(context: context,
              applicationName: AppInfo.appName, applicationVersion: AppInfo.version),
          icon: const Icon(Icons.description_outlined),
          label: Text(s.isFa ? 'مجوزهای متن‌باز' : 'Open-source licenses'),
        ),
        // ── the tunnel core ──
        Text(s.aboutCore, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(s.aboutCoreCredit,
            style: const TextStyle(color: VoidrauColors.muted, height: 1.45)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _chip('${s.coreVersion} v${AppInfo.core}'),
            _chip('Android 7+'),
            _chip('Windows 8.1+'),
            _chip('iOS 16+'),
            _chip('Aether: AGPL-3.0'),
          ],
        ),
      ],
    );
  }

  Widget _chip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: VoidrauColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: VoidrauColors.line),
      ),
      child: Text(text,
          style: const TextStyle(color: VoidrauColors.muted, fontSize: 12)),
    );
  }
}
