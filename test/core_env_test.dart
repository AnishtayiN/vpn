import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/models/settings.dart';
import 'package:voidrauvpn/services/core_args.dart';

Map<String, String> env(VpnSettings s, {bool windows = false}) =>
    CoreLaunch.environment(
      s,
      configPath: '/tmp/aether.toml',
      windowsMode: windows,
    );

void main() {
  test('the core is driven at the pinned version', () {
    expect(CoreLaunch.coreVersion, isNotEmpty);
    expect(RegExp(r'^\d+\.\d+\.\d+$').hasMatch(CoreLaunch.coreVersion), isTrue);
  });

  group('speed profile', () {
    test('eco asks for the low tier, auto lets the core decide', () {
      expect(env(VpnSettings(perf: PerfProfile.eco))['AETHER_PERF_PROFILE'],
          'low');
      expect(env(VpnSettings(perf: PerfProfile.auto))
          .containsKey('AETHER_PERF_PROFILE'), isFalse);
    });

    test('turbo and extreme force the high tier', () {
      expect(env(VpnSettings(perf: PerfProfile.turbo))['AETHER_PERF_PROFILE'],
          'high');
      expect(env(VpnSettings(perf: PerfProfile.extreme))['AETHER_PERF_PROFILE'],
          'high');
    });

    test('the TCP window grows with the tier, and only when asked', () {
      final auto = env(VpnSettings(perf: PerfProfile.auto));
      expect(auto.containsKey('AETHER_NETSTACK_TCP_RX'), isFalse);
      final turbo = env(VpnSettings(perf: PerfProfile.turbo));
      expect(turbo['AETHER_NETSTACK_TCP_RX'], '${2 * 1024 * 1024}');
      expect(turbo['AETHER_NETSTACK_TCP_TX'], '${512 * 1024}');
      final extreme = env(VpnSettings(perf: PerfProfile.extreme));
      expect(extreme['AETHER_NETSTACK_TCP_RX'], '${4 * 1024 * 1024}');
    });

    test('an explicit window wins over the profile', () {
      final e = env(VpnSettings(perf: PerfProfile.auto, perfRxKb: 3072));
      expect(e['AETHER_NETSTACK_TCP_RX'], '${3 * 1024 * 1024}');
    });

    test('timeouts ride along so a dead destination fails over', () {
      final e = env(VpnSettings(
        tcpConnectSecs: 10,
        tcpKeepaliveSecs: 45,
        halfCloseSecs: 15,
      ));
      expect(e['AETHER_TCP_CONNECT_SECS'], '10');
      expect(e['AETHER_TCP_KEEPALIVE_SECS'], '45');
      expect(e['AETHER_HALF_CLOSE_SECS'], '15');
    });
  });

  group('censorship workarounds', () {
    test('QUIC v2 is on by default and named only when turned off', () {
      expect(env(VpnSettings()).containsKey('AETHER_QUIC_V2'), isFalse);
      expect(env(VpnSettings(quicV2: false))['AETHER_QUIC_V2'], '0');
    });

    test('ECH is opt-in', () {
      expect(env(VpnSettings()).containsKey('AETHER_ECH'), isFalse);
      expect(env(VpnSettings(ech: true))['AETHER_ECH'], 'auto');
    });
  });

  group('exit lock', () {
    test('the default rule is a deny list, enforced by the core', () {
      final e = env(VpnSettings());
      expect(e['AETHER_EXIT_LOC'], '!IR');
      expect(e['AETHER_EXIT_LOC_SECS'], '${CoreLaunch.exitLocSecs}');
    });

    test('a preferred list becomes an allow list without the blocked ones', () {
      final e = env(VpnSettings(
        exitFilter: ExitFilter.preferred,
        exitPreferred: const ['DE', 'NL', 'IR'],
        exitBlocked: const ['IR'],
      ));
      expect(e['AETHER_EXIT_LOC'], 'DE,NL');
    });

    test('clearing the preferred list never lets a blocked exit in', () {
      final e = env(VpnSettings(
        exitFilter: ExitFilter.preferred,
        exitPreferred: const [],
        exitBlocked: const ['IR'],
      ));
      expect(e['AETHER_EXIT_LOC'], '!IR');
    });

    test('the switch takes the rule away from the core', () {
      final e = env(VpnSettings(coreExitLoc: false));
      expect(e.containsKey('AETHER_EXIT_LOC'), isFalse);
    });

    test('a paused rule is remembered but never sent to the core', () {
      // "Connect with the Iran IP" pauses the rule: the core must not be told
      // to refuse the exit the user just asked for, and the countries the user
      // chose stay in the settings for the one-tap resume.
      final e = env(VpnSettings(exitRulePaused: true));
      expect(e.containsKey('AETHER_EXIT_LOC'), isFalse);
    });

    test('with the filter off nothing is sent', () {
      final e = env(VpnSettings(exitFilter: ExitFilter.off));
      expect(e.containsKey('AETHER_EXIT_LOC'), isFalse);
    });
  });

  group('split tunneling by destination', () {
    test('rules travel as one comma-separated value each', () {
      final e = env(VpnSettings(
        routeDirect: const ['example.com', '10.0.0.0/8'],
        routeBlock: const ['ads.example', 'port:25'],
      ));
      expect(e['AETHER_ROUTE_DIRECT'], 'example.com,10.0.0.0/8');
      expect(e['AETHER_ROUTE_BLOCK'], 'ads.example,port:25');
    });

    test('empty rule lists are not sent at all', () {
      final e = env(VpnSettings());
      expect(e.containsKey('AETHER_ROUTE_DIRECT'), isFalse);
      expect(e.containsKey('AETHER_ROUTE_BLOCK'), isFalse);
    });

    test('Windows keeps only what a route can honour', () {
      final e = env(
        VpnSettings(routeDirect: const ['private', 'example.com', '1.2.3.4']),
        windows: true,
      );
      expect(e['AETHER_ROUTE_DIRECT'], 'private,1.2.3.4');
    });
  });

  group('second hop', () {
    test('psiphon carries the tunnel, with its own bind', () {
      final e = env(VpnSettings(
        chain: ChainMode.psiphon,
        psiphonRegion: 'de',
      ));
      expect(e['AETHER_PSIPHON'], 'chain');
      expect(e['AETHER_PSIPHON_REGION'], 'DE');
      expect(e['AETHER_PSIPHON_MODE'], 'direct');
      expect(e['AETHER_PSIPHON_BIND'], '127.0.0.1:1821');
      expect(e.containsKey('AETHER_TOR'), isFalse);
    });

    test('reverse and only map to the core tokens', () {
      expect(env(VpnSettings(chain: ChainMode.psiphonReverse))
          ['AETHER_PSIPHON'], 'reverse');
      expect(env(VpnSettings(chain: ChainMode.torOnly))['AETHER_TOR'], 'only');
    });

    test('tor gets its country and its own bind', () {
      final e = env(VpnSettings(chain: ChainMode.tor, torCountry: 'IR'));
      expect(e['AETHER_TOR'], 'chain');
      expect(e['AETHER_TOR_COUNTRY'], 'ir');
      expect(e['AETHER_TOR_BIND'], '127.0.0.1:1821');
      expect(e.containsKey('AETHER_PSIPHON'), isFalse);
    });

    test('the hop can open its own HTTP listener without collisions', () {
      final psiphon = env(VpnSettings(chain: ChainMode.psiphon, hopHttp: true));
      // SOCKS5 is 1819, the tunnel's HTTP listener 1820, the hop 1821 and the
      // hop's HTTP listener 1822.
      expect(psiphon['AETHER_PSIPHON_BIND'], '127.0.0.1:1821');
      expect(psiphon['AETHER_PSIPHON_HTTP'], '127.0.0.1:1822');
      final tor = env(VpnSettings(chain: ChainMode.tor, hopHttp: true));
      expect(tor['AETHER_TOR_BIND'], '127.0.0.1:1821');
      expect(tor['AETHER_TOR_HTTP'], '127.0.0.1:1822');
    });

    test('no chain means no chain env at all', () {
      final e = env(VpnSettings());
      expect(e.containsKey('AETHER_PSIPHON'), isFalse);
      expect(e.containsKey('AETHER_TOR'), isFalse);
    });
  });

  group('extras', () {
    test('stats are always on: they feed the live meter', () {
      final e = env(VpnSettings());
      expect(e['AETHER_STATS'], '1');
      expect(e['AETHER_STATS_SECS'], '5');
    });

    test('the HTTP listener sits one port above SOCKS5', () {
      final e = env(VpnSettings(httpProxy: true));
      expect(e['AETHER_HTTP_PROXY'], '127.0.0.1:1820');
      expect(env(VpnSettings()).containsKey('AETHER_HTTP_PROXY'), isFalse);
      final moved = env(VpnSettings(httpProxy: true, socksPort: 2000));
      expect(moved['AETHER_HTTP_PROXY'], '127.0.0.1:2001');
    });

    test('the inner MTU is only sent when the user overrode it', () {
      expect(env(VpnSettings(protocol: Protocol.masque))
          .containsKey('AETHER_MASQUE_MTU'), isFalse);
      expect(env(VpnSettings(protocol: Protocol.masque, coreMtu: 1400))
          ['AETHER_MASQUE_MTU'], '1400');
      // Out of range values are clamped to what the core accepts.
      expect(env(VpnSettings(protocol: Protocol.masque, coreMtu: 4000))
          ['AETHER_MASQUE_MTU'], '1500');
      // The device MTU is our own TUN setting, not the core's.
      expect(env(VpnSettings(protocol: Protocol.masque, tunMtu: 9000))
          .containsKey('AETHER_MASQUE_MTU'), isFalse);
    });
  });

  group('smart connect escalation', () {
    final ladder = CoreLaunch.smartLadder(VpnSettings());
    // The exit search numbers its rungs globally (`epoch * ladder.length + i`),
    // so the protocol for rung n is the ladder entry n wraps around to.
    VpnSettings variant(int i, {List<Protocol>? l, Protocol? proto}) {
      final rungs = l ?? ladder;
      return CoreLaunch.smartVariant(
        VpnSettings(),
        index: i,
        ladder: rungs,
        proto: proto ?? rungs[i % rungs.length],
      );
    }

    test('the first pass is left exactly as configured', () {
      final first = variant(0);
      expect(first.protocol, Protocol.masque);
      expect(first.transport, MasqueTransport.h3);
      expect(first.fragment, isFalse);
      expect(first.ech, isFalse);
    });

    test('the second pass takes the TCP carrier with a hidden ClientHello', () {
      final second = variant(1);
      // A carrier that drops QUIC usually matches on the TLS server name; the
      // HTTP/2 carrier plus a fragmented ClientHello and ECH is the answer.
      expect(second.transport, MasqueTransport.h2);
      expect(second.fragment, isTrue);
      expect(second.ech, isTrue);
    });

    test('later MASQUE passes keep ECH on', () {
      final later = variant(4);
      expect(later.protocol, Protocol.mim);
      expect(later.ech, isTrue);
    });

    test('a fixed protocol is never rewritten', () {
      final wg = CoreLaunch.smartVariant(
        VpnSettings(protocol: Protocol.wg),
        index: 1,
        ladder: const [Protocol.wg],
        proto: Protocol.wg,
      );
      expect(wg.protocol, Protocol.wg);
      expect(wg.ech, isFalse);
      expect(wg.fragment, isFalse);
    });

    test('the exit search flips the carrier once the ladder is walked', () {
      // The first rung of the second pass: a carrier the first pass never
      // opened, i.e. a different pool of gateways to land in.
      final second = variant(ladder.length);
      expect(second.transport, MasqueTransport.h2);
      expect(second.fragment, isTrue);
      // The rung after it is the scheduled hidden handshake again, on a rung
      // that is not MASQUE the carrier is left alone.
      final wireguard = variant(ladder.length + 2);
      expect(wireguard.protocol, Protocol.wg);
      expect(wireguard.transport, MasqueTransport.h3);
    });
  });

  group('stats parsing', () {
    test('the core\'s own line becomes byte counts', () {
      final stats = CoreStats.parse('[=] up 1.2 MiB down 8.0 MiB uptime 00:01:31');
      expect(stats, isNotNull);
      expect(stats!.upBytes, (1.2 * 1024 * 1024).round());
      expect(stats.downBytes, 8 * 1024 * 1024);
      expect(stats.uptime, const Duration(minutes: 1, seconds: 31));
    });

    test('any other log line is ignored', () {
      expect(CoreStats.parse('[+] routing rules loaded: 2 block, 1 direct'),
          isNull);
      expect(CoreStats.parse('up 1 MiB down 2 MiB'), isNull);
    });

    test('units are read the way the core prints them', () {
      expect(CoreStats.bytes('512 B'), 512);
      expect(CoreStats.bytes('832 KiB'), 832 * 1024);
      expect(CoreStats.bytes('1.5 GB'), 1610612736);
      expect(CoreStats.bytes('nonsense'), isNull);
    });
  });
}
