import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/models/settings.dart';
import 'package:voidrauvpn/services/core_args.dart';
import 'package:voidrauvpn/services/ios_policy.dart';

void main() {
  test('iOS removes imported capabilities it cannot implement', () {
    final settings = VpnSettings(
      mode: ConnectionMode.proxy,
      lanShare: true,
      splitMode: SplitMode.include,
      splitApps: ['example.android.app'],
      privateDns: false,
      autoDownload: true,
      autoUpdate: true,
    );
    IosPolicy.normalize(settings);
    expect(settings.mode, ConnectionMode.vpn);
    expect(settings.lanShare, isFalse);
    expect(settings.splitMode, SplitMode.off);
    expect(settings.splitApps, isEmpty);
    expect(settings.privateDns, isTrue);
    expect(settings.autoDownload, isFalse);
    expect(settings.autoUpdate, isFalse);
  });

  test('iOS pins the performance profile the extension can afford', () {
    final settings = VpnSettings(
      perf: PerfProfile.extreme,
      perfRxKb: 8192,
      perfTxKb: 4096,
    );
    IosPolicy.normalize(settings);
    // The native shim forces `low` and 16 KiB buffers; the UI must not claim
    // otherwise.
    expect(settings.perf, PerfProfile.eco);
    expect(settings.perfRxKb, 0);
    expect(settings.perfTxKb, 0);
    final env = CoreLaunch.environment(settings, configPath: 'aether.toml');
    expect(env['AETHER_PERF_PROFILE'], 'low');
  });

  test('iOS keeps protocol, language and supported routing choices', () {
    final settings = VpnSettings(
      protocol: Protocol.mim,
      transport: MasqueTransport.h2,
      language: LanguageChoice.fa,
      killSwitch: true,
      bypassLan: false,
      ipv6Tunnel: true,
      endpoint: '162.159.192.1:443',
    );
    IosPolicy.normalize(settings);
    expect(settings.protocol, Protocol.mim);
    expect(settings.transport, MasqueTransport.h2);
    expect(settings.language, LanguageChoice.fa);
    expect(settings.killSwitch, isTrue);
    expect(settings.bypassLan, isFalse);
    expect(settings.ipv6Tunnel, isTrue);
    final env = CoreLaunch.environment(settings, configPath: 'aether.toml');
    expect(env['AETHER_PROTOCOL'], 'mim');
    expect(env['AETHER_MASQUE_HTTP2'], '1');
    expect(env['AETHER_SOCKS'], '127.0.0.1:1819');
    expect(env['AETHER_PEER'], '162.159.192.1:443');
  });

  test('iOS clamps the device MTU to what the extension accepts', () {
    final jumbo = VpnSettings(tunMtu: 8500);
    IosPolicy.normalize(jumbo);
    expect(jumbo.tunMtu, 1500);
    final tiny = VpnSettings(tunMtu: 1000);
    IosPolicy.normalize(tiny);
    expect(tiny.tunMtu, 1280);
    // And the normalization stays idempotent.
    IosPolicy.normalize(jumbo);
    expect(jumbo.tunMtu, 1500);
  });

  test('normalization is idempotent', () {
    final settings = VpnSettings();
    IosPolicy.normalize(settings);
    final once = settings.toJson();
    IosPolicy.normalize(settings);
    expect(settings.toJson(), once);
  });
}
