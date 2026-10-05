package pm.dnschanger.nimbus

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.os.Build
import android.widget.RemoteViews

class NimbusWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val up = NimbusVpnService.running.get()
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.nimbus_widget)
            views.setTextViewText(
                R.id.widget_status,
                if (up) "Protected" else "Disconnected",
            )
            views.setTextViewText(R.id.widget_action, if (up) "Disconnect" else "Connect")
            val action = Intent(context, NimbusVpnService::class.java)
                .setAction(if (up) NimbusVpnService.ACTION_STOP else NimbusVpnService.ACTION_START)
            val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            val pi = if (!up && Build.VERSION.SDK_INT >= 26) {
                PendingIntent.getForegroundService(context, 2, action, flags)
            } else {
                PendingIntent.getService(context, 2, action, flags)
            }
            views.setOnClickPendingIntent(R.id.widget_action, pi)
            val open = PendingIntent.getActivity(
                context,
                3,
                context.packageManager.getLaunchIntentForPackage(context.packageName),
                flags,
            )
            views.setOnClickPendingIntent(R.id.widget_title, open)
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
