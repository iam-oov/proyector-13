import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared/shared.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'mask.dart';
import 'player.dart';
import 'queue.dart';
import 'spotify_follow.dart';
import 'state.dart';
import 'stats_overlay.dart';

/// Servidor HTTP en la LAN. El teléfono manda `POST /play {"videoId": "..."}`
/// con el token que viene en el QR (`Authorization: Bearer <token>`).
class ReceiverServer {
  ReceiverServer(
    this.state, {
    this.port = 8080,
    this.onTradingChanged,
    this.mask,
    this.spotify,
    this.stats,
    this.queue,
  });

  final QueueController? queue;

  final ReceiverState state;
  final int port;
  final MaskController? mask;
  final SpotifyFollower? spotify;
  final StatsOverlayController? stats;

  /// Se llama después de cada POST /trading (persistir, pedir precios).
  final Future<void> Function()? onTradingChanged;
  Timer? _addressTimer;

  Future<void> start() async {
    final router = Router()
      ..get('/health', _health)
      ..post('/pair', _auth(_pair))
      ..post('/unpair', _auth(_unpair))
      ..post('/play', _auth(_play))
      ..post('/trading', _auth(_trading))
      ..post('/mask', _auth(_mask))
      ..post('/spotify', _auth(_spotify))
      ..post('/queue', _auth(_queue))
      ..post('/media', _auth(_media))
      ..get('/volume', _auth(_getVolume))
      ..post('/volume', _auth(_setVolume));
    final handler = const Pipeline()
        .addMiddleware(_cors())
        .addHandler(router.call);
    await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
    state.listening(await _lanAddress() ?? '0.0.0.0', port);
    debugPrint('pairing: ${state.pairingUri}');
    _addressTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refreshAddress(),
    );
  }

  void stop() => _addressTimer?.cancel();

  /// La IP puede cambiar (DHCP); si cambia, el QR se regenera.
  Future<void> _refreshAddress() async {
    if (state.addressChanged(await _lanAddress())) {
      debugPrint('pairing: ${state.pairingUri}');
    }
  }

  /// Exige el token del QR. Sin él, 401.
  Handler _auth(Handler inner) => (Request request) {
    final header = request.headers['authorization'] ?? '';
    if (header != 'Bearer ${state.identity.token}') {
      return _json(
        {'ok': false, 'error': 'código inválido: escanea el QR del proyector'},
        401,
        {'www-authenticate': 'Bearer realm="proyector"'},
      );
    }
    return inner(request);
  };

  Response _health(Request _) => _json({
    'ok': true,
    'app': receiverApp,
    'version': receiverApiVersion,
    'id': state.identity.id,
    'name': state.identity.name,
    'spotify': {
      'linked': state.spotifyLinked,
      'following': state.spotifyFollowing,
    },
    // Para que el teléfono muestre los controles de la cola (saltar/detener).
    'queue': {'active': queue?.active ?? false, 'info': state.queueInfo},
    'media': {
      'title': queue?.mediaTitle,
      'playing': queue?.mediaPlaying ?? false,
    },
  });

  /// Video de YouTube: `{"action": "play"|"pause"|"stop"}` o
  /// `{"action": "seek", "to"|"by": segundos}`. `stop` también
  /// corta la cola.
  Future<Response> _media(Request request) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'ok': false, 'error': 'body JSON inválido'}, 400);
    }
    final action = body['action']?.toString();
    if (action == 'seek') {
      // {"action": "seek", "to": segundos} o {"by": ±segundos}.
      final to = (body['to'] as num?)?.toInt();
      final by = (body['by'] as num?)?.toInt();
      if (to == null && by == null) {
        return _json({'ok': false, 'error': 'seek necesita to o by'}, 400);
      }
      final pos = await mediaSeek(
        toMs: to == null ? null : to * 1000,
        byMs: by == null ? null : by * 1000,
      );
      if (pos == null) {
        return _json({'ok': false, 'error': 'no hay video sonando'}, 409);
      }
      return _json({'ok': true, 'position': pos ~/ 1000});
    }
    if (action != 'play' && action != 'pause' && action != 'stop') {
      return _json({
        'ok': false,
        'error': 'action: play, pause, stop o seek',
      }, 400);
    }
    if (action == 'stop') queue?.stop();
    final ok = await mediaControl(action == 'play' ? 'play' : 'pause');
    return _json({'ok': true, 'media': ok});
  }

  /// Spotify del proyector:
  /// - `{"link": {"clientId": "...", "token": {access_token, refresh_token, expires_at, …}}}`
  /// - `{"following": true|false}`
  /// - `{"unlink": true}`
  Future<Response> _spotify(Request request) async {
    final s = spotify;
    if (s == null) {
      return _json({'ok': false, 'error': 'Spotify no disponible'}, 500);
    }
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'ok': false, 'error': 'body JSON inválido'}, 400);
    }
    final link = body['link'];
    if (link is Map) {
      final clientId = link['clientId']?.toString();
      final token = (link['token'] as Map?)?.cast<String, dynamic>();
      if (clientId == null || token == null || token['refresh_token'] == null) {
        return _json({'ok': false, 'error': 'faltan clientId o token'}, 400);
      }
      await s.link(clientId: clientId, token: token);
    }
    if (body['following'] is bool) {
      await s.setFollowing(body['following'] as bool);
    }
    if (body['unlink'] == true) await s.unlink();
    return _json({
      'ok': true,
      'linked': state.spotifyLinked,
      'following': state.spotifyFollowing,
    });
  }

  /// El teléfono se presenta (y opcionalmente renombra la pantalla).
  Future<Response> _pair(Request request) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'ok': false, 'error': 'body JSON inválido'}, 400);
    }
    final phone = body['phoneName']?.toString().trim() ?? '';
    if (phone.isEmpty) {
      return _json({'ok': false, 'error': 'falta phoneName'}, 400);
    }
    await state.addPhone(phone);
    final screenName = body['screenName']?.toString().trim();
    if (screenName != null && screenName.isNotEmpty) {
      await state.rename(screenName);
    }
    return _json({
      'ok': true,
      'id': state.identity.id,
      'name': state.identity.name,
      'phones': state.phones,
    });
  }

  /// El teléfono borró esta pantalla: `{"phoneName": "..."}`. Sale de
  /// "Conectado: …", se suelta la sesión de Spotify y se corta la cola (lo que
  /// el teléfono puso aquí no se queda corriendo sin él).
  Future<Response> _unpair(Request request) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'ok': false, 'error': 'body JSON inválido'}, 400);
    }
    final phone = body['phoneName']?.toString().trim() ?? '';
    if (phone.isNotEmpty) await state.removePhone(phone);
    await spotify?.unlink();
    queue?.stop();
    return _json({'ok': true, 'phones': state.phones});
  }

  /// El teléfono manda su bitácora y/o pide mostrar u ocultar el tablero:
  /// `{"show": true, "trades": [...]}` (ambos opcionales).
  Future<Response> _trading(Request request) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'ok': false, 'error': 'body JSON inválido'}, 400);
    }
    if (body['trades'] is List) {
      try {
        state.setTrades([
          for (final j in body['trades'] as List)
            Trade.fromJson(j as Map<String, dynamic>),
        ]);
      } catch (e) {
        return _json({'ok': false, 'error': 'trades inválidos: $e'}, 400);
      }
    }
    // "Mostrar": si hay otra app al frente (p. ej. YouTube con música), la
    // tarjeta flota encima del video sin interrumpirlo; si el inicio está al
    // frente, las estadísticas ya se ven ahí.
    var mode = 'none';
    if (body['show'] == true) {
      if (state.appInForeground || stats == null) {
        state.showPanel(ReceiverPanel.home);
        await bringToFront();
        mode = 'home';
      } else {
        await onTradingChanged?.call();
        await stats!.show();
        mode = 'overlay';
      }
    }
    if (body['overlay'] == false) await stats?.hide();
    if (mode != 'overlay') await onTradingChanged?.call();
    return _json({
      'ok': true,
      'mode': mode,
      'overlay': stats?.visible ?? false,
      'trades': state.trades.length,
    });
  }

  /// Cola: `{"tracks": [{title, artists}], "name": "…", "shuffle": true, "startAt": 0}`,
  /// `{"next": true}` o `{"stop": true}`.
  Future<Response> _queue(Request request) async {
    final q = queue;
    if (q == null) {
      return _json({'ok': false, 'error': 'cola no disponible'}, 500);
    }
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'ok': false, 'error': 'body JSON inválido'}, 400);
    }
    if (body['stop'] == true) {
      q.stop();
    } else if (body['next'] == true) {
      await q.next();
    } else if (body['tracks'] is List) {
      final tracks = <Track>[];
      try {
        for (final t in body['tracks'] as List) {
          tracks.add(Track.fromJson((t as Map).cast<String, dynamic>()));
        }
      } catch (e) {
        return _json({'ok': false, 'error': 'tracks inválidos: $e'}, 400);
      }
      if (body['shuffle'] == true) tracks.shuffle();
      await q.start(
        tracks,
        name: body['name']?.toString(),
        startAt: (body['startAt'] as num?)?.toInt() ?? 0,
      );
    }
    return _json({
      'ok': true,
      'active': q.active,
      'watching': q.watching,
      'info': state.queueInfo,
    });
  }

  Future<Response> _getVolume(Request _) async =>
      _json({'ok': true, ...await getVolume()});

  /// `{"level": 0..max}`, `{"delta": 1|-1}` o `{"mute": true|false}`.
  Future<Response> _setVolume(Request request) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'ok': false, 'error': 'body JSON inválido'}, 400);
    }
    try {
      final v = await setVolume(
        level: (body['level'] as num?)?.toInt(),
        delta: (body['delta'] as num?)?.toInt(),
        mute: body['mute'] as bool?,
      );
      return _json({'ok': true, ...v});
    } catch (e) {
      return _json({'ok': false, 'error': '$e'}, 500);
    }
  }

  /// Máscara de figura libre: `{"shapes": [[x,y,…],…], "feather": 0.02, "outline": true}`
  /// o `{"clear": true}`. Coordenadas normalizadas 0..1.
  Future<Response> _mask(Request request) async {
    final m = mask;
    if (m == null) {
      return _json({'ok': false, 'error': 'máscara no disponible'}, 500);
    }
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'ok': false, 'error': 'body JSON inválido'}, 400);
    }
    try {
      if (body['clear'] == true) {
        await m.clear();
      } else {
        await m.apply(
          shapes: parseShapes(body['shapes']),
          feather: ((body['feather'] as num?)?.toDouble() ?? 0).clamp(0.0, 0.1),
          outline: body['outline'] == true,
          save: body['save'] != false,
        );
      }
      return _json({'ok': true, 'active': m.active});
    } on FormatException catch (e) {
      return _json({'ok': false, 'error': e.message}, 400);
    } catch (e) {
      return _json({'ok': false, 'error': '$e'}, 500);
    }
  }

  Future<Response> _play(Request request) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'ok': false, 'error': 'body JSON inválido'}, 400);
    }
    final uri = youtubeUri(
      videoId: body['videoId']?.toString(),
      url: body['url']?.toString(),
      start: (body['start'] as num?)?.toInt(),
    );
    if (uri == null) {
      return _json({
        'ok': false,
        'error': 'falta videoId (11 chars) o url de YouTube',
      }, 400);
    }
    final label = body['title']?.toString() ?? uri.toString();
    try {
      queue?.stop(); // un video elegido a mano termina la cola
      await openVideo(uri);
      state.add('▶  $label');
      return _json({'ok': true});
    } catch (e) {
      state.add('✕  $label: $e', error: true);
      return _json({'ok': false, 'error': '$e'}, 500);
    }
  }
}

Response _json(
  Map<String, Object?> data, [
  int status = 200,
  Map<String, String> headers = const {},
]) => Response(
  status,
  body: jsonEncode(data),
  headers: {'content-type': 'application/json', ...headers},
);

const _corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
  'access-control-allow-headers': 'content-type, authorization',
};

Middleware _cors() => createMiddleware(
  requestHandler: (r) =>
      r.method == 'OPTIONS' ? Response.ok('', headers: _corsHeaders) : null,
  responseHandler: (r) => r.change(headers: _corsHeaders),
);

/// IP de wlan0 (o la primera que no sea loopback), para el QR y la pantalla.
Future<String?> _lanAddress() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  interfaces.sort(
    (a, b) => (a.name == 'wlan0' ? 0 : 1) - (b.name == 'wlan0' ? 0 : 1),
  );
  for (final i in interfaces) {
    for (final a in i.addresses) {
      if (!a.isLoopback) return a.address;
    }
  }
  return null;
}
