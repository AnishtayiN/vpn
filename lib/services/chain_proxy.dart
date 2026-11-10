import 'dart:io';
import 'dart:math';

import '../models/settings.dart';
import 'proxy_uri.dart';

/// What a chain proxy's link says about it, for the UI: name, address, tags.
///
/// Chain proxies come ONLY from links the user enters — the app ships no
/// proxy, no subscription and no server of its own.
class ChainInfo {
  final ProxyUri uri;
  const ChainInfo(this.uri);

  /// Null when [link] is not a supported share link.
  static ChainInfo? of(String link) {
    try {
      return ChainInfo(ProxyUri.parse(link));
    } on FormatException {
      return null;
    }
  }

  bool get isWireGuard => uri.protocol == 'wireguard';

  /// WireGuard and Hysteria2 (QUIC) run over UDP.
  bool get isUdp => isWireGuard || uri.protocol == 'hysteria2';

  /// `host:port` (an IPv6 host in brackets).
  String get address =>
      '${uri.server.contains(':') ? '[${uri.server}]' : uri.server}:${uri.port}';

  String get protocol => switch (uri.protocol) {
        'vless' => 'VLESS',
        'vmess' => 'VMess',
        'trojan' => 'Trojan',
        'shadowsocks' => 'SS',
        'socks' => 'SOCKS',
        'http' => 'HTTP',
        'wireguard' => 'WireGuard',
        'hysteria2' => 'Hysteria2',
        final p => p.toUpperCase(),
      };

  /// The link's `type` for the V2Ray protocols; null for WireGuard and
  /// Hysteria2, which have none.
  String? get transport {
    if (isUdp) return null;
    return switch ((uri['type'] ?? 'tcp').toLowerCase()) {
      'tcp' || 'raw' => 'TCP',
      'ws' => 'WS',
      'grpc' => 'gRPC',
      'xhttp' || 'splithttp' => 'XHTTP',
      'httpupgrade' => 'HTTPUpgrade',
      'kcp' || 'mkcp' => 'mKCP',
      'h2' || 'http' => 'HTTP/2',
      final t => t.toUpperCase(),
    };
  }

  /// TLS or Reality; null without security. Hysteria2 is always TLS.
  String? get security => uri.protocol == 'hysteria2'
      ? 'TLS'
      : switch (uri['security']?.toLowerCase()) {
          'tls' => 'TLS',
          'reality' => 'Reality',
          _ => null,
        };

  /// Protocol, transport and security (when there are), as the UI shows them.
  List<String> get tags {
    final out = <String>[protocol];
    final tr = transport;
    if (tr != null) out.add(tr);
    final sec = security;
    if (sec != null) out.add(sec);
    return out;
  }

  /// Whether an [XrayMode] connection can carry this proxy: WireGuard and
  /// Hysteria2 are UDP, which only WARP carries (the Worker relays TCP only,
  /// and Serverless has no upstream at all).
  bool canChainOver(XrayMode mode) => !isUdp || mode == XrayMode.warp;

  /// Whether a mode can carry this proxy at all (Serverless never chains).
  static bool canChainOverLink(String link, XrayMode mode) {
    if (mode == XrayMode.serverless) return false;
    final info = ChainInfo.of(link);
    return info != null && info.canChainOver(mode);
  }
}

/// A new chain proxy's id.
String newChainId() {
  final random = Random.secure();
  return List.generate(8, (_) => random.nextInt(16).toRadixString(16)).join();
}

/// The chain proxies in [text] (pasted, a scanned QR code or a file): share
/// links, one per line, or a WireGuard config (`[Interface]` / `[Peer]`),
/// named [fileName] without its extension when it comes from a file.
/// Throws [FormatException] when none is found.
List<ChainProxy> parseChainProxies(String text, {String? fileName}) {
  if (text.contains('[Interface]')) {
    return [wireGuardConfToChain(text, name: fileName)];
  }
  final proxies = <ChainProxy>[];
  for (final line in text.split(RegExp(r'\s+'))) {
    if (!line.contains('://')) continue;
    final info = ChainInfo.of(line);
    if (info == null) continue;
    final name = info.uri.remark.isNotEmpty ? info.uri.remark : info.address;
    proxies.add(ChainProxy(id: newChainId(), name: name, link: line.trim()));
  }
  if (proxies.isEmpty) {
    throw const FormatException(
      'No supported proxy link or WireGuard config found',
    );
  }
  return proxies;
}

/// A WireGuard config file (`[Interface]` / first `[Peer]`) as a chain proxy,
/// stored as a wireguard:// link named [name] without its extension
/// (wg0.conf → wg0), else the endpoint's host.
/// Throws [FormatException] when a required field is missing.
ChainProxy wireGuardConfToChain(String conf, {String? name}) {
  final interface = <String, String>{};
  final peer = <String, String>{};
  Map<String, String>? section;
  var peers = 0;
  for (final raw in conf.split('\n')) {
    final line = raw.split('#').first.trim();
    if (line.isEmpty) continue;
    if (line.toLowerCase() == '[interface]') {
      section = interface;
    } else if (line.toLowerCase() == '[peer]') {
      section = ++peers == 1 ? peer : null; // Only the first peer.
    } else if (section != null && line.contains('=')) {
      final i = line.indexOf('=');
      section[line.substring(0, i).trim().toLowerCase()] =
          line.substring(i + 1).trim();
    }
  }
  final privateKey = interface['privatekey'];
  final address = interface['address'];
  final publicKey = peer['publickey'];
  final endpoint = peer['endpoint'];
  if (privateKey == null ||
      address == null ||
      publicKey == null ||
      endpoint == null) {
    throw const FormatException(
      'Not a WireGuard config: PrivateKey, Address, PublicKey and Endpoint '
      'are needed',
    );
  }
  List<String> list(String? v) => [
        for (final s in (v ?? '').split(','))
          if (s.trim().isNotEmpty) s.trim(),
      ];
  final colon = endpoint.lastIndexOf(':');
  if (colon <= 0) {
    throw const FormatException('WireGuard Endpoint needs host:port');
  }
  final host =
      endpoint.substring(0, colon).replaceAll(RegExp(r'^\[|\]$'), '');
  final baseName = name?.replaceFirst(RegExp(r'\.[^.]*$'), '').trim() ?? '';
  final label = baseName.isEmpty ? host : baseName;
  final query = <String, String>{
    'publickey': publicKey,
    'address': list(address).join(','),
    if (interface['mtu'] != null) 'mtu': interface['mtu']!,
    if (peer['presharedkey'] != null)
      'presharedkey': peer['presharedkey']!,
    if (peer['persistentkeepalive'] != null)
      'keepalive': peer['persistentkeepalive']!,
    if (list(peer['allowedips']).isNotEmpty)
      'allowedips': list(peer['allowedips']).join(','),
    // Xray's remoteDNS takes IPs only; search domains in DNS are left out.
    if (list(interface['dns']).where(_isIp).isNotEmpty)
      'dns': list(interface['dns']).where(_isIp).join(','),
  };
  final link = Uri(
    scheme: 'wireguard',
    userInfo: Uri.encodeComponent(privateKey),
    host: host,
    port: int.tryParse(endpoint.substring(colon + 1)),
    queryParameters: query,
    fragment: label,
  ).toString();
  return ChainProxy(id: newChainId(), name: label, link: link);
}

bool _isIp(String v) => InternetAddress.tryParse(v) != null;

/// Builds the Xray outbound JSON for a chain proxy link, as the exit of an
/// Xray connection. Throws [FormatException] / [StateError] for bad links.
///
/// The outbound is tagged `exit` and dials through the main connection: the
/// caller wires routing so traffic reaches it (see XrayConfigBuilder).
Map<String, dynamic> chainProxyOutbound(String link) {
  final p = ProxyUri.parse(link);
  if (p.protocol == 'wireguard') return _wireGuardChain(p);
  if (p.protocol == 'hysteria2') return _hysteria2Chain(p);

  final type = p['type'] ?? 'raw';
  final security = p['security'];
  final streamSettings = <String, dynamic>{
    'network': type,
    ..._transport(type, p),
    if (security == 'tls' || security == 'reality')
      'security': security,
    if (security == 'tls')
      'tlsSettings': {
        'serverName': p['sni'] ?? p['host'] ?? p.server,
        if (p['fp'] != null) 'fingerprint': p['fp'],
        if (p['alpn'] != null) 'alpn': p['alpn']!.split(','),
        ..._pinning(p),
      },
    if (security == 'reality')
      'realitySettings': {
        'serverName': p['sni'] ?? p.server,
        'publicKey': p['pbk'],
        'shortId': p['sid'],
        if (p['fp'] != null) 'fingerprint': p['fp'],
      },
  };

  final settings = switch (p.protocol) {
    'shadowsocks' => {
        'address': p.server,
        'port': p.port,
        'method': p['method'],
        'password': p['password'],
      },
    'vless' => {
        'address': p.server,
        'port': p.port,
        'id': p['uuid'],
        'encryption': p['encryption'] ?? 'none',
        'flow': p['flow'],
      },
    'vmess' => {
        'address': p.server,
        'port': p.port,
        'id': p['uuid'],
        'security': 'auto',
      },
    'trojan' => {
        'address': p.server,
        'port': p.port,
        'password': p['password'],
      },
    'socks' => {
        'address': p.server,
        'port': p.port,
        if (p['user'] != null) 'user': p['user'],
        if (p['pass'] != null) 'pass': p['pass'],
      },
    'http' => {
        'address': p.server,
        'port': p.port,
        if (p['user'] != null) 'user': p['user'],
        if (p['pass'] != null) 'pass': p['pass'],
      },
    _ => throw StateError('Unsupported chain proxy protocol: ${p.protocol}'),
  };

  return {
    'protocol': p.protocol,
    'settings': settings,
    'streamSettings': streamSettings,
    'tag': 'exit',
  };
}

/// The link's certificate checks: pcs (pinned SHA-256 hashes) and vcn (names
/// to verify the certificate by); Hysteria2 links carry the hash as pinSHA256.
Map<String, dynamic> _pinning(ProxyUri p) {
  final sha = p['pcs'] ?? p['pinSHA256'];
  final name = p['vcn'];
  return {
    if (sha != null) 'pinnedPeerCertSha256': sha,
    if (name != null) 'verifyPeerCertByName': name,
  };
}

Map<String, dynamic> _transport(String type, ProxyUri p) {
  final path = p['path'] ?? '/';
  final host = p['host'];
  switch (type) {
    case 'tcp':
    case 'raw':
      return {
        'rawSettings': {
          'header': p['headerType'] == 'http'
              ? {
                  'type': 'http',
                  'request': {
                    'headers': {
                      'Host': host?.split(','),
                      'Accept-Encoding': ['gzip, deflate'],
                      'Connection': ['keep-alive'],
                      'Pragma': ['no-cache'],
                    },
                    'path': path.split(','),
                    'method': 'GET',
                    'version': '1.1',
                  },
                }
              : {'type': 'none'},
        },
      };
    case 'ws':
      return {
        'wsSettings': {'host': host, 'path': path},
      };
    case 'httpupgrade':
      return {
        'httpupgradeSettings': {'host': host, 'path': path},
      };
    case 'grpc':
      return {
        'grpcSettings': {
          'authority': p['authority'],
          'multiMode': p['mode'] == 'multi',
          'serviceName': p['serviceName'],
        },
      };
    case 'xhttp':
      return {
        'xhttpSettings': {
          'host': host,
          'path': path,
          'mode': p['mode'] ?? 'auto',
        },
      };
    default:
      return {};
  }
}

Map<String, dynamic> _hysteria2Chain(ProxyUri p) {
  final masks = <Map<String, dynamic>>[];
  final mport = p['mport'];
  if (mport != null && mport.isNotEmpty) {
    masks.add({
      'type': 'udphop',
      'settings': {
        'mode': 'intervalRemote,intervalLocal',
        'remotePorts': mport,
      },
    });
  }
  return {
    'protocol': 'hysteria',
    'settings': {'version': 2, 'address': p.server, 'port': p.port},
    'streamSettings': {
      'network': 'hysteria',
      'hysteriaSettings': {
        'version': 2,
        'auth': p['auth'],
        if (p['obfs'] == 'salamander')
          'obfsPassword': p['obfs-password'],
      },
      'security': 'tls',
      'tlsSettings': {
        'serverName': p['sni'] ?? p.server,
        ..._pinning(p),
      },
      if (masks.isNotEmpty) 'finalmask': {'udp': masks},
    },
    'tag': 'exit',
  };
}

Map<String, dynamic> _wireGuardChain(ProxyUri p) {
  List<String> list(String? v) => [
        for (final s in (v ?? '').split(','))
          if (s.trim().isNotEmpty) s.trim(),
      ];
  final reserved = list(p['reserved']).map(int.tryParse).whereType<int>().toList();
  final allowedIPs = list(p['allowedips']);
  final dns =
      list(p['dns']).where((ip) => InternetAddress.tryParse(ip) != null).toList();
  return {
    'protocol': 'wireguard',
    'settings': {
      'secretKey': p['privateKey'],
      'address': list(p['address']),
      'peers': [
        {
          'publicKey': p['publickey'],
          if (p['presharedkey'] != null) 'preSharedKey': p['presharedkey'],
          'endpoint':
              '${p.server.contains(':') ? '[${p.server}]' : p.server}:${p.port}',
          if (int.tryParse(p['keepalive'] ?? '') != null)
            'keepAlive': int.tryParse(p['keepalive'] ?? ''),
          if (allowedIPs.isNotEmpty) 'allowedIPs': allowedIPs,
        },
      ],
      // Only the config's own MTU: without one, Xray's default.
      if (int.tryParse(p['mtu'] ?? '') != null)
        'mtu': int.tryParse(p['mtu'] ?? ''),
      if (reserved.length == 3) 'reserved': reserved,
      if (dns.isNotEmpty) 'remoteDNS': dns,
    },
    'tag': 'exit',
  };
}
