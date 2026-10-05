import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/settings.dart';
import 'services/vpn_controller.dart';
import 'theme/voidrau_theme.dart';
import 'ui/home_shell.dart';
import 'ui/pages/force_update_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const ['Aether'],
      await rootBundle.loadString('assets/legal/Aether-AGPL-3.0.txt'),
    );
    yield LicenseEntryWithLineBreaks(
      const ['hev-socks5-tunnel'],
      await rootBundle.loadString('assets/legal/Hev-MIT.txt'),
    );
  });
  runApp(const VoidrauApp());
}

class VoidrauApp extends StatefulWidget {
  const VoidrauApp({super.key});

  @override
  State<VoidrauApp> createState() => _VoidrauAppState();
}

class _VoidrauAppState extends State<VoidrauApp> with WidgetsBindingObserver {
  final controller = VpnController();
  final _navigator = GlobalKey<NavigatorState>();
  bool _locked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(_watchLock);
    controller.boot();
  }

  /// Coming back to the foreground is one of the mandatory-update checkpoints:
  /// a release published while the app was in the background locks it here.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      controller.refreshUpdate();
      controller.syncNativeState();
    }
  }

  /// As soon as the app is locked by a newer release, unwind whatever page the
  /// user is on: the update screen must be the only reachable surface.
  void _watchLock() {
    if (controller.blocked == _locked) return;
    _locked = controller.blocked;
    if (!_locked) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigator.currentState?.popUntil((route) => route.isFirst);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_watchLock);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final theme = controller.settings.theme;
        final dark = switch (theme) {
          ThemeChoice.dark => true,
          ThemeChoice.light => false,
          ThemeChoice.system =>
            MediaQuery.platformBrightnessOf(context) == Brightness.dark,
        };
        return MaterialApp(
          title: 'VoidrauVPN',
          navigatorKey: _navigator,
          debugShowCheckedModeBanner: false,
          theme: VoidrauColors.light(),
          darkTheme: VoidrauColors.dark(),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          locale: controller.rtl ? const Locale('fa') : const Locale('en'),
          builder: (context, child) {
            return Directionality(
              textDirection:
                  controller.rtl ? TextDirection.rtl : TextDirection.ltr,
              child: child ?? const SizedBox.shrink(),
            );
          },
          // A retired build shows one screen and nothing else: no connect
          // button, no tunnel, just the way to the new version.
          home: controller.blocked
              ? ForceUpdatePage(controller: controller)
              : HomeShell(controller: controller),
        );
      },
    );
  }
}
