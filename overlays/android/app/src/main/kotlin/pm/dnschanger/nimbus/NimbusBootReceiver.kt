package pm.dnschanger.nimbus

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

class NimbusBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }
        val prefs = context.getSharedPreferences(NimbusVpnService.PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean("autoConnect", false)) return
        // A retired build never reconnects itself.
        if (prefs.getBoolean("blocked", false)) return
        val start = Intent(context, NimbusVpnService::class.java)
            .setAction(NimbusVpnService.ACTION_START)
        if (Build.VERSION.SDK_INT >= 26) {
            context.startForegroundService(start)
        } else {
            context.startService(start)
        }
    }
}
