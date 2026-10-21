import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'identity.dart';

const _channel = MethodChannel('proyector/launch');

/// Máscara de proyección: polígonos normalizados (0..1) donde SÍ se ve la
/// imagen; el resto queda negro. Se guarda en mask.json y se restaura al arrancar.
class MaskController {
  MaskController(this._file);

  final File? _file;
  Map<String, Object?>? current;

  static Future<MaskController> open() async {
    final dir = await appFilesDir();
    final c = MaskController(dir == null ? null : File('$dir/mask.json'));
    await c._restore();
    return c;
  }

  bool get active => current != null;

  /// `shapes`: lista de polígonos `[x0, y0, x1, y1, …]`; `feather` 0..0.1.
  Future<void> apply({
    required List<List<double>> shapes,
    double feather = 0,
    bool outline = false,
    bool save = true,
  }) async {
    if (shapes.isEmpty) return clear();
    final data = <String, Object?>{
      'shapes': shapes,
      'feather': feather,
      'outline': outline,
    };
    await _channel.invokeMethod<bool>('setMask', data);
    current = data;
    // El contorno es para calibrar: no se guarda encendido.
    if (save) await _save({...data, 'outline': false});
  }

  Future<void> clear() async {
    await _channel.invokeMethod<bool>('clearMask');
    current = null;
    final f = _file;
    if (f != null && await f.exists()) await f.delete();
  }

  Future<void> _restore() async {
    final f = _file;
    if (f == null || !await f.exists()) return;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      await apply(
        shapes: parseShapes(j['shapes']),
        feather: (j['feather'] as num?)?.toDouble() ?? 0,
        save: false,
      );
    } catch (_) {
      // Máscara corrupta: se ignora.
    }
  }

  Future<void> _save(Map<String, Object?> data) async {
    final f = _file;
    if (f == null) return;
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(data), flush: true);
    await tmp.rename(f.path);
  }
}

/// Valida y convierte `[[x, y, x, y, …], …]` a polígonos con valores en 0..1.
List<List<double>> parseShapes(Object? raw) {
  if (raw is! List) throw const FormatException('shapes debe ser una lista');
  final out = <List<double>>[];
  for (final s in raw) {
    if (s is! List || s.length < 6 || s.length.isOdd) continue;
    out.add([for (final v in s) ((v as num).toDouble()).clamp(0.0, 1.0)]);
  }
  return out;
}
