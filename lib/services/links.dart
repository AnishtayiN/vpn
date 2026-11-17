import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_info.dart';

/// Opens links in the system browser / Telegram app.
///
/// Every outbound link in the app goes through here, so the only destination
/// the product advertises is the official Telegram channel defined in [AppInfo].
class Links {
  static Future<bool> open(String url) async {
    if (url.isEmpty) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// Like [open], but tells the user when the link could not be opened
  /// instead of failing silently (m25: every caller used to ignore the bool).
  static Future<void> openChecked(
      BuildContext context, String url, String failMessage) async {
    final ok = await open(url);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failMessage)));
    }
  }

  /// Official VoidrauVPN channel — new releases and install instructions.
  static Future<bool> openTelegram() => open(AppInfo.telegramUrl);

  static Future<void> openTelegramChecked(
          BuildContext context, String failMessage) =>
      openChecked(context, AppInfo.telegramUrl, failMessage);

  /// The license/download bot — where users fetch the newest build.
  static Future<bool> openBot() => open(AppInfo.botUrl);

  static Future<void> openBotChecked(BuildContext context, String failMessage) =>
      openChecked(context, AppInfo.botUrl, failMessage);
}
