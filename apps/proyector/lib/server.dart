import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared/shared.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'player.dart';
import 'state.dart';

/// Servidor HTTP en la LAN. El teléfono manda `POST /play {"videoId": "..."}`
/// con el token que viene en el QR (`Authorization: Bearer <token>`).
class ReceiverServer {
  ReceiverServer(this.state, {this.port = 8080, this.onTradingChanged});

  final ReceiverState state;
  final int port;

  /// Se llama después de cada POST /trading (persistir, pedir precios).
  final Future<void> Function()? onTradingChanged;
  Timer? _addressTimer;

  Future<void> start() async {
    final router = Router()
      ..get('/health', _health)
      ..post('/pair', _auth(_pair))
      ..post('/play', _auth(_play))
      ..post('/trading', _auth(_trading));
    final handler = const Pipeline().addMiddleware(_cors()).addHandler(router.call);
    await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
    state.listening(await _lanAddress() ?? '0.0.0.0', port);
    debugPrint('pairing: ${state.pairingUri}');
    _addressTimer = Timer.periodic(const Duration(seconds: 30), (_) => _refreshAddress());
  }

  void stop() => _addressTimer?.cancel();

  /// La IP puede cambiar (DHCP); si cambia, el QR se regenera.
  Future<void> _refreshAddress() async {
    if (state.addressChanged(await _lanAddress())) debugPrint('pairing: ${state.pairingUri}');
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
      });

  /// El teléfono se presenta (y opcionalmente renombra la pantalla).
  Future<Response> _pair(Request request) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'ok': false, 'error': 'body JSON inválido'}, 400);
    }
    final phone = body['phoneName']?.toString().trim() ?? '';
    if (phone.isEmpty) return _json({'ok': false, 'error': 'falta phoneName'}, 400);
    await state.addPhone(phone);
    final screenName = body['screenName']?.toString().trim();
    if (screenName != null && screenName.isNotEmpty) await state.rename(screenName);
    return _json({
      'ok': true,
      'id': state.identity.id,
      'name': state.identity.name,
      'phones': state.phones,
    });
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
        state.setTrades([for (final j in body['trades'] as List) Trade.fromJson(j as Map<String, dynamic>)]);
      } catch (e) {
        return _json({'ok': false, 'error': 'trades inválidos: $e'}, 400);
      }
    }
    if (body['show'] is bool) {
      final show = body['show'] as bool;
      state.showPanel(show ? ReceiverPanel.trading : ReceiverPanel.qr);
      // Si YouTube está al frente, el tablero no se vería: nos traemos al frente.
      if (show) await bringToFront();
    }
    await onTradingChanged?.call();
    return _json({'ok': true, 'panel': state.panel.name, 'trades': state.trades.length});
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
    );
    if (uri == null) {
      return _json({'ok': false, 'error': 'falta videoId (11 chars) o url de YouTube'}, 400);
    }
    final label = body['title']?.toString() ?? uri.toString();
    try {
      await openVideo(uri);
      state.add('▶  $label');
      return _json({'ok': true});
    } catch (e) {
      state.add('✕  $label: $e', error: true);
      return _json({'ok': false, 'error': '$e'}, 500);
    }
  }
}

Response _json(Map<String, Object?> data, [int status = 200, Map<String, String> headers = const {}]) =>
    Response(
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
      requestHandler: (r) => r.method == 'OPTIONS' ? Response.ok('', headers: _corsHeaders) : null,
      responseHandler: (r) => r.change(headers: _corsHeaders),
    );

/// IP de wlan0 (o la primera que no sea loopback), para el QR y la pantalla.
Future<String?> _lanAddress() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  interfaces.sort((a, b) => (a.name == 'wlan0' ? 0 : 1) - (b.name == 'wlan0' ? 0 : 1));
  for (final i in interfaces) {
    for (final a in i.addresses) {
      if (!a.isLoopback) return a.address;
    }
  }
  return null;
}
