import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../models/engine_state.dart';
import '../../models/settings.dart';
import '../../services/split.dart';
import '../../services/vpn_controller.dart';
import '../../theme/voidrau_theme.dart';
import 'app_picker_page.dart';

/// Split tunneling, in one place: *which apps* ride the VPN, and *which
/// destinations* must not.
///
/// The two halves are deliberately separate, because they run in different
/// places and have different reach:
///
/// * the per-app list is enforced by Android itself (the kernel decides before a
///   packet even exists), so it is offered only where that API exists;
/// * the destination rules live inside the tunnel core, which is what dials the
///   connection — so they work under a full-device tunnel on every platform.
class SplitPage extends StatefulWidget {
  const SplitPage({super.key, required this.controller});
  final VpnController controller;

  @override
  State<SplitPage> createState() => _SplitPageState();
}

class _SplitPageState extends State<SplitPage> {
  final _direct = TextEditingController();
  final _block = TextEditingController();

  @override
  void dispose() {
    _direct.dispose();
    _block.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final s = c.s;
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final st = c.settings;
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 40),
          children: [
            Text(s.splitTitle,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            _perApp(c, s, st),
            const SizedBox(height: 18),
            _destinations(c, s, st),
            const SizedBox(height: 18),
            if (c.snapshot.phase == EnginePhase.connected)
              FilledButton.tonalIcon(
                onPressed: c.busy ? null : c.applyAndReconnect,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(s.applyNow),
              ),
          ],
        );
      },
    );
  }

  // ── per app ──────────────────────────────────────────────────────────────

  Widget _perApp(VpnController c, S s, VpnSettings st) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.apps_rounded, color: VoidrauColors.cyan, size: 20),
          const SizedBox(height: 8),
          Text(s.splitPerApp,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 4),
          Text(s.splitPerAppHelp,
              style: const TextStyle(color: VoidrauColors.muted, fontSize: 12.5, height: 1.4)),
          const SizedBox(height: 12),
          if (!Platform.isAndroid)
            Text(s.splitPerAppUnsupported,
                style: const TextStyle(color: VoidrauColors.muted, height: 1.4))
          else ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: Text(s.splitOff),
                  selected: st.splitMode == SplitMode.off,
                  onSelected: (_) {
                    st.splitMode = SplitMode.off;
                    c.persist();
                    c.notifyToast(s.splitApplied);
                  },
                ),
                ChoiceChip(
                  label: Text(s.splitInclude),
                  selected: st.splitMode == SplitMode.include,
                  onSelected: (_) {
                    st.splitMode = SplitMode.include;
                    c.persist();
                    c.notifyToast(s.splitApplied);
                  },
                ),
                ChoiceChip(
                  label: Text(s.splitExclude),
                  selected: st.splitMode == SplitMode.exclude,
                  onSelected: (_) {
                    st.splitMode = SplitMode.exclude;
                    c.persist();
                    c.notifyToast(s.splitApplied);
                  },
                ),
              ],
            ),
            if (st.splitMode != SplitMode.off) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AppPickerPage(controller: c),
                  ),
                ),
                icon: const Icon(Icons.list_alt_rounded, size: 18),
                label: Text(
                    '${s.selectApps}  (${st.splitApps.length} ${s.selected})'),
              ),
              const SizedBox(height: 8),
              Text(s.splitAppsOwn,
                  style: const TextStyle(
                      fontSize: 11.5, color: VoidrauColors.muted, height: 1.4)),
            ],
          ],
        ],
      ),
    );
  }

  // ── per destination ──────────────────────────────────────────────────────

  Widget _destinations(VpnController c, S s, VpnSettings st) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.alt_route_rounded,
              color: VoidrauColors.cyan, size: 20),
          const SizedBox(height: 8),
          Text(s.splitDestinations,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 4),
          Text(s.splitDestinationsHelp,
              style: const TextStyle(color: VoidrauColors.muted, fontSize: 12.5, height: 1.4)),
          const SizedBox(height: 12),
          _ruleEditor(
            c,
            s,
            title: s.splitDirect,
            hint: s.splitDirectHint,
            entries: st.routeDirect,
            controller: _direct,
            onAdd: (v) {
              st.routeDirect = SplitRules.normalize([...st.routeDirect, v]);
              c.persist();
            },
            onRemove: (v) {
              st.routeDirect = [...st.routeDirect]..remove(v);
              c.persist();
            },
            warnOnWindows: true,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              ActionChip(
                avatar: const Icon(Icons.lan_outlined, size: 16),
                label: Text(s.splitPresetPrivate),
                tooltip: s.splitPresetPrivateHelp,
                onPressed: () {
                  st.routeDirect = SplitRules.normalize([...st.routeDirect, 'private']);
                  c.persist();
                },
              ),
              ActionChip(
                avatar: const Icon(Icons.mail_outline, size: 16),
                label: Text(s.splitPresetSmtp),
                onPressed: () {
                  st.routeBlock = SplitRules.normalize([...st.routeBlock, 'port:25']);
                  c.persist();
                },
              ),
            ],
          ),
          const Divider(height: 28),
          _ruleEditor(
            c,
            s,
            title: s.splitBlock,
            hint: s.splitBlockHint,
            entries: st.routeBlock,
            controller: _block,
            onAdd: (v) {
              st.routeBlock = SplitRules.normalize([...st.routeBlock, v]);
              c.persist();
            },
            onRemove: (v) {
              st.routeBlock = [...st.routeBlock]..remove(v);
              c.persist();
            },
          ),
          if (Platform.isWindows) ...[
            const SizedBox(height: 10),
            Text(s.splitWindowsNote,
                style: const TextStyle(
                    fontSize: 11.5, color: VoidrauColors.muted, height: 1.4)),
          ],
        ],
      ),
    );
  }

  Widget _ruleEditor(
    VpnController c,
    S s, {
    required String title,
    required String hint,
    required List<String> entries,
    required TextEditingController controller,
    required ValueChanged<String> onAdd,
    required ValueChanged<String> onRemove,
    bool warnOnWindows = false,
  }) {
    void add() {
      final raw = controller.text.trim();
      if (raw.isEmpty) return;
      final parsed = SplitRules.parse(raw);
      final bad = parsed.isEmpty ? [raw] : parsed;
      for (final entry in bad) {
        final problem = SplitRules.problem(SplitRules.canonical(entry));
        if (problem != null) {
          c.notifyToast(s.splitRuleBad);
          return;
        }
        if (entries.contains(SplitRules.canonical(entry))) {
          c.notifyToast(s.splitRuleDuplicate);
          return;
        }
      }
      onAdd(raw);
      controller.clear();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
                color: VoidrauColors.muted, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                decoration: InputDecoration(
                  hintText: hint,
                  isDense: true,
                  filled: true,
                  fillColor: VoidrauColors.surface,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                onSubmitted: (_) => add(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: add, child: Text(s.splitAdd)),
          ],
        ),
        if (entries.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: entries.map((e) {
                // A rule the current platform cannot honour is shown, but muted
                // and explained: silently dropping it would look like a bug.
                final inactive = warnOnWindows &&
                    Platform.isWindows &&
                    !SplitRules.windowsRoutable(e);
                final chip = Chip(
                  label: Text(e),
                  backgroundColor:
                      inactive ? VoidrauColors.surface2 : null,
                  onDeleted: () => onRemove(e),
                  deleteIcon: const Icon(Icons.close, size: 16),
                );
                return inactive
                    ? Tooltip(message: s.splitWindowsNote, child: chip)
                    : chip;
              }).toList(),
            ),
          ),
      ],
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VoidrauColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: VoidrauColors.line),
      ),
      child: child,
    );
  }
}
