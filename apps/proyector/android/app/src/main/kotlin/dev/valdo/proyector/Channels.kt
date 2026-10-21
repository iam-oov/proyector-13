package dev.valdo.proyector

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.media.AudioManager
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

// Canal "proyector/launch": todo lo que Dart necesita de Android y que no
// depende de una Activity (se usa el contexto de la aplicacion).
object Channels {
    fun install(context: Context, engine: FlutterEngine) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "proyector/launch")
        channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    // Wi-Fi y Bluetooth para el inicio.
                    "connectivity" -> result.success(Connectivity.snapshot(context))
                    // Empieza a avisar a Dart ("mediaChanged") de lo que reproduce YouTube.
                    "startMediaWatch" -> result.success(
                        MediaWatcher.start(context) { info -> channel.invokeMethod("mediaChanged", info) },
                    )
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
                    // Volumen del proyector (STREAM_MUSIC). FLAG_SHOW_UI muestra la barra
                    // del sistema encima de lo que se esté viendo.
                    "getVolume" -> result.success(volume(context))
                    "setVolume" -> {
                        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val level = call.argument<Int>("level")
                        val delta = call.argument<Int>("delta")
                        val mute = call.argument<Boolean>("mute")
                        try {
                            when {
                                mute != null -> am.adjustStreamVolume(
                                    AudioManager.STREAM_MUSIC,
                                    if (mute) AudioManager.ADJUST_MUTE else AudioManager.ADJUST_UNMUTE,
                                    AudioManager.FLAG_SHOW_UI,
                                )
                                level != null -> am.setStreamVolume(
                                    AudioManager.STREAM_MUSIC,
                                    level.coerceIn(0, am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)),
                                    AudioManager.FLAG_SHOW_UI,
                                )
                                delta != null -> am.adjustStreamVolume(
                                    AudioManager.STREAM_MUSIC,
                                    if (delta > 0) AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER,
                                    AudioManager.FLAG_SHOW_UI,
                                )
                            }
                            result.success(volume(context))
                        } catch (e: Exception) {
                            result.error("volume", e.message, null)
                        }
                    }
                    // Tarjeta de trading encima del video (sustituto del PiP).
                    "showStats" -> {
                        try {
                            @Suppress("UNCHECKED_CAST")
                            StatsOverlay.show(context, (call.arguments as Map<String, Any?>))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("stats", e.message, null)
                        }
                    }
                    "hideStats" -> {
                        StatsOverlay.hide(context)
                        result.success(true)
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

    private fun volume(context: Context): Map<String, Any> {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        return mapOf(
            "level" to am.getStreamVolume(AudioManager.STREAM_MUSIC),
            "max" to am.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
            "muted" to am.isStreamMute(AudioManager.STREAM_MUSIC),
        )
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
