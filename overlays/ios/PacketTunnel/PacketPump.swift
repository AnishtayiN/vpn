import Darwin
import Foundation
import NetworkExtension

/// Public NEPacketTunnelFlow API only. HEV receives a socketpair endpoint with
/// Darwin's 4-byte address-family framing, not a private/KVC utun descriptor.
final class PacketPump {
    private let flow: NEPacketTunnelFlow
    private let queue = DispatchQueue(label: "pm.dnschanger.voidrau.packets")
    private var source: DispatchSourceRead?
    private var socket: Int32 = -1
    private var active = false
    private var forwardIPv6 = false
    private(set) var engineSocket: Int32 = -1

    init(flow: NEPacketTunnelFlow) { self.flow = flow }

    func start(forwardIPv6: Bool) throws {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair) == 0 else {
            throw TunnelFailure.message("Cannot create packet socketpair: \(errno)")
        }
        for fd in pair {
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var size: Int32 = 256 * 1024
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        socket = pair[0]
        engineSocket = pair[1]
        self.forwardIPv6 = forwardIPv6
        active = true
        let reader = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        reader.setEventHandler { [weak self] in self?.drain() }
        // Closing on cancellation avoids descriptor-reuse races with drain().
        let fd = socket
        reader.setCancelHandler { close(fd) }
        source = reader
        reader.resume()
        queue.async { self.readPackets() }
    }

    private func readPackets() {
        guard active else { return }
        flow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            self.queue.async {
                guard self.active else { return }
                for (packet, proto) in zip(packets, protocols) {
                    guard proto.int32Value == AF_INET ||
                            (self.forwardIPv6 && proto.int32Value == AF_INET6) else { continue }
                    var family = proto.uint32Value.bigEndian
                    var frame = Data(bytes: &family, count: 4)
                    frame.append(packet)
                    // Nonblocking, bounded memory: packet loss under pressure is
                    // preferable to blocking the provider or unbounded queues.
                    frame.withUnsafeBytes { ptr in
                        _ = send(self.socket, ptr.baseAddress, ptr.count, 0)
                    }
                }
                self.readPackets()
            }
        }
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 65540)
        while active {
            let count = recv(socket, &buffer, buffer.count, 0)
            if count <= 4 { return }
            let family = buffer[4] >> 4 == 6 ? AF_INET6 : AF_INET
            if family == AF_INET6 && !forwardIPv6 { continue }
            flow.writePackets([Data(buffer[4..<count])], withProtocols: [NSNumber(value: family)])
        }
    }

    // Call only after the HEV worker has returned. HEV doesn't own an externally
    // supplied fd (hev_socks5_tunnel_fini closes only fds it opened itself).
    func stop() {
        queue.sync {
            active = false
            source?.cancel()
            source = nil
            socket = -1
            if engineSocket >= 0 { close(engineSocket); engineSocket = -1 }
        }
    }
}
