import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/models/settings.dart';
import 'package:voidrauvpn/services/split.dart';

void main() {
  group('rule parsing', () {
    test('bare IPv6 is spelled the way the core reads it', () {
      // The core splits an entry on its first ':', so a bare IPv6 prefix would
      // be read as an unknown rule name and dropped.
      expect(SplitRules.canonical('2001:db8::/32'), 'cidr:2001:db8::/32');
      expect(SplitRules.canonical('2001:db8::1'), 'ip:2001:db8::1');
      // Documented prefixes are left alone.
      expect(SplitRules.canonical('ip:2001:db8::1'), 'ip:2001:db8::1');
      expect(SplitRules.canonical('domain:example.com'), 'domain:example.com');
      expect(SplitRules.canonical('port:25'), 'port:25');
      expect(SplitRules.canonical('10.0.0.0/8'), '10.0.0.0/8');
    });

    test('entries that would break the env list are refused', () {
      expect(SplitRules.problem('a.example'), isNull);
      expect(SplitRules.problem('two,words'), 'comma');
      expect(SplitRules.problem('two words'), 'space');
      expect(SplitRules.problem(''), 'empty');
      expect(SplitRules.problem('port:'), 'empty-value');
      expect(SplitRules.problem('#comment'), 'comment');
    });

    test('normalize deduplicates and keeps the typed order', () {
      final out = SplitRules.normalize(
          [' b.example ', 'a.example', 'b.example', '', 'port:']);
      expect(out, ['b.example', 'a.example']);
    });

    test('a pasted blob is split on commas, semicolons and newlines', () {
      expect(SplitRules.parse('a.example, b.example;c.example\nd.example'),
          ['a.example', 'b.example', 'c.example', 'd.example']);
    });
  });

  group('IPv4 helpers', () {
    test('network and mask come out as route.exe wants them', () {
      expect(SplitRules.ipv4NetworkMask('10.0.0.0/8'),
          ['10.0.0.0', '255.0.0.0']);
      expect(SplitRules.ipv4NetworkMask('192.168.1.7/24'),
          ['192.168.1.0', '255.255.255.0']);
      expect(SplitRules.ipv4NetworkMask('1.2.3.4'),
          ['1.2.3.4', '255.255.255.255']);
      expect(SplitRules.ipv4NetworkMask('example.com'), isNull);
      expect(SplitRules.ipv4NetworkMask('10.0.0.0/33'), isNull);
      expect(SplitRules.ipv4NetworkMask('999.0.0.0/8'), isNull);
    });
  });

  group('platform reality', () {
    test('Android takes the whole list, Windows only what can be routed', () {
      final s = VpnSettings(
        routeDirect: const [
          'private',
          'example.com',
          '10.0.0.0/8',
          '1.2.3.4',
        ],
      );
      expect(SplitRules.coreDirectEntries(s, windows: false),
          ['private', 'example.com', '10.0.0.0/8', '1.2.3.4']);
      // A name rule cannot be honoured under a full-device tunnel: the core's
      // own socket would be captured and handed back to it.
      expect(SplitRules.coreDirectEntries(s, windows: true),
          ['private', '10.0.0.0/8', '1.2.3.4']);
    });

    test('only routable rules are promised on Windows', () {
      expect(SplitRules.windowsRoutable('private'), isTrue);
      expect(SplitRules.windowsRoutable('10.0.0.0/8'), isTrue);
      expect(SplitRules.windowsRoutable('1.2.3.4'), isTrue);
      expect(SplitRules.windowsRoutable('example.com'), isFalse);
      expect(SplitRules.windowsRoutable('full:example.com'), isFalse);
    });

    test('private expands to the three LAN ranges for the routing table', () {
      final s = VpnSettings(routeDirect: const ['private', '1.2.3.4']);
      final routes = SplitRules.windowsBypassRoutes(s);
      // `equals` is what makes this a comparison of *contents*: two lists are
      // different objects, and `contains` alone would compare identities.
      expect(routes, contains(equals(['10.0.0.0', '255.0.0.0'])));
      expect(routes, contains(equals(['172.16.0.0', '255.240.0.0'])));
      expect(routes, contains(equals(['192.168.0.0', '255.255.0.0'])));
      expect(routes, contains(equals(['1.2.3.4', '255.255.255.255'])));
      expect(routes.length, 4);
    });

    test('per-app is Android-only', () {
      expect(SplitRules.perAppSupported(android: true), isTrue);
      expect(SplitRules.perAppSupported(android: false), isFalse);
    });

    test('no rules at all is reported as inactive', () {
      expect(SplitRules.routingActive(VpnSettings()), isFalse);
      expect(SplitRules.routingActive(VpnSettings(routeBlock: const ['x.test'])),
          isTrue);
    });
  });

  group('app picker', () {
    final raw = [
      {'package': 'com.b', 'label': 'Beta', 'system': '0'},
      {'package': 'com.a', 'label': 'Alpha', 'system': '1'},
      {'package': 'com.a', 'label': 'Alpha (dup)', 'system': '1'},
      {'package': 'com.c'},
    ];

    test('the list is deduplicated, labelled and sorted', () {
      final apps = SplitRules.parseApps(raw);
      expect(apps.map((a) => a.id), ['com.a', 'com.b', 'com.c']);
      // A row without a label falls back to its package name.
      expect(apps.last.label, 'com.c');
      expect(apps.first.system, isTrue);
      expect(apps[1].system, isFalse);
    });

    test('search matches label or package, case-insensitively', () {
      final apps = SplitRules.parseApps(raw);
      expect(SplitRules.visibleApps(apps, query: 'alp').length, 1);
      expect(SplitRules.visibleApps(apps, query: 'COM.b').single.id, 'com.b');
    });

    test('system apps are hidden unless asked for — or already selected', () {
      final apps = SplitRules.parseApps(raw);
      expect(SplitRules.visibleApps(apps).length, 3);
      expect(SplitRules.visibleApps(apps, showSystem: false).length, 2);
      // A selected system app stays visible so it can still be removed.
      final kept = SplitRules.visibleApps(apps,
          showSystem: false, selected: {'com.a'});
      expect(kept.map((a) => a.id), contains('com.a'));
    });

    test('invert only touches what is visible', () {
      final apps = SplitRules.parseApps(raw);
      final visible = SplitRules.visibleApps(apps, showSystem: false);
      final out = SplitRules.invertSelection({'com.a', 'com.b'}, visible);
      expect(out.contains('com.a'), isTrue); // hidden row keeps its state
      expect(out.contains('com.b'), isFalse);
      expect(out.contains('com.c'), isTrue);
    });
  });

  group('dashboard summary', () {
    test('lists every half that is in play', () {
      final s = VpnSettings(
        splitMode: SplitMode.exclude,
        splitApps: const ['com.a', 'com.b'],
        routeBlock: const ['ads.example'],
      );
      final en = SplitRules.summary(s, fa: false, android: true);
      expect(en, contains('2 apps bypassed'));
      expect(en, contains('1 blocked'));
      // The per-app half is not promised where the platform cannot do it.
      final desktop = SplitRules.summary(s, fa: false, android: false);
      expect(desktop, isNot(contains('apps bypassed')));
    });
  });
}
