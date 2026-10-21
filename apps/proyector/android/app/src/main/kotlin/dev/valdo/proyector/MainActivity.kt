package dev.valdo.proyector

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

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
                    // Trae el receptor al frente (p. ej. para mostrar el tablero de trading
                    // encima de YouTube). Permitido desde segundo plano por SYSTEM_ALERT_WINDOW.
                    "bringToFront" -> {
                        try {
                            val intent = Intent(applicationContext, MainActivity::class.java)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                            applicationContext.startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("front", e.message, null)
                        }
                    }
                    // Apps de TV instaladas (las que aparecen en un launcher leanback), con icono PNG.
                    "installedApps" -> result.success(installedApps())
                    // Abre una app por paquete (launcher): para los tiles del inicio.
                    "launchPackage" -> {
                        val pkg = call.argument<String>("package")
                        val pm = applicationContext.packageManager
                        val intent = if (pkg == null) null else (pm.getLeanbackLaunchIntentForPackage(pkg) ?: pm.getLaunchIntentForPackage(pkg))
                        if (intent == null) {
                            result.error("launch", "no se puede abrir $pkg", null)
                        } else {
                            try {
                                applicationContext.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("launch", e.message, null)
                            }
                        }
                    }
                    // Abre una Activity concreta (p. ej. los ajustes del fabricante).
                    "launchComponent" -> {
                        val pkg = call.argument<String>("package")
                        val cls = call.argument<String>("class")
                        if (pkg == null || cls == null) {
                            result.error("args", "falta package/class", null)
                            return@setMethodCallHandler
                        }
                        try {
                            applicationContext.startActivity(Intent().setClassName(pkg, cls).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("launch", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun installedApps(): List<Map<String, Any?>> {
        val pm = applicationContext.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LEANBACK_LAUNCHER)
        return pm.queryIntentActivities(intent, 0).map { ri ->
            val icon = try {
                val d = ri.loadIcon(pm)
                val bmp = Bitmap.createBitmap(128, 128, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bmp)
                d.setBounds(0, 0, canvas.width, canvas.height)
                d.draw(canvas)
                ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
            } catch (_: Exception) {
                null
            }
            mapOf(
                "package" to ri.activityInfo.packageName,
                "activity" to ri.activityInfo.name,
                "label" to ri.loadLabel(pm).toString(),
                "icon" to icon,
            )
        }
    }
}
