import 'package:flutter/services.dart';

const _channel = MethodChannel('proyector/launch');

/// Una app de TV instalada en el proyector (las de un launcher leanback).
class TvApp {
  const TvApp({
    required this.package,
    required this.activity,
    required this.label,
    this.icon,
  });

  final String package;
  final String activity;
  final String label;
  final Uint8List? icon;
}

/// Paquetes que no tiene sentido mostrar en el inicio.
const hiddenPackages = {
  'dev.valdo.proyector',
  'com.jixin.launcher5',
  'org.liskovsoft.androidtv.rukeyboard',
};

/// Orden preferido para los tiles; lo demás va después, alfabético.
const preferredOrder = [
  'com.google.android.youtube.tv',
  'com.spotify.tv.android',
  'com.crunchyroll.crunchyroid',
  'com.android.vending',
];

Future<List<TvApp>> installedApps() async {
  final raw =
      await _channel.invokeMethod<List<Object?>>('installedApps') ?? const [];
  final apps = <TvApp>[];
  for (final item in raw) {
    final m = (item as Map).cast<String, Object?>();
    final package = m['package'] as String;
    if (hiddenPackages.contains(package)) continue;
    final icon = m['icon'];
    apps.add(
      TvApp(
        package: package,
        activity: m['activity'] as String,
        label: m['label'] as String,
        icon: icon is Uint8List ? icon : null,
      ),
    );
  }
  int rank(TvApp a) {
    final i = preferredOrder.indexOf(a.package);
    return i < 0 ? preferredOrder.length : i;
  }

  apps.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    return r != 0 ? r : a.label.toLowerCase().compareTo(b.label.toLowerCase());
  });
  return apps;
}

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
