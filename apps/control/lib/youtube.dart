import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared/shared.dart';

import 'config.dart';

/// Búsqueda de videos en tres capas, para no depender de la cuota de la API
/// oficial (solo 100 búsquedas al día):
/// 1. caché local (la misma búsqueda no se repite);
/// 2. la búsqueda web de YouTube (la que usa youtube.com; sin cuota);
/// 3. YouTube Data API v3 como respaldo si la web falla.
class YouTubeApi {
  YouTubeApi({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  static const _kCache = 'video_cache';
  static const _maxCached = 300;

  final FlutterSecureStorage _storage;
  Map<String, List<VideoCandidate>>? _cache;

  Future<List<VideoCandidate>> search(String query) async {
    final key = query.trim().toLowerCase();
    final cache = await _loadCache();
    final hit = cache[key];
    if (hit != null && hit.isNotEmpty) return hit;

    List<VideoCandidate> results;
    try {
      results = await _searchWeb(query);
      if (results.isEmpty) results = await _searchApi(query);
    } catch (_) {
      results = await _searchApi(query);
    }
    if (results.isNotEmpty) await _remember(key, results);
    return results;
  }

  /// youtube.com/youtubei/v1/search con el filtro "solo videos".
  Future<List<VideoCandidate>> _searchWeb(String query) async {
    final r = await http
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
        if (out.length >= 5) return out;
      }
    }
    return out;
  }

  static String _runs(Object? o) {
    final runs = (o as Map?)?['runs'] as List?;
    return runs == null ? '' : runs.map((r) => r['text'] ?? '').join();
  }

  /// Respaldo: API oficial (100 búsquedas al día con la key gratuita).
  Future<List<VideoCandidate>> _searchApi(String query) async {
    if (!Config.hasYouTube) throw StateError('No pude buscar en YouTube');
    final r = await http.get(Uri.https('www.googleapis.com', '/youtube/v3/search', {
      'part': 'snippet',
      'type': 'video',
      'videoCategoryId': '10',
      'maxResults': '5',
      'q': query,
      'key': Config.youtubeApiKey,
    }));
    if (r.statusCode == 429 || r.statusCode == 403) {
      throw StateError('YouTube no responde y se acabó la cuota diaria de búsquedas. Intenta más tarde.');
    }
    if (r.statusCode != 200) throw StateError('YouTube respondió ${r.statusCode}');

    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return [
      for (final item in j['items'] as List)
        VideoCandidate(
          id: item['id']['videoId'] as String,
          title: _unescape(item['snippet']['title'] as String),
          channel: _unescape(item['snippet']['channelTitle'] as String),
          thumbnailUrl: item['snippet']['thumbnails']?['default']?['url'] as String?,
        ),
    ];
  }

  // search.list manda los títulos con entidades HTML.
  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&#39;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  Future<Map<String, List<VideoCandidate>>> _loadCache() async {
    if (_cache != null) return _cache!;
    final cache = <String, List<VideoCandidate>>{};
    try {
      final raw = await _storage.read(key: _kCache);
      if (raw != null) {
        (jsonDecode(raw) as Map<String, dynamic>).forEach((k, v) {
          cache[k] = [
            for (final m in v as List)
              VideoCandidate(
                id: m['id'] as String,
                title: m['title'] as String,
                channel: m['channel'] as String,
                thumbnailUrl: m['thumb'] as String?,
              ),
          ];
        });
      }
    } catch (_) {
      // Caché corrupta: se empieza de cero.
    }
    return _cache = cache;
  }

  Future<void> _remember(String key, List<VideoCandidate> results) async {
    final cache = await _loadCache();
    cache.remove(key);
    cache[key] = results;
    while (cache.length > _maxCached) {
      cache.remove(cache.keys.first);
    }
    await _storage.write(
      key: _kCache,
      value: jsonEncode({
        for (final e in cache.entries)
          e.key: [
            for (final v in e.value) {'id': v.id, 'title': v.title, 'channel': v.channel, 'thumb': v.thumbnailUrl},
          ],
      }),
    );
  }
}
