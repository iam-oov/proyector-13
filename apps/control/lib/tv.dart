import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'screens.dart';

/// Estado de YouTube en una TV sin receptor (por DIAL).
class TvStatus {
  const TvStatus({required this.running, this.screenId});

  final bool running;

  /// Id de la pantalla de YouTube: aparece en DIAL ~18 s después de abrirla.
  final String? screenId;
}

/// TV sin receptor (p. ej. Hyundai/Horion con Linux): no se le instala nada.
/// DIAL (puerto 56789) abre o cierra YouTube, y la API Lounge de YouTube (la que
/// usa "transmitir" del teléfono) pone videos, pausa, salta y cambia el volumen
/// de YouTube. No puede encenderla ni manejar sus menús.
class TvClient {
  TvClient(this.screen);

  final Screen screen;

  /// Una sesión Lounge por TV: volver a enlazar en cada comando hace que la TV
  /// muestre "conectado" cada vez.
  static final _sessions = <String, _LoungeSession>{};

  Uri get _youtubeApp => Uri(scheme: 'http', host: screen.host, port: screen.port, path: '/apps/YouTube');

  /// Null si la TV no responde o no tiene YouTube por DIAL.
  Future<TvStatus?> status() async {
    try {
      final r = await http.get(_youtubeApp).timeout(const Duration(seconds: 3));
      if (r.statusCode != 200 || !r.body.contains('<name>YouTube</name>')) return null;
      final running = RegExp(r'<state>running</state>').hasMatch(r.body);
      final id = RegExp(r'<screenId>([^<]+)</screenId>').firstMatch(r.body)?.group(1);
      return TvStatus(running: running, screenId: id);
    } catch (_) {
      return null;
    }
  }

  /// Pone el video. Si YouTube está cerrado, lo abre por DIAL con el video (va
  /// directo al video, sin "Elige una cuenta") y espera su screenId.
  Future<void> play(String videoId, {int? start}) async {
    var st = await status();
    if (st == null) throw StateError('La TV no responde: ¿está prendida y en la misma red Wi-Fi que el teléfono?');
    if (!st.running || st.screenId == null) {
      final r = await http
          .post(_youtubeApp, headers: {'content-type': 'text/plain; charset=utf-8'}, body: 'v=$videoId${start == null ? '' : '&t=$start'}')
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 201 && r.statusCode != 200) throw StateError('La TV no abrió YouTube (${r.statusCode})');
      // Con el video en el arranque ya basta; el screenId se espera para que
      // los botones (pausa, siguiente) funcionen enseguida.
      for (var i = 0; i < 30 && st?.screenId == null; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        st = await status();
      }
      return;
    }
    await _command(st.screenId!, 'setPlaylist', {
      'videoId': videoId,
      'videoIds': videoId,
      'currentIndex': '0',
      'currentTime': '${start ?? 0}',
      'listId': '',
      'audioOnly': 'false',
    });
  }

  Future<void> pause() => _withScreen('pause');
  Future<void> resume() => _withScreen('play');
  Future<void> next() => _withScreen('next');

  /// Volumen de YouTube (0..100), no el de la TV.
  Future<void> setVolume(int volume) => _withScreen('setVolume', {'volume': '${volume.clamp(0, 100)}'});

  Future<void> mute(bool on) => _withScreen(on ? 'mute' : 'unMute');

  /// Salta a [to] segundos, o [by] segundos desde donde va (se pregunta la
  /// posición a YouTube con getNowPlaying → evento nowPlaying). Devuelve la nueva.
  Future<int> seek({int? to, int? by}) async {
    final st = await status();
    final id = st?.screenId;
    if (id == null || !st!.running) throw StateError('YouTube no está abierto en la TV');
    var target = to;
    if (target == null) {
      await _command(id, 'getNowPlaying', const {});
      final m = await _sessions[screen.host]?.waitEvent('nowPlaying');
      final now = m == null ? null : double.tryParse('${(jsonDecode(m) as Map)['currentTime']}');
      if (now == null) throw StateError('No supe en qué minuto va el video de la TV');
      target = now.round() + (by ?? 0);
    }
    target = target < 0 ? 0 : target;
    await _command(id, 'seekTo', {'newTime': '$target'});
    return target;
  }

  /// Volumen actual de YouTube: se pide con getVolume y llega como evento
  /// onVolumeChanged en el canal de eventos de la sesión. Null si no llega.
  Future<({int level, bool muted})?> volume() async {
    final st = await status();
    final id = st?.screenId;
    if (id == null || !st!.running) return null;
    try {
      await _command(id, 'getVolume', const {});
      final m = await _sessions[screen.host]?.waitEvent('onVolumeChanged');
      if (m == null) return null;
      final j = jsonDecode(m) as Map<String, dynamic>;
      return (level: int.tryParse('${j['volume']}') ?? 0, muted: '${j['muted']}' == 'true');
    } catch (_) {
      return null;
    }
  }

  /// Cierra YouTube en la TV.
  Future<void> stop() async {
    await http.delete(_youtubeApp.replace(path: '/apps/YouTube/run')).timeout(const Duration(seconds: 5));
    _sessions.remove(screen.host);
  }

  Future<void> _withScreen(String command, [Map<String, String> args = const {}]) async {
    final st = await status();
    final id = st?.screenId;
    if (id == null || !st!.running) throw StateError('YouTube no está abierto en la TV');
    await _command(id, command, args);
  }

  Future<void> _command(String screenId, String command, Map<String, String> args) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      var s = _sessions[screen.host];
      if (s == null || s.screenId != screenId) {
        s = await _LoungeSession.bind(screenId);
        _sessions[screen.host] = s;
      }
      if (await s.send(command, args)) return;
      _sessions.remove(screen.host); // sesión vencida: se enlaza otra vez
    }
    throw StateError('YouTube en la TV no aceptó "$command"');
  }
}

/// Sesión de la API Lounge de YouTube con una pantalla.
class _LoungeSession {
  _LoungeSession(this.screenId, this._params, this._sid, this._gsession, this._rid);

  static const _base = 'https://www.youtube.com/api/lounge';

  final String screenId;
  final Map<String, String> _params;
  final String _sid;
  final String _gsession;
  int _rid;
  int _aid = 0;

  /// Mensajes ya mandados en esta sesión: cada comando va con el siguiente.
  int _ofs = 0;

  static Future<_LoungeSession> bind(String screenId) async {
    final t = await http
        .post(Uri.parse('$_base/pairing/get_lounge_token_batch'), body: {'screen_ids': screenId})
        .timeout(const Duration(seconds: 10));
    if (t.statusCode != 200) throw StateError('YouTube no dio acceso a la TV (${t.statusCode})');
    final token = ((jsonDecode(t.body) as Map)['screens'] as List).first['loungeToken'] as String;

    final rnd = Random();
    final rid = 10000 + rnd.nextInt(80000);
    final params = {
      'device': 'REMOTE_CONTROL',
      'name': 'Proyector',
      'app': 'youtube-desktop',
      'mdx-version': '3',
      'id': List.generate(16, (_) => rnd.nextInt(16).toRadixString(16)).join(),
      'VER': '8',
      'loungeIdToken': token,
    };
    final r = await http
        .post(
          Uri.parse('$_base/bc/bind').replace(queryParameters: {
            ...params,
            'CVER': '1',
            'RID': '$rid',
            'zx': List.generate(12, (_) => String.fromCharCode(97 + rnd.nextInt(26))).join(),
            't': '1',
          }),
          body: {'count': '0'},
        )
        .timeout(const Duration(seconds: 10));
    // La respuesta viene en bloques partidos en varias líneas: basta con los eventos
    // ["c","<SID>",…] y ["S","<gsessionid>"].
    final sid = RegExp(r'\["c","([^"]+)"').firstMatch(r.body)?.group(1);
    final gs = RegExp(r'\["S","([^"]+)"').firstMatch(r.body)?.group(1);
    if (sid == null || gs == null) throw StateError('No pude conectarme a YouTube en la TV');
    return _LoungeSession(screenId, params, sid, gs, rid);
  }

  /// Lee el canal de eventos (long-poll) hasta ver `name` y devuelve su JSON, o null
  /// a los 5 s.
  Future<String?> waitEvent(String name) async {
    final client = http.Client();
    try {
      final req = http.Request(
        'GET',
        Uri.parse('$_base/bc/bind').replace(queryParameters: {
          ..._params,
          'SID': _sid,
          'gsessionid': _gsession,
          'RID': 'rpc',
          'CI': '0',
          'AID': '$_aid',
          'TYPE': 'xmlhttp',
        }),
      );
      final res = await client.send(req).timeout(const Duration(seconds: 5));
      final pattern = RegExp('\\["$name",(\\{[^}]*\\})\\]');
      var body = '';
      await for (final chunk in res.stream.transform(utf8.decoder).timeout(const Duration(seconds: 5))) {
        body += chunk;
        final m = pattern.firstMatch(body);
        if (m != null) return m.group(1);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  Future<bool> send(String command, Map<String, String> args) async {
    _rid++;
    final r = await http
        .post(
          Uri.parse('$_base/bc/bind').replace(queryParameters: {
            ..._params,
            'SID': _sid,
            'gsessionid': _gsession,
            'RID': '$_rid',
            'AID': '${_aid++}',
          }),
          body: {
            'count': '1',
            'ofs': '${_ofs++}',
            'req0__sc': command,
            for (final e in args.entries) 'req0_${e.key}': e.value,
          },
        )
        .timeout(const Duration(seconds: 10));
    return r.statusCode == 200;
  }
}
