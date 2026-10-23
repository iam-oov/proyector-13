import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'screens.dart';

/// Lo que cuenta la Roku de sí misma.
class RokuInfo {
  const RokuInfo({required this.name, required this.model, required this.powerOn, required this.ecpMode});

  final String name;
  final String model;

  /// Encendida con imagen. Apagada "en espera rápida" sigue respondiendo por red
  /// (power-mode Ready) y se puede prender; apagada del todo no responde.
  final bool powerOn;

  /// "permissive" o "default" aceptan teclas; "limited"/"disabled" solo lecturas.
  final String ecpMode;

  bool get acceptsKeys => ecpMode == 'permissive' || ecpMode == 'default';
}

/// Una app o entrada de la Roku ("Netflix", "HDMI 1", "PlayStation 4").
class RokuApp {
  const RokuApp({required this.id, required this.name, required this.isInput});

  final String id;
  final String name;
  final bool isInput;
}

/// Roku encontrada en la red del teléfono.
class RokuFound {
  const RokuFound({required this.host, required this.name});

  final String host;
  final String name;
}

/// Roku TV: se controla entera por ECP (HTTP en el puerto 8060, sin emparejar):
/// prender y apagar, volumen, entradas, teclas del control y abrir apps directo
/// en un título (Netflix, YouTube, Disney+, Prime). No dice en qué volumen está
/// ni sabe de brillo: eso se lleva desde la app.
class RokuClient {
  RokuClient(this.screen);

  final Screen screen;

  /// Ids fijos de las apps en el catálogo de Roku (iguales en todas las Roku).
  static const appIds = {
    'netflix': '12',
    'prime': '13',
    'disneyplus': '291097',
    'appletv': '551012',
    'youtube': '837',
    'hbomax': '61322',
    'crunchyroll': '2595',
    'vix': '552828',
    'spotify': '22297',
  };

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri(scheme: 'http', host: screen.host, port: screen.port, path: path, queryParameters: query);

  static const _timeout = Duration(seconds: 4);

  /// Null si no responde (apagada del todo o fuera de la red).
  Future<RokuInfo?> info() async {
    try {
      final r = await http.get(_uri('/query/device-info')).timeout(_timeout);
      if (r.statusCode != 200) return null;
      String tag(String name) => RegExp('<$name>([^<]*)</$name>').firstMatch(r.body)?.group(1) ?? '';
      return RokuInfo(
        name: tag('user-device-name').isEmpty ? tag('friendly-device-name') : tag('user-device-name'),
        model: tag('friendly-model-name'),
        powerOn: tag('power-mode') == 'PowerOn',
        ecpMode: tag('ecp-setting-mode'),
      );
    } catch (_) {
      return null;
    }
  }

  /// App al frente, o null si está en el inicio de Roku (o no responde).
  Future<RokuApp?> activeApp() async {
    try {
      final r = await http.get(_uri('/query/active-app')).timeout(_timeout);
      final m = RegExp(r'<app id="([^"]+)" type="([^"]+)"[^>]*>([^<]*)</app>').firstMatch(r.body);
      if (m == null || m.group(2) == 'home') return null;
      return RokuApp(id: m.group(1)!, name: m.group(3)!, isInput: m.group(2) == 'tvin');
    } catch (_) {
      return null;
    }
  }

  /// Apps instaladas y entradas (HDMI, AV, TV en vivo) con el nombre que les puso la casa.
  Future<List<RokuApp>> apps() async {
    final r = await http.get(_uri('/query/apps')).timeout(_timeout);
    if (r.statusCode != 200) throw StateError('La Roku no deja ver sus apps: activa "Acceso a la red" en Control por aplicaciones móviles');
    return [
      for (final m in RegExp(r'<app id="([^"]+)" type="([^"]+)"[^>]*>([^<]*)</app>').allMatches(r.body))
        RokuApp(id: m.group(1)!, name: m.group(3)!, isInput: m.group(2) == 'tvin'),
    ];
  }

  /// Una tecla del control: Home, Back, Select, Up/Down/Left/Right, Play, Rev, Fwd,
  /// VolumeUp/VolumeDown/VolumeMute, PowerOn/PowerOff, Info (*), InputHDMI1…
  Future<void> key(String key) async {
    final r = await http.post(_uri('/keypress/$key')).timeout(_timeout);
    if (r.statusCode == 403) throw StateError('La Roku no acepta teclas por red: en la TV, Configuración → Sistema → Configuración avanzada → Control por aplicaciones móviles → Acceso a la red → Permisivo');
    if (r.statusCode != 200) throw StateError('La Roku no aceptó la tecla $key (${r.statusCode})');
  }

  /// Varias teclas seguidas (la Roku acepta unas 10 por segundo).
  Future<void> keys(Iterable<String> keys, {Duration gap = const Duration(milliseconds: 60)}) async {
    for (final k in keys) {
      await key(k);
      await Future<void>.delayed(gap);
    }
  }

  /// Abre una app, opcionalmente directo en un contenido (cada app entiende su
  /// propio contentId: Netflix el número del título, YouTube el id del video).
  Future<void> launch(String appId, {String? contentId, String? mediaType}) async {
    final r = await http
        .post(_uri('/launch/$appId', {'contentId': ?contentId, 'mediaType': ?mediaType}))
        .timeout(const Duration(seconds: 8));
    if (r.statusCode == 403) throw StateError('La Roku no acepta órdenes por red: activa "Acceso a la red" (Permisivo) en Control por aplicaciones móviles');
    if (r.statusCode != 200) throw StateError('La Roku no abrió la app ($appId): ${r.statusCode}');
  }

  Future<void> youtube(String videoId) => launch(appIds['youtube']!, contentId: videoId);

  Future<void> powerOn() => key('PowerOn');
  Future<void> powerOff() => key('PowerOff');

  /// Pone el volumen en [level] (0..100). La Roku no dice en cuánto está, así que
  /// baja hasta 0 y sube: unos 10 s con el indicador a la vista.
  Future<void> setVolume(int level) async {
    final target = level.clamp(0, 100);
    await keys(List.filled(100, 'VolumeDown'), gap: const Duration(milliseconds: 30));
    await keys(List.filled(target, 'VolumeUp'), gap: const Duration(milliseconds: 30));
  }

  /// Sube o baja [steps] (negativo baja).
  Future<void> nudgeVolume(int steps) =>
      keys(List.filled(steps.abs(), steps < 0 ? 'VolumeDown' : 'VolumeUp'), gap: const Duration(milliseconds: 30));

  /// Busca Rokus en el Wi-Fi del teléfono (SSDP, 3 s).
  static Future<List<RokuFound>> discover({Duration wait = const Duration(seconds: 3)}) async {
    final found = <String, RokuFound>{};
    RawDatagramSocket? sock;
    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.broadcastEnabled = true;
      const msg = 'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: roku:ecp\r\n\r\n';
      sock.send(msg.codeUnits, InternetAddress('239.255.255.250'), 1900);
      final done = Completer<void>();
      final timer = Timer(wait, () => done.isCompleted ? null : done.complete());
      sock.listen((event) {
        final d = sock?.receive();
        if (d == null) return;
        final host = d.address.address;
        if (found.containsKey(host)) return;
        found[host] = RokuFound(host: host, name: 'Roku');
      });
      await done.future;
      timer.cancel();
    } catch (_) {
      // Sin red o sin permiso de multicast: lista vacía y se escribe la IP a mano.
    } finally {
      sock?.close();
    }
    // Nombre real de cada una, en paralelo.
    final named = await Future.wait(found.values.map((f) async {
      final i = await RokuClient(Screen.roku(f.host)).info();
      return RokuFound(host: f.host, name: i == null || i.name.isEmpty ? f.name : i.name);
    }));
    return named;
  }
}
