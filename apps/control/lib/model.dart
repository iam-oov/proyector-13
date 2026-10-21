import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'config.dart';
import 'projector.dart';
import 'screens.dart';
import 'spotify.dart';
import 'spotify_auth.dart';
import 'trading_store.dart';
import 'tv.dart';
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
    autoFollow = await _store.loadAutoFollow();
    trades = await _tradeStore.load();
    if (selectedScreen == null && screens.isNotEmpty) selectedScreenId = screens.first.id;
    loggedIn = await auth.isLoggedIn;
    if (loggedIn && !await auth.hasAllScopes) {
      await auth.logout();
      loggedIn = false;
      status = 'Spotify pide un permiso nuevo (saltar y pausar): vuelve a conectar';
    }
    notifyListeners();
    _startPolling();
  }

  void _startPolling() {
    _poll?.cancel();
    _tick();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
  }

  /// En línea o no, por pantalla (los puntos de la fila de equipos). La elegida se
  /// revisa en cada vuelta; las demás, cada cuatro (unos 12 s).
  final _online = <String, bool>{};
  int _ticks = 0;

  bool? isScreenOnline(String id) => id == selectedScreenId && screenChecked ? projectorOnline : _online[id];

  Future<void> _checkOthers() async {
    await Future.wait([
      for (final s in screens.where((s) => s.id != selectedScreenId))
        (s.isTv ? TvClient(s).status().then((st) => st != null) : ProjectorClient(s).health().then((h) => h?.id == s.id))
            .then((on) => _online[s.id] = on),
    ]);
  }

  Future<void> _tick() async {
    if (_ticks++ % 4 == 0) unawaited(_checkOthers().then((_) => notifyListeners()));
    final s = selectedScreen;
    if (s == null) {
      projectorOnline = false;
      screenIdMismatch = false;
      screenChecked = false;
    } else if (s.isTv) {
      // TV sin receptor: solo se sabe si YouTube está abierto.
      final st = await TvClient(s).status();
      screenIdMismatch = false;
      projectorOnline = st != null;
      screenSpotifyLinked = false;
      screenFollowing = false;
      screenQueueInfo = null;
      screenMediaTitle = st != null && st.running ? 'YouTube' : null;
      screenMediaPlaying = st != null && st.running;
      screenChecked = true;
      // Volumen de YouTube: se lee una vez al conectarse; después lo lleva la app.
      if (st == null || !st.running) {
        volume = null;
      } else if (volume == null || volume!.max != 100) {
        final v = await TvClient(s).volume();
        volume = v == null ? null : (level: v.level, max: 100, muted: v.muted);
      }
    } else {
      final h = await ProjectorClient(s).health();
      screenIdMismatch = h != null && h.id != s.id;
      projectorOnline = h != null && h.id == s.id;
      screenSpotifyLinked = projectorOnline && h!.spotifyLinked;
      screenFollowing = projectorOnline && h!.spotifyFollowing;
      screenQueueInfo = projectorOnline ? h!.queueInfo : null;
      screenMediaTitle = projectorOnline ? h!.mediaTitle : null;
      screenMediaPlaying = projectorOnline && h!.mediaPlaying;
      screenChecked = true;
      volume = projectorOnline ? await ProjectorClient(s).volume() : null;
      // El proyector se cambió de red o de IP: buscarlo solo (una vez cada 2 min).
      if (!projectorOnline && !rediscovering) {
        final last = _lastRediscover[s.id];
        if (last == null || DateTime.now().difference(last) > const Duration(minutes: 2)) {
          unawaited(rediscover(s.id));
        }
      }
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
        error = _msg(e);
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
    unawaited(_store.saveAutoFollow(value));
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

  /// Agrega una TV sin receptor por su IP, si responde a DIAL con YouTube.
  Future<void> addTv(String host, {String? name}) => _run(() async {
        final h = host.trim();
        final screen = Screen.tv(h, name: name?.trim().isEmpty ?? true ? 'TV' : name!.trim());
        if (await TvClient(screen).status() == null) {
          throw StateError('$h no responde como TV con YouTube: revisa la IP y que el teléfono esté en su Wi-Fi');
        }
        final i = screens.indexWhere((s) => s.id == screen.id);
        if (i >= 0) {
          screens[i] = screen;
        } else {
          screens.add(screen);
        }
        selectedScreenId = screen.id;
        await _persistScreens();
        status = 'TV "${screen.name}" guardada';
        await _tick();
      });

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
    if (name == null || s.isTv) return;
    try {
      final r = await ProjectorClient(s).pair(name);
      if (r.name != s.name) await _updateScreen(s.copyWith(name: r.name));
    } catch (_) {
      // Receptor apagado o viejo: se reintenta en el siguiente arranque de la app.
    }
  }

  // --- Cambio de red / IP ---------------------------------------------------------

  /// Buscando en la red una pantalla que dejó de responder.
  bool rediscovering = false;
  final _lastRediscover = <String, DateTime>{};

  /// Recorre la red del teléfono (y la de la IP anterior) buscando el receptor
  /// con el mismo id del QR en su puerto; si lo encuentra, guarda la IP nueva.
  /// Las TVs no tienen id: para ellas solo sirve [changeAddress].
  Future<bool> rediscover(String id) async {
    final i = screens.indexWhere((s) => s.id == id);
    if (i < 0 || screens[i].isTv || rediscovering) return false;
    final s = screens[i];
    rediscovering = true;
    _lastRediscover[id] = DateTime.now();
    notifyListeners();
    try {
      final prefixes = <String>{};
      final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      // Solo el Wi-Fi (wlan0): con datos móviles se recorrería la red de la compañía.
      final wifi = ifaces.where((i) => i.name.startsWith('wlan') || i.name.startsWith('eth')).toList();
      for (final iface in wifi.isEmpty ? ifaces : wifi) {
        for (final a in iface.addresses) {
          if (!a.isLoopback) prefixes.add(a.address.substring(0, a.address.lastIndexOf('.')));
        }
      }
      prefixes.add(s.host.substring(0, s.host.lastIndexOf('.')));
      final hosts = [for (final p in prefixes) for (var n = 1; n < 255; n++) '$p.$n'];
      var answered = 0;
      // De 64 en 64: primero ver quién abre el puerto, luego preguntarle su id.
      for (var start = 0; start < hosts.length; start += 64) {
        final batch = hosts.sublist(start, (start + 64).clamp(0, hosts.length));
        final open = await Future.wait(batch.map((h) async {
          try {
            final sock = await Socket.connect(h, s.port, timeout: const Duration(milliseconds: 800));
            sock.destroy();
            return h;
          } catch (_) {
            return null;
          }
        }));
        for (final h in open.whereType<String>()) {
          answered++;
          final health = await ProjectorClient(s.copyWith(host: h)).health();
          if (health?.id == s.id) {
            await _updateScreen(s.copyWith(host: h));
            status = '${s.name} cambió de IP: ahora es $h';
            error = null;
            if (id == selectedScreenId) await _tick();
            return true;
          }
        }
      }
      status = 'No encontré a ${s.name}: busqué en ${prefixes.map((p) => '$p.x').join(' y ')} '
          '($answered con el puerto ${s.port} abierto)';
      return false;
    } finally {
      rediscovering = false;
      notifyListeners();
    }
  }

  /// Cambia la IP (y el puerto) a mano. Para un receptor, comprueba que en esa
  /// dirección responda el mismo equipo; para una TV, que tenga YouTube por DIAL.
  Future<void> changeAddress(String id, String address) => _run(() async {
        final i = screens.indexWhere((s) => s.id == id);
        if (i < 0) return;
        final s = screens[i];
        final parts = address.trim().split(':');
        final host = parts.first.replaceAll(RegExp(r'[^0-9.]'), '');
        final port = parts.length > 1 ? int.tryParse(parts[1]) ?? s.port : s.port;
        if (!RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) throw StateError('"$address" no es una IP válida');
        if (s.isTv) {
          final tv = Screen.tv(host, name: s.name);
          if (await TvClient(tv).status() == null) throw StateError('En $host no responde una TV con YouTube');
          // El id de la TV sale de su IP: se reemplaza la entrada.
          screens[i] = tv;
          if (selectedScreenId == id) selectedScreenId = tv.id;
          await _persistScreens();
        } else {
          final moved = s.copyWith(host: host, port: port);
          final h = await ProjectorClient(moved).health();
          if (h == null) throw StateError('En $host:$port no responde ningún proyector');
          if (h.id != s.id) throw StateError('En $host responde otra pantalla ("${h.name}"): escanea su QR para agregarla');
          await _updateScreen(moved);
        }
        status = '${s.name} ahora está en $host';
        await _tick();
      });

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
    if (id == selectedScreenId && projectorOnline && !screens[i].isTv) {
      try {
        final r = await ProjectorClient(screens[i]).pair(phoneName ?? 'Teléfono', screenName: n);
        finalName = r.name;
      } catch (e) {
        error = _msg(e);
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
      error = _msg(e);
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
        if (s.isTv) throw StateError('Aleatorio todavía no funciona en TVs: toca una canción para mandarla');
        status = 'Armando la cola…';
        notifyListeners();
        final info = await ProjectorClient(s).queue(tracks: tracks, name: name, shuffle: shuffle, startAt: startAt);
        status = info == null ? 'No encontré videos para esta playlist' : 'Sonando en ${s.name}: $info';
        screenQueueInfo = info;
      });

  /// Cola sonando en la pantalla elegida ("Playlist · 3 de 20"); null si no hay.
  String? screenQueueInfo;

  // --- Tarjeta "En el proyector" ------------------------------------------------

  /// Ya respondió la pantalla elegida al menos una vez: hasta entonces no se sabe
  /// si sigue a Spotify por su cuenta y no se muestra el switch.
  bool screenChecked = false;

  /// Video de YouTube en el proyector y si está sonando.
  String? screenMediaTitle;
  bool screenMediaPlaying = false;

  /// Qué suena: una cola en el proyector, una canción de Spotify o solo un
  /// video en el proyector (o nada).
  ProjectorMode get projectorMode {
    if (screenQueueInfo != null) return ProjectorMode.queue;
    if (loggedIn && track != null) return ProjectorMode.spotify;
    return ProjectorMode.free;
  }

  /// El proyector cambia el video cuando cambia la canción de Spotify.
  bool get followingSpotify => screenSpotifyLinked ? screenFollowing : loggedIn && autoFollow;

  bool get isPlaying => projectorMode == ProjectorMode.spotify ? track!.isPlaying : screenMediaPlaying;

  /// El proyector muestra el video de la canción de Spotify: la sigue solo, o
  /// se le mandó esta misma canción.
  bool get showingTrack {
    final t = track;
    if (!projectorOnline || screenMediaTitle == null || t == null) return false;
    return followingSpotify || _sentKey == '${t.artist}|${t.title}';
  }

  /// Canción cuyo video se mandó a mano por última vez.
  String? _sentKey;

  /// Para marcar en las listas lo último que se mandó a la pantalla.
  bool isSentTrack(Track t) => _sentKey == '${t.artist}|${t.title}';
  String? lastSentVideoId;

  /// El status es solo el aviso de "enviado": la pestaña Ahora ya lo muestra
  /// en la tarjeta y no lo repite (Buscar y Playlists sí, en su SnackBar).
  bool get statusIsSend => status != null && status == _sendStatus;
  String? _sendStatus;

  /// Pausa o reanuda lo que suena: la música de Spotify y el video del proyector.
  Future<void> togglePlay() => _run(() async {
        final s = selectedScreen;
        final playing = isPlaying;
        final t = track;
        if (projectorMode == ProjectorMode.spotify && t != null) {
          await spotify.player(playing ? 'pause' : 'play');
          track = Track(title: t.title, artists: t.artists, isPlaying: !playing, album: t.album, artUrl: t.artUrl);
        }
        if (s != null && projectorOnline && screenMediaTitle != null) {
          if (s.isTv) {
            playing ? await TvClient(s).pause() : await TvClient(s).resume();
          } else {
            await ProjectorClient(s).media(playing ? 'pause' : 'play');
          }
          screenMediaPlaying = !playing;
        }
      });

  /// Siguiente: en una cola, la siguiente canción (el proyector busca su video);
  /// en modo Spotify salta la canción y el proyector la sigue en unos segundos.
  Future<void> skip() => _run(() async {
        final s = selectedScreen;
        if (projectorMode == ProjectorMode.queue && s != null) {
          status = 'Buscando la siguiente…';
          notifyListeners();
          final info = await ProjectorClient(s).queue(next: true);
          screenQueueInfo = info;
          status = info == null ? 'Cola terminada' : 'Sonando en ${s.name}: $info';
        } else if (projectorMode == ProjectorMode.spotify) {
          await spotify.player('next');
          status = followingSpotify && s != null ? 'Siguiente canción: ${s.name} cambia el video en unos segundos' : 'Siguiente canción';
        }
      });

  /// Detiene todo: corta la cola, pausa el video y, en modo Spotify, la música.
  Future<void> stopAll() => _run(() async {
        final s = selectedScreen;
        final t = track;
        if (projectorMode == ProjectorMode.spotify && t != null) {
          await spotify.player('pause');
          track = Track(title: t.title, artists: t.artists, isPlaying: false, album: t.album, artUrl: t.artUrl);
        }
        if (s != null && projectorOnline && (screenMediaTitle != null || screenQueueInfo != null)) {
          s.isTv ? await TvClient(s).pause() : await ProjectorClient(s).media('stop');
          screenQueueInfo = null;
          screenMediaPlaying = false;
        }
        status = 'Detenido';
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
      error = _msg(e);
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
        // Sin respuesta: reintenta en 1 minuto aunque el mercado esté cerrado.
        nextQuotesAt = q.isEmpty
            ? DateTime.now().add(const Duration(minutes: 1))
            : UsMarketHours.nextRefresh(DateTime.now(), lastMarketState: q.values.first.marketState);
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
        if (s.isTv) throw StateError('${s.name} no tiene el receptor: el tablero solo va en los proyectores');
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
        if (s == null || s.isTv) return;
        await ProjectorClient(s).trading(overlay: false);
        tradingOverlay = false;
        status = 'Video en grande otra vez';
      });

  // --- Volumen del proyector -------------------------------------------------------

  ({int level, int max, bool muted})? volume;

  Future<void> changeVolume({int? level, int? delta, bool? mute}) async {
    final s = selectedScreen;
    if (s == null) return;
    if (s.isTv) {
      // Volumen de YouTube 0..100 en pasos de 5.
      final cur = volume ?? (level: 50, max: 100, muted: false);
      try {
        if (mute != null) {
          await TvClient(s).mute(mute);
          volume = (level: cur.level, max: 100, muted: mute);
        } else {
          final next = (level ?? cur.level + (delta ?? 0) * 5).clamp(0, 100);
          await TvClient(s).setVolume(next);
          volume = (level: next, max: 100, muted: false);
        }
        error = null;
      } catch (e) {
        error = _msg(e);
      }
      notifyListeners();
      return;
    }
    final v = await ProjectorClient(s).volume(level: level, delta: delta, mute: mute);
    if (v != null) {
      volume = v;
      notifyListeners();
    }
  }

  /// Si el tablero está en el proyector, cada cambio se refleja allá.
  Future<void> _pushTrading() async {
    final s = selectedScreen;
    if (s == null || !projectorOnline || s.isTv) return;
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
    candidates = rankVideos(await youtube.search(t.searchQuery, fallbackQuery: t.plainQuery), t);
    if (candidates.isEmpty) throw StateError('YouTube no encontró nada para "$t"');
    await _play(candidates.first.video);
    _sentKey = '${t.artist}|${t.title}';
  }

  Future<void> _play(VideoCandidate video) async {
    final s = selectedScreen;
    if (s == null) throw StateError('No hay pantalla: escanea el QR del proyector');
    status = 'Enviando a ${s.name}…';
    notifyListeners();
    if (s.isTv) {
      await TvClient(s).play(video.id);
    } else {
      await ProjectorClient(s).play(video);
    }
    lastSentVideoId = video.id;
    status = _sendStatus = 'En ${s.name}: ${video.title}';
  }

  Future<void> _run(Future<void> Function() action) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
    } catch (e) {
      error = _msg(e);
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

/// Texto de error para mostrar: sin el prefijo "Bad state: " de StateError.
String _msg(Object e) => '$e'.replaceFirst('Bad state: ', '');

enum ProjectorMode { queue, spotify, free }
