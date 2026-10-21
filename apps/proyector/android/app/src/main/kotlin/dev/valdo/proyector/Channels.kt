package dev.valdo.proyector

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

// Canal "proyector/launch": todo lo que Dart necesita de Android y que no
// depende de una Activity (se usa el contexto de la aplicacion).
object Channels {
    fun install(context: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "proyector/launch")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Abre la URL en su propia tarea. CLEAR_TASK: cada envio recrea la pantalla
                    // de YouTube, para no reutilizar una superficie de video que se quedo en negro.
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url == null) {
                            result.error("args", "falta url", null)
                            return@setMethodCallHandler
                        }
                        start(context, result, Intent(Intent.ACTION_VIEW, Uri.parse(url))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
                    }
                    // Carpeta privada de la app (identity.json, trading.json).
                    "filesDir" -> result.success(context.filesDir.absolutePath)
                    // Trae el receptor al frente (tablero de trading encima de YouTube).
                    // Permitido desde segundo plano por SYSTEM_ALERT_WINDOW.
                    "bringToFront" -> start(context, result, Intent(context, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
                    // Apps de TV instaladas (las de un launcher leanback), con icono PNG.
                    "installedApps" -> result.success(installedApps(context))
                    // Abre una app por paquete: para los tiles del inicio.
                    "launchPackage" -> {
                        val pkg = call.argument<String>("package")
                        val pm = context.packageManager
                        val intent = if (pkg == null) null else (pm.getLeanbackLaunchIntentForPackage(pkg) ?: pm.getLaunchIntentForPackage(pkg))
                        if (intent == null) result.error("launch", "no se puede abrir $pkg", null)
                        else start(context, result, intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    }
                    // Abre una Activity concreta (p. ej. los ajustes del fabricante).
                    "launchComponent" -> {
                        val pkg = call.argument<String>("package")
                        val cls = call.argument<String>("class")
                        if (pkg == null || cls == null) result.error("args", "falta package/class", null)
                        else start(context, result, Intent().setClassName(pkg, cls).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    }
                    // Mascara de proyeccion (figura libre dibujada en el telefono).
                    "setMask" -> {
                        try {
                            @Suppress("UNCHECKED_CAST")
                            val shapes = (call.argument<List<Any?>>("shapes") ?: emptyList()).map { s ->
                                (s as List<Any?>).map { (it as Number).toDouble() }
                            }
                            MaskOverlay.show(
                                context,
                                shapes,
                                call.argument<Double>("feather") ?: 0.0,
                                call.argument<Boolean>("outline") ?: false,
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("mask", e.message, null)
                        }
                    }
                    "clearMask" -> {
                        try {
                            MaskOverlay.hide(context)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("mask", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun start(context: Context, result: MethodChannel.Result, intent: Intent) {
        try {
            context.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("launch", e.message, null)
        }
    }

    private fun installedApps(context: Context): List<Map<String, Any?>> {
        val pm = context.packageManager
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
