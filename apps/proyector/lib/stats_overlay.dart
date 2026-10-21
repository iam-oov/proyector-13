import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared/shared.dart';

import 'state.dart';

const _channel = MethodChannel('proyector/launch');

/// Tarjeta de trading flotando encima de YouTube (el video sigue en grande).
/// Se actualiza sola con cada precio nuevo y se esconde después de [autoHide].
class StatsOverlayController {
  StatsOverlayController(this.state);

  final ReceiverState state;
  static const autoHide = Duration(seconds: 45);
  bool visible = false;
  Timer? _hideTimer;

  Future<void> show() async {
    visible = true;
    state.addListener(_update);
    await _push();
    _hideTimer?.cancel();
    _hideTimer = Timer(autoHide, hide);
  }

  Future<void> hide() async {
    _hideTimer?.cancel();
    state.removeListener(_update);
    if (!visible) return;
    visible = false;
    await _channel.invokeMethod<bool>('hideStats');
  }

  void _update() {
    if (visible) unawaited(_push());
  }

  Future<void> _push() async {
    final s = state.stats;
    int c(double? v) => v == null || v == 0 ? 0xFFFFFFFF : (v > 0 ? 0xFF4CD964 : 0xFFFF5A5F);
    final at = state.quotesAt;
    final open = state.quotes.values.any((q) => q.isMarketOpen);
    await _channel.invokeMethod<bool>('showStats', {
      'nextAt': state.nextQuotesAt?.millisecondsSinceEpoch ?? 0,
      'day': money(s.dayTotal),
      'dayColor': c(s.dayTotal),
      'minis': [
        {'label': 'Abierto', 'value': money(s.unrealizedPnl), 'color': c(s.unrealizedPnl)},
        {'label': 'Realizado hoy', 'value': money(s.realizedToday), 'color': c(s.realizedToday)},
        {'label': 'Total', 'value': money(s.totalPnl), 'color': c(s.totalPnl)},
      ],
      'rows': [
        for (final p in s.positions.take(6))
          {
            'symbol': p.symbol,
            'price': p.quote == null ? '—' : money(p.quote!.price, sign: false),
            'pnl': money(p.unrealized),
            'pct': pct(p.unrealizedPct),
            'color': c(p.unrealized),
          },
      ],
      'footer': at == null
          ? 'Precios de Yahoo Finance'
          : '${open ? 'Mercado abierto' : 'Mercado cerrado'} · Yahoo '
              '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}',
    });
  }
}
