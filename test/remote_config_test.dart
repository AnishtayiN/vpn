import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/services/remote_config.dart';

void main() {
  group('RemoteConfig.fromJson', () {
    test('parses the full shape', () {
      final cfg = RemoteConfig.fromJson({
        'announcement': 'سلام',
        'announcementId': 'a1',
        'changelog': 'notes',
        'coreOnlyVersions': ['1.9.1', '1.9.2'],
        'flags': {'whatsNew': true, 'beta': false},
      });
      expect(cfg.announcement, 'سلام');
      expect(cfg.announcementId, 'a1');
      expect(cfg.changelog, 'notes');
      expect(cfg.coreOnlyVersions, ['1.9.1', '1.9.2']);
      expect(cfg.flag('whatsNew'), isTrue);
      expect(cfg.flag('beta', defaultValue: true), isFalse);
      expect(cfg.flag('missing', defaultValue: true), isTrue);
      expect(cfg.flag('missing'), isFalse);
    });

    test('wrong types are dropped, never thrown', () {
      final cfg = RemoteConfig.fromJson({
        'announcement': 42,
        'coreOnlyVersions': '1.9.1',
        'flags': {'ok': 'yes', 'also': true},
        'servers': ['evil.example'],
      });
      expect(cfg.announcement, isNull);
      expect(cfg.coreOnlyVersions, isEmpty);
      expect(cfg.flags, {'also': true});
    });

    test('version list keeps only x.y.z strings', () {
      final cfg = RemoteConfig.fromJson({
        'coreOnlyVersions': ['1.9.1', 'v1.9.2', 'latest', '2.0'],
      });
      expect(cfg.coreOnlyVersions, ['1.9.1']);
      expect(cfg.isCoreOnly('1.9.1'), isTrue);
      expect(cfg.isCoreOnly('1.9.2'), isFalse);
      expect(cfg.isCoreOnly(null), isFalse);
    });

    test('empty input is the empty config', () {
      final cfg = RemoteConfig.fromJson({});
      expect(cfg.announcement, isNull);
      expect(cfg.announcementKey, isNull);
      expect(cfg.toJson(), isEmpty);
    });
  });

  group('announcementKey', () {
    test('prefers the server id', () {
      final cfg = RemoteConfig.fromJson(
          {'announcement': 'x', 'announcementId': 'id-7'});
      expect(cfg.announcementKey, 'id-7');
    });

    test('falls back to a stable hash of the text', () {
      final a = RemoteConfig.fromJson({'announcement': 'hello'});
      final b = RemoteConfig.fromJson({'announcement': 'hello'});
      final c = RemoteConfig.fromJson({'announcement': 'hello2'});
      expect(a.announcementKey, b.announcementKey);
      expect(a.announcementKey, isNot(c.announcementKey));
      expect(a.announcementKey!.length, 16);
    });
  });

  test('toJson round-trips through fromJson', () {
    final cfg = RemoteConfig.fromJson({
      'announcement': 'hi',
      'coreOnlyVersions': ['1.9.1'],
      'flags': {'a': true},
    });
    final again = RemoteConfig.fromJson(cfg.toJson());
    expect(again.announcement, 'hi');
    expect(again.coreOnlyVersions, ['1.9.1']);
    expect(again.flags, {'a': true});
  });
}
