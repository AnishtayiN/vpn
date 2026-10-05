import Flutter
import NetworkExtension
import UIKit

/// All manager mutations are serialized on the main queue. Reload after every
/// save, as required by NetworkExtension; never start a stale preference object.
final class VPNPlugin: NSObject, FlutterStreamHandler {
    private var manager: NETunnelProviderManager?
    private var sink: FlutterEventSink?
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var changing = false
    private var wanted = false
    private var lastError = ""
    private var providerID: String { Bundle.main.bundleIdentifier! + ".PacketTunnel" }

    init(messenger: FlutterBinaryMessenger) {
        super.init()
        let methods = FlutterMethodChannel(name: "nimbus.vpn/engine", binaryMessenger: messenger)
        methods.setMethodCallHandler { [weak self] call, reply in
            self?.handle(call, reply: reply)
        }
        FlutterEventChannel(name: "nimbus.vpn/events", binaryMessenger: messenger).setStreamHandler(self)
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange,
                                                         object: nil, queue: .main) { [weak self] _ in
            self?.publish()
        }
        load { _ in }
    }

    private func load(_ completion: @escaping (Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            DispatchQueue.main.async {
                if error == nil {
                    self.manager = managers?.first {
                        ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.providerID
                    }
                }
                completion(error)
            }
        }
    }

    private func handle(_ call: FlutterMethodCall, reply: @escaping FlutterResult) {
        switch call.method {
        case "prepareVpn":
            if UserDefaults.standard.bool(forKey: "vpnDisclosureAccepted") { reply(true); return }
            guard let presenter = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow })?.rootViewController else {
                reply(failure("Cannot display VPN consent")); return
            }
            let fa = Locale.preferredLanguages.first?.hasPrefix("fa") == true
            let text = fa
                ? "ترافیک دستگاه از طریق تونل Cloudflare WARP منتقل می‌شود. آدرس IP و درخواست‌های اتصال برای سرویس‌دهنده قابل مشاهده است. بررسی اتصال و IP با سرویس‌های عمومی انجام می‌شود؛ گزارش‌ها محلی هستند مگر خودتان به اشتراک بگذارید. این سرویس با Cloudflare وابستگی رسمی ندارد. ادامه می‌دهید؟"
                : "Device traffic is routed through Cloudflare WARP. Your IP and connection requests are visible to that provider. Connectivity and exit-IP checks contact public services. Diagnostics stay on-device unless you share them. This app is not affiliated with Cloudflare. Continue?"
            let alert = UIAlertController(title: "VoidrauVPN", message: text, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: fa ? "لغو" : "Cancel", style: .cancel) { _ in reply(false) })
            alert.addAction(UIAlertAction(title: fa ? "ادامه" : "Continue", style: .default) { _ in
                UserDefaults.standard.set(true, forKey: "vpnDisclosureAccepted")
                reply(true)
            })
            presenter.present(alert, animated: true)
        case "start":
            guard !changing else { reply(failure("VPN preferences are busy")); return }
            guard let values = call.arguments as? [String: Any] else { reply(failure("Missing configuration")); return }
            do { _ = try TunnelConfiguration(values) }
            catch { reply(failure(error.localizedDescription)); return }
            changing = true
            load { error in
                if let error = error { self.changing = false; reply(self.failure(error.localizedDescription)); return }
                let manager = self.manager ?? NETunnelProviderManager()
                if [.connected, .connecting, .reasserting, .disconnecting].contains(manager.connection.status) {
                    self.changing = false
                    reply(self.failure("Stop the current tunnel before starting another")); return
                }
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = self.providerID
                proto.serverAddress = "VoidrauVPN"
                proto.providerConfiguration = values
                proto.disconnectOnSleep = false
                proto.includeAllNetworks = values["killSwitch"] as? Bool ?? false
                proto.excludeLocalNetworks = values["bypassLan"] as? Bool ?? false
                manager.protocolConfiguration = proto
                manager.localizedDescription = "VoidrauVPN"
                manager.isEnabled = true
                // Only explicit user connection starts a session. No perpetual
                // on-demand rule that would undo a user's manual disconnect.
                manager.isOnDemandEnabled = false
                manager.saveToPreferences { error in
                    DispatchQueue.main.async {
                        if let error = error { self.changing = false; reply(self.failure(error.localizedDescription)); return }
                        manager.loadFromPreferences { error in
                            DispatchQueue.main.async {
                                self.changing = false
                                if let error = error { reply(self.failure(error.localizedDescription)); return }
                                self.manager = manager
                                self.lastError = ""
                                do {
                                    guard let session = manager.connection as? NETunnelProviderSession else {
                                        throw TunnelFailure.message("No packet tunnel session")
                                    }
                                    try session.startTunnel()
                                    self.wanted = true
                                    reply(nil)
                                } catch { reply(self.failure(error.localizedDescription)) }
                            }
                        }
                    }
                }
            }
        case "stop", "recover":
            guard !changing else { reply(failure("VPN preferences are busy")); return }
            wanted = false
            lastError = ""
            guard let manager = manager else { reply(nil); return }
            manager.connection.stopVPNTunnel()
            // Wait for OS teardown so the protocol fallback doesn't race the
            // old extension's sockets. Surface a timeout instead of pretending.
            waitStopped(manager, deadline: Date().addingTimeInterval(15), reply: reply)
        case "status":
            if manager == nil { load { error in
                if let error = error { reply(self.failure(error.localizedDescription)) }
                else { self.status(reply) }
            } } else { status(reply) }
        case "openVpnSettings":
            // There is no public URL to the VPN pane. Open this app's Settings.
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            reply(nil)
        case "listApps": reply([])
        default: reply(FlutterMethodNotImplemented)
        }
    }

    private func waitStopped(_ manager: NETunnelProviderManager, deadline: Date, reply: @escaping FlutterResult) {
        if [.disconnected, .invalid].contains(manager.connection.status) { reply(nil); return }
        if Date() >= deadline { reply(failure("iOS VPN teardown timed out")); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.waitStopped(manager, deadline: deadline, reply: reply) }
    }

    private func failure(_ text: String) -> FlutterError {
        lastError = text
        return FlutterError(code: "ios_vpn", message: text, details: nil)
    }

    private func status(_ reply: @escaping FlutterResult) {
        guard let manager = manager else {
            reply(["type": "status", "phase": "disconnected"]); return
        }
        var phase: String
        switch manager.connection.status {
        case .connected: phase = "connected"
        case .connecting: phase = "connecting"
        case .reasserting: phase = "connecting"
        case .disconnecting: phase = "disconnecting"
        default: phase = wanted || !lastError.isEmpty ? "error" : "disconnected"
        }
        let config = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        let fallback: [String: Any] = ["type": "status", "phase": phase,
            "message": lastError.isEmpty && phase == "error" ? "iOS tunnel disconnected; inspect device VPN logs" : lastError,
            "protocol": config["protocol"] as? String ?? "",
            "socksPort": config["socksPort"] as? Int ?? 1819,
            "connectedAt": Int64((manager.connection.connectedDate?.timeIntervalSince1970 ?? 0) * 1000)]
        guard manager.connection.status == .connected,
              let session = manager.connection as? NETunnelProviderSession else { reply(fallback); return }
        var answered = false
        let once: (Any?) -> Void = { value in
            guard !answered else { return }
            answered = true
            reply(value)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { once(fallback) }
        do {
            try session.sendProviderMessage(Data("status".utf8)) { data in
                DispatchQueue.main.async {
                    guard let data = data,
                          var result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                        once(fallback); return
                    }
                    result["socksPort"] = config["socksPort"]
                    result["connectedAt"] = fallback["connectedAt"]
                    once(result)
                }
            }
        } catch { once(fallback) }
    }

    private func publish() {
        guard sink != nil else { return }
        if wanted, manager?.connection.status == .disconnected {
            manager?.connection.fetchLastDisconnectError { [weak self] error in
                DispatchQueue.main.async {
                    guard self?.manager?.connection.status == .disconnected else { return }
                    if let error = error { self?.lastError = error.localizedDescription }
                    else { self?.wanted = false; self?.lastError = "" }
                    self?.status { [weak self] value in self?.sink?(value) }
                }
            }
        } else { status { [weak self] value in self?.sink?(value) } }
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        load { _ in self.publish() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.publish() }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        timer?.invalidate()
        timer = nil
        return nil
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        timer?.invalidate()
    }
}
