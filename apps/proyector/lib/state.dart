import 'package:flutter/foundation.dart';
import 'package:shared/shared.dart';

import 'identity.dart';

/// Lo que la pantalla del proyector muestra: el QR, dónde escucha y qué ha recibido.
class ReceiverState extends ChangeNotifier {
  ReceiverState(this.identity);

  final ReceiverIdentity identity;
  String? host;
  int port = 8080;
  final List<ReceiverEvent> events = [];

  /// Contenido del QR. Null hasta que se conoce la IP.
  String? get pairingUri => host == null
      ? null
      : PairingPayload(id: identity.id, name: identity.name, host: host!, port: port, token: identity.token)
          .toUri()
          .toString();

  void listening(String host, int port) {
    this.host = host;
    this.port = port;
    notifyListeners();
  }

  /// Solo notifica (y regenera el QR) cuando la IP de verdad cambió.
  bool addressChanged(String? host) {
    if (host == null || host == this.host) return false;
    this.host = host;
    notifyListeners();
    return true;
  }

  Future<void> rename(String name) async {
    await identity.rename(name);
    notifyListeners();
  }

  List<String> get phones => identity.phones;

  Future<void> addPhone(String name) async {
    if (await identity.addPhone(name)) {
      add('🔗  $name conectado');
    }
  }

  void add(String message, {bool error = false}) {
    events.insert(0, ReceiverEvent(DateTime.now(), message, error));
    if (events.length > 8) events.removeLast();
    notifyListeners();
  }
}

class ReceiverEvent {
  ReceiverEvent(this.at, this.message, this.error);

  final DateTime at;
  final String message;
  final bool error;
}
