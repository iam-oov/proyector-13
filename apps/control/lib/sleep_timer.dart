import 'dart:async';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';

import 'projector.dart';
import 'roku.dart';
import 'screens.dart';
import 'tv.dart';

/// "Apágala en 30 minutos": una alarma de Android que apaga la pantalla a la
/// hora aunque la app esté cerrada (un Timer de Dart muere con la app).
class SleepTimer {
  static const _alarmId = 7013;

  /// Cuándo se apaga la pantalla elegida, o null si no hay temporizador.
  static DateTime? at;
  static String? screenName;

  static Future<void> init() async {
    try {
      await AndroidAlarmManager.initialize();
    } catch (_) {
      // Sin alarmas (iOS o plugin ausente): queda el Timer mientras la app viva.
    }
  }

  static Timer? _fallback;

  /// Programa el apagado. Devuelve false si solo quedó el Timer en memoria.
  static Future<bool> schedule(Screen s, Duration after) async {
    await cancel();
    at = DateTime.now().add(after);
    screenName = s.name;
    _fallback = Timer(after, () => fire(s.toJson()));
    try {
      return await AndroidAlarmManager.oneShotAt(
        at!,
        _alarmId,
        sleepTimerFired,
        exact: true,
        wakeup: true,
        rescheduleOnReboot: false,
        params: s.toJson(),
      );
    } catch (_) {
      return false;
    }
  }

  static Future<void> cancel() async {
    _fallback?.cancel();
    _fallback = null;
    at = null;
    screenName = null;
    try {
      await AndroidAlarmManager.cancel(_alarmId);
    } catch (_) {}
  }

  /// Apaga la pantalla según su tipo (la TV sin receptor solo se detiene).
  static Future<void> fire(Map<String, dynamic> json) async {
    final s = Screen.fromJson(json);
    try {
      if (s.isRoku) {
        await RokuClient(s).powerOff();
      } else if (s.isTv) {
        await TvClient(s).stop();
      } else {
        await ProjectorClient(s).media('stop');
      }
    } catch (_) {
      // La pantalla ya estaba apagada o fuera de la red.
    }
    if (at != null && !at!.isAfter(DateTime.now())) {
      at = null;
      screenName = null;
    }
  }
}

/// Corre en un isolate aparte, con la app cerrada: solo HTTP, nada de UI.
@pragma('vm:entry-point')
Future<void> sleepTimerFired(int id, Map<String, dynamic> params) => SleepTimer.fire(params);
