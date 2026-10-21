import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared/shared.dart';

import 'identity.dart';
import 'player.dart';
import 'state.dart';

/// El proyector sigue a Spotify por su cuenta: con su propia sesión (la vincula
/// el teléfono una vez) consulta qué suena cada 5 s y, cuando cambia la
/// canción, abre el video oficial en YouTube. No depende del teléfono.
class SpotifyFollower {
  SpotifyFollower(this.state, this._file);

  final ReceiverState state;
  final File? _file;
  Map<String, dynamic>? _token;
  String? _clientId;
  Timer? _poll;
  Timer? _debounce;
  String? _lastKey;
  bool _primed = false;
  final _cache = <String, VideoCandidate>{};

  static Future<SpotifyFollower> open(ReceiverState state) async {
    final dir = await appFilesDir();
    final f = SpotifyFollower(state, dir == null ? null : File('$dir/spotify.json'));
    await f._restore();
    return f;
  }

  bool get linked => _token != null;

  /// El teléfono manda una sesión nueva (login PKCE hecho para el proyector).
  Future<void> link({required String clientId, required Map<String, dynamic> token, bool follow = true}) async {
    _clientId = clientId;
    _token = token;
    state.setSpotify(linked: true, following: follow);
    await _save();
    _restart();
  }

  Future<void> unlink() async {
    _token = null;
    _clientId = null;
    _poll?.cancel();
    _debounce?.cancel();
    state.setSpotify(linked: false, following: false, nowPlaying: null);
    final f = _file;
    if (f != null && await f.exists()) await f.delete();
  }

  Future<void> setFollowing(bool on) async {
    state.setSpotify(following: on);
    await _save();
    if (!on) _debounce?.cancel();
  }

  void _restart() {
    _poll?.cancel();
    _primed = false;
    _lastKey = null;
    if (!linked) return;
    unawaited(_tick());
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _tick());
  }

  Future<void> _tick() async {
    final access = await _accessToken();
    if (access == null) return;
    Track? t;
    try {
      t = await spotifyNowPlaying(access);
    } on SpotifyUnauthorized {
      _token?['expires_at'] = 0; // fuerza el refresh en el siguiente tick
      return;
    } catch (_) {
      return; // sin red / Spotify caído: se reintenta en 5 s
    }
    state.setSpotify(nowPlaying: t, clearNowPlaying: t == null);
    _followIfChanged(t);
  }

  /// Igual que en el teléfono: espera 3 s por si se van saltando canciones y
  /// la primera lectura tras arrancar no manda nada.
  void _followIfChanged(Track? t) {
    final key = t == null ? null : '${t.artist}|${t.title}';
    if (key == _lastKey) return;
    _lastKey = key;
    _debounce?.cancel();
    if (!_primed) {
      _primed = true;
      return;
    }
    if (!state.spotifyFollowing || t == null || !t.isPlaying) return;
    _debounce = Timer(const Duration(seconds: 3), () {
      if (_lastKey == key) unawaited(_play(t));
    });
  }

  Future<void> _play(Track t) async {
    final key = '${t.artist}|${t.title}'.toLowerCase();
    try {
      var video = _cache[key];
      if (video == null) {
        final ranked = rankVideos(await searchYouTubeWeb(t.searchQuery), t);
        if (ranked.isEmpty) return;
        video = ranked.first.video;
        _cache[key] = video;
      }
      await openVideo(video.url);
      state.add('♪  ${video.title}');
    } catch (e) {
      state.add('✕  Spotify → YouTube: $e', error: true);
    }
  }

  /// Token vigente; refresca (y guarda el refresh_token rotado) si está por vencer.
  Future<String?> _accessToken() async {
    final t = _token;
    final clientId = _clientId;
    if (t == null || clientId == null) return null;
    final expiresAt = (t['expires_at'] as num?)?.toInt() ?? 0;
    if (DateTime.now().millisecondsSinceEpoch < expiresAt - 60000) return t['access_token'] as String?;
    try {
      final fresh = await spotifyRefresh(clientId, t['refresh_token'] as String);
      _token = {...t, ...fresh};
      await _save();
      return _token!['access_token'] as String?;
    } catch (e) {
      state.add('✕  Spotify: no pude renovar la sesión ($e)', error: true);
      return null;
    }
  }

  Future<void> _restore() async {
    final f = _file;
    if (f == null || !await f.exists()) return;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      _clientId = j['clientId'] as String?;
      _token = (j['token'] as Map?)?.cast<String, dynamic>();
      if (_token == null || _clientId == null) return;
      state.setSpotify(linked: true, following: j['following'] != false);
      _restart();
    } catch (_) {
      // Archivo corrupto: hay que volver a vincular.
    }
  }

  Future<void> _save() async {
    final f = _file;
    if (f == null || _token == null) return;
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({'clientId': _clientId, 'token': _token, 'following': state.spotifyFollowing}),
      flush: true,
    );
    await tmp.rename(f.path);
  }
}
