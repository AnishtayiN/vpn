import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let control = DispatchQueue(label: "pm.dnschanger.voidrau.control")
    private let worker = DispatchQueue(label: "pm.dnschanger.voidrau.hev", qos: .userInitiated)
    private var pump: PacketPump?
    private var bridgeRunning = false
    private var stopping = false
    private var monitor: DispatchSourceTimer?
    private var probe: TunnelProbe?
    private var startReply: ((Error?) -> Void)?
    private var stopReply: (() -> Void)?
    private var config: TunnelConfiguration?
    private var phase = "disconnected"
    private var message = ""
    private var deadline = Date()
    private var generation = 0

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        control.async {
            guard self.phase == "disconnected", !self.bridgeRunning else {
                completionHandler(TunnelFailure.message("Tunnel already active")); return
            }
            self.startReply = completionHandler
            self.stopping = false
            self.generation += 1
            let generation = self.generation
            do {
                guard let proto = self.protocolConfiguration as? NETunnelProviderProtocol,
                      let values = proto.providerConfiguration else {
                    throw TunnelFailure.message("Missing VPN configuration")
                }
                let config = try TunnelConfiguration(values)
                self.config = config
                var root = try FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                     ofItemAtPath: root.path)
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = true
                try root.setResourceValues(resourceValues)
                var env = config.environment
                env["AETHER_CONFIG"] = root.appendingPathComponent("aether.toml").path
                let json = try JSONSerialization.data(withJSONObject: env)
                let rc = String(decoding: json, as: UTF8.self).withCString { voidrau_core_start($0) }
                guard rc == 0 else { throw TunnelFailure.message(self.coreError()) }
                self.phase = "connecting"
                self.message = "Scanning and proving the tunnel…"
                self.deadline = Date().addingTimeInterval(195)
                let timer = DispatchSource.makeTimerSource(queue: self.control)
                timer.schedule(deadline: .now(), repeating: 1)
                timer.setEventHandler { [weak self] in self?.tick(generation: generation) }
                self.monitor = timer
                timer.resume()
            } catch { self.fail(error) }
        }
    }

    private func coreError() -> String {
        guard let ptr = voidrau_core_error() else { return "Unknown core failure" }
        defer { voidrau_core_string_free(ptr) }
        return String(cString: ptr)
    }

    private func tick(generation: Int) {
        guard !stopping, self.generation == generation else { return }
        let error = coreError()
        if !error.isEmpty { fail(TunnelFailure.message(error)); return }
        guard phase == "connecting", probe == nil, let config = config else { return }
        if Date() > deadline { fail(TunnelFailure.message("Tunnel readiness timed out")); return }
        let probe = TunnelProbe(port: config.port, queue: control)
        self.probe = probe
        probe.run { [weak self] success in
            guard let self = self else { return }
            self.probe = nil
            guard !self.stopping, self.generation == generation, success else { return }
            self.phase = "preparing"
            self.installNetwork(config, generation: generation)
        }
    }

    private func installNetwork(_ config: TunnelConfiguration, generation: Int) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: config.mtu)
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        if config.bypassLAN {
            ipv4.excludedRoutes = [
                NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
                NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
                NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0")
            ]
        }
        settings.ipv4Settings = ipv4
        // Capture IPv6 even when disabled: discard it in the pump rather than
        // leaking it through the underlying interface.
        let ipv6 = NEIPv6Settings(addresses: ["fd00:1819::1"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6
        let dns = NEDNSSettings(servers: ["1.1.1.1", "1.0.0.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        setTunnelNetworkSettings(settings) { error in
            self.control.async {
                guard !self.stopping, self.generation == generation else { return }
                if let error = error { self.fail(error); return }
                do {
                    let pump = PacketPump(flow: self.packetFlow)
                    try pump.start(forwardIPv6: config.values["ipv6Tunnel"] as? Bool ?? false)
                    self.pump = pump
                    let yaml = """
                    tunnel:
                      mtu: \(config.mtu)
                      ipv4: 198.18.0.1
                      ipv6: 'fd00:1819::1'
                    socks5:
                      address: 127.0.0.1
                      port: \(config.port)
                      udp: udp
                    misc:
                      task-stack-size: 24576
                      tcp-buffer-size: 16384
                      max-session-count: 128
                      log-level: warn
                    """
                    self.bridgeRunning = true
                    let fd = pump.engineSocket
                    self.worker.async {
                        let bytes = Array(yaml.utf8)
                        let rc = bytes.withUnsafeBufferPointer {
                            hev_socks5_tunnel_main_from_str($0.baseAddress, UInt32($0.count), fd)
                        }
                        self.control.async {
                            self.bridgeRunning = false
                            if self.stopping { self.finishStop() }
                            else { self.fail(TunnelFailure.message("Packet bridge exited (\(rc))")) }
                        }
                    }
                    self.phase = "connected"
                    self.message = "iOS packet tunnel active"
                    let reply = self.startReply
                    self.startReply = nil
                    reply?(nil)
                } catch { self.fail(error) }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        control.async {
            self.stopReply = completionHandler
            self.beginStop()
        }
    }

    private func fail(_ error: Error) {
        message = error.localizedDescription
        phase = "error"
        let reply = startReply
        startReply = nil
        reply?(error)
        beginStop()
        cancelTunnelWithError(error)
    }

    private func beginStop() {
        stopping = true
        generation += 1
        monitor?.cancel()
        monitor = nil
        probe?.cancel()
        probe = nil
        let reply = startReply
        startReply = nil
        reply?(TunnelFailure.message("Connection cancelled"))
        // quit is safe even during HEV initialization (upstream SYNC_STOP).
        if bridgeRunning { hev_socks5_tunnel_quit() }
        else { finishStop() }
    }

    private func finishStop() {
        pump?.stop()
        pump = nil
        voidrau_core_stop()
        phase = "disconnected"
        let reply = stopReply
        stopReply = nil
        reply?()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        control.async {
            var txPackets = 0, txBytes = 0, rxPackets = 0, rxBytes = 0
            if self.bridgeRunning && !self.stopping {
                hev_socks5_tunnel_stats(&txPackets, &txBytes, &rxPackets, &rxBytes)
            }
            let status: [String: Any] = [
                "type": "status", "phase": self.phase, "message": self.message,
                "protocol": self.config?.protocolName ?? "",
                "endpoint": self.config?.values["endpoint"] as? String ?? "",
                "download": rxBytes, "upload": txBytes
            ]
            completionHandler?(try? JSONSerialization.data(withJSONObject: status))
        }
    }
}
