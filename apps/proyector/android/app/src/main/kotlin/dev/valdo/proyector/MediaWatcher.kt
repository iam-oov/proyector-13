package dev.valdo.proyector

import android.content.ComponentName
import android.content.Context
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.SystemClock
import android.service.notification.NotificationListenerService

// Necesario para leer las sesiones de medios de otras apps (YouTube). No hace
// nada con las notificaciones. Se habilita una vez por adb:
//   cmd notification allow_listener dev.valdo.proyector/dev.valdo.proyector.MediaListener
class MediaListener : NotificationListenerService()

// Vigila la sesion de medios de YouTube y avisa a Dart cada vez que cambia el
// titulo o el estado. Con eso la cola sabe cuando termino un video (YouTube
// pasa solo a un "recomendado" y nosotros lo reemplazamos por la siguiente).
object MediaWatcher {
    private const val YOUTUBE = "com.google.android.youtube.tv"
    private var controller: MediaController? = null
    private var onChange: ((Map<String, Any?>) -> Unit)? = null

    private val callback = object : MediaController.Callback() {
        override fun onMetadataChanged(metadata: MediaMetadata?) = emit()
        override fun onPlaybackStateChanged(state: PlaybackState?) = emit()
        override fun onSessionDestroyed() {
            controller = null
            onChange?.invoke(mapOf("title" to null, "state" to 0))
        }
    }

    /** Devuelve false si falta el permiso de "acceso a notificaciones". */
    fun start(context: Context, listener: (Map<String, Any?>) -> Unit): Boolean {
        onChange = listener
        val msm = context.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
        val component = ComponentName(context, MediaListener::class.java)
        return try {
            msm.addOnActiveSessionsChangedListener({ sessions -> attach(sessions.orEmpty()) }, component)
            attach(msm.getActiveSessions(component))
            true
        } catch (_: SecurityException) {
            false
        }
    }

    /** Play/pausa del video de YouTube (botones del telefono). False si no hay sesion. */
    fun control(action: String): Boolean {
        val controls = controller?.transportControls ?: return false
        when (action) {
            "play" -> controls.play()
            "pause" -> controls.pause()
            else -> return false
        }
        return true
    }

    /** Posicion actual en ms: la del ultimo estado mas lo que ha corrido desde entonces. */
    private fun currentPosition(): Long? {
        val st = controller?.playbackState ?: return null
        var pos = st.position
        if (st.state == PlaybackState.STATE_PLAYING && st.lastPositionUpdateTime > 0) {
            pos += ((SystemClock.elapsedRealtime() - st.lastPositionUpdateTime) * st.playbackSpeed).toLong()
        }
        return pos
    }

    /**
     * Salta a [toMs], o se mueve [byMs] desde donde va ("adelantalo 5 min").
     * Devuelve la posicion nueva en ms, o null si YouTube no tiene sesion.
     */
    fun seek(toMs: Long?, byMs: Long?): Long? {
        val c = controller ?: return null
        val target = toMs ?: ((currentPosition() ?: return null) + (byMs ?: 0L))
        val duration = c.metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L
        var pos = target.coerceAtLeast(0L)
        if (duration > 0) pos = pos.coerceAtMost(duration - 1000)
        c.transportControls.seekTo(pos)
        return pos
    }

    private fun attach(sessions: List<MediaController>) {
        val yt = sessions.firstOrNull { it.packageName == YOUTUBE }
        if (yt?.sessionToken == controller?.sessionToken) return
        controller?.unregisterCallback(callback)
        controller = yt
        yt?.registerCallback(callback)
        emit()
    }

    private fun emit() {
        val c = controller
        val md = c?.metadata
        val st = c?.playbackState
        onChange?.invoke(
            mapOf(
                "title" to (md?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: md?.description?.title?.toString()),
                "state" to (st?.state ?: 0),
                "position" to (st?.position ?: 0L),
                "duration" to (md?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L),
            ),
        )
    }
}
