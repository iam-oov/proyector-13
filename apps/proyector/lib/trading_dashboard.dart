import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'state.dart';

/// Tablero de trading para la TV: P&L del día, abierto y realizado, y las
/// posiciones con precio de Yahoo. Atrás en el control vuelve al QR.
class TradingDashboard extends StatelessWidget {
  const TradingDashboard({super.key, required this.state});

  final ReceiverState state;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (_, _) => state.showPanel(ReceiverPanel.home),
      child: Scaffold(
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 56, vertical: 40),
          child: ListenableBuilder(
            listenable: state,
            builder: (context, _) {
              final s = state.stats;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('Trading', style: text.headlineMedium),
                      const Spacer(),
                      Text(_footer(state), style: text.bodyMedium?.copyWith(color: Colors.white54)),
                      if (!state.quotesLoading && state.nextQuotesAt != null) ...[
                        const SizedBox(width: 16),
                        _Countdown(until: state.nextQuotesAt!, style: text.bodyMedium?.copyWith(color: Colors.white70)),
                      ],
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      _Stat('P&L del día', s.dayTotal, big: true),
                      _Stat('P&L abierto', s.unrealizedPnl),
                      _Stat('Realizado hoy', s.realizedToday),
                      _Stat('Realizado total', s.realizedTotal),
                    ],
                  ),
                  const SizedBox(height: 28),
                  if (s.positions.isEmpty)
                    Text('Sin posiciones abiertas', style: text.titleMedium?.copyWith(color: Colors.white54))
                  else
                    Expanded(child: _PositionsTable(positions: s.positions)),
                  if (state.quotesError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(state.quotesError!, style: text.bodyMedium?.copyWith(color: Colors.redAccent)),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  static String _footer(ReceiverState state) {
    final at = state.quotesAt;
    if (state.quotesLoading) return 'Actualizando precios de Yahoo…';
    if (at == null) return 'Pidiendo precios a Yahoo Finance…';
    final open = state.quotes.values.any((q) => q.isMarketOpen);
    return '${open ? 'Mercado abierto' : 'Mercado cerrado'} · precios de ${_hhmm(at)}';
  }
}

/// "Siguiente actualización 0:42": se redibuja cada segundo.
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
    var left = widget.until.difference(DateTime.now()).inSeconds;
    if (left < 0) left = 0;
    return Text('⟳ ${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}', style: widget.style);
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, {this.big = false});

  final String label;
  final double? value;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: text.titleSmall?.copyWith(color: Colors.white54)),
          const SizedBox(height: 4),
          Text(
            money(value),
            style: (big ? text.displayMedium : text.headlineMedium)?.copyWith(color: pnlColor(value)),
          ),
        ],
      ),
    );
  }
}

class _PositionsTable extends StatelessWidget {
  const _PositionsTable({required this.positions});

  final List<Position> positions;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final head = text.titleSmall?.copyWith(color: Colors.white54);
    final cell = text.titleMedium;
    const cols = {1: FlexColumnWidth(1.2), 2: FlexColumnWidth(0.8)};
    return SingleChildScrollView(
      child: Table(
        columnWidths: cols,
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(children: [
            for (final h in ['Símbolo', 'Lado', 'Acciones', 'Invertido', 'Entrada', 'Precio Yahoo', 'Hoy', 'P&L', '%'])
              Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(h, style: head)),
          ]),
          for (final p in positions)
            TableRow(children: [
              _cell(p.symbol, cell),
              _cell(p.side == TradeSide.long ? 'Largo' : 'Corto', cell),
              _cell(qtyText(p.qty), cell),
              _cell(money(p.cost, sign: false), cell),
              _cell(money(p.avgEntry, sign: false), cell),
              _cell(p.quote == null ? '—' : money(p.quote!.price, sign: false), cell),
              _cell(money(p.dayPnl(DateTime.now())), cell?.copyWith(color: pnlColor(p.dayPnl(DateTime.now())))),
              _cell(money(p.unrealized), cell?.copyWith(color: pnlColor(p.unrealized))),
              _cell(pct(p.unrealizedPct), cell?.copyWith(color: pnlColor(p.unrealizedPct))),
            ]),
        ],
      ),
    );
  }

  static Widget _cell(String s, TextStyle? style) =>
      Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(s, style: style));
}

Color? pnlColor(double? v) {
  if (v == null || v == 0) return null;
  return v > 0 ? const Color(0xFF4CD964) : const Color(0xFFFF5A5F);
}

String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
