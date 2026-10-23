import 'dart:convert';

import 'package:http/http.dart' as http;

/// Un título (serie o película) y dónde se ve en México, con el id que cada
/// servicio usa en su enlace directo.
class CatalogTitle {
  const CatalogTitle({required this.title, required this.year, required this.isShow, required this.offers});

  final String title;
  final int? year;
  final bool isShow;

  /// provider → contentId para la Roku: netflix → "80057281",
  /// disneyplus → el uuid sin "entity-" (con el prefijo dice "no disponible"),
  /// prime → "amzn1.dv.gti.…", hbomax → uuid.
  final Map<String, String> offers;

  String get mediaType => isShow ? 'series' : 'movie';

  @override
  String toString() => '$title${year == null ? '' : ' ($year)'} · ${offers.keys.join(', ')}';
}

/// Catálogo de JustWatch (sin key): "stranger things" → Netflix 80057281. La
/// búsqueda propia de la Roku no da resultados en México, así que el id lo
/// pone la app.
class Catalog {
  static const _query = r'''
query S($f: TitleFilter!, $c: Country!, $l: Language!, $n: Int!) {
  popularTitles(country: $c, filter: $f, first: $n) { edges { node { ... on MovieOrShow {
    objectType content(country: $c, language: $l) { title originalReleaseYear }
    offers(country: $c, platform: WEB) { standardWebURL package { technicalName } } } } } } }''';

  /// JustWatch nombra cada paquete a su manera; aquí el nombre que usa la app.
  static const _providers = {
    'netflix': 'netflix',
    'netflixbasicwithads': 'netflix',
    'disneyplus': 'disneyplus',
    'amazonprimevideo': 'prime',
    'amazonprimevideowithads': 'prime',
    'amazon': 'prime',
    'max': 'hbomax',
    'hbomax': 'hbomax',
    'itunes': 'appletv',
    'appletvplus': 'appletv',
    'crunchyroll': 'crunchyroll',
    'vix': 'vix',
    'vixplus': 'vix',
  };

  Future<List<CatalogTitle>> search(String title, {int max = 5}) async {
    final r = await http
        .post(
          Uri.https('apis.justwatch.com', '/graphql'),
          headers: {'content-type': 'application/json', 'user-agent': 'Mozilla/5.0 (Proyector)'},
          body: jsonEncode({
            'query': _query,
            'variables': {'f': {'searchQuery': title}, 'c': 'MX', 'l': 'es', 'n': max},
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (r.statusCode != 200) throw StateError('El catálogo no respondió (${r.statusCode})');
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final edges = ((j['data'] as Map?)?['popularTitles'] as Map?)?['edges'] as List? ?? [];
    final out = <CatalogTitle>[];
    for (final e in edges) {
      final n = (e as Map)['node'] as Map;
      final c = n['content'] as Map? ?? {};
      final offers = <String, String>{};
      for (final o in (n['offers'] as List? ?? [])) {
        final p = _providers[((o as Map)['package'] as Map)['technicalName'] as String? ?? ''];
        if (p == null) continue;
        final id = _contentId(p, o['standardWebURL'] as String? ?? '');
        if (id != null) offers.putIfAbsent(p, () => id);
      }
      out.add(CatalogTitle(
        title: c['title'] as String? ?? title,
        year: c['originalReleaseYear'] as int?,
        isShow: n['objectType'] == 'SHOW',
        offers: offers,
      ));
    }
    return out;
  }

  /// El contentId que la app de la Roku entiende, sacado del enlace web.
  static String? _contentId(String provider, String url) {
    final u = Uri.tryParse(url);
    if (u == null) return null;
    switch (provider) {
      case 'netflix':
        return RegExp(r'/title/(\d+)').firstMatch(u.path)?.group(1);
      case 'disneyplus':
        return RegExp(r'/entity-([0-9a-f-]+)').firstMatch(u.path)?.group(1);
      case 'prime':
        return u.queryParameters['gti'];
      case 'hbomax':
        return RegExp(r'/(?:show|video/watch|movie)/([0-9a-f-]{36})').firstMatch(u.path)?.group(1);
      case 'appletv':
        return RegExp(r'/(umc\.cmc\.[a-z0-9]+)').firstMatch(u.path)?.group(1);
      default:
        return u.pathSegments.isEmpty ? null : u.pathSegments.last;
    }
  }
}
