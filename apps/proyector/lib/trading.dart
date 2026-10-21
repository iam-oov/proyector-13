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

/// Pide precios a Yahoo cada minuto mientras el tablero está en pantalla y
/// hay posiciones abiertas; persiste lo que manda el teléfono.
class TradingController {
  TradingController(this.state, this.store);

  final ReceiverState state;
  final TradingStore store;
  final _yahoo = YahooFinance();
  Timer? _timer;
  bool _savedShow = false;

  Future<void> init() async {
    final saved = await store.load();
    state.trades = saved.trades;
    _savedShow = saved.show;
    if (saved.show) state.panel = ReceiverPanel.trading;
    state.addListener(_onState);
    _onState();
  }

  void _onState() {
    final show = state.panel == ReceiverPanel.trading;
    if (show != _savedShow) {
      _savedShow = show;
      unawaited(store.save(state.trades, show));
    }
    final want = show && state.trades.any((t) => t.isOpen);
    if (want && _timer == null) {
      _timer = Timer.periodic(_every, (_) => refresh());
      unawaited(refresh());
    } else if (!want && _timer != null) {
      _timer!.cancel();
      _timer = null;
      state.nextQuotesAt = null;
    }
  }

  static const _every = Duration(minutes: 1);

  /// Llamado por el servidor después de un POST /trading.
  Future<void> onChanged() async {
    await store.save(state.trades, state.panel == ReceiverPanel.trading);
    if (state.panel == ReceiverPanel.trading) await refresh();
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
    // El countdown del tablero apunta al siguiente tick del timer.
    state.setQuotesLoading(false, nextAt: _timer == null ? null : DateTime.now().add(_every));
  }
}
