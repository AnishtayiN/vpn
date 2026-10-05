import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/services/windows_tun.dart';

/// Real `netsh interface ipv4 show interfaces` output: a localized-free header,
/// a padded separator line, names with spaces, a multi-word state, and the
/// "Voidrau 2" rename Windows hands out when a stale adapter is still around.
const _netshInterfaces = '''
   Idx     Met         MTU          State                Name
---  ----------  ----------  ------------  ---------------------------
  1         75  4294967295  connected     Loopback Pseudo-Interface 1
 12         25        1500  connected     Ethernet
 19          5        1400  hardware not present  Bluetooth Network Connection
 23         15        1400  connected     Voidrau 2
''';

const _whoamiElevated = '''
GROUP INFORMATION
-----------------
BUILTIN\\Administrators                                    Alias            S-1-5-32-544        Mandatory group, Enabled
Mandatory Label\\High Mandatory Level                      Label            S-1-16-12288
''';

const _whoamiStandard = '''
GROUP INFORMATION
-----------------
BUILTIN\\Administrators                                    Alias            S-1-5-32-544        Group used for deny only
Mandatory Label\\Medium Mandatory Level                    Label            S-1-16-8192
''';

const _routePrintTunFirst = '''
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0      198.18.0.1     198.18.0.1      6
          0.0.0.0          0.0.0.0      192.168.1.1     192.168.1.50     25
===========================================================================
''';

const _routePrintRealOnly = '''
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0      192.168.1.1     192.168.1.50     25
===========================================================================
''';

/// A full `route print` the way Windows 8.1 prints it after the tunnel is up:
/// interface list, `===` separators, the IPv4 table and an IPv6 table with a
/// different column order. The default route through the tunnel is stored as
/// an **on-link** route (gateway = the adapter's own address), so its Gateway
/// column is the word "On-link" — not an IP.
const _routePrintFullOnLink = '''
===========================================================================
Interface List
  12...1a-2b-3c-4d-5e-6f ..................................Ethernet
  42...aa-bb-cc-dd-ee-ff ..................................Voidrau
  ...........................
===========================================================================
IPv4 Route Table
===========================================================================
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0         On-link         198.18.0.1       5
          0.0.0.0          0.0.0.0       192.168.1.1     192.168.1.50      25
        127.0.0.0        255.0.0.0         On-link         127.0.0.1     331
        127.0.0.1  255.255.255.255         On-link         127.0.0.1     331
      192.168.1.0    255.255.255.0         On-link     192.168.1.50     266
    192.168.1.50  255.255.255.255         On-link     192.168.1.50     266
    198.18.0.0    255.255.255.252         On-link         198.18.0.1     281
  255.255.255.255  255.255.255.255         On-link         198.18.0.1     281
===========================================================================
Persistent Routes:
  None
IPv6 Route Table
===========================================================================
Active Routes:
 If Metric Network Destination         Gateway
 -- ----- -------------------------  --------------------------
  1  331                          ::1  on-link
 12    25            fe80::1a2b:3c4d:5e6f::/64  on-link
 42    25                       fe80::aabb:ccdd:eeff::/64  on-link
 42    25                              ff00::/8  on-link
  1  331                         *  *
===========================================================================
''';

/// Same table on a Persian-language Windows: the section header and the
/// on-link word are localized, everything else (numbers, IPs) is not.
const _routePrintPersianOnLink = '''
مسیرهای فعال:
وجه مقصد شبکه        ماسک شبکه          دروازه        رابط  متریک
          0.0.0.0          0.0.0.0       روی پیوند        198.18.0.1       5
          0.0.0.0          0.0.0.0      192.168.1.1     192.168.1.50      25
===========================================================================
''';

/// The only default route is the tunnel's, stored on-link — exactly the
/// moment between `route add` succeeding and the verification running.
const _routePrintTunnelOnLinkOnly = '''
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0         On-link         198.18.0.1       5
===========================================================================
''';

void main() {
  group('netsh interface parsing', () {
    test('reads index, state and names that contain spaces', () {
      final rows = Netsh.parseInterfaces(_netshInterfaces);
      expect(rows.length, 4);
      expect(rows[0].index, 1);
      expect(rows[0].name, 'Loopback Pseudo-Interface 1');
      // A state with spaces must not swallow the first word of the name.
      expect(rows[2].state, 'hardware not present');
      expect(rows[2].name, 'Bluetooth Network Connection');
    });

    test('finds the adapter Windows renamed to "Voidrau 2"', () {
      final rows = Netsh.parseInterfaces(_netshInterfaces);
      final adapter = Netsh.findAdapter(rows, 'Voidrau');
      expect(adapter, isNotNull);
      expect(adapter!.name, 'Voidrau 2');
      expect(adapter.index, 23);
    });

    test('prefers an exact name over a numbered twin', () {
      final rows = Netsh.parseInterfaces('''
   Idx     Met         MTU          State                Name
---  ----------  ----------  ------------  ---------------------------
 31         15        1400  connected     Voidrau
 23         15        1400  connected     Voidrau 2
''');
      expect(Netsh.findAdapter(rows, 'Voidrau')!.index, 31);
    });

    test('reports a missing adapter as missing', () {
      final rows = Netsh.parseInterfaces(_netshInterfaces);
      expect(Netsh.findAdapter(rows, 'WireGuard'), isNull);
      expect(Netsh.findAdapter(const [], 'Voidrau'), isNull);
    });

    test('ignores the header and separator lines', () {
      final rows = Netsh.parseInterfaces('''
   Idx     Met         MTU          State                Name
---  ----------  ----------  ------------  ---------------------------
''');
      expect(rows, isEmpty);
    });
  });

  group('route table parsing', () {
    test('sees a default route through the tunnel', () {
      expect(Netsh.hasDefaultRoute(_routePrintTunFirst, '198.18.0.1'), isTrue);
      expect(Netsh.hasDefaultRoute(_routePrintRealOnly, '198.18.0.1'), isFalse);
    });

    test('sees an on-link default route via the interface column', () {
      const onLink = '''
          0.0.0.0          0.0.0.0         0.0.0.0     198.18.0.1     25
''';
      expect(Netsh.hasDefaultRoute(onLink, '198.18.0.1'), isTrue);
    });

    test('sees an on-link default route the way Windows 8.1 prints it', () {
      // The Gateway column holds the localized word "On-link", not an IP.
      // The old check (regex demanding an IP there) reported this table as
      // "no route" and turned a working tunnel into "device VPN unavailable".
      expect(Netsh.hasDefaultRoute(_routePrintFullOnLink, '198.18.0.1'),
          isTrue);
      expect(Netsh.hasDefaultRoute(_routePrintPersianOnLink, '198.18.0.1'),
          isTrue);
      expect(Netsh.hasDefaultRoute(_routePrintTunnelOnLinkOnly, '198.18.0.1'),
          isTrue);
      // And it still says "no" when only the physical default route exists.
      expect(
          Netsh.hasDefaultRoute(_routePrintFullOnLink.replaceAll(
              RegExp(r'0\.0\.0\.0\s+0\.0\.0\.0\s+On-link\s+198\.18\.0\.1\s+5'),
              ''), '198.18.0.1'),
          isFalse);
    });

    test('parseRouteLines keeps only IPv4 route rows', () {
      final rows = Netsh.parseRouteLines(_routePrintFullOnLink);
      // 8 IPv4 active rows: 2 defaults + 6 host/subnet routes.
      expect(rows.length, 8);
      // Interface list, separators, headers, "None" and the whole IPv6
      // table (different column order) are all skipped.
      expect(rows.every((r) => RouteLine.ipPattern.hasMatch(r.interfaceAddress)),
          isTrue);
      final tunnel =
          rows.firstWhere((r) => r.interfaceAddress == '198.18.0.1');
      expect(tunnel.destination, '0.0.0.0');
      expect(tunnel.mask, '0.0.0.0');
      expect(tunnel.gateway, 'On-link');
      expect(tunnel.isOnLink, isTrue);
      expect(tunnel.metric, 5);
    });

    test('parseRouteLines survives a localized on-link word with a space',
        () {
      final rows = Netsh.parseRouteLines(_routePrintPersianOnLink);
      expect(rows.length, 2);
      expect(rows[0].gateway, 'روی پیوند');
      expect(rows[0].isOnLink, isTrue);
      expect(rows[0].interfaceAddress, '198.18.0.1');
    });

    test('never treats an on-link default as a usable upstream gateway', () {
      // On-link rows carry no next hop: a machine whose only default route
      // is the tunnel's (or a broken on-link one) has no upstream to bypass
      // through, so parseGateway must come back empty rather than looping.
      expect(Netsh.parseGateway(_routePrintTunnelOnLinkOnly, ignore: '198.18.0.1'),
          isNull);
      // With both defaults present the on-link one is skipped and the real
      // gateway wins.
      expect(Netsh.parseGateway(_routePrintFullOnLink, ignore: '198.18.0.1'),
          '192.168.1.1');
      expect(Netsh.parseGateway(_routePrintPersianOnLink, ignore: '198.18.0.1'),
          '192.168.1.1');
    });

    test('never captures the tunnel address as the real gateway', () {
      // A crashed run leaves our own route in the table; taking 198.18.0.1 as
      // "the upstream gateway" would build a routing loop on reconnect.
      expect(
        Netsh.parseGateway(_routePrintTunFirst, ignore: '198.18.0.1'),
        '192.168.1.1',
      );
      expect(Netsh.parseGateway(_routePrintRealOnly), '192.168.1.1');
      const onlyTunnel = '''
          0.0.0.0          0.0.0.0      198.18.0.1     198.18.0.1      6
''';
      expect(Netsh.parseGateway(onlyTunnel, ignore: '198.18.0.1'), isNull);
    });
  });

  group('elevation', () {
    test('high integrity means elevated', () {
      expect(Elevation.parseWhoamiGroups(_whoamiElevated), isTrue);
    });

    test('medium integrity means not elevated, even for an admin account', () {
      expect(Elevation.parseWhoamiGroups(_whoamiStandard), isFalse);
    });

    test('a service running as SYSTEM counts as elevated', () {
      expect(
        Elevation.parseWhoamiGroups('Mandatory Label\\System Mandatory Level  S-1-16-16384'),
        isTrue,
      );
    });

    test('the check is language independent (SIDs, not labels)', () {
      expect(Elevation.parseWhoamiGroups('برچسب اجباری  S-1-16-12288'), isTrue);
    });
  });

  group('Windows build detection', () {
    test('reads CurrentBuild from reg query', () {
      expect(
        WindowsBuild.parseRegQuery('''

HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion
    CurrentBuild    REG_SZ    9600
    CurrentType    REG_SZ    Multiprocess Free
'''),
        9600,
      );
    });

    test('falls back to CurrentBuildNumber', () {
      expect(
        WindowsBuild.parseRegQuery('    CurrentBuildNumber    REG_SZ    19045'),
        19045,
      );
      expect(WindowsBuild.parseRegQuery('nothing here'), 0);
    });

    test('reads cmd /c ver on old and new Windows', () {
      expect(
        WindowsBuild.parseVer('Microsoft Windows [Version 6.3.9600]'),
        9600,
      );
      expect(
        WindowsBuild.parseVer('Microsoft Windows [Version 10.0.22631.3007]'),
        22631,
      );
    });

    test('labels and the Go runtime floor', () {
      expect(const WindowsBuild(9600).label, contains('8.1'));
      expect(const WindowsBuild(22631).label, contains('11'));
      expect(const WindowsBuild(10240).label, contains('10'));
      // Go >= 1.21 requires Windows 10+: current tun2socks cannot run on 8.1.
      expect(const WindowsBuild(9600).supportsGoRuntime, isFalse);
      expect(const WindowsBuild(10240).supportsGoRuntime, isTrue);
      expect(WindowsBuild.unknown.isKnown, isFalse);
      expect(WindowsBuild.unknown.label, 'unknown Windows');
    });
  });

  group('bridge order', () {
    test('Windows 8.1 tries the Go 1.20 build first', () {
      final plan = TunPlan.order(
        build: const WindowsBuild(9600),
        available: TunBackend.values,
      );
      expect(plan.first, TunBackend.tun2socksLegacy);
      // The Windows 10+ Go build is a last resort, not a 20 s dead end.
      expect(plan.last, TunBackend.tun2socks);
      expect(plan, contains(TunBackend.hev));
    });

    test('Windows 11 tries the current build first', () {
      final plan = TunPlan.order(
        build: const WindowsBuild(22631),
        available: TunBackend.values,
      );
      expect(plan.first, TunBackend.tun2socks);
      expect(plan.length, 3);
    });

    test('an unknown Windows version still gets a full plan', () {
      final plan = TunPlan.order(
        build: WindowsBuild.unknown,
        available: TunBackend.values,
      );
      expect(plan.length, 3);
      expect(plan.first, TunBackend.tun2socks);
    });

    test('only installed bridges are planned', () {
      final plan = TunPlan.order(
        build: const WindowsBuild(9600),
        available: const [TunBackend.hev],
      );
      expect(plan, [TunBackend.hev]);
    });

    test('every bridge names the file it is staged as', () {
      expect(TunBackend.tun2socks.fileName, 'tun2socks.exe');
      expect(TunBackend.tun2socksLegacy.fileName, 'tun2socks-legacy.exe');
      expect(TunBackend.hev.fileName, 'hev-socks5-tunnel.exe');
    });
  });

  group('hev config', () {
    test('carries adapter name, MTU and the SOCKS5 listener', () {
      final yaml = HevConfig.yaml(
        adapterName: 'Voidrau',
        mtu: 1400,
        socksPort: 1819,
      );
      expect(yaml, contains("name: 'Voidrau'"));
      expect(yaml, contains('mtu: 1400'));
      expect(yaml, contains('port: 1819'));
      expect(yaml, contains("address: '127.0.0.1'"));
      expect(yaml, contains("udp: 'udp'"));
    });

    test('leaves the address to Voidrau so both bridges are configured alike',
        () {
      // hev would stamp a /32 on the adapter and fight the /30 the routing
      // code installs; the config must not contain tunnel.ipv4.
      final yaml = HevConfig.yaml(
        adapterName: 'Voidrau',
        mtu: 1400,
        socksPort: 1819,
      );
      expect(yaml, isNot(contains('ipv4')));
      expect(
        HevConfig.yaml(
          adapterName: 'Voidrau',
          mtu: 1400,
          socksPort: 1819,
          ipv6: true,
        ),
        contains("ipv6: 'fc00::1'"),
      );
    });
  });

  group('exit codes', () {
    test('Windows statuses arrive signed and are normalized', () {
      expect(ExitCodes.normalize(-1073741795), 0xC000001D);
      expect(ExitCodes.normalize(-1073741515), 0xC0000135);
      expect(ExitCodes.describe(-1073741795), contains('AVX2'));
      expect(ExitCodes.describe(-1073741515), contains('DLL'));
      expect(ExitCodes.describe(-1073741511), contains('API'));
      expect(ExitCodes.describe(1), isNull);
    });
  });
}
