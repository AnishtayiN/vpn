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

  /// Official VoidrauVPN channel — new releases and install instructions.
  static Future<bool> openTelegram() => open(AppInfo.telegramUrl);
}
