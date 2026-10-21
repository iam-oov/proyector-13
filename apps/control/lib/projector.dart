import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared/shared.dart';

import 'screens.dart';

class ReceiverHealth {
  const ReceiverHealth({required this.id, required this.name, required this.version});

  final String id;
  final String name;
  final int version;
}

class ProjectorUnauthorized implements Exception {
  const ProjectorUnauthorized();

  @override
  String toString() => 'La pantalla rechazó el código: vuelve a escanear su QR';
}

/// Cliente del receptor (apps/proyector) de una pantalla vinculada.
class ProjectorClient {
  ProjectorClient(this.screen);

  final Screen screen;

  Uri _url(String path) => Uri(scheme: 'http', host: screen.host, port: screen.port, path: path);

  Map<String, String> get _auth => {'authorization': 'Bearer ${screen.token}'};

  /// Null si no responde o lo que responde no es un receptor nuestro.
  Future<ReceiverHealth?> health() async {
    try {
      final r = await http.get(_url('/health')).timeout(const Duration(seconds: 2));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (j['app'] != receiverApp || j['id'] == null) return null;
      return ReceiverHealth(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? screen.name,
        version: (j['version'] as int?) ?? 1,
      );
    } catch (_) {
      return null;
    }
  }

  /// Se presenta ante la pantalla; opcionalmente la renombra. Devuelve el
  /// nombre vigente de la pantalla y los teléfonos que conoce.
  Future<({String name, List<String> phones})> pair(String phoneName, {String? screenName}) async {
    final r = await http
        .post(
          _url('/pair'),
          headers: {'content-type': 'application/json', ..._auth},
          body: jsonEncode({'phoneName': phoneName, 'screenName': ?screenName}),
        )
        .timeout(const Duration(seconds: 5));
    if (r.statusCode == 401) throw const ProjectorUnauthorized();
    if (r.statusCode != 200) throw StateError('Pantalla ${r.statusCode}: ${r.body}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (
      name: (j['name'] as String?) ?? screen.name,
      phones: [for (final p in (j['phones'] as List?) ?? const []) p.toString()],
    );
  }

  /// Manda la bitácora y/o pide mostrar u ocultar el tablero de trading.
  Future<void> trading({bool? show, List<Trade>? trades}) async {
    final r = await http
        .post(
          _url('/trading'),
          headers: {'content-type': 'application/json', ..._auth},
          body: jsonEncode({
            'show': ?show,
            'trades': ?trades?.map((t) => t.toJson()).toList(),
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode == 401) throw const ProjectorUnauthorized();
    if (r.statusCode != 200) throw StateError('Pantalla ${r.statusCode}: ${r.body}');
  }

  /// Máscara de figura libre: polígonos normalizados 0..1. `save: false` para
  /// las actualizaciones en vivo mientras se dibuja.
  Future<void> mask({
    required List<List<double>> shapes,
    double feather = 0,
    bool outline = false,
    bool save = true,
  }) async {
    final r = await http
        .post(
          _url('/mask'),
          headers: {'content-type': 'application/json', ..._auth},
          body: jsonEncode({'shapes': shapes, 'feather': feather, 'outline': outline, 'save': save}),
        )
        .timeout(const Duration(seconds: 5));
    if (r.statusCode == 401) throw const ProjectorUnauthorized();
    if (r.statusCode != 200) throw StateError('Pantalla ${r.statusCode}: ${r.body}');
  }

  Future<void> clearMask() async {
    final r = await http
        .post(_url('/mask'), headers: {'content-type': 'application/json', ..._auth}, body: '{"clear":true}')
        .timeout(const Duration(seconds: 5));
    if (r.statusCode == 401) throw const ProjectorUnauthorized();
    if (r.statusCode != 200) throw StateError('Pantalla ${r.statusCode}: ${r.body}');
  }

  Future<void> play(VideoCandidate video) async {
    final r = await http
        .post(
          _url('/play'),
          headers: {'content-type': 'application/json', ..._auth},
          body: jsonEncode({'videoId': video.id, 'title': video.title}),
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode == 401) throw const ProjectorUnauthorized();
    if (r.statusCode != 200) throw StateError('Pantalla ${r.statusCode}: ${r.body}');
  }
}
