import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared/shared.dart';

import 'spotify_auth.dart';

class SpotifyApi {
  SpotifyApi(this.auth);

  /// Id de la pseudo-playlist "Canciones que te gustan" (/me/tracks).
  static const likedId = 'liked';

  final SpotifyAuth auth;

  /// Lo que suena ahora en cualquier dispositivo de la cuenta, o null si nada.
  Future<Track?> nowPlaying() async {
    final r = await http.get(
      Uri.https('api.spotify.com', '/v1/me/player/currently-playing'),
      headers: await _headers,
    );
    if (r.statusCode == 204) return null;
    if (r.statusCode == 401) throw const SpotifyNotLoggedIn();
    if (r.statusCode != 200) throw StateError('Spotify ${r.statusCode}: ${r.body}');

    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final item = j['item'] as Map<String, dynamic>?;
    if (item == null || j['currently_playing_type'] != 'track') return null;
    return _track(item, isPlaying: j['is_playing'] as bool? ?? false);
  }

  /// Playlists del usuario, con "Canciones que te gustan" al inicio.
  Future<List<Playlist>> playlists() async {
    final j = await _get(Uri.https('api.spotify.com', '/v1/me/playlists', {'limit': '50'}));
    return [
      const Playlist(id: likedId, name: 'Canciones que te gustan', total: 0),
      for (final p in j['items'] as List)
        if (p != null)
          Playlist(
            id: p['id'] as String,
            name: p['name'] as String,
            total: (p['tracks']?['total'] as int?) ?? 0,
            imageUrl: _firstImage(p['images'] as List?),
            owner: p['owner']?['display_name'] as String?,
            ownerId: p['owner']?['id'] as String?,
          ),
    ];
  }

  /// Canciones de una playlist (hasta [max]), siguiendo la paginación de Spotify.
  /// Usa `/playlists/{id}/items`: el viejo `/tracks` ya responde 403 a las apps
  /// en modo desarrollo.
  Future<List<Track>> tracks(String playlistId, {int max = 300}) async {
    Uri? next = playlistId == likedId
        ? Uri.https('api.spotify.com', '/v1/me/tracks', {'limit': '50'})
        : Uri.https('api.spotify.com', '/v1/playlists/$playlistId/items', {'limit': '100'});
    final out = <Track>[];
    while (next != null && out.length < max) {
      final j = await _get(next);
      for (final item in j['items'] as List) {
        // /items trae la canción en "item"; /me/tracks la sigue trayendo en "track".
        final t = (item?['item'] ?? item?['track']) as Map<String, dynamic>?;
        if (t == null || t['is_local'] == true || t['type'] != 'track') continue;
        out.add(_track(t));
      }
      next = j['next'] == null ? null : Uri.parse(j['next'] as String);
    }
    return out;
  }

  Future<Map<String, String>> get _headers async => {'authorization': 'Bearer ${await auth.accessToken()}'};

  Future<Map<String, dynamic>> _get(Uri uri) async {
    final r = await http.get(uri, headers: await _headers);
    if (r.statusCode == 401) throw const SpotifyNotLoggedIn();
    if (r.statusCode == 403 || r.statusCode == 404) {
      throw StateError('Spotify no deja leer esta playlist desde la app (${r.statusCode}). '
          'Las playlists editoriales de Spotify están cerradas para apps en modo desarrollo.');
    }
    if (r.statusCode != 200) throw StateError('Spotify ${r.statusCode}: ${r.body}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  static Track _track(Map<String, dynamic> t, {bool isPlaying = true}) {
    final album = t['album'] as Map<String, dynamic>?;
    return Track(
      title: t['name'] as String,
      artists: [for (final a in t['artists'] as List) a['name'] as String],
      isPlaying: isPlaying,
      album: album?['name'] as String?,
      artUrl: _firstImage(album?['images'] as List?),
    );
  }

  static String? _firstImage(List? images) =>
      images == null || images.isEmpty ? null : images.last['url'] as String?;
}
