/// Modelos y el ranker que comparten la app del teléfono y la del proyector.
library;

export 'media.dart';
export 'pairing.dart';
export 'trading.dart';

/// Lo que está sonando en Spotify.
class Track {
  const Track({
    required this.title,
    required this.artists,
    this.isPlaying = true,
    this.album,
    this.artUrl,
  });

  final String title;
  final List<String> artists;
  final bool isPlaying;
  final String? album;
  final String? artUrl;

  String get artist => artists.join(', ');

  /// Lo que se busca en YouTube. Solo el primer artista: con varios la búsqueda empeora.
  String get searchQuery => '${artists.first} $title official video';

  @override
  String toString() => '$artist – $title';
}

/// Una playlist de Spotify. La app solo la lee: es el catálogo para elegir videos.
class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    required this.total,
    this.imageUrl,
    this.owner,
    this.ownerId,
  });

  final String id;
  final String name;
  final int total;
  final String? imageUrl;
  final String? owner;
  final String? ownerId;

  /// Las playlists editoriales de Spotify no se pueden leer desde una app en
  /// modo desarrollo (Spotify las cerró en noviembre de 2024).
  bool get isSpotifyOwned => ownerId == 'spotify';
}

/// Un resultado de búsqueda de YouTube.
class VideoCandidate {
  const VideoCandidate({
    required this.id,
    required this.title,
    required this.channel,
    this.thumbnailUrl,
  });

  final String id;
  final String title;
  final String channel;
  final String? thumbnailUrl;

  Uri get url => Uri.https('www.youtube.com', '/watch', {'v': id});
}

class RankedVideo {
  const RankedVideo(this.video, this.score);

  final VideoCandidate video;
  final int score;
}

const _accents = {
  'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u', 'ü': 'u', 'ñ': 'n',
  'à': 'a', 'è': 'e', 'ì': 'i', 'ò': 'o', 'ù': 'u', 'ç': 'c',
};

String normalize(String s) {
  final sb = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    sb.write(_accents[ch] ?? ch);
  }
  return sb.toString();
}

/// Título base de la canción: sin " - En Vivo", "(Live)", "- Remastered", etc.
String baseTitle(String title) => normalize(title).split(RegExp(r'\s+[-–]\s+|\s*[(\[]')).first.trim();

final _official = RegExp(r'official (music )?video|video oficial');
final _lyrics = RegExp(r'lyric|letra');
final _covers = RegExp(r'cover|karaoke|reaction|reacci');
final _live = RegExp(r'\blive\b|en vivo');
final _topic = RegExp(r' - topic$');

/// Prefiere el video oficial del artista; castiga lyrics, covers, lives y reacciones.
/// Este es el hueco donde después puede entrar un modelo de decisión.
int scoreVideo(VideoCandidate v, Track track) {
  final t = normalize(v.title);
  final c = normalize(v.channel);
  var s = 0;
  if (_official.hasMatch(t)) s += 3;
  if (c.contains('vevo') || track.artists.any((a) => c.contains(normalize(a)))) s += 2;
  s += t.contains(baseTitle(track.title)) ? 3 : -3;
  if (_lyrics.hasMatch(t)) s -= 3;
  if (_covers.hasMatch(t)) s -= 5;
  if (_live.hasMatch(t)) s -= 2;
  if (_topic.hasMatch(c)) s -= 1;
  return s;
}

/// Ordena de mejor a peor. Es estable: a igual puntaje gana el que YouTube puso primero.
List<RankedVideo> rankVideos(List<VideoCandidate> videos, Track track) {
  final ranked = [for (final v in videos) RankedVideo(v, scoreVideo(v, track))];
  ranked.sort((a, b) => b.score.compareTo(a.score));
  return ranked;
}
