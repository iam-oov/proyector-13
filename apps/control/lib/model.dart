import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'projector.dart';
import 'screens.dart';
import 'spotify.dart';
import 'spotify_auth.dart';
import 'youtube.dart';

/// Estado de la app: pantallas vinculadas, sesión, qué suena, playlists y el último envío.
class ControlModel extends ChangeNotifier with WidgetsBindingObserver {
  final auth = SpotifyAuth();
  late final spotify = SpotifyApi(auth);
  final youtube = YouTubeApi();
  final _store = ScreenStore();

  // Pantallas (proyectores/TVs con el receptor), vinculadas por QR.
  List<Screen> screens = [];
  String? selectedScreenId;
  bool projectorOnline = false;

  /// La IP responde, pero con otro id: el receptor se reinstaló o la IP cambió de dueño.
  bool screenIdMismatch = false;

  bool loggedIn = false;
  bool busy = false;
  Track? track;
  List<RankedVideo> candidates = [];
  String? status;
  String? error;
  Timer? _poll;

  /// Cuando cambia la canción en Spotify, manda el video solo.
  bool autoFollow = true;
  String? _lastTrackKey;
  bool _primed = false;
  Timer? _followTimer;

  List<Playlist> playlists = [];
  bool playlistsLoading = false;
  final _tracks = <String, List<Track>>{};

  Screen? get selectedScreen {
    for (final s in screens) {
      if (s.id == selectedScreenId) return s;
    }
    return null;
  }

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    screens = await _store.loadScreens();
    selectedScreenId = await _store.loadSelectedId();
    if (selectedScreen == null && screens.isNotEmpty) selectedScreenId = screens.first.id;
    loggedIn = await auth.isLoggedIn;
    if (loggedIn && !await auth.hasAllScopes) {
      await auth.logout();
      loggedIn = false;
      status = 'Spotify pide un permiso nuevo (playlists): vuelve a conectar';
    }
    notifyListeners();
    _startPolling();
  }

  void _startPolling() {
    _poll?.cancel();
    _tick();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
  }

  Future<void> _tick() async {
    final s = selectedScreen;
    if (s == null) {
      projectorOnline = false;
      screenIdMismatch = false;
    } else {
      final h = await ProjectorClient(s).health();
      screenIdMismatch = h != null && h.id != s.id;
      projectorOnline = h != null && h.id == s.id;
    }
    if (loggedIn) {
      try {
        track = await spotify.nowPlaying();
        error = null;
        _followIfChanged();
      } on SpotifyNotLoggedIn {
        await _dropSession();
      } catch (e) {
        error = '$e';
      }
    }
    notifyListeners();
  }

  /// Detecta el cambio de canción. Espera 3 s por si el usuario va saltando
  /// canciones, y la primera lectura al abrir la app no manda nada.
  void _followIfChanged() {
    final t = track;
    final key = t == null ? null : '${t.artist}|${t.title}';
    if (key == _lastTrackKey) return;
    _lastTrackKey = key;
    _followTimer?.cancel();
    if (!_primed) {
      _primed = true;
      return;
    }
    if (!autoFollow || t == null || !t.isPlaying) return;
    _followTimer = Timer(const Duration(seconds: 3), () {
      if (_lastTrackKey == key && !busy && projectorOnline) send();
    });
  }

  void setAutoFollow(bool value) {
    autoFollow = value;
    if (!value) _followTimer?.cancel();
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPolling();
    } else if (state == AppLifecycleState.paused) {
      _poll?.cancel();
    }
  }

  // --- Pantallas ---------------------------------------------------------------

  /// Guarda la pantalla del QR (o actualiza la que ya estaba con ese id) y la activa.
  Future<void> addScreen(PairingPayload payload) async {
    final screen = Screen.fromPayload(payload);
    final i = screens.indexWhere((s) => s.id == screen.id);
    if (i >= 0) {
      screens[i] = screen;
    } else {
      screens.add(screen);
    }
    selectedScreenId = screen.id;
    await _persistScreens();
    status = 'Pantalla "${screen.name}" guardada';
    error = null;
    notifyListeners();
    await _tick();
  }

  Future<void> selectScreen(String id) async {
    if (!screens.any((s) => s.id == id)) return;
    selectedScreenId = id;
    projectorOnline = false;
    await _store.saveSelectedId(id);
    notifyListeners();
    await _tick();
  }

  Future<void> renameScreen(String id, String name) async {
    final n = name.trim();
    final i = screens.indexWhere((s) => s.id == id);
    if (i < 0 || n.isEmpty) return;
    screens[i] = screens[i].copyWith(name: n);
    await _persistScreens();
    notifyListeners();
  }

  Future<void> removeScreen(String id) async {
    screens.removeWhere((s) => s.id == id);
    if (selectedScreenId == id) {
      selectedScreenId = screens.isEmpty ? null : screens.first.id;
      projectorOnline = false;
    }
    await _persistScreens();
    notifyListeners();
    await _tick();
  }

  Future<void> _persistScreens() async {
    await _store.saveScreens(screens);
    await _store.saveSelectedId(selectedScreenId);
  }

  // --- Spotify -----------------------------------------------------------------

  Future<void> login() => _run(() async {
        await auth.login();
        loggedIn = true;
        status = 'Spotify conectado';
      });

  Future<void> logout() => _run(_dropSession);

  Future<void> _dropSession() async {
    await auth.logout();
    loggedIn = false;
    track = null;
    playlists = [];
    _tracks.clear();
  }

  Future<void> loadPlaylists({bool force = false}) async {
    if (playlistsLoading || (playlists.isNotEmpty && !force)) return;
    playlistsLoading = true;
    notifyListeners();
    try {
      playlists = await spotify.playlists();
      error = null;
    } on SpotifyNotLoggedIn {
      await _dropSession();
    } catch (e) {
      error = '$e';
    } finally {
      playlistsLoading = false;
      notifyListeners();
    }
  }

  Future<List<Track>> tracksOf(String playlistId) async =>
      _tracks[playlistId] ??= await spotify.tracks(playlistId);

  // --- Enviar ------------------------------------------------------------------

  /// Manda a la pantalla activa el video de lo que suena en Spotify.
  Future<void> send() => _run(() async {
        final t = track;
        if (t == null) throw StateError('No hay nada sonando en Spotify');
        await _sendTrack(t);
      });

  /// Manda el video de una canción elegida de una playlist.
  Future<void> sendTrack(Track t) => _run(() => _sendTrack(t));

  Future<void> sendVideo(VideoCandidate video) => _run(() => _play(video));

  Future<void> _sendTrack(Track t) async {
    status = 'Buscando el video de "$t"…';
    notifyListeners();
    candidates = rankVideos(await youtube.search(t.searchQuery), t);
    if (candidates.isEmpty) throw StateError('YouTube no encontró nada para "$t"');
    await _play(candidates.first.video);
  }

  Future<void> _play(VideoCandidate video) async {
    final s = selectedScreen;
    if (s == null) throw StateError('No hay pantalla: escanea el QR del proyector');
    status = 'Enviando a ${s.name}…';
    notifyListeners();
    await ProjectorClient(s).play(video);
    status = 'En ${s.name}: ${video.title}';
  }

  Future<void> _run(Future<void> Function() action) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _followTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
