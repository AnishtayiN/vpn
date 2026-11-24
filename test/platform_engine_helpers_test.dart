import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/services/platform_engine.dart';

/// Tests for the pure/testable parts of platform_engine (finding 2).
///
/// No big refactor/split of the 1,811-line file was done in this release:
/// the engine's Windows-only paths (TUN bring-up, `route`/`netsh` calls,
/// core processes) still need a real Windows machine and are listed as
/// not-done. What *is* covered here is what was made testable with
/// minimal, safe extractions — the endpoint-IP extraction that feeds the
/// bypass set, and the default-route summary the gate logs — plus the
/// already-tested helpers the engine is built on (proxy strings in
/// windows_proxy_test.dart, firewall commands in
/// windows_killswitch_test.dart, route parsing in windows_tun_test.dart,
/// core stats in core_env_test.dart, egress verdicts in
/// egress_check_test.dart).
void main() {
  group('WindowsEngine.extractEndpointIp', () {
    test('pulls the peer IP out of a core log line', () {
      expect(
        WindowsEngine.extractEndpointIp(
            'peer 203.0.113.5:443 connected, identity ready'),
        '203.0.113.5',
      );
      expect(
        WindowsEngine.extractEndpointIp('gateway 192.168.1.1 found'),
        '192.168.1.1',
      );
      expect(
        WindowsEngine.extractEndpointIp('using endpoint 8.8.8.8:53'),
        '8.8.8.8',
      );
    });

    test('a line with no peer/endpoint/gateway keyword yields null', () {
      expect(
        WindowsEngine.extractEndpointIp('error: dial 1.2.3.4 failed'),
        isNull,
      );
      expect(
        WindowsEngine.extractEndpointIp('scan complete, no peers yet'),
        isNull,
      );
      expect(WindowsEngine.extractEndpointIp(''), isNull);
    });

    test('loopback, the tunnel range and 0.0.0.0 are never upstreams', () {
      expect(
        WindowsEngine.extractEndpointIp('connected to 127.0.0.1:1819'),
        isNull,
      );
      expect(
        WindowsEngine.extractEndpointIp('peer 198.18.0.5 connected'),
        isNull,
      );
      expect(
        WindowsEngine.extractEndpointIp('endpoint 0.0.0.0 selected'),
        isNull,
      );
    });
  });

  group('WindowsEngine.defaultRouteSnapshot', () {
    test('summarises the default routes in a route table', () {
      const table = '''
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0      198.18.0.1     198.18.0.1      6
          0.0.0.0          0.0.0.0      192.168.1.1     192.168.1.50     25
        192.168.1.0    255.255.255.0         On-link     192.168.1.50     266
''';
      expect(
        WindowsEngine.defaultRouteSnapshot(table),
        '198.18.0.1→198.18.0.1 (m6), 192.168.1.1→192.168.1.50 (m25)',
      );
    });

    test('an on-link tunnel default is reported, not hidden', () {
      const table = '''
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0         On-link         198.18.0.1       5
''';
      expect(
        WindowsEngine.defaultRouteSnapshot(table),
        'On-link→198.18.0.1 (m5)',
      );
    });

    test('a table with no default route says so plainly', () {
      const table = '''
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
        192.168.1.0    255.255.255.0         On-link     192.168.1.50     266
''';
      expect(
        WindowsEngine.defaultRouteSnapshot(table),
        'no default route at all',
      );
      expect(WindowsEngine.defaultRouteSnapshot(''), 'no default route at all');
    });
  });
}
