package pm.dnschanger.nimbus

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * VpnService sibling of [NimbusVpnService] for the Xray engine only.
 *
 * It owns the TUN device and hands its file descriptor to
 * [XrayCoreManager.startController]; Xray-core itself reads packets from the
 * fd (see `xray/xray.go`, env `xray.tun.fd`). The app excludes itself from
 * the tunnel, so Xray's own sockets bypass it without `protect()` — same
 * reasoning as the Aether path.
 *
 * Lifecycle: started by [XrayCoreManager.start] with ACTION_START + the
 * config JSON; stopped by ACTION_STOP or by the manager's stop(). The
 * service goes foreground immediately (same notification channel as the
 * Aether service) so Android never kills it mid-handshake. Only one engine
 * runs at a time — the Dart side guarantees Aether is stopped first.
 *
 * NOTE: this service is deliberately small: no split tunneling, no kill
 * switch of its own — Xray's own routing rules in the generated config
 * decide what goes through the tunnel, and the Dart side's kill switch
 * (which watches the VPN state) applies to both engines.
 */
class XrayVpnService : VpnService() {

    @Volatile
    private var tun: ParcelFileDescriptor? = null

    @Volatile
    private var config: String = ""

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START, null -> {
                config = intent?.getStringExtra(EXTRA_CONFIG) ?: ""
                if (config.isBlank()) {
                    Log.w(TAG, "XrayVpnService started without a config")
                    stopSelf()
                    return START_NOT_STICKY
                }
                startForegroundCompat()
                Thread { establishAndStart() }.start()
            }
        }
        return START_NOT_STICKY
    }

    private fun establishAndStart() {
        val builder = Builder()
            .setSession("VoidrauVPN")
            .setMtu(1500)
            .setBlocking(false)
            .addAddress("198.18.0.1", 30)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("1.1.1.1")
            .addDnsServer("1.0.0.1")
        try {
            builder.addDisallowedApplication(packageName)
        } catch (_: Exception) {
        }
        val descriptor = try {
            builder.establish()
        } catch (e: Exception) {
            Log.e(TAG, "Android refused the VPN interface: ${e.message}")
            stopSelf()
            return
        }
        if (descriptor == null) {
            Log.e(TAG, "Android could not create the VPN interface")
            stopSelf()
            return
        }
        tun = descriptor
        val fd = try {
            descriptor.detachFd()
        } catch (e: Exception) {
            Log.e(TAG, "Could not detach the TUN fd: ${e.message}")
            stopSelf()
            return
        }
        if (!XrayCoreManager.startController(config, fd)) {
            try {
                descriptor.close()
            } catch (_: Exception) {
            }
            stopSelf()
            return
        }
        XrayCoreManager.onConnected()
        Log.i(TAG, "Xray TUN established, fd=$fd")
    }

    override fun onDestroy() {
        XrayCoreManager.stopController()
        try {
            tun?.close()
        } catch (_: Exception) {
        }
        tun = null
        XrayCoreManager.onStopped()
        super.onDestroy()
    }

    private fun startForegroundCompat() {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(
                    NimbusVpnService.CHANNEL,
                    "VoidrauVPN",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(
            this, 0, launch, PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, XrayVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val notification: Notification = NotificationCompat.Builder(this, NimbusVpnService.CHANNEL)
            .setContentTitle("VoidrauVPN")
            .setContentText("Protected (Xray)")
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

    companion object {
        const val TAG = "VoidrauXrayVpn"
        const val NOTIF = 1820
        const val ACTION_START = "pm.dnschanger.nimbus.XRAY_START"
        const val ACTION_STOP = "pm.dnschanger.nimbus.XRAY_STOP"
        const val EXTRA_CONFIG = "xrayConfig"
    }
}
