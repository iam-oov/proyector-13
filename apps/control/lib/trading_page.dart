import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'model.dart';

/// Bitácora de trading: registrar movimientos, cerrar posiciones y mandar
/// el tablero al proyector.
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
        return Scaffold(
          appBar: AppBar(
            title: const Text('Trading'),
            actions: [
              IconButton(
                tooltip: 'Actualizar precios',
                onPressed: model.quotesLoading ? null : model.refreshQuotes,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _newTrade(context),
            icon: const Icon(Icons.add),
            label: const Text('Registrar movimiento'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              _StatsHeader(
                stats: s,
                quotesAt: model.quotesAt,
                nextAt: model.nextQuotesAt,
                loading: model.quotesLoading,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    // Las estadísticas viven en el inicio del proyector: esto lo trae al frente.
                    child: FilledButton.icon(
                      onPressed: model.busy || !model.projectorOnline
                          ? null
                          : () => model.showTradingOnProjector(true),
                      icon: const Icon(Icons.tv),
                      label: const Text('Ver en el proyector'),
                    ),
                  ),
                ],
              ),
              if (model.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(model.error!, style: const TextStyle(color: Colors.redAccent)),
                ),
              const SizedBox(height: 20),
              Text('Posiciones abiertas', style: Theme.of(context).textTheme.titleMedium),
              if (s.positions.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Ninguna. Registra tu primer movimiento.', style: TextStyle(color: Colors.white54)),
                ),
              for (final p in s.positions) _PositionTile(position: p, onClose: () => _closePosition(context, p)),
              if (s.closedTrades.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text('Cerrados', style: Theme.of(context).textTheme.titleMedium),
                for (final t in s.closedTrades)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${t.symbol} · ${t.side == TradeSide.long ? 'Largo' : 'Corto'} · ${qtyText(t.qty)} acc.'),
                    subtitle: Text('${money(t.entryPrice, sign: false)} → ${money(t.exitPrice, sign: false)} · ${_date(t.closedAt!)}'),
                    trailing: Text(money(t.realizedPnl),
                        style: TextStyle(color: _pnlColor(t.realizedPnl), fontWeight: FontWeight.w600)),
                    onLongPress: () => _confirmDelete(context, t),
                  ),
              ],
            ],
          ),
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
  const _StatsHeader({required this.stats, required this.quotesAt, required this.nextAt, required this.loading});

  final PortfolioStats stats;
  final DateTime? quotesAt;
  final DateTime? nextAt;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget stat(String label, double? v, {bool big = false}) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: text.labelMedium?.copyWith(color: Colors.white54)),
              Text(money(v), style: (big ? text.headlineSmall : text.titleMedium)?.copyWith(color: _pnlColor(v))),
            ],
          ),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [stat('P&L del día', stats.dayTotal, big: true), stat('P&L abierto', stats.unrealizedPnl)]),
            const SizedBox(height: 12),
            Row(children: [stat('Realizado hoy', stats.realizedToday), stat('Realizado total', stats.realizedTotal)]),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    loading
                        ? 'Actualizando precios…'
                        : quotesAt == null
                            ? 'Sin precios todavía'
                            : 'Precios de Yahoo Finance · ${_hhmm(quotesAt!)}',
                    style: text.bodySmall?.copyWith(color: Colors.white38),
                  ),
                ),
                if (!loading && nextAt != null)
                  CountdownText(until: nextAt!, prefix: 'siguiente en ', style: text.bodySmall?.copyWith(color: Colors.white38)),
              ],
            ),
          ],
        ),
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
    final p = position;
    final q = p.quote;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('${p.symbol} · ${p.side == TradeSide.long ? 'Largo' : 'Corto'} · ${qtyText(p.qty)} acc.'),
      subtitle: Text(
        'Invertido ${money(p.cost, sign: false)} · entrada ${money(p.avgEntry, sign: false)}\n'
        '${q == null ? 'Sin precio' : 'Ahora ${money(q.price, sign: false)}'}'
        '${p.dayPnl(DateTime.now()) == null ? '' : ' · hoy ${money(p.dayPnl(DateTime.now()))}'}',
      ),
      isThreeLine: true,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(money(p.unrealized), style: TextStyle(color: _pnlColor(p.unrealized), fontWeight: FontWeight.w600)),
          Text(pct(p.unrealizedPct), style: TextStyle(color: _pnlColor(p.unrealizedPct), fontSize: 12)),
        ],
      ),
      onTap: onClose,
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
    var left = widget.until.difference(DateTime.now()).inSeconds;
    if (left < 0) left = 0;
    return Text('${widget.prefix}${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}', style: widget.style);
  }
}

Color? _pnlColor(double? v) {
  if (v == null || v == 0) return null;
  return v > 0 ? const Color(0xFF4CD964) : const Color(0xFFFF5A5F);
}

String _date(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
