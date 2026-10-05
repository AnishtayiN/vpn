import '../models/settings.dart';

/// iOS capabilities are intentionally narrower than Android's. Keep this pure
/// so imported/stored settings and unsupported UI options can be regression tested.
class IosPolicy {
  static void normalize(VpnSettings settings) {
    settings.mode = ConnectionMode.vpn;
    settings.lanShare = false;
    settings.splitMode = SplitMode.off;
    settings.splitApps = const [];
    // The extension holds the whole machine's packets, so a "direct" rule would
    // be captured by the tunnel again and loop: the core's own connection would
    // come straight back to it. Blocking still works (nothing is dialled).
    settings.routeDirect = const [];
    // A packet-tunnel extension may not fork/exec, and Tor's pluggable
    // transports are separate binaries: the second hop is unavailable here.
    settings.chain = ChainMode.off;
    settings.privateDns = true; // Tunnel-scoped DNS, never the physical interface.
    // The native shim pins the profile and the netstack buffers to what an
    // extension's memory budget allows, so the UI must not claim otherwise.
    settings.perf = PerfProfile.eco;
    settings.perfRxKb = 0;
    settings.perfTxKb = 0;
    // The extension sets the TUN MTU itself and the Swift validator accepts the
    // documented 1280-1500 range; a larger device MTU is an Android/desktop
    // optimisation a packet tunnel cannot use.
    if (settings.tunMtu < 1280) settings.tunMtu = 1280;
    if (settings.tunMtu > 1500) settings.tunMtu = 1500;
    settings.autoDownload = false;
    settings.autoUpdate = false; // TestFlight / App Store owns distribution.
  }

  static String help(bool fa) => fa
      ? 'در iOS اتصال از طریق افزونهٔ VPN سیستم انجام می‌شود. حالت پروکسی مستقل، اشتراک LAN و انتخاب اپ‌ها پشتیبانی نمی‌شوند. قواعد «مسدودسازی مقصد» کار می‌کنند اما «عبور مستقیم» نه، چون همهٔ بسته‌ها از تونل عبور می‌کنند. DNS از تونل عبور می‌کند. قطع اضطراری تابع محدودیت‌های iOS است و Always-On سازمانی نیست. اتصال خودکار فقط هنگام بازکردن اپ اجرا می‌شود. پروفایل سرعت روی کم‌مصرف‌ترین سطح می‌ماند، چون افزونهٔ iOS حافظهٔ بسیار کمتری از یک اپ معمولی دارد.'
      : 'iOS uses a system VPN extension. Standalone proxy, LAN sharing and per-app selection are unavailable. Destination *block* rules work, per-destination "direct" rules do not (every packet belongs to the tunnel). DNS uses the tunnel. The performance profile stays at the lowest tier: an extension has a much smaller memory budget than a normal app. Kill switch follows iOS restrictions; it is not supervised Always-On VPN. Auto-connect runs when opening the app.';
}
