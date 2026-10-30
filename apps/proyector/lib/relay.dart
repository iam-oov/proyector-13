import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shelf/shelf.dart';

import 'server.dart';
import 'state.dart';

/// Where the relay lives. Override for local tests with
/// `--dart-define=RELAY_URL=ws://<mac-ip>:8090/proyector/relay/ws`.
const relayUrl = String.fromEnvironment(
  'RELAY_URL',
  defaultValue: 'wss://valdoh.com/proyector/relay/ws',
);

/// Keeps an outbound WebSocket open to the relay so phones outside this
/// network (the PWA at valdoh.com/proyector) can reach the projector.
///
/// Requests arrive as `{"type":"req","rid","method","path","query","headers","body"}`
/// and are answered by the same shelf pipeline as the LAN server, so routes
/// and the Bearer token check behave exactly the same both ways.
class RelayClient {
  RelayClient(this.state, this.server);

  final ReceiverState state;
  final ReceiverServer server;

  static const _backoff = [2, 5, 10, 30];

  WebSocket? _ws;
  String? _connectedId;
  bool _stopped = false;

  /// True while the relay has accepted this projector.
  bool online = false;

  void start() {
    // Regenerating the pairing code changes the id: reconnect under the new one.
    state.addListener(() {
      if (_connectedId != null && _connectedId != state.identity.id) {
        unawaited(_ws?.close(1000, 'id changed'));
      }
    });
    unawaited(_run());
  }

  void stop() {
    _stopped = true;
    unawaited(_ws?.close(1000, 'stopped'));
  }

  Future<void> _run() async {
    var attempt = 0;
    while (!_stopped) {
      try {
        await _session();
        attempt = 0; // it was connected for a while; start the backoff over
      } catch (e) {
        debugPrint('relay: $e');
      }
      online = false;
      _connectedId = null;
      if (_stopped) break;
      final wait = _backoff[attempt.clamp(0, _backoff.length - 1)];
      attempt++;
      await Future<void>.delayed(Duration(seconds: wait));
    }
  }

  Future<void> _session() async {
    final ws = await WebSocket.connect(relayUrl).timeout(const Duration(seconds: 15));
    // Cloudflare drops idle sockets after ~100 s.
    ws.pingInterval = const Duration(seconds: 30);
    _ws = ws;
    final identity = state.identity;
    _connectedId = identity.id;
    ws.add(jsonEncode({
      'type': 'hello',
      'id': identity.id,
      'key': identity.relayKey,
      'name': identity.name,
    }));
    await for (final raw in ws) {
      if (raw is! String) continue;
      final Map<String, dynamic> msg;
      try {
        msg = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      switch (msg['type']) {
        case 'welcome':
          online = true;
          debugPrint('relay: online as ${identity.id} (relay ${msg['version']})');
        case 'req':
          unawaited(_answer(ws, msg));
      }
    }
    if (ws.closeCode != null && ws.closeCode! >= 4000) {
      debugPrint('relay: closed ${ws.closeCode} ${ws.closeReason}');
    }
  }

  Future<void> _answer(WebSocket ws, Map<String, dynamic> msg) async {
    final rid = msg['rid'];
    Map<String, Object?> reply;
    try {
      final handler = server.handler;
      if (handler == null) throw StateError('server not started');
      final query = (msg['query'] as String?) ?? '';
      final uri = Uri.parse('http://relay${msg['path']}${query.isEmpty ? '' : '?$query'}');
      final headers = <String, String>{
        for (final e in ((msg['headers'] as Map?) ?? const {}).entries) '${e.key}'.toLowerCase(): '${e.value}',
      };
      final body = base64Decode((msg['body'] as String?) ?? '');
      final response = await handler(Request(
        (msg['method'] as String?) ?? 'GET',
        uri,
        headers: headers,
        body: body,
      ));
      final bytes = await response.read().expand((chunk) => chunk).toList();
      reply = {
        'status': response.statusCode,
        'headers': response.headers,
        'body': base64Encode(bytes),
      };
    } catch (e) {
      reply = {
        'status': 500,
        'headers': {'content-type': 'application/json'},
        'body': base64Encode(utf8.encode(jsonEncode({'ok': false, 'error': '$e'}))),
      };
    }
    if (ws.readyState == WebSocket.open) {
      ws.add(jsonEncode({'type': 'res', 'rid': rid, ...reply}));
    }
  }
}
