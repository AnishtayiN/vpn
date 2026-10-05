package pm.dnschanger.nimbus

import android.util.Log
import java.io.DataInputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Authenticated SOCKS5 on the LAN that relays to the tunnel core on
 * loopback.
 * Matches Aethon: the core stays on 127.0.0.1 without auth.
 */
class LanProxyServer {
    private val workers = Executors.newCachedThreadPool()
    private val clients = ConcurrentHashMap.newKeySet<Socket>()
    private val active = AtomicInteger()
    private val random = SecureRandom()
    @Volatile private var server: ServerSocket? = null
    @Volatile var address: String = ""
        private set
    @Volatile var port: Int = 0
        private set
    @Volatile var username: String = ""
        private set
    @Volatile var password: String = ""
        private set
    @Volatile private var upstreamHost = "127.0.0.1"
    @Volatile private var upstreamPort = 1819

    @Synchronized
    fun start(requestedPort: Int, upstreamHost: String, upstreamPort: Int): Boolean {
        if (server != null) return true
        return try {
            val local = localAddress() ?: return false
            if (!local.isSiteLocalAddress) return false
            val socket = ServerSocket(requestedPort, 16, local)
            this.upstreamHost = upstreamHost
            this.upstreamPort = upstreamPort
            username = "voidrau-" + hex(4)
            password = hex(16)
            server = socket
            address = local.hostAddress ?: ""
            port = socket.localPort
            workers.execute { accept(socket) }
            true
        } catch (e: Exception) {
            Log.w(TAG, "LAN proxy failed", e)
            false
        }
    }

    @Synchronized
    fun stop() {
        val socket = server
        server = null
        address = ""
        port = 0
        username = ""
        password = ""
        try {
            socket?.close()
        } catch (_: Exception) {
        }
        for (c in clients) {
            try {
                c.close()
            } catch (_: Exception) {
            }
        }
        clients.clear()
        active.set(0)
    }

    private fun accept(socket: ServerSocket) {
        while (server === socket) {
            var client: Socket? = null
            try {
                client = socket.accept()
                if (!client.inetAddress.isSiteLocalAddress) {
                    client.close()
                    continue
                }
                if (active.get() >= MAX_CLIENTS) {
                    client.close()
                    continue
                }
                active.incrementAndGet()
                clients.add(client)
                val accepted = client
                workers.execute { relay(accepted) }
            } catch (e: Exception) {
                try {
                    client?.close()
                } catch (_: Exception) {
                }
                if (server === socket) Log.w(TAG, "LAN accept", e)
            }
        }
    }

    private fun relay(client: Socket) {
        var upstream: Socket? = null
        try {
            client.soTimeout = HANDSHAKE
            client.tcpNoDelay = true
            if (!authenticate(client)) return
            upstream = Socket()
            upstream.tcpNoDelay = true
            upstream.connect(java.net.InetSocketAddress(upstreamHost, upstreamPort), 15_000)
            upstream.soTimeout = HANDSHAKE
            if (!greetUpstream(upstream)) return
            // Handshake timeouts must not govern the live relay: an idle but
            // legitimate connection (SSH, keep-alive-less app) would otherwise
            // be killed after RELAY ms. A blocking read after the handshake
            // stays blocking until the peer closes it.
            client.soTimeout = 0
            upstream.soTimeout = 0
            val peer = upstream
            val up = Thread({ copy(client, peer) }, "lan-up")
            val down = Thread({ copy(peer, client) }, "lan-down")
            up.start()
            down.start()
            up.join()
            down.join()
        } catch (_: Exception) {
        } finally {
            try {
                upstream?.close()
            } catch (_: Exception) {
            }
            try {
                client.close()
            } catch (_: Exception) {
            }
            clients.remove(client)
            active.decrementAndGet()
        }
    }

    private fun authenticate(client: Socket): Boolean {
        val input = DataInputStream(client.getInputStream())
        val output = client.getOutputStream()
        if (input.readByte() != SOCKS) return false
        val n = input.readUnsignedByte()
        if (n <= 0) return false
        val methods = ByteArray(n)
        input.readFully(methods)
        if (!methods.contains(AUTH_USER)) {
            output.write(byteArrayOf(SOCKS, 0xff.toByte()))
            output.flush()
            return false
        }
        output.write(byteArrayOf(SOCKS, AUTH_USER))
        output.flush()
        if (input.readByte() != 0x01.toByte()) return false
        val user = ByteArray(input.readUnsignedByte())
        input.readFully(user)
        val secret = ByteArray(input.readUnsignedByte())
        input.readFully(secret)
        val ok = MessageDigest.isEqual(String(user).toByteArray(), username.toByteArray()) &&
            MessageDigest.isEqual(secret, password.toByteArray())
        output.write(byteArrayOf(0x01, if (ok) 0x00 else 0x01))
        output.flush()
        return ok
    }

    private fun greetUpstream(upstream: Socket): Boolean {
        val out = upstream.getOutputStream()
        val input = DataInputStream(upstream.getInputStream())
        out.write(byteArrayOf(SOCKS, 0x01, 0x00))
        out.flush()
        val ver = input.readByte()
        val method = input.readByte()
        return ver == SOCKS && method == 0x00.toByte()
    }

    private fun copy(from: Socket, to: Socket) {
        try {
            val buf = ByteArray(16 * 1024)
            val input: InputStream = from.getInputStream()
            val output: OutputStream = to.getOutputStream()
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                output.write(buf, 0, n)
                output.flush()
            }
        } catch (_: Exception) {
        } finally {
            try {
                to.shutdownOutput()
            } catch (_: Exception) {
            }
        }
    }

    private fun hex(n: Int): String {
        val bytes = ByteArray(n)
        random.nextBytes(bytes)
        return bytes.joinToString("") { b -> "%02x".format(b) }
    }

    companion object {
        private const val TAG = "VoidrauLan"
        private const val MAX_CLIENTS = 24
        private const val RELAY = 300_000
        private const val HANDSHAKE = 10_000
        private const val SOCKS: Byte = 0x05
        private const val AUTH_USER: Byte = 0x02

        fun localAddress(): InetAddress? {
            for (nic in Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!nic.isUp || nic.isLoopback) continue
                for (addr in Collections.list(nic.inetAddresses)) {
                    if (addr is Inet4Address && addr.isSiteLocalAddress) return addr
                }
            }
            return null
        }
    }
}
