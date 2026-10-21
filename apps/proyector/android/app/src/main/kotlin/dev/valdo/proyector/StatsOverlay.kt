package dev.valdo.proyector

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView

// Tarjeta de trading flotando encima del video (YouTube sigue reproduciendo en
// grande debajo). Sustituye al PiP, que este proyector no soporta. Los textos
// y colores ya vienen calculados desde Dart; aqui solo se dibujan y se lleva
// el contador del siguiente refresh.
object StatsOverlay {
    private var root: LinearLayout? = null
    private var countdown: TextView? = null
    private var until = 0L
    private val handler = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            countdown?.text = countdownText(until - System.currentTimeMillis())
            handler.postDelayed(this, 1000)
        }
    }

    @Suppress("UNCHECKED_CAST")
    fun show(context: Context, data: Map<String, Any?>) {
        val ctx = context.applicationContext
        val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val panel = root ?: LinearLayout(ctx).also { attach(ctx, wm, it) }
        panel.removeAllViews()
        fun dp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, ctx.resources.displayMetrics).toInt()
        fun text(s: String?, size: Float, color: Int = Color.WHITE, bold: Boolean = false) = TextView(ctx).apply {
            text = s ?: ""
            setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
            setTextColor(color)
            if (bold) typeface = Typeface.DEFAULT_BOLD
            maxLines = 1
        }
        fun color(v: Any?, fallback: Int = Color.WHITE) = (v as? Number)?.toInt() ?: fallback

        // Encabezado: "Trading" y el contador.
        val header = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL }
        header.addView(text("Trading", 16f, bold = true), LinearLayout.LayoutParams(0, -2, 1f))
        countdown = text("", 13f, 0xB3FFFFFF.toInt())
        header.addView(countdown)
        panel.addView(header)
        until = (data["nextAt"] as? Number)?.toLong() ?: 0L
        handler.removeCallbacks(tick)
        if (until > 0) handler.post(tick)

        panel.addView(text("P&L del día", 12f, 0x8AFFFFFF.toInt()).apply { setPadding(0, dp(8f), 0, 0) })
        panel.addView(text(data["day"] as? String, 30f, color(data["dayColor"])))

        val minis = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL; setPadding(0, dp(6f), 0, dp(6f)) }
        for (m in (data["minis"] as? List<Map<String, Any?>>).orEmpty()) {
            val col = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
            col.addView(text(m["label"] as? String, 11f, 0x8AFFFFFF.toInt()))
            col.addView(text(m["value"] as? String, 14f, color(m["color"])))
            minis.addView(col, LinearLayout.LayoutParams(0, -2, 1f))
        }
        panel.addView(minis)

        for (r in (data["rows"] as? List<Map<String, Any?>>).orEmpty()) {
            val row = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL; setPadding(0, dp(3f), 0, dp(3f)) }
            row.addView(text(r["symbol"] as? String, 14f, bold = true), LinearLayout.LayoutParams(0, -2, 0.9f))
            row.addView(text(r["price"] as? String, 14f, 0xB3FFFFFF.toInt()), LinearLayout.LayoutParams(0, -2, 1.1f))
            row.addView(text(r["pnl"] as? String, 14f, color(r["color"])).apply { gravity = Gravity.END }, LinearLayout.LayoutParams(0, -2, 1.1f))
            row.addView(text(r["pct"] as? String, 12f, color(r["color"])).apply { gravity = Gravity.END }, LinearLayout.LayoutParams(0, -2, 0.9f))
            panel.addView(row)
        }
        panel.addView(text(data["footer"] as? String, 11f, 0x61FFFFFF.toInt()).apply { setPadding(0, dp(6f), 0, 0) })
    }

    fun hide(context: Context) {
        val v = root ?: return
        handler.removeCallbacks(tick)
        (context.applicationContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager).removeView(v)
        root = null
        countdown = null
    }

    val visible: Boolean get() = root != null

    private fun attach(ctx: Context, wm: WindowManager, panel: LinearLayout) {
        val density = ctx.resources.displayMetrics.density
        panel.orientation = LinearLayout.VERTICAL
        val pad = (20 * density).toInt()
        panel.setPadding(pad, pad, pad, pad)
        panel.background = GradientDrawable().apply {
            setColor(0xE61C2226.toInt())
            cornerRadius = 18 * density
        }
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        val params = WindowManager.LayoutParams(
            (300 * density).toInt(),
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.END
            x = (32 * density).toInt()
            y = (32 * density).toInt()
        }
        wm.addView(panel, params)
        root = panel
    }

    private fun countdownText(ms: Long): String {
        val s = (ms / 1000).coerceAtLeast(0)
        if (s >= 86400) return "⟳ ${s / 86400} d ${(s % 86400) / 3600} h"
        val h = s / 3600
        val m = (s % 3600) / 60
        val sec = (s % 60).toString().padStart(2, '0')
        return if (h > 0) "⟳ $h:${m.toString().padStart(2, '0')}:$sec" else "⟳ $m:$sec"
    }
}
