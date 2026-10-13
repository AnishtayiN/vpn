
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../app_info.dart';

/// One downloadable file attached to a GitHub release.
class ReleaseAsset {
  ReleaseAsset({required this.name, required this.url, required this.size});
  final String name;
  final String url; // browser_download_url
  final int size;
}

class ReleaseInfo {
  ReleaseInfo({required this.tag, required this.notes, required this.assets, required this.publishedAt});
  final String tag;
  final String notes;
  final List<ReleaseAsset> assets;
  final DateTime? publishedAt;
}

/// Reads the public GitHub releases of the app repo and lets users download
/// any build (APK / EXE) from inside the app.
class ReleasesService {
  static final _api =
      Uri.parse('https://api.github.com/repos/${AppInfo.owner}/${AppInfo.repo}/releases?per_page=20');

  static Future<List<ReleaseInfo>> fetch() async {
    final res = await http.get(_api, headers: {
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'VoidrauVPN/${AppInfo.version}',
    }).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw HttpException('releases ${res.statusCode}');
    final list = jsonDecode(res.body) as List;
    return [
      for (final r in list)
        ReleaseInfo(
          tag: r['tag_name'] as String? ?? '',
          notes: r['body'] as String? ?? '',
          publishedAt: DateTime.tryParse(r['published_at']?.toString() ?? ''),
          assets: [
            for (final a in (r['assets'] as List? ?? []))
              ReleaseAsset(
                name: a['name'] as String? ?? '',
                url: a['browser_download_url'] as String? ?? '',
                size: a['size'] as int? ?? 0,
              ),
          ],
        ),
    ];
  }

  /// Downloads [url] to the Downloads directory (Android) or temp dir,
  /// returns the saved file path.
  static Future<String> download(String url, String name, {void Function(int, int)? onProgress}) async {
    final req = http.Request('GET', Uri.parse(url));
    final res = await http.Client().send(req).timeout(const Duration(minutes: 10));
    if (res.statusCode != 200) throw HttpException('download ${res.statusCode}');
    final dir = Platform.isAndroid
        ? Directory('/storage/emulated/0/Download')
        : await getTemporaryDirectory();
    try {
      await dir.create(recursive: true);
    } catch (_) {}
    final file = File('${dir.path}/$name');
    final sink = file.openWrite();
    final total = res.contentLength ?? 0;
    var done = 0;
    await for (final chunk in res.stream) {
      done += chunk.length;
      sink.add(chunk);
      if (onProgress != null && total > 0) onProgress(done, total);
    }
    await sink.flush();
    await sink.close();
    return file.path;
  }
}
