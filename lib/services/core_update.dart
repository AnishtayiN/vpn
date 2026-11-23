import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Windows core-only updates: when a release changes nothing but the
/// tunnel core files, refresh just those files in place from the
/// portable zip instead of running the installer. Settings live in the
/// per-user runtime dir / SharedPreferences, never beside the exe, so
/// they are untouched either way.
///
/// Whether a release *is* core-only is declared, never guessed: either
/// by a `core-manifest.json` asset on the release ([CoreUpdateManifest])
/// or by the remote config's `coreOnlyVersions` list. The zip contents
/// are then *verified* against that claim — if any app file differs,
/// the core-only path refuses and the caller falls back to the full
/// installer. Android keeps the full-APK in-app update: replacing
/// native libraries at runtime is not safe there.

/// One file entry of a [CoreUpdateManifest].
class CoreManifestFile {
  const CoreManifestFile({required this.path, this.sha256, this.source});

  /// Install-relative path, forward slashes (`pt/lyrebird.exe`).
  final String path;
  final String? sha256;

  /// Where the file comes from (`portable-zip` today; a per-file URL
  /// can plug in here later without changing the shape).
  final String? source;

  factory CoreManifestFile.fromJson(Map<String, dynamic> json) =>
      CoreManifestFile(
        path: CoreFileSet.normalize('${json['path'] ?? ''}'),
        sha256: (json['sha256'] as String?)?.toLowerCase(),
        source: json['source'] as String?,
      );
}

/// The `core-manifest.json` release asset: declares whether a release
/// is core-only and lists the core files it carries. Produced by the
/// release workflow (see the v1.9.0 report); absent on older releases,
/// where the remote config list is the declaration instead.
class CoreUpdateManifest {
  const CoreUpdateManifest({
    required this.version,
    required this.coreOnly,
    this.files = const [],
  });

  final String version;
  final bool coreOnly;
  final List<CoreManifestFile> files;

  bool isCoreOnlyFor(String? v) => coreOnly && v != null && v == version;

  static CoreUpdateManifest? tryParse(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map) return null;
      final map = Map<String, dynamic>.from(json);
      final version = '${map['version'] ?? ''}'.trim();
      if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) return null;
      final files = <CoreManifestFile>[];
      final raw = map['files'];
      if (raw is List) {
        for (final f in raw) {
          if (f is Map) {
            files.add(
                CoreManifestFile.fromJson(Map<String, dynamic>.from(f)));
          }
        }
      }
      return CoreUpdateManifest(
        version: version,
        coreOnly: map['coreOnly'] == true,
        files: files,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Which install-relative paths are "core" files — the sidecars staged
/// by `scripts/fetch_cores.sh` next to `voidrauvpn.exe`. Everything
/// else (the app exe, Flutter DLLs, `data/…`) is app code: if any of
/// it differs, the release is not core-only.
class CoreFileSet {
  static const Set<String> corePaths = {
    'aether.exe',
    'pt/psiphon-tunnel-core.exe',
    'pt/lyrebird.exe',
    'tun2socks.exe',
    'tun2socks-legacy.exe',
    'hev-socks5-tunnel.exe',
    'msys-2.0.dll',
    'wintun.dll',
    'xray.exe',
    'geoip.dat',
    'geosite.dat',
  };

  /// Install-relative path in canonical form: forward slashes, no
  /// leading `./`, lowercase (Windows paths are case-insensitive).
  static String normalize(String path) {
    var s = path.replaceAll('\\', '/');
    while (s.startsWith('./')) {
      s = s.substring(2);
    }
    return s.toLowerCase();
  }

  static bool isCorePath(String path) => corePaths.contains(normalize(path));
}

/// The difference between the installed tree and an incoming zip,
/// split into core vs app changes. [coreOnly] is the gate: every
/// changed/added/removed path must be a core file.
class CoreDiff {
  const CoreDiff({
    this.changedCore = const [],
    this.changedApp = const [],
    this.addedCore = const [],
    this.removedCore = const [],
  });

  final List<String> changedCore;
  final List<String> changedApp;
  final List<String> addedCore;
  final List<String> removedCore;

  bool get coreOnly => changedApp.isEmpty;
  bool get isEmpty =>
      changedCore.isEmpty && addedCore.isEmpty && removedCore.isEmpty;
}

/// Pure classification: [installed] and [incoming] map normalized
/// relative paths to sha256 hex. Unit-testable anywhere.
CoreDiff classifyCoreDiff(
  Map<String, String> installed,
  Map<String, String> incoming,
) {
  final changedCore = <String>[];
  final changedApp = <String>[];
  final addedCore = <String>[];
  final removedCore = <String>[];
  for (final e in incoming.entries) {
    final old = installed[e.key];
    if (old == null) {
      if (CoreFileSet.isCorePath(e.key)) {
        addedCore.add(e.key);
      } else {
        changedApp.add(e.key);
      }
    } else if (old != e.value) {
      if (CoreFileSet.isCorePath(e.key)) {
        changedCore.add(e.key);
      } else {
        changedApp.add(e.key);
      }
    }
  }
  for (final path in installed.keys) {
    if (incoming.containsKey(path)) continue;
    if (CoreFileSet.isCorePath(path)) {
      removedCore.add(path);
    } else {
      changedApp.add(path);
    }
  }
  return CoreDiff(
    changedCore: changedCore,
    changedApp: changedApp,
    addedCore: addedCore,
    removedCore: removedCore,
  );
}

enum CoreUpdateOutcome { applied, notCoreOnly, failed }

class CoreUpdateResult {
  const CoreUpdateResult(this.outcome, {this.changed = const [], this.error});

  final CoreUpdateOutcome outcome;

  /// Core files replaced/added/removed (on [CoreUpdateOutcome.applied])
  /// or the app files that vetoed the update (on notCoreOnly).
  final List<String> changed;
  final String? error;
}

/// Applies a core-only update from the portable release zip.
/// Windows-only; every step is logged through [onLog] and every
/// failure leaves the install exactly as it was (`.bak` rollback).
class CoreUpdater {
  CoreUpdater({this.onLog});

  final void Function(String line)? onLog;

  void _log(String line) => onLog?.call(line);

  static String _hash(List<int> bytes) => sha256.convert(bytes).toString();

  /// Hashes every file under [dir] (normalized relative path → sha256).
  Future<Map<String, String>> _hashTree(Directory dir) async {
    final out = <String, String>{};
    if (!await dir.exists()) return out;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = CoreFileSet.normalize(p.relative(e.path, from: dir.path));
      // Our own update scratch files are never part of the install.
      if (rel.endsWith('.bak') || rel.endsWith('.new')) continue;
      out[rel] = _hash(await e.readAsBytes());
    }
    return out;
  }

  /// Verifies [zipFile] against the installed tree in [installDir] and,
  /// when the difference is core-only, replaces just those files.
  /// The caller must have verified the zip's own sha256 against the
  /// release digest first (UpdateService.download does), and must not
  /// call this while the tunnel is connected (core files are locked).
  Future<CoreUpdateResult> applyZip({
    required File zipFile,
    required String installDir,
  }) async {
    try {
      final archive =
          ZipDecoder().decodeBytes(await zipFile.readAsBytes());
      final incomingBytes = <String, List<int>>{};
      final incomingHashes = <String, String>{};
      for (final entry in archive.files) {
        if (!entry.isFile) continue;
        final rel = CoreFileSet.normalize(entry.name);
        // Zip-slip guard: nothing may land outside the install dir.
        if (rel.startsWith('../') || rel.contains('/../')) {
          return CoreUpdateResult(CoreUpdateOutcome.failed,
              error: 'unsafe path in update zip: ${entry.name}');
        }
        final bytes = entry.content as List<int>;
        incomingBytes[rel] = bytes;
        incomingHashes[rel] = _hash(bytes);
      }
      final installed = await _hashTree(Directory(installDir));
      final diff = classifyCoreDiff(installed, incomingHashes);
      if (!diff.coreOnly) {
        _log('core update refused: app files differ '
            '(${diff.changedApp.take(5).join(', ')}'
            '${diff.changedApp.length > 5 ? ', …' : ''})');
        return CoreUpdateResult(CoreUpdateOutcome.notCoreOnly,
            changed: diff.changedApp);
      }
      if (diff.isEmpty) {
        _log('core update: cores already match the release');
        return const CoreUpdateResult(CoreUpdateOutcome.applied);
      }

      final touched = <String>[];
      final backups = <String, String>{}; // target → .bak path
      Future<void> rollback() async {
        for (final e in backups.entries) {
          try {
            final target = File(e.key);
            if (await target.exists()) await target.delete();
            await File(e.value).rename(e.key);
          } catch (_) {}
        }
        for (final rel in touched) {
          try {
            await File(p.join(installDir, '$rel.new')).delete();
          } catch (_) {}
        }
      }

      try {
        for (final rel in [...diff.changedCore, ...diff.addedCore]) {
          final target = File(p.join(installDir, rel));
          await target.parent.create(recursive: true);
          final staged = File('${target.path}.new');
          await staged.writeAsBytes(incomingBytes[rel]!, flush: true);
          if (_hash(await staged.readAsBytes()) != incomingHashes[rel]) {
            throw FileSystemException('hash mismatch staging $rel');
          }
          if (await target.exists()) {
            final bak = '${target.path}.bak';
            await target.rename(bak);
            backups[target.path] = bak;
          }
          await staged.rename(target.path);
          touched.add(rel);
          _log('core update: replaced $rel');
        }
        for (final rel in diff.removedCore) {
          final target = File(p.join(installDir, rel));
          if (await target.exists()) {
            final bak = '${target.path}.bak';
            await target.rename(bak);
            backups[target.path] = bak;
            touched.add(rel);
            _log('core update: removed $rel');
          }
        }
      } catch (e) {
        await rollback();
        return CoreUpdateResult(CoreUpdateOutcome.failed, error: '$e');
      }
      for (final bak in backups.values) {
        try {
          await File(bak).delete();
        } catch (_) {}
      }
      _log('core update applied: ${touched.join(', ')}');
      return CoreUpdateResult(CoreUpdateOutcome.applied, changed: touched);
    } catch (e) {
      return CoreUpdateResult(CoreUpdateOutcome.failed, error: '$e');
    }
  }
}
