package dev.valdo.proyector

import android.content.Context
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.os.Build
import android.view.View
import android.view.WindowManager

// Mascara de proyeccion: una ventana encima de todo, negra (el proyector no
// ilumina) con huecos transparentes donde si se ve la imagen. En Amlogic el
// video va en un plano debajo del OSD, asi que tambien recorta a YouTube.
// Requiere SYSTEM_ALERT_WINDOW (concedido por adb). No recibe foco.
object MaskOverlay {
    private var view: MaskView? = null

    /** shapes: poligonos con coordenadas normalizadas 0..1 [x0, y0, x1, y1, ...]. */
    fun show(context: Context, shapes: List<List<Double>>, feather: Double, outline: Boolean) {
        val v = view ?: MaskView(context.applicationContext).also { attach(context, it) }
        v.update(shapes, feather.toFloat(), outline)
    }

    fun hide(context: Context) {
        val v = view ?: return
        (context.applicationContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager).removeView(v)
        view = null
    }

    private fun attach(context: Context, v: MaskView) {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        // Sin FLAG_NOT_TOUCHABLE a proposito: desde Android 12 el sistema limita a
        // 0.8 la opacidad de overlays "no tocables" y el negro dejaria pasar la
        // imagen. El proyector no tiene pantalla tactil y, con NOT_FOCUSABLE, las
        // teclas del control siguen llegando a la app de abajo.
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply { alpha = 1f }
        (context.applicationContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager).addView(v, params)
        view = v
    }

    private class MaskView(context: Context) : View(context) {
        private var shapes: List<List<Double>> = emptyList()
        private var feather = 0f
        private var outline = false
        private val clear = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR)
            style = Paint.Style.FILL
        }
        private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            style = Paint.Style.STROKE
            strokeWidth = 4f
        }

        init {
            // El CLEAR con desenfoque necesita dibujo por software.
            setLayerType(LAYER_TYPE_SOFTWARE, null)
        }

        fun update(shapes: List<List<Double>>, feather: Float, outline: Boolean) {
            this.shapes = shapes
            this.feather = feather
            this.outline = outline
            invalidate()
        }

        override fun onDraw(canvas: Canvas) {
            canvas.drawColor(Color.BLACK)
            val w = width.toFloat()
            val h = height.toFloat()
            // Suavizado del borde: radio en pixeles relativo al lado corto.
            val blur = feather * minOf(w, h)
            clear.maskFilter = if (blur > 0.5f) BlurMaskFilter(blur, BlurMaskFilter.Blur.NORMAL) else null
            for (s in shapes) {
                if (s.size < 6) continue
                val path = Path()
                path.moveTo((s[0] * w).toFloat(), (s[1] * h).toFloat())
                var i = 2
                while (i + 1 < s.size) {
                    path.lineTo((s[i] * w).toFloat(), (s[i + 1] * h).toFloat())
                    i += 2
                }
                path.close()
                canvas.drawPath(path, clear)
                if (outline) canvas.drawPath(path, stroke)
            }
        }
    }
}
