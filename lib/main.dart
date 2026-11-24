import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'models/settings.dart';
import 'services/vpn_controller.dart';
import 'theme/voidrau_theme.dart';
import 'ui/home_shell.dart';
import 'ui/pages/force_update_page.dart';
import 'services/license_service.dart';
import 'ui/pages/license_gate_page.dart';

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

  Future<void> _refreshLicense() async {
    final beforePlan = LicenseService.instance.plan;
    final beforeActive = LicenseService.instance.isActive;
    await LicenseService.instance.check();
    // Notify when the plan changed OR when active flipped: a license that
    // expired while the app was backgrounded keeps the same plan string
    // ('paid') but isActive goes false — without this the shell never
    // rebuilds and the gate never appears.
    if (LicenseService.instance.plan != beforePlan ||
        LicenseService.instance.isActive != beforeActive) {
      controller.notifyLicenseChanged();
    }
  }

  /// Coming back to the foreground is one of the mandatory-update checkpoints:
  /// a release published while the app was in the background locks it here.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      controller.refreshUpdate();
      controller.syncNativeState();
      // Re-validate the license on resume: an admin approval (trial → paid)
      // upgrades the plan server-side; this refresh unlocks UI without
      // requiring the user to re-enter the key.
      _refreshLicense();
    }
    if (state == AppLifecycleState.detached) {
      // Exit handler: the process is going away — tear the tunnel down
      // now so the system proxy is restored instead of left pointing at
      // the dead listener (Chrome ERR_PROXY_CONNECTION_FAILED after a
      // hard close). Best effort: the engine may already be detaching,
      // and the on-disk proxy snapshot is the backstop for a close that
      // outruns this cleanup.
      unawaited(controller.disconnect().catchError((_) {}));
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
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('fa'), Locale('en')],
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
              : LicenseService.instance.isActive
                  ? HomeShell(controller: controller)
                  : LicenseGatePage(
                      onUnlocked: () => setState(() {}),
                    ),
        );
      },
    );
  }
}
