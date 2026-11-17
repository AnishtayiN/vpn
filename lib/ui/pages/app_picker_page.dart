import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../models/settings.dart';
import '../../services/split.dart';
import '../../services/vpn_controller.dart';
import '../../theme/voidrau_theme.dart';

/// The per-app half of split tunneling: pick the apps that ride the tunnel, or
/// the ones that stay out of it.
///
/// The list comes from Android, which is also what enforces the choice, so
/// nothing here has to be dialled or routed by us — the kernel decides before a
/// packet exists. On a platform without that API the page still opens (the
/// destination rules live next to it) and says so instead of showing an empty
/// list that looks broken.
class AppPickerPage extends StatefulWidget {
  const AppPickerPage({super.key, required this.controller});
  final VpnController controller;

  @override
  State<AppPickerPage> createState() => _AppPickerPageState();
}

class _AppPickerPageState extends State<AppPickerPage> {
  String query = '';
  bool showSystem = false;
  late Set<String> selected;
  late List<SplitApp> apps;

  @override
  void initState() {
    super.initState();
    final c = widget.controller;
    selected = {...c.settings.splitApps};
    apps = SplitRules.parseApps(c.apps);
    c.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  /// The platform app list arrives asynchronously (boot() + m23's
  /// installedApps fetch); refresh the rows when it lands instead of
  /// keeping the empty snapshot from initState.
  void _onControllerChanged() {
    final fresh = SplitRules.parseApps(widget.controller.apps);
    final changed = fresh.length != apps.length ||
        !fresh.every((a) => apps.any((b) => b.id == a.id));
    if (changed && mounted) setState(() => apps = fresh);
  }

  List<SplitApp> get visible => SplitRules.visibleApps(
        apps,
        query: query,
        showSystem: showSystem,
        selected: selected,
      );

  /// Persists the current selection. [toast] is only for the explicit
  /// Apply button — every toggle auto-saves silently (M3b), so Android back
  /// no longer discards the selection.
  void _save({bool toast = false}) {
    final c = widget.controller;
    c.settings.splitApps = selected.toList()..sort();
    c.persist();
    if (toast) c.notifyToast(c.s.splitApplied);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final s = c.s;
    final mode = c.settings.splitMode;
    final rows = visible;
    final systemCount = apps.where((a) => a.system).length;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.selectApps),
        actions: [
          TextButton(
            onPressed: () {
              _save(toast: true);
              Navigator.pop(context);
            },
            child: Text(s.apply),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              decoration: InputDecoration(
                hintText: s.searchApps,
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: VoidrauTheme.surfaceOf(context),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onChanged: (v) => setState(() => query = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                mode == SplitMode.exclude
                    ? s.splitAppsExcludeHint
                    : s.splitAppsIncludeHint,
                style: TextStyle(
                    color: VoidrauTheme.mutedOf(context), fontSize: 12),
              ),
            ),
          ),
          if (apps.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(s.splitPerAppUnsupported,
                  style: TextStyle(color: VoidrauTheme.mutedOf(context))),
            )
          else ...[
            Wrap(
              spacing: 4,
              children: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      selected.addAll(rows.map((e) => e.id));
                    });
                    _save();
                  },
                  child: Text(s.selectAll),
                ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      for (final app in rows) {
                        selected.remove(app.id);
                      }
                    });
                    _save();
                  },
                  child: Text(s.clearAll),
                ),
                // "Everything but these" is the useful gesture in exclude mode:
                // selecting three apps and letting the rest go direct is the
                // same as inverting a list of the two that must not.
                TextButton(
                  onPressed: () {
                    setState(() {
                      selected = SplitRules.invertSelection(selected, rows);
                    });
                    _save();
                  },
                  child: Text(s.appInvert),
                ),
                if (systemCount > 0)
                  FilterChip(
                    label: Text('${s.systemApps} ($systemCount)'),
                    selected: showSystem,
                    onSelected: (v) => setState(() => showSystem = v),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text('${selected.length} ${s.selected}',
                    style: const TextStyle(
                        color: VoidrauColors.cyan, fontSize: 12.5)),
              ),
            ),
            Expanded(
              child: c.apps.isEmpty
                  ? _manualList(s)
                  : rows.isEmpty
                      ? Center(
                          child: Text(s.appSearchEmpty,
                              style: TextStyle(
                                  color: VoidrauTheme.mutedOf(context))),
                        )
                      : ListView.builder(
                          itemCount: rows.length,
                          itemBuilder: (context, i) {
                            final app = rows[i];
                            return CheckboxListTile(
                              dense: true,
                              value: selected.contains(app.id),
                              title: Text(app.label),
                              subtitle: Text(app.id,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              secondary: app.system
                                  ? Icon(Icons.phone_android,
                                      size: 18,
                                      color: VoidrauTheme.mutedOf(context))
                                  : null,
                              onChanged: (v) {
                                setState(() {
                                  if (v == true) {
                                    selected.add(app.id);
                                  } else {
                                    selected.remove(app.id);
                                  }
                                });
                                _save();
                              },
                            );
                          },
                        ),
            ),
          ],
        ],
      ),
    );
  }

  /// No platform list (a desktop, or a build without the API): the entries the
  /// user typed by hand are the whole list, and an executable path can be added.
  Widget _manualList(S s) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: OutlinedButton.icon(
            onPressed: () async {
              final path = await _askPath(context, s.addExe);
              if (path != null && path.trim().isNotEmpty) {
                setState(() => selected.add(path.trim()));
                _save();
              }
            },
            icon: const Icon(Icons.add, size: 18),
            label: Text(s.addExe),
          ),
        ),
        Expanded(
          child: ListView(
            children: selected
                .map((e) => ListTile(
                      dense: true,
                      title: Text(e),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          setState(() => selected.remove(e));
                          _save();
                        },
                      ),
                    ))
                .toList(),
          ),
        ),
      ],
    );
  }

  Future<String?> _askPath(BuildContext context, String title) async {
    final box = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: box,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'C:\\Program Files\\...'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, box.text),
            child: Text(widget.controller.s.apply),
          ),
        ],
      ),
    );
  }
}
