import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voidrauvpn/services/core_update.dart';

void main() {
  group('CoreUpdateManifest.tryParse', () {
    test('parses a core-only manifest', () {
      final m = CoreUpdateManifest.tryParse('''
{"version":"1.9.1","coreOnly":true,"files":[
  {"path":"aether.exe","sha256":"ABC","source":"portable-zip"},
  {"path":"pt\\\\lyrebird.exe"}
]}''');
      expect(m, isNotNull);
      expect(m!.version, '1.9.1');
      expect(m.isCoreOnlyFor('1.9.1'), isTrue);
      expect(m.isCoreOnlyFor('1.9.2'), isFalse);
      expect(m.files.length, 2);
      expect(m.files[0].sha256, 'abc');
      expect(m.files[1].path, 'pt/lyrebird.exe');
    });

    test('rejects garbage and non-versions', () {
      expect(CoreUpdateManifest.tryParse('not json'), isNull);
      expect(CoreUpdateManifest.tryParse('{"version":"latest"}'), isNull);
      expect(CoreUpdateManifest.tryParse('[1,2]'), isNull);
    });

    test('coreOnly defaults to false', () {
      final m = CoreUpdateManifest.tryParse('{"version":"1.9.1"}');
      expect(m!.coreOnly, isFalse);
      expect(m.isCoreOnlyFor('1.9.1'), isFalse);
    });
  });

  group('CoreFileSet', () {
    test('normalizes separators and case', () {
      expect(CoreFileSet.normalize(r'PT\Lyrebird.EXE'), 'pt/lyrebird.exe');
      expect(CoreFileSet.normalize('./aether.exe'), 'aether.exe');
    });

    test('knows core paths, rejects app paths', () {
      expect(CoreFileSet.isCorePath('aether.exe'), isTrue);
      expect(CoreFileSet.isCorePath(r'pt\psiphon-tunnel-core.exe'), isTrue);
      expect(CoreFileSet.isCorePath('voidrauvpn.exe'), isFalse);
      expect(CoreFileSet.isCorePath('data/app.so'), isFalse);
      expect(CoreFileSet.isCorePath('flutter_windows.dll'), isFalse);
    });
  });

  group('classifyCoreDiff', () {
    test('core-only when only core files change', () {
      final diff = classifyCoreDiff(
        {'aether.exe': 'a1', 'voidrauvpn.exe': 'v1', 'xray.exe': 'x1'},
        {'aether.exe': 'a2', 'voidrauvpn.exe': 'v1', 'xray.exe': 'x1'},
      );
      expect(diff.coreOnly, isTrue);
      expect(diff.changedCore, ['aether.exe']);
    });

    test('an app change vetoes core-only', () {
      final diff = classifyCoreDiff(
        {'aether.exe': 'a1', 'voidrauvpn.exe': 'v1'},
        {'aether.exe': 'a2', 'voidrauvpn.exe': 'v2'},
      );
      expect(diff.coreOnly, isFalse);
      expect(diff.changedApp, ['voidrauvpn.exe']);
    });

    test('added/removed core files are fine, added app files are not', () {
      final diff = classifyCoreDiff(
        {'aether.exe': 'a1', 'tun2socks.exe': 't1'},
        {'aether.exe': 'a1', 'geoip.dat': 'g1'},
      );
      expect(diff.coreOnly, isTrue);
      expect(diff.addedCore, ['geoip.dat']);
      expect(diff.removedCore, ['tun2socks.exe']);

      final diff2 = classifyCoreDiff(
        {'aether.exe': 'a1'},
        {'aether.exe': 'a1', 'newfile.dll': 'n1'},
      );
      expect(diff2.coreOnly, isFalse);
    });

    test('identical trees are an empty diff', () {
      final diff = classifyCoreDiff({'aether.exe': 'a'}, {'aether.exe': 'a'});
      expect(diff.isEmpty, isTrue);
      expect(diff.coreOnly, isTrue);
    });
  });

  group('CoreUpdater.applyZip', () {
    late Directory tmp;
    late Directory install;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('core_update_test');
      install = Directory(p.join(tmp.path, 'install'));
      await install.create(recursive: true);
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    Future<File> writeZip(Map<String, String> files) async {
      final archive = Archive();
      for (final e in files.entries) {
        final bytes = e.value.codeUnits;
        archive.addFile(ArchiveFile(e.key, bytes.length, bytes));
      }
      final zip = File(p.join(tmp.path, 'update.zip'));
      await zip.writeAsBytes(ZipEncoder().encode(archive));
      return zip;
    }

    Future<void> writeInstall(Map<String, String> files) async {
      for (final e in files.entries) {
        final f = File(p.join(install.path, e.key));
        await f.parent.create(recursive: true);
        await f.writeAsString(e.value);
      }
    }

    test('replaces only the changed core file, leaves the app alone',
        () async {
      await writeInstall({
        'aether.exe': 'old-core',
        'voidrauvpn.exe': 'app-v1',
        'pt/lyrebird.exe': 'bird',
      });
      final zip = await writeZip({
        'aether.exe': 'new-core',
        'voidrauvpn.exe': 'app-v1',
        'pt/lyrebird.exe': 'bird',
      });
      final result = await CoreUpdater()
          .applyZip(zipFile: zip, installDir: install.path);
      expect(result.outcome, CoreUpdateOutcome.applied);
      expect(result.changed, ['aether.exe']);
      expect(await File(p.join(install.path, 'aether.exe')).readAsString(),
          'new-core');
      expect(
          await File(p.join(install.path, 'voidrauvpn.exe')).readAsString(),
          'app-v1');
      // No scratch files left behind.
      final leftovers = await install
          .list(recursive: true)
          .where((e) => e.path.endsWith('.bak') || e.path.endsWith('.new'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('refuses when an app file differs and touches nothing', () async {
      await writeInstall({
        'aether.exe': 'old-core',
        'voidrauvpn.exe': 'app-v1',
      });
      final zip = await writeZip({
        'aether.exe': 'new-core',
        'voidrauvpn.exe': 'app-v2',
      });
      final result = await CoreUpdater()
          .applyZip(zipFile: zip, installDir: install.path);
      expect(result.outcome, CoreUpdateOutcome.notCoreOnly);
      expect(result.changed, ['voidrauvpn.exe']);
      expect(await File(p.join(install.path, 'aether.exe')).readAsString(),
          'old-core');
    });

    test('adds a new core file and removes a dropped one', () async {
      await writeInstall({
        'aether.exe': 'core',
        'tun2socks.exe': 'old-bridge',
      });
      final zip = await writeZip({
        'aether.exe': 'core',
        'xray.exe': 'xray-core',
      });
      final result = await CoreUpdater()
          .applyZip(zipFile: zip, installDir: install.path);
      expect(result.outcome, CoreUpdateOutcome.applied);
      expect(await File(p.join(install.path, 'xray.exe')).exists(), isTrue);
      expect(await File(p.join(install.path, 'tun2socks.exe')).exists(),
          isFalse);
    });
  });
}
