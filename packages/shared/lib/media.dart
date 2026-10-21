import 'dart:convert';

import 'package:http/http.dart' as http;

import 'shared.dart';

/// Búsqueda web de YouTube (la misma que usa youtube.com): sin cuota diaria.
/// Filtro "solo videos". Devuelve hasta [max] resultados.
Future<List<VideoCandidate>> searchYouTubeWeb(String query, {int max = 5, http.Client? client}) async {
  final c = client ?? http.Client();
  final r = await c
      .post(
        Uri.https('www.youtube.com', '/youtubei/v1/search', {'prettyPrint': 'false'}),
        headers: {'content-type': 'application/json', 'user-agent': 'Mozilla/5.0'},
        body: jsonEncode({
          'context': {
            'client': {'clientName': 'WEB', 'clientVersion': '2.20251001.00.00', 'hl': 'es', 'gl': 'MX'},
          },
          'query': query,
          'params': 'EgIQAQ%3D%3D',
        }),
      )
      .timeout(const Duration(seconds: 8));
  if (r.statusCode != 200) throw StateError('YouTube web ${r.statusCode}');
  final j = jsonDecode(r.body) as Map<String, dynamic>;
  final sections = j['contents']?['twoColumnSearchResultsRenderer']?['primaryContents']?['sectionListRenderer']
      ?['contents'] as List?;
  final out = <VideoCandidate>[];
  for (final s in sections ?? const []) {
    for (final item in (s['itemSectionRenderer']?['contents'] as List?) ?? const []) {
      final v = item['videoRenderer'];
      if (v == null || v['videoId'] == null) continue;
      out.add(VideoCandidate(
        id: v['videoId'] as String,
        title: _runs(v['title']),
        channel: _runs(v['ownerText']),
        thumbnailUrl: (v['thumbnail']?['thumbnails'] as List?)?.firstOrNull?['url'] as String?,
      ));
      if (out.length >= max) return out;
    }
  }
  return out;
}

/// Videos para una canción. Primero "artista título official video"; si YouTube
/// no da resultados (p. ej. pide "Confirma tu edad" por una palabra sensible),
/// reintenta solo con "artista título".
Future<List<VideoCandidate>> searchTrackVideos(Track t, {http.Client? client}) async {
  final first = await searchYouTubeWeb(t.searchQuery, client: client);
  if (first.isNotEmpty) return first;
  return searchYouTubeWeb(t.plainQuery, client: client);
}

String _runs(Object? o) {
  final runs = (o as Map?)?['runs'] as List?;
  return runs == null ? '' : runs.map((r) => r['text'] ?? '').join();
}

/// El access token ya no sirve (401): hay que refrescar o volver a vincular.
class SpotifyUnauthorized implements Exception {
  const SpotifyUnauthorized();

  @override
  String toString() => 'Sesión de Spotify vencida';
}

/// Lo que suena en la cuenta (cualquier dispositivo), o null si nada.
Future<Track?> spotifyNowPlaying(String accessToken, {http.Client? client}) async {
  final c = client ?? http.Client();
  final r = await c
      .get(
        Uri.https('api.spotify.com', '/v1/me/player/currently-playing'),
        headers: {'authorization': 'Bearer $accessToken'},
      )
      .timeout(const Duration(seconds: 8));
  if (r.statusCode == 204) return null;
  if (r.statusCode == 401) throw const SpotifyUnauthorized();
  if (r.statusCode != 200) throw StateError('Spotify ${r.statusCode}');
  final j = jsonDecode(r.body) as Map<String, dynamic>;
  final item = j['item'] as Map<String, dynamic>?;
  if (item == null || j['currently_playing_type'] != 'track') return null;
  final album = item['album'] as Map<String, dynamic>?;
  final images = (album?['images'] as List?) ?? const [];
  return Track(
    title: item['name'] as String,
    artists: [for (final a in item['artists'] as List) a['name'] as String],
    isPlaying: j['is_playing'] as bool? ?? false,
    album: album?['name'] as String?,
    artUrl: images.isEmpty ? null : images.last['url'] as String?,
  );
}

/// Refresh de un token PKCE. Spotify rota el refresh_token: hay que guardar el nuevo.
Future<Map<String, dynamic>> spotifyRefresh(String clientId, String refreshToken, {http.Client? client}) async {
  final c = client ?? http.Client();
  final r = await c.post(
    Uri.https('accounts.spotify.com', '/api/token'),
    headers: {'content-type': 'application/x-www-form-urlencoded'},
    body: {'grant_type': 'refresh_token', 'refresh_token': refreshToken, 'client_id': clientId},
  ).timeout(const Duration(seconds: 10));
  if (r.statusCode != 200) throw StateError('Spotify token ${r.statusCode}');
  final t = jsonDecode(r.body) as Map<String, dynamic>;
  t['expires_at'] = DateTime.now().millisecondsSinceEpoch + (t['expires_in'] as int) * 1000;
  return t;
}
