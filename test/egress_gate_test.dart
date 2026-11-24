import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/services/remote_config.dart';
import 'package:voidrauvpn/services/socks_probe.dart';

/// Tests for the egress gate (findings 4 + 5): the keep/teardown table
/// ([EgressGate.decide], extracted from the Windows engine's device-VPN
/// path so it is testable without a TUN adapter) and the probe
/// parallelisation ([SocksProbe.deviceExitDetailed] — HTTPS IP literals
/// first, under a ~20 s total budget, with no real network touched: the
/// probes below aim at loopback ports only).
void main() {
  group('EgressGate.decide', () {
    test('verified: device egress == tunnel exit keeps the tunnel', () {
      final d = EgressGate.decide(
        mode: GateMode.enforce,
        deviceIp: '203.0.113.7',
        tunnelIp: '203.0.113.7',
        rawIp: '198.51.100.9',
      );
      expect(d.outcome, EgressGateOutcome.verified);
      expect(d.verdict, EgressVerdict.verified);
      expect(d.keepTunnel, isTrue);
      expect(d.egressState, 'verified (EgressVerdict.verified)');
      expect(d.tunFail, isNull);
    });

    test('leaked + enforce tears the tunnel down', () {
      final d = EgressGate.decide(
        mode: GateMode.enforce,
        deviceIp: '198.51.100.9',
        tunnelIp: '203.0.113.7',
        rawIp: '198.51.100.9',
      );
      expect(d.outcome, EgressGateOutcome.teardownLeak);
      expect(d.verdict, EgressVerdict.leaked);
      expect(d.keepTunnel, isFalse);
      expect(d.tunFail, contains('198.51.100.9'));
      expect(d.tunFail, contains('raw line address'));
    });

    test('leaked + warn keeps the tunnel, unverified', () {
      final d = EgressGate.decide(
        mode: GateMode.warn,
        deviceIp: '198.51.100.9',
        tunnelIp: '203.0.113.7',
        rawIp: '198.51.100.9',
      );
      expect(d.outcome, EgressGateOutcome.warnLeak);
      expect(d.verdict, EgressVerdict.leaked);
      expect(d.keepTunnel, isTrue);
      expect(d.egressState, 'unverified: leak suspected (warn-only)');
      expect(d.tunFail, isNull);
    });

    test('probeFailed keeps the tunnel with an explicit unverified state',
        () {
      for (final deviceIp in [null, '', '   ']) {
        final d = EgressGate.decide(
          mode: GateMode.enforce,
          deviceIp: deviceIp,
          tunnelIp: '203.0.113.7',
          rawIp: '198.51.100.9',
        );
        expect(d.outcome, EgressGateOutcome.probeFailed, reason: '$deviceIp');
        expect(d.verdict, EgressVerdict.probeFailed);
        expect(d.keepTunnel, isTrue);
        expect(d.egressState, 'unverified: all egress probes failed');
      }
      // A measurement failure never tears the tunnel down, in any mode —
      // not even enforce.
      final warn = EgressGate.decide(mode: GateMode.warn, deviceIp: null);
      expect(warn.keepTunnel, isTrue);
    });

    test('gate off keeps the tunnel without measuring anything', () {
      final d = EgressGate.decide(
        mode: GateMode.off,
        deviceIp: '198.51.100.9',
        tunnelIp: '203.0.113.7',
        rawIp: '198.51.100.9',
      );
      expect(d.outcome, EgressGateOutcome.gateOff);
      expect(d.keepTunnel, isTrue);
      expect(d.egressState, 'unverified: gate off (remote config)');
    });

    test('inconclusive measurement keeps the tunnel, unverified', () {
      // A pooled exit that merely differs from the raw line (finding 4):
      // unknown, not "tunneled", not a leak — the tunnel stays up.
      final d = EgressGate.decide(
        mode: GateMode.enforce,
        deviceIp: '203.0.113.8',
        tunnelIp: '203.0.113.7',
        rawIp: '198.51.100.9',
      );
      expect(d.outcome, EgressGateOutcome.unverified);
      expect(d.verdict, EgressVerdict.unknown);
      expect(d.keepTunnel, isTrue);
      expect(d.egressState, contains('203.0.113.8'));
    });

    test('a v6 device egress next to v4 references is unverified, '
        'never a leak', () {
      final d = EgressGate.decide(
        mode: GateMode.enforce,
        deviceIp: '2606:4700:4700::1111',
        tunnelIp: '203.0.113.7',
        rawIp: '198.51.100.9',
      );
      expect(d.outcome, EgressGateOutcome.unverified);
      expect(d.keepTunnel, isTrue);
    });

    test('the leak test wins even when raw and tunnel agree', () {
      final d = EgressGate.decide(
        mode: GateMode.enforce,
        deviceIp: '198.51.100.9',
        tunnelIp: '198.51.100.9',
        rawIp: '198.51.100.9',
      );
      expect(d.outcome, EgressGateOutcome.teardownLeak);
    });
  });

  group('GateConfig HTTPS-only probes (finding 9)', () {
    test('plain-http probe URLs from remote config are dropped', () {
      final g = GateConfig.fromJson({
        'mode': 'enforce',
        'probes': [
          'http://1.1.1.1/cdn-cgi/trace',
          'https://1.1.1.1/cdn-cgi/trace',
        ],
      });
      expect(g.probes, ['https://1.1.1.1/cdn-cgi/trace']);
    });
  });

  group('SocksProbe.deviceExitDetailed (finding 5)', () {
    test('HTTPS IP literals are tried before hostnames, whatever the '
        'configured order', () async {
      // Both targets refuse instantly (closed loopback ports) — the only
      // thing under test is the order the attempts are logged in.
      final r = await SocksProbe.deviceExitDetailed(
        probeUrls: [
          'https://localhost:1/cdn-cgi/trace',
          'https://127.0.0.1:1/cdn-cgi/trace',
        ],
        timeout: const Duration(seconds: 2),
        attempts: 1,
      );
      expect(r.ip, isNull);
      // The IPv6 literal may also be present (inserted when the machine
      // has a global IPv6 address) — what matters is the relative order
      // of the two configured probes, not the exact count.
      final literalIdx = r.attempts.indexWhere(
          (a) => a.startsWith('https://127.0.0.1:1/'));
      final hostIdx = r.attempts
          .indexWhere((a) => a.startsWith('https://localhost:1/'));
      expect(literalIdx, greaterThanOrEqualTo(0));
      expect(hostIdx, greaterThanOrEqualTo(0));
      expect(literalIdx, lessThan(hostIdx));
    });

    test('a non-http(s) probe URL is skipped, never attempted', () async {
      final r = await SocksProbe.deviceExitDetailed(
        probeUrls: ['ftp://1.1.1.1/cdn-cgi/trace'],
        timeout: const Duration(seconds: 2),
        attempts: 1,
      );
      expect(r.ip, isNull);
      expect(
        r.attempts.any((a) =>
            a.startsWith('ftp://1.1.1.1/cdn-cgi/trace') &&
            a.contains('skipped (not an http(s) URL)')),
        isTrue,
      );
    });

    test('an unreachable literal returns quickly with no ip', () async {
      final sw = Stopwatch()..start();
      final r = await SocksProbe.deviceExitDetailed(
        probeUrls: ['https://127.0.0.1:1/cdn-cgi/trace'],
        timeout: const Duration(seconds: 2),
        attempts: 1,
      );
      expect(r.ip, isNull);
      // The IPv6 literal may also be attempted on a v6 machine; the
      // configured literal must be among the attempts either way.
      expect(
        r.attempts.any(
            (a) => a.startsWith('https://127.0.0.1:1/cdn-cgi/trace')),
        isTrue,
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('the total budget is bounded at ~20 s even when every probe '
        'hangs', () async {
      // Two loopback servers that accept TCP and then stay silent: the
      // TLS handshake never completes, so each probe hangs for its full
      // per-probe timeout. Sequential code would burn 2 attempts x
      // (8 s literal + 8 s hostname) = 32 s; the ~20 s deadline must cut
      // it short. No real network is touched.
      final literal = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final host = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = <Socket>[];
      for (final server in [literal, host]) {
        server.listen((s) => held.add(s));
      }
      try {
        final sw = Stopwatch()..start();
        final r = await SocksProbe.deviceExitDetailed(
          probeUrls: [
            'https://127.0.0.1:${literal.port}/cdn-cgi/trace',
            'https://localhost:${host.port}/cdn-cgi/trace',
          ],
          timeout: const Duration(seconds: 8),
          attempts: 2,
        );
        sw.stop();
        expect(r.ip, isNull);
        expect(r.attempts, isNotEmpty);
        expect(sw.elapsed, lessThan(const Duration(seconds: 26)),
            reason: 'budget is ~20 s; got ${sw.elapsed}');
        expect(sw.elapsed, greaterThan(const Duration(seconds: 15)),
            reason: 'the probes really did hang — a fast return would '
                'mean the timeout never engaged and the budget is untested');
      } finally {
        for (final s in held) {
          s.destroy();
        }
        await literal.close();
        await host.close();
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
