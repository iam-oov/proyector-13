import 'dart:convert';

import 'package:http/http.dart' as http;

/// Bitácora de trading: movimientos (trades) registrados a mano en el
/// teléfono, precios de Yahoo Finance y las estadísticas que ve el proyector.
/// Acciones/ETFs de EE. UU. en USD.

enum TradeSide { long, short }

class Trade {
  const Trade({
    required this.id,
    required this.symbol,
    required this.side,
    required this.qty,
    required this.entryPrice,
    required this.openedAt,
    this.exitPrice,
    this.closedAt,
    this.notes,
  });

  final String id;
  final String symbol;
  final TradeSide side;
  final double qty;
  final double entryPrice;
  final DateTime openedAt;
  final double? exitPrice;
  final DateTime? closedAt;
  final String? notes;

  bool get isOpen => closedAt == null;

  /// +1 en largo, −1 en corto: multiplica la diferencia de precio.
  int get sign => side == TradeSide.long ? 1 : -1;

  double get realizedPnl => isOpen ? 0 : (exitPrice! - entryPrice) * qty * sign;

  double unrealizedPnl(double price) => (price - entryPrice) * qty * sign;

  Trade close({required double exitPrice, DateTime? at}) =>
      copyWith(exitPrice: exitPrice, closedAt: at ?? DateTime.now());

  Trade copyWith({
    String? symbol,
    TradeSide? side,
    double? qty,
    double? entryPrice,
    DateTime? openedAt,
    double? exitPrice,
    DateTime? closedAt,
    String? notes,
  }) =>
      Trade(
        id: id,
        symbol: symbol ?? this.symbol,
        side: side ?? this.side,
        qty: qty ?? this.qty,
        entryPrice: entryPrice ?? this.entryPrice,
        openedAt: openedAt ?? this.openedAt,
        exitPrice: exitPrice ?? this.exitPrice,
        closedAt: closedAt ?? this.closedAt,
        notes: notes ?? this.notes,
      );

  factory Trade.fromJson(Map<String, dynamic> j) => Trade(
        id: j['id'] as String,
        symbol: j['symbol'] as String,
        side: j['side'] == 'short' ? TradeSide.short : TradeSide.long,
        qty: (j['qty'] as num).toDouble(),
        entryPrice: (j['entryPrice'] as num).toDouble(),
        openedAt: DateTime.parse(j['openedAt'] as String),
        exitPrice: (j['exitPrice'] as num?)?.toDouble(),
        closedAt: j['closedAt'] == null ? null : DateTime.parse(j['closedAt'] as String),
        notes: j['notes'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'symbol': symbol,
        'side': side.name,
        'qty': qty,
        'entryPrice': entryPrice,
        'openedAt': openedAt.toIso8601String(),
        'exitPrice': ?exitPrice,
        'closedAt': ?closedAt?.toIso8601String(),
        'notes': ?notes,
      };

  static List<Trade> listFromJson(String raw) =>
      [for (final j in jsonDecode(raw) as List) Trade.fromJson(j as Map<String, dynamic>)];

  static String listToJson(List<Trade> trades) => jsonEncode([for (final t in trades) t.toJson()]);
}

class Quote {
  const Quote({
    required this.symbol,
    required this.price,
    required this.previousClose,
    required this.currency,
    required this.marketState,
    required this.updatedAt,
  });

  final String symbol;
  final double price;
  final double? previousClose;
  final String currency;

  /// REGULAR, PRE, POST, CLOSED… tal como lo da Yahoo.
  final String marketState;
  final DateTime updatedAt;

  bool get isMarketOpen => marketState == 'REGULAR';

  factory Quote.fromJson(Map<String, dynamic> j) => Quote(
        symbol: j['symbol'] as String,
        price: (j['price'] as num).toDouble(),
        previousClose: (j['previousClose'] as num?)?.toDouble(),
        currency: j['currency'] as String? ?? 'USD',
        marketState: j['marketState'] as String? ?? '',
        updatedAt: DateTime.parse(j['updatedAt'] as String),
      );

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'price': price,
        'previousClose': ?previousClose,
        'currency': currency,
        'marketState': marketState,
        'updatedAt': updatedAt.toIso8601String(),
      };
}

/// Posición abierta agregada por símbolo y lado.
class Position {
  const Position({required this.symbol, required this.side, required this.trades, this.quote});

  final String symbol;
  final TradeSide side;
  final List<Trade> trades;
  final Quote? quote;

  double get qty => trades.fold(0.0, (s, t) => s + t.qty);

  double get avgEntry => qty == 0 ? 0 : trades.fold(0.0, (s, t) => s + t.entryPrice * t.qty) / qty;

  double get cost => avgEntry * qty;

  /// Ganancia/pérdida no realizada al precio actual (null sin precio).
  double? get unrealized {
    final q = quote;
    if (q == null) return null;
    return trades.fold<double>(0.0, (s, t) => s + t.unrealizedPnl(q.price));
  }

  /// Cuánto se movió hoy: contra el cierre anterior, o contra la entrada si
  /// la posición se abrió hoy.
  double? dayPnl(DateTime now) {
    final q = quote;
    if (q == null) return null;
    return trades.fold<double>(0.0, (s, t) {
      final base = _sameDay(t.openedAt, now) || q.previousClose == null ? t.entryPrice : q.previousClose!;
      return s + (q.price - base) * t.qty * t.sign;
    });
  }

  double? get unrealizedPct {
    final u = unrealized;
    return u == null || cost == 0 ? null : u / cost * 100;
  }
}

/// Todo lo que muestra el tablero del proyector.
class PortfolioStats {
  const PortfolioStats({
    required this.positions,
    required this.unrealizedPnl,
    required this.dayPnl,
    required this.realizedToday,
    required this.realizedTotal,
    required this.closedTrades,
    required this.computedAt,
  });

  final List<Position> positions;

  /// Null si falta el precio de alguna posición.
  final double? unrealizedPnl;
  final double? dayPnl;
  final double realizedToday;
  final double realizedTotal;
  final List<Trade> closedTrades;
  final DateTime computedAt;

  double? get totalPnl => unrealizedPnl == null ? null : unrealizedPnl! + realizedTotal;

  /// P&L del día = movimiento de hoy de las abiertas + lo realizado hoy.
  double? get dayTotal => dayPnl == null ? null : dayPnl! + realizedToday;

  static PortfolioStats compute(List<Trade> trades, Map<String, Quote> quotes, {DateTime? now}) {
    final today = now ?? DateTime.now();
    final open = trades.where((t) => t.isOpen).toList();
    final closed = trades.where((t) => !t.isOpen).toList()..sort((a, b) => b.closedAt!.compareTo(a.closedAt!));

    final groups = <String, List<Trade>>{};
    for (final t in open) {
      (groups['${t.symbol}|${t.side.name}'] ??= []).add(t);
    }
    final positions = [
      for (final g in groups.values)
        Position(symbol: g.first.symbol, side: g.first.side, trades: g, quote: quotes[g.first.symbol]),
    ]..sort((a, b) => a.symbol.compareTo(b.symbol));

    double? unrealized = 0;
    double? day = 0;
    for (final p in positions) {
      final u = p.unrealized;
      final d = p.dayPnl(today);
      unrealized = unrealized == null || u == null ? null : unrealized + u;
      day = day == null || d == null ? null : day + d;
    }

    return PortfolioStats(
      positions: positions,
      unrealizedPnl: unrealized,
      dayPnl: day,
      realizedToday: closed.where((t) => _sameDay(t.closedAt!, today)).fold(0.0, (s, t) => s + t.realizedPnl),
      realizedTotal: closed.fold(0.0, (s, t) => s + t.realizedPnl),
      closedTrades: closed,
      computedAt: today,
    );
  }
}

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// "+$1,234.56" / "−$12.00" / "—" si no hay dato. Con [sign] false no pone el +.
String money(double? v, {bool sign = true}) {
  if (v == null) return '—';
  final abs = v.abs();
  final whole = abs.floor();
  final cents = ((abs - whole) * 100).round();
  final (w, c) = cents == 100 ? (whole + 1, 0) : (whole, cents);
  final digits = w.toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  final prefix = !sign ? (v < 0 ? '−' : '') : (v > 0 ? '+' : (v < 0 ? '−' : ''));
  return '$prefix\$$buf.${c.toString().padLeft(2, '0')}';
}

String pct(double? v) => v == null ? '—' : '${v > 0 ? '+' : (v < 0 ? '−' : '')}${v.abs().toStringAsFixed(2)}%';

/// Cantidad de acciones: entera sin decimales; fraccionaria con hasta 4
/// decimales (quien compra por monto tiene fracciones como 0.4348).
String qtyText(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  var s = v.toStringAsFixed(4);
  while (s.endsWith('0')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// Precios de Yahoo Finance (endpoint público de gráficas, sin API key).
class YahooFinance {
  YahooFinance({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<Quote?> quote(String symbol) async {
    final uri = Uri.https('query1.finance.yahoo.com', '/v8/finance/chart/$symbol', {
      'range': '1d',
      'interval': '5m',
      'includePrePost': 'false',
    });
    try {
      final r = await _client
          .get(uri, headers: {'user-agent': 'Mozilla/5.0 (Proyector; Flutter)'})
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return null;
      final result = (jsonDecode(r.body)['chart']['result'] as List?)?.firstOrNull;
      if (result == null) return null;
      final meta = result['meta'] as Map<String, dynamic>;
      final price = meta['regularMarketPrice'] as num?;
      if (price == null) return null;
      return Quote(
        symbol: symbol,
        price: price.toDouble(),
        previousClose: ((meta['chartPreviousClose'] ?? meta['previousClose']) as num?)?.toDouble(),
        currency: meta['currency'] as String? ?? 'USD',
        marketState: meta['marketState']?.toString() ?? '',
        updatedAt: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Un request por símbolo, en paralelo. Los que fallan simplemente faltan.
  Future<Map<String, Quote>> quotes(Iterable<String> symbols) async {
    final results = await Future.wait(symbols.toSet().map(quote));
    return {for (final q in results) if (q != null) q.symbol: q};
  }
}
