import 'dart:math';

/// Formato del QR con el que el teléfono se vincula a una pantalla:
///   proyector://pair?v=1&id=<id>&n=<nombre>&h=<host>&p=<puerto>&t=<token>
const pairingScheme = 'proyector';
const pairingHost = 'pair';
const pairingVersion = 1;

/// Lo que responde `GET /health` del receptor.
const receiverApp = 'proyector';
const receiverApiVersion = 2;

final _idRe = RegExp(r'^[a-z0-9]{8,32}$');
final _tokenRe = RegExp(r'^[A-Za-z0-9_-]{16,128}$');
final _spaceRe = RegExp(r'\s');

/// Lo que el proyector mete en su QR y el teléfono guarda al escanearlo.
class PairingPayload {
  const PairingPayload({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.token,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String token;

  Uri toUri() => Uri(
        scheme: pairingScheme,
        host: pairingHost,
        queryParameters: {
          'v': '$pairingVersion',
          'id': id,
          'n': name,
          'h': host,
          'p': '$port',
          't': token,
        },
      );

  Uri get baseUrl => Uri(scheme: 'http', host: host, port: port);

  /// Lanza [FormatException] con un mensaje en español si el QR no sirve.
  static PairingPayload parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != pairingScheme || uri.host != pairingHost) {
      throw const FormatException('Este QR no es de Proyector');
    }
    final q = uri.queryParameters;
    final version = int.tryParse(q['v'] ?? '');
    if (version == null || version > pairingVersion) {
      throw const FormatException('QR de una versión nueva: actualiza la app');
    }
    final id = q['id'] ?? '';
    if (!_idRe.hasMatch(id)) throw const FormatException('QR inválido: falta el id');
    final token = q['t'] ?? '';
    if (!_tokenRe.hasMatch(token)) throw const FormatException('QR inválido: falta el código');
    final host = (q['h'] ?? '').trim();
    if (host.isEmpty || host.contains(_spaceRe)) throw const FormatException('QR inválido: falta la dirección');
    final port = int.tryParse(q['p'] ?? '');
    if (port == null || port < 1 || port > 65535) throw const FormatException('QR inválido: puerto');
    var name = (q['n'] ?? '').trim();
    if (name.isEmpty) name = 'Proyector';
    if (name.length > 40) name = name.substring(0, 40);
    return PairingPayload(id: id, name: name, host: host, port: port, token: token);
  }

  static PairingPayload? tryParse(String raw) {
    try {
      return parse(raw);
    } on FormatException {
      return null;
    }
  }
}

const _urlSafe = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
const _lowerAlnum = 'abcdefghijklmnopqrstuvwxyz0123456789';

/// Cadena aleatoria segura con el alfabeto de base64url (para el token).
String randomUrlSafe(int length) => _random(_urlSafe, length);

/// Id de pantalla: 12 caracteres en minúsculas y dígitos.
String randomScreenId() => _random(_lowerAlnum, 12);

String _random(String alphabet, int length) {
  final rng = Random.secure();
  return List.generate(length, (_) => alphabet[rng.nextInt(alphabet.length)]).join();
}
