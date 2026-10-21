import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared/shared.dart';

const _channel = MethodChannel('proyector/launch');

/// Identidad de esta pantalla: id y token se generan una vez y sobreviven
/// reinicios; van dentro del QR. El nombre se puede cambiar y se recuerdan
/// los teléfonos que se han vinculado.
///
/// Se guarda en `identity.json` dentro de la carpeta privada de la app
/// (sin plugins: shared_preferences tronaba en este proyector con R8).
class ReceiverIdentity {
  ReceiverIdentity._(this._file, this.id, this.token, this._name, this.phones);

  final File? _file;
  final String id;
  final String token;
  String _name;

  /// Nombres de los teléfonos que han hecho POST /pair (máximo 20).
  final List<String> phones;

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
          final phones = [for (final p in (j['phones'] as List?) ?? const []) p.toString()];
          return ReceiverIdentity._(file, id, token, (j['name'] as String?) ?? 'Proyector', phones);
        }
      } catch (_) {
        // Archivo corrupto: se genera una identidad nueva.
      }
    }
    final identity = ReceiverIdentity._(file, randomScreenId(), randomUrlSafe(32), 'Proyector', []);
    await identity._save();
    return identity;
  }

  /// Identidad de emergencia (no persiste) para que la app arranque aunque
  /// falle el almacenamiento.
  factory ReceiverIdentity.ephemeral() =>
      ReceiverIdentity._(null, randomScreenId(), randomUrlSafe(32), 'Proyector', []);

  Future<void> rename(String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    _name = n.length > 40 ? n.substring(0, 40) : n;
    await _save();
  }

  /// True si el teléfono es nuevo (se compara sin mayúsculas).
  Future<bool> addPhone(String name) async {
    var n = name.trim();
    if (n.isEmpty) return false;
    if (n.length > 40) n = n.substring(0, 40);
    if (phones.any((p) => p.toLowerCase() == n.toLowerCase())) return false;
    phones.add(n);
    if (phones.length > 20) phones.removeAt(0);
    await _save();
    return true;
  }

  Future<void> _save() async {
    final f = _file;
    if (f == null) return;
    // Escritura atómica: primero un temporal y luego rename.
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({'id': id, 'token': token, 'name': _name, 'phones': phones}),
      flush: true,
    );
    await tmp.rename(f.path);
  }
}
