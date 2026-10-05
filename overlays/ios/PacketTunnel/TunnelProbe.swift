import Foundation
import Network

/// Bounded SOCKS5 + HTTP proof. Does not mistake a listening port for a working
/// tunnel. All remote DNS is performed by the SOCKS core.
final class TunnelProbe {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var completion: ((Bool) -> Void)?
    private var timer: DispatchWorkItem?

    init(port: Int, queue: DispatchQueue) {
        self.queue = queue
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
    }

    func run(_ completion: @escaping (Bool) -> Void) {
        self.completion = completion
        let timeout = DispatchWorkItem { [weak self] in self?.finish(false) }
        timer = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.send(Data([5, 1, 0])) {
                    self.read(2) { bytes in
                        guard bytes == Data([5, 0]) else { self.finish(false); return }
                        let host = Array("www.cloudflare.com".utf8)
                        self.send(Data([5, 1, 0, 3, UInt8(host.count)] + host + [0, 80])) {
                            self.read(4) { header in
                                guard header[0] == 5, header[1] == 0 else { self.finish(false); return }
                                switch header[3] {
                                case 1: self.consumeAddress(6)
                                case 4: self.consumeAddress(18)
                                case 3: self.read(1) { self.consumeAddress(Int($0[0]) + 2) }
                                default: self.finish(false)
                                }
                            }
                        }
                    }
                }
            case .failed, .cancelled: self.finish(false)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func consumeAddress(_ count: Int) {
        read(count) { _ in
            let request = "GET /cdn-cgi/trace HTTP/1.1\r\nHost: www.cloudflare.com\r\nConnection: close\r\n\r\n"
            self.send(Data(request.utf8)) {
                self.read(12) { header in
                    let text = String(decoding: header, as: UTF8.self)
                    self.finish(text.hasPrefix("HTTP/1.1 200") || text.hasPrefix("HTTP/1.0 200"))
                }
            }
        }
    }

    private func send(_ data: Data, then: @escaping () -> Void) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self = self, self.completion != nil else { return }
            if error != nil { self.finish(false) } else { then() }
        })
    }

    private func read(_ count: Int, accumulated: Data = Data(), then: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: count - accumulated.count) { [weak self] data, _, complete, error in
            guard let self = self, self.completion != nil else { return }
            var bytes = accumulated
            if let data = data { bytes.append(data) }
            if bytes.count == count { then(bytes) }
            else if complete || error != nil { self.finish(false) }
            else { self.read(count, accumulated: bytes, then: then) }
        }
    }

    func cancel() { finish(false) }

    private func finish(_ success: Bool) {
        guard let completion = completion else { return }
        self.completion = nil
        timer?.cancel()
        timer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        completion(success)
    }
}
