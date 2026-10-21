import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  // Al volver al inicio se relee la lista: así aparecen las apps recién instaladas.
  late final _lifecycle = AppLifecycleListener(onResume: _load);
  final _firstApp = FocusNode();

  @override
  void initState() {
    super.initState();
    _lifecycle;
    _load();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _firstApp.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final apps = await installedApps();
      if (!mounted) return;
      final first = _apps.isEmpty && apps.isNotEmpty;
      setState(() => _apps = apps);
      // Las apps llegan después del primer frame: el foco inicial va a la primera.
      if (first) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _firstApp.requestFocus(),
        );
      }
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
                      Text(
                        state.identity.name,
                        style: text.bodyMedium?.copyWith(color: Colors.white54),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const ClockText(),
                      const ConnectivityRow(),
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
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, box) {
                        // Columnas según cuántas apps haya, para llenar filas
                        // completas a todo lo ancho (6 apps = 2 filas de 3).
                        const gap = 12.0;
                        final n = _apps.length;
                        final cols = n <= 6 ? 3 : (n <= 8 ? 4 : 5);
                        final w = ((box.maxWidth - gap * (cols - 1)) / cols)
                            .floorToDouble();
                        final sw = ((box.maxWidth - gap * 2) / 3)
                            .floorToDouble();
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: gap,
                              runSpacing: gap,
                              children: [
                                for (final (i, app) in _apps.indexed)
                                  HomeTile(
                                    width: w,
                                    label: app.label,
                                    icon: app.icon == null
                                        ? const Icon(Icons.apps, size: 34)
                                        : Image.memory(
                                            app.icon!,
                                            width: 56,
                                            height: 56,
                                            filterQuality: FilterQuality.medium,
                                          ),
                                    focusNode: i == 0 ? _firstApp : null,
                                    onTap: () =>
                                        _open(() => launchPackage(app.package)),
                                  ),
                              ],
                            ),
                            const SizedBox(height: gap),
                            // Accesos del sistema: una fila compacta debajo de las apps.
                            Row(
                              children: [
                                HomeTile(
                                  width: sw,
                                  compact: true,
                                  label: 'Vincular teléfono',
                                  icon: const Icon(Icons.qr_code_2, size: 24),
                                  color: const Color(0xFF2D2640),
                                  autofocus: _apps.isEmpty,
                                  onTap: () =>
                                      state.showPanel(ReceiverPanel.qr),
                                ),
                                const SizedBox(width: gap),
                                // Los del fabricante: trapezoide, modo de proyección, imagen, sonido, red.
                                HomeTile(
                                  width: sw,
                                  compact: true,
                                  label: 'Ajustes',
                                  icon: const Icon(Icons.settings, size: 24),
                                  color: const Color(0xFF2B2B2B),
                                  onTap: () => _open(
                                    () => launchComponent(
                                      'com.jixin.settings5',
                                      'com.jixin.settings5.SettingsActivity',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: gap),
                                // Los de Android TV: apps, cuentas, mandos, redes.
                                HomeTile(
                                  width: sw,
                                  compact: true,
                                  label: 'Ajustes Android',
                                  icon: const Icon(Icons.tune, size: 24),
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
                          ],
                        );
                      },
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
              if (state.queueInfo != null) ...[
                Row(
                  children: [
                    const Icon(Icons.shuffle, size: 20, color: Colors.white70),
                    const SizedBox(width: 8),
                    Text('Cola: ${state.queueInfo}', style: text.titleSmall),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              if (state.spotifyLinked && state.nowPlaying != null) ...[
                NowPlayingBar(state: state),
                const SizedBox(height: 16),
              ],
              // Último envío en una sola línea.
              Text(
                state.events.isEmpty
                    ? 'Último envío: todavía nada. Manda un video desde el teléfono.'
                    : 'Último envío · ${_hhmm(state.events.first.at)}  ${state.events.first.message}',
                style: text.bodyMedium?.copyWith(
                  color: state.events.isEmpty
                      ? Colors.white38
                      : (state.events.first.error
                            ? Colors.redAccent
                            : Colors.white70),
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
              : Image.network(
                  t.artUrl!,
                  width: 44,
                  height: 44,
                  fit: BoxFit.cover,
                ),
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
              Text(
                '${t.title} — ${t.artist}',
                style: text.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Wi-Fi (nombre + barras de intensidad) y Bluetooth conectados; cada 10 s.
class ConnectivityRow extends StatefulWidget {
  const ConnectivityRow({super.key});

  @override
  State<ConnectivityRow> createState() => _ConnectivityRowState();
}

class _ConnectivityRowState extends State<ConnectivityRow> {
  static const _channel = MethodChannel('proyector/launch');
  Map<String, Object?>? _wifi;
  List<Map<String, Object?>> _bt = [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final r = (await _channel.invokeMethod<Map<Object?, Object?>>(
        'connectivity',
      ))?.cast<String, Object?>();
      if (!mounted || r == null) return;
      setState(() {
        _wifi = (r['wifi'] as Map?)?.cast<String, Object?>();
        _bt = [
          for (final d in (r['bluetooth'] as List?) ?? const [])
            (d as Map).cast<String, Object?>(),
        ];
      });
    } catch (_) {
      // Sin datos: se deja lo último.
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium
        ?.copyWith(color: Colors.white70);
    final wifi = _wifi;
    final level = (wifi?['level'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            wifi == null
                ? Icons.wifi_off
                : const [
                    Icons.wifi_1_bar,
                    Icons.wifi_1_bar,
                    Icons.wifi_2_bar,
                    Icons.wifi,
                    Icons.wifi,
                  ][level],
            size: 18,
            color: wifi == null ? Colors.redAccent : Colors.white70,
          ),
          const SizedBox(width: 6),
          Text(
            wifi == null
                ? 'Sin Wi-Fi'
                : '${wifi['ssid'] ?? 'Wi-Fi'} · ${_signal(level)} (${wifi['rssi']} dBm)',
            style: style,
          ),
          for (final d in _bt) ...[
            const SizedBox(width: 14),
            Icon(
              d['kind'] == 'audio'
                  ? Icons.headphones
                  : Icons.bluetooth_connected,
              size: 18,
              color: Colors.lightBlueAccent,
            ),
            const SizedBox(width: 4),
            Text('${d['name']}', style: style),
          ],
        ],
      ),
    );
  }

  static String _signal(int level) => const [
    'muy débil',
    'débil',
    'regular',
    'buena',
    'excelente',
  ][level.clamp(0, 4)];
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
    this.width = 140,
    this.compact = false,
    this.focusNode,
  });

  final String label;
  final Widget icon;
  final VoidCallback onTap;
  final Color? color;
  final bool autofocus;
  final double width;
  final FocusNode? focusNode;

  /// Fila baja con ícono y texto lado a lado (accesos del sistema).
  final bool compact;

  @override
  State<HomeTile> createState() => _HomeTileState();
}

class _HomeTileState extends State<HomeTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = Text(
      widget.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    );
    return AnimatedScale(
      scale: _focused ? 1.06 : 1,
      duration: const Duration(milliseconds: 120),
      child: Material(
        color: widget.color ?? scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          autofocus: widget.autofocus,
          focusNode: widget.focusNode,
          borderRadius: BorderRadius.circular(16),
          onTap: widget.onTap,
          onFocusChange: (f) => setState(() => _focused = f),
          child: Container(
            width: widget.width,
            height: widget.compact ? 52 : 96,
            padding: EdgeInsets.symmetric(
              horizontal: widget.compact ? 14 : 12,
              vertical: widget.compact ? 0 : 12,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _focused ? Colors.white : Colors.transparent,
                width: 3,
              ),
            ),
            child: widget.compact
                ? Row(
                    children: [
                      widget.icon,
                      const SizedBox(width: 10),
                      Expanded(child: label),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [widget.icon, label],
                  ),
          ),
        ),
      ),
    );
  }
}
