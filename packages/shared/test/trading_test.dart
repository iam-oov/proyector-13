import 'package:flutter_test/flutter_test.dart';
import 'package:shared/shared.dart';

void main() {
  final today = DateTime(2026, 10, 20, 15);
  final yesterday = DateTime(2026, 10, 19, 10);

  final trades = [
    // Larga de ayer: hoy se mide contra el cierre anterior.
    Trade(id: 'a', symbol: 'AAPL', side: TradeSide.long, qty: 10, entryPrice: 100, openedAt: yesterday),
    // Otra compra hoy del mismo símbolo: se mide contra su entrada.
    Trade(id: 'b', symbol: 'AAPL', side: TradeSide.long, qty: 5, entryPrice: 110, openedAt: today),
    // Corta abierta.
    Trade(id: 'c', symbol: 'TSLA', side: TradeSide.short, qty: 2, entryPrice: 300, openedAt: yesterday),
    // Cerrada hoy con ganancia.
    Trade(id: 'd', symbol: 'SPY', side: TradeSide.long, qty: 1, entryPrice: 500, openedAt: yesterday,
        exitPrice: 520, closedAt: today),
    // Cerrada ayer con pérdida.
    Trade(id: 'e', symbol: 'NVDA', side: TradeSide.long, qty: 1, entryPrice: 200, openedAt: yesterday,
        exitPrice: 190, closedAt: yesterday),
  ];
  final quotes = {
    'AAPL': Quote(symbol: 'AAPL', price: 120, previousClose: 115, currency: 'USD', marketState: 'REGULAR', updatedAt: today),
    'TSLA': Quote(symbol: 'TSLA', price: 290, previousClose: 295, currency: 'USD', marketState: 'REGULAR', updatedAt: today),
  };

  test('posiciones agregadas por símbolo y lado', () {
    final s = PortfolioStats.compute(trades, quotes, now: today);
    expect(s.positions.map((p) => p.symbol), ['AAPL', 'TSLA']);
    final aapl = s.positions.first;
    expect(aapl.qty, 15);
    expect(aapl.avgEntry, closeTo((100 * 10 + 110 * 5) / 15, 1e-9));
    expect(aapl.unrealized, (120 - 100) * 10 + (120 - 110) * 5); // 250
  });

  test('P&L no realizado, del día, realizado hoy y total', () {
    final s = PortfolioStats.compute(trades, quotes, now: today);
    // TSLA corta: (290-300)*2*-1 = +20
    expect(s.unrealizedPnl, 250 + 20);
    // Día: AAPL ayer (120-115)*10=50, AAPL hoy (120-110)*5=50, TSLA (290-295)*2*-1=+10
    expect(s.dayPnl, 110);
    expect(s.realizedToday, 20);
    expect(s.realizedTotal, 20 - 10);
    expect(s.totalPnl, 270 + 10);
    expect(s.dayTotal, 110 + 20);
    expect(s.closedTrades.first.id, 'd'); // la más reciente primero
  });

  test('sin precio de alguna posición, los totales quedan en null', () {
    final s = PortfolioStats.compute(trades, {'AAPL': quotes['AAPL']!}, now: today);
    expect(s.unrealizedPnl, isNull);
    expect(s.dayPnl, isNull);
    expect(s.realizedTotal, 10);
  });

  group('horario del mercado de EE. UU.', () {
    // Martes 21 oct 2026: NY en horario de verano (UTC−4).
    test('abierto a las 10:00 NY, cerrado a las 16:30 NY y en fin de semana', () {
      expect(UsMarketHours.isOpen(DateTime.utc(2026, 10, 21, 14)), isTrue); // 10:00 NY
      expect(UsMarketHours.isOpen(DateTime.utc(2026, 10, 21, 13, 29)), isFalse); // 9:29 NY
      expect(UsMarketHours.isOpen(DateTime.utc(2026, 10, 21, 20, 30)), isFalse); // 16:30 NY
      expect(UsMarketHours.isOpen(DateTime.utc(2026, 10, 24, 15)), isFalse); // sábado
    });

    test('cerrado: el siguiente refresh es 1 min después de la apertura', () {
      // Martes 21:00 NY → miércoles 9:31 NY = 13:31 UTC.
      final next = UsMarketHours.nextRefresh(DateTime.utc(2026, 10, 22, 1));
      expect(next.toUtc(), DateTime.utc(2026, 10, 22, 13, 31));
      // Viernes 17:00 NY → lunes 9:31 NY.
      final weekend = UsMarketHours.nextRefresh(DateTime.utc(2026, 10, 23, 21));
      expect(weekend.toUtc(), DateTime.utc(2026, 10, 26, 13, 31));
    });

    test('cambio de horario: en diciembre NY es UTC−5', () {
      expect(UsMarketHours.isOpen(DateTime.utc(2026, 12, 1, 14, 31)), isTrue); // 9:31 NY
      expect(UsMarketHours.isOpen(DateTime.utc(2026, 12, 1, 14, 29)), isFalse); // 9:29 NY
      // El viernes 30 oct cierra con horario de verano; el lunes 2 nov abre ya en UTC−5.
      expect(UsMarketHours.nextRefresh(DateTime.utc(2026, 10, 30, 21)).toUtc(), DateTime.utc(2026, 11, 2, 14, 31));
    });

    test('abierto: cada minuto, o cada 30 si Yahoo dice CLOSED (feriado)', () {
      final now = DateTime.utc(2026, 10, 21, 15);
      expect(UsMarketHours.nextRefresh(now), now.add(const Duration(minutes: 1)));
      expect(UsMarketHours.nextRefresh(now, lastMarketState: 'CLOSED'), now.add(const Duration(minutes: 30)));
    });

    test('countdownText', () {
      expect(countdownText(const Duration(seconds: 42)), '0:42');
      expect(countdownText(const Duration(hours: 3, minutes: 5, seconds: 10)), '3:05:10');
      expect(countdownText(const Duration(days: 2, hours: 4)), '2 d 4 h');
    });
  });

  test('cerrar un trade y JSON ida y vuelta', () {
    final closed = trades.first.close(exitPrice: 130, at: today);
    expect(closed.isOpen, isFalse);
    expect(closed.realizedPnl, 300);
    final back = Trade.listFromJson(Trade.listToJson([closed, trades[2]]));
    expect(back.length, 2);
    expect(back.first.exitPrice, 130);
    expect(back[1].side, TradeSide.short);
    expect(back[1].exitPrice, isNull);
    final q = Quote.fromJson(quotes['AAPL']!.toJson());
    expect(q.previousClose, 115);
  });

  test('las estadísticas en JSON traen lo mismo que el tablero (para el teléfono)', () {
    final withClosed = [trades.first.close(exitPrice: 130, at: today), ...trades.skip(1)];
    final stats = PortfolioStats.compute(withClosed, quotes, now: today);
    final j = stats.toJson();
    // a cerrada hoy (+300) más las del ejemplo: d (+20) y e (−10).
    expect(j['realizedTotal'], 310);
    expect(j['unrealizedPnl'], stats.unrealizedPnl);
    expect(j['dayTotal'], stats.dayTotal);
    final closed = {for (final t in j['closed'] as List) t['id']: t['realizedPnl']};
    expect(closed, {'a': 300, 'd': 20, 'e': -10});
    final first = (j['positions'] as List).first as Map<String, dynamic>;
    final p = stats.positions.first;
    expect(first['symbol'], p.symbol);
    expect(first['qty'], p.qty);
    expect(first['unrealized'], p.unrealized);
    expect(first['tradeIds'], [for (final t in p.trades) t.id]);
  });
}
