package dev.valdo.proyector

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "proyector/launch")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Abre la URL en su propia tarea (FLAG_ACTIVITY_NEW_TASK) desde el
                    // contexto de la app: asi YouTube no se mete en nuestra tarea y
                    // funciona aunque el receptor este en segundo plano.
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url == null) {
                            result.error("args", "falta url", null)
                            return@setMethodCallHandler
                        }
                        try {
                            // CLEAR_TASK: cada envio recrea la pantalla de YouTube, para no
                            // reutilizar una superficie de video que se quedo en negro.
                            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                            applicationContext.startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("launch", e.message, null)
                        }
                    }
                    // Carpeta privada de la app, para guardar la identidad (id/token/nombre)
                    // en un JSON sin depender de plugins.
                    "filesDir" -> result.success(applicationContext.filesDir.absolutePath)
                    else -> result.notImplemented()
                }
            }
    }
}
