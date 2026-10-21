import 'package:flutter/services.dart';

final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');
const _youtubeHosts = {
  'www.youtube.com',
  'youtube.com',
  'm.youtube.com',
  'youtu.be',
};

// Implementado en MainActivity.kt: lanza el intent VIEW en una tarea nueva.
const _launch = MethodChannel('proyector/launch');

/// Convierte lo que manda el teléfono en una URL que la app de YouTube del
/// proyector entiende. Solo acepta IDs de video o URLs de YouTube.
Uri? youtubeUri({String? videoId, String? url}) {
  if (videoId != null && _videoId.hasMatch(videoId)) {
    return Uri.https('www.youtube.com', '/watch', {'v': videoId});
  }
  if (url != null) {
    final uri = Uri.tryParse(url);
    if (uri != null &&
        uri.scheme == 'https' &&
        _youtubeHosts.contains(uri.host)) {
      return uri;
    }
  }
  return null;
}

/// Volumen del proyector: `{level, max, muted}`.
Future<Map<String, Object?>> getVolume() async =>
    (await _launch.invokeMethod<Map<Object?, Object?>>('getVolume'))!
        .cast<String, Object?>();

Future<Map<String, Object?>> setVolume({
  int? level,
  int? delta,
  bool? mute,
}) async => (await _launch.invokeMethod<Map<Object?, Object?>>('setVolume', {
  'level': ?level,
  'delta': ?delta,
  'mute': ?mute,
}))!.cast<String, Object?>();

/// Trae esta app al frente (encima de YouTube) para mostrar el tablero.
Future<void> bringToFront() async {
  try {
    await _launch.invokeMethod<bool>('bringToFront');
  } on PlatformException {
    // Si no se puede, el tablero queda listo para cuando el usuario vuelva a la app.
  }
}

/// Play/pausa del video de YouTube. False si YouTube no tiene sesión de medios.
Future<bool> mediaControl(String action) async =>
    await _launch.invokeMethod<bool>('mediaControl', {'action': action}) ??
    false;

/// Abre el video en la app de YouTube del proyector (intent VIEW).
Future<void> openVideo(Uri uri) async {
  try {
    await _launch.invokeMethod<bool>('openUrl', {'url': uri.toString()});
  } on PlatformException catch (e) {
    throw StateError('YouTube no abrió $uri: ${e.message}');
  }
}
