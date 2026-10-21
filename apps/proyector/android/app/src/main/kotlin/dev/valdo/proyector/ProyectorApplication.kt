package dev.valdo.proyector

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

// Un solo FlutterEngine para todo el proceso. Como launcher (HOME), Android
// puede crear mas de una instancia de MainActivity (tarea normal + tarea home);
// con el engine compartido, main() y el servidor HTTP corren una sola vez.
class ProyectorApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val engine = FlutterEngine(this)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        Channels.install(applicationContext, engine)
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    }

    companion object {
        const val ENGINE_ID = "main"
    }
}
