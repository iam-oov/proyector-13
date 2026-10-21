import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'config.dart';

/// Login de Spotify con PKCE: abre el navegador y recibe el redirect en un
/// servidor local en 127.0.0.1 (la única dirección HTTP que Spotify permite).
class SpotifyAuth {
  SpotifyAuth({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  /// Si se agrega un scope aquí, el usuario tiene que volver a iniciar sesión.
  static const scopes = [
    'user-read-currently-playing',
    'user-read-playback-state',
    'playlist-read-private',
    'playlist-read-collaborative',
    'user-library-read',
  ];
  static final _scopes = scopes.join(' ');
  static const _key = 'spotify_token';

  final FlutterSecureStorage _storage;

  Future<bool> get isLoggedIn async => await _storage.read(key: _key) != null;

  /// False cuando la sesión guardada es de antes de agregar un scope.
  Future<bool> get hasAllScopes async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return false;
    final token = jsonDecode(raw) as Map<String, dynamic>;
    final granted = (token['scope'] as String? ?? '').split(' ');
    return scopes.every(granted.contains);
  }

  Future<void> logout() => _storage.delete(key: _key);

  Future<void> login() async {
    final verifier = _randomString(64);
    final challenge = base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
    final redirect = Uri.parse(Config.spotifyRedirectUri);
    final authUrl = Uri.https('accounts.spotify.com', '/authorize', {
      'client_id': Config.spotifyClientId,
      'response_type': 'code',
      'redirect_uri': redirect.toString(),
      'scope': _scopes,
      'code_challenge_method': 'S256',
      'code_challenge': challenge,
    });

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, redirect.port);
    try {
      if (!await launchUrl(authUrl, mode: LaunchMode.externalApplication)) {
        throw StateError('No se pudo abrir el navegador');
      }
      final code = await _waitForCode(server, redirect.path);
      final token = await _tokenRequest({
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirect.toString(),
        'client_id': Config.spotifyClientId,
        'code_verifier': verifier,
      });
      await _save(token);
    } finally {
      await server.close(force: true);
    }
  }

  /// Espera el redirect de Spotify; ignora otras peticiones (p. ej. favicon).
  Future<String> _waitForCode(HttpServer server, String path) async {
    await for (final req in server.timeout(const Duration(minutes: 5))) {
      if (req.uri.path != path) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        continue;
      }
      final code = req.uri.queryParameters['code'];
      final error = req.uri.queryParameters['error'];
      req.response
        ..headers.contentType = ContentType.html
        ..write(code != null
            ? '<h2 style="font-family:sans-serif">Listo. Ya puedes volver a la app.</h2>'
            : '<h2 style="font-family:sans-serif">Spotify no dio acceso: $error</h2>');
      await req.response.close();
      if (code == null) throw StateError('Spotify: ${error ?? 'sin code'}');
      return code;
    }
    throw StateError('Spotify no respondió');
  }

  /// Token vigente; lo refresca solo cuando está por vencer.
  Future<String> accessToken() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) throw const SpotifyNotLoggedIn();
    var token = jsonDecode(raw) as Map<String, dynamic>;
    final expiresAt = token['expires_at'] as int;
    if (DateTime.now().millisecondsSinceEpoch > expiresAt - 60000) {
      final fresh = await _tokenRequest({
        'grant_type': 'refresh_token',
        'refresh_token': token['refresh_token'] as String,
        'client_id': Config.spotifyClientId,
      });
      token = {...token, ...fresh};
      await _save(token);
    }
    return token['access_token'] as String;
  }

  Future<Map<String, dynamic>> _tokenRequest(Map<String, String> params) async {
    final r = await http.post(
      Uri.https('accounts.spotify.com', '/api/token'),
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      body: params,
    );
    if (r.statusCode != 200) throw StateError('Spotify token ${r.statusCode}: ${r.body}');
    final token = jsonDecode(r.body) as Map<String, dynamic>;
    token['expires_at'] = DateTime.now().millisecondsSinceEpoch + (token['expires_in'] as int) * 1000;
    return token;
  }

  Future<void> _save(Map<String, dynamic> token) => _storage.write(key: _key, value: jsonEncode(token));

  static String _randomString(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    final rng = Random.secure();
    return List.generate(length, (_) => chars[rng.nextInt(chars.length)]).join();
  }
}

class SpotifyNotLoggedIn implements Exception {
  const SpotifyNotLoggedIn();

  @override
  String toString() => 'Sin sesión de Spotify';
}
