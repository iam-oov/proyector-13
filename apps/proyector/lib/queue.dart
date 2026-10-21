import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared/shared.dart';

import 'player.dart';
import 'state.dart';

const _channel = MethodChannel('proyector/launch');

/// Cola de reproducción en el proyector (p. ej. una playlist en aleatorio).
/// YouTube, al terminar un video, salta solo a un "recomendado"; cuando vemos
/// en su sesión de medios que el título ya no es el nuestro (o que se detuvo),
/// ponemos la siguiente canción de la cola.
class QueueController {
  QueueController(this.state);

  final ReceiverState state;
  List<Track> _tracks = [];
  int _index = -1;
  String? _name;

  /// Título de YouTube del video que pusimos y si ya lo vimos sonar.
  String? _expected;
  bool _sawExpected = false;
  bool _advancing = false;
  bool watching = false;

  /// Lo último que reportó la sesión de medios de YouTube (para el teléfono).
  String? mediaTitle;
  bool mediaPlaying = false;

  bool get active => _index >= 0 && _index < _tracks.length;

  Future<void> init() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'mediaChanged') {
        final info = (call.arguments as Map).cast<String, Object?>();
        mediaTitle = info['title'] as String?;
        // 3 = PLAYING, 6 = BUFFERING.
        final s = (info['state'] as num?)?.toInt();
        mediaPlaying = s == 3 || s == 6;
        _onMedia(info);
      }
    });
    try {
      watching = await _channel.invokeMethod<bool>('startMediaWatch') ?? false;
    } catch (_) {
      watching = false;
    }
    if (!watching) {
      state.add(
        'Cola: falta el permiso de acceso a notificaciones (adb)',
        error: true,
      );
    }
  }

  Future<void> start(
    List<Track> tracks, {
    String? name,
    int startAt = 0,
  }) async {
    if (tracks.isEmpty) return stop();
    _tracks = tracks;
    _name = name;
    _index = startAt.clamp(0, tracks.length - 1) - 1;
    await next();
  }

  void stop() {
    _tracks = [];
    _index = -1;
    _expected = null;
    _sawExpected = false;
    state.setQueue(null);
  }

  /// Pone la siguiente canción que tenga video en YouTube.
  Future<void> next() async {
    if (_advancing) return;
    _advancing = true;
    try {
      while (_index + 1 < _tracks.length) {
        _index++;
        final t = _tracks[_index];
        try {
          final ranked = rankVideos(await searchTrackVideos(t), t);
          if (ranked.isEmpty) continue;
          final v = ranked.first.video;
          _expected = _norm(v.title);
          _sawExpected = false;
          await openVideo(v.url);
          state.setQueue(
            '${_name ?? 'Cola'} · ${_index + 1} de ${_tracks.length}',
          );
          state.add('♫  ${t.title} — ${t.artist}');
          return;
        } catch (e) {
          state.add('✕  Cola: ${t.title}: $e', error: true);
        }
      }
      state.add('Cola terminada');
      stop();
    } finally {
      _advancing = false;
    }
  }

  void _onMedia(Map<String, Object?> info) {
    if (!active || _advancing) return;
    final title = info['title'] as String?;
    final playbackState = (info['state'] as num?)?.toInt() ?? 0;
    final norm = title == null ? null : _norm(title);
    final isOurs =
        norm != null &&
        _expected != null &&
        (norm == _expected ||
            norm.startsWith(_expected!) ||
            _expected!.startsWith(norm));
    if (isOurs) {
      _sawExpected = true;
      // 1 = STOPPED: terminó sin autoplay.
      if (playbackState == 1) unawaited(next());
      return;
    }
    // Ya sonaba lo nuestro y ahora YouTube puso otra cosa → siguiente.
    if (_sawExpected && norm != null) unawaited(next());
  }

  static String _norm(String s) {
    final n = normalize(s).replaceAll(RegExp(r'\s+'), ' ').trim();
    return n.length > 40 ? n.substring(0, 40) : n;
  }
}
