import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'config.dart';
import 'projector.dart';
import 'screens.dart';
import 'spotify.dart';
import 'spotify_auth.dart';
import 'trading_store.dart';
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

  /// Cómo se presenta este teléfono ante las pantallas.
  String? phoneName;
  final _announced = <String>{};

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

  // Pestaña Buscar: para quien no tiene Spotify.
  List<VideoCandidate> searchResults = [];
  bool searching = false;

  // Trading: bitácora manual + precios de Yahoo mientras la página está abierta.
  final _tradeStore = TradeStore();
  final _yahoo = YahooFinance();
  List<Trade> trades = [];
  Map<String, Quote> quotes = {};
  DateTime? quotesAt;
  DateTime? nextQuotesAt;
  bool quotesLoading = false;
  bool tradingOnProjector = false;
  Timer? _quotesTimer;

  PortfolioStats get tradingStats => PortfolioStats.compute(trades, quotes);

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
    phoneName = await _store.loadPhoneName();
    pinned = await _store.loadPinned();
    trades = await _tradeStore.load();
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
      screenSpotifyLinked = projectorOnline && h!.spotifyLinked;
      screenFollowing = projectorOnline && h!.spotifyFollowing;
      volume = projectorOnline ? await ProjectorClient(s).volume() : null;
      if (projectorOnline) {
        // La pantalla es dueña de su nombre: si la renombró otro teléfono, nos enteramos aquí.
        if (h!.name != s.name) await _updateScreen(s.copyWith(name: h.name));
        if (!_announced.contains(s.id) && phoneName != null) {
          _announced.add(s.id);
          unawaited(_announce(s));
        }
      }
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
    // Si el proyector sigue a Spotify por su cuenta, el teléfono no manda nada
    // (si no, se abriría el video dos veces).
    if (screenSpotifyLinked || !autoFollow || t == null || !t.isPlaying) return;
    _followTimer = Timer(const Duration(seconds: 3), () {
      if (_lastTrackKey == key && !busy && projectorOnline) send();
    });
  }

  void setAutoFollow(bool value) {
    autoFollow = value;
    if (!value) _followTimer?.cancel();
    notifyListeners();
  }

  // --- Spotify del proyector ----------------------------------------------------

  bool screenSpotifyLinked = false;
  bool screenFollowing = false;

  /// Login de Spotify dedicado al proyector (su propia sesión) y se la manda.
  /// Desde ahí el proyector sigue la música aunque el teléfono esté guardado.
  Future<void> linkSpotifyToScreen() => _run(() async {
        final s = selectedScreen;
        if (s == null) throw StateError('No hay pantalla: escanea el QR del proyector');
        final token = await auth.authorize(scopes: const ['user-read-currently-playing', 'user-read-playback-state']);
        await ProjectorClient(s).spotify(link: {'clientId': Config.spotifyClientId, 'token': token});
        screenSpotifyLinked = true;
        screenFollowing = true;
        status = '${s.name} ya sigue a Spotify por su cuenta';
      });

  Future<void> setScreenFollowing(bool on) => _run(() async {
        final s = selectedScreen;
        if (s == null) return;
        await ProjectorClient(s).spotify(following: on);
        screenFollowing = on;
      });

  Future<void> unlinkSpotifyFromScreen() => _run(() async {
        final s = selectedScreen;
        if (s == null) return;
        await ProjectorClient(s).spotify(unlink: true);
        screenSpotifyLinked = false;
        screenFollowing = false;
        status = 'Spotify desvinculado de ${s.name}';
      });

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
    // Misma pantalla con código regenerado (id nuevo, misma dirección): reemplaza.
    var i = screens.indexWhere((s) => s.id == screen.id);
    if (i < 0) i = screens.indexWhere((s) => s.address == screen.address);
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
    _announced.add(screen.id);
    await _announce(screen);
    await _tick();
  }

  Future<void> setPhoneName(String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    phoneName = n.length > 40 ? n.substring(0, 40) : n;
    await _store.savePhoneName(phoneName!);
    _announced.clear(); // que las pantallas se enteren del nombre nuevo
    notifyListeners();
  }

  /// POST /pair: la pantalla muestra "Conectado: `nombre`". Si falla, no pasa nada.
  Future<void> _announce(Screen s) async {
    final name = phoneName;
    if (name == null) return;
    try {
      final r = await ProjectorClient(s).pair(name);
      if (r.name != s.name) await _updateScreen(s.copyWith(name: r.name));
    } catch (_) {
      // Receptor apagado o viejo: se reintenta en el siguiente arranque de la app.
    }
  }

  Future<void> _updateScreen(Screen updated) async {
    final i = screens.indexWhere((s) => s.id == updated.id);
    if (i < 0) return;
    screens[i] = updated;
    await _persistScreens();
    notifyListeners();
  }

  Future<void> selectScreen(String id) async {
    if (!screens.any((s) => s.id == id)) return;
    selectedScreenId = id;
    projectorOnline = false;
    await _store.saveSelectedId(id);
    notifyListeners();
    await _tick();
  }

  /// Renombra la pantalla en el receptor (si responde) y en la lista local.
  Future<void> renameScreen(String id, String name) async {
    final n = name.trim();
    final i = screens.indexWhere((s) => s.id == id);
    if (i < 0 || n.isEmpty) return;
    var finalName = n;
    if (id == selectedScreenId && projectorOnline) {
      try {
        final r = await ProjectorClient(screens[i]).pair(phoneName ?? 'Teléfono', screenName: n);
        finalName = r.name;
      } catch (e) {
        error = '$e';
      }
    }
    await _updateScreen(screens[i].copyWith(name: finalName));
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

  // Playlists fijadas arriba (se guardan en el teléfono).
  Set<String> pinned = {};

  bool isPinned(String id) => pinned.contains(id);

  Future<void> togglePin(String id) async {
    pinned = {...pinned};
    if (!pinned.remove(id)) pinned.add(id);
    await _store.savePinned(pinned);
    notifyListeners();
  }

  /// Arma una cola en el proyector (aleatoria o en orden desde `startAt`).
  Future<void> playQueue(List<Track> tracks, {String? name, bool shuffle = false, int startAt = 0}) =>
      _run(() async {
        final s = selectedScreen;
        if (s == null) throw StateError('No hay pantalla: escanea el QR del proyector');
        status = 'Armando la cola…';
        notifyListeners();
        final info = await ProjectorClient(s).queue(tracks: tracks, name: name, shuffle: shuffle, startAt: startAt);
        status = info == null ? 'No encontré videos para esta playlist' : 'Sonando en ${s.name}: $info';
      });

  // --- Buscar ------------------------------------------------------------------

  /// Búsqueda libre en YouTube (categoría Música), en el orden que da YouTube.
  Future<void> search(String query) async {
    final q = query.trim();
    if (q.isEmpty || searching) return;
    searching = true;
    error = null;
    notifyListeners();
    try {
      searchResults = await youtube.search(q);
    } catch (e) {
      error = '$e';
    } finally {
      searching = false;
      notifyListeners();
    }
  }

  // --- Trading -----------------------------------------------------------------

  Future<void> addTrade(Trade t) async {
    trades = [...trades, t];
    await _saveTrades();
  }

  Future<void> closeTrade(String id, {required double exitPrice, DateTime? at}) async {
    trades = [for (final t in trades) t.id == id ? t.close(exitPrice: exitPrice, at: at) : t];
    await _saveTrades();
  }

  Future<void> deleteTrade(String id) async {
    trades = [for (final t in trades) if (t.id != id) t];
    await _saveTrades();
  }

  Future<void> _saveTrades() async {
    await _tradeStore.save(trades);
    notifyListeners();
    unawaited(refreshQuotes());
    unawaited(_pushTrading());
  }

  /// Precios de las posiciones abiertas mientras la página está abierta: cada
  /// minuto con el mercado abierto; con el mercado cerrado, hasta la apertura.
  Future<void> refreshQuotes() async {
    final symbols = trades.where((t) => t.isOpen).map((t) => t.symbol).toSet();
    if (symbols.isEmpty || quotesLoading) return;
    quotesLoading = true;
    notifyListeners();
    Map<String, Quote> q = {};
    try {
      q = await _yahoo.quotes(symbols);
      if (q.isNotEmpty) {
        quotes = q;
        quotesAt = DateTime.now();
      }
    } finally {
      quotesLoading = false;
      if (_polling) {
        nextQuotesAt = UsMarketHours.nextRefresh(
          DateTime.now(),
          lastMarketState: q.isEmpty ? null : q.values.first.marketState,
        );
        _quotesTimer?.cancel();
        _quotesTimer = Timer(nextQuotesAt!.difference(DateTime.now()), refreshQuotes);
      }
      notifyListeners();
    }
  }

  bool _polling = false;

  void startQuotePolling() {
    _polling = true;
    _quotesTimer?.cancel();
    // Si ya hay precios y el siguiente refresh es en el futuro (mercado
    // cerrado), no se vuelve a pedir: solo se reagenda.
    final next = nextQuotesAt;
    if (quotesAt != null && next != null && next.isAfter(DateTime.now())) {
      _quotesTimer = Timer(next.difference(DateTime.now()), refreshQuotes);
      notifyListeners();
    } else {
      unawaited(refreshQuotes());
    }
  }

  void stopQuotePolling() {
    _polling = false;
    _quotesTimer?.cancel();
    _quotesTimer = null;
  }

  /// Manda la bitácora al proyector y lo pone en modo Trading (o lo quita).
  Future<void> showTradingOnProjector(bool show) => _run(() async {
        final s = selectedScreen;
        if (s == null) throw StateError('No hay pantalla: escanea el QR del proyector');
        final mode = await ProjectorClient(s).trading(show: show, trades: trades);
        tradingOverlay = mode == 'overlay';
        tradingOnProjector = show;
        status = tradingOverlay
            ? 'Tus acciones flotan encima del video (se quitan solas en 45 s)'
            : 'Estadísticas en el inicio de ${s.name}';
      });

  /// La tarjeta de trading flotando encima del video en el proyector.
  bool tradingOverlay = false;

  Future<void> hideTradingOverlay() => _run(() async {
        final s = selectedScreen;
        if (s == null) return;
        await ProjectorClient(s).trading(overlay: false);
        tradingOverlay = false;
        status = 'Video en grande otra vez';
      });

  // --- Volumen del proyector -------------------------------------------------------

  ({int level, int max, bool muted})? volume;

  Future<void> changeVolume({int? level, int? delta, bool? mute}) async {
    final s = selectedScreen;
    if (s == null) return;
    final v = await ProjectorClient(s).volume(level: level, delta: delta, mute: mute);
    if (v != null) {
      volume = v;
      notifyListeners();
    }
  }

  /// Si el tablero está en el proyector, cada cambio se refleja allá.
  Future<void> _pushTrading() async {
    final s = selectedScreen;
    if (s == null || !projectorOnline) return;
    try {
      await ProjectorClient(s).trading(trades: trades);
    } catch (_) {
      // El proyector no está: se manda completo la próxima vez que se muestre.
    }
  }

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
    _quotesTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
