import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// SOCKS5 data-plane probes.
///
/// Everything here speaks SOCKS5 with a *domain* CONNECT (ATYP=3) so name
/// resolution happens inside the tunnel, exactly the path the TUN bridge
/// forwards for apps. Plain HTTP on port 80 is used so no TLS stack is
/// needed; the previous implementation dialled port 443 and then spoke
/// cleartext HTTP on it, which can never succeed — that is why the stats
/// probe always threw and the watchdog tore down healthy connections.
class SocksProbe {
  /// Independent targets on three different operators, mirroring the
  /// reference client's proven-data-plane gate.
  static const _targets = <List<String>>[
    ['www.cloudflare.com', '/cdn-cgi/trace'],
    ['detectportal.firefox.com', '/success.txt'],
    ['connectivitycheck.gstatic.com', '/generate_204'],
  ];

  /// Proves the tunnel can complete a real HTTP request through SOCKS.
  /// Returns the round-trip in ms for the first target that answers,
  /// or throws when every target failed.
  static Future<int> prove({
    String host = '127.0.0.1',
    int port = 1819,
    int attempts = 2,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final target in _targets) {
        try {
          final result = await httpGet(
            target[0],
            target[1],
            host: host,
            port: port,
            timeout: timeout,
          );
          return result.pingMs;
        } catch (e) {
          lastError = e;
        }
      }
    }
    throw SocketException('tunnel data-plane proof failed: $lastError');
  }

  /// Proves the **device** VPN (not the SOCKS listener) carries traffic: a
  /// plain HTTP GET with no proxy at all. Once the TUN adapter holds the
  /// default route, the OS has nothing else to send it through, so a successful
  /// reply is proof the adapter, the bridge and the routes really work.
  ///
  /// The first target is an IP literal — it must succeed even when DNS inside
  /// the tunnel is broken, so a routing failure and a DNS failure are not
  /// confused with each other. The domain targets then check name resolution
  /// through the tunnel.
  ///
  /// Connectivity only: a reply that left through the physical line (the
  /// TUN default route installed but not winning) also succeeds here. Use
  /// [deviceExit] + [EgressCheck] when the *egress* has to be proven.
  static Future<int> proveDevice({
    Duration timeout = const Duration(seconds: 12),
    int attempts = 2,
  }) async {
    const targets = <List<String>>[
      ['1.1.1.1', '/cdn-cgi/trace'],
      ['www.cloudflare.com', '/cdn-cgi/trace'],
      ['detectportal.firefox.com', '/success.txt'],
    ];
    Object? lastError;
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final target in targets) {
        try {
          final r = await _directGet(target[0], target[1], timeout: timeout);
          return r.pingMs;
        } catch (e) {
          lastError = e;
        }
      }
    }
    throw SocketException('device VPN data-plane proof failed: $lastError');
  }

  /// Ordered egress-probe URLs for the device path. HTTPS IP literals
  /// first: they need no DNS at all, and Cloudflare's edge certificate
  /// carries the IP SANs (verified: `subjectAltName: host "1.1.1.1"
  /// matched cert's IP address`), so Dart's TLS validation accepts them.
  /// The IPv6 literal is appended only when the machine actually has a
  /// global IPv6 address (see [deviceExitDetailed]). Plain-HTTP IP
  /// literals follow — note `http://1.1.1.1/cdn-cgi/trace` answers 301
  /// with an HTML body that carries no `ip=` line, so it can never prove
  /// an egress on its own — and the hostname targets last, because they
  /// depend on DNS, which is exactly the path that can bypass the tunnel
  /// (WSANO_DATA, errno 11004, on a filtered line). Configurable via
  /// remote config (the gate's `probes`); these built-ins are the fallback
  /// when no server list arrives.
  static const defaultEgressProbeUrls = <String>[
    'https://1.1.1.1/cdn-cgi/trace',
    'https://1.0.0.1/cdn-cgi/trace',
    'http://1.1.1.1/cdn-cgi/trace',
    'http://1.0.0.1/cdn-cgi/trace',
    'https://www.cloudflare.com/cdn-cgi/trace',
    'http://www.cloudflare.com/cdn-cgi/trace',
  ];

  static const _ipv6EgressProbeUrl =
      'https://[2606:4700:4700::1111]/cdn-cgi/trace';

  /// The egress the **device** path presents: a plain HTTP GET (no proxy)
  /// to a Cloudflare trace target, parsed for `ip=`/`loc=`.
  ///
  /// This is the address the machine's own traffic leaves from — through
  /// the TUN when the TUN captures it, through the physical line when it
  /// does not. It is the counterpart of [exitInfo] (which dials SOCKS
  /// explicitly and therefore only ever proves the *listener*): comparing
  /// the two is how a TUN that routes nowhere is caught instead of being
  /// published as "connected" on the strength of the SOCKS probe alone.
  static Future<({String ip, String country, int pingMs})> deviceExit({
    Duration timeout = const Duration(seconds: 8),
    int attempts = 2,
  }) async {
    final r = await deviceExitDetailed(timeout: timeout, attempts: attempts);
    if (r.ip == null || r.ip!.isEmpty) {
      throw SocketException(
          'device egress lookup failed: ${r.attempts.isEmpty ? 'no probes configured' : r.attempts.last}');
    }
    return (ip: r.ip!, country: r.country, pingMs: r.pingMs ?? 0);
  }

  /// The device path's egress, measured without depending on DNS: HTTPS
  /// IP-literal trace endpoints first, plain-HTTP IP literals next,
  /// hostname targets only as a last resort. Never throws: when no probe
  /// can run at all the result carries `ip == null` and the per-probe
  /// attempts, so the caller can tell "nothing could be measured"
  /// ([EgressVerdict.probeFailed]) apart from "measured and leaking"
  /// ([EgressVerdict.leaked]).
  ///
  /// [probeUrls] overrides [defaultEgressProbeUrls] (remote-config gate
  /// settings); an empty list falls back to the built-ins.
  static Future<DeviceEgressResult> deviceExitDetailed({
    List<String>? probeUrls,
    Duration timeout = const Duration(seconds: 8),
    int attempts = 2,
  }) async {
    final urls = List<String>.from(
        (probeUrls == null || probeUrls.isEmpty)
            ? defaultEgressProbeUrls
            : probeUrls);
    // The IPv6 literal only when the machine has a global IPv6 address,
    // right after the IPv4 HTTPS literals so a working v4 tunnel wins.
    if (await _hasGlobalIpv6() &&
        !urls.any((u) => u.contains('2606:4700:4700::1111'))) {
      final at = urls.indexWhere((u) => u.startsWith('http://'));
      urls.insert(at == -1 ? urls.length : at, _ipv6EgressProbeUrl);
    }
    final log = <String>[];
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final url in urls) {
        final uri = Uri.tryParse(url);
        if (uri == null ||
            (uri.scheme != 'https' && uri.scheme != 'http')) {
          log.add('$url → skipped (not an http(s) URL)');
          continue;
        }
        try {
          final r = await _directGetUri(uri, timeout: timeout);
          final exit = traceExit(r.body);
          if (exit == null) {
            log.add('$url → no address in the answer');
            continue;
          }
          log.add('$url → ${exit.ip} '
              '(${exit.country.isEmpty ? '??' : exit.country})');
          return DeviceEgressResult(
            ip: exit.ip,
            country: exit.country,
            pingMs: r.pingMs,
            attempts: log,
          );
        } catch (e) {
          log.add('$url → $e');
        }
      }
    }
    return DeviceEgressResult(attempts: log);
  }

  /// True when an interface holds a global (non-link-local) IPv6 address.
  /// Best effort: any failure means "no IPv6" and the v6 probe is skipped.
  static Future<bool> _hasGlobalIpv6() async {
    try {
      final ifs = await NetworkInterface.list(
          includeLoopback: false, includeLinkLocal: false);
      for (final i in ifs) {
        for (final a in i.addresses) {
          if (a.type == InternetAddressType.IPv6) return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// `ip=`/`loc=` out of a Cloudflare trace body, or null when the body
  /// carries no usable address. Pure, so the parsing is unit-testable
  /// without a network.
  static ({String ip, String country})? traceExit(String body) {
    final map = parseTrace(body);
    final ip = (map['ip'] ?? '').trim();
    if (ip.isEmpty) return null;
    return (ip: ip, country: countryCode(map['loc'] ?? ''));
  }

  static Future<({String body, int pingMs})> _directGet(
    String host,
    String path, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final sw = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      // Never inherit a proxy: the point is to test the adapter itself.
      client.findProxy = (_) => 'DIRECT';
      final request =
          await client.getUrl(Uri.parse('http://$host$path')).timeout(timeout);
      request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      sw.stop();
      if (response.statusCode < 200 || response.statusCode >= 400) {
        throw SocketException('HTTP ${response.statusCode} via the TUN device');
      }
      return (body: body, pingMs: sw.elapsedMilliseconds);
    } finally {
      client.close(force: true);
    }
  }

  /// A direct GET (no proxy) against a full URL, https or http. Unlike
  /// [_directGet] it rejects 3xx: a redirect body (e.g. the 301 HTML
  /// `http://1.1.1.1/cdn-cgi/trace` answers) carries no trace address,
  /// so accepting it would silently measure nothing.
  static Future<({String body, int pingMs})> _directGetUri(
    Uri uri, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final sw = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      // Never inherit a proxy: the point is to test the adapter itself.
      client.findProxy = (_) => 'DIRECT';
      final request = await client.getUrl(uri).timeout(timeout);
      request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      sw.stop();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw SocketException('HTTP ${response.statusCode} from $uri');
      }
      return (body: body, pingMs: sw.elapsedMilliseconds);
    } finally {
      client.close(force: true);
    }
  }

  /// Cloudflare trace through the tunnel (ping + exit IP + colo).
  static Future<({String body, int pingMs})> cloudflareTrace({
    String host = '127.0.0.1',
    int port = 1819,
  }) async {
    final r = await httpGet(
      'www.cloudflare.com',
      '/cdn-cgi/trace',
      host: host,
      port: port,
      timeout: const Duration(seconds: 12),
    );
    return (body: r.body, pingMs: r.pingMs);
  }

  /// The public IP this machine shows **without** the tunnel, read on the raw
  /// interface — DHCP, carrier NAT and the ISP's own transparent proxies
  /// included.
  ///
  /// This is the counterpart of [exitInfo], and the only honest way to answer
  /// "is the VPN actually carrying my traffic?": when both report the same
  /// address, the traffic leaving the machine is the *line's*, not the exit's,
  /// and any "exit country" shown elsewhere is really the user's own.
  static Future<({String ip, String country, int pingMs})> rawInfo() async {
    Object? lastError;
    for (final target in _targets) {
      try {
        final sw = Stopwatch()..start();
        // Straight to the address, no SOCKS anywhere: this has to fail if the
        // line is filtered, because that is the answer we are after.
        final socket = await Socket.connect(target[0], 80,
            timeout: const Duration(seconds: 8));
        socket.setOption(SocketOption.tcpNoDelay, true);
        socket.write('GET ${target[1]} HTTP/1.0\r\n'
            'Host: ${target[0]}\r\n'
            'User-Agent: voidrau-probe\r\n\r\n');
        await socket.flush();
        final chunks = BytesBuilder();
        await for (final data in socket.timeout(const Duration(seconds: 8))) {
          chunks.add(data);
          if (chunks.length > 8192) break;
          final text = utf8.decode(chunks.toBytes(), allowMalformed: true);
          if (text.contains('\r\n\r\n') && text.length > 64) break;
        }
        socket.destroy();
        sw.stop();
        final body = utf8.decode(chunks.takeBytes(), allowMalformed: true);
        final trace = parseTrace(body);
        final ip = (trace['ip'] ?? '').trim();
        if (ip.isEmpty) {
          throw const SocketException('no address in the answer');
        }
        return (
          ip: ip,
          country: countryCode(trace['loc'] ?? ''),
          pingMs: sw.elapsedMilliseconds,
        );
      } catch (e) {
        lastError = e;
      }
    }
    throw SocketException('raw address lookup failed: $lastError');
  }

  /// Exit facts for the dashboard: the public IP the tunnel presents and the
  /// country that IP is registered in — this is the "VPN's own IP" the user
  /// sees after connecting.
  ///
  /// Cloudflare's trace answers both in one request; when it is unreachable or
  /// anonymised (Tor's `T1`, Cloudflare's `XX`), a plain-HTTP geo lookup goes
  /// through the same SOCKS listener so the card still has something to show.
  static Future<({String ip, String country, String colo, int pingMs})> exitInfo({
    String host = '127.0.0.1',
    int port = 1819,
  }) async {
    Object? lastError;
    try {
      final r = await httpGet(
        'www.cloudflare.com',
        '/cdn-cgi/trace',
        host: host,
        port: port,
        timeout: const Duration(seconds: 12),
      );
      final map = parseTrace(r.body);
      final ip = (map['ip'] ?? '').trim();
      final cc = countryCode(map['loc'] ?? '');
      if (ip.isNotEmpty && cc.isNotEmpty) {
        return (
          ip: ip,
          country: cc,
          colo: (map['colo'] ?? '').trim(),
          pingMs: r.pingMs,
        );
      }
      if (ip.isNotEmpty || cc.isNotEmpty) {
        // Partial answer: keep what we have and let the caller merge it.
        return (
          ip: ip,
          country: cc,
          colo: (map['colo'] ?? '').trim(),
          pingMs: r.pingMs,
        );
      }
      lastError = const SocketException('empty trace');
    } catch (e) {
      lastError = e;
    }
    try {
      final r = await httpGet(
        'ip-api.com',
        '/json/?fields=status,countryCode,query',
        host: host,
        port: port,
        timeout: const Duration(seconds: 10),
      );
      final json = jsonDecode(r.body) as Map<String, dynamic>;
      return (
        ip: '${json['query'] ?? ''}'.trim(),
        country: countryCode('${json['countryCode'] ?? ''}'),
        colo: '',
        pingMs: r.pingMs,
      );
    } catch (e) {
      lastError = e;
    }
    throw SocketException('exit lookup failed: $lastError');
  }

  /// Normalises a country code coming from a trace/geo API. Empty string means
  /// "unknown" — `XX` and `T1` are the anonymised placeholders the APIs use.
  static String countryCode(String raw) {
    final v = raw.trim().toUpperCase();
    if (v.length != 2) return '';
    if (v == 'XX' || v == 'T1' || v == 'A1' || v == 'A2') return '';
    if (!RegExp(r'^[A-Z]{2}$').hasMatch(v)) return '';
    return v;
  }

  /// One SOCKS5 CONNECT + HTTP/1.0 GET against `target:80`.
  static Future<({String body, int pingMs})> httpGet(
    String name,
    String path, {
    String host = '127.0.0.1',
    int port = 1819,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final sw = Stopwatch()..start();
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    final stash = <int>[];
    final iter = StreamIterator<List<int>>(socket);

    Future<Uint8List> readN(int n) async {
      while (stash.length < n) {
        if (!await iter.moveNext().timeout(timeout)) {
          throw const SocketException('SOCKS short read');
        }
        stash.addAll(iter.current);
      }
      final out = Uint8List.fromList(stash.take(n).toList());
      stash.removeRange(0, n);
      return out;
    }

    try {
      // Greeting: version 5, one method, no-auth.
      socket.add(Uint8List.fromList([0x05, 0x01, 0x00]));
      await socket.flush();
      final greet = await readN(2);
      if (greet[0] != 0x05 || greet[1] != 0x00) {
        throw const SocketException('SOCKS5 handshake failed');
      }
      final target = utf8.encode(name);
      final req = BytesBuilder()
        ..add([0x05, 0x01, 0x00, 0x03, target.length])
        ..add(target)
        ..add([0x00, 0x50]); // port 80, plain HTTP
      socket.add(req.toBytes());
      await socket.flush();
      final reply = await readN(4);
      if (reply[1] != 0x00) {
        throw SocketException('SOCKS connect status ${reply[1]}');
      }
      // Drain BND.ADDR per ATYP.
      if (reply[3] == 0x01) {
        await readN(6);
      } else if (reply[3] == 0x04) {
        await readN(18);
      } else if (reply[3] == 0x03) {
        final n = (await readN(1))[0];
        await readN(n + 2);
      }
      socket.add(utf8.encode(
        'GET $path HTTP/1.0\r\nHost: $name\r\nUser-Agent: voidrau-probe\r\n\r\n',
      ));
      await socket.flush();
      final chunks = BytesBuilder()..add(stash);
      stash.clear();
      var statusOk = false;
      while (await iter.moveNext().timeout(timeout)) {
        chunks.add(iter.current);
        final text = utf8.decode(chunks.toBytes(), allowMalformed: true);
        final headEnd = text.indexOf('\r\n\r\n');
        if (headEnd == -1 && chunks.length > 8192) break;
        if (headEnd != -1) {
          final statusLine = text.split('\r\n').first;
          statusOk = statusLine.startsWith('HTTP/') &&
              (statusLine.contains(' 200') ||
                  statusLine.contains(' 204') ||
                  statusLine.contains(' 301') ||
                  statusLine.contains(' 302'));
          final body = text.substring(headEnd + 4);
          if (statusOk &&
              (body.isNotEmpty ||
                  statusLine.contains(' 204') ||
                  chunks.length > 8192)) {
            break;
          }
          if (chunks.length > 16384) break;
        }
      }
      sw.stop();
      if (!statusOk) {
        throw const SocketException('no valid HTTP response through tunnel');
      }
      final text = utf8.decode(chunks.takeBytes(), allowMalformed: true);
      final headEnd = text.indexOf('\r\n\r\n');
      final body = headEnd == -1 ? text : text.substring(headEnd + 4);
      return (body: body, pingMs: sw.elapsedMilliseconds);
    } finally {
      await iter.cancel();
      socket.destroy();
    }
  }

  /// Fast SOCKS5 greeting check: true when the listener completes a
  /// method-selection handshake — not merely accepts TCP. A half-open or
  /// wedged listener passes a bare connect test and then publishes a tunnel
  /// that carries nothing.
  static Future<bool> handshake({
    String host = '127.0.0.1',
    int port = 1819,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      socket.add(Uint8List.fromList([0x05, 0x01, 0x00]));
      await socket.flush();
      final data = await socket.first.timeout(timeout);
      return data.length >= 2 && data[0] == 0x05 && data[1] == 0x00;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  /// One `key=value` per line, which is what a Cloudflare trace is. Everything
  /// around the two lines we need is tolerated: a proxy may append its own
  /// lines, and an anonymised exit reports `loc=XX`.
  static Map<String, String> parseTrace(String body) {
    final map = <String, String>{};
    for (final line in body.split(RegExp(r'\r?\n'))) {
      final i = line.indexOf('=');
      if (i > 0) map[line.substring(0, i)] = line.substring(i + 1);
    }
    return map;
  }
}

/// Verdict of comparing the device path's egress against the tunnel's.
///
/// The SOCKS probe ([SocksProbe.exitInfo]) only ever proves the *listener*
/// exits where the UI says. The device path (TUN adapter + routes, or the
/// system proxy) is a separate mechanism that can fail independently —
/// a default route that loses the metric race, a proxy write that never
/// landed — while every SOCKS probe stays green. This is the comparison
/// that closes that gap: device traffic must demonstrably leave through
/// the tunnel before "connected" is claimed.
enum EgressVerdict {
  /// Device egress == tunnel exit: the same exit the UI displays.
  verified,

  /// Device egress is not the raw line address (tunneled), but differs
  /// from the probed exit — an exit pool (Tor circuits, anycast) handing
  /// out more than one address. Protected, worth a log line.
  tunneled,

  /// Device egress == the raw line address: traffic bypasses the tunnel.
  leaked,

  /// No probe could run at all — nothing was measured. Not a leak and
  /// not a verification: the tunnel stays up with an explicit
  /// "unverified" state instead of being torn down for a measurement
  /// failure (the v1.9.0 gate killed healthy tunnels this way when DNS
  /// answered WSANO_DATA on a filtered line).
  probeFailed,

  /// Not enough measurements to tell. Unverified capture must not be
  /// published as connected.
  unknown,
}

/// The outcome of [SocksProbe.deviceExitDetailed]: the measured egress
/// when a probe answered, plus one line per probe tried, in order —
/// what the Diagnostics log shows when nothing could be measured.
class DeviceEgressResult {
  const DeviceEgressResult({
    this.ip,
    this.country = '',
    this.pingMs,
    this.attempts = const [],
  });

  final String? ip;
  final String country;
  final int? pingMs;
  final List<String> attempts;
}

class EgressCheck {
  /// [deviceIp] is the egress measured on the device path itself
  /// ([SocksProbe.deviceExit]); [tunnelIp] the exit measured through the
  /// device-traffic SOCKS listener ([SocksProbe.exitInfo] on the device
  /// port); [rawIp] the line's own address measured *before* any capture
  /// was installed ([SocksProbe.rawInfo]). Either reference may be null
  /// when its lookup failed.
  static EgressVerdict evaluate({
    required String deviceIp,
    String? tunnelIp,
    String? rawIp,
  }) {
    final device = deviceIp.trim();
    if (device.isEmpty) return EgressVerdict.unknown;
    final raw = (rawIp ?? '').trim();
    final tunnel = (tunnelIp ?? '').trim();
    // Addresses of different families cannot be compared: a v6 device
    // egress next to v4 tunnel/raw references proves nothing either way
    // (a v6 leak must be judged against a v6 reference, not a v4 one).
    final deviceV6 = device.contains(':');
    bool sameFamily(String ref) =>
        ref.isEmpty || ref.contains(':') == deviceV6;
    // A device egress equal to the line's own address is a leak even when
    // it also equals the probed exit (that only happens when the "tunnel"
    // itself exits via the user's address, which no Windows Aether mode
    // does) — so the leak test runs first.
    if (raw.isNotEmpty && sameFamily(raw) && device == raw) {
      return EgressVerdict.leaked;
    }
    if (tunnel.isNotEmpty && sameFamily(tunnel) && device == tunnel) {
      return EgressVerdict.verified;
    }
    if (raw.isNotEmpty && sameFamily(raw)) return EgressVerdict.tunneled;
    return EgressVerdict.unknown;
  }

  /// True when the device path is proven to leave through the tunnel.
  static bool ok(EgressVerdict v) =>
      v == EgressVerdict.verified || v == EgressVerdict.tunneled;
}
