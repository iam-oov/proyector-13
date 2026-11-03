import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

void main() {
  final relay = Uri.parse('https://www.valdoh.com/proyector/api/search');
  const track = Track(title: 'Hasta Que Me Olvides', artists: ['Luis Miguel']);

  String relayAnswer(List<String> ids) => jsonEncode({
        'ok': true,
        'results': [
          for (final id in ids) {'id': id, 'title': 'Luis Miguel - $id', 'channel': 'LuisMiguelVEVO', 'thumb': null, 'duration': '4:27'},
        ],
      });

  test('a song is looked up through the relay when it answers', () async {
    final asked = <Uri>[];
    final client = MockClient((r) async {
      asked.add(r.url);
      return http.Response(relayAnswer(['a1', 'b2']), 200);
    });
    final videos = await searchTrackVideos(track, client: client, relaySearch: relay);
    expect(videos.map((v) => v.id), ['a1', 'b2']);
    expect(videos.first.channel, 'LuisMiguelVEVO');
    expect(asked.single.host, 'www.valdoh.com');
    expect(asked.single.queryParameters['q'], 'Luis Miguel Hasta Que Me Olvides official video');
  });

  test('if the relay fails it goes straight to YouTube', () async {
    final hosts = <String>[];
    final client = MockClient((r) async {
      hosts.add(r.url.host);
      if (r.url.host == 'www.valdoh.com') return http.Response('{"ok": false}', 503);
      return http.Response(jsonEncode({'contents': {}}), 200);
    });
    final videos = await searchTrackVideos(track, client: client, relaySearch: relay);
    expect(videos, isEmpty);
    // Both queries (official video, then plain) tried the relay first.
    expect(hosts, ['www.valdoh.com', 'www.youtube.com', 'www.valdoh.com', 'www.youtube.com']);
  });

  test('an empty answer retries with only artist and title', () async {
    final queries = <String>[];
    final client = MockClient((r) async {
      final q = r.url.queryParameters['q']!;
      queries.add(q);
      return http.Response(relayAnswer(q.endsWith('official video') ? [] : ['c3']), 200);
    });
    final videos = await searchTrackVideos(track, client: client, relaySearch: relay);
    expect(videos.map((v) => v.id), ['c3']);
    expect(queries, ['Luis Miguel Hasta Que Me Olvides official video', 'Luis Miguel Hasta Que Me Olvides']);
  });
}
