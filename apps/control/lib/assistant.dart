import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared/shared.dart';

import 'config.dart';

/// Lo que entendió el asistente de una frase.
class AssistantIntent {
  const AssistantIntent({
    required this.action,
    required this.searchQuery,
    required this.prefer,
    required this.control,
    required this.volume,
    required this.screen,
    required this.reply,
    required this.startSeconds,
    required this.seconds,
  });

  factory AssistantIntent.fromJson(Map<String, dynamic> j) => AssistantIntent(
        action: j['action'] as String,
        searchQuery: (j['search_query'] as String?) ?? '',
        prefer: (j['prefer'] as String?) ?? 'none',
        control: (j['control'] as String?) ?? 'none',
        volume: ((j['volume'] as num?) ?? 0).toInt().clamp(0, 100),
        screen: (j['screen'] as String?) ?? '',
        reply: (j['reply'] as String?) ?? '',
        startSeconds: ((j['start_seconds'] as num?) ?? 0).toInt().clamp(0, 86400),
        seconds: ((j['seconds'] as num?) ?? 0).toInt().clamp(0, 86400).abs(),
      );

  /// play | control | switch_screen | unknown
  final String action;
  final String searchQuery;

  /// long_mix | single_video | latest_from_channel | none
  final String prefer;

  /// pause | resume | next | stop | volume_up | volume_down | volume_set | mute | unmute |
  /// seek_forward | seek_back | seek_to | none
  final String control;

  /// play: segundo en que debe arrancar el video (0 = desde el inicio).
  final int startSeconds;

  /// seek_forward / seek_back: cuántos segundos moverse; seek_to: a qué segundo.
  final int seconds;
  final int volume;
  final String screen;
  final String reply;
}

/// Asistente de voz estilo "teevee": entiende lo que se dice ("quiero poner
/// música para la playa") y elige el video de YouTube adecuado. Claude Haiku por
/// la API HTTP (Dart no tiene SDK oficial), con salida JSON validada por esquema.
class Assistant {
  static const _model = 'claude-haiku-5-5';

  static const _intentSystem = '''
Eres el asistente de voz de una app que controla los proyectores y TVs de una casa en México.
Recibes lo que dijo la persona (transcrito por el teléfono, puede traer errores) y el estado
de las pantallas. Decide UNA acción:

- play: quiere ver o escuchar algo en YouTube. En search_query escribe lo que buscarías en
  YouTube para obtener el mejor resultado: conserva nombres de artistas, canales, lugares y
  títulos. Agrega "mix" o "playlist" solo para ambientes o géneros (long_mix); para un video
  concreto no agregues palabras que cambien lo que se busca. En prefer:
  long_mix para ambientes, géneros, estados de ánimo o actividades ("música para la playa",
  "algo para dormir", "cumbias para limpiar"); single_video para una canción o video concreto;
  latest_from_channel cuando pida lo último o lo más reciente de un canal o persona.
  Si pide empezar en un momento ("desde el minuto 15", "a partir del 1:20"), pon ese momento
  en segundos en start_seconds (minuto 15 = 900); si no, 0.
- Para moverse dentro del video que ya suena usa control: seek_forward ("adelántalo 5 minutos",
  "sáltate 30 segundos"), seek_back ("regrésalo un minuto") o seek_to ("ponlo en el minuto 20"),
  con la cantidad o el momento en segundos en seconds.
- control: pausar (pause), reanudar (resume), siguiente (next), detener (stop), subir o bajar el
  volumen (volume_up / volume_down), poner el volumen en un número o porcentaje (volume_set con
  volume de 0 a 100), silenciar (mute) o quitar el silencio (unmute).
- switch_screen: quiere usar otra pantalla; en screen va el nombre tal como aparece en la lista.
- unknown: no se entiende o no se puede hacer con esta app.

reply: confirmación corta en español, de máximo ocho palabras ("Pongo música para la playa").
Los campos que no apliquen van vacíos: "" en texto, "none" en listas y 0 en los números.''';

  static const _pickSystem = '''
Eliges el video de YouTube que mejor cumple lo que pidió la persona, de una lista numerada.
Primero, el título tiene que corresponder a lo pedido: los nombres, lugares y palabras concretas
de la frase ("en la México", "capítulo 2", "en vivo") deben estar en el título; entre los que
cumplen, gana el que coincide con más detalles.
- long_mix: prefiere mezclas o playlists largas (30 minutos o más) del ambiente o género pedido
  sobre canciones sueltas; evita shorts, tutoriales, reacciones y videos que no son música.
- single_video: el video oficial del artista y la canción correctos; si no hay oficial, el más
  fiel (letra o en vivo del mismo artista).
- latest_from_channel: el más reciente (según "publicado") del canal o persona correctos.
- Si la persona quiere empezar en un momento ("Empieza en"), descarta los videos que duran menos
  que eso. Es solo un filtro: no elijas uno por ser más largo si otro coincide mejor con el título.
Nunca elijas algo que no corresponda a lo pedido. index es el número de la lista.
reply: confirmación corta en español con el título resumido ("Pongo Beach House Mix 2026").''';

  static const _intentSchema = {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'action': {
        'type': 'string',
        'enum': ['play', 'control', 'switch_screen', 'unknown'],
      },
      'search_query': {'type': 'string'},
      'prefer': {
        'type': 'string',
        'enum': ['long_mix', 'single_video', 'latest_from_channel', 'none'],
      },
      'control': {
        'type': 'string',
        'enum': [
          'pause', 'resume', 'next', 'stop', 'volume_up', 'volume_down', 'volume_set', 'mute', 'unmute',
          'seek_forward', 'seek_back', 'seek_to', 'none',
        ],
      },
      'volume': {'type': 'integer'},
      'start_seconds': {'type': 'integer'},
      'seconds': {'type': 'integer'},
      'screen': {'type': 'string'},
      'reply': {'type': 'string'},
    },
    'required': ['action', 'search_query', 'prefer', 'control', 'volume', 'start_seconds', 'seconds', 'screen', 'reply'],
  };

  static const _pickSchema = {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'index': {'type': 'integer'},
      'reply': {'type': 'string'},
    },
    'required': ['index', 'reply'],
  };

  /// Primer paso: qué quiere la persona. [context] describe las pantallas y lo que suena.
  Future<AssistantIntent> understand(String said, String context) async {
    final j = await _ask(_intentSystem, '$context\n\nDijo: «$said»', _intentSchema);
    return AssistantIntent.fromJson(j);
  }

  /// Segundo paso: cuál de los resultados de YouTube poner.
  Future<({int index, String reply})> pick(String said, AssistantIntent intent, List<VideoCandidate> videos) async {
    final list = [
      for (final (i, v) in videos.indexed)
        '$i. ${v.title} — ${v.channel}'
            '${v.duration == null ? '' : ' · dura ${v.duration}'}'
            '${v.published == null ? '' : ' · publicado ${v.published}'}'
            '${v.views == null ? '' : ' · ${v.views}'}',
    ].join('\n');
    final j = await _ask(
      _pickSystem,
      'Pidió: «$said»\nTipo: ${intent.prefer}\nBúsqueda: ${intent.searchQuery}'
      '${intent.startSeconds > 0 ? '\nEmpieza en: ${intent.startSeconds ~/ 60} min ${intent.startSeconds % 60} s' : ''}'
      '\n\nResultados:\n$list',
      _pickSchema,
    );
    final index = (j['index'] as num).toInt();
    return (index: index.clamp(0, videos.length - 1), reply: (j['reply'] as String?) ?? '');
  }

  Future<Map<String, dynamic>> _ask(String system, String user, Map<String, Object> schema) async {
    if (!Config.hasAssistant) throw StateError('Falta ANTHROPIC_API_KEY en el .env: compila con --dart-define-from-file');
    for (var attempt = 0; ; attempt++) {
      final r = await http
          .post(
            Uri.https('api.anthropic.com', '/v1/messages'),
            headers: {
              'content-type': 'application/json',
              'x-api-key': Config.anthropicApiKey,
              'anthropic-version': '2023-06-01',
            },
            body: jsonEncode({
              'model': _model,
              'max_tokens': 1024,
              'system': system,
              'messages': [
                {'role': 'user', 'content': user},
              ],
              // Haiku 5.5 piensa por defecto con esfuerzo medium: low para que responda rápido.
              'output_config': {
                'effort': 'low',
                'format': {'type': 'json_schema', 'schema': schema},
              },
            }),
          )
          .timeout(const Duration(seconds: 25));
      if (r.statusCode == 401) throw StateError('La API key de Anthropic no es válida');
      if (r.statusCode == 429) throw StateError('El asistente está ocupado: intenta en un momento');
      if ((r.statusCode >= 500 || r.statusCode == 529) && attempt == 0) continue;
      if (r.statusCode != 200) throw StateError('El asistente respondió ${r.statusCode}');
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final stop = j['stop_reason'];
      if (stop == 'refusal') throw StateError('El asistente no puede con eso');
      if (stop == 'max_tokens') throw StateError('El asistente no terminó de responder');
      final text = [
        for (final b in j['content'] as List)
          if (b['type'] == 'text') b['text'] as String,
      ].join();
      return jsonDecode(text) as Map<String, dynamic>;
    }
  }
}
