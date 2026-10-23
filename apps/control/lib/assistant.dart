import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared/shared.dart';

import 'config.dart';

/// Una acción de las que entendió el asistente en una frase.
class AssistantAction {
  const AssistantAction({
    required this.action,
    required this.searchQuery,
    required this.prefer,
    required this.title,
    required this.provider,
    required this.control,
    required this.volume,
    required this.screen,
    required this.startSeconds,
    required this.seconds,
    required this.minutes,
    required this.app,
    required this.on,
  });

  factory AssistantAction.fromJson(Map<String, dynamic> j) => AssistantAction(
        action: j['action'] as String,
        searchQuery: (j['search_query'] as String?) ?? '',
        prefer: (j['prefer'] as String?) ?? 'none',
        title: (j['title'] as String?) ?? '',
        provider: (j['provider'] as String?) ?? 'any',
        control: (j['control'] as String?) ?? 'none',
        volume: ((j['volume'] as num?) ?? 0).toInt().clamp(0, 100),
        screen: (j['screen'] as String?) ?? '',
        startSeconds: ((j['start_seconds'] as num?) ?? 0).toInt().clamp(0, 86400),
        seconds: ((j['seconds'] as num?) ?? 0).toInt().clamp(0, 86400).abs(),
        minutes: ((j['minutes'] as num?) ?? 0).toInt().clamp(0, 1440),
        app: (j['app'] as String?) ?? '',
        on: (j['on'] as bool?) ?? true,
      );

  /// play | play_title | control | switch_screen | power | sleep_timer | open | brightness | unknown
  final String action;

  /// play: qué buscar en YouTube.
  final String searchQuery;

  /// long_mix | single_video | latest_from_channel | none
  final String prefer;

  /// play_title: nombre de la serie o película tal como se conoce.
  final String title;

  /// play_title: netflix | disneyplus | prime | hbomax | appletv | crunchyroll | vix | youtube | any
  final String provider;

  /// pause | resume | next | stop | volume_up | volume_down | volume_set | mute | unmute |
  /// seek_forward | seek_back | seek_to | none
  final String control;

  /// play: segundo en que debe arrancar el video (0 = desde el inicio).
  final int startSeconds;

  /// seek_forward / seek_back: cuántos segundos moverse; seek_to: a qué segundo.
  final int seconds;
  final int volume;
  final String screen;

  /// sleep_timer: en cuántos minutos apagar (0 = cancelar el temporizador).
  final int minutes;

  /// open: app o entrada por su nombre ("PlayStation", "HDMI 1", "Spotify").
  final String app;

  /// power: prender (true) o apagar; brightness: mínimo (false) o normal.
  final bool on;
}

/// Lo que entendió el asistente de una frase: una lista de acciones en orden y
/// una confirmación.
class AssistantIntent {
  const AssistantIntent({required this.actions, required this.reply});

  factory AssistantIntent.fromJson(Map<String, dynamic> j) => AssistantIntent(
        actions: [for (final a in (j['actions'] as List? ?? [])) AssistantAction.fromJson(a as Map<String, dynamic>)],
        reply: (j['reply'] as String?) ?? '',
      );

  final List<AssistantAction> actions;
  final String reply;
}

/// Asistente de voz estilo "teevee": entiende lo que se dice ("quiero poner
/// música para la playa", "pon Stranger Things a volumen 8 y apaga en 30 minutos")
/// y lo convierte en acciones. Claude Haiku por la API HTTP (Dart no tiene SDK
/// oficial), con salida JSON validada por esquema.
class Assistant {
  static const _model = 'claude-haiku-5-5';

  static const _intentSystem = '''
Eres el asistente de voz de una app que controla los proyectores y TVs de una casa en México.
Recibes lo que dijo la persona (transcrito por el teléfono, puede traer errores) y el estado
de las pantallas. Una frase puede pedir VARIAS cosas ("pon Stranger Things a volumen 8 y apaga
en 30 minutos"): devuelve una acción por cada una, en el orden en que deben hacerse (primero lo
que se pone, luego volumen y brillo, al final el temporizador). Acciones:

- play: quiere ver o escuchar algo en YouTube (música, videos, canales). En search_query
  escribe lo que buscarías en YouTube para obtener el mejor resultado: conserva nombres de
  artistas, canales, lugares y títulos. Agrega "mix" o "playlist" solo para ambientes o géneros
  (long_mix); para un video concreto no agregues palabras que cambien lo que se busca. En prefer:
  long_mix para ambientes, géneros, estados de ánimo o actividades ("música para la playa",
  "algo para dormir", "cumbias para limpiar"); single_video para una canción o video concreto;
  latest_from_channel cuando pida lo último o lo más reciente de un canal o persona.
  Si pide empezar en un momento ("desde el minuto 15"), pon ese momento en segundos en
  start_seconds (minuto 15 = 900); si no, 0.
- play_title: quiere ver una serie o película de un servicio de streaming. En title va el nombre
  tal como se conoce (corrige errores de transcripción: "estranger tins" → "Stranger Things") y
  en provider el servicio si lo dijo (netflix, disneyplus, prime, hbomax, appletv, crunchyroll,
  vix) o any si no. Series y películas van aquí, no en play. Solo las Roku pueden; si la pantalla
  elegida no es Roku, igual devuelve play_title: la app avisará.
- control: pausar (pause), reanudar (resume), siguiente (next), detener (stop), subir o bajar el
  volumen (volume_up / volume_down; si dice cuánto, "súbele 3" o "bájale tantito", pon en volume
  cuántos pasos: tantito = 1, mucho = 4; si no dice, 0), poner el volumen en un número ("volumen 8", "al 50%":
  volume_set con volume de 0 a 100; en las TVs el número va de 0 a 100, así que "volumen 8" es 8),
  silenciar (mute) o quitar el silencio (unmute). Para moverse dentro del video que ya suena:
  seek_forward ("adelántalo 5 minutos"), seek_back ("regrésalo un minuto") o seek_to ("ponlo en
  el minuto 20"), con la cantidad o el momento en segundos en seconds.
- power: prender (on true) o apagar (on false) la pantalla ahora ("apaga el proyector", "préndelo",
  "ya me voy a dormir, apágalo").
- sleep_timer: apagar la pantalla dentro de un tiempo ("apágala en 30 minutos", "temporizador de
  una hora"): minutes con los minutos; "quita el temporizador" = minutes 0.
- open: abrir una app o cambiar de entrada por su nombre ("abre Spotify", "pon el PlayStation",
  "cambia a HDMI 1"): app con el nombre tal como aparece en la lista de la pantalla.
- brightness: brillo al mínimo ("brillo bajito", "modo noche": on false) o normal (on true).
- switch_screen: quiere usar otra pantalla; en screen va el nombre tal como aparece en la lista.
  Si en la misma frase pide algo para esa pantalla, switch_screen va primero.
- unknown: no se entiende o no se puede hacer con esta app (una sola acción unknown).

reply: confirmación corta en español de todo lo pedido, máximo doce palabras
("Pongo Stranger Things, volumen 8 y apago en 30 min").
Los campos que no apliquen van vacíos: "" en texto, "none"/"any" en listas, 0 en números y
true en on.''';

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

  static const _titleSystem = '''
Eliges, de una lista numerada de series y películas del catálogo, la que corresponde a lo que
pidió la persona: mismo título (aunque lo haya dicho con errores o en otro idioma), y si dijo el
año o "la nueva" o "la original", respétalo. Si pidió un servicio (Netflix, Disney…), prefiere
la que esté en ese servicio. Si ninguna corresponde, index -1. index es el número de la lista.
reply: confirmación corta en español ("Pongo Stranger Things en Netflix").''';

  static const _actionSchema = {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'action': {
        'type': 'string',
        'enum': ['play', 'play_title', 'control', 'switch_screen', 'power', 'sleep_timer', 'open', 'brightness', 'unknown'],
      },
      'search_query': {'type': 'string'},
      'prefer': {
        'type': 'string',
        'enum': ['long_mix', 'single_video', 'latest_from_channel', 'none'],
      },
      'title': {'type': 'string'},
      'provider': {
        'type': 'string',
        'enum': ['netflix', 'disneyplus', 'prime', 'hbomax', 'appletv', 'crunchyroll', 'vix', 'youtube', 'any'],
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
      'minutes': {'type': 'integer'},
      'screen': {'type': 'string'},
      'app': {'type': 'string'},
      'on': {'type': 'boolean'},
    },
    'required': [
      'action', 'search_query', 'prefer', 'title', 'provider', 'control', 'volume', 'start_seconds', 'seconds',
      'minutes', 'screen', 'app', 'on',
    ],
  };

  static const _intentSchema = {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'actions': {'type': 'array', 'items': _actionSchema},
      'reply': {'type': 'string'},
    },
    'required': ['actions', 'reply'],
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

  /// Segundo paso de play: cuál de los resultados de YouTube poner.
  Future<({int index, String reply})> pick(String said, AssistantAction a, List<VideoCandidate> videos) async {
    final list = [
      for (final (i, v) in videos.indexed)
        '$i. ${v.title} — ${v.channel}'
            '${v.duration == null ? '' : ' · dura ${v.duration}'}'
            '${v.published == null ? '' : ' · publicado ${v.published}'}'
            '${v.views == null ? '' : ' · ${v.views}'}',
    ].join('\n');
    final j = await _ask(
      _pickSystem,
      'Pidió: «$said»\nTipo: ${a.prefer}\nBúsqueda: ${a.searchQuery}'
      '${a.startSeconds > 0 ? '\nEmpieza en: ${a.startSeconds ~/ 60} min ${a.startSeconds % 60} s' : ''}'
      '\n\nResultados:\n$list',
      _pickSchema,
    );
    final index = (j['index'] as num).toInt();
    return (index: index.clamp(0, videos.length - 1), reply: (j['reply'] as String?) ?? '');
  }

  /// Segundo paso de play_title: cuál título del catálogo es (o -1 si ninguno).
  Future<({int index, String reply})> pickTitle(String said, AssistantAction a, List<String> titles) async {
    final list = [for (final (i, t) in titles.indexed) '$i. $t'].join('\n');
    final j = await _ask(
      _titleSystem,
      'Pidió: «$said»\nTítulo: ${a.title}\nServicio: ${a.provider}\n\nCatálogo:\n$list',
      _pickSchema,
    );
    final index = (j['index'] as num).toInt();
    return (index: index >= titles.length ? -1 : index, reply: (j['reply'] as String?) ?? '');
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
              'max_tokens': 2048,
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
