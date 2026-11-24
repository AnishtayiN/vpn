import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/services/remote_config.dart';
import 'package:voidrauvpn/services/socks_probe.dart';

void main() {
  group('defaultEgressProbeUrls', () {
    test('HTTPS IP literals first, hostnames last', () {
      final urls = SocksProbe.defaultEgressProbeUrls;
      expect(urls, [
        'https://1.1.1.1/cdn-cgi/trace',
        'https://1.0.0.1/cdn-cgi/trace',
        'https://www.cloudflare.com/cdn-cgi/trace',
      ]);
      // HTTPS only: a plain-HTTP probe answer can be forged by an on-path
      // attacker (finding 9). Only the hostname target depends on DNS.
      expect(urls.every((u) => u.startsWith('https://')), isTrue);
      expect(
        urls.take(2).every((u) => u.contains('1.1.1.1') || u.contains('1.0.0.1')),
        isTrue,
      );
    });
  });

  group('traceExit', () {
    test('reads an IPv6 address out of a trace body', () {
      const body = 'fl=1\n'
          'h=[2606:4700:4700::1111]\n'
          'ip=2606:4700:4700::1111\n'
          'loc=US\n';
      final exit = SocksProbe.traceExit(body);
      expect(exit?.ip, '2606:4700:4700::1111');
      expect(exit?.country, 'US');
    });
  });

  group('EgressCheck family-aware comparison', () {
    test('a v6 device egress next to v4 references is unknown, not a leak',
        () {
      // A v6 address can never equal a v4 raw line, so comparing them
      // would either false-alarm (tunneled) or false-clear. Unknown is
      // the honest answer — the gate keeps the tunnel, unverified.
      final v = EgressCheck.evaluate(
        deviceIp: '2606:4700:4700::1111',
        tunnelIp: '203.0.113.7',
        rawIp: '198.51.100.9',
      );
      expect(v, EgressVerdict.unknown);
      expect(EgressCheck.ok(v), isFalse);
    });

    test('a v6 device egress equal to a v6 raw line is a leak', () {
      final v = EgressCheck.evaluate(
        deviceIp: '2606:4700:4700::1111',
        tunnelIp: '203.0.113.7',
        rawIp: '2606:4700:4700::1111',
      );
      expect(v, EgressVerdict.leaked);
    });

    test('a v6 device egress equal to a v6 tunnel exit is verified', () {
      final v = EgressCheck.evaluate(
        deviceIp: '2606:4700:4700::1111',
        tunnelIp: '2606:4700:4700::1111',
        rawIp: '198.51.100.9',
      );
      expect(v, EgressVerdict.verified);
      expect(EgressCheck.ok(v), isTrue);
    });

    test('probeFailed is never ok', () {
      expect(EgressCheck.ok(EgressVerdict.probeFailed), isFalse);
    });
  });

  group('DeviceEgressResult', () {
    test('an empty result carries no ip and the probe log', () {
      const r = DeviceEgressResult(
        attempts: ['https://1.1.1.1/cdn-cgi/trace → SocketException'],
      );
      expect(r.ip, isNull);
      expect(r.attempts, hasLength(1));
    });
  });

  group('GateConfig.fromJson', () {
    test('parses mode and probe URLs', () {
      final g = GateConfig.fromJson({
        'mode': 'warn',
        'probes': [
          'https://1.1.1.1/cdn-cgi/trace',
          'https://example.com/trace',
        ],
      });
      expect(g.mode, GateMode.warn);
      expect(g.probes, hasLength(2));
      expect(g.isDefault, isFalse);
    });

    test('an unknown mode falls back to enforce', () {
      expect(
        GateConfig.fromJson({'mode': 'strict'}).mode,
        GateMode.enforce,
      );
      expect(GateConfig.fromJson({}).mode, GateMode.enforce);
      expect(GateConfig.fromJson({}).isDefault, isTrue);
    });

    test('non-http(s), host-less and over-long probe URLs are dropped',
        () {
      final g = GateConfig.fromJson({
        'probes': [
          'ftp://1.1.1.1/trace',
          'https://',
          'https://1.1.1.1',
          'https://1.1.1.1/${'x' * 300}',
          42,
          'https://1.1.1.1/cdn-cgi/trace',
        ],
      });
      expect(g.probes, ['https://1.1.1.1/cdn-cgi/trace']);
    });

    test('the probe list is capped at 8', () {
      final g = GateConfig.fromJson({
        'probes': List.generate(
            12, (i) => 'https://1.1.1.$i/cdn-cgi/trace'),
      });
      expect(g.probes, hasLength(8));
    });
  });

  group('RemoteConfig gate', () {
    test('a gate key survives a round trip', () {
      final cfg = RemoteConfig.fromJson({
        'gate': {
          'mode': 'off',
          'probes': ['https://1.1.1.1/cdn-cgi/trace'],
        },
      });
      expect(cfg.gate.mode, GateMode.off);
      expect(cfg.gate.probes, ['https://1.1.1.1/cdn-cgi/trace']);
      expect(cfg.toJson()['gate'], {
        'mode': 'off',
        'probes': ['https://1.1.1.1/cdn-cgi/trace'],
      });
    });

    test('a bad gate value falls back to defaults without throwing', () {
      final cfg = RemoteConfig.fromJson({'gate': 'enforce'});
      expect(cfg.gate.isDefault, isTrue);
      expect(cfg.toJson(), isEmpty);
    });

    test('empty input still serializes to empty', () {
      expect(RemoteConfig.fromJson({}).toJson(), isEmpty);
    });
  });
}
