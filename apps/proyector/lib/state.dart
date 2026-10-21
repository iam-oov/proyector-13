import 'package:flutter/foundation.dart';
import 'package:shared/shared.dart';

import 'identity.dart';

enum ReceiverPanel { home, qr }

/// Lo que la pantalla del proyector muestra: el QR, dónde escucha, qué ha
/// recibido y, si el teléfono lo pide, el tablero de trading.
class ReceiverState extends ChangeNotifier {
  ReceiverState(this.identity);

  final ReceiverIdentity identity;
  String? host;
  int port = 8080;
  final List<ReceiverEvent> events = [];

  ReceiverPanel panel = ReceiverPanel.home;
  List<Trade> trades = [];
  Map<String, Quote> quotes = {};
  DateTime? quotesAt;
  DateTime? nextQuotesAt;
  bool quotesLoading = false;
  String? quotesError;

  /// Contenido del QR. Null hasta que se conoce la IP.
  String? get pairingUri => host == null
      ? null
      : PairingPayload(id: identity.id, name: identity.name, host: host!, port: port, token: identity.token)
          .toUri()
          .toString();

  PortfolioStats get stats => PortfolioStats.compute(trades, quotes);

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

  void showPanel(ReceiverPanel p) {
    if (panel == p) return;
    panel = p;
    notifyListeners();
  }

  void setTrades(List<Trade> t) {
    trades = t;
    notifyListeners();
  }

  void setQuotes(Map<String, Quote> q) {
    quotes = q;
    quotesAt = DateTime.now();
    quotesError = null;
    notifyListeners();
  }

  void quoteError(String message) {
    quotesError = message;
    notifyListeners();
  }

  // Spotify del propio proyector (ver spotify_follow.dart).
  bool spotifyLinked = false;
  bool spotifyFollowing = false;
  Track? nowPlaying;

  /// Solo notifica si algo visible cambió (se llama cada 5 s).
  void setSpotify({bool? linked, bool? following, Track? nowPlaying, bool clearNowPlaying = false}) {
    String snap() => '$spotifyLinked|$spotifyFollowing|${this.nowPlaying}|${this.nowPlaying?.isPlaying}';
    final before = snap();
    if (linked != null) spotifyLinked = linked;
    if (following != null) spotifyFollowing = following;
    if (nowPlaying != null) this.nowPlaying = nowPlaying;
    if (clearNowPlaying || linked == false) this.nowPlaying = null;
    if (snap() != before) notifyListeners();
  }

  void setQuotesLoading(bool loading, {DateTime? nextAt}) {
    quotesLoading = loading;
    if (nextAt != null) nextQuotesAt = nextAt;
    notifyListeners();
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
