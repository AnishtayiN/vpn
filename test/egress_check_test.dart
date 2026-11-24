import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/services/socks_probe.dart';

void main() {
  group('EgressCheck', () {
    test('device egress == tunnel exit is verified', () {
      final v = EgressCheck.evaluate(
        deviceIp: '203.0.113.7',
        tunnelIp: '203.0.113.7',
        rawIp: '198.51.100.9',
      );
      expect(v, EgressVerdict.verified);
      expect(EgressCheck.ok(v), isTrue);
    });

    test('device egress == raw line address is a leak', () {
      final v = EgressCheck.evaluate(
        deviceIp: '198.51.100.9',
        tunnelIp: '203.0.113.7',
        rawIp: '198.51.100.9',
      );
      expect(v, EgressVerdict.leaked);
      expect(EgressCheck.ok(v), isFalse);
    });

    test('the leak test wins when raw and tunnel agree', () {
      // A "tunnel" exiting via the user's own address is not a tunnel.
      final v = EgressCheck.evaluate(
        deviceIp: '198.51.100.9',
        tunnelIp: '198.51.100.9',
        rawIp: '198.51.100.9',
      );
      expect(v, EgressVerdict.leaked);
    });

    test('a pooled exit differing from the probe is unknown, not a leak',
        () {
      // Tor circuits / anycast pools hand out more than one address, but
      // the raw address was measured once, before capture — an ISP/CGNAT
      // reassignment reads exactly the same way. So a device egress that
      // merely differs from the raw line proves nothing: only an exact
      // match with the tunnel exit counts as tunneled. Unknown keeps the
      // tunnel up, unverified (finding 4).
      final v = EgressCheck.evaluate(
        deviceIp: '203.0.113.8',
        tunnelIp: '203.0.113.7',
        rawIp: '198.51.100.9',
      );
      expect(v, EgressVerdict.unknown);
      expect(EgressCheck.ok(v), isFalse);
    });

    test('without a raw reference only an exact tunnel match proves capture',
        () {
      expect(
        EgressCheck.evaluate(
          deviceIp: '203.0.113.7',
          tunnelIp: '203.0.113.7',
        ),
        EgressVerdict.verified,
      );
      final v = EgressCheck.evaluate(
        deviceIp: '203.0.113.8',
        tunnelIp: '203.0.113.7',
      );
      expect(v, EgressVerdict.unknown);
      expect(EgressCheck.ok(v), isFalse);
    });

    test('no tunnel reference and no raw reference is unknown', () {
      expect(
        EgressCheck.evaluate(deviceIp: '203.0.113.7'),
        EgressVerdict.unknown,
      );
    });

    test('an empty device egress is unknown, never ok', () {
      final v = EgressCheck.evaluate(
        deviceIp: '',
        tunnelIp: '203.0.113.7',
        rawIp: '198.51.100.9',
      );
      expect(v, EgressVerdict.unknown);
      expect(EgressCheck.ok(v), isFalse);
    });

    test('blank references count as missing', () {
      expect(
        EgressCheck.evaluate(
          deviceIp: '203.0.113.7',
          tunnelIp: '  ',
          rawIp: '',
        ),
        EgressVerdict.unknown,
      );
    });
  });

  group('traceExit', () {
    test('reads ip and loc out of a Cloudflare trace body', () {
      const body = 'fl=1\n'
          'h=www.cloudflare.com\n'
          'ip=203.0.113.7\n'
          'ts=1\n'
          'loc=DE\n'
          'warp=on\n';
      final exit = SocksProbe.traceExit(body);
      expect(exit?.ip, '203.0.113.7');
      expect(exit?.country, 'DE');
    });

    test('a body without an address yields null', () {
      expect(SocksProbe.traceExit('loc=DE\nwarp=on\n'), isNull);
      expect(SocksProbe.traceExit(''), isNull);
    });
  });
}
