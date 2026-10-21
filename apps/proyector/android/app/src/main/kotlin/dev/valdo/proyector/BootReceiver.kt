package dev.valdo.proyector

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

// Arranca el receptor al encender la pantalla. Android solo entrega
// BOOT_COMPLETED a apps que el usuario abrio al menos una vez, y el
// startActivity desde aqui funciona porque la app tiene SYSTEM_ALERT_WINDOW.
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        context.startActivity(
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }
}
