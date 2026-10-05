import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_info.dart';
import '../l10n/strings.dart';
import '../models/settings.dart';
import '../services/links.dart';
import '../models/engine_state.dart';
import '../services/vpn_controller.dart';
import '../theme/voidrau_theme.dart';
import 'pages/about_page.dart';
import 'pages/config_page.dart';
import 'pages/connect_page.dart';
import 'pages/diagnostics_page.dart';
import 'pages/settings_page.dart';
import 'pages/speed_page.dart';
import 'pages/split_page.dart';
import 'widgets/telegram_button.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});
  final VpnController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int index = 0;

  /// Guards the "still scanning?" dialog: the controller publishes
  /// [VpnController.exitPrompt] and the shell turns it into exactly one dialog.
  bool _asking = false;
  bool _exitPromptScheduled = false;

  @override
  void initState() {
    super.initState();
    // Show WireGuard hint on first launch (or until "Don't show again" is checked).
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowWgHint());
  }

  Future<void> _maybeShowWgHint() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dontShow = prefs.getBool('wgHintDontShow') ?? false;
      if (dontShow) return;
      if (!mounted) return;
      final c = widget.controller;
      final s = c.s;
      bool dontShowChecked = false;

      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setState) {
              return AlertDialog(
                title: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: VoidrauColors.cyan.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.bolt_rounded,
                          color: VoidrauColors.cyan, size: 22),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(s.wgHintTitle,
                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                    ),
                  ],
                ),
                content: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: VoidrauColors.surface,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: VoidrauColors.line),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.public, size: 14, color: VoidrauColors.muted),
                            const SizedBox(width: 6),
                            Text(
                              s.isFa ? 'پیش‌فرض: هر کشوری (Any Country)' : 'Default: Any Country',
                              style: const TextStyle(fontSize: 12, color: VoidrauColors.muted),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(s.wgHintBody, style: const TextStyle(height: 1.6, fontSize: 13.5)),
                      const SizedBox(height: 16),
                      InkWell(
                        onTap: () {
                          setState(() => dontShowChecked = !dontShowChecked);
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Row(
                          children: [
                            Checkbox(
                              value: dontShowChecked,
                              onChanged: (v) {
                                setState(() => dontShowChecked = v ?? false);
                              },
                            ),
                            Expanded(child: Text(s.wgHintDontShow)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () async {
                      if (dontShowChecked) {
                        await prefs.setBool('wgHintDontShow', true);
                      }
                      if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                    },
                    child: Text(s.wgHintSkip),
                  ),
                  FilledButton.icon(
                    onPressed: () async {
                      // Apply WireGuard protocol
                      c.settings.protocol = Protocol.wg;
                      await c.persist();
                      if (dontShowChecked) {
                        await prefs.setBool('wgHintDontShow', true);
                      }
                      // Guard the *dialog* context with its own mounted flag:
                      // the State's `mounted` is unrelated to dialogContext.
                      if (dialogContext.mounted) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          SnackBar(content: Text(s.wgHintApplied)),
                        );
                        Navigator.of(dialogContext).pop();
                      }
                    },
                    icon: const Icon(Icons.bolt_rounded, size: 18),
                    label: Text(s.wgHintUseWg),
                  ),
                ],
              );
            },
          );
        },
      );
      // If user dismissed without checking "Don't show again", we do NOT save the flag,
      // so next app launch it will show again — exactly as requested.
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final s = c.s;
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final titles = [
          s.navConnect,
          s.navConfig,
          s.navSpeed,
          s.navSplit,
          s.navSettings,
          s.navDiag,
          s.navAbout,
        ];
        final toast = c.toast;
        if (toast != null && toast.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(toast)));
            c.toast = null;
          });
        }
        if (c.exitPrompt && !_asking && !_exitPromptScheduled) {
          _exitPromptScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _exitPromptScheduled = false;
            _askAboutExit(c, s);
          });
        }
        return Scaffold(
          drawer: _Drawer(
            s: s,
            index: index,
            version: c.update?.current ?? AppInfo.version,
            hasUpdate: c.update?.available == true,
            phase: c.snapshot.phase,
            onSelect: (i) {
              setState(() => index = i);
              Navigator.pop(context);
            },
          ),
          appBar: AppBar(
            title: Text(titles[index]),
            actions: [
              // Top-right Telegram mark: opens the official channel, where new
              // versions and their notes are published.
              Center(
                child: TelegramButton(
                  tooltip: '${s.telegram} · ${AppInfo.telegramHandle}',
                  onPressed: () => Links.openTelegram(),
                ),
              ),
              const SizedBox(width: 6),
            ],
          ),
          body: IndexedStack(
            index: index,
            children: [
              ConnectPage(controller: c),
              ConfigPage(controller: c),
              SpeedPage(controller: c),
              SplitPage(controller: c),
              SettingsPage(controller: c),
              DiagnosticsPage(controller: c),
              AboutPage(controller: c),
            ],
          ),
        );
      },
    );
  }

  /// The exit-country search has been running longer than the user's patience
  /// setting (3 minutes by default), so the app asks instead of spinning on:
  /// keep looking for a foreign exit, or take the Iranian one that already
  /// worked. Dismissing the dialog counts as "keep looking".
  Future<void> _askAboutExit(VpnController c, S s) async {
    if (!mounted || _asking) return;
    setState(() => _asking = true);
    final body = c.exitPromptBody;
    final rule = c.exitFilterLabel;
    final keep = s.exitKeepScanning;
    final iran = s.exitUseIran;
    final title = s.exitPromptTitle(rule);
    NavigatorState? dialogNavigator;
    // The search keeps running behind the question. If it lands on an exit the
    // user wants while they are still reading, the dialog must get out of the
    // way instead of asking about a problem that no longer exists.
    void onProgress() {
      if (c.exitPrompt) return;
      dialogNavigator?.pop();
    }

    c.addListener(onProgress);
    try {
      final choice = await showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) {
          dialogNavigator = Navigator.of(dialogContext);
          return AlertDialog(
            title: Text(title, style: const TextStyle(fontSize: 17)),
            content: SingleChildScrollView(child: Text(body)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(keep),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(iran),
              ),
            ],
          );
        },
      );
      if (!mounted) return;
      // Removed before acting on the answer: both handlers notify listeners,
      // and a stale listener would pop whatever route comes next.
      c.removeListener(onProgress);
      if (choice == true) {
        await c.acceptBlockedExit();
      } else {
        await c.keepSearchingForExit();
      }
    } finally {
      c.removeListener(onProgress);
      if (mounted) setState(() => _asking = false);
    }
  }
}

class _Drawer extends StatelessWidget {
  const _Drawer({
    required this.s,
    required this.index,
    required this.onSelect,
    required this.version,
    required this.hasUpdate,
    required this.phase,
  });

  final S s;
  final int index;
  final ValueChanged<int> onSelect;
  final String version;
  final bool hasUpdate;
  final EnginePhase phase;

  @override
  Widget build(BuildContext context) {
    Widget item(int i, IconData icon, String label, {bool badge = false}) {
      final active = index == i;
      return ListTile(
        selected: active,
        leading: Icon(icon, color: active ? VoidrauColors.cyan : VoidrauColors.muted),
        title: Text(label),
        trailing: badge
            ? const CircleAvatar(
                radius: 10,
                backgroundColor: VoidrauColors.coral,
                child: Text('1', style: TextStyle(fontSize: 11, color: Colors.white)),
              )
            : null,
        onTap: () => onSelect(i),
      );
    }

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset('assets/branding/icon.png', width: 44, height: 44),
              ),
              title: Text(s.appName, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(s.brandSubtitle),
            ),
            const Divider(),
            item(0, Icons.shield_outlined, s.navConnect),
            item(1, Icons.tune, s.navConfig),
            item(2, Icons.speed_rounded, s.navSpeed),
            item(3, Icons.alt_route_rounded, s.navSplit),
            item(4, Icons.settings_outlined, s.navSettings, badge: hasUpdate),
            item(5, Icons.terminal, s.navDiag),
            item(6, Icons.info_outline, s.navAbout),
            const Spacer(),
            const Divider(),
            ListTile(
              leading: TelegramButton(
                size: 30,
                onPressed: () => Links.openTelegram(),
              ),
              title: const Text(AppInfo.telegramHandle),
              subtitle: Text(s.telegram),
              onTap: () => Links.openTelegram(),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Text(
                    phase.name,
                    style: const TextStyle(color: VoidrauColors.muted),
                  ),
                  const Spacer(),
                  Text('v$version', style: const TextStyle(color: VoidrauColors.muted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
