import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'state.dart';

/// Estadísticas de trading para el inicio: P&L del día y abierto, realizado,
/// y las posiciones con el precio de Yahoo. Se actualiza cada minuto.
class TradingStats extends StatelessWidget {
  const TradingStats({super.key, required this.state});

  final ReceiverState state;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final s = state.stats;
    final small = text.bodyMedium?.copyWith(color: Colors.white54);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C2226),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text('Trading', style: text.titleMedium),
              const Spacer(),
              if (state.quotesLoading)
                Text('Actualizando…', style: small)
              else if (state.nextQuotesAt != null)
                _Countdown(until: state.nextQuotesAt!, style: small),
            ],
          ),
          const SizedBox(height: 10),
          Text('P&L del día', style: small),
          Text(
            money(s.dayTotal),
            style: text.displaySmall?.copyWith(color: pnlColor(s.dayTotal)),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _MiniStat('Abierto', s.unrealizedPnl),
              _MiniStat('Realizado hoy', s.realizedToday),
              _MiniStat('Total', s.totalPnl),
            ],
          ),
          if (s.positions.isNotEmpty) ...[
            const Divider(height: 24),
            for (final p in s.positions.take(5))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 56,
                      child: Text(p.symbol, style: text.titleSmall),
                    ),
                    Expanded(
                      child: Text(
                        p.quote == null
                            ? '—'
                            : money(p.quote!.price, sign: false),
                        style: text.bodyMedium?.copyWith(color: Colors.white70),
                      ),
                    ),
                    Text(
                      money(p.unrealized),
                      style: text.bodyMedium?.copyWith(
                        color: pnlColor(p.unrealized),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 60,
                      child: Text(
                        pct(p.unrealizedPct),
                        textAlign: TextAlign.right,
                        style: text.bodySmall?.copyWith(
                          color: pnlColor(p.unrealizedPct),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 6),
          Text(
            _footer(state),
            style: text.bodySmall?.copyWith(color: Colors.white38),
          ),
        ],
      ),
    );
  }

  static String _footer(ReceiverState state) {
    if (state.quotesError != null) return state.quotesError!;
    final at = state.quotesAt;
    if (at == null) return 'Precios de Yahoo Finance';
    final open = state.quotes.values.any((q) => q.isMarketOpen);
    return '${open ? 'Mercado abierto' : 'Mercado cerrado'} · Yahoo ${_hhmm(at)}';
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat(this.label, this.value);

  final String label;
  final double? value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: text.bodySmall?.copyWith(color: Colors.white54)),
          Text(
            money(value),
            style: text.titleSmall?.copyWith(color: pnlColor(value)),
          ),
        ],
      ),
    );
  }
}

/// "⟳ 0:42" hasta la siguiente consulta a Yahoo; se redibuja cada segundo.
class _Countdown extends StatefulWidget {
  const _Countdown({required this.until, this.style});

  final DateTime until;
  final TextStyle? style;

  @override
  State<_Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<_Countdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      '⟳ ${countdownText(widget.until.difference(DateTime.now()))}',
      style: widget.style,
    );
  }
}

Color? pnlColor(double? v) {
  if (v == null || v == 0) return null;
  return v > 0 ? const Color(0xFF4CD964) : const Color(0xFFFF5A5F);
}

String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
