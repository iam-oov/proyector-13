import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'home_theme.dart';

/// Clima de hoy para el inicio: Open-Meteo (gratis, sin clave). La ubicación
/// sale de la IP pública (ipwho.is) una vez por arranque.
class Weather {
  const Weather({
    required this.temp,
    required this.max,
    required this.min,
    required this.code,
    required this.isDay,
  });

  final int temp;
  final int max;
  final int min;

  /// Código WMO del cielo (0 despejado … 99 tormenta con granizo).
  final int code;
  final bool isDay;

  String get description => switch (code) {
    0 => 'Despejado',
    1 => 'Mayormente despejado',
    2 => 'Parcialmente nublado',
    3 => 'Nublado',
    45 || 48 => 'Niebla',
    >= 51 && <= 57 => 'Llovizna',
    65 || 67 || 82 => 'Lluvia fuerte',
    >= 61 && <= 67 || >= 80 && <= 82 => 'Lluvia',
    >= 71 && <= 77 || 85 || 86 => 'Nieve',
    >= 95 => 'Tormenta',
    _ => 'Nublado',
  };

  IconData get icon => switch (code) {
    0 => isDay ? Icons.wb_sunny_rounded : Icons.nightlight_round,
    1 || 2 => isDay ? Icons.wb_cloudy_outlined : Icons.nights_stay_rounded,
    45 || 48 => Icons.foggy,
    >= 51 && <= 67 || >= 80 && <= 82 => Icons.water_drop_rounded,
    >= 71 && <= 77 || 85 || 86 => Icons.ac_unit_rounded,
    >= 95 => Icons.thunderstorm_rounded,
    _ => Icons.cloud_rounded,
  };
}

({double lat, double lon})? _place;

Future<Weather> fetchWeather({http.Client? client}) async {
  final c = client ?? http.Client();
  final p = _place ??= await _locate(c);
  final r = await c
      .get(
        Uri.https('api.open-meteo.com', '/v1/forecast', {
          'latitude': '${p.lat}',
          'longitude': '${p.lon}',
          'current': 'temperature_2m,weather_code,is_day',
          'daily': 'temperature_2m_max,temperature_2m_min',
          'timezone': 'auto',
          'forecast_days': '1',
        }),
      )
      .timeout(const Duration(seconds: 10));
  if (r.statusCode != 200) throw StateError('Open-Meteo ${r.statusCode}');
  final j = jsonDecode(r.body) as Map<String, dynamic>;
  final now = j['current'] as Map<String, dynamic>;
  final day = j['daily'] as Map<String, dynamic>;
  int first(String k) => ((day[k] as List).first as num).round();
  return Weather(
    temp: (now['temperature_2m'] as num).round(),
    code: (now['weather_code'] as num).toInt(),
    isDay: now['is_day'] == 1,
    max: first('temperature_2m_max'),
    min: first('temperature_2m_min'),
  );
}

Future<({double lat, double lon})> _locate(http.Client c) async {
  final r = await c
      .get(Uri.https('ipwho.is', '/'))
      .timeout(const Duration(seconds: 10));
  final j = jsonDecode(r.body) as Map<String, dynamic>;
  if (j['success'] != true) throw StateError('Ubicación: ${j['message']}');
  return (
    lat: (j['latitude'] as num).toDouble(),
    lon: (j['longitude'] as num).toDouble(),
  );
}

/// "☁ 18° Parcialmente nublado · 21° / 12°", cada 30 min (5 min si falló).
/// Sin datos no muestra nada.
class WeatherText extends StatefulWidget {
  const WeatherText({super.key});

  @override
  State<WeatherText> createState() => _WeatherTextState();
}

class _WeatherTextState extends State<WeatherText> {
  // El último clima sobrevive a que el inicio se cree de nuevo (al volver del
  // QR): se muestra de inmediato mientras se vuelve a consultar.
  static Weather? _last;
  Weather? _weather = _last;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    var next = const Duration(minutes: 30);
    try {
      final w = await fetchWeather();
      _last = w;
      if (mounted) setState(() => _weather = w);
    } catch (_) {
      // Sin internet o sin ubicación: se deja lo último y se reintenta pronto.
      next = const Duration(minutes: 5);
    }
    if (mounted) _timer = Timer(next, _refresh);
  }

  @override
  Widget build(BuildContext context) {
    final w = _weather;
    if (w == null) return const SizedBox.shrink();
    final p = HomePalette.of(context);
    final style = Theme.of(context).textTheme.titleMedium?.copyWith(
      color: p.muted,
    );
    // Sol en ámbar; lo demás (nubes, lluvia, noche) del color del texto.
    final sunny = w.isDay && w.code <= 2;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(w.icon, size: 20, color: sunny ? const Color(0xFFE0A100) : p.muted),
        const SizedBox(width: 6),
        Text(
          '${w.temp}°',
          style: style?.copyWith(color: p.text, fontWeight: FontWeight.w700),
        ),
        const SizedBox(width: 6),
        Text('${w.description} · ${w.max}° / ${w.min}°', style: style),
      ],
    );
  }
}
