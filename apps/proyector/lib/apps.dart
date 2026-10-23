import 'package:flutter/services.dart';

const _channel = MethodChannel('proyector/launch');

/// Una app de TV instalada en el proyector (las de un launcher leanback).
class TvApp {
  const TvApp({
    required this.package,
    required this.activity,
    required this.label,
    this.icon,
    this.banner,
    this.lastUsed,
  });

  final String package;
  final String activity;
  final String label;
  final Uint8List? icon;

  /// Banner 16:9 de Android TV (320×180); null si la app no trae.
  final Uint8List? banner;

  /// Última vez que estuvo en pantalla; null si nunca o sin el permiso.
  final DateTime? lastUsed;
}

/// Paquetes que no tiene sentido mostrar en el inicio.
const hiddenPackages = {
  'dev.valdo.proyector',
  'com.jixin.launcher5',
  'org.liskovsoft.androidtv.rukeyboard',
};

/// Orden de las apps que nunca se han abierto (o sin el permiso de uso); lo
/// demás va después, alfabético.
const preferredOrder = [
  'com.google.android.youtube.tv',
  'com.spotify.tv.android',
  'com.crunchyroll.crunchyroid',
];

/// Siempre al final de la fila.
const playStore = 'com.android.vending';

Future<List<TvApp>> installedApps() async {
  final raw =
      await _channel.invokeMethod<List<Object?>>('installedApps') ?? const [];
  final apps = <TvApp>[];
  for (final item in raw) {
    final m = (item as Map).cast<String, Object?>();
    final package = m['package'] as String;
    if (hiddenPackages.contains(package)) continue;
    final icon = m['icon'];
    final banner = m['banner'];
    final used = m['lastUsed'];
    apps.add(
      TvApp(
        package: package,
        activity: m['activity'] as String,
        label: m['label'] as String,
        icon: icon is Uint8List ? icon : null,
        banner: banner is Uint8List ? banner : null,
        lastUsed: used is int
            ? DateTime.fromMillisecondsSinceEpoch(used)
            : null,
      ),
    );
  }
  int rank(TvApp a) {
    final i = preferredOrder.indexOf(a.package);
    return i < 0 ? preferredOrder.length : i;
  }

  // La abierta más reciente primero; las que nunca se abrieron después (en el
  // orden preferido y luego alfabético); la Play Store siempre al final.
  apps.sort((a, b) {
    final store = (a.package == playStore ? 1 : 0).compareTo(
      b.package == playStore ? 1 : 0,
    );
    if (store != 0) return store;
    final ua = a.lastUsed, ub = b.lastUsed;
    if (ua != null || ub != null) {
      if (ua == null) return 1;
      if (ub == null) return -1;
      return ub.compareTo(ua);
    }
    final r = rank(a).compareTo(rank(b));
    return r != 0 ? r : a.label.toLowerCase().compareTo(b.label.toLowerCase());
  });
  return apps;
}

/// Una pantalla concreta de una app (p. ej. unos ajustes).
typedef AppActivity = ({String package, String activity});

Future<bool> hasActivity(AppActivity a) async =>
    await _channel.invokeMethod<bool>('hasActivity', {
      'package': a.package,
      'class': a.activity,
    }) ??
    false;

/// Ajustes del fabricante (trapezoide, proyección, imagen…) conocidos.
const vendorSettings = <AppActivity>[
  (
    package: 'com.jixin.settings5',
    activity: 'com.jixin.settings5.SettingsActivity',
  ),
];

/// Ajustes de Android TV (apps, cuentas, mandos, redes).
const androidSettings = (
  package: 'com.android.tv.settings',
  activity: 'com.android.tv.settings.MainSettings',
);

Future<void> launchPackage(String package) async {
  try {
    await _channel.invokeMethod<bool>('launchPackage', {'package': package});
  } on PlatformException catch (e) {
    throw StateError('No se pudo abrir $package: ${e.message}');
  }
}

Future<void> launchComponent(String package, String cls) async {
  try {
    await _channel.invokeMethod<bool>('launchComponent', {
      'package': package,
      'class': cls,
    });
  } on PlatformException catch (e) {
    throw StateError('No se pudo abrir $package: ${e.message}');
  }
}
