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
