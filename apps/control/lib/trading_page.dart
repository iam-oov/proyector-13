import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'app_theme.dart';
import 'model.dart';

/// Pestaña Trading (2e): bitácora, posiciones y mandar el tablero al proyector.
class TradingPage extends StatefulWidget {
  const TradingPage({super.key, required this.model});

  final ControlModel model;

  @override
  State<TradingPage> createState() => _TradingPageState();
}

class _TradingPageState extends State<TradingPage> {
  @override
  void initState() {
    super.initState();
    widget.model.startQuotePolling();
  }

  @override
  void dispose() {
    widget.model.stopQuotePolling();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final s = model.tradingStats;
        final screen = model.selectedScreen;
        final isTv = !(screen?.hasReceiver ?? true);
        final canShow = !model.busy && model.projectorOnline && !isTv;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              // Como las demás pestañas: arriba la pantalla elegida, sin título propio.
              child: ListView(
                padding: const EdgeInsets.only(top: 12, bottom: 16),
                children: [
                  ScreenRow(model: model),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                      _StatsHeader(
                        stats: s,
                        quotesAt: model.quotesAt,
                        nextAt: model.nextQuotesAt,
                        loading: model.quotesLoading,
                        onRefresh: model.quotesLoading ? null : model.refreshQuotes,
                      ),
                      const SizedBox(height: 12),
                      // Si el proyector está en el inicio, lo trae al frente; si está con un
                      // video, la tarjeta flota encima sin interrumpirlo.
                      SizedBox(
                        height: 52,
                        child: model.tradingOverlay
                            ? OutlinedButton.icon(
                                onPressed: model.busy ? null : model.hideTradingOverlay,
                                icon: const Icon(Icons.fullscreen_rounded),
                                label: const Text('Quitar del video'),
                              )
                            : FilledButton.icon(
                                onPressed: canShow ? () => model.showTradingOnProjector(true) : null,
                                icon: const Icon(Icons.cast_rounded),
                                label: Text('Mostrar en ${screen?.name ?? 'el proyector'}',
                                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                                style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                              ),
                      ),
                      if (!canShow && !model.tradingOverlay && screen != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            isTv
                                ? '${screen.name} es una TV sin receptor: el tablero solo va en los proyectores.'
                                : '${screen.name} no responde.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 13, color: Palette.text3),
                          ),
                        ),
                      if (model.error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Notice(model.error!, error: true)),
                      const SizedBox(height: 20),
                      const SectionLabel('Posiciones abiertas'),
                      const SizedBox(height: 10),
                      if (s.positions.isEmpty)
                        const Text('Ninguna. Registra tu primer movimiento.', style: TextStyle(color: Palette.text3)),
                      for (final p in s.positions) ...[
                        _PositionTile(position: p, onClose: () => _closePosition(context, p)),
                        const SizedBox(height: 8),
                      ],
                      if (s.closedTrades.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        const SectionLabel('Cerrados'),
                        for (final t in s.closedTrades)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text('${t.symbol} · ${t.side == TradeSide.long ? 'Largo' : 'Corto'} · ${qtyText(t.qty)} acc.'),
                            subtitle: Text('${money(t.entryPrice, sign: false)} → ${money(t.exitPrice, sign: false)} · ${_date(t.closedAt!)}',
                                style: const TextStyle(color: Palette.text2)),
                            trailing: Text(money(t.realizedPnl),
                                style: TextStyle(color: _pnlColor(t.realizedPnl), fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()])),
                            onLongPress: () => _confirmDelete(context, t),
                          ),
                      ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: () => _newTrade(context),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Registrar movimiento', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _newTrade(BuildContext context) async {
    final trade = await showDialog<Trade>(context: context, builder: (_) => const _TradeDialog());
    if (trade != null) await widget.model.addTrade(trade);
  }

  /// Cierra todos los trades de la posición al mismo precio de salida.
  Future<void> _closePosition(BuildContext context, Position p) async {
    final result = await showDialog<({double price, DateTime at})>(
      context: context,
      builder: (_) => _CloseDialog(position: p),
    );
    if (result == null) return;
    for (final t in p.trades) {
      await widget.model.closeTrade(t.id, exitPrice: result.price, at: result.at);
    }
  }

  Future<void> _confirmDelete(BuildContext context, Trade t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Borrar este movimiento?'),
        content: Text('${t.symbol} ${money(t.entryPrice, sign: false)} → ${money(t.exitPrice, sign: false)}'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Borrar')),
        ],
      ),
    );
    if (ok == true) await widget.model.deleteTrade(t.id);
  }
}

class _StatsHeader extends StatelessWidget {
  const _StatsHeader({required this.stats, required this.quotesAt, required this.nextAt, required this.loading, this.onRefresh});

  final PortfolioStats stats;
  final DateTime? quotesAt;
  final DateTime? nextAt;
  final bool loading;

  /// Pide los precios ya (antes era el botón junto al título de la pestaña).
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    const tab = [FontFeature.tabularFigures()];
    Widget stat(String label, double? v) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 13, color: Palette.text2)),
              Text(money(v), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _pnlColor(v) ?? Palette.text, fontFeatures: tab)),
            ],
          ),
        );
    return Tile(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('P&L del día'),
          Text(money(stats.dayTotal),
              style: TextStyle(fontSize: 44, fontWeight: FontWeight.w700, height: 1.15, color: _pnlColor(stats.dayTotal) ?? Palette.text, fontFeatures: tab)),
          const SizedBox(height: 12),
          Row(children: [stat('Abierto', stats.unrealizedPnl), stat('Realizado hoy', stats.realizedToday), stat('Realizado total', stats.realizedTotal)]),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  loading
                      ? 'Actualizando precios…'
                      : quotesAt == null
                          ? 'Sin precios todavía'
                          : 'Yahoo Finance · ${_hhmm(quotesAt!)}',
                  style: const TextStyle(fontSize: 12, color: Palette.text3),
                ),
              ),
              if (!loading && nextAt != null)
                CountdownText(until: nextAt!, prefix: 'siguiente en ', style: const TextStyle(fontSize: 12, color: Palette.text3)),
              IconButton(
                tooltip: 'Actualizar precios',
                visualDensity: VisualDensity.compact,
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh_rounded, size: 20, color: Palette.text2),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PositionTile extends StatelessWidget {
  const _PositionTile({required this.position, required this.onClose});

  final Position position;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    const tab = [FontFeature.tabularFigures()];
    final p = position;
    final q = p.quote;
    final day = p.dayPnl(DateTime.now());
    return Tile(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      onTap: onClose,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(TextSpan(children: [
                  TextSpan(text: p.symbol, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                  TextSpan(
                    text: '  ${p.side == TradeSide.long ? 'Largo' : 'Corto'} · ${qtyText(p.qty)} acc.',
                    style: const TextStyle(fontSize: 13, color: Palette.text2),
                  ),
                ])),
                const SizedBox(height: 4),
                // Todo como "Título: $N"; la compra es la del primer movimiento.
                Text(
                  'Compra: ${_date(p.trades.map((t) => t.openedAt).reduce((a, b) => a.isBefore(b) ? a : b))}'
                  ' · Entrada: ${money(p.avgEntry, sign: false)}\n'
                  'Ahora: ${q == null ? 'sin precio' : money(q.price, sign: false)}'
                  '${day == null ? '' : ' · Hoy: ${money(day)}'}',
                  style: const TextStyle(fontSize: 13, height: 1.35, color: Palette.text2, fontFeatures: tab),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(money(p.unrealized), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _pnlColor(p.unrealized), fontFeatures: tab)),
              Text(pct(p.unrealizedPct), style: TextStyle(fontSize: 13, color: _pnlColor(p.unrealizedPct), fontFeatures: tab)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Formulario de un movimiento nuevo.
class _TradeDialog extends StatefulWidget {
  const _TradeDialog();

  @override
  State<_TradeDialog> createState() => _TradeDialogState();
}

class _TradeDialogState extends State<_TradeDialog> {
  final _symbol = TextEditingController();
  final _qty = TextEditingController();
  final _amount = TextEditingController();
  final _price = TextEditingController();
  TradeSide _side = TradeSide.long;

  /// Comprar por monto ("$50 de INTC") es lo habitual: la cantidad se calcula.
  bool _byAmount = true;
  DateTime _at = DateTime.now();
  String? _error;

  @override
  void dispose() {
    _symbol.dispose();
    _qty.dispose();
    _amount.dispose();
    _price.dispose();
    super.dispose();
  }

  double? get _parsedPrice => double.tryParse(_price.text.replaceAll(',', '.'));

  /// Cantidad resultante: capturada, o monto ÷ precio.
  double? get _computedQty {
    if (!_byAmount) return double.tryParse(_qty.text.replaceAll(',', '.'));
    final amount = double.tryParse(_amount.text.replaceAll(',', '.'));
    final price = _parsedPrice;
    if (amount == null || price == null || price <= 0) return null;
    return amount / price;
  }

  void _submit() {
    final symbol = _symbol.text.trim().toUpperCase();
    final qty = _computedQty;
    final price = _parsedPrice;
    if (symbol.isEmpty || qty == null || qty <= 0 || price == null || price <= 0) {
      setState(() => _error = _byAmount ? 'Revisa símbolo, monto y precio' : 'Revisa símbolo, cantidad y precio');
      return;
    }
    Navigator.of(context).pop(Trade(
      id: randomScreenId(),
      symbol: symbol,
      side: _side,
      qty: qty,
      entryPrice: price,
      openedAt: _at,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Registrar movimiento'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _symbol,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Símbolo', hintText: 'AAPL'),
            ),
            const SizedBox(height: 12),
            SegmentedButton<TradeSide>(
              segments: const [
                ButtonSegment(value: TradeSide.long, label: Text('Largo (compra)')),
                ButtonSegment(value: TradeSide.short, label: Text('Corto (venta)')),
              ],
              selected: {_side},
              onSelectionChanged: (s) => setState(() => _side = s.first),
            ),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Por monto (USD)')),
                ButtonSegment(value: false, label: Text('Por acciones')),
              ],
              selected: {_byAmount},
              onSelectionChanged: (s) => setState(() => _byAmount = s.first),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _byAmount ? _amount : _qty,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: _byAmount ? 'Monto (USD)' : 'Cantidad',
                      hintText: _byAmount ? '50' : '1.5',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _price,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Precio (USD)', hintText: '115'),
                  ),
                ),
              ],
            ),
            if (_byAmount && _computedQty != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('= ${qtyText(_computedQty!)} acciones',
                      style: const TextStyle(color: Colors.white70)),
                ),
              ),
            const SizedBox(height: 8),
            _DateRow(value: _at, onChanged: (d) => setState(() => _at = d)),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(onPressed: _submit, child: const Text('Guardar')),
      ],
    );
  }
}

class _CloseDialog extends StatefulWidget {
  const _CloseDialog({required this.position});

  final Position position;

  @override
  State<_CloseDialog> createState() => _CloseDialogState();
}

class _CloseDialogState extends State<_CloseDialog> {
  late final _price = TextEditingController(text: widget.position.quote?.price.toStringAsFixed(2) ?? '');
  DateTime _at = DateTime.now();
  String? _error;

  @override
  void dispose() {
    _price.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.position;
    return AlertDialog(
      title: Text('Cerrar ${p.symbol}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${p.side == TradeSide.long ? 'Largo' : 'Corto'} · ${qtyText(p.qty)} acc. · entrada ${money(p.avgEntry, sign: false)} · invertido ${money(p.cost, sign: false)}'),
          const SizedBox(height: 12),
          TextField(
            controller: _price,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Precio de salida (USD)'),
          ),
          const SizedBox(height: 8),
          _DateRow(value: _at, onChanged: (d) => setState(() => _at = d)),
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(
          onPressed: () {
            final price = double.tryParse(_price.text.replaceAll(',', '.'));
            if (price == null || price <= 0) {
              setState(() => _error = 'Precio inválido');
              return;
            }
            Navigator.of(context).pop((price: price, at: _at));
          },
          child: const Text('Cerrar posición'),
        ),
      ],
    );
  }
}

class _DateRow extends StatelessWidget {
  const _DateRow({required this.value, required this.onChanged});

  final DateTime value;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.event, size: 18, color: Colors.white54),
        const SizedBox(width: 8),
        Text(_date(value)),
        const Spacer(),
        TextButton(
          onPressed: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: value,
              firstDate: DateTime(2015),
              lastDate: DateTime.now().add(const Duration(days: 1)),
            );
            if (d != null) onChanged(DateTime(d.year, d.month, d.day, value.hour, value.minute));
          },
          child: const Text('Cambiar fecha'),
        ),
      ],
    );
  }
}

/// "siguiente en 0:42": se redibuja cada segundo hasta [until].
class CountdownText extends StatefulWidget {
  const CountdownText({super.key, required this.until, this.prefix = '', this.style});

  final DateTime until;
  final String prefix;
  final TextStyle? style;

  @override
  State<CountdownText> createState() => _CountdownTextState();
}

class _CountdownTextState extends State<CountdownText> {
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
    return Text('${widget.prefix}${countdownText(widget.until.difference(DateTime.now()))}', style: widget.style);
  }
}

Color? _pnlColor(double? v) {
  if (v == null || v == 0) return null;
  return v > 0 ? Palette.live : Palette.danger;
}

String _date(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
