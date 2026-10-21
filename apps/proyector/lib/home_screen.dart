import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'apps.dart';
import 'identity.dart';
import 'state.dart';
import 'trading_dashboard.dart';

/// Título del inicio si no se eligió otro. Se cambia por ADB (lo pregunta la
/// skill /proyector-start): MainActivity guarda el extra `homeTitle` en
/// `home_title.txt` y el inicio lo relee cada vez que vuelve al frente.
const householdTitle = 'Familia HG';

Future<String> loadHomeTitle() async {
  final dir = await appFilesDir();
  if (dir == null) return householdTitle;
  try {
    final t = (await File('$dir/home_title.txt').readAsString()).trim();
    return t.isEmpty ? householdTitle : t;
  } catch (_) {
    return householdTitle;
  }
}

/// Colores del inicio: fondo rosa pastel, apps en morado lila y accesos del
/// sistema en fucsia. Estilo "Liquid Glass": los tiles son vidrio teñido de esos
/// colores sobre manchas difusas del fondo.
const homeBackground = Color(0xFFFFD6E7);
const homeTileColor = Color(0xFF9B6BD6);
const homeSystemTileColor = Color(0xFFA8005C);

/// Borde del tile con el foco del control: oscuro para que resalte sobre el pastel.
const homeFocusColor = Color(0xFF4A0026);

/// Vidrio teñido. Sin BackdropFilter a propósito: en proyectores de 1 GB el
/// desenfoque real se recalcula en cada animación de foco y se traba. Como el
/// fondo es fijo, basta con translucidez, brillo arriba, borde de luz y sombra.
BoxDecoration glassDecoration(
  Color tint, {
  double radius = 20,
  bool focused = false,
  double opacity = 0.55,
}) {
  final a = focused ? opacity + 0.2 : opacity;
  return BoxDecoration(
    borderRadius: BorderRadius.circular(radius),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        tint.withValues(alpha: (a + 0.15).clamp(0, 1)),
        tint.withValues(alpha: a),
      ],
    ),
    border: Border.all(
      color: focused ? homeFocusColor : Colors.white.withValues(alpha: 0.6),
      width: focused ? 3 : 1.2,
    ),
    boxShadow: [
      BoxShadow(
        color: tint.withValues(alpha: focused ? 0.45 : 0.25),
        blurRadius: focused ? 26 : 16,
        offset: const Offset(0, 8),
      ),
    ],
  );
}

/// Brillo del vidrio: luz blanca que cae desde arriba.
BoxDecoration glassHighlight({double radius = 20}) => BoxDecoration(
  borderRadius: BorderRadius.circular(radius),
  gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.center,
    colors: [
      Colors.white.withValues(alpha: 0.32),
      Colors.white.withValues(alpha: 0),
    ],
  ),
);

/// Panel de vidrio claro (encabezado) o teñido.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.tint = Colors.white,
    this.opacity = 0.35,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
  });

  final Widget child;
  final Color tint;
  final double opacity;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: glassDecoration(tint, opacity: opacity),
    child: DecoratedBox(
      decoration: glassHighlight(),
      child: Padding(padding: padding, child: child),
    ),
  );
}

/// Fondo del inicio: rosa pastel con manchas grandes y difusas (rosa, fucsia,
/// lila) que se ven a través del vidrio. Es fijo: se pinta una vez.
class HomeBackdrop extends StatelessWidget {
  const HomeBackdrop({super.key, required this.child});

  final Widget child;

  static Widget _blob(Color c, double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(
        colors: [c.withValues(alpha: 0.6), c.withValues(alpha: 0)],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: RepaintBoundary(
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFFFFE4F0),
                        homeBackground,
                        Color(0xFFF3D4F2),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: -140,
                top: -160,
                child: _blob(const Color(0xFFFF5FA2), 560),
              ),
              Positioned(
                right: -180,
                bottom: -220,
                child: _blob(const Color(0xFFB98BEA), 640),
              ),
              Positioned(
                right: 260,
                top: 120,
                child: _blob(const Color(0xFFFF9EC7), 420),
              ),
              Positioned(
                left: 180,
                bottom: -160,
                child: _blob(const Color(0xFFE88BD8), 380),
              ),
            ],
          ),
        ),
      ),
      child,
    ],
  );
}

/// Tema claro del inicio: con fondo pastel el texto va oscuro.
final homeTheme = ThemeData(
  brightness: Brightness.light,
  colorSchemeSeed: homeTileColor,
  scaffoldBackgroundColor: homeBackground,
  useMaterial3: true,
);

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
  String _title = householdTitle;
  // Accesos de ajustes que existen en este equipo (cambian según el fabricante).
  AppActivity? _vendorSettings;
  AppActivity? _androidSettings;
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
      final title = await loadHomeTitle();
      final all = await installedApps();
      // Si el fabricante pone sus ajustes como app (com.android.tv.settings en el
      // Rockchip), van a la fila de accesos y no se repiten en la cuadrícula.
      final gridSettings = all
          .where((a) => a.package == androidSettings.package)
          .firstOrNull;
      final apps = [
        for (final a in all)
          if (a != gridSettings) a,
      ];
      AppActivity? vendor;
      for (final v in vendorSettings) {
        if (await hasActivity(v)) {
          vendor = v;
          break;
        }
      }
      vendor ??= gridSettings == null
          ? null
          : (package: gridSettings.package, activity: gridSettings.activity);
      final android =
          vendor != androidSettings && await hasActivity(androidSettings)
          ? androidSettings
          : null;
      if (!mounted) return;
      final first = _apps.isEmpty && apps.isNotEmpty;
      setState(() {
        _title = title;
        _apps = apps;
        _vendorSettings = vendor;
        _androidSettings = android;
      });
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
    // Tamaños del tema de la app (homeTheme.textTheme solo trae colores) con
    // los colores oscuros del inicio.
    final text = Theme.of(context).textTheme.merge(homeTheme.textTheme);
    // La tarjeta de trading conserva el tema oscuro de la app.
    final appTheme = Theme.of(context);
    return Theme(
      data: homeTheme,
      child: Scaffold(
        body: HomeBackdrop(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 28),
            child: ListenableBuilder(
              listenable: state,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Título y hora a la misma altura y del mismo tamaño.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _title,
                            style: text.displaySmall?.copyWith(height: 1),
                          ),
                          // El nombre de esta pantalla (el del QR) queda como subtítulo.
                          Text(
                            state.identity.name,
                            style: text.bodyMedium?.copyWith(
                              color: Colors.black87,
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      GlassPanel(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            const ClockText(),
                            const ConnectivityRow(),
                            Text(
                              state.phones.isEmpty
                                  ? 'Nadie conectado'
                                  : 'Conectado: ${state.phones.join(', ')}',
                              style: text.bodyMedium?.copyWith(
                                color: Colors.black87,
                              ),
                            ),
                          ],
                        ),
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
                            // Cada app mide lo que su ícono y su nombre: así caben
                            // más por fila (un nombre largo solo ensancha su tile).
                            const gap = 12.0;
                            final vendor = _vendorSettings;
                            final android = _androidSettings;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  spacing: gap,
                                  runSpacing: gap,
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
                                                filterQuality:
                                                    FilterQuality.medium,
                                              ),
                                        focusNode: i == 0 ? _firstApp : null,
                                        onTap: () => _open(
                                          () => launchPackage(app.package),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: gap),
                                // Accesos del sistema: una fila compacta debajo de las apps.
                                Row(
                                  children: [
                                    HomeTile(
                                      compact: true,
                                      label: 'Vincular teléfono',
                                      icon: const Icon(
                                        Icons.qr_code_2,
                                        size: 24,
                                      ),
                                      color: homeSystemTileColor,
                                      autofocus: _apps.isEmpty,
                                      onTap: () =>
                                          state.showPanel(ReceiverPanel.qr),
                                    ),
                                    // Los del fabricante: trapezoide, modo de proyección, imagen, sonido, red.
                                    if (vendor != null) ...[
                                      const SizedBox(width: gap),
                                      HomeTile(
                                        compact: true,
                                        label: 'Ajustes',
                                        icon: const Icon(
                                          Icons.settings,
                                          size: 24,
                                        ),
                                        color: homeSystemTileColor,
                                        onTap: () => _open(
                                          () => launchComponent(
                                            vendor.package,
                                            vendor.activity,
                                          ),
                                        ),
                                      ),
                                    ],
                                    // Los de Android TV: apps, cuentas, mandos, redes.
                                    if (android != null) ...[
                                      const SizedBox(width: gap),
                                      HomeTile(
                                        compact: true,
                                        label: 'Ajustes Android',
                                        icon: const Icon(Icons.tune, size: 24),
                                        color: homeSystemTileColor,
                                        onTap: () => _open(
                                          () => launchComponent(
                                            android.package,
                                            android.activity,
                                          ),
                                        ),
                                      ),
                                    ],
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
                        SizedBox(
                          width: 288,
                          child: Theme(
                            data: appTheme,
                            child: TradingStats(state: state),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _error!,
                        style: text.bodyMedium?.copyWith(
                          color: Colors.red.shade800,
                        ),
                      ),
                    ),
                  const Spacer(),
                  if (state.queueInfo != null) ...[
                    Row(
                      children: [
                        const Icon(
                          Icons.shuffle,
                          size: 20,
                          color: Colors.black87,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Cola: ${state.queueInfo}',
                          style: text.titleSmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (state.spotifyLinked && state.nowPlaying != null) ...[
                    NowPlayingBar(state: state),
                    const SizedBox(height: 16),
                  ],
                  const SizedBox(height: 10),
                  // Último envío en una sola línea.
                  Text(
                    state.events.isEmpty
                        ? 'Último envío: todavía nada. Manda un video desde el teléfono.'
                        : 'Último envío · ${_hhmm(state.events.first.at)}  ${state.events.first.message}',
                    style: text.bodyMedium?.copyWith(
                      color: state.events.isEmpty
                          ? Colors.black87
                          : (state.events.first.error
                                ? Colors.red.shade800
                                : Colors.black87),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
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
                style: text.bodySmall?.copyWith(color: Colors.black87),
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
        ?.copyWith(color: Colors.black87);
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
            color: wifi == null ? Colors.red.shade800 : Colors.black87,
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
              color: Colors.blue.shade800,
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
          style: text.bodyMedium?.copyWith(color: Colors.black87),
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
    this.width,
    this.compact = false,
    this.focusNode,
  });

  final String label;
  final Widget icon;
  final VoidCallback onTap;
  final Color? color;
  final bool autofocus;

  /// Ancho fijo (fila de accesos); sin él, el tile mide lo que su contenido.
  final double? width;
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
    final label = Text(
      widget.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: Colors.white,
        // Sombra suave: el texto blanco se sigue leyendo sobre el vidrio.
        shadows: [Shadow(color: Color(0x66000000), blurRadius: 4)],
      ),
    );
    final icon = IconTheme(
      data: const IconThemeData(color: Colors.white),
      child: widget.icon,
    );
    return AnimatedScale(
      scale: _focused ? 1.06 : 1,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        // El tamaño va aquí: así el borde del vidrio queda por dentro y no
        // ensancha el tile (si no, la fila pierde un lugar).
        width: widget.width,
        height: widget.compact ? 52 : 106,
        constraints: widget.width == null
            ? const BoxConstraints(minWidth: 112, maxWidth: 240)
            : null,
        duration: const Duration(milliseconds: 120),
        decoration: glassDecoration(
          widget.color ?? homeTileColor,
          focused: _focused,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            autofocus: widget.autofocus,
            focusNode: widget.focusNode,
            borderRadius: BorderRadius.circular(20),
            onTap: widget.onTap,
            onFocusChange: (f) => setState(() => _focused = f),
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: widget.compact ? 14 : 12,
                vertical: widget.compact ? 0 : 12,
              ),
              decoration: glassHighlight(),
              child: widget.compact
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        icon,
                        const SizedBox(width: 10),
                        Flexible(child: label),
                      ],
                    )
                  // Ícono y nombre centrados en el tile, a lo ancho y a lo alto.
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [icon, const SizedBox(height: 6), label],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
