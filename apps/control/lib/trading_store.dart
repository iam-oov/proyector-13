import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared/shared.dart';

/// La bitácora vive en el teléfono (por ahora). Misma bóveda que el resto.
class TradeStore {
  TradeStore({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  static const _kTrades = 'trades';

  final FlutterSecureStorage _storage;

  Future<List<Trade>> load() async {
    final raw = await _storage.read(key: _kTrades);
    if (raw == null) return [];
    try {
      return Trade.listFromJson(raw);
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<Trade> trades) => _storage.write(key: _kTrades, value: Trade.listToJson(trades));
}
