class S {
  S(this.languageCode);
  final String languageCode;
  bool get isFa => languageCode == 'fa';

  String get appName => 'VoidrauVPN';
  String get brandSubtitle => isFa ? 'شبکه خصوصی' : 'Private network';
  String get navConnect => isFa ? 'اتصال' : 'Connect';
  String get navConfig => isFa ? 'پیکربندی' : 'Configurations';
  String get navSettings => isFa ? 'تنظیمات' : 'Settings';
  String get navSpeed => isFa ? 'سرعت' : 'Speed';
  String get navSplit => isFa ? 'تونل تفکیکی' : 'Split';
  String get navDiag => isFa ? 'عیب‌یابی' : 'Diagnostics';
  String get navAbout => isFa ? 'درباره' : 'About';

  String get connect => isFa ? 'اتصال' : 'CONNECT';
  String get disconnect => isFa ? 'قطع اتصال' : 'DISCONNECT';
  String get tapToSecure => isFa ? 'برای امنیت لمس کنید' : 'Tap to secure';
  String get ready => isFa ? 'آماده اتصال' : 'Ready';
  String get active => isFa ? 'محافظت فعال' : 'Protected';
  String get connecting => isFa ? 'در حال اتصال…' : 'Connecting…';
  String get scanning => isFa ? 'در حال اسکن…' : 'Scanning…';
  String get reconnecting => isFa ? 'اتصال مجدد…' : 'Reconnecting…';
  String get disconnecting => isFa ? 'در حال قطع…' : 'Disconnecting…';
  String get error => isFa ? 'خطای اتصال' : 'Connection error';
  String get preparing => isFa ? 'آماده‌سازی مسیر امن' : 'Preparing a secure route';

  String get download => isFa ? 'دانلود' : 'Download';
  String get upload => isFa ? 'آپلود' : 'Upload';
  String get ping => isFa ? 'پینگ' : 'Ping';
  String get location => isFa ? 'موقعیت' : 'Location';

  String get mode => isFa ? 'حالت اتصال' : 'Connection mode';
  String get deviceVpn => isFa ? 'VPN دستگاه' : 'Device VPN';
  String get socksProxy => isFa ? 'پروکسی SOCKS5' : 'SOCKS5 proxy';
  String get protocol => isFa ? 'پروتکل' : 'Protocol';
  String get scan => isFa ? 'حالت اسکن' : 'Scan mode';
  String get obfuscation => isFa ? 'استتار' : 'Obfuscation';
  String get transport => isFa ? 'انتقال MASQUE' : 'MASQUE transport';
  String get endpoint => isFa ? 'نقطه پایانی سفارشی' : 'Custom endpoint';
  String get ipVersion => isFa ? 'نسخه IP' : 'IP version';
  String get autoReconnect => isFa ? 'اتصال مجدد خودکار' : 'Quick reconnect';
  String get autoReconnectHelp => isFa
      ? 'استفاده از آخرین دروازه سالم'
      : 'Reuse the last known-good gateway';
  String get fragment => isFa ? 'فرگمنت TLS' : 'TLS fragmentation';
  String get fragmentHelp => isFa
      ? 'فقط برای MASQUE روی HTTP/2'
      : 'MASQUE HTTP/2 ClientHello splitting';
  String get autoConnect => isFa ? 'اتصال هنگام شروع' : 'Connect at launch';
  String get killSwitch => isFa ? 'مسدودسازی هنگام خطا' : 'Fail closed';
  String get killSwitchHelp =>
      isFa ? 'قطع ترافیک تا بازیابی تونل' : 'Block traffic while recovering';
  String get privateDns => isFa ? 'DNS خصوصی' : 'Private DNS';
  String get lanShare => isFa ? 'اشتراک در شبکه محلی' : 'Allow LAN clients';
  String get lanShareHelp => isFa
      ? 'گوش دادن SOCKS روی همه رابط‌ها — فقط شبکه مورد اعتماد'
      : 'Bind SOCKS on all interfaces — trusted LAN only';
  String get splitTitle => isFa ? 'تونل تفکیکی' : 'Split tunneling';
  String get splitHelp => isFa
      ? 'انتخاب کنید کدام برنامه‌ها از تونل عبور کنند و کدام مقصدها بیرون از آن بمانند'
      : 'Choose which apps ride the tunnel, and which destinations stay outside it';
  String get splitOff => isFa ? 'همه برنامه‌ها' : 'All apps';
  String get splitInclude => isFa ? 'فقط انتخاب‌شده' : 'Only selected';
  String get splitExclude => isFa ? 'به‌جز انتخاب‌شده' : 'Bypass selected';

  String get appearance => isFa ? 'ظاهر' : 'Appearance';
  String get themeSystem => isFa ? 'سیستم' : 'System';
  String get themeDark => isFa ? 'تیره' : 'Dark';
  String get themeLight => isFa ? 'روشن' : 'Light';
  String get language => isFa ? 'زبان' : 'Language';
  String get notifications => isFa ? 'اعلان‌ها' : 'Notifications';
  String get updates => isFa ? 'به‌روزرسانی' : 'Updates';
  String get autoUpdates => isFa ? 'بررسی خودکار' : 'Automatic checks';
  String get autoUpdatesHelp => isFa
      ? 'هنگام اجرا، بازگشت به برنامه و پیش از هر اتصال بررسی می‌شود'
      : 'Checked on launch, on resume and before every connection';
  String get currentVersion => isFa ? 'نسخه فعلی' : 'Current version';
  String get latestVersion => isFa ? 'آخرین نسخه' : 'Latest version';
  String get checkUpdates => isFa ? 'بررسی به‌روزرسانی' : 'Check for updates';
  String get downloadUpdate => isFa ? 'دانلود به‌روزرسانی' : 'Download update';
  String get openRelease => isFa ? 'مشاهده در تلگرام' : 'Open Telegram channel';
  String get upToDate => isFa ? 'برنامه به‌روز است' : 'You are up to date';
  String get updateAvailable => isFa ? 'نسخه جدید آماده است' : 'Update available';
  String get updateFailed => isFa ? 'بررسی ناموفق بود' : 'Update check failed';
  String get installNow => isFa ? 'دانلود و نصب خودکار' : 'Download & install now';
  String get installingUpdate =>
      isFa ? 'در حال دانلود… %SUM%' : 'Downloading… %SUM%';
  String get updateReadyInstalling => isFa
      ? 'دانلود کامل شد — نصب شروع شد'
      : 'Download complete — installation started';
  String get updateDownloadFailed =>
      isFa ? 'دانلود ناموفق بود — دوباره تلاش کنید' : 'Download failed — try again';
  String get checking => isFa ? 'در حال بررسی…' : 'Checking…';
  String get updateChannel => isFa ? 'کانال انتشار نسخه‌ها' : 'Release channel';

  String get logs => isFa ? 'گزارش زنده' : 'Live log';
  String get clearLogs => isFa ? 'پاک کردن' : 'Clear';
  String get copyLogs => isFa ? 'کپی' : 'Copy';
  String get testConnection => isFa ? 'تست اتصال' : 'Test connection';
  String get recover => isFa ? 'بازیابی شبکه' : 'Recover network';

  String get aboutTitle => isFa ? 'درباره' : 'About';
  String get aboutCore => isFa ? 'هسته تونل' : 'Tunnel core';
  String get aboutCoreCredit => isFa
      ? 'موتور داخلی برنامه — MASQUE، WireGuard، gool و MASQUE×2.'
      : 'The engine built into the app — MASQUE, WireGuard, gool and MASQUE×2.';
  String get aboutApp => isFa ? 'برنامه: VoidrauVPN' : 'Application: VoidrauVPN';
  String get aboutAppCredit => isFa
      ? 'کلاینت فلاتر برای ویندوز ۸.۱ تا ۱۱ و اندروید ۷ به بالا.'
      : 'Flutter client for Windows 8.1–11 and Android 7+.';
  String get aboutChannel => isFa ? 'کانال تلگرام' : 'Telegram channel';
  String get aboutChannelCredit => isFa
      ? 'نسخه‌های جدید، توضیحات انتشار و پشتیبانی در کانال تلگرام منتشر می‌شود.'
      : 'New versions, release notes and support are posted on the Telegram channel.';
  String get telegram => isFa ? 'کانال تلگرام' : 'Telegram channel';
  String get telegramShort => 'Telegram';
  String get openTelegram => isFa ? 'باز کردن کانال تلگرام' : 'Open Telegram channel';
  String get reset => isFa ? 'بازنشانی پیش‌فرض' : 'Reset defaults';
  String get apply => isFa ? 'اعمال' : 'Apply';
  String socksHint(int port) => isFa
      ? 'پروکسی محلی: 127.0.0.1:$port'
      : 'Local proxy: 127.0.0.1:$port';
  String get statusReady => isFa ? 'آماده' : 'Ready';
  String get lanUser => isFa ? 'کاربر LAN' : 'LAN user';
  String get lanPass => isFa ? 'رمز LAN' : 'LAN password';
  String get logLevel => isFa ? 'سطح گزارش' : 'Log level';
  String get detecting => isFa ? 'در حال تشخیص موقعیت…' : 'Detecting location…';
  String get needVpnPerm => isFa
      ? 'اجازه VPN سیستم لازم است'
      : 'System VPN permission is required';
  String get needAdmin => isFa
      ? 'برای VPN سراسری ویندوز، برنامه را به‌صورت Administrator اجرا کنید'
      : 'System-wide Windows VPN needs Administrator rights';
  String get deviceVpnHint => isFa
      ? 'برای VPN دستگاه (عبور همه برنامه‌ها از تونل)، برنامه باید Administrator باشد'
      : 'A device VPN (every app through the tunnel) needs VoidrauVPN to run as Administrator';
  String get restartAsAdmin => isFa
      ? 'اجرا به‌صورت Administrator'
      : 'Run as Administrator';
  String get elevationRefused => isFa
      ? 'ارتقای دسترسی انجام نشد — پنجره UAC رد شد یا در دسترس نیست'
      : 'Elevation did not happen — the UAC prompt was declined or unavailable';
  String get windowsVersion => isFa ? 'ویندوز' : 'Windows';
  String get elevated => isFa ? 'دسترسی Administrator' : 'Administrator';
  String get tunBackend => isFa ? 'پل TUN' : 'TUN bridge';
  String get tunAdapter => isFa ? 'آداپتور WinTUN' : 'WinTUN adapter';
  String get tunBlocked => isFa
      ? 'چرا VPN دستگاه بالا نیامد'
      : 'Why the device VPN is down';
  String get yes => isFa ? 'بله' : 'Yes';
  String get no => isFa ? 'خیر' : 'No';
  String get selectApps => isFa ? 'انتخاب برنامه‌ها' : 'Select applications';
  String get searchApps => isFa ? 'جست‌وجوی برنامه‌ها' : 'Search applications';
  String get selected => isFa ? 'انتخاب‌شده' : 'selected';
  String get selectAll => isFa ? 'انتخاب همه' : 'Select all';
  String get clearAll => isFa ? 'پاک کردن همه' : 'Clear all';
  String get addExe => isFa ? 'افزودن مسیر برنامه' : 'Add executable path';
  String get duration => isFa ? 'مدت اتصال' : 'Duration';
  String get copyProxy => isFa ? 'کپی آدرس پروکسی' : 'Copy proxy address';
  String get copied => isFa ? 'کپی شد' : 'Copied';
  String get tun => isFa ? 'رابط TUN' : 'TUN interface';
  String get exitIp => isFa ? 'آی‌پی خروجی' : 'Exit IP';
  String get exitCountry => isFa ? 'کشور خروجی' : 'Exit country';
  String get tunnelIp => isFa ? 'آی‌پی تونل' : 'VPN IP';
  String get ipCopied => isFa ? 'آی‌پی کپی شد' : 'IP copied';
  String get copyIp => isFa ? 'کپی آی‌پی' : 'Copy IP';
  String get coreVersion => isFa ? 'هسته تونل' : 'Tunnel core';
  String get tunnel => isFa ? 'تونل' : 'Tunnel';
  String get refresh => isFa ? 'نوسازی' : 'Refresh';
  String get downloading => isFa ? 'در حال دانلود…' : 'Downloading…';
  String get install => isFa ? 'نصب' : 'Install';
  String get verifying => isFa ? 'در حال بررسی صحت فایل…' : 'Verifying file…';
  String get shaMismatch => isFa ? 'هش فایل مطابقت ندارد' : 'File hash mismatch';
  String get lanAddress => isFa ? 'آدرس اشتراک LAN' : 'LAN listen address';
  String get battery => isFa ? 'بهینه‌سازی باتری' : 'Battery optimization';
  String get batteryHelp => isFa
      ? 'برای اتصال پایدار، بهینه‌سازی باتری را برای VoidrauVPN خاموش کنید'
      : 'Disable battery optimization so the tunnel can stay up';
  String get vpnSettings => isFa ? 'تنظیمات VPN سیستم' : 'System VPN settings';
  String get scanTurbo => isFa ? 'سریع' : 'Turbo';
  String get scanBalanced => isFa ? 'متعادل' : 'Balanced';
  String get scanThorough => isFa ? 'عمیق' : 'Thorough';
  String get scanStealth => isFa ? 'پنهان' : 'Stealth';
  String get scanIronclad => isFa ? 'قطعی' : 'Ironclad';
  String get freeNote => isFa
      ? 'کاملاً رایگان و متن‌باز. بدون حساب کاربری و بدون محدودیت ترافیک.'
      : 'Free and open source. No account and no traffic quota.';
  String get bypassLan => isFa ? 'دور زدن شبکه محلی' : 'Bypass LAN';
  String get bypassLanHelp => isFa
      ? 'ترافیک 192.168/10/172.16 از تونل نرود'
      : 'Keep RFC1918 LAN off the tunnel';
  String get ipv6Tunnel => isFa ? 'تونل IPv6' : 'Tunnel IPv6';
  String get watchdog => isFa ? 'نگهبان اتصال' : 'Connection watchdog';
  String get watchdogHelp => isFa
      ? 'اگر هسته افتاد، خودش دوباره وصل شود'
      : 'Reconnect automatically if the core drops';
  String get advanced => isFa ? 'پیشرفته' : 'Advanced';
  String get socksPort => isFa ? 'پورت SOCKS' : 'SOCKS port';
  String get keepalive => isFa ? 'Keepalive (ثانیه)' : 'Keepalive (seconds)';
  String get tunMtu => 'TUN MTU';
  String get stallTimeout => isFa ? 'مهلت ایست (ثانیه)' : 'Stall timeout (seconds)';
  String get orbStyle => isFa ? 'سبک دکمه اتصال' : 'Orb style';
  String get orbClassic => isFa ? 'کلاسیک' : 'Classic';
  String get orbMercury => isFa ? 'جیوه زنده' : 'Living mercury';
  String get autoDownload => isFa ? 'دانلود خودکار به‌روزرسانی' : 'Auto-download updates';
  String get qsTile => isFa
      ? 'کاشی تنظیمات سریع و ویجت صفحه اصلی را از لانچر اضافه کنید'
      : 'Add the Quick Settings tile and home widget from your launcher';

  // ── forced update ──────────────────────────────────────────────────────────
  String get updateRequiredTitle => isFa
      ? 'نسخه جدید منتشر شده است'
      : 'A new version is out';
  String get updateRequiredHeadline => isFa
      ? 'این نسخه غیرفعال شده است'
      : 'This version has been disabled';
  String get updateRequiredBody => isFa
      ? 'به‌محض انتشار نسخه جدید، نسخه‌های قبلی از کار می‌افتند. برای ادامه استفاده، نسخه جدید VoidrauVPN را نصب کنید.'
      : 'As soon as a new release is published, older versions stop working. Install the new VoidrauVPN build to keep using it.';
  String get updateRequiredTelegramLead => isFa
      ? 'فایل نصبی و توضیحات کامل نسخه جدید در کانال تلگرام منتشر می‌شود:'
      : 'The installer and the full release notes are published on the Telegram channel:';
  String get updateStep1 => isFa
      ? 'وارد کانال تلگرام شوید'
      : 'Open the Telegram channel';
  String get updateStep2 => isFa
      ? 'آخرین نسخه VoidrauVPN را از کانال دانلود کنید'
      : 'Download the latest VoidrauVPN build from the channel';
  String get updateStep3 => isFa
      ? 'فایل را نصب کنید و برنامه را دوباره باز کنید'
      : 'Install it and reopen the app';
  String get releaseNotes => isFa ? 'توضیحات نسخه' : 'Release notes';
  String get checkAgain => isFa ? 'بررسی مجدد' : 'Check again';
  String get updatedToContinue => isFa
      ? 'پس از نصب نسخه جدید، اتصال دوباره فعال می‌شود'
      : 'Connecting is re-enabled once the new version is installed';
  String get directDownload => isFa
      ? 'دانلود از کانال تلگرام'
      : 'Download from Telegram channel';
  String get downloadFromChannel => isFa
      ? 'نصب از کانال تلگرام'
      : 'Install from the Telegram channel';
  String get versionOutdated => isFa ? 'نسخه قدیمی' : 'Outdated version';

  // ── exit country ─────────────────────────────────────────────────────────
  String get exitFilter => isFa ? 'کشور آی‌پی خروجی' : 'Exit IP country';
  String get exitPausedTitle =>
      isFa ? 'قاعدهٔ کشور خروج موقتاً کنار گذاشته شده' : 'Exit rule paused';
  String get exitPausedBody => isFa
      ? 'چون یک‌بار «اتصال با آی‌پی ایران» را انتخاب کردید، قاعده فعال نیست؛ اما پاک هم نشده است. با یک ضربه دوباره فعال می‌شود و دنبال کشورهای انتخابی می‌گردد.'
      : 'Because you once chose "connect with the Iran IP", the rule is not being enforced — but it has not been thrown away. One tap turns it back on and searches for your countries again.';
  String get exitResume => isFa ? 'فعال کردن دوبارهٔ قاعده و جست‌وجو' : 'Turn the rule back on and search';
  String get exitFilterHelp => isFa
      ? 'پس از اتصال، کشور آی‌پی خروجی بررسی می‌شود؛ اگر مطابق انتخاب شما نبود، تونل بسته و مسیر دیگری امتحان می‌شود.'
      : 'After connecting, the exit IP\'s country is checked; if it is not the one you want, the tunnel is redialled on another route.';
  String get exitOff => isFa ? 'هر کشوری' : 'Any country';
  String get exitNonIran => isFa ? 'هر آی‌پی غیر ایران' : 'Any IP but Iran';
  String get exitPreferred => isFa ? 'کشور دلخواه' : 'Preferred country';
  String get exitAny => isFa ? 'هر کشوری' : 'any country';
  String get exitAnyExcept => isFa ? 'هر کشور به‌جز' : 'any country except';
  String get exitPreferredCountries =>
      isFa ? 'کشورهای ترجیحی' : 'Preferred countries';
  String get exitBlockedCountries => isFa ? 'کشورهای حذف‌شده' : 'Excluded countries';
  String get exitAskAfter => isFa ? 'پرسش پس از (دقیقه)' : 'Ask after (minutes)';
  String exitSearching(String rule, String seen, int tries, int maxTries) {
    final t = '$tries/$maxTries';
    if (isFa) {
      return seen.isEmpty
          ? 'جست‌وجوی خروجی $rule — تلاش $t'
          : 'خروجی $rule می‌خواهیم؛ تاکنون: $seen — تلاش $t';
    }
    return seen.isEmpty
        ? 'Looking for an exit in $rule — attempt $t'
        : 'Wanted exit: $rule; seen so far: $seen — attempt $t';
  }

  String exitPromptTitle(String rule) => isFa
      ? 'هنوز دنبال آی‌پی $rule هستیم'
      : 'Still looking for an IP in $rule';
  String exitPromptBody(int minutes, String rule, int tries) => isFa
      ? '$minutes دقیقه است که برای خروجی «$rule» اسکن می‌کنیم ($tries تلاش). ادامه بدهیم یا به همان آی‌پی ایران وصل شویم؟'
      : 'We have been scanning for $minutes minutes for an exit matching "$rule" ($tries attempts). Keep looking, or connect with the Iran IP instead?';
  String get exitKeepScanning => isFa ? 'ادامه اسکن' : 'Keep scanning';
  String get exitUseIran => isFa ? 'اتصال با آی‌پی ایران' : 'Connect with the Iran IP';
  String exitNotFound(String rule) => isFa
      ? 'خروجی $rule پیدا نشد — کشور آی‌پی خروجی را در پیکربندی تغییر دهید'
      : 'No exit matching $rule was found — change the exit IP country in Configurations';

  // ── WireGuard hint (first launch) ────────────────────────────────────────
  String get wgHintTitle => isFa
      ? 'پیشنهاد برای اینترنت ایران'
      : 'Recommendation for Iran';
  String get wgHintBody => isFa
      ? 'برای اینترنت ایران، پروتکل WireGuard معمولاً پایدارتر و سریع‌تره:\n\n'
          '• مصرف باتری و دیتای کمتر نسبت به MASQUE\n'
          '• اتصال سریع‌تر و پینگ پایین‌تر\n'
          '• عبور بهتر از فیلترینگ‌های سنگین\n'
          '• مناسب برای تماس، بازی و استریم\n\n'
          'حالت پیش‌فرض برنامه روی «هر کشوری» (Any Country) تنظیم شده تا سریع وصل بشه. '
          'اگر می‌خوای بهترین تجربه رو برای نت ایران داشته باشی، پروتکل رو روی WireGuard بذار.\n\n'
          'می‌تونی بعداً از بخش پیکربندی هم پروتکل رو تغییر بدی.'
      : 'For Iranian networks, WireGuard is usually more stable and faster:\n\n'
          '• Lower battery and data usage than MASQUE\n'
          '• Faster handshake and lower ping\n'
          '• Better bypass on heavily filtered networks\n'
          '• Great for calls, gaming and streaming\n\n'
          'Default exit is set to "Any Country" for fastest connection. '
          'If you want the best experience on Iran networks, switch protocol to WireGuard.\n\n'
          'You can change protocol anytime in Configurations.';
  String get wgHintUseWg => isFa ? 'استفاده از وایرگارد' : 'Use WireGuard';
  String get wgHintSkip => isFa ? 'رد کردن' : 'Skip';
  String get wgHintDontShow => isFa ? 'دیگه نشون نده' : "Don't show again";
  String get wgHintApplied => isFa
      ? 'پروتکل روی WireGuard تنظیم شد'
      : 'Protocol set to WireGuard';

  // ── speed (2.3.0 performance profile, live meter, throughput test) ────────
  String get speedTitle => isFa ? 'سرعت و پروفایل کارایی' : 'Speed & performance';
  String get speedHelp => isFa
      ? 'هسته به‌طور خودکار از روی تعداد هسته و رم دستگاه یک سطح کارایی انتخاب می‌کند. اگر خط شما پرسرعت است و هنوز سرعت کم است، سطح را دستی بالا ببرید.'
      : 'The core picks a performance tier from your CPU count and RAM. If your line is fast and the tunnel still feels capped, raise it by hand.';
  String get perfEco => isFa ? 'کم‌مصرف' : 'Eco';
  String get perfAuto => isFa ? 'خودکار' : 'Automatic';
  String get perfTurbo => isFa ? 'توربو' : 'Turbo';
  String get perfExtreme => isFa ? 'حداکثر' : 'Extreme';
  String get perfEcoHelp => isFa
      ? 'کوچک‌ترین بافرها — برای گوشی‌های قدیمی و مصرف باتری'
      : 'Smallest buffers — old phones, battery first';
  String get perfAutoHelp => isFa
      ? 'تشخیص خودکار بر اساس سخت‌افزار (پیشنهادی)'
      : 'Detected from the hardware (recommended)';
  String get perfTurboHelp => isFa
      ? 'سطح High با پنجره ۲ مگابایتی — بیشترین اثر روی دانلود'
      : 'The high tier with a 2 MiB window — the big download win';
  String get perfExtremeHelp => isFa
      ? 'دو برابر توربو؛ رم بیشتری مصرف می‌کند'
      : 'Twice Turbo; uses more memory per connection';
  String get perfIosNote => isFa
      ? 'در iOS افزونهٔ VPN با حافظهٔ محدود کار می‌کند، پس پروفایل همیشه روی کم‌مصرف‌ترین سطح می‌ماند. سرعت اینجا از مسیر و پروتکل می‌آید، نه از بافرها.'
      : 'On iOS the extension runs with a much smaller memory budget, so the profile always stays at the lowest tier. Speed here comes from the route and the protocol, not from buffers.';
  String get perfApplied => isFa
      ? 'پروفایل ذخیره شد — برای اعمال، اتصال دوباره لازم است'
      : 'Profile saved — reconnect to apply it';
  String get applyNow => isFa ? 'اعمال و اتصال دوباره' : 'Apply & reconnect';
  String get liveSpeed => isFa ? 'ترافیک زنده' : 'Live traffic';
  String get leakCheck => isFa ? 'آزمون واقعی تونل' : 'Tunnel reality check';
  String get leakCheckHelp => isFa
      ? 'همین حالا دو بار آی‌پی عمومی خوانده می‌شود: یک‌بار از مسیر عادی خط و یک‌بار از داخل تونل. اگر یکی باشند، ترافیک شما از تونل عبور نمی‌کند.'
      : 'Reads the public IP twice: once on the raw line, once through the tunnel. If they match, your traffic is not going through the tunnel.';
  String get leakRun => isFa ? 'بررسی کن' : 'Check now';
  String get leakRunning => isFa ? 'در حال بررسی…' : 'Checking…';
  String get leakRaw => isFa ? 'خط عادی (بدون تونل)' : 'Raw line (no tunnel)';
  String get leakThrough => isFa ? 'از داخل تونل' : 'Through the tunnel';
  String get leakOk => isFa
      ? 'ترافیک واقعاً از تونل عبور می‌کند؛ آی‌پی و کشور بالا همان چیزی است که سایت‌ها می‌بینند.'
      : 'Traffic really goes through the tunnel; the address above is what sites see.';
  String get leakBypassed => isFa
      ? 'هر دو یکی هستند: ترافیک از تونل عبور نمی‌کند و آی‌پی نمایش‌داده‌شده آی‌پی خود خط است. اتصال را دوباره برقرار کنید و اگر تکرار شد، حالت پروتکل را عوض کنید.'
      : 'Both are the same address: traffic is not going through the tunnel, and the IP you see is your own line. Reconnect, and if it repeats switch the protocol.';
  String get leakNoTunnel => isFa
      ? 'برای مقایسه، اول وصل شوید تا مسیر داخل تونل هم خوانده شود.'
      : 'Connect first so the tunnelled path can be compared.';
  String get leakFailed => isFa
      ? 'خواندن آی‌پی ممکن نشد (فیلترینگ یا قطعی).'
      : 'Could not read the address (filtering or no connectivity).';
  String get perfProfile => isFa ? 'پروفایل سرعت' : 'Speed profile';
  String get off => isFa ? 'خاموش' : 'Off';

  /// Diagnostics cell: the two MTUs, spelled out so nobody has to guess which
  /// side is which.
  String mtuSummary(int device, int core) => isFa
      ? 'دستگاه $device / هسته ${core == 0 ? 'خودکار' : '$core'}'
      : 'device $device / core ${core == 0 ? 'auto' : '$core'}';

  String get mtuHelp => isFa
      ? 'MTU دستگاه: اندازه بسته‌هایی که برنامه‌ها می‌فرستند. ۱۵۰۰ پیشنهاد می‌شود.'
      : 'Device MTU: the packet size apps send. 1500 is the usual pick.';
  String get coreMtuLabel =>
      isFa ? 'MTU داخلی هسته (۰ = خودکار)' : 'Core inner MTU (0 = auto)';
  String get coreMtuHelp => isFa
      ? 'MTU داخلی هسته: ۰ یعنی خودش تصمیم بگیرد (۱۲۸۰ برای QUIC، ۱۵۰۰ برای HTTP/2)'
      : 'Core inner MTU: 0 lets the core decide (1280 for QUIC, 1500 over TCP)';
  String get tcpTuning => isFa ? 'تنظیم دقیق TCP' : 'TCP tuning';
  String get tcpConnect => isFa ? 'مهلت اتصال (ثانیه)' : 'Connect timeout (s)';
  String get tcpKeepalive => isFa ? 'Keepalive (ثانیه)' : 'Keep-alive (s)';
  String get halfClose => isFa ? 'نیمه‌بسته (ثانیه)' : 'Half-closed (s)';
  String get quicV2 => isFa ? 'بازکننده QUIC v2' : 'QUIC v2 opener';
  String get quicV2Help => isFa
      ? 'عبور از فیلترهایی که فقط QUIC نسخه ۱ را می‌شناسند'
      : 'Slips past filters that only know QUIC v1';
  String get ech => isFa ? 'ECH (پنهان‌کردن SNI)' : 'ECH (hide the SNI)';
  String get echHelp => isFa
      ? 'درخواست Encrypted Client Hello از کلاودفلر'
      : 'Fetch an Encrypted Client Hello config from Cloudflare';
  String get secondHop => isFa ? 'مسیر دوم (Psiphon / Tor)' : 'Second hop (Psiphon / Tor)';
  String get secondHopHelp => isFa
      ? 'اگر شبکه‌ای WARP را می‌بندد، تونل را از داخل Psiphon یا Tor عبور بده'
      : 'When a network blocks WARP outright, carry or dial the tunnel through Psiphon or Tor';
  String get hopOff => isFa ? 'خاموش' : 'Off';
  String get hopPsiphon => isFa ? 'Psiphon' : 'Psiphon';
  String get hopPsiphonReverse => isFa ? 'Psiphon (معکوس)' : 'Psiphon reverse';
  String get hopPsiphonOnly => isFa ? 'فقط Psiphon' : 'Psiphon only';
  String get hopTor => isFa ? 'Tor' : 'Tor';
  String get hopTorReverse => isFa ? 'Tor (معکوس)' : 'Tor reverse';
  String get hopTorOnly => isFa ? 'فقط Tor' : 'Tor only';
  String get standaloneMode => isFa ? 'حالت مستقل' : 'Standalone mode';
  String get standaloneStandard =>
      isFa ? 'معمولی (پروتکل + مسیر دوم)' : 'Standard (protocol + second hop)';
  String get standaloneHelp => isFa
      ? '«فقط Psiphon» یا «فقط Tor» یعنی همهٔ ترافیک فقط از Psiphon یا Tor عبور می‌کند و WARP زیر آن نیست. در یک زمان فقط یک تونل باز است؛ انتخاب هر حالت، حالت قبلی را کنار می‌گذارد.'
      : '“Psiphon only” or “Tor only” means all traffic exits through Psiphon or Tor alone, with no WARP underneath. Only one tunnel runs at a time; picking a mode replaces the previous one.';
  String get standaloneTorHeavy => isFa
      ? 'Tor سنگین‌ترین حالت است: مصرف داده و باتری بیشتر و سرعت کمتر — فقط وقتی لازم است از آن استفاده کنید.'
      : 'Tor is the heaviest mode: more data and battery, slower — use it only when needed.';
  String get standaloneUnverified => isFa
      ? 'بودن Psiphon/Tor در این نسخهٔ هسته هنوز تأیید نشده است. اگر وصل نشد، به حالت معمولی برگردید.'
      : 'Psiphon/Tor in this core version is not verified yet. If it fails to connect, switch back to Standard.';
  String get standaloneSlow => isFa
      ? 'Psiphon و Tor دیر بالا می‌آیند؛ گاهی تا ۳ دقیقه طول می‌کشد. صبر کنید و اگر نشد، به حالت معمولی برگردید.'
      : 'Psiphon and Tor are slow to start; it can take up to 3 minutes. Wait, and switch back to Standard if it never comes up.';
  String get hopIgnoredNote => isFa
      ? 'در حالت مستقل، مسیر دوم نادیده گرفته می‌شود؛ برای استفاده از آن، حالت را روی «معمولی» بگذارید.'
      : 'In a standalone mode the second hop is ignored; set the mode back to Standard to use it.';
  String get reverseForcesMasque => isFa
      ? 'با مسیر معکوس، پروتکل به‌صورت خودکار MASQUE روی HTTP/2 می‌شود؛ WireGuard از داخل Psiphon یا Tor رد نمی‌شود.'
      : 'With a reverse hop the protocol automatically becomes MASQUE over HTTP/2; WireGuard cannot travel through Psiphon or Tor.';
  String get showDiagnostics =>
      isFa ? 'مشاهدهٔ گزارش کامل' : 'Show full diagnostics';
  String get connectionMode => isFa ? 'حالت اتصال' : 'Connection mode';
  String connectionModeLine(String engine, String mode) =>
      isFa ? 'حالت اتصال: $engine — $mode' : 'Connection mode: $engine — $mode';
  String get errPsiphonMissing => isFa
      ? 'فایل کمکی Psiphon در برنامه نیست؛ با نصب نسخهٔ جدید درست می‌شود. اگر این خطا را در نسخهٔ ۱٫۵٫۲ یا جدیدتر دیدید، گزارش را بفرستید.'
      : 'The Psiphon helper file is missing from the app; installing the new version fixes it. If you see this on v1.5.2 or newer, please send the diagnostics.';
  String get errTorNoTransports => isFa
      ? 'Tor نتوانست بریج‌های obfs4 را اجرا کند (فایل کمکی Tor نیست)؛ با نصب نسخهٔ جدید درست می‌شود.'
      : 'Tor could not run its obfs4 bridges (the Tor helper file is missing); installing the new version fixes it.';
  String get errReverseWg => isFa
      ? 'مسیر معکوس با WireGuard کار نمی‌کند؛ پروتکل به MASQUE برگردانده شد. دوباره وصل شوید.'
      : 'A reverse hop cannot use WireGuard; the protocol was switched back to MASQUE. Connect again.';
  String get errSocksTimeout => isFa
      ? 'هسته بالا نیامد؛ شبکه را عوض کنید یا حالت را تغییر دهید و دوباره تلاش کنید.'
      : 'The tunnel core did not come up; try another network or mode and connect again.';
  String get errNoTraffic => isFa
      ? 'تونل باز شد ولی ترافیکی عبور نکرد؛ گیت‌وی جواب نمی‌دهد. حالت یا شبکه را عوض کنید.'
      : 'The tunnel opened but carried no traffic; the gateway is not answering. Try another mode or network.';
  String get errHopSlow => isFa
      ? 'Psiphon/Tor در زمان مقرر بالا نیامد؛ شاید در این شبکه مسدود است. حالت معمولی یا شبکهٔ دیگر را امتحان کنید.'
      : 'Psiphon/Tor did not come up in time; it may be blocked on this network. Try Standard mode or another network.';
  String get errCoreExited => isFa
      ? 'هسته ناگهان خاموش شد. گزارش کامل را در بخش عیب‌یابی ببینید.'
      : 'The tunnel core stopped unexpectedly. See the full log in Diagnostics.';
  String get hopRegion => isFa ? 'کشور خروجی Psiphon' : 'Psiphon exit country';
  String get hopRegionHelp => isFa
      ? 'مثلاً DE یا US — خالی یعنی خودش انتخاب کند'
      : 'e.g. DE or US — empty lets it choose';
  String get hopCdn => isFa ? 'محدود به CDN (meek)' : 'CDN only (meek)';
  String get hopHttp => isFa ? 'پروکسی HTTP هم بساز' : 'Also serve HTTP CONNECT';
  String get hopHttpHelp => isFa
      ? 'پروکسی HTTP این پرش روی یک پورت جدا باز می‌شود تا برنامه‌هایی که SOCKS5 نمی‌فهمند هم از آن استفاده کنند.'
      : 'The hop also opens an HTTP proxy on its own port, for apps that cannot speak SOCKS5.';
  String get torCountry => isFa ? 'کشور برای دریافت بریج' : 'Bridgedb country';
  String get torCountryHelp => isFa
      ? 'مثل ir — بریج‌های مناسب همان کشور'
      : 'e.g. ir — bridges suited to that country';

  // ── split tunneling ──────────────────────────────────────────────────────
  String get splitPerApp => isFa ? 'تفکیک برنامه‌ها' : 'Per app';
  String get splitPerAppHelp => isFa
      ? 'اندروید خودش تصمیم می‌گیرد کدام برنامه وارد تونل شود؛ برنامه‌های دیگر اینترنت عادی خود را دارند.'
      : 'Android itself decides which apps enter the tunnel; the rest keep their normal internet.';
  String get splitPerAppUnsupported => isFa
      ? 'روی این سیستم‌عامل امکان تفکیک برنامه‌ای نیست (کارت شبکه بسته را می‌بیند، نه برنامه را).'
      : 'This OS cannot split per app: the adapter sees packets, not processes.';
  String get splitDestinations => isFa ? 'تفکیک مقصدها' : 'Per destination';
  String get splitDestinationsHelp => isFa
      ? 'دامنه/آی‌پی/پورت را مستقیم بفرست یا کامل مسدود کن — روی همه سیستم‌عامل‌ها کار می‌کند.'
      : 'Send a domain/IP/port out directly, or refuse it — works on every platform.';
  String get splitDirect => isFa ? 'عبور مستقیم (بدون VPN)' : 'Direct (leave the VPN)';
  String get splitBlock => isFa ? 'مسدود' : 'Block';
  String get splitDirectHint => isFa
      ? 'مثال: bank.ir یا 10.0.0.0/8 یا keyword:tiktok'
      : 'e.g. bank.ir, 10.0.0.0/8 or keyword:tiktok';
  String get splitBlockHint => isFa
      ? 'مثال: ads.example.com یا port:25'
      : 'e.g. ads.example.com or port:25';
  String get splitAdd => isFa ? 'افزودن' : 'Add';
  String get splitPresetPrivate => isFa ? 'شبکه محلی' : 'Local network';
  String get splitPresetPrivateHelp => isFa
      ? 'رنج‌های خصوصی از تونل بیرون بمانند'
      : 'Keep private ranges off the tunnel';
  String get splitPresetSmtp => isFa ? 'پورت ۲۵' : 'Port 25';
  String get splitRuleBad => isFa
      ? 'این قاعده قابل استفاده نیست (فاصله/کاما/خالی)'
      : 'That rule cannot be used (space, comma or empty)';
  String get splitRuleDuplicate => isFa ? 'تکراری است' : 'Already in the list';
  String get splitWindowsNote => isFa
      ? 'در ویندوز فقط قاعده‌های آدرس‌محور (IP/شبکه) روی اینترنت واقعی اثر دارند؛ قاعده‌های نام‌محور در اندروید اعمال می‌شوند.'
      : 'On Windows only address rules (IP/network) really leave the tunnel; name rules apply on Android.';
  String get splitNone => isFa ? 'فعال نیست' : 'Not active';
  String get appSearchEmpty => isFa ? 'برنامه‌ای پیدا نشد' : 'No application found';
  String get appInvert => isFa ? 'برعکس کن' : 'Invert';
  String get systemApps => isFa ? 'برنامه‌های سیستمی' : 'System apps';
  String get splitAppsIncludeHint => isFa
      ? 'فقط همین برنامه‌ها از تونل عبور می‌کنند؛ بقیه با اینترنت عادی.'
      : 'Only these apps go through the tunnel; everything else uses the raw connection.';
  String get splitAppsExcludeHint => isFa
      ? 'همه از تونل عبور می‌کنند جز همین برنامه‌ها.'
      : 'Everything goes through the tunnel except these apps.';
  String get splitAppsOwn => isFa
      ? 'خود VoidrauVPN همیشه از تونل بیرون می‌ماند تا حلقه ایجاد نشود'
      : 'VoidrauVPN itself always stays outside the tunnel (no routing loop)';
  String get splitApplied => isFa
      ? 'قواعد تفکیکی ذخیره شد — برای اعمال، اتصال دوباره لازم است'
      : 'Split rules saved — reconnect to apply them';


  // ── downloads ────────────────────────────────────────────────────────────
  String get downloadsError => isFa ? 'خطا در دریافت لیست نسخه‌ها' : 'Failed to load releases';
  String get retry => isFa ? 'تلاش دوباره' : 'Retry';
  String get getFromBot => isFa ? 'دریافت نسخه جدید از ربات' : 'Get the new build from the bot';
  String get getFromBotHelp => isFa ? 'نسخهٔ جدید را ربات تلگرام برایت می‌فرستد' : 'The Telegram bot sends you the new build';
  String downloadsAssets(int n) => isFa ? '$n فایل' : '$n files';
  String get downloadsTrialLocked => isFa
      ? 'دانلود نسخه‌های جدید فقط برای لایسنس خریداری‌شده فعال است'
      : 'Downloads are available with a paid license only';
  String get settingsLocked => isFa
      ? 'در حالت تست رایگان تنظیمات قفل است — برای تغییر، لایسنس بخرید'
      : 'Settings are locked during the free trial — buy a license to change them';

  // ── license ──────────────────────────────────────────────────────────────
  String get navLicense => isFa ? 'لایسنس' : 'License';
  String get licenseActiveTitle => isFa ? 'لایسنس فعال است' : 'License active';
  String get licenseInactiveTitle => isFa ? 'لایسنس فعال نیست' : 'No active license';
  String get licenseInactiveBody => isFa
      ? 'برای استفاده از VPN ابتدا لایسنس بگیرید — تست رایگان ۲۴ ساعته از طریق ربات تلگرام.'
      : 'Get a license to use the VPN — start with a free 24h trial via the Telegram bot.';
  String get licenseRemaining => isFa ? 'زمان باقی‌مانده' : 'Time remaining';
  String get licensePlan => isFa ? 'پلن' : 'Plan';
  String get licenseRecheck => isFa ? 'بررسی دوباره لایسنس' : 'Re-check license';
  String get licenseTrial => isFa ? 'تست رایگان ۲۴ ساعته (ربات تلگرام)' : 'Free 24h trial (Telegram bot)';
  String get licenseBuy => isFa ? 'خرید لایسنس / شارژ' : 'Buy / top-up license';
  String get licenseKeyLabel => isFa ? 'کد لایسنس' : 'License key';
  String get licenseActivate => isFa ? 'فعال‌سازی' : 'Activate';
  String get licenseOk => isFa ? '✅ لایسنس فعال شد' : '✅ License activated';
  String get licenseBadKey => isFa ? '❌ کد نامعتبر یا منقضی است' : '❌ Invalid or expired key';
  String get licenseSignOut => isFa ? 'خروج از لایسنس' : 'Sign out of license';
  String get licenseReferral => isFa ? 'دعوت دوستان و گرفتن روز هدیه' : 'Invite friends, earn free days';
  String get licenseRequiredToast => isFa
      ? 'لایسنس فعال نیست — از تب «لایسنس» تست رایگان بگیرید'
      : 'No active license — get a free trial from the License tab';

  // ── diagnostics additions ────────────────────────────────────────────────
  String get exitLock => isFa ? 'قفل کشور خروجی در هسته' : 'Core exit lock';
  String get httpProxy => isFa ? 'پروکسی HTTP محلی' : 'Local HTTP proxy';
  String get httpProxyHelp => isFa
      ? 'برای برنامه‌هایی که فقط پروکسی HTTP می‌فهمند'
      : 'For apps that only understand an HTTP proxy';
  String get exitLockHelp => isFa
      ? 'هسته پیش از باز شدن پروکسی، کشور خروجی را بررسی می‌کند تا اسکن دوباره لازم نشود'
      : 'The core checks the exit country before opening the proxy, so fewer re-dials';

  // ── speed & quality metrics ──────────────────────────────────────────────
  String get qualityExcellent => isFa ? 'کیفیت عالی (مناسب گیم و استریم)' : 'Excellent quality (Gaming & 4K)';
  String get qualityGood => isFa ? 'کیفیت خوب (وبگردی سریع و تماس)' : 'Good quality (Fast browsing & Calls)';
  String get qualityFair => isFa ? 'کیفیت معمولی (پینگ متوسط)' : 'Fair quality (Moderate ping)';
  String get qualityPoor => isFa ? 'تاخیر بالا (پینگ ضعیف)' : 'High latency (Poor ping)';
  String get peakSpeed => isFa ? 'رکورد سرعت جلسه' : 'Session Peak Speed';
  String get recheckPing => isFa ? 'تست مجدد پینگ' : 'Re-check ping';

  // ── diagnostics report ───────────────────────────────────────────────────
  String get copyDiagReport => isFa ? 'کپی گزارش کامل سیستم' : 'Copy Full Diagnostics Report';
  String get diagReportCopied => isFa ? 'گزارش عیب‌یابی کپی شد' : 'Diagnostics report copied to clipboard';
  String get dnsLeakTest => isFa ? 'بررسی نشت DNS و IP' : 'DNS & IP Leak Check';

  // ── Xray engine (Android only) ─────────────────────────────────────────
  String get xrayTitle => isFa ? 'حالت‌های Xray' : 'Xray modes';
  String get xrayHelp => isFa
      ? 'موتور دوم کنار Aether — فقط اندروید. هر حالت جداگانه فعال و خاموش می‌شود و در یک زمان فقط یک تونل باز است. هیچ سرور، ورکر یا کلید آماده‌ای در برنامه نیست.'
      : 'A second engine beside Aether — Android only. Each mode can be switched on or off separately, and only one tunnel runs at a time. The app ships no server, Worker or key.';
  String get xrayAndroidOnly => isFa
      ? 'حالت‌های Xray فعلاً فقط روی اندروید هستند؛ ویندوز و iOS با همان Aether کار می‌کنند.'
      : 'Xray modes are Android-only for now; Windows and iOS keep using Aether.';
  String get xrayModeLabel => isFa ? 'حالت Xray' : 'Xray mode';
  String get xrayOff => isFa ? 'خاموش (Aether)' : 'Off (Aether)';
  String get xrayWorker => 'Worker';
  String get xrayWarp => 'WARP';
  String get xrayServerless => isFa ? 'مستقیم (Serverless)' : 'Serverless';
  String get xrayWorkerHelp => isFa
      ? 'VLESS از طریق ورکر کلادفلر خودتان — ورکر با توکن خودتان دیپلوی می‌شود و فقط TCP را رله می‌کند.'
      : 'VLESS through your own Cloudflare Worker — deployed with your own token, TCP relay only.';
  String get xrayWarpHelp => isFa
      ? 'وایرگارد به WARP کلادفلر با حسابی که روی همین دستگاه ثبت می‌شود؛ بدون ورکر. پروکسی‌های UDP هم روی همین حالت سوار می‌شوند.'
      : 'WireGuard to Cloudflare WARP with an account registered on this device; no Worker. UDP proxies ride on this mode.';
  String get xrayServerlessHelp => isFa
      ? 'اتصال مستقیم با فرگمنت TLS و نویز UDP — بدون سرور، بدون MITM و بدون نصب گواهی.'
      : 'Direct connections with TLS fragmentation and UDP noise — no server, no MITM, no certificate install.';
  String get xrayFragment => isFa ? 'فرگمنت TLS' : 'TLS fragment';
  String get xrayFragmentHelp => isFa
      ? 'تقسیم ClientHello به قطعه‌های کوچک'
      : 'Split the ClientHello into small pieces';
  String get xrayNoise => isFa ? 'نویز UDP' : 'UDP noise';
  String get xrayNoiseHelp => isFa
      ? 'بسته‌های نویز تصادفی روی UDP'
      : 'Random noise packets over UDP';
  String get xrayModeSaved =>
      isFa ? 'حالت Xray ذخیره شد' : 'Xray mode saved';
  String get xrayUseServerless =>
      isFa ? 'استفاده از حالت مستقیم' : 'Use Serverless mode';

  // ── setup wizard ───────────────────────────────────────────────────────
  String get wizardToken => isFa ? 'توکن API کلادفلر' : 'Cloudflare API token';
  String get wizardTokenHint =>
      isFa ? 'توکن را اینجا بچسبانید' : 'Paste the token here';
  String get wizardCheckToken =>
      isFa ? 'بررسی توکن و نمایش حساب‌ها' : 'Check token & list accounts';
  String get wizardMakeToken =>
      isFa ? 'ساخت توکن در کلادفلر' : 'Create a token at Cloudflare';
  String get wizardTokenHelp => isFa
      ? 'توکن فقط در حافظهٔ امن گوشی می‌ماند و هرگز در کد، گزارش یا گیت نمی‌رود. برای حذف، «حذف ورکر» را بزنید.'
      : 'The token stays only in the phone’s secure storage and never goes into code, logs or git. Use “Remove Worker” to delete it.';
  String get wizardCheckingToken =>
      isFa ? 'در حال بررسی توکن…' : 'Checking the token…';
  String get wizardAccount => isFa ? 'حساب کلادفلر' : 'Cloudflare account';
  String get wizardFallback =>
      isFa ? 'سایت جایگزین (اختیاری)' : 'Fallback site (optional)';
  String get wizardFallbackHint =>
      isFa ? 'مثلاً example.com' : 'e.g. example.com';
  String get wizardProxyIps =>
      isFa ? 'آی‌پی‌های پروکسی (اختیاری)' : 'Proxy IPs (optional)';
  String get wizardProxyIpsHint => isFa
      ? 'هر خط یک host:port — برای هدف‌های میزبانی‌شده روی کلادفلر'
      : 'One host:port per line — for Cloudflare-hosted targets';
  String get wizardCustomDomain =>
      isFa ? 'دامنهٔ اختصاصی (اختیاری)' : 'Custom domain (optional)';
  String get wizardCustomDomainHint =>
      isFa ? 'مثلاً vpn.example.com' : 'e.g. vpn.example.com';
  String get wizardDeploy => isFa ? 'دیپلوی ورکر' : 'Deploy Worker';
  String get wizardDeploying =>
      isFa ? 'در حال دیپلوی ورکر…' : 'Deploying the Worker…';
  String wizardDeployed(String domain) =>
      isFa ? 'ورکر دیپلوی شد: $domain' : 'Worker deployed: $domain';
  String get wizardDeployedNote => isFa
      ? 'ورکر شما آماده است — حالت Worker را از صفحهٔ اتصال انتخاب کنید.'
      : 'Your Worker is ready — pick Worker mode on the Connect page.';
  String get wizardRemoveWorker =>
      isFa ? 'حذف ورکر (توکن و UUID هم پاک می‌شود)' : 'Remove Worker (also wipes the token and UUID)';
  String get wizardRegisteringWarp =>
      isFa ? 'در حال ثبت حساب WARP…' : 'Registering a WARP account…';
  String get wizardRegisterWarp =>
      isFa ? 'ثبت حساب WARP' : 'Register a WARP account';
  String get wizardReRegisterWarp =>
      isFa ? 'ثبت دوبارهٔ حساب WARP' : 'Re-register the WARP account';
  String get wizardWarpDone =>
      isFa ? 'حساب WARP ثبت شد' : 'WARP account registered';
  String get wizardWarpHelp => isFa
      ? 'کلیدها روی همین دستگاه ساخته می‌شوند؛ کلید خصوصی هرگز از گوشی خارج نمی‌شود و فقط در حافظهٔ امن می‌ماند.'
      : 'Keys are generated on this device; the private key never leaves the phone and stays only in secure storage.';

  // ── chain proxies ──────────────────────────────────────────────────────
  String get chainTitle => isFa ? 'پروکسی‌های زنجیره‌ای' : 'Chain proxies';
  String get chainHelp => isFa
      ? 'لینک پروکسی‌هایی که خودتان وارد می‌کنید، به‌عنوان خروجی اتصال Xray استفاده می‌شوند. برنامه هیچ پروکسی آماده‌ای ندارد.'
      : 'Proxy links you enter yourself, used as the exit of an Xray connection. The app ships no proxy.';
  String get chainUdpNote => isFa
      ? 'پروکسی‌های UDP (وایرگارد / Hysteria2) فقط روی WARP سوار می‌شوند؛ ورکر فقط TCP رله می‌کند و Serverless اصلاً زنجیره ندارد.'
      : 'UDP proxies (WireGuard / Hysteria2) ride on WARP only; the Worker relays TCP only and Serverless has no chain at all.';
  String get chainHint => isFa
      ? 'لینک را بچسبانید: vless:// ،vmess:// ،trojan:// ،ss:// ،socks:// ،http:// ،wireguard:// ،hysteria2:// یا فایل کانفیگ وایرگارد'
      : 'Paste a link: vless://, vmess://, trojan://, ss://, socks://, http://, wireguard://, hysteria2://, or a WireGuard config file';
  String get chainAdd => isFa ? 'افزودن' : 'Add';
  String get chainPaste => isFa ? 'چسباندن' : 'Paste';
  String chainAdded(int n) =>
      isFa ? '$n پروکسی اضافه شد' : '$n prox${n == 1 ? 'y' : 'ies'} added';
  String get chainInvalid =>
      isFa ? 'لینک پشتیبانی نمی‌شود' : 'Link not supported';
  String get chainEmpty =>
      isFa ? 'هنوز پروکسی‌ای اضافه نشده است.' : 'No proxy added yet.';
  String get chainUdpOnly =>
      isFa ? 'فقط UDP — فقط روی WARP' : 'UDP only — WARP only';
  String get chainUseAsExit =>
      isFa ? 'استفاده به‌عنوان خروجی' : 'Use as exit';
}

