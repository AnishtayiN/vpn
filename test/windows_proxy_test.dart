import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/services/windows_proxy.dart';

void main() {
  group('parseRegQuery', () {
    test('parses an enabled manual proxy with an override list', () {
      const text = '''
HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings

    ProxyEnable    REG_DWORD    0x1
    ProxyServer    REG_SZ    127.0.0.1:1819
    ProxyOverride    REG_SZ    127.0.0.1;localhost;<local>
''';
      final s = WindowsSystemProxy.parseRegQuery(text);
      expect(s.enabled, isTrue);
      expect(s.server, '127.0.0.1:1819');
      expect(s.overrideList, '127.0.0.1;localhost;<local>');
    });

    test('accepts decimal DWORD values and multi-entry servers', () {
      const text = '''
HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings

    ProxyEnable    REG_DWORD    1
    ProxyServer    REG_SZ    http=10.0.0.1:8080;https=10.0.0.1:8080
''';
      final s = WindowsSystemProxy.parseRegQuery(text);
      expect(s.enabled, isTrue);
      expect(s.server, 'http=10.0.0.1:8080;https=10.0.0.1:8080');
      expect(s.overrideList, isNull);
    });

    test('keeps remembered values while the proxy is off', () {
      const text = '''
    ProxyEnable    REG_DWORD    0x0
    ProxyServer    REG_SZ    127.0.0.1:1819
''';
      final s = WindowsSystemProxy.parseRegQuery(text);
      expect(s.enabled, isFalse);
      expect(s.server, '127.0.0.1:1819');
    });

    test('missing key or junk output yields direct', () {
      final s = WindowsSystemProxy.parseRegQuery(
          'ERROR: The system was unable to find the specified registry key or value.');
      expect(s.enabled, isFalse);
      expect(s.server, isNull);
      expect(s.overrideList, isNull);
    });

    test('tolerates localized type names', () {
      const text = '''
    ProxyEnable    DWORD    0x1
    ProxyServer    String    10.1.1.1:3128
''';
      final s = WindowsSystemProxy.parseRegQuery(text);
      expect(s.enabled, isTrue);
      expect(s.server, '10.1.1.1:3128');
    });
  });

  group('loopback', () {
    test('points the system proxy at our own listener with loopback bypassed',
        () {
      final s = WindowsSystemProxy.loopback(1819);
      expect(s.enabled, isTrue);
      expect(s.server, '127.0.0.1:1819');
      expect(s.overrideList, '127.0.0.1;localhost;<local>');
    });

    test('follows the configured port', () {
      expect(WindowsSystemProxy.loopback(9999).server, '127.0.0.1:9999');
    });
  });

  group('pointsAt', () {
    test('matches a bare loopback entry', () {
      expect(WindowsSystemProxy.pointsAt('127.0.0.1:1819', 1819), isTrue);
    });

    test('matches inside a per-scheme list', () {
      expect(
        WindowsSystemProxy.pointsAt('socks=127.0.0.1:1819', 1819),
        isTrue,
      );
      expect(
        WindowsSystemProxy.pointsAt('http=10.0.0.1:8080;https=10.0.0.1:8080',
            1819),
        isFalse,
      );
    });

    test('never touches a foreign listener', () {
      expect(WindowsSystemProxy.pointsAt('127.0.0.1:7890', 1819), isFalse);
      expect(WindowsSystemProxy.pointsAt(null, 1819), isFalse);
      expect(WindowsSystemProxy.pointsAt('', 1819), isFalse);
    });
  });
}
