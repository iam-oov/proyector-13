import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared/shared.dart';

import 'identity.dart';
import 'relay.dart' show pwaUrl;

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

  /// Connected to the relay (www.valdoh.com): phones can reach it from any
  /// network. Shown as the dot next to the Wi-Fi on the home screen.
  bool relayOnline = false;

  void setRelayOnline(bool on) {
    if (relayOnline == on) return;
    relayOnline = on;
    notifyListeners();
  }

  /// Si nuestra app está al frente (si no, normalmente YouTube).
  bool appInForeground = true;
  List<Trade> trades = [];
  Map<String, Quote> quotes = {};
  DateTime? quotesAt;
  DateTime? nextQuotesAt;
  bool quotesLoading = false;
  String? quotesError;

  /// Contenido del QR. Null hasta que se conoce la IP.
  String? get pairingUri => host == null
      ? null
      : PairingPayload(
          id: identity.id,
          name: identity.name,
          host: host!,
          port: port,
          token: identity.token,
        ).toLink(pwaUrl);

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

  Future<void> regenerateCode() async {
    await identity.regenerate();
    add('🔑  Código nuevo: los teléfonos tienen que volver a escanear');
  }

  List<String> get phones => identity.phones;

  Future<void> addPhone(String name) async {
    if (await identity.addPhone(name)) {
      add('🔗  $name conectado');
    }
  }

  Future<void> removePhone(String name) async {
    if (await identity.removePhone(name)) {
      add('🔌  $name se desvinculó');
    }
  }

  void showPanel(ReceiverPanel p) {
    if (panel == p) return;
    panel = p;
    if (p == ReceiverPanel.qr) {
      _newShortCode();
    } else {
      _clearShortCode();
    }
    notifyListeners();
  }

  /// 6 digits shown next to the QR while the pairing panel is open, to type
  /// on a phone (www.valdoh.com/proyector) instead of scanning. Null when
  /// the panel is closed. Not the same as [regenerateCode], which replaces
  /// the QR's token.
  String? shortCode;
  DateTime? _shortCodeUntil;
  int _shortCodeMisses = 0;
  Timer? _shortCodeTimer;
  static const shortCodeTtl = Duration(minutes: 10);
  static const _shortCodeMaxMisses = 5;

  void _newShortCode() {
    final rng = Random.secure();
    shortCode = List.generate(6, (_) => rng.nextInt(10)).join();
    _shortCodeUntil = DateTime.now().add(shortCodeTtl);
    _shortCodeMisses = 0;
    _shortCodeTimer?.cancel();
    // Panel still open when it expires: show a fresh one, not a dead number.
    _shortCodeTimer = Timer(shortCodeTtl, () {
      if (panel != ReceiverPanel.qr) return;
      _newShortCode();
      notifyListeners();
    });
  }

  void _clearShortCode() {
    _shortCodeTimer?.cancel();
    shortCode = null;
    _shortCodeUntil = null;
  }

  /// One use: a match rotates the code. Too many misses rotate it too, so it
  /// cannot be guessed from the LAN either.
  bool redeemShortCode(String code) {
    final current = shortCode;
    if (current == null) return false;
    final ok = code == current && DateTime.now().isBefore(_shortCodeUntil!);
    if (ok || ++_shortCodeMisses >= _shortCodeMaxMisses) {
      _newShortCode();
      notifyListeners();
    }
    return ok;
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

  /// "Pa pistear 3am · 3 de 57" mientras hay una cola activa.
  String? queueInfo;

  void setQueue(String? info) {
    if (info == queueInfo) return;
    queueInfo = info;
    notifyListeners();
  }

  // Spotify del propio proyector (ver spotify_follow.dart).
  /// Lo conecta main.dart a SpotifyFollower.setFollowing (botón en la pantalla del QR).
  Future<void> Function(bool on)? toggleFollowing;
  bool spotifyLinked = false;
  bool spotifyFollowing = false;
  Track? nowPlaying;

  /// Solo notifica si algo visible cambió (se llama cada 5 s).
  void setSpotify({
    bool? linked,
    bool? following,
    Track? nowPlaying,
    bool clearNowPlaying = false,
  }) {
    String snap() =>
        '$spotifyLinked|$spotifyFollowing|${this.nowPlaying}|${this.nowPlaying?.isPlaying}';
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
