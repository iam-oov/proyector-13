package dev.valdo.proyector

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val keepAlive = Intent(this, KeepAliveService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(keepAlive)
        } else {
            startService(keepAlive)
        }
    }

    // Engine compartido creado en ProyectorApplication: una sola instancia de Dart
    // aunque Android abra la Activity en mas de una tarea.
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(ProyectorApplication.ENGINE_ID)

    override fun shouldDestroyEngineWithHost(): Boolean = false
}
