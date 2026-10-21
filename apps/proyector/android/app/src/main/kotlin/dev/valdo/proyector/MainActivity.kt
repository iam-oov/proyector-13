package dev.valdo.proyector

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import java.io.File

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val keepAlive = Intent(this, KeepAliveService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(keepAlive)
        } else {
            startService(keepAlive)
        }
        saveHomeTitle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        saveHomeTitle(intent)
    }

    // Titulo del inicio desde ADB (lo pregunta la skill /proyector-start):
    //   am start -n dev.valdo.proyector/.MainActivity --es homeTitle "Casa Lopez"
    // El inicio lo relee al volver al frente.
    private fun saveHomeTitle(intent: Intent?) {
        val title = intent?.getStringExtra("homeTitle")?.trim() ?: return
        File(filesDir, "home_title.txt").writeText(title.take(40))
    }

    // Engine compartido creado en ProyectorApplication: una sola instancia de Dart
    // aunque Android abra la Activity en mas de una tarea.
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(ProyectorApplication.ENGINE_ID)

    override fun shouldDestroyEngineWithHost(): Boolean = false
}
