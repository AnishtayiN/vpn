import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/models/settings.dart';
import 'package:voidrauvpn/services/chain_proxy.dart';
import 'package:voidrauvpn/services/cloudflare_api.dart';
import 'package:voidrauvpn/services/warp.dart';
import 'package:voidrauvpn/services/xray_engine.dart';

const _vlessLink =
    'vless://11111111-2222-4333-8444-555555555555@example.com:443'
    '?type=ws&security=tls&path=%2F#My%20VLESS';
const _wgConf = '''
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.0.0.2/32
[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
Endpoint = 203.0.113.7:51820
''';

void main() {
  group('Xray is Android-only', () {
    test('the engine refuses to start where no Xray binary exists', () {
      // This test runs on the host (Linux), not Android.
      expect(XrayEngine.supported, isFalse);
      expect(XrayEngine.requireSupported, throwsUnsupportedError);
    });
  });

  group('worker config', () {
    test('worker outbound is VLESS over WS+TLS to the user domain', () {
      final out = XrayConfigBuilder.workerOutbound(
        'voidrau-abc.workers.dev',
        '11111111-2222-4333-8444-555555555555',
        XrayVariant.normal,
        VpnSettings(),
      );
      expect(out['protocol'], 'vless');
      expect(out['tag'], 'proxy');
      final settings = out['settings'] as Map;
      expect(settings['address'], 'voidrau-abc.workers.dev');
      expect(settings['port'], 443);
      expect(settings['id'], '11111111-2222-4333-8444-555555555555');
      final stream = out['streamSettings'] as Map;
      expect(stream['network'], 'ws');
      expect(stream['security'], 'tls');
      expect(stream.containsKey('finalmask'), isFalse);
    });

    test('fragment variant adds the TLS-fragment finalmask', () {
      final out = XrayConfigBuilder.workerOutbound(
        'voidrau-abc.workers.dev',
        '11111111-2222-4333-8444-555555555555',
        XrayVariant.fragment,
        VpnSettings(),
      );
      final stream = out['streamSettings'] as Map;
      final mask = stream['finalmask'] as Map;
      final tcp = (mask['tcp'] as List).first as Map;
      expect(tcp['type'], 'fragment');
      expect((tcp['settings'] as Map)['packets'], 'tlshello');
    });

    test('build refuses Worker mode before a deploy', () {
      expect(
        () => XrayConfigBuilder.build(VpnSettings(xrayMode: XrayMode.worker)),
        throwsStateError,
      );
      expect(
        () => XrayConfigBuilder.build(
          VpnSettings(
              xrayMode: XrayMode.worker,
              workerDeployed: true,
              workerDomain: 'voidrau-abc.workers.dev'),
        ),
        throwsStateError, // UUID missing
      );
    });

    test('build succeeds with a deployed Worker and a UUID', () {
      final cfg = XrayConfigBuilder.build(
        VpnSettings(
          xrayMode: XrayMode.worker,
          workerDeployed: true,
          workerDomain: 'voidrau-abc.workers.dev',
        ),
        workerUuid: '11111111-2222-4333-8444-555555555555',
      );
      final outbounds = cfg['outbounds'] as List;
      expect(outbounds.first['protocol'], 'vless');
      expect((cfg['inbounds'] as List).first['protocol'], 'socks');
    });
  });

  group('warp config', () {
    test('build refuses WARP mode without a registered account', () {
      expect(
        () => XrayConfigBuilder.build(VpnSettings(xrayMode: XrayMode.warp)),
        throwsStateError,
      );
    });

    test('warp outbound is WireGuard with the account keys', () {
      const account = WarpAccount(
        privateKey: 'cHJpdmF0ZWtleQ==',
        publicKey: 'cHVibGlja2V5',
        ipv6: '2606:4700:d0::1/128',
        reserved: [1, 2, 3],
      );
      final out = XrayConfigBuilder.warpOutbound(
        account,
        '162.159.192.4:2408',
        XrayVariant.normal,
      );
      expect(out['protocol'], 'wireguard');
      expect(out['tag'], 'proxy');
      final settings = out['settings'] as Map;
      expect(settings['secretKey'], 'cHJpdmF0ZWtleQ==');
      expect(settings['reserved'], [1, 2, 3]);
      expect(
          (settings['peers'] as List).first['endpoint'], '162.159.192.4:2408');
    });

    test('obfuscated WARP adds the UDP-noise finalmask', () {
      const account = WarpAccount(
        privateKey: 'cHJpdmF0ZWtleQ==',
        publicKey: 'cHVibGlja2V5',
        ipv6: '2606:4700:d0::1/128',
        reserved: [0, 0, 0],
      );
      final out = XrayConfigBuilder.warpOutbound(
        account,
        '162.159.192.4:2408',
        XrayVariant.obfuscated,
      );
      final stream = out['streamSettings'] as Map;
      expect((stream['finalmask'] as Map).containsKey('udp'), isTrue);
    });
  });

  group('serverless config', () {
    test('serverless is freedom only, with fragment and noise', () {
      final cfg = XrayConfigBuilder.build(
        VpnSettings(xrayMode: XrayMode.serverless),
      );
      final outbounds = cfg['outbounds'] as List;
      final proxy = outbounds.firstWhere((o) => o['tag'] == 'proxy');
      expect(proxy['protocol'], 'freedom');
      expect(
        outbounds.any((o) => o['tag'] == 'udp-noise'),
        isTrue,
      );
      // No MITM anywhere in the config.
      expect(jsonEncode(cfg).toLowerCase().contains('mitm'), isFalse);
      expect(jsonEncode(cfg).contains('domainFronting'), isFalse);
    });

    test('serverless never takes a chain exit', () {
      final cfg = XrayConfigBuilder.build(
        VpnSettings(
          xrayMode: XrayMode.serverless,
          xrayChainProxies: const [
            ChainProxy(id: 'a', name: 'x', link: _vlessLink),
          ],
        ),
      );
      final outbounds = cfg['outbounds'] as List;
      expect(outbounds.any((o) => o['tag'] == 'exit'), isFalse);
    });
  });

  group('chain proxies', () {
    test('VLESS link parses to protocol, address and tags', () {
      final info = ChainInfo.of(_vlessLink);
      expect(info, isNotNull);
      expect(info!.protocol, 'VLESS');
      expect(info.address, 'example.com:443');
      expect(info.tags, contains('WS'));
      expect(info.isUdp, isFalse);
      expect(info.canChainOver(XrayMode.worker), isTrue);
    });

    test('UDP proxies ride on WARP only, never on the Worker', () {
      const wgLink =
          'wireguard://AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=@203.0.113.7:51820'
          '?publickey=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=&address=10.0.0.2/32#wg';
      final info = ChainInfo.of(wgLink);
      expect(info, isNotNull);
      expect(info!.isUdp, isTrue);
      expect(info.canChainOver(XrayMode.warp), isTrue);
      expect(info.canChainOver(XrayMode.worker), isFalse);
      expect(ChainProxy.isUdpLink(wgLink), isTrue);
      expect(ChainProxy.isUdpLink(_vlessLink), isFalse);
    });

    test('garbage text parses to nothing and throws', () {
      expect(ChainInfo.of('hello world'), isNull);
      expect(() => parseChainProxies('hello world'), throwsFormatException);
    });

    test('a WireGuard config file becomes a wireguard:// link', () {
      final proxy = wireGuardConfToChain(_wgConf, name: 'wg0.conf');
      expect(proxy.name, 'wg0');
      expect(proxy.link.startsWith('wireguard://'), isTrue);
      expect(ChainInfo.of(proxy.link)?.protocol, 'WireGuard');
    });

    test('chain outbound is tagged exit and dials through the main proxy', () {
      final cfg = XrayConfigBuilder.build(
        VpnSettings(
          xrayMode: XrayMode.worker,
          workerDeployed: true,
          workerDomain: 'voidrau-abc.workers.dev',
          xrayChainProxies: const [
            ChainProxy(id: 'a', name: 'x', link: _vlessLink),
          ],
        ),
        workerUuid: '11111111-2222-4333-8444-555555555555',
      );
      final outbounds = cfg['outbounds'] as List;
      final exit = outbounds.firstWhere((o) => o['tag'] == 'exit');
      expect(exit['protocol'], 'vless');
      final stream = exit['streamSettings'] as Map;
      expect((stream['sockopt'] as Map)['dialerProxy'], 'proxy');
    });
  });

  group('warp keys', () {
    test('client_id decodes to the 3 reserved bytes', () {
      expect(
        WarpAccount.reservedFromClientId(base64.encode([1, 2, 3])),
        [1, 2, 3],
      );
      expect(WarpAccount.reservedFromClientId('!!!'), [0, 0, 0]);
    });

    test('generated X25519 keys round-trip', () {
      final keys = X25519KeyPair.generate();
      expect(X25519KeyPair.publicKeyOf(keys.privateKey), keys.publicKey);
      expect(base64.decode(keys.privateKey).length, 32);
    });

    test('WARP endpoints expand v4/v6 over the offered ports', () {
      final eps = WarpRegistrar.offeredEndpoints({
        'v4': '162.159.192.4:0',
        'v6': '2606:4700:d0::a29f:c004:0',
        'ports': [2408, 4500],
      });
      expect(eps, contains('162.159.192.4:2408'));
      expect(eps, contains('162.159.192.4:4500'));
      expect(eps.length, 4);
    });
  });

  group('cloudflare deploy helpers', () {
    test('ENV binding round-trips the UUID, proxy IPs and fallback', () {
      final env = CloudflareApi.encodeEnv(
        uuid: '11111111-2222-4333-8444-555555555555',
        proxyIps: ['203.0.113.1:443'],
        fallbackUrl: 'https://example.com',
      );
      final decoded = jsonDecode(
        utf8.decode(base64.decode(env)),
      ) as Map<String, dynamic>;
      expect(decoded['v'], 1);
      expect(decoded['id'], '11111111-2222-4333-8444-555555555555');
      expect(decoded['pips'], ['203.0.113.1:443']);
      expect(decoded['fb'], 'https://example.com');
    });

    test('token normalisation strips Bearer and quotes, rejects the global key',
        () {
      expect(
        CloudflareApi.normalizeToken(
          'curl -H "Authorization: Bearer abcDEF1234567890abcdefghij1234567890"',
        ),
        'abcDEF1234567890abcdefghij1234567890',
      );
      expect(
        () => CloudflareApi.normalizeToken('a' * 37),
        throwsA(isA<CloudflareException>()),
      );
      expect(
        () => CloudflareApi.normalizeToken('short'),
        throwsA(isA<CloudflareException>()),
      );
    });

    test('token creation URL names VoidrauVPN, not the reference app', () {
      expect(CloudflareApi.tokenCreationUrl(), contains('VoidrauVPN'));
      expect(CloudflareApi.tokenCreationUrl(), isNot(contains('BPB')));
    });
  });

  group('settings round-trip', () {
    test('Xray fields survive save and load', () {
      final st = VpnSettings(
        xrayMode: XrayMode.warp,
        xrayVariant: XrayVariant.obfuscated,
        warpRegistered: true,
        warpEndpoints: const ['162.159.192.4:2408'],
        xrayChainProxies: const [
          ChainProxy(id: 'a', name: 'x', link: _vlessLink),
        ],
        xrayChainExitId: 'a',
      );
      final loaded = VpnSettings.fromJson(st.toJson());
      expect(loaded.xrayMode, XrayMode.warp);
      expect(loaded.xrayVariant, XrayVariant.obfuscated);
      expect(loaded.warpRegistered, isTrue);
      expect(loaded.warpEndpoints, ['162.159.192.4:2408']);
      expect(loaded.xrayChainProxies.length, 1);
      expect(loaded.xrayChainProxies.first.link, _vlessLink);
      expect(loaded.xrayChainExitId, 'a');
    });

    test('chain exit picks the chosen proxy, or the first usable one', () {
      final st = VpnSettings(
        xrayMode: XrayMode.worker,
        xrayChainProxies: const [
          ChainProxy(id: 'a', name: 'x', link: _vlessLink),
        ],
      );
      expect(st.xrayChainExitFor(XrayMode.worker)?.id, 'a');
      expect(st.xrayChainExitFor(XrayMode.serverless), isNull);
    });
  });
}
