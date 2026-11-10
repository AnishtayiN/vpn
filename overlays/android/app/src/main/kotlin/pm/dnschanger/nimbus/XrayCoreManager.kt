package pm.dnschanger.nimbus

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import xray.Controller
import xray.Xray

/**
 * Process-wide owner of the Xray core instance — the CoreManager-equivalent
 * for the second engine (BPB-VPN's CoreManager.kt plays the same role there,
 * GPLv3; this file is our own implementation).
 *
 * Contract with the Dart side (`lib/services/xray_engine.dart`):
 *   - `startXray {config, mode}` — mode is `vpn` (open a VpnService, hand
 *     Xray the TUN fd) or `proxy` (no TUN, SOCKS only).
 *   - `stopXray` — close the instance and the VpnService.
 *   - `xrayStatus` — `{"running": bool, "version": String, "available": bool,
 *     "error": String?, "trafficUp": long, "trafficDown": long}`.
 *
 * The `xray.aar` is produced by `scripts/build_xray.sh` and linked into the
 * app; without it this file would not compile, which is intentional — the
 * release workflow builds the .aar before Flutter builds (see
 * `.github/workflows/xray-android.yml`).
 *
 * Threading: the Xray instance is started on a worker thread (its Start can
 * block on network setup); the MethodChannel result is always completed on
 * the main thread. In `vpn` mode the result only means the VpnService was
 * launched — the real state is in [status], which the Dart side polls.
 * One tunnel at a time: the Dart side never starts Aether and Xray together,
 * and [start] refuses while one is already running.
 */
object XrayCoreManager {
    private const val TAG = "VoidrauXray"

    @Volatile
    var running: Boolean = false
        private set

    @Volatile
    var lastError: String? = null
        private set

    /** True once the xray.aar is linked and the controller exists. */
    @Volatile
    var xrayAvailable: Boolean = false
        private set

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var controller: Controller? = null

    @Volatile
    private var filesDirPath: String? = null

    /** Creates the controller and points Xray at the app's files dir (geo
     * files and certificates). Called once, on first use. */
    @Synchronized
    private fun ensureController(context: Context): Controller? {
        controller?.let { return it }
        return try {
            val dir = context.applicationContext.filesDir.absolutePath
            Xray.initEnv(dir)
            filesDirPath = dir
            Xray.newController().also {
                controller = it
                xrayAvailable = true
                Log.i(TAG, "Xray controller ready, version=${version()}")
            }
        } catch (e: Throwable) {
            lastError = "xray_unavailable: ${e.message}"
            Log.e(TAG, "Xray controller failed to start", e)
            null
        }
    }

    /** Xray-core version from the linked .aar, or "" when unavailable. */
    fun version(): String = try {
        Xray.version()
    } catch (_: Throwable) {
        ""
    }

    fun status(): Map<String, Any?> {
        val (up, down) = traffic()
        return mapOf(
            "running" to running,
            "version" to version(),
            "available" to xrayAvailable,
            "error" to lastError,
            "trafficUp" to up,
            "trafficDown" to down,
        )
    }

    /** Uplink / downlink bytes of the proxy outbound; (0, 0) when stopped. */
    fun traffic(): Pair<Long, Long> {
        val c = controller ?: return 0L to 0L
        if (!running) return 0L to 0L
        return try {
            c.trafficUp() to c.trafficDown()
        } catch (_: Exception) {
            0L to 0L
        }
    }

    fun start(activity: Activity, config: String, mode: String, result: MethodChannel.Result) {
        if (running) {
            result.success(null)
            return
        }
        if (config.isBlank()) {
            result.error("xray_config", "empty Xray config", null)
            return
        }
        val ctx = activity.applicationContext
        if (ensureController(ctx) == null) {
            result.error("xray_unavailable", lastError ?: "Xray core is not linked", null)
            return
        }
        if (mode == "proxy") {
            Thread {
                val ok = startController(config, 0)
                mainHandler.post {
                    if (ok) result.success(null)
                    else result.error("xray_start", lastError ?: "Xray did not start", null)
                }
            }.start()
            return
        }
        // vpn mode: the VpnService owns the TUN fd and calls back into
        // startController. VPN permission is requested by the app's normal
        // prepare flow (NimbusPlugin "prepareVpn"); refuse clearly if the
        // user has not granted it yet instead of crashing.
        if (VpnService.prepare(activity) != null) {
            lastError = "vpn_permission: grant the VPN permission first"
            result.error("vpn_permission", lastError, null)
            return
        }
        val intent = Intent(ctx, XrayVpnService::class.java)
            .setAction(XrayVpnService.ACTION_START)
            .putExtra(XrayVpnService.EXTRA_CONFIG, config)
        try {
            ctx.startForegroundService(intent)
        } catch (e: Exception) {
            lastError = "xray_service: ${e.message}"
            Log.e(TAG, "Could not start XrayVpnService", e)
            result.error("xray_service", lastError, null)
            return
        }
        // The service reports the real outcome through status()/onConnected;
        // success here only means it was launched.
        result.success(null)
    }

    /**
     * Starts the Xray instance on [tunFd] (0: no TUN, proxy mode). Called by
     * [XrayVpnService] after it establishes the TUN, or by [start] for proxy
     * mode. Returns false (with [lastError] set) when the core refuses the
     * config or is already running.
     */
    @Synchronized
    fun startController(config: String, tunFd: Int): Boolean {
        if (running) return true
        val c = controller ?: return false
        return try {
            c.start(config, tunFd)
            running = true
            lastError = null
            Log.i(TAG, "Xray started (tunFd=$tunFd)")
            true
        } catch (e: Exception) {
            lastError = "xray_start: ${e.message}"
            Log.e(TAG, "Xray start failed", e)
            false
        }
    }

    fun stop(activity: Activity) {
        stopController()
        try {
            activity.applicationContext.stopService(
                Intent(activity.applicationContext, XrayVpnService::class.java),
            )
        } catch (_: Exception) {
        }
    }

    /** Stops the Xray instance; the VpnService calls this from onDestroy. */
    @Synchronized
    fun stopController() {
        try {
            controller?.stop()
        } catch (_: Exception) {
        }
        running = false
    }

    /** Called by the VpnService once the Xray instance is really up. */
    fun onConnected() {
        running = true
        lastError = null
    }

    /** Called by the VpnService once the instance and the TUN are down. */
    fun onStopped() {
        running = false
    }

    @Suppress("UNUSED_PARAMETER")
    fun onServiceIntent(intent: Intent): Boolean = false
}
