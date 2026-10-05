package pm.dnschanger.nimbus

import android.app.Activity
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList

object NimbusPlugin {
    private const val METHODS = "nimbus.vpn/engine"
    private const val EVENTS = "nimbus.vpn/events"
    private val sinks = CopyOnWriteArrayList<EventChannel.EventSink>()
    private var activity: Activity? = null
    private var vpnResult: MethodChannel.Result? = null

    fun attach(activity: Activity, engine: FlutterEngine) {
        this.activity = activity
        MethodChannel(engine.dartExecutor.binaryMessenger, METHODS).setMethodCallHandler { call, result ->
            when (call.method) {
                "prepareVpn" -> prepare(activity, result)
                "start" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
                    val intent = Intent(activity, NimbusVpnService::class.java)
                        .setAction(NimbusVpnService.ACTION_START)
                    intent.putStringArrayListExtra(
                        NimbusVpnService.EXTRA_ENV,
                        ArrayList((args["env"] as? List<*>)?.map { "$it" } ?: emptyList())
                    )
                    intent.putStringArrayListExtra(
                        NimbusVpnService.EXTRA_ARGS,
                        ArrayList((args["args"] as? List<*>)?.map { "$it" } ?: emptyList())
                    )
                    intent.putExtra(NimbusVpnService.EXTRA_PROTOCOL, "${args["protocol"] ?: "masque"}")
                    intent.putExtra(NimbusVpnService.EXTRA_TRANSPORT, "${args["transport"] ?: "h3"}")
                    intent.putExtra(NimbusVpnService.EXTRA_MODE, "${args["mode"] ?: "vpn"}")
                    intent.putExtra(NimbusVpnService.EXTRA_DNS, args["privateDns"] != false)
                    intent.putExtra(NimbusVpnService.EXTRA_SPLIT_MODE, "${args["splitMode"] ?: "off"}")
                    intent.putStringArrayListExtra(
                        NimbusVpnService.EXTRA_SPLIT_APPS,
                        ArrayList((args["splitApps"] as? List<*>)?.map { "$it" } ?: emptyList())
                    )
                    fun num(key: String, d: Int): Int {
                        val v = args[key]
                        return when (v) {
                            is Number -> v.toInt()
                            else -> v?.toString()?.toIntOrNull() ?: d
                        }
                    }
                    intent.putExtra(NimbusVpnService.EXTRA_SOCKS_PORT, num("socksPort", 1819))
                    intent.putExtra(NimbusVpnService.EXTRA_MTU, num("tunMtu", 1500))
                    intent.putExtra(NimbusVpnService.EXTRA_KILL, args["killSwitch"] != false)
                    intent.putExtra(NimbusVpnService.EXTRA_BYPASS_LAN, args["bypassLan"] != false)
                    intent.putExtra(NimbusVpnService.EXTRA_IPV6, args["ipv6Tunnel"] == true)
                    intent.putExtra(NimbusVpnService.EXTRA_LAN_SHARE, args["lanShare"] == true)
                    intent.putExtra("autoConnect", args["autoConnect"] == true)
                    if (Build.VERSION.SDK_INT >= 26) {
                        activity.startForegroundService(intent)
                    } else {
                        activity.startService(intent)
                    }
                    result.success(null)
                }
                "stop" -> {
                    activity.startService(
                        Intent(activity, NimbusVpnService::class.java)
                            .setAction(NimbusVpnService.ACTION_STOP)
                    )
                    result.success(null)
                }
                "status" -> result.success(NimbusVpnService.statusMap())
                "listApps" -> result.success(listApps(activity))
                "recover" -> result.success(null)
                "isWifi" -> result.success(isWifi(activity))
                "verifyApk" -> {
                    val path = (call.arguments as? Map<*, *>)?.get("path")?.toString()
                    result.success(path != null && verifyApkSigner(activity, path))
                }
                "savePrefs" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
                    activity.getSharedPreferences(NimbusVpnService.PREFS, android.content.Context.MODE_PRIVATE)
                        .edit()
                        .putBoolean("autoConnect", args["autoConnect"] == true)
                        .putBoolean(NimbusVpnService.EXTRA_LAN_SHARE, args["lanShare"] == true)
                        // A retired build: the tunnel must stay down even when
                        // started from the tile or the boot receiver.
                        .putBoolean("blocked", args["blocked"] == true)
                        .apply()
                    result.success(null)
                }
                "installApk" -> {
                    val path = (call.arguments as? Map<*, *>)?.get("path")?.toString()
                    if (path.isNullOrBlank()) {
                        result.error("path", "missing apk path", null)
                    } else {
                        installApk(activity, path)
                        result.success(true)
                    }
                }
                "openBattery" -> {
                    try {
                        val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        activity.startActivity(intent)
                    } catch (_: Exception) {
                        activity.startActivity(Intent(Settings.ACTION_SETTINGS))
                    }
                    result.success(null)
                }
                "openVpnSettings" -> {
                    try {
                        activity.startActivity(Intent("android.net.vpn.SETTINGS"))
                    } catch (_: Exception) {
                        activity.startActivity(Intent(Settings.ACTION_SETTINGS))
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(engine.dartExecutor.binaryMessenger, EVENTS).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    sinks.add(events)
                }

                override fun onCancel(arguments: Any?) {
                    sinks.clear()
                }
            }
        )
    }

    fun onActivityResult(requestCode: Int, resultCode: Int) {
        if (requestCode != 24) return
        vpnResult?.success(resultCode == Activity.RESULT_OK)
        vpnResult = null
    }

    fun emit(payload: Map<String, Any?>) {
        val act = activity ?: return
        act.runOnUiThread {
            sinks.forEach { it.success(payload) }
        }
    }

    private fun prepare(activity: Activity, result: MethodChannel.Result) {
        val intent = VpnService.prepare(activity)
        if (intent == null) {
            result.success(true)
            return
        }
        vpnResult = result
        activity.startActivityForResult(intent, 24)
    }

    private fun installApk(activity: Activity, path: String) {
        val file = File(path)
        val uri = if (Build.VERSION.SDK_INT >= 24) {
            FileProvider.getUriForFile(activity, "${activity.packageName}.files", file)
        } else {
            Uri.fromFile(file)
        }
        val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        activity.startActivity(intent)
    }

    /**
     * The apps a user can actually open, which is what a split-tunnel list is
     * about. The old version dropped every `FLAG_SYSTEM` package, which on most
     * phones also drops the preinstalled browser — the one app people most
     * often want on the bypass list. Preinstalled apps are included now and
     * marked, so the picker can filter them while still showing the ones the
     * user has already selected.
     */
    private fun listApps(activity: Activity): List<Map<String, String>> {
        val pm = activity.packageManager
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val appInfos = pm.queryIntentActivities(launcher, 0)
            .mapNotNull { it.activityInfo?.applicationInfo }
            .distinctBy { it.packageName }
            .ifEmpty { pm.getInstalledApplications(0) }
        return appInfos
            .map { info ->
                val preinstalled = info.flags and
                    (ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
                mapOf(
                    "package" to info.packageName,
                    "label" to (info.loadLabel(pm)?.toString() ?: info.packageName),
                    "system" to if (preinstalled) "1" else "0",
                )
            }
            .sortedBy { it["label"] }
    }

    private fun isWifi(activity: Activity): Boolean {
        val cm = activity.getSystemService(android.content.Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return false
        val capabilities = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
        return capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
    }

    private fun ownSignature(activity: Activity): Signature? {
        val info: PackageInfo = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                activity.packageManager.getPackageInfo(
                    activity.packageName,
                    PackageManager.GET_SIGNING_CERTIFICATES,
                )
            } else {
                @Suppress("DEPRECATION")
                activity.packageManager.getPackageInfo(
                    activity.packageName,
                    PackageManager.GET_SIGNATURES,
                )
            }
        } catch (_: PackageManager.NameNotFoundException) {
            return null
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners?.firstOrNull()
        } else {
            @Suppress("DEPRECATION")
            info.signatures?.firstOrNull()
        }
    }

    private fun verifyApkSigner(activity: Activity, path: String): Boolean {
        val own = ownSignature(activity) ?: return false
        val downloaded = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                activity.packageManager.getPackageArchiveInfo(
                    path,
                    PackageManager.GET_SIGNING_CERTIFICATES,
                )
            } else {
                @Suppress("DEPRECATION")
                activity.packageManager.getPackageArchiveInfo(
                    path,
                    PackageManager.GET_SIGNATURES,
                )
            }
        } catch (_: Exception) {
            return false
        } ?: return false
        val theirs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            downloaded.signingInfo?.apkContentsSigners?.firstOrNull()
        } else {
            @Suppress("DEPRECATION")
            downloaded.signatures?.firstOrNull()
        }
        return theirs != null && own.toByteArray().contentEquals(theirs.toByteArray())
    }
}
