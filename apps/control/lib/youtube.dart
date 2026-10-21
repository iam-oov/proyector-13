import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared/shared.dart';

import 'config.dart';

class YouTubeApi {
  /// Hasta 5 videos de la categoría Música. Cada búsqueda cuesta 100 de las
  /// 10,000 unidades diarias de la key gratuita.
  Future<List<VideoCandidate>> search(String query) async {
    final r = await http.get(Uri.https('www.googleapis.com', '/youtube/v3/search', {
      'part': 'snippet',
      'type': 'video',
      'videoCategoryId': '10',
      'maxResults': '5',
      'q': query,
      'key': Config.youtubeApiKey,
    }));
    if (r.statusCode != 200) throw StateError('YouTube ${r.statusCode}: ${r.body}');

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
}
