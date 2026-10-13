import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/strings.dart';
import '../../services/license_service.dart';
import '../../services/releases_service.dart';
import '../../theme/voidrau_theme.dart';

/// Downloads tab: every release build published on GitHub, ready to install.
/// Settings changes stay locked while the user is only on a free trial —
/// paying customers get the full app (business rule).
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});
  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  List<ReleaseInfo>? _releases;
  String? _error;
  final Map<String, double> _progress = {}; // asset name → 0..1
  final Map<String, String> _done = {}; // asset name → path

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await ReleasesService.fetch();
      if (mounted) setState(() => _releases = r);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  String _size(int b) => b > 1 << 20
      ? '${(b / (1 << 20)).toStringAsFixed(1)} MB'
      : '${(b / (1 << 10)).round()} KB';

  Future<void> _install(ReleaseAsset a) async {
    if (LicenseService.instance.plan == 'trial') {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(S(Localizations.localeOf(context).languageCode)
              .downloadsTrialLocked)));
      return;
    }
    setState(() => _progress[a.name] = 0);
    try {
      final path = await ReleasesService.download(a.url, a.name,
          onProgress: (d, t) =>
              setState(() => _progress[a.name] = d / t));
      setState(() {
        _progress.remove(a.name);
        _done[a.name] = path;
      });
      if (!mounted) return;
      if (Platform.isAndroid && a.name.endsWith('.apk')) {
        await launchUrl(Uri.parse('file://$path'),
            mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _progress.remove(a.name));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S(Localizations.localeOf(context).languageCode);
    if (_error != null) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(s.downloadsError, style: const TextStyle(color: VoidrauColors.muted)),
        const SizedBox(height: 8),
        TextButton(onPressed: _load, child: Text(s.retry)),
      ]));
    }
    if (_releases == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _releases!.length,
        itemBuilder: (context, i) {
          final rel = _releases![i];
          return Card(
            child: ExpansionTile(
              title: Text(rel.tag,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(s.downloadsAssets(rel.assets.length)),
              children: [
                for (final a in rel.assets)
                  ListTile(
                    leading: Icon(
                      a.name.endsWith('.apk')
                          ? Icons.android
                          : a.name.endsWith('.exe')
                              ? Icons.desktop_windows
                              : Icons.insert_drive_file,
                      color: VoidrauColors.cyan,
                    ),
                    title: Text(a.name),
                    subtitle: _progress.containsKey(a.name)
                        ? LinearProgressIndicator(
                            value: _progress[a.name]! > 0
                                ? _progress[a.name]
                                : null)
                        : Text(_size(a.size)),
                    trailing: _done.containsKey(a.name)
                        ? const Icon(Icons.check_circle,
                            color: Colors.green)
                        : IconButton(
                            icon: const Icon(Icons.download),
                            onPressed: () => _install(a),
                          ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
