import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/models/settings.dart';
import 'package:voidrauvpn/services/core_args.dart';
import 'package:voidrauvpn/services/socks_probe.dart';

void main() {
  group('chain-hop topology', () {
    test('a chain hop carries the device traffic', () {
      final psiphon = VpnSettings(secondHop: SecondHop.psiphon);
      expect(psiphon.isChainHop, isTrue);
      expect(psiphon.isReverseHop, isFalse);
      expect(psiphon.hasPsiphonHop, isTrue);
      expect(psiphon.hopName, 'Psiphon');

      final tor = VpnSettings(secondHop: SecondHop.tor);
      expect(tor.isChainHop, isTrue);
      expect(tor.isReverseHop, isFalse);
      expect(tor.hasTorHop, isTrue);
      expect(tor.hopName, 'Tor');
    });

    test('a reverse hop is not a chain hop', () {
      final psiphon = VpnSettings(secondHop: SecondHop.psiphonReverse);
      expect(psiphon.isChainHop, isFalse);
      expect(psiphon.isReverseHop, isTrue);
      expect(psiphon.hasPsiphonHop, isTrue);

      final tor = VpnSettings(secondHop: SecondHop.torReverse);
      expect(tor.isChainHop, isFalse);
      expect(tor.isReverseHop, isTrue);
    });

    test('a standalone hop is neither chain nor reverse', () {
      final psiphon =
          VpnSettings(standaloneMode: StandaloneMode.psiphonOnly);
      expect(psiphon.isChainHop, isFalse);
      expect(psiphon.isReverseHop, isFalse);
      expect(psiphon.hasPsiphonHop, isTrue);
      expect(psiphon.hopName, 'Psiphon');

      final tor = VpnSettings(standaloneMode: StandaloneMode.torOnly);
      expect(tor.isChainHop, isFalse);
      expect(tor.isReverseHop, isFalse);
      expect(tor.hopName, 'Tor');
    });

    test('a standalone mode wins over a second hop', () {
      // A stored second hop under a standalone mode is ignored by the
      // core, so it must not count as chain or reverse either.
      final s = VpnSettings(
        standaloneMode: StandaloneMode.psiphonOnly,
        secondHop: SecondHop.psiphonReverse,
      );
      expect(s.isChainHop, isFalse);
      expect(s.isReverseHop, isFalse);
    });

    test('a plain tunnel has no hop at all', () {
      final s = VpnSettings();
      expect(s.isChainHop, isFalse);
      expect(s.isReverseHop, isFalse);
      expect(s.hasPsiphonHop, isFalse);
      expect(s.hasTorHop, isFalse);
      expect(s.hopName, '');
    });
  });

  group('device port', () {
    test('chain mode routes device traffic through the hop listener', () {
      expect(
        VpnSettings(secondHop: SecondHop.psiphon).devicePort,
        1821,
      );
      expect(
        VpnSettings(secondHop: SecondHop.tor).devicePort,
        1821,
      );
      // The hop port follows a custom SOCKS port.
      expect(
        VpnSettings(secondHop: SecondHop.psiphon, socksPort: 2000)
            .devicePort,
        2002,
      );
      // A SOCKS port near the top of the range falls back to 1821.
      expect(
        VpnSettings(secondHop: SecondHop.psiphon, socksPort: 65534)
            .devicePort,
        1821,
      );
    });

    test('every other mode keeps the tunnel listener', () {
      expect(VpnSettings().devicePort, 1819);
      expect(
        VpnSettings(secondHop: SecondHop.psiphonReverse).devicePort,
        1819,
      );
      expect(
        VpnSettings(secondHop: SecondHop.torReverse).devicePort,
        1819,
      );
      expect(
        VpnSettings(standaloneMode: StandaloneMode.psiphonOnly).devicePort,
        1819,
      );
      expect(
        VpnSettings(standaloneMode: StandaloneMode.torOnly).devicePort,
        1819,
      );
    });

    test('CoreLaunch agrees with settings on the topology', () {
      expect(
        CoreLaunch.isChainHop(VpnSettings(secondHop: SecondHop.psiphon)),
        isTrue,
      );
      expect(
        CoreLaunch.isChainHop(VpnSettings(secondHop: SecondHop.tor)),
        isTrue,
      );
      expect(
        CoreLaunch.isChainHop(
            VpnSettings(secondHop: SecondHop.psiphonReverse)),
        isFalse,
      );
      expect(
        CoreLaunch.isReverseHop(
            VpnSettings(secondHop: SecondHop.psiphonReverse)),
        isTrue,
      );
      expect(CoreLaunch.isChainHop(VpnSettings()), isFalse);
    });
  });

  group('exit lock in chain mode', () {
    Map<String, String> env(VpnSettings s) =>
        CoreLaunch.environment(s, configPath: '/tmp/aether.toml');

    test('the core gets no exit rule in chain mode', () {
      // The core's check reads the trace through the TUNNEL stack (the
      // WARP egress) while the device exit is the hop's: enforcing the
      // rule there would kill a tunnel whose hop exit is exactly what was
      // asked for. The client-side search enforces it instead.
      final psiphon = env(VpnSettings(
        secondHop: SecondHop.psiphon,
        exitFilter: ExitFilter.nonIran,
        exitBlocked: const ['IR'],
      ));
      expect(psiphon.containsKey('AETHER_EXIT_LOC'), isFalse);

      final tor = env(VpnSettings(
        secondHop: SecondHop.tor,
        torExitCountry: 'DE',
      ));
      expect(tor.containsKey('AETHER_EXIT_LOC'), isFalse);
    });

    test('the core still gets the rule in reverse mode', () {
      // Reverse: the exit IS the tunnel's, so the core check judges the
      // right egress.
      final psiphon = env(VpnSettings(
        secondHop: SecondHop.psiphonReverse,
        exitFilter: ExitFilter.nonIran,
        exitBlocked: const ['IR'],
      ));
      expect(psiphon['AETHER_EXIT_LOC'], '!IR');

      final tor = env(VpnSettings(
        secondHop: SecondHop.torReverse,
        torExitCountry: 'DE',
      ));
      expect(tor['AETHER_EXIT_LOC'], 'DE');
    });

    test('the hop env contract is unchanged', () {
      final e = env(VpnSettings(
        secondHop: SecondHop.psiphon,
        psiphonRegion: 'DE',
      ));
      expect(e['AETHER_PSIPHON'], 'chain');
      expect(e['AETHER_PSIPHON_BIND'], '127.0.0.1:1821');
      expect(e['AETHER_PSIPHON_REGION'], 'DE');
      final t = env(VpnSettings(secondHop: SecondHop.tor));
      expect(t['AETHER_TOR'], 'chain');
      expect(t['AETHER_TOR_BIND'], '127.0.0.1:1821');
    });
  });

  group('hop readiness handshake', () {
    test('a listener that answers the greeting is ready', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      server.listen((socket) {
        sockets.add(socket);
        socket.listen((data) {
          if (data.length >= 3 && data[0] == 5) socket.add([5, 0]);
        });
      });
      try {
        expect(
          await SocksProbe.handshake(
            port: server.port,
            timeout: const Duration(seconds: 2),
          ),
          isTrue,
        );
      } finally {
        for (final s in sockets) {
          s.destroy();
        }
        await server.close();
      }
    });

    test('a listener that accepts but never answers is not ready', () async {
      // The core holds the hop's listener from the start and only relays
      // to it once the hop is tunnelled: a bare TCP accept must not count
      // as readiness, or "connected" would be published on a hop that
      // serves nothing yet.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      server.listen((socket) {
        sockets.add(socket);
        // Hold the connection open; never send the greeting back.
      });
      try {
        expect(
          await SocksProbe.handshake(
            port: server.port,
            timeout: const Duration(milliseconds: 300),
          ),
          isFalse,
        );
      } finally {
        for (final s in sockets) {
          s.destroy();
        }
        await server.close();
      }
    });

    test('a refused connection is not ready', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      expect(
        await SocksProbe.handshake(
          port: port,
          timeout: const Duration(seconds: 2),
        ),
        isFalse,
      );
    });
  });
}
