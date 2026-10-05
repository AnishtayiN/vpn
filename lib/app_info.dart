/// Single source of truth for the product identity: name, release channel and
/// the links the UI is allowed to show.
///
/// Only VoidrauVPN links live here. The tunnel *core* binary is treated as a
/// black box (it is launched through `AETHER_*` environment variables, which is
/// its own interface) — nothing in the UI advertises any other project.
///
/// The updater checks GitHub Releases internally to know a new version exists,
/// but the UI never shows the repository link — all user-facing update
/// messages point to the official Telegram channel.
class AppInfo {
  static const appName = 'VoidrauVPN';

  /// Injected by the release workflow (`--dart-define=VOIDRAU_VERSION=...`).
  static const version =
      String.fromEnvironment('VOIDRAU_VERSION', defaultValue: '1.0.0');

  /// Version of the bundled tunnel core.
  static const core = '2.1.0';

  static const socksHost = '127.0.0.1';
  static const socksPort = 1819;

  /// Internal release repository — used only for version checking, never shown in UI.
  static const owner = 'DnsChangerPM';
  static const repo = 'VPN';
  static const repoUrl = 'https://github.com/DnsChangerPM/VPN';
  static const releasesUrl = 'https://github.com/DnsChangerPM/VPN/releases';

  /// Official channel — install instructions and release notes are posted here.
  /// This is the only link shown to the user when an update is available.
  static const telegramHandle = '@Voidrau';
  static const telegramUrl = 'https://t.me/Voidrau';
}
