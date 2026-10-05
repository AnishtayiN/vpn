import Foundation

// Standalone executable: exercises the same validator linked by BOTH targets,
// without needing Flutter, signing, an iPhone or a NetworkExtension entitlement.
@main
enum ConfigurationTests {
    static func main() throws {
        let valid: [String: Any] = [
            "mode": "vpn", "splitMode": "off", "lanShare": false,
            "socksPort": 1819, "tunMtu": 1360, "protocol": "masque",
            "env": ["AETHER_PROTOCOL=masque", "AETHER_CONFIG=aether.toml", "AETHER_SOCKS=0.0.0.0:9999"],
            "killSwitch": true, "bypassLan": false
        ]
        let config = try TunnelConfiguration(valid)
        precondition(config.environment["AETHER_SOCKS"] == "127.0.0.1:1819")
        precondition(config.killSwitch && !config.bypassLAN)
        let invalid: [(String, Any)] = [
            ("mode", "proxy"), ("lanShare", true), ("splitMode", "include"),
            ("socksPort", 0), ("socksPort", 65536), ("socksPort", "1819"),
            ("tunMtu", 1279), ("tunMtu", 9000), ("protocol", "unknown"),
            ("env", ["LD_PRELOAD=evil"]), ("env", ["AETHER_PEER=bad\0peer"]),
            ("env", ["AETHER_PEER"])
        ]
        for (key, value) in invalid {
            var input = valid
            input[key] = value
            precondition((try? TunnelConfiguration(input)) == nil, "Accepted invalid \(key)")
        }
        for name in ["masque", "wg", "gool", "mim"] {
            var input = valid
            input["protocol"] = name
            let parsed = try TunnelConfiguration(input)
            precondition(parsed.environment["AETHER_PROTOCOL"] == name)
        }
        print("iOS shared configuration: all checks passed")
    }
}
