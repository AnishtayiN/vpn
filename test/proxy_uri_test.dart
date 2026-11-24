import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voidrauvpn/services/proxy_uri.dart';

/// Tests for the share-link parser (finding 14): the input is fully
/// attacker-controllable user-pasted text, and the parsed credentials flow
/// into Xray configs and stored settings — so valid links, malformed links
/// and hostile inputs all need pinned behaviour.
void main() {
  group('valid links', () {
    test('vless: uuid, query params and a percent-encoded remark', () {
      final p = ProxyUri.parse(
        'vless://11111111-2222-4333-8444-555555555555@example.com:443'
        '?encryption=none&security=tls&sni=example.com&type=ws&path=%2F'
        '#My%20VLESS',
      );
      expect(p.protocol, 'vless');
      expect(p.server, 'example.com');
      expect(p.port, 443);
      expect(p['uuid'], '11111111-2222-4333-8444-555555555555');
      expect(p['security'], 'tls');
      expect(p['sni'], 'example.com');
      expect(p['type'], 'ws');
      expect(p.remark, 'My VLESS');
    });

    test('vmess: base64 JSON carries server, port, uuid and transport', () {
      final json = jsonEncode({
        'v': '2',
        'ps': 'My VMess',
        'add': 'vmess.example.com',
        'port': '8443',
        'id': '11111111-2222-4333-8444-555555555555',
        'aid': '0',
        'net': 'ws',
        'type': 'none',
        'host': '',
        'path': '/ws',
        'tls': 'tls',
        'sni': 'vmess.example.com',
      });
      final p = ProxyUri.parse(
          'vmess://${base64Encode(utf8.encode(json))}');
      expect(p.protocol, 'vmess');
      expect(p.server, 'vmess.example.com');
      expect(p.port, 8443);
      expect(p['uuid'], '11111111-2222-4333-8444-555555555555');
      expect(p['type'], 'ws');
      expect(p['security'], 'tls');
      expect(p.remark, 'My VMess');
    });

    test('vmess: an explicit #remark wins over the embedded ps field', () {
      final json = jsonEncode({
        'ps': 'Embedded',
        'add': 'example.com',
        'port': '443',
        'id': '11111111-2222-4333-8444-555555555555',
      });
      final p = ProxyUri.parse(
          'vmess://${base64Encode(utf8.encode(json))}#Chosen');
      expect(p.remark, 'Chosen');
    });

    test('trojan: password from userinfo, sni from the query', () {
      final p = ProxyUri.parse(
          'trojan://s3cret@example.com:443?sni=example.com#Trojan');
      expect(p.protocol, 'trojan');
      expect(p.server, 'example.com');
      expect(p.port, 443);
      expect(p['password'], 's3cret');
      expect(p['sni'], 'example.com');
      expect(p.remark, 'Trojan');
    });

    test('shadowsocks: plain method:password@host:port', () {
      final p = ProxyUri.parse('ss://aes-256-gcm:hunter2@example.com:8388#SS');
      expect(p.protocol, 'shadowsocks');
      expect(p.server, 'example.com');
      expect(p.port, 8388);
      expect(p['method'], 'aes-256-gcm');
      expect(p['password'], 'hunter2');
    });

    test('shadowsocks: whole link base64-encoded, with a plugin query', () {
      final encoded = base64Encode(
          utf8.encode('aes-256-gcm:hunter2@example.com:8388'));
      final p = ProxyUri.parse('ss://$encoded?plugin=obfs#SS64');
      expect(p.protocol, 'shadowsocks');
      expect(p['method'], 'aes-256-gcm');
      expect(p['password'], 'hunter2');
      expect(p.port, 8388);
    });

    test('shadowsocks: base64 userinfo without a colon is rejected', () {
      final encoded = base64Encode(utf8.encode('justauser'));
      expect(
        () => ProxyUri.parse('ss://$encoded@example.com:8388'),
        throwsA(isA<FormatException>()),
      );
    });

    test('socks and socks5 alias to socks; credentials split on the colon',
        () {
      final p = ProxyUri.parse('socks://alice:wonderland@127.0.0.1:1080');
      expect(p.protocol, 'socks');
      expect(p['user'], 'alice');
      expect(p['pass'], 'wonderland');
      expect(ProxyUri.parse('socks5://127.0.0.1:1080').protocol, 'socks');
    });

    test('socks: a bare username without a password parses as user only',
        () {
      // 'only.user' is not valid base64, so the plain-username fallback
      // runs. (A bare username that *is* valid base64 is decoded instead
      // — see the quirk test below.)
      final p = ProxyUri.parse('socks://only.user@127.0.0.1:1080');
      expect(p['user'], 'only.user');
      expect(p['pass'], isNull);
    });

    test('socks: a base64-shaped bare username is decoded, not kept '
        '(known quirk)', () {
      // 'onlyuser' is 8 valid base64 characters, so the parser treats it
      // as base64 credentials and decodes it instead of keeping the plain
      // username. Pinned as-is: changing it is a parser fix, not a test
      // fix — flagging here so it is a deliberate decision.
      final p = ProxyUri.parse('socks://onlyuser@127.0.0.1:1080');
      expect(p['user'], isNot('onlyuser'));
      expect(p['pass'], isNull);
    });

    test('http: user, pass and port', () {
      final p = ProxyUri.parse('http://bob:builder@proxy.example.com:8080');
      expect(p.protocol, 'http');
      expect(p.server, 'proxy.example.com');
      expect(p.port, 8080);
      expect(p['user'], 'bob');
      expect(p['pass'], 'builder');
    });

    test('wireguard: keys survive, including a + inside the private key',
        () {
      const priv = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA+';
      const pub = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=';
      final p = ProxyUri.parse(
        'wireguard://$priv@10.0.0.1:51820'
        '?publickey=$pub&address=10.0.0.2%2F32&mtu=1400#WG',
      );
      expect(p.protocol, 'wireguard');
      expect(p.server, '10.0.0.1');
      expect(p.port, 51820);
      expect(p['privateKey'], priv);
      expect(p['publickey'], pub);
      expect(p['mtu'], '1400');
      expect(p.remark, 'WG');
    });

    test('wg:// aliases to wireguard', () {
      const priv = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
      final p = ProxyUri.parse(
          'wg://$priv@10.0.0.1:51820?publickey=$priv');
      expect(p.protocol, 'wireguard');
      expect(p['privateKey'], priv);
    });

    test('hysteria2: auth and obfs options; hy2:// aliases', () {
      final p = ProxyUri.parse(
        'hysteria2://secret@hy.example.com:443'
        '?sni=hy.example.com&obfs=salamander&obfs-password=pw123#HY2',
      );
      expect(p.protocol, 'hysteria2');
      expect(p['auth'], 'secret');
      expect(p['sni'], 'hy.example.com');
      expect(p['obfs'], 'salamander');
      expect(p['obfs-password'], 'pw123');
      expect(
        ProxyUri.parse('hy2://secret@hy.example.com:443').protocol,
        'hysteria2',
      );
    });

    test('scheme matching is case-insensitive and whitespace is trimmed',
        () {
      final p = ProxyUri.parse(
          '  VLESS://11111111-2222-4333-8444-555555555555@example.com:443  ');
      expect(p.protocol, 'vless');
      expect(p.port, 443);
    });

    test('a link without a remark parses with an empty remark', () {
      final p = ProxyUri.parse(
          'vless://11111111-2222-4333-8444-555555555555@example.com:443');
      expect(p.remark, isEmpty);
    });

    test('an unknown query param is kept, not dropped or crashed on', () {
      final p = ProxyUri.parse(
        'vless://11111111-2222-4333-8444-555555555555@example.com:443'
        '?futureOption=abc123',
      );
      expect(p['futureOption'], 'abc123');
    });
  });

  group('malformed links', () {
    test('empty input, plain text and a bare scheme are rejected', () {
      for (final bad in ['', '   ', 'not a link', 'vless://', '://host:443']) {
        expect(() => ProxyUri.parse(bad), throwsA(isA<FormatException>()),
            reason: bad);
      }
    });

    test('unsupported schemes are rejected', () {
      for (final bad in [
        'https://example.com:443',
        'ftp://user@example.com:21',
        'ssr://example.com:443',
        'ssh://user@example.com:22',
      ]) {
        expect(() => ProxyUri.parse(bad), throwsA(isA<FormatException>()),
            reason: bad);
      }
    });

    test('a missing host or port is rejected', () {
      for (final bad in [
        'vless://11111111-2222-4333-8444-555555555555@:443',
        'vless://11111111-2222-4333-8444-555555555555@example.com',
        'trojan://pass@example.com',
        'http://proxy.example.com',
      ]) {
        expect(() => ProxyUri.parse(bad), throwsA(isA<FormatException>()),
            reason: bad);
      }
    });

    test('port 0 has no port for the parser and is rejected', () {
      expect(
        () => ProxyUri.parse(
            'vless://11111111-2222-4333-8444-555555555555@example.com:0'),
        throwsA(isA<FormatException>()),
      );
    });

    test('wireguard without keys is rejected', () {
      // No private key in the userinfo.
      expect(
        () => ProxyUri.parse(
            'wireguard://10.0.0.1:51820?publickey=BBBB'),
        throwsA(isA<FormatException>()),
      );
      // No public key in the query.
      expect(
        () => ProxyUri.parse(
            'wireguard://AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=@10.0.0.1:51820'),
        throwsA(isA<FormatException>()),
      );
    });

    test('vmess with invalid base64 is rejected', () {
      expect(
        () => ProxyUri.parse('vmess://!!!not-base64!!!'),
        throwsA(isA<FormatException>()),
      );
    });

    test('vmess whose JSON is not an object is rejected', () {
      final encoded = base64Encode(utf8.encode('"just a string"'));
      expect(
        () => ProxyUri.parse('vmess://$encoded'),
        throwsA(isA<TypeError>()),
      );
      final list = base64Encode(utf8.encode('[1, 2, 3]'));
      expect(
        () => ProxyUri.parse('vmess://$list'),
        throwsA(isA<TypeError>()),
      );
    });

    test('vmess with a non-numeric port yields port 0, not a crash', () {
      final json = jsonEncode({
        'add': 'example.com',
        'port': 'notaport',
        'id': '11111111-2222-4333-8444-555555555555',
      });
      final p = ProxyUri.parse(
          'vmess://${base64Encode(utf8.encode(json))}');
      expect(p.port, 0);
      expect(p.server, 'example.com');
    });
  });

  group('malicious / hostile input', () {
    test('bad percent-encoding never throws: values stay literal', () {
      final p = ProxyUri.parse(
          'vless://11111111-2222-4333-8444-555555555555@example.com:443'
          '?security=%ZZ#bad%2');
      expect(p['security'], '%ZZ');
      expect(p.remark, 'bad%2');
    });

    test('oversized input is rejected fast, not hung on', () {
      final huge = 'vless://${'x' * 200000}';
      final sw = Stopwatch()..start();
      expect(() => ProxyUri.parse(huge), throwsA(isA<FormatException>()));
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('oversized vmess payload is rejected, not decoded forever', () {
      final huge = 'vmess://${'A' * 200000}';
      expect(() => ProxyUri.parse(huge), throwsA(isA<Object>()));
    });

    test('unexpected fields in vmess JSON are ignored', () {
      final json = jsonEncode({
        'add': 'example.com',
        'port': '443',
        'id': '11111111-2222-4333-8444-555555555555',
        'ps': 'x',
        'evil': {'nested': ['a', 'b']},
        'another': 42,
      });
      final p = ProxyUri.parse(
          'vmess://${base64Encode(utf8.encode(json))}');
      expect(p.server, 'example.com');
      expect(p.port, 443);
    });

    test('a link smuggling a second scheme in the remark stays one link',
        () {
      final p = ProxyUri.parse(
        'trojan://pass@example.com:443#https://evil.example/x',
      );
      expect(p.protocol, 'trojan');
      expect(p.server, 'example.com');
      expect(p.remark, 'https://evil.example/x');
    });

    test('CRLF / control characters in the link do not change the parse',
        () {
      final p = ProxyUri.parse(
        'vless://11111111-2222-4333-8444-555555555555@example.com:443'
        '?security=tls#Name\r\nInjected: header',
      );
      expect(p.server, 'example.com');
      expect(p['security'], 'tls');
    });

    test('an out-of-range port is passed through unvalidated (no silent '
        'rewrite)', () {
      // The parser does not range-check ports today: pin the behaviour so
      // a future validation change is a deliberate decision, not an
      // accident. Downstream config builders must validate.
      final p = ProxyUri.parse(
          'vless://11111111-2222-4333-8444-555555555555@example.com:99999');
      expect(p.port, 99999);
    });

    test('ss:// with a whitespace-padded base64 blob still decodes', () {
      final encoded = base64Encode(
          utf8.encode('aes-256-gcm:hunter2@example.com:8388'));
      final spaced = encoded.replaceRange(4, 4, '  \n ');
      final p = ProxyUri.parse('ss://$spaced');
      expect(p['method'], 'aes-256-gcm');
      expect(p['password'], 'hunter2');
    });
  });

  group('decodeBase64Loose', () {
    test('URL-safe alphabet and missing padding are accepted', () {
      expect(decodeBase64Loose('aGVsbG8'), 'hello');
      expect(decodeBase64Loose('aGVsbG8='), 'hello');
      // The same bytes in standard ('+/8=') and URL-safe ('-_8=') form
      // decode identically.
      expect(decodeBase64Loose('-_8='), decodeBase64Loose('+/8='));
      expect(decodeBase64Loose('-_8'), decodeBase64Loose('+/8='));
    });

    test('a length that can never be valid base64 is rejected', () {
      expect(() => decodeBase64Loose('abcde'), throwsA(isA<FormatException>()));
    });
  });

  group('ProxyUri operator []', () {
    test('missing and empty params read as null', () {
      const p = ProxyUri(protocol: 'vless', server: 'h', port: 1);
      expect(p['nope'], isNull);
      const q = ProxyUri(
          protocol: 'vless', server: 'h', port: 1, params: {'x': ''});
      expect(q['x'], isNull);
    });
  });
}
