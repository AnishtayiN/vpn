import Foundation

struct TunnelConfiguration {
    let values: [String: Any]
    let environment: [String: String]
    let port: Int
    let mtu: Int
    let protocolName: String
    let bypassLAN: Bool
    let killSwitch: Bool

    init(_ values: [String: Any]) throws {
        guard values["mode"] as? String == "vpn",
              values["lanShare"] as? Bool != true,
              values["splitMode"] as? String == "off",
              let port = values["socksPort"] as? Int, (1024...65535).contains(port),
              let mtu = values["tunMtu"] as? Int, (1280...1500).contains(mtu),
              let proto = values["protocol"] as? String,
              ["masque", "wg", "gool", "mim"].contains(proto),
              let lines = values["env"] as? [String] else {
            throw TunnelFailure.message("Invalid or unsupported iOS VPN configuration")
        }
        // Every key Aether 2.1.0 understands. The app's own policy decides what
        // an iOS tunnel may actually ask for (no Psiphon/Tor binaries ship in
        // the bundle, so chains stay off and their keys are never produced),
        // while the native shim pins the profile and the netstack buffers to
        // values that fit an extension's memory budget.
        let allowed: Set<String> = [
            "AETHER_PROTOCOL", "AETHER_SCAN", "AETHER_IP", "AETHER_NOIZE",
            "AETHER_SOCKS", "AETHER_CONFIG", "AETHER_QUICK_RECONNECT",
            "AETHER_LOG_LEVEL", "AETHER_MASQUE_HTTP2", "AETHER_MASQUE_MTU",
            "AETHER_MASQUE_H2_FRAGMENT", "AETHER_WG_KEEPALIVE", "AETHER_PEER", "AETHER_WG_PEER",
            "AETHER_STATS", "AETHER_STATS_SECS",
            "AETHER_PERF_PROFILE", "AETHER_NETSTACK_TCP_RX", "AETHER_NETSTACK_TCP_TX",
            "AETHER_TCP_CONNECT_SECS", "AETHER_TCP_KEEPALIVE_SECS", "AETHER_HALF_CLOSE_SECS",
            "AETHER_QUIC_V2", "AETHER_ECH",
            "AETHER_EXIT_LOC", "AETHER_EXIT_LOC_SECS",
            "AETHER_ROUTE_DIRECT", "AETHER_ROUTE_BLOCK",
            "AETHER_HTTP_PROXY",
            "AETHER_PSIPHON", "AETHER_PSIPHON_REGION", "AETHER_PSIPHON_MODE",
            "AETHER_PSIPHON_HTTP", "AETHER_PSIPHON_BIND", "AETHER_PSIPHON_DIR",
            "AETHER_TOR", "AETHER_TOR_COUNTRY", "AETHER_TOR_HTTP",
            "AETHER_TOR_BIND", "AETHER_TOR_DIR"
        ]
        var env: [String: String] = [:]
        for line in lines {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, allowed.contains(String(pair[0])), !line.contains("\0") else {
                throw TunnelFailure.message("Invalid core configuration key")
            }
            env[String(pair[0])] = String(pair[1])
        }
        env["AETHER_SOCKS"] = "127.0.0.1:\(port)"
        env["AETHER_PROTOCOL"] = proto
        self.values = values
        environment = env
        self.port = port
        self.mtu = mtu
        protocolName = proto
        bypassLAN = values["bypassLan"] as? Bool ?? false
        killSwitch = values["killSwitch"] as? Bool ?? true
    }
}

enum TunnelFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
