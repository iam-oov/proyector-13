import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'assistant.dart';
import 'catalog.dart';
import 'config.dart';
import 'projector.dart';
import 'roku.dart';
import 'screens.dart';
import 'sleep_timer.dart';
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

  /// Aviso pasajero: la app lo muestra como toast de 3 s ([statusSeq] cambia con
  /// cada aviso nuevo, aunque el texto se repita).
  String? get status => _status;
  set status(String? value) {
    _status = value;
    if (value != null) statusSeq++;
  }

  String? _status;
  int statusSeq = 0;
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

  /// Los resultados vienen del asistente: el primero ya se mandó y el resto son
  /// las otras opciones ("¿No es el video correcto?").
  bool searchFromAssistant = false;

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
        (s.isRoku
                ? RokuClient(s).info().then((i) => i != null)
                : s.isTv
                    ? TvClient(s).status().then((st) => st != null)
                    : ProjectorClient(s).health().then((h) => h?.id == s.id))
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
      screenSpotifyLinked = false;
      screenFollowing = false;
      screenQueueInfo = null;
      screenMediaTitle = null;
      screenMediaPlaying = false;
      volume = null;
    } else if (s.isRoku) {
      // Roku: responde aunque esté "apagada" en espera rápida. Lo que suena es la app al frente.
      final info = await RokuClient(s).info();
      screenIdMismatch = false;
      projectorOnline = info != null;
      rokuPowerOn = info?.powerOn ?? false;
      screenSpotifyLinked = false;
      screenFollowing = false;
      screenQueueInfo = null;
      final app = info == null ? null : await RokuClient(s).activeApp();
      screenMediaTitle = app?.name;
      screenMediaPlaying = app != null;
      screenChecked = true;
      // Volumen: la Roku no lo dice; queda el último que puso la app.
      if (info == null) volume = null;
      if (info != null && (rokuApps.isEmpty || _ticks % 100 == 0)) {
        try {
          rokuApps = await RokuClient(s).apps();
        } catch (_) {
          // Sin "Acceso a la red": las teclas tampoco van a entrar; se avisa al mandar algo.
        }
      }
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

  /// La Roku elegida está encendida con imagen (en espera sigue respondiendo).
  bool rokuPowerOn = false;

  /// Apps y entradas de la Roku elegida (para "abre Spotify", "pon el PlayStation").
  List<RokuApp> rokuApps = [];

  /// Rokus encontradas en el Wi-Fi del teléfono (SSDP).
  Future<List<RokuFound>> discoverRokus() => RokuClient.discover();

  /// Agrega una Roku TV por su IP, si responde por ECP.
  Future<void> addRoku(String host, {String? name}) => _run(() async {
        final h = host.trim();
        final info = await RokuClient(Screen.roku(h)).info();
        if (info == null) throw StateError('$h no responde como Roku: revisa la IP y que esté prendida (o en espera rápida)');
        final n = name?.trim().isEmpty ?? true ? (info.name.isEmpty ? 'Roku' : info.name) : name!.trim();
        final screen = Screen.roku(h, name: n);
        final i = screens.indexWhere((s) => s.id == screen.id);
        if (i >= 0) {
          screens[i] = screen;
        } else {
          screens.add(screen);
        }
        selectedScreenId = screen.id;
        rokuApps = [];
        await _persistScreens();
        status = info.acceptsKeys
            ? 'Roku "$n" guardada'
            : 'Roku "$n" guardada. Para que acepte órdenes: en la TV, Configuración → Sistema → Configuración avanzada → Control por aplicaciones móviles → Acceso a la red → Permisivo';
        await _tick();
      });

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
    if (name == null || !s.hasReceiver) return;
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
    if (i < 0 || !screens[i].hasReceiver || rediscovering) return false;
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
        // La pantalla se borró mientras se buscaba: ya no hay nada que avisar.
        if (!screens.any((x) => x.id == id)) return false;
        for (final h in open.whereType<String>()) {
          answered++;
          final health = await ProjectorClient(s.copyWith(host: h)).health();
          if (!screens.any((x) => x.id == id)) return false;
          if (health?.id == s.id) {
            await _updateScreen(s.copyWith(host: h));
            status = '${s.name} cambió de IP: ahora es $h';
            error = null;
            if (id == selectedScreenId) await _tick();
            return true;
          }
        }
      }
      if (!screens.any((x) => x.id == id)) return false;
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
        if (s.isRoku) {
          final roku = Screen.roku(host, name: s.name);
          if (await RokuClient(roku).info() == null) throw StateError('En $host no responde una Roku');
          // El id de la Roku sale de su IP: se reemplaza la entrada.
          screens[i] = roku;
          if (selectedScreenId == id) selectedScreenId = roku.id;
          await _persistScreens();
        } else if (s.isTv) {
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
    if (id == selectedScreenId && projectorOnline && screens[i].hasReceiver) {
      try {
        final r = await ProjectorClient(screens[i]).pair(phoneName ?? 'Teléfono', screenName: n);
        finalName = r.name;
      } catch (e) {
        error = _msg(e);
      }
    }
    await _updateScreen(screens[i].copyWith(name: finalName));
  }

  /// Desvincula la pantalla: al proyector se le quita la sesión de Spotify y se
  /// corta su cola (si no, sigue la música de este teléfono por su cuenta) y
  /// después se borra el token, así que para volver a usarla hay que escanear su QR.
  Future<void> removeScreen(String id) async {
    final i = screens.indexWhere((s) => s.id == id);
    if (i < 0) return;
    final s = screens[i];
    var reached = true;
    if (s.hasReceiver) {
      final client = ProjectorClient(s);
      // /unpair además lo quita de "Conectado: …"; Spotify y la cola van aparte
      // por si el receptor es viejo y no lo tiene. Tope de 4 s: si el proyector
      // está apagado, "Eliminar" no se queda colgado.
      final results = await Future.wait([
        client.spotify(unlink: true).then((_) => true, onError: (_) => false),
        client.queue(stop: true).then((_) => true, onError: (_) => false),
        if (phoneName != null) client.unpair(phoneName!).then((_) => true, onError: (_) => true),
      ]).timeout(const Duration(seconds: 4), onTimeout: () => [false]);
      reached = results.every((ok) => ok);
    }
    screens.removeAt(i);
    _online.remove(id);
    _announced.remove(id);
    _lastRediscover.remove(id);
    status = reached
        ? '${s.name} desvinculada: para volver a usarla escanea su QR'
        : 'Borré ${s.name}, pero no respondió: si seguía a Spotify, lo sigue. Apágalo en el proyector con "Dejar de seguir a Spotify" '
            'o, cuando prenda, escanea su QR y elimínalo otra vez';
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
        if (!s.hasReceiver) throw StateError('Aleatorio todavía no funciona en TVs: toca una canción para mandarla');
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

  /// El último video mandado (para su miniatura en Ahora).
  VideoCandidate? lastSentVideo;

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
          if (s.isRoku) {
            await RokuClient(s).key('Play'); // la misma tecla pausa y reanuda
          } else if (s.isTv) {
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
        if (s != null && s.isRoku && projectorMode != ProjectorMode.spotify) {
          await RokuClient(s).key('Fwd'); // en la Roku "siguiente" es avanzar
          status = 'Adelantando en ${s.name}';
        } else if (projectorMode == ProjectorMode.queue && s != null) {
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
          if (s.isRoku) {
            await RokuClient(s).key('Home');
          } else if (s.isTv) {
            await TvClient(s).pause();
          } else {
            await ProjectorClient(s).media('stop');
          }
          screenQueueInfo = null;
          screenMediaPlaying = false;
        }
        status = 'Detenido';
      });

  // --- Asistente de voz ----------------------------------------------------------

  final _assistant = Assistant();

  /// Paso en curso ("Entendiendo…", "Buscando…", "Eligiendo…"), o null si no hay.
  String? assistantStep;

  /// Lo que contestó el asistente la última vez ("Pongo música para la playa").
  String? assistantReply;

  /// Lo que se dijo la última vez (para mostrarlo arriba de la respuesta).
  String? assistantHeard;

  /// "Quiero poner música para la playa" → Claude entiende, busca en YouTube,
  /// elige el video adecuado y lo manda a la pantalla elegida. Una frase puede
  /// traer varias acciones ("pon Stranger Things a volumen 8 y apaga en 30 min"):
  /// se hacen en orden y se cuenta qué se hizo y qué no se pudo.
  Future<void> runAssistant(String said) async {
    final text = said.trim();
    if (text.isEmpty || assistantStep != null) return;
    assistantHeard = text;
    assistantReply = null;
    error = null;
    assistantStep = 'Entendiendo…';
    notifyListeners();
    try {
      final intent = await _assistant.understand(text, _assistantContext());
      if (intent.actions.isEmpty) throw StateError('No entendí. Prueba "pon música para la playa".');
      final done = <String>[];
      final failed = <String>[];
      for (final a in intent.actions) {
        try {
          final r = await _assistantAction(text, a);
          if (r != null) done.add(r);
        } catch (e) {
          failed.add(_msg(e));
        }
      }
      if (done.isEmpty && failed.length == 1) throw StateError(failed.first);
      final reply = intent.actions.length == 1 && done.isNotEmpty ? done.first : intent.reply;
      assistantReply = failed.isEmpty ? reply : '$reply. No pude: ${failed.join('; ')}';
    } catch (e) {
      error = _msg(e);
    } finally {
      assistantStep = null;
      notifyListeners();
    }
  }

  /// Hace una acción y devuelve su confirmación (null si no hay nada que decir).
  Future<String?> _assistantAction(String said, AssistantAction a) async {
    switch (a.action) {
      case 'play':
        if (selectedScreen == null) throw StateError('Primero elige una pantalla');
        assistantStep = 'Buscando en YouTube…';
        notifyListeners();
        final videos = await searchYouTubeWeb(a.searchQuery, max: 8);
        if (videos.isEmpty) throw StateError('YouTube no encontró nada para "${a.searchQuery}"');
        assistantStep = 'Eligiendo el video…';
        notifyListeners();
        final pick = await _assistant.pick(said, a, videos);
        searchResults = [videos[pick.index], for (final (i, v) in videos.indexed) if (i != pick.index) v];
        searchFromAssistant = true;
        assistantStep = 'Enviando…';
        notifyListeners();
        candidates = [];
        await _play(videos[pick.index], start: a.startSeconds > 0 ? a.startSeconds : null);
        return pick.reply;
      case 'play_title':
        return _playTitle(said, a);
      case 'control':
        assistantStep = 'Controlando…';
        notifyListeners();
        await _assistantControl(a);
        return null;
      case 'switch_screen':
        final q = a.screen.toLowerCase();
        final match = screens.where((s) => s.name.toLowerCase().contains(q) || q.contains(s.name.toLowerCase())).firstOrNull;
        if (match == null || q.isEmpty) throw StateError('No encontré la pantalla "${a.screen}"');
        await selectScreen(match.id);
        return 'Ahora en ${match.name}';
      case 'power':
        // Solo la Roku se apaga de verdad; el proyector solo quedaría en negro.
        final s = _roku('prender o apagar');
        assistantStep = a.on ? 'Prendiendo…' : 'Apagando…';
        notifyListeners();
        a.on ? await RokuClient(s).powerOn() : await RokuClient(s).powerOff();
        if (!a.on) await SleepTimer.cancel();
        return a.on ? 'Prendo ${s.name}' : 'Apago ${s.name}';
      case 'sleep_timer':
        final s = selectedScreen;
        if (s == null) throw StateError('Primero elige una pantalla');
        if (a.minutes == 0) {
          await SleepTimer.cancel();
          return 'Temporizador cancelado';
        }
        final exact = await SleepTimer.schedule(s, Duration(minutes: a.minutes));
        return '${s.isRoku ? 'Apago' : 'Detengo'} ${s.name} en ${a.minutes} min${exact ? '' : ' (si la app sigue abierta)'}';
      case 'open':
        final s = _roku('abrir apps o cambiar de entrada');
        if (rokuApps.isEmpty) rokuApps = await RokuClient(s).apps();
        final q = a.app.toLowerCase();
        final app = rokuApps.where((x) => x.name.toLowerCase().contains(q) || q.contains(x.name.toLowerCase())).firstOrNull;
        if (app == null || q.isEmpty) throw StateError('En ${s.name} no hay "${a.app}"');
        await RokuClient(s).launch(app.id);
        return '${app.isInput ? 'Cambio a' : 'Abro'} ${app.name}';
      case 'brightness':
        throw StateError('El brillo todavía no se puede desde la app');
      default:
        throw StateError('No entendí. Prueba "pon música para la playa".');
    }
  }

  /// La Roku elegida, o un error claro de por qué no se puede.
  Screen _roku(String what) {
    final s = selectedScreen;
    if (s == null) throw StateError('Primero elige una pantalla');
    if (!s.isRoku) throw StateError('${s.name} no es una Roku: $what solo se puede en las Roku');
    return s;
  }

  final _catalog = Catalog();

  /// Serie o película en un servicio: busca el título en el catálogo, Claude
  /// elige cuál es y la Roku abre la app directo en él.
  Future<String> _playTitle(String said, AssistantAction a) async {
    final s = _roku('ver series y películas');
    assistantStep = 'Buscando "${a.title}"…';
    notifyListeners();
    final titles = await _catalog.search(a.title);
    if (titles.isEmpty) throw StateError('No encontré "${a.title}" en el catálogo');
    assistantStep = 'Eligiendo…';
    notifyListeners();
    final pick = await _assistant.pickTitle(said, a, [for (final t in titles) t.toString()]);
    if (pick.index < 0) throw StateError('No encontré "${a.title}" en ningún servicio');
    final t = titles[pick.index];
    // El servicio pedido; si no dijo, el primero que lo tenga (en este orden).
    const order = ['netflix', 'disneyplus', 'prime', 'hbomax', 'appletv', 'crunchyroll', 'vix'];
    final provider = a.provider != 'any' && a.provider != 'youtube'
        ? a.provider
        : order.where(t.offers.containsKey).firstOrNull;
    final appId = provider == null ? null : RokuClient.appIds[provider];
    if (provider == null || appId == null) throw StateError('"${t.title}" no está en ningún servicio de ${s.name}');
    final id = t.offers[provider];
    assistantStep = 'Abriendo en ${_providerName(provider)}…';
    notifyListeners();
    if (id == null) {
      // Está en otro servicio, no en el pedido: se abre la app para buscarlo a mano.
      await RokuClient(s).launch(appId);
      throw StateError('"${t.title}" no está en ${_providerName(provider)}; abrí la app para que lo busques');
    }
    await RokuClient(s).launch(appId, contentId: id, mediaType: t.mediaType);
    screenMediaTitle = t.title;
    return pick.reply.isEmpty ? 'Pongo ${t.title} en ${_providerName(provider)}' : pick.reply;
  }

  static String _providerName(String p) => const {
        'netflix': 'Netflix',
        'disneyplus': 'Disney+',
        'prime': 'Prime Video',
        'hbomax': 'HBO Max',
        'appletv': 'Apple TV',
        'crunchyroll': 'Crunchyroll',
        'vix': 'ViX',
      }[p] ?? p;

  String _assistantContext() {
    final list = [
      for (final s in screens)
        '- ${s.name} (${s.isRoku ? 'Roku' : s.isTv ? 'TV' : 'proyector'}'
            '${s.id == selectedScreenId ? ', elegida' : ''}'
            '${isScreenOnline(s.id) == false ? ', no responde' : ''})',
    ].join('\n');
    final t = track;
    final playing = screenMediaTitle != null ? 'En la pantalla elegida suena: $screenMediaTitle' : 'En la pantalla elegida no suena nada';
    final s = selectedScreen;
    final apps = s != null && s.isRoku && rokuApps.isNotEmpty
        ? '\nApps y entradas de ${s.name}: ${rokuApps.map((x) => x.name).join(', ')}'
        : '';
    final sleep = SleepTimer.at == null ? '' : '\nTemporizador: se apaga ${SleepTimer.screenName} a las ${_hhmm(SleepTimer.at!)}';
    final v = volume;
    final vol = v == null ? '' : '\nVolumen: ${v.muted ? 'en silencio' : '${v.level} de ${v.max}'}';
    return 'Pantallas:\n${list.isEmpty ? '(ninguna)' : list}\n$playing$apps$sleep$vol'
        '${t == null ? '' : '\nEn Spotify: ${t.title} — ${t.artist}'}';
  }

  static String _hhmm(DateTime d) => '${d.hour}:${d.minute.toString().padLeft(2, '0')}';

  Future<void> _assistantControl(AssistantAction i) async {
    final s = selectedScreen;
    if (s == null) throw StateError('Primero elige una pantalla');
    // _run apaga busy y guarda el error; aquí solo se necesita la acción.
    switch (i.control) {
      case 'pause':
        if (isPlaying) await togglePlay();
      case 'resume':
        if (!isPlaying) await togglePlay();
      case 'next':
        await skip();
      case 'stop':
        await stopAll();
      case 'volume_up' || 'volume_down':
        // Pasos que dijo ("súbele 3"); si no dijo, 2.
        final steps = (i.volume > 0 ? i.volume : 2) * (i.control == 'volume_up' ? 1 : -1);
        final v = volume;
        // El proyector sube de a uno por llamada: mejor poner el nivel de una vez.
        s.hasReceiver && v != null
            ? await changeVolume(level: (v.level + steps).clamp(0, v.max))
            : await changeVolume(delta: steps);
      case 'volume_set':
        final v = volume;
        await changeVolume(level: v == null || s.isRoku ? i.volume : (i.volume * v.max / 100).round());
      case 'seek_forward':
        await seekVideo(by: i.seconds);
      case 'seek_back':
        await seekVideo(by: -i.seconds);
      case 'seek_to':
        await seekVideo(to: i.seconds);
      case 'mute':
        await changeVolume(mute: true);
      case 'unmute':
        await changeVolume(mute: false);
    }
    if (error != null) throw StateError(error!);
  }

  // --- Buscar ------------------------------------------------------------------

  /// Búsqueda libre en YouTube (categoría Música), en el orden que da YouTube.
  Future<void> search(String query) async {
    final q = query.trim();
    if (q.isEmpty || searching) return;
    searching = true;
    searchFromAssistant = false;
    assistantHeard = assistantReply = null;
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

  Future<void> deleteTrade(String id) => deleteTrades({id});

  /// Borra sin vender: para movimientos de prueba o mal capturados. Una
  /// posición se borra completa (todos sus movimientos) en un solo guardado.
  Future<void> deleteTrades(Set<String> ids) async {
    trades = [for (final t in trades) if (!ids.contains(t.id)) t];
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
        if (!s.hasReceiver) throw StateError('${s.name} no tiene el receptor: el tablero solo va en los proyectores');
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
        if (s == null || !s.hasReceiver) return;
        await ProjectorClient(s).trading(overlay: false);
        tradingOverlay = false;
        status = 'Video en grande otra vez';
      });

  // --- Volumen del proyector -------------------------------------------------------

  ({int level, int max, bool muted})? volume;

  Future<void> changeVolume({int? level, int? delta, bool? mute}) async {
    final s = selectedScreen;
    if (s == null) return;
    if (s.isRoku) {
      // La Roku no dice su volumen: se lleva aquí el último que puso la app (0..100,
      // de uno en uno). Poner un nivel exacto baja a 0 y sube: unos 10 s.
      final cur = volume;
      try {
        if (mute != null) {
          if ((cur?.muted ?? false) != mute) await RokuClient(s).key('VolumeMute');
          volume = (level: cur?.level ?? 0, max: 100, muted: mute);
        } else if (level != null) {
          status = 'Poniendo el volumen de ${s.name} en $level…';
          notifyListeners();
          await RokuClient(s).setVolume(level);
          volume = (level: level.clamp(0, 100), max: 100, muted: false);
        } else {
          final steps = (delta ?? 0) * 5;
          await RokuClient(s).nudgeVolume(steps);
          volume = cur == null ? null : (level: (cur.level + steps).clamp(0, 100), max: 100, muted: false);
        }
        error = null;
      } catch (e) {
        error = _msg(e);
      }
      notifyListeners();
      return;
    }
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
    if (s == null || !projectorOnline || !s.hasReceiver) return;
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

  /// Salta dentro del video que suena: a [to] segundos o [by] desde donde va.
  Future<int> seekVideo({int? to, int? by}) async {
    final s = selectedScreen;
    if (s == null) throw StateError('Primero elige una pantalla');
    if (s.isRoku) throw StateError('En la Roku no se puede adelantar por red; usa pausa o siguiente');
    return s.isTv ? TvClient(s).seek(to: to, by: by) : ProjectorClient(s).seek(to: to, by: by);
  }

  Future<void> _play(VideoCandidate video, {int? start}) async {
    final s = selectedScreen;
    if (s == null) throw StateError('No hay pantalla: escanea el QR del proyector');
    status = 'Enviando a ${s.name}…';
    notifyListeners();
    if (s.isRoku) {
      // YouTube en la Roku abre el video; el minuto de inicio no lo entiende.
      await RokuClient(s).youtube(video.id);
    } else if (s.isTv) {
      await TvClient(s).play(video.id, start: start);
    } else {
      await ProjectorClient(s).play(video, start: start);
    }
    lastSentVideoId = video.id;
    lastSentVideo = video;
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
