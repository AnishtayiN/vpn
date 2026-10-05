package pm.dnschanger.nimbus

import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.annotation.RequiresApi

@RequiresApi(24)
class NimbusTileService : TileService() {
    override fun onStartListening() {
        qsTile?.state =
            if (NimbusVpnService.running.get()) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        qsTile?.label = "VoidrauVPN"
        qsTile?.updateTile()
    }

    override fun onClick() {
        // Retired build: no tunnel from here — bring the update screen up so
        // the user sees where the new version is.
        if (getSharedPreferences(NimbusVpnService.PREFS, MODE_PRIVATE)
                .getBoolean("blocked", false)
        ) {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            return
        }
        val up = NimbusVpnService.running.get()
        val intent = Intent(this, NimbusVpnService::class.java)
            .setAction(if (up) NimbusVpnService.ACTION_STOP else NimbusVpnService.ACTION_START)
        if (!up && Build.VERSION.SDK_INT >= 26) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        qsTile?.state = if (up) Tile.STATE_INACTIVE else Tile.STATE_ACTIVE
        qsTile?.updateTile()
    }
}
