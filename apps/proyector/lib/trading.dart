import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared/shared.dart';

import 'identity.dart';
import 'state.dart';

/// Guarda la bitácora que manda el teléfono (trading.json) y si el tablero
/// debe mostrarse al arrancar.
class TradingStore {
  TradingStore(this._file);

  final File? _file;

  static Future<TradingStore> open() async {
    final dir = await appFilesDir();
    return TradingStore(dir == null ? null : File('$dir/trading.json'));
  }

  Future<({List<Trade> trades, bool show})> load() async {
    final f = _file;
    if (f == null || !await f.exists()) return (trades: <Trade>[], show: false);
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return (
        trades: [for (final t in (j['trades'] as List?) ?? const []) Trade.fromJson(t as Map<String, dynamic>)],
        show: j['show'] == true,
      );
    } catch (_) {
      return (trades: <Trade>[], show: false);
    }
  }

  Future<void> save(List<Trade> trades, bool show) async {
    final f = _file;
    if (f == null) return;
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({'show': show, 'trades': [for (final t in trades) t.toJson()]}),
      flush: true,
    );
    await tmp.rename(f.path);
  }
}

/// Las estadísticas viven en el inicio: pide precios a Yahoo mientras el
/// inicio está en pantalla y hay posiciones abiertas — cada minuto con el
/// mercado abierto; con el mercado cerrado espera a la siguiente apertura.
/// Persiste lo que manda el teléfono.
class TradingController {
  TradingController(this.state, this.store);

  final ReceiverState state;
  final TradingStore store;
  final _yahoo = YahooFinance();
  Timer? _timer;
  bool _active = false;

  Future<void> init() async {
    final saved = await store.load();
    state.trades = saved.trades;
    state.addListener(_onState);
    _onState();
  }

  void _onState() {
    final want = state.panel == ReceiverPanel.home && state.trades.any((t) => t.isOpen);
    if (want == _active) return;
    _active = want;
    _timer?.cancel();
    _timer = null;
    if (!want) return;
    // Al volver al inicio: si ya hay un siguiente refresh agendado en el
    // futuro (p. ej. mercado cerrado), se respeta; si no, se pide ya.
    final next = state.nextQuotesAt;
    if (next != null && next.isAfter(DateTime.now()) && state.quotesAt != null) {
      _schedule(next);
    } else {
      unawaited(refresh());
    }
  }

  void _schedule(DateTime at) {
    _timer?.cancel();
    _timer = Timer(at.difference(DateTime.now()), () => refresh());
  }

  /// Llamado por el servidor después de un POST /trading.
  Future<void> onChanged() async {
    await store.save(state.trades, false);
    if (state.panel == ReceiverPanel.home) await refresh();
  }

  Future<void> refresh() async {
    final symbols = state.trades.where((t) => t.isOpen).map((t) => t.symbol).toSet();
    if (symbols.isEmpty) return;
    state.setQuotesLoading(true);
    final quotes = await _yahoo.quotes(symbols);
    if (quotes.isEmpty) {
      state.quoteError('Sin respuesta de Yahoo Finance');
    } else {
      state.setQuotes(quotes);
    }
    final next = UsMarketHours.nextRefresh(
      DateTime.now(),
      lastMarketState: quotes.isEmpty ? null : quotes.values.first.marketState,
    );
    state.setQuotesLoading(false, nextAt: next);
    if (_active) _schedule(next);
  }
}
