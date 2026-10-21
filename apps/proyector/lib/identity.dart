import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared/shared.dart';

const _channel = MethodChannel('proyector/launch');

/// Identidad de esta pantalla: id y token se generan una vez y sobreviven
/// reinicios; van dentro del QR. El nombre se puede cambiar.
///
/// Se guarda en `identity.json` dentro de la carpeta privada de la app
/// (sin plugins: shared_preferences tronaba en este proyector con R8).
class ReceiverIdentity {
  ReceiverIdentity._(this._file, this.id, this.token, this._name);

  final File? _file;
  final String id;
  final String token;
  String _name;

  String get name => _name;

  static Future<ReceiverIdentity> load() async {
    File? file;
    try {
      final dir = await _channel.invokeMethod<String>('filesDir');
      if (dir != null) file = File('$dir/identity.json');
    } catch (_) {
      file = null;
    }
    if (file != null && await file.exists()) {
      try {
        final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final id = j['id'] as String?;
        final token = j['token'] as String?;
        if (id != null && token != null) {
          return ReceiverIdentity._(file, id, token, (j['name'] as String?) ?? 'Proyector');
        }
      } catch (_) {
        // Archivo corrupto: se genera una identidad nueva.
      }
    }
    final identity = ReceiverIdentity._(file, randomScreenId(), randomUrlSafe(32), 'Proyector');
    await identity._save();
    return identity;
  }

  /// Identidad de emergencia (no persiste) para que la app arranque aunque
  /// falle el almacenamiento.
  factory ReceiverIdentity.ephemeral() =>
      ReceiverIdentity._(null, randomScreenId(), randomUrlSafe(32), 'Proyector');

  Future<void> rename(String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    _name = n.length > 40 ? n.substring(0, 40) : n;
    await _save();
  }

  Future<void> _save() async {
    final f = _file;
    if (f == null) return;
    // Escritura atómica: primero un temporal y luego rename.
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode({'id': id, 'token': token, 'name': _name}), flush: true);
    await tmp.rename(f.path);
  }
}
