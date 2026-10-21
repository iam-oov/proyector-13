import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared/shared.dart';

/// Una pantalla vinculada (un proyector o TV con el receptor instalado).
class Screen {
  const Screen({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.token,
  });

  factory Screen.fromPayload(PairingPayload p) =>
      Screen(id: p.id, name: p.name, host: p.host, port: p.port, token: p.token);

  factory Screen.fromJson(Map<String, dynamic> j) => Screen(
        id: j['id'] as String,
        name: j['name'] as String,
        host: j['host'] as String,
        port: j['port'] as int,
        token: j['token'] as String,
      );

  final String id;
  final String name;
  final String host;
  final int port;
  final String token;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'host': host, 'port': port, 'token': token};

  Screen copyWith({String? name, String? host, int? port, String? token}) => Screen(
        id: id,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        token: token ?? this.token,
      );

  String get address => '$host:$port';
}

/// Guarda las pantallas y cuál está activa, en el mismo almacén seguro que
/// el token de Spotify (el token de cada pantalla también es un secreto).
class ScreenStore {
  ScreenStore({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  static const _kScreens = 'screens';
  static const _kSelected = 'selected_screen_id';
  static const _kPhoneName = 'phone_name';

  final FlutterSecureStorage _storage;

  Future<List<Screen>> loadScreens() async {
    final raw = await _storage.read(key: _kScreens);
    if (raw == null) return [];
    try {
      return [for (final j in jsonDecode(raw) as List) Screen.fromJson(j as Map<String, dynamic>)];
    } catch (_) {
      return [];
    }
  }

  Future<void> saveScreens(List<Screen> screens) =>
      _storage.write(key: _kScreens, value: jsonEncode([for (final s in screens) s.toJson()]));

  Future<String?> loadSelectedId() => _storage.read(key: _kSelected);

  Future<void> saveSelectedId(String? id) =>
      id == null ? _storage.delete(key: _kSelected) : _storage.write(key: _kSelected, value: id);

  /// Cómo se presenta este teléfono ante las pantallas ("Conectado: Valdo").
  Future<String?> loadPhoneName() => _storage.read(key: _kPhoneName);

  Future<void> savePhoneName(String name) => _storage.write(key: _kPhoneName, value: name);
}
