import 'dart:async';

import 'package:flutter/material.dart';

import 'apps.dart';
import 'state.dart';
import 'trading_dashboard.dart';

/// Título del inicio (el mismo en todas las pantallas de la casa).
const householdTitle = 'Familia HG';

/// Pantalla de inicio del proyector: tiles de apps + Vincular + Ajustes,
/// navegables con el control; a la derecha, las estadísticas de trading.
/// Abajo, el último envío.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.state});

  final ReceiverState state;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<TvApp> _apps = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final apps = await installedApps();
      if (mounted) setState(() => _apps = apps);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _open(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      widget.state.add('✕  $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 28),
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(householdTitle, style: text.headlineMedium),
                      // El nombre de esta pantalla (el del QR) queda como subtítulo.
                      Text(state.identity.name, style: text.bodyMedium?.copyWith(color: Colors.white54)),
                    ],
                  ),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const ClockText(),
                      Text(
                        state.phones.isEmpty
                            ? 'Nadie conectado'
                            : 'Conectado: ${state.phones.join(', ')}',
                        style: text.bodyMedium?.copyWith(color: Colors.white54),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final (i, app) in _apps.indexed)
                          HomeTile(
                            label: app.label,
                            icon: app.icon == null
                                ? const Icon(Icons.apps, size: 34)
                                : Image.memory(
                                    app.icon!,
                                    width: 56,
                                    height: 56,
                                    filterQuality: FilterQuality.medium,
                                  ),
                            autofocus: i == 0,
                            onTap: () =>
                                _open(() => launchPackage(app.package)),
                          ),
                        HomeTile(
                          label: 'Vincular teléfono',
                          icon: const Icon(Icons.qr_code_2, size: 34),
                          color: const Color(0xFF2D2640),
                          autofocus: _apps.isEmpty,
                          onTap: () => state.showPanel(ReceiverPanel.qr),
                        ),
                        // Los del fabricante: trapezoide, modo de proyección, imagen, sonido, red.
                        HomeTile(
                          label: 'Ajustes',
                          icon: const Icon(Icons.settings, size: 34),
                          color: const Color(0xFF2B2B2B),
                          onTap: () => _open(
                            () => launchComponent(
                              'com.jixin.settings5',
                              'com.jixin.settings5.SettingsActivity',
                            ),
                          ),
                        ),
                        // Los de Android TV: apps, cuentas, mandos, redes.
                        HomeTile(
                          label: 'Ajustes Android',
                          icon: const Icon(Icons.tune, size: 34),
                          color: const Color(0xFF2B2B2B),
                          onTap: () => _open(
                            () => launchComponent(
                              'com.android.tv.settings',
                              'com.android.tv.settings.MainSettings',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Estadísticas de trading (solo si hay movimientos registrados).
                  if (state.trades.isNotEmpty) ...[
                    const SizedBox(width: 20),
                    SizedBox(width: 288, child: TradingStats(state: state)),
                  ],
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: text.bodyMedium?.copyWith(color: Colors.redAccent),
                  ),
                ),
              const Spacer(),
              if (state.spotifyLinked && state.nowPlaying != null) ...[
                NowPlayingBar(state: state),
                const SizedBox(height: 16),
              ],
              Text('Últimos envíos', style: text.titleMedium),
              const SizedBox(height: 8),
              if (state.events.isEmpty)
                Text(
                  'Todavía nada. Manda un video desde el teléfono.',
                  style: text.bodyMedium?.copyWith(color: Colors.white38),
                ),
              for (final e in state.events.take(1))
                Text(
                  '${_hhmm(e.at)}  ${e.message}',
                  style: text.bodyMedium?.copyWith(
                    color: e.error ? Colors.redAccent : Colors.white70,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// "Sonando ahora" en Spotify (lo lee el propio proyector) y si lo está siguiendo.
class NowPlayingBar extends StatelessWidget {
  const NowPlayingBar({super.key, required this.state});

  final ReceiverState state;

  @override
  Widget build(BuildContext context) {
    final t = state.nowPlaying!;
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: t.artUrl == null
              ? const SizedBox.square(dimension: 44, child: Icon(Icons.album))
              : Image.network(t.artUrl!, width: 44, height: 44, fit: BoxFit.cover),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${t.isPlaying ? 'Sonando' : 'En pausa'} en Spotify · '
                '${state.spotifyFollowing ? 'el video sigue a la música' : 'seguimiento apagado'}',
                style: text.bodySmall?.copyWith(color: Colors.white54),
              ),
              Text('${t.title} — ${t.artist}', style: text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ],
    );
  }
}

/// Hora y fecha, actualizadas cada 15 s.
class ClockText extends StatefulWidget {
  const ClockText({super.key});

  @override
  State<ClockText> createState() => _ClockTextState();
}

class _ClockTextState extends State<ClockText> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    const days = [
      'lunes',
      'martes',
      'miércoles',
      'jueves',
      'viernes',
      'sábado',
      'domingo',
    ];
    const months = [
      'ene',
      'feb',
      'mar',
      'abr',
      'may',
      'jun',
      'jul',
      'ago',
      'sep',
      'oct',
      'nov',
      'dic',
    ];
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
          style: text.displaySmall?.copyWith(
            fontWeight: FontWeight.w300,
            height: 1,
          ),
        ),
        Text(
          '${days[now.weekday - 1]} ${now.day} de ${months[now.month - 1]}',
          style: text.bodyMedium?.copyWith(color: Colors.white54),
        ),
      ],
    );
  }
}

/// Tile grande con resalte de foco para el D-pad. Enter/OK lo activa.
class HomeTile extends StatefulWidget {
  const HomeTile({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.color,
    this.autofocus = false,
  });

  final String label;
  final Widget icon;
  final VoidCallback onTap;
  final Color? color;
  final bool autofocus;

  @override
  State<HomeTile> createState() => _HomeTileState();
}

class _HomeTileState extends State<HomeTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedScale(
      scale: _focused ? 1.06 : 1,
      duration: const Duration(milliseconds: 120),
      child: Material(
        color: widget.color ?? scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          autofocus: widget.autofocus,
          borderRadius: BorderRadius.circular(16),
          onTap: widget.onTap,
          onFocusChange: (f) => setState(() => _focused = f),
          child: Container(
            width: 140,
            height: 96,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _focused ? Colors.white : Colors.transparent,
                width: 3,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                widget.icon,
                Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
