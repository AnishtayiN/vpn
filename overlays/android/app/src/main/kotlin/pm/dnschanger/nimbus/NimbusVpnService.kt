package pm.dnschanger.nimbus

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import hev.htproxy.TProxyService
import java.io.BufferedReader
import java.io.File
import java.io.FileWriter
import java.io.InputStreamReader
import java.net.InetSocketAddress
import java.net.Socket
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Device VPN / local SOCKS harness around the Tunnel core.
 *
 * Lifecycle is deliberately staged:
 *
 *  1. stale cores from an older session are reaped — one wedged instance that
 *     still owns :1819 used to make every later Connect report "connected"
 *     against a core that carries nothing;
 *  2. the core is configured through environment variables only;
 *  3. readiness means a real SOCKS5 method-selection handshake, not a bare
 *     TCP accept;
 *  4. MASQUE HTTP/3 gets a short primary window and then falls back to the
 *     HTTP/2 carrier, because networks that drop QUIC only pass TCP 443;
 *  5. "connected" is only published after a real HTTP request completes
 *     through the tunnel — the false-Connected the old build showed (no key
 *     icon, nothing working) came from skipping exactly this gate;
 *  6. a broken gateway becomes an explicit error with the core's own log
 *     lines attached, never an endless spinner.
 */
class NimbusVpnService : VpnService() {
    private val io: ExecutorService = Executors.newCachedThreadPool()
    @Volatile private var tun: ParcelFileDescriptor? = null
    @Volatile private var core: Process? = null
    // PID of the core this service instance spawned; never reaped as "orphan".
    private val childPid = java.util.concurrent.atomic.AtomicLong(-1)
    @Volatile private var download: Long = 0
    @Volatile private var upload: Long = 0
    @Volatile private var endpoint: String = ""
    @Volatile private var protocol: String = "masque"
    @Volatile private var socksPort: Int = 1819
    @Volatile private var tunMtu: Int = 1500
    @Volatile private var bridgeStarted: Boolean = false
    @Volatile private var h3GatewayUnavailable: Boolean = false
    @Volatile private var lastCoreError: String = ""
    private val lanProxy = LanProxyServer()
    private val generation = AtomicLong(0)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                io.execute { stopTunnelFromIntent() }
                return START_NOT_STICKY
            }
            ACTION_START, null -> {
                if (isRetired()) {
                    // A newer release exists: starting the tunnel here would
                    // keep a retired build alive without the UI ever knowing.
                    sendLog("a newer release is available — refusing to start this build")
                    // The caller may have used startForegroundService(), which
                    // must be answered with a notification before the service
                    // goes away. It is destroyed again immediately.
                    startForegroundCompat()
                    stopSelf()
                    return START_NOT_STICKY
                }
                val extras = intent?.extras ?: lastExtras ?: extrasFromPrefs()
                if (intent?.extras != null) lastExtras = Bundle(intent.extras!!)
                io.execute { startTunnel(extras) }
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        generation.incrementAndGet()
        teardownQuiet()
        io.shutdownNow()
        super.onDestroy()
    }

    /// Set by the app whenever the release feed reports a newer build.
    private fun isRetired(): Boolean =
        getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean("blocked", false)

    private fun isCurrent(session: Long): Boolean =
        running.get() && generation.get() == session

    // ------------------------------------------------------------------
    // Start pipeline
    // ------------------------------------------------------------------

    private fun startTunnel(extras: Bundle?) {
        // Serialize pipelines: two rapid ACTION_START intents must not run two
        // concurrent startTunnel bodies (they would reap each other's cores).
        synchronized(this) {
        // A stale error from a previous session must not leak into this one.
        lastCoreError = ""
        // A repeated Connect restarts cleanly instead of stacking on top of a
        // half-dead session: invalidate the old generation, tear it down
        // quietly, then take a fresh session id for this pipeline.
        generation.incrementAndGet()
        val wasRunning = running.get()
        running.set(false)
        if (wasRunning) teardownQuiet()
        val session = generation.incrementAndGet()
        running.set(true)
        publishPhase("preparing", "Preparing")
        startForegroundCompat()
        try {
            val envLines = extras?.getStringArrayList(EXTRA_ENV) ?: arrayListOf()
            val env = parseEnvironment(envLines)
            protocol = value(env, "AETHER_PROTOCOL",
                extras?.getString(EXTRA_PROTOCOL) ?: "masque")
            val transport = value(env, "AETHER_MASQUE_HTTP2", if ("h2" == extras?.getString(EXTRA_TRANSPORT)) "1" else "0")
            val mode = extras?.getString(EXTRA_MODE) ?: "vpn"
            val dns = extras?.getBoolean(EXTRA_DNS, true) != false
            val splitMode = extras?.getString(EXTRA_SPLIT_MODE) ?: "off"
            val splitApps = extras?.getStringArrayList(EXTRA_SPLIT_APPS) ?: arrayListOf()
            socksPort = extras?.getInt(EXTRA_SOCKS_PORT, 1819) ?: 1819
            tunMtu = extras?.getInt(EXTRA_MTU, 1500) ?: 1500
            val bypassLan = extras?.getBoolean(EXTRA_BYPASS_LAN, true) != false
            val ipv6 = extras?.getBoolean(EXTRA_IPV6, false) == true
            val lanShare = extras?.getBoolean(EXTRA_LAN_SHARE, false) == true

            val bin = File(applicationInfo.nativeLibraryDir, "libaether.so")
            if (!bin.isFile) {
                throw IllegalStateException("Tunnel core is missing for this device architecture")
            }

            // One stale core that outlived its session still owns the SOCKS
            // port and its upstream sockets; clearing it is what makes a
            // repeated Connect deterministic.
            reapOrphanedCores()
            awaitSocksPortReleased()

            env["AETHER_CONFIG"] = File(filesDir, "aether.toml").absolutePath
            env["AETHER_SOCKS"] = "127.0.0.1:$socksPort"
            env["TMPDIR"] = cacheDir.absolutePath
            // Persist before any failure path so QS tile / boot auto-connect
            // reuse the last request.
            persistLast(extras, envLines)

            if (!startCoreWithMasqueFallback(bin, env, transport, session)) return bail(session)

            if (lanShare) {
                val lanPort = if (socksPort in 1..65534) socksPort + 1 else 1820
                if (lanProxy.start(lanPort, "127.0.0.1", socksPort)) {
                    emit(
                        "lan",
                        "connected",
                        "${lanProxy.address}:${lanProxy.port}|${lanProxy.username}|${lanProxy.password}",
                    )
                }
            }

            if (mode == "vpn") {
                if (!establishVpn(dns, bypassLan, ipv6, splitMode, splitApps, session, env)) {
                    return bail(session)
                }
            }

            publishPhase("securing", "Verifying the tunnel")
            if (!validateTrafficReady(session, attempts = 2)) {
                // The gateway answered but carries no traffic: re-roll the
                // endpoint in place once (core restart only, TUN stays).
                sendLog("Gateway cannot carry traffic; re-rolling endpoint")
                stopCoreOnly()
                awaitSocksPortReleased()
                if (!isCurrent(session)) return
                if (!startCoreWithMasqueFallback(bin, env, transport, session)) return bail(session)
                if (!validateTrafficReady(session, attempts = 1)) {
                    throw IllegalStateException(
                        "Real traffic validation failed — the gateway cannot carry traffic",
                    )
                }
            }
            if (!isCurrent(session)) return

            publishChrome()
            publishPhase(
                "connected",
                if (mode == "vpn") "Device VPN active" else "SOCKS5 127.0.0.1:$socksPort",
            )
            io.execute { monitor(session, mode) }
        } catch (e: Throwable) {
            Log.e(TAG, "start failed", e)
            lastCoreError = e.message ?: "start failed"
            if (running.get()) {
                emit("status", "error", lastCoreError)
                stopTunnelQuietFail(session)
            }
        }
        } // synchronized(this)
    }

    private fun bail(session: Long) {
        if (generation.get() == session) {
            stopTunnelQuietFail(session)
        }
    }

    /** Failure teardown from inside the start pipeline: reports the error. */
    private fun stopTunnelQuietFail(session: Long) {
        running.set(false)
        teardownQuiet()
        if (lastCoreError.isNotEmpty()) {
            emit("status", "error", lastCoreError)
        }
        publishPhase("disconnected", "")
        publishChrome()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun parseEnvironment(lines: List<String>): LinkedHashMap<String, String> {
        val env = LinkedHashMap<String, String>()
        for (line in lines) {
            val i = line.indexOf('=')
            if (i > 0) env[line.substring(0, i)] = line.substring(i + 1)
        }
        if (env.isEmpty()) {
            env["AETHER_PROTOCOL"] = "masque"
            env["AETHER_SCAN"] = "balanced"
            env["AETHER_IP"] = "v4"
            env["AETHER_NOIZE"] = "balanced"
            env["AETHER_LOG_LEVEL"] = "info"
            env["AETHER_QUICK_RECONNECT"] = "1"
            env["AETHER_MASQUE_HTTP2"] = "0"
            env["AETHER_MASQUE_MTU"] = tunMtu.toString()
        }
        return env
    }

    private fun value(env: Map<String, String>, key: String, fallback: String): String =
        env[key]?.takeIf { it.isNotBlank() } ?: fallback

    // ------------------------------------------------------------------
    // Core process management
    // ------------------------------------------------------------------

    private fun startCore(bin: File, env: Map<String, String>): Process {
        val builder = ProcessBuilder(bin.absolutePath)
        builder.directory(filesDir)
        builder.redirectErrorStream(true)
        val pbEnv = builder.environment()
        env.forEach { (k, v) -> pbEnv[k] = v }
        val process = builder.start()
        core = process
        childPid.set(process.aetherPid())
        sendLog("Tunnel core started (${Build.SUPPORTED_ABIS.firstOrNull() ?: "abi"})")
        val reader = Thread({ readCoreLogs(process) }, "core-log-reader")
        reader.isDaemon = true
        reader.start()
        return process
    }

    /**
     * MASQUE over HTTP/3 gets [MASQUE_H3_PRIMARY_MS] first; when QUIC cannot
     * get through — explicitly ("no usable masque gateway") or by timeout —
     * the same attempt restarts on the HTTP/2 carrier. Other protocols just
     * get the full [SOCKS_TIMEOUT_MS].
     */
    private fun startCoreWithMasqueFallback(
        bin: File,
        env: MutableMap<String, String>,
        transport: String,
        session: Long,
    ): Boolean {
        val deadline = System.currentTimeMillis() + SOCKS_TIMEOUT_MS
        val masqueH3 = "masque" == protocol && transport != "1"
        val masqueMimH3 = "mim" == protocol && transport != "1"
        h3GatewayUnavailable = false
        startCore(bin, env)
        val primary = if (masqueH3 || masqueMimH3) {
            System.currentTimeMillis() + MASQUE_H3_PRIMARY_MS
        } else {
            deadline
        }
        if (waitForSocks(primary, session)) return true
        if (!isCurrent(session)) return false
        if (!masqueH3 && !masqueMimH3) {
            if (lastCoreError.isEmpty()) {
                lastCoreError = "SOCKS5 listener did not start in time"
            }
            sendLog(lastCoreError)
            return false
        }
        sendLog(
            if (h3GatewayUnavailable) {
                "MASQUE HTTP/3 gateway scan found nothing; retrying on HTTP/2"
            } else {
                "MASQUE HTTP/3 did not establish; retrying on HTTP/2"
            },
        )
        stopCoreOnly()
        awaitSocksPortReleased()
        if (!isCurrent(session)) return false
        env["AETHER_MASQUE_HTTP2"] = "1"
        publishPhase("scanning", "MASQUE HTTP/2")
        startCore(bin, env)
        if (waitForSocks(deadline, session)) return true
        if (lastCoreError.isEmpty()) {
            lastCoreError = "SOCKS5 listener did not start in time"
        }
        sendLog(lastCoreError)
        return false
    }

    private fun readCoreLogs(process: Process) {
        try {
            BufferedReader(InputStreamReader(process.inputStream)).use { reader ->
                var line: String?
                while (reader.readLine().also { line = it } != null) {
                    val text = line ?: continue
                    emit("log", null, text)
                    val lower = text.lowercase(Locale.US)
                    if (lower.contains("no usable masque gateway found")) {
                        h3GatewayUnavailable = true
                    }
                    if (lower.contains("error") || lower.contains("failed")) {
                        lastCoreError = text
                    }
                    if (lower.contains("identity ready") || lower.contains("hunting for")) {
                        publishPhase("scanning", "Scanning for a gateway")
                    }
                    if (lower.contains("validated") || lower.contains("passed handshake")) {
                        publishPhase("securing", "Gateway verified")
                    }
                    if (lower.contains("peer") ||
                        lower.contains("endpoint") ||
                        lower.contains("using")
                    ) {
                        Regex("""(\d{1,3}(?:\.\d{1,3}){3})(?::\d+)?""")
                            .find(text)?.groupValues?.get(1)?.let { ip ->
                                if (!ip.startsWith("127.") &&
                                    !ip.startsWith("198.18.") &&
                                    ip != "0.0.0.0"
                                ) {
                                    endpoint = ip
                                }
                            }
                    }
                }
            }
        } catch (e: Exception) {
            if (running.get()) sendLog("Tunnel-core log stream closed: ${e.message}")
        }
    }

    /** SOCKS5 greeting, the minimum honest readiness signal. */
    private fun socksHandshakeSucceeds(): Boolean {
        return try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress("127.0.0.1", socksPort), 250)
                socket.soTimeout = 600
                socket.getOutputStream().write(byteArrayOf(5, 1, 0))
                socket.getOutputStream().flush()
                val greeting = ByteArray(2)
                var off = 0
                while (off < 2) {
                    val n = socket.getInputStream().read(greeting, off, 2 - off)
                    if (n < 0) return false
                    off += n
                }
                greeting[0].toInt() == 5 && greeting[1].toInt() == 0
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun waitForSocks(deadlineMs: Long, session: Long): Boolean {
        while (isCurrent(session) && System.currentTimeMillis() < deadlineMs) {
            if (h3GatewayUnavailable) return false
            val process = core
            if (process != null && !process.isAlive) {
                lastCoreError = "Tunnel core exited (${process.exitValueSafely()})" +
                    lastCoreError.let { if (it.isEmpty()) "" else ": $it" }
                return false
            }
            if (socksHandshakeSucceeds()) return true
            try {
                Thread.sleep(120)
            } catch (_: InterruptedException) {
                return false
            }
        }
        return false
    }

    /// PID of the spawned core process. `Process.pid()` does not exist on the
    /// Android runtime, so scan /proc for the child whose parent (stat field 4)
    /// is our own pid and whose cmdline matches this core binary.
    private fun Process.aetherPid(): Long {
        return try {
            val mine = android.os.Process.myPid()
            File("/proc").listFiles { f -> f.name.all { it.isDigit() } }
                ?.firstOrNull { dir ->
                    try {
                        val stat = File(dir, "stat").readText()
                        val ppid = stat.substringAfterLast(") ")?.trim()
                            ?.split(" ")?.getOrNull(1)?.toLongOrNull()
                        ppid == mine.toLong() &&
                            File(dir, "cmdline").readText().contains("libaether.so")
                    } catch (_: Exception) { false }
                }?.name?.toLongOrNull() ?: -1L
        } catch (_: Exception) { -1L }
    }
    private fun Process.exitValueSafely(): String =
        try {
            exitValue().toString()
        } catch (_: IllegalThreadStateException) {
            "running"
        }

    /**
     * Kills stale cores from previous sessions. They share nothing with this
     * process, so the only safe handle is /proc: every tunnel-core child's cmdline
     * is the libaether.so absolute path.
     */
    private fun reapOrphanedCores() {
        val mine = android.os.Process.myPid()
        val selfExe = try {
            File("/proc/self/exe").canonicalPath
        } catch (_: Exception) {
            ""
        }
        File("/proc").listFiles { f -> f.name.all { it.isDigit() } }?.forEach { procDir ->
            val pid = procDir.name.toIntOrNull() ?: return@forEach
            if (pid == mine) return@forEach
            // Never touch the zygote/app process itself. Check identity BEFORE
            // killing, otherwise the check is dead code and a concurrent start
            // can reap its own freshly spawned core.
            if (childPid.get() == pid.toLong()) return@forEach
            try {
                val cmdline = File(procDir, "cmdline").readText()
                if (selfExe.isNotEmpty() && cmdline.startsWith(selfExe)) return@forEach
                if (cmdline.contains("libaether.so")) {
                    Log.w(TAG, "reaping orphaned Tunnel core pid=$pid")
                    android.os.Process.killProcess(pid)
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun awaitSocksPortReleased() {
        val deadline = System.currentTimeMillis() + 5_000L
        while (System.currentTimeMillis() < deadline) {
            if (!socksHandshakeSucceeds()) return
            reapOrphanedCores()
            try {
                Thread.sleep(150)
            } catch (_: InterruptedException) {
                return
            }
        }
    }

    private fun stopCoreOnly() {
        val process = core ?: return
        core = null
        try {
            process.destroy()
        } catch (_: Exception) {
        }
        io.execute {
            try {
                if (!process.waitFor(2, TimeUnit.SECONDS)) {
                    process.destroyForcibly()
                    process.waitFor(2, TimeUnit.SECONDS)
                }
            } catch (_: Exception) {
            }
        }
    }

    // ------------------------------------------------------------------
    // TUN establishment (mirrors the reference client's Builder choices)
    // ------------------------------------------------------------------

    private fun establishVpn(
        dns: Boolean,
        bypassLan: Boolean,
        ipv6: Boolean,
        splitMode: String,
        splitApps: List<String>,
        session: Long,
        env: Map<String, String>,
    ): Boolean {
        val builder = Builder()
            .setSession("VoidrauVPN")
            .setMtu(tunMtu)
            // setBlocking(false): the old build passed the kill-switch flag
            // here; blocking while the VPN recloses during core restarts is
            // what wedged apps instead of failing over.
            .setBlocking(false)
            .addAddress("198.18.0.1", 30)
        if (ipv6) {
            builder.addAddress("fc00::1", 126)
            builder.addRoute("::", 0)
        }
        if (bypassLan) {
            addPublicRoutes(builder)
        } else {
            builder.addRoute("0.0.0.0", 0)
        }
        if (dns) {
            // Both resolvers are public addresses covered by the tunnel
            // routes, so lookups — including Private DNS — ride the tunnel.
            builder.addDnsServer("1.1.1.1")
            builder.addDnsServer("1.0.0.1")
        }
        // Per-app routing. The app itself must stay out of the tunnel in
        // every mode except an explicit include-list that names it (never
        // auto-added): the core shares this UID, and routing the core's own
        // egress back into the TUN is a routing loop that looks exactly like
        // "connected but nothing works".
        if (splitMode != "include") {
            try {
                builder.addDisallowedApplication(packageName)
            } catch (_: Exception) {
            }
        }
        var included = 0
        for (pkg in splitApps.map { it.trim() }.filter { it.isNotEmpty() }) {
            if (pkg == packageName) continue
            try {
                when (splitMode) {
                    "include" -> builder.addAllowedApplication(pkg)
                    "exclude" -> builder.addDisallowedApplication(pkg)
                }
                included++
            } catch (_: Exception) {
            }
        }
        if (splitMode == "include" && included == 0) {
            lastCoreError = "Include-selected apps needs at least one valid app"
            emit("status", "error", lastCoreError)
            return false
        }

        val descriptor = try {
            builder.establish()
        } catch (e: Exception) {
            lastCoreError = "Android refused the VPN interface: ${e.message}"
            emit("status", "error", lastCoreError)
            return false
        }
        if (descriptor == null) {
            lastCoreError = "Android could not create the VPN interface"
            emit("status", "error", lastCoreError)
            return false
        }
        tun = descriptor

        // A previous bridge worker that has not finished makes upstream
        // TProxyStartService a silent no-op; never start on top of it.
        if (!awaitBridgeHandover()) {
            lastCoreError = "The previous tunnel bridge has not shut down yet"
            emit("status", "error", lastCoreError)
            return false
        }
        val config = writeHevConfig(ipv6, env)
        val started = try {
            TProxyService.TProxyStartService(config.absolutePath, descriptor.fd)
        } catch (e: UnsatisfiedLinkError) {
            lastCoreError = "The HEV JNI bridge could not be loaded"
            emit("status", "error", lastCoreError)
            return false
        }
        if (!started) {
            lastCoreError = "HEV tunnel failed to start"
            emit("status", "error", lastCoreError)
            return false
        }
        bridgeStarted = true
        sendLog("HEV TUN bridge started")
        return isCurrent(session)
    }

    private fun awaitBridgeHandover(): Boolean {
        val deadline = System.currentTimeMillis() + BRIDGE_HANDOVER_MS
        while (System.currentTimeMillis() < deadline) {
            val alive = try {
                TProxyService.TProxyIsRunning()
            } catch (_: Throwable) {
                false
            }
            if (!alive) return true
            try {
                TProxyService.TProxyStopService()
            } catch (_: Throwable) {
            }
            try {
                Thread.sleep(200)
            } catch (_: InterruptedException) {
                return false
            }
        }
        return false
    }

    /**
     * The bridge's YAML. Beyond the addresses this is where the device's own
     * throughput is decided: `tcp-buffer-size` is the splice buffer for every
     * TCP session and `udp-recv-buffer-size` the socket buffer for QUIC/DNS, so
     * the speed profile the user picked in the UI is honoured here too — the
     * core's own tier cannot help with traffic the bridge has not handed over
     * yet.
     */
    private fun writeHevConfig(ipv6: Boolean, env: Map<String, String>): File {
        val fast = env["AETHER_PERF_PROFILE"] == "high"
        val tcpBuffer = if (fast) 131072 else 65536
        // The TCP splice buffer is allocated on the worker's own stack, so the
        // stack has to grow with it (upstream's rule: size + 20480). The old
        // fixed 32768 with a 65536 buffer was an overflow waiting to happen.
        val stack = 20480 + tcpBuffer
        val udpRecv = if (fast) 1048576 else 524288
        val config = File(cacheDir, "hev.yml")
        FileWriter(config, false).use { writer ->
            writer.write("misc:\n")
            writer.write("  task-stack-size: $stack\n")
            writer.write("  tcp-buffer-size: $tcpBuffer\n")
            writer.write("  udp-recv-buffer-size: $udpRecv\n")
            writer.write("  max-session-count: 0\n")
            writer.write("  connect-timeout: 15000\n")
            writer.write("  limit-nofile: 65535\n")
            writer.write("  log-level: warn\n")
            writer.write("tunnel:\n")
            writer.write("  mtu: $tunMtu\n")
            writer.write("  ipv4: 198.18.0.1\n")
            if (ipv6) writer.write("  ipv6: 'fc00::1'\n")
            writer.write("  icmp: 'reply'\n")
            writer.write("socks5:\n")
            writer.write("  address: '127.0.0.1'\n")
            writer.write("  port: $socksPort\n")
            writer.write("  udp: 'udp'\n")
        }
        return config
    }

    /**
     * "0.0.0.0/0 minus local networks", the reference client's bypass-local
     * route table. The old hand-written list leaked 100.64.0.0/10 (carrier
     * NAT) and 198.18.0.0/15 (the TUN's own block!) into the tunnel.
     */
    private fun addPublicRoutes(builder: Builder) {
        val ranges = mutableListOf<Pair<Long, Long>>()
        fun add(cidr: String, prefix: Int) {
            ranges.add(cidrStart(cidr) to cidrEnd(cidr, prefix))
        }
        add("0.0.0.0", 8)
        add("10.0.0.0", 8)
        add("100.64.0.0", 10)
        add("127.0.0.0", 8)
        add("169.254.0.0", 16)
        add("172.16.0.0", 12)
        add("192.0.0.0", 24)
        add("192.168.0.0", 16)
        add("198.18.0.0", 15)
        add("224.0.0.0", 3)
        ranges.sortBy { it.first }
        var cursor = 0L
        for (range in ranges) {
            if (cursor < range.first) addRangeRoutes(builder, cursor, range.first - 1)
            cursor = maxOf(cursor, range.second + 1)
        }
        if (cursor <= 0xffffffffL) addRangeRoutes(builder, cursor, 0xffffffffL)
    }

    private fun cidrStart(ip: String): Long {
        val parts = ip.split(".")
        var value = 0L
        for (part in parts) value = (value shl 8) or (part.toLong() and 0xff)
        return value
    }

    private fun cidrEnd(ip: String, prefix: Int): Long =
        cidrStart(ip) or ((1L shl (32 - prefix)) - 1)

    private fun addRangeRoutes(builder: Builder, start: Long, end: Long) {
        var s = start
        while (s <= end) {
            val alignment = if (s == 0L) 1L shl 32 else java.lang.Long.lowestOneBit(s)
            val remaining = end - s + 1
            var block = alignment
            while (block > remaining) block = block ushr 1
            val prefix = 32 - java.lang.Long.numberOfTrailingZeros(block)
            builder.addRoute(formatIp(s), prefix)
            s += block
        }
    }

    private fun formatIp(value: Long): String =
        "${(value ushr 24) and 0xff}.${(value ushr 16) and 0xff}.${(value ushr 8) and 0xff}.${value and 0xff}"

    // ------------------------------------------------------------------
    // Proven data plane: "connected" only after real traffic
    // ------------------------------------------------------------------

    private fun validateTrafficReady(session: Long, attempts: Int): Boolean {
        for (attempt in 1..attempts) {
            if (!isCurrent(session)) return false
            for (target in TRAFFIC_TARGETS) {
                if (httpThroughSocks(target.first, target.second)) return true
            }
        }
        return false
    }

    /**
     * One SOCKS5 domain CONNECT + HTTP/1.0 GET through the tunnel. Domain
     * CONNECT means the core resolves inside the tunnel — the exact path HEV
     * forwards for apps.
     */
    private fun httpThroughSocks(name: String, path: String): Boolean {
        return try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress("127.0.0.1", socksPort), 4_000)
                socket.soTimeout = 8_000
                val out = socket.getOutputStream()
                val input = socket.getInputStream()
                out.write(byteArrayOf(5, 1, 0))
                out.flush()
                val greeting = readExact(input, 2) ?: return false
                if (greeting[0].toInt() != 5 || greeting[1].toInt() != 0) return false
                val host = name.toByteArray(Charsets.UTF_8)
                val request = byteArrayOf(5, 1, 0, 3, host.size.toByte()) +
                    host + byteArrayOf(0, 80.toByte())
                out.write(request)
                out.flush()
                val replyHead = readExact(input, 4) ?: return false
                if (replyHead[1].toInt() != 0) return false
                when (replyHead[3].toInt()) {
                    1 -> readExact(input, 6)
                    3 -> {
                        val n = (readExact(input, 1)?.get(0)?.toInt() ?: 0) and 0xff
                        readExact(input, n + 2)
                    }
                    4 -> readExact(input, 18)
                }
                out.write(
                    ("GET $path HTTP/1.0\r\nHost: $name\r\nUser-Agent: nimbus-probe\r\n\r\n")
                        .toByteArray(Charsets.UTF_8),
                )
                out.flush()
                val head = readUntilDoubleCrlf(input, 8_192) ?: return false
                val status = head.substringBefore("\r\n")
                status.startsWith("HTTP/") &&
                    (status.contains(" 200") ||
                        status.contains(" 204") ||
                        status.contains(" 301") ||
                        status.contains(" 302"))
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun readExact(input: java.io.InputStream, n: Int): ByteArray? {
        val buffer = ByteArray(n)
        var off = 0
        while (off < n) {
            val read = input.read(buffer, off, n - off)
            if (read < 0) return null
            off += read
        }
        return buffer
    }

    private fun readUntilDoubleCrlf(input: java.io.InputStream, cap: Int): String? {
        val buffer = java.io.ByteArrayOutputStream()
        var b: Int
        var matched = 0
        val pattern = byteArrayOf(13, 10, 13, 10)
        while (buffer.size() < cap) {
            b = input.read()
            if (b < 0) break
            buffer.write(b)
            matched = if (b.toByte() == pattern[matched]) matched + 1 else 0
            if (matched == 4) return buffer.toString("UTF-8")
        }
        return if (buffer.size() > 0) buffer.toString("UTF-8") else null
    }

    // ------------------------------------------------------------------
    // Monitor + health
    // ------------------------------------------------------------------

    private fun monitor(session: Long, mode: String) {
        var failures = 0
        var tick = 0
        while (isCurrent(session)) {
            val process = core
            if (process == null) {
                // During stop/restart the core field is nulled first; that is
                // teardown in progress, not a dead core. Skip this tick.
                tick++
                Thread.sleep(1000)
                continue
            }
            val alive = try {
                process.exitValue()
                false
            } catch (_: IllegalThreadStateException) {
                true
            }
            if (!alive) {
                lastCoreError = "Tunnel core exited"
                emit("status", "error", lastCoreError)
                stopTunnelQuietFail(session)
                return
            }
            if (mode == "vpn" && bridgeStarted) {
                val hevAlive = try {
                    TProxyService.TProxyIsRunning()
                } catch (_: Throwable) {
                    true
                }
                if (!hevAlive) {
                    lastCoreError = "The TUN bridge stopped"
                    emit("status", "error", lastCoreError)
                    stopTunnelQuietFail(session)
                    return
                }
                try {
                    val stats = TProxyService.TProxyGetStats()
                    if (stats != null && stats.size >= 4) {
                        upload = stats[1]
                        download = stats[3]
                    }
                } catch (_: Throwable) {
                }
            }
            tick++
            if (tick % 8 == 0) {
                // Periodic health probe through the tunnel itself.
                val healthy = httpThroughSocks(
                    TRAFFIC_TARGETS[0].first,
                    TRAFFIC_TARGETS[0].second,
                )
                failures = if (healthy) 0 else failures + 1
                if (failures >= 3) {
                    sendLog("Tunnel stalled; restarting the core")
                    emit("status", "reconnecting", "Tunnel stalled")
                    stopCoreOnly()
                    awaitSocksPortReleased()
                    val bin = File(applicationInfo.nativeLibraryDir, "libaether.so")
                    val env = parseEnvironment(
                        lastExtras?.getStringArrayList(EXTRA_ENV) ?: arrayListOf(),
                    )
                    env["AETHER_CONFIG"] = File(filesDir, "aether.toml").absolutePath
                    env["AETHER_SOCKS"] = "127.0.0.1:$socksPort"
                    env["TMPDIR"] = cacheDir.absolutePath
                    // Reuse the H3→H2 fallback: a bare startCore() here drops
                    // AETHER_MASQUE_HTTP2=1 and every stall recovery would
                    // retry dead H3 on QUIC-hostile networks.
                    val transport = lastExtras?.getString(EXTRA_TRANSPORT) ?: ""
                    val recovered = if (env["AETHER_PROTOCOL"] == "masque" || env["AETHER_PROTOCOL"] == "mim") {
                        startCoreWithMasqueFallback(bin, env, transport, session)
                    } else {
                        startCore(bin, env)
                        waitForSocks(System.currentTimeMillis() + SOCKS_TIMEOUT_MS, session)
                    }
                    if (!recovered || !validateTrafficReady(session, 1)) {
                        lastCoreError = "Tunnel did not recover"
                        emit("status", "error", lastCoreError)
                        stopTunnelQuietFail(session)
                        return
                    }
                    failures = 0
                    emit("status", "connected", "Connection restored")
                }
            }
            emit("status", if (running.get()) "connected" else "disconnected", null)
            try {
                Thread.sleep(2_000)
            } catch (_: InterruptedException) {
                return
            }
        }
    }

    // ------------------------------------------------------------------
    // Stop
    // ------------------------------------------------------------------

    private fun stopTunnelFromIntent() {
        generation.incrementAndGet()
        running.set(false)
        teardownQuiet()
        publishPhase("disconnected", "")
        publishChrome()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /**
     * Releases every resource of a session, quietly. Never blocks the UI.
     * Emits nothing: a "disconnected" blip here would read as a user stop —
     * phases are published only by the explicit start/stop/fail paths.
     */
    private fun teardownQuiet() {
        bridgeStarted = false
        try {
            lanProxy.stop()
        } catch (_: Throwable) {
        }
        // TProxyStopService joins the tunnel worker; a native call of
        // unbounded duration never runs on the lifecycle thread.
        io.execute {
            try {
                TProxyService.TProxyStopService()
            } catch (_: Throwable) {
            }
        }
        try {
            tun?.close()
        } catch (_: Exception) {
        }
        tun = null
        stopCoreOnly()
    }

    // ------------------------------------------------------------------
    // Plumbing (unchanged contracts with tile/widget/plugin)
    // ------------------------------------------------------------------

    private fun persistLast(extras: Bundle?, envLines: List<String>) {
        extras ?: return
        lastExtras = Bundle(extras)
        if (!lastExtras!!.containsKey(EXTRA_ENV)) {
            lastExtras!!.putStringArrayList(EXTRA_ENV, ArrayList(envLines))
        }
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putString(EXTRA_PROTOCOL, extras.getString(EXTRA_PROTOCOL, protocol))
            .putString(EXTRA_MODE, extras.getString(EXTRA_MODE, "vpn"))
            .putBoolean(EXTRA_DNS, extras.getBoolean(EXTRA_DNS, true))
            .putString(EXTRA_SPLIT_MODE, extras.getString(EXTRA_SPLIT_MODE, "off"))
            .putString(
                EXTRA_SPLIT_APPS,
                extras.getStringArrayList(EXTRA_SPLIT_APPS)?.joinToString(","),
            )
            .putInt(EXTRA_SOCKS_PORT, extras.getInt(EXTRA_SOCKS_PORT, 1819))
            .putInt(EXTRA_MTU, extras.getInt(EXTRA_MTU, 1500))
            .putBoolean(EXTRA_KILL, extras.getBoolean(EXTRA_KILL, true))
            .putBoolean(EXTRA_BYPASS_LAN, extras.getBoolean(EXTRA_BYPASS_LAN, true))
            .putBoolean(EXTRA_IPV6, extras.getBoolean(EXTRA_IPV6, false))
            .putBoolean(EXTRA_LAN_SHARE, extras.getBoolean(EXTRA_LAN_SHARE, false))
            .putString(EXTRA_TRANSPORT, extras.getString(EXTRA_TRANSPORT, "h3"))
            .putBoolean("autoConnect", extras.getBoolean("autoConnect", false))
            .putString(EXTRA_ENV, (extras.getStringArrayList(EXTRA_ENV) ?: ArrayList(envLines)).joinToString("\u0001"))
            .apply()
    }

    private fun extrasFromPrefs(): Bundle {
        val p = getSharedPreferences(PREFS, MODE_PRIVATE)
        val b = Bundle()
        b.putString(EXTRA_PROTOCOL, p.getString(EXTRA_PROTOCOL, "masque"))
        b.putString(EXTRA_MODE, p.getString(EXTRA_MODE, "vpn"))
        b.putBoolean(EXTRA_DNS, p.getBoolean(EXTRA_DNS, true))
        b.putString(EXTRA_SPLIT_MODE, p.getString(EXTRA_SPLIT_MODE, "off"))
        val apps = p.getString(EXTRA_SPLIT_APPS, "") ?: ""
        b.putStringArrayList(
            EXTRA_SPLIT_APPS,
            ArrayList(apps.split(",").filter { it.isNotEmpty() }),
        )
        b.putInt(EXTRA_SOCKS_PORT, p.getInt(EXTRA_SOCKS_PORT, 1819))
        b.putInt(EXTRA_MTU, p.getInt(EXTRA_MTU, 1500))
        b.putBoolean(EXTRA_KILL, p.getBoolean(EXTRA_KILL, true))
        b.putBoolean(EXTRA_BYPASS_LAN, p.getBoolean(EXTRA_BYPASS_LAN, true))
        b.putBoolean(EXTRA_IPV6, p.getBoolean(EXTRA_IPV6, false))
        b.putBoolean(EXTRA_LAN_SHARE, p.getBoolean(EXTRA_LAN_SHARE, false))
        b.putString(EXTRA_TRANSPORT, p.getString(EXTRA_TRANSPORT, "h3"))
        val env = (p.getString(EXTRA_ENV, "") ?: "").split("\u0001")
            .filter { it.contains('=') }
        b.putStringArrayList(EXTRA_ENV, ArrayList(env))
        return b
    }

    private fun startForegroundCompat() {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "VoidrauVPN", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(
            this, 0, launch, PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, NimbusVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL)
            .setContentTitle("VoidrauVPN")
            .setContentText("Protected")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pi)
            .addAction(0, "Disconnect", stop)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIF,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIF, notification)
        }
    }

    private fun publishChrome() {
        try {
            val mgr = AppWidgetManager.getInstance(this)
            val ids = mgr.getAppWidgetIds(ComponentName(this, NimbusWidgetProvider::class.java))
            val upd = Intent(this, NimbusWidgetProvider::class.java)
                .setAction(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
            upd.putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
            sendBroadcast(upd)
        } catch (_: Exception) {
        }
    }

    private fun publishPhase(phase: String, message: String) {
        currentPhase = phase
        currentMessage = message
        emit("status", phase, message)
    }

    private fun sendLog(line: String) {
        emit("log", null, line)
        Log.i(TAG, line)
    }

    private fun emit(type: String, phase: String?, message: String?) {
        // Mirror what the broadcast carries into the companion, so the Dart
        // side's status *poll* is as complete as the event stream: the live
        // meter reads whichever arrives first.
        liveDownload = download
        liveUpload = upload
        liveEndpoint = endpoint
        liveProtocol = protocol
        liveSocksPort = socksPort
        val i = Intent(ACTION_EVENT).setPackage(packageName)
        i.putExtra("type", type)
        i.putExtra("phase", phase)
        i.putExtra("message", message)
        i.putExtra("endpoint", endpoint)
        i.putExtra("protocol", protocol)
        i.putExtra("download", download)
        i.putExtra("upload", upload)
        sendBroadcast(i)
        NimbusPlugin.emit(
            mapOf(
                "type" to type,
                "phase" to (phase ?: ""),
                "message" to (message ?: ""),
                "endpoint" to endpoint,
                "protocol" to protocol,
                "download" to download,
                "upload" to upload,
            ),
        )
    }

    companion object {
        const val TAG = "NimbusVpn"
        const val CHANNEL = "nimbus_vpn"
        const val NOTIF = 1819
        const val ACTION_START = "pm.dnschanger.nimbus.START"
        const val ACTION_STOP = "pm.dnschanger.nimbus.STOP"
        const val ACTION_EVENT = "pm.dnschanger.nimbus.EVENT"
        const val EXTRA_ARGS = "args" // legacy, kept for stored-pref compat
        const val EXTRA_ENV = "env"
        const val EXTRA_PROTOCOL = "protocol"
        const val EXTRA_TRANSPORT = "transport"
        const val EXTRA_MODE = "mode"
        const val EXTRA_DNS = "dns"
        const val EXTRA_SPLIT_MODE = "splitMode"
        const val EXTRA_SPLIT_APPS = "splitApps"
        const val EXTRA_SOCKS_PORT = "socksPort"
        const val EXTRA_MTU = "tunMtu"
        const val EXTRA_KILL = "killSwitch"
        const val EXTRA_BYPASS_LAN = "bypassLan"
        const val EXTRA_IPV6 = "ipv6Tunnel"
        const val EXTRA_LAN_SHARE = "lanShare"
        const val PREFS = "nimbus_vpn"

        private const val SOCKS_TIMEOUT_MS = 60_000L
        private const val MASQUE_H3_PRIMARY_MS = 20_000L
        private const val BRIDGE_HANDOVER_MS = 10_000L

        /** Independent operators, plain HTTP through the tunnel. */
        private val TRAFFIC_TARGETS = listOf(
            "www.cloudflare.com" to "/cdn-cgi/trace",
            "detectportal.firefox.com" to "/success.txt",
            "connectivitycheck.gstatic.com" to "/generate_204",
        )

        val running = AtomicBoolean(false)
        @Volatile var lastExtras: Bundle? = null
        @Volatile var currentPhase: String = "disconnected"
            private set
        @Volatile var currentMessage: String = ""
            private set

        /** Last values the running service published; the Dart poll reads these
         *  while the event stream carries the same numbers as they change. */
        @Volatile var liveDownload: Long = 0
        @Volatile var liveUpload: Long = 0
        @Volatile var liveEndpoint: String = ""
        @Volatile var liveProtocol: String = "masque"
        @Volatile var liveSocksPort: Int = 1819

        fun statusMap(): Map<String, Any?> = mapOf(
            "phase" to (if (running.get()) currentPhase else "disconnected"),
            "message" to currentMessage,
            "endpoint" to liveEndpoint,
            "protocol" to liveProtocol,
            "socksPort" to liveSocksPort,
            "download" to liveDownload,
            "upload" to liveUpload,
        )
    }
}
