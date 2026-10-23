import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'apps.dart';
import 'dollar.dart';
import 'identity.dart';
import 'state.dart';
import 'home_theme.dart';
import 'trading_dashboard.dart';
import 'weather.dart';

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

/// Si el inicio muestra las acciones (botón de trading). Se guarda en
/// `home_trading.txt`; prendido mientras no se apague.
Future<bool> loadHomeTrading() async {
  final dir = await appFilesDir();
  if (dir == null) return true;
  try {
    return (await File('$dir/home_trading.txt').readAsString()).trim() != 'off';
  } catch (_) {
    return true;
  }
}

Future<void> saveHomeTrading(bool on) async {
  final dir = await appFilesDir();
  if (dir == null) return;
  try {
    await File('$dir/home_trading.txt').writeAsString(on ? 'on' : 'off');
  } catch (_) {
    // Sin disco: dura hasta que se reinicie la app.
  }
}

/// Panel de vidrio del tema (música, cómo empezar).
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final p = HomePalette.of(context);
    return DecoratedBox(
      decoration: glassDecoration(p, p.panel, opacity: p.panelOpacity),
      child: DecoratedBox(
        decoration: glassHighlight(p),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Fondo del inicio: degradado del tema con manchas grandes y difusas que se
/// ven a través del vidrio. Es fijo: se pinta una vez por tema.
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
  Widget build(BuildContext context) {
    final p = HomePalette.of(context);
    return Stack(
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
                        colors: p.background,
                      ),
                    ),
                  ),
                ),
                Positioned(left: -140, top: -160, child: _blob(p.blobs[0], 560)),
                Positioned(
                  right: -180,
                  bottom: -220,
                  child: _blob(p.blobs[1], 640),
                ),
                Positioned(right: 260, top: 120, child: _blob(p.blobs[2], 420)),
                Positioned(
                  left: 180,
                  bottom: -160,
                  child: _blob(p.blobs[3], 380),
                ),
              ],
            ),
          ),
        ),
        child,
      ],
    );
  }
}


/// Pantalla de inicio del proyector, navegable con el control. Arriba título,
/// fecha, hora y clima; al centro las acciones (o la música si no hay
/// trading); una fila de apps que se desplaza a lo ancho; abajo los accesos
/// del sistema, el último envío y la conexión. Todo cabe en la pantalla: nada
/// empuja nada hacia abajo.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.state});

  final ReceiverState state;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// Lo último que mostró el inicio. Al volver del QR el inicio se crea de nuevo:
/// arranca con esto (no con los valores por defecto) mientras relee del disco,
/// así no parpadea el tema, la fila de apps ni el trading.
class _HomeMemory {
  static List<TvApp> apps = [];
  static String title = householdTitle;
  static HomePalette palette = HomePalette.rosa;
  static bool showTrading = true;
  static AppActivity? vendorSettings;
  static AppActivity? androidSettings;
}

class _HomeScreenState extends State<HomeScreen> {
  List<TvApp> _apps = _HomeMemory.apps;
  String _title = _HomeMemory.title;
  HomePalette _palette = _HomeMemory.palette;
  bool _showTrading = _HomeMemory.showTrading;
  // Accesos de ajustes que existen en este equipo (cambian según el fabricante).
  AppActivity? _vendorSettings = _HomeMemory.vendorSettings;
  AppActivity? _androidSettings = _HomeMemory.androidSettings;
  String? _error;
  // Al volver al inicio se relee la lista: así aparecen las apps recién instaladas.
  late final _lifecycle = AppLifecycleListener(onResume: _load);
  final _firstApp = FocusNode();

  @override
  void initState() {
    super.initState();
    _lifecycle;
    // De regreso (las apps ya estaban en memoria): el foco va a la primera.
    if (_apps.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _firstApp.requestFocus(),
      );
    }
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
      final palette = await loadHomePalette();
      final showTrading = await loadHomeTrading();
      final all = await installedApps();
      // Si el fabricante pone sus ajustes como app (com.android.tv.settings en el
      // Rockchip), van a la fila de accesos y no se repiten en la de apps.
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
        _title = _HomeMemory.title = title;
        _palette = _HomeMemory.palette = palette;
        _showTrading = _HomeMemory.showTrading = showTrading;
        _apps = _HomeMemory.apps = apps;
        _vendorSettings = _HomeMemory.vendorSettings = vendor;
        _androidSettings = _HomeMemory.androidSettings = android;
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

  /// La bolita de temas: rosa → blanco → oscuro → rosa.
  /// El botón de trading: muestra u oculta las acciones del inicio.
  void _toggleTrading() {
    setState(() => _showTrading = _HomeMemory.showTrading = !_showTrading);
    unawaited(saveHomeTrading(_showTrading));
  }

  void _nextTheme() {
    setState(() => _palette = _HomeMemory.palette = _palette.next);
    unawaited(saveHomePalette(_palette));
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
    // Tamaños del tema de la app (el del inicio solo trae colores) con los
    // colores del tema elegido.
    final text = Theme.of(context).textTheme.merge(_palette.theme.textTheme);
    return Theme(
      data: _palette.theme,
      child: Scaffold(
        body: HomeBackdrop(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(26, 18, 26, 18),
            child: ListenableBuilder(
              listenable: state,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _topBar(text),
                  const SizedBox(height: 14),
                  Expanded(child: _hero(state)),
                  const SizedBox(height: 14),
                  _appsRow(text),
                  const SizedBox(height: 10),
                  _bottomRow(state),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar(TextTheme text) => Row(
    children: [
      Expanded(
        child: Text(
          _title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      const DollarText(),
      const SizedBox(width: 20),
      const WeatherText(),
      const SizedBox(width: 20),
      const ClockText(),
    ],
  );

  /// Lo principal: las acciones con Spotify al lado; si falta una, la otra
  /// ocupa todo; sin ninguna, cómo empezar.
  Widget _hero(ReceiverState state) {
    final trading = _showTrading && state.trades.isNotEmpty;
    final music =
        (state.spotifyLinked && state.nowPlaying != null) ||
        state.queueInfo != null;
    final stats = TradingStats(state: state);
    if (trading && music) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: stats),
          // Sin fondos, una línea separa las acciones de la música.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: VerticalDivider(
              width: 1,
              thickness: 1,
              color: _palette.muted.withValues(alpha: 0.25),
            ),
          ),
          SizedBox(width: 190, child: MusicCard(state: state)),
        ],
      );
    }
    if (trading) return stats;
    if (music) return MusicCard(state: state, large: true);
    return IdleCard(state: state);
  }

  /// Una sola fila de apps; si no caben, se desplaza a lo ancho con el control
  /// (el foco lleva el scroll) y la última se ve cortada en la orilla.
  Widget _appsRow(TextTheme text) {
    if (_apps.isEmpty) {
      return SizedBox(
        height: AppTile.height,
        child: Center(
          child: Text(
            _error ?? 'Buscando apps…',
            style: text.bodyMedium?.copyWith(
              color: _error == null ? _palette.muted : _palette.error,
            ),
          ),
        ),
      );
    }
    return SizedBox(
      // Aire arriba y abajo para el tile con foco (crece 8%).
      height: AppTile.height + 12,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        clipBehavior: Clip.none,
        itemCount: _apps.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final app = _apps[i];
          return AppTile(
            app: app,
            focusNode: i == 0 ? _firstApp : null,
            onTap: () => _open(() => launchPackage(app.package)),
          );
        },
      ),
    );
  }

  Widget _bottomRow(ReceiverState state) {
    const gap = 10.0;
    final vendor = _vendorSettings;
    final android = _androidSettings;
    return Row(
      children: [
        // Trading: con el aro verde cuando está prendido.
        RevealButton(
          label: _showTrading ? 'Trading ON' : 'Trading OFF',
          icon: Icons.show_chart,
          color: _palette.system,
          active: _showTrading,
          onTap: _toggleTrading,
        ),
        const SizedBox(width: gap),
        RevealButton(
          label: 'Vincular teléfono',
          icon: Icons.qr_code_2,
          color: _palette.system,
          autofocus: _apps.isEmpty,
          onTap: () => state.showPanel(ReceiverPanel.qr),
        ),
        // Los del fabricante: trapezoide, modo de proyección, imagen, sonido, red.
        if (vendor != null) ...[
          const SizedBox(width: gap),
          RevealButton(
            label: 'Ajustes',
            icon: Icons.settings,
            color: _palette.system,
            onTap: () => _open(
              () => launchComponent(vendor.package, vendor.activity),
            ),
          ),
        ],
        // Los de Android TV: apps, cuentas, mandos, redes.
        if (android != null) ...[
          const SizedBox(width: gap),
          RevealButton(
            label: 'Ajustes Android',
            icon: Icons.tune,
            color: _palette.system,
            onTap: () => _open(
              () => launchComponent(android.package, android.activity),
            ),
          ),
        ],
        const SizedBox(width: gap),
        // Temas: la bolita es del color del tema actual.
        RevealButton(
          label: 'Tema ${_palette.label.toLowerCase()}',
          color: _palette.swatch,
          onTap: _nextTheme,
        ),
        const Spacer(),
        const ConnectivityRow(),
      ],
    );
  }
}

/// Lo que suena en Spotify (lo lee el propio proyector) con la cola; si solo
/// hay cola, la cola. `large` cuando ocupa el centro (no hay trading).
class MusicCard extends StatelessWidget {
  const MusicCard({super.key, required this.state, this.large = false});

  final ReceiverState state;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final t = state.spotifyLinked ? state.nowPlaying : null;
    final queue = state.queueInfo;
    final text = Theme.of(context).textTheme;
    final p = HomePalette.of(context);
    final accent = p.accent;
    final label = t == null
        ? 'Cola'
        : large
        ? '${t.isPlaying ? 'Sonando' : 'En pausa'} en Spotify'
        : (t.isPlaying ? 'Spotify' : 'Spotify · pausa');
    final pills = [
      if (t != null)
        state.spotifyFollowing
            ? 'El video sigue a la música'
            : 'Seguimiento apagado',
      if (queue != null && t != null) 'Cola · $queue',
    ];
    // Sin fondo propio, como las acciones: directo sobre el fondo del inicio.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: LayoutBuilder(
        builder: (context, box) {
          // La portada se achica si la pantalla es baja.
          final art = large
              ? (box.maxHeight - 8).clamp(64.0, 176.0)
              : (box.maxHeight - 120).clamp(48.0, 84.0);
          final cover = ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox.square(
              dimension: art,
              child: t?.artUrl == null
                  ? ColoredBox(
                      color: Colors.white.withValues(alpha: 0.4),
                      child: Icon(
                        t == null ? Icons.queue_music : Icons.album,
                        size: art * 0.45,
                        color: accent,
                      ),
                    )
                  : Image.network(t!.artUrl!, fit: BoxFit.cover),
            ),
          );
          final heading = Row(
            children: [
              Icon(
                t == null ? Icons.shuffle : Icons.graphic_eq,
                size: 16,
                color: accent,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelMedium?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ],
          );
          final titles = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                t?.title ?? queue ?? '',
                maxLines: large ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: (large ? text.headlineMedium : text.titleMedium)
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (t != null)
                Text(
                  t.album == null || !large
                      ? t.artist
                      : '${t.artist} · ${t.album}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: (large ? text.titleMedium : text.bodyMedium)
                      ?.copyWith(color: p.muted),
                ),
            ],
          );
          final chips = Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final p in pills) _Pill(p)],
          );
          if (large) {
            return Row(
              children: [
                cover,
                const SizedBox(width: 22),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      heading,
                      const SizedBox(height: 8),
                      titles,
                      if (pills.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        chips,
                      ],
                    ],
                  ),
                ),
              ],
            );
          }
          // Angosta (al lado de las acciones): portada a todo el ancho con
          // alto fijo (recortada) y los textos justo debajo.
          final note = t == null
              ? null
              : (queue != null
                    ? 'Cola · $queue'
                    : (state.spotifyFollowing ? null : 'Seguimiento apagado'));
          final coverHeight = (box.maxHeight - (note == null ? 82 : 100))
              .clamp(40.0, 96.0);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading,
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: double.infinity,
                  height: coverHeight,
                  child: t?.artUrl == null
                      ? ColoredBox(
                          color: Colors.white.withValues(alpha: 0.4),
                          child: Icon(
                            t == null ? Icons.queue_music : Icons.album,
                            size: coverHeight * 0.5,
                            color: accent,
                          ),
                        )
                      : Image.network(t!.artUrl!, fit: BoxFit.cover),
                ),
              ),
              const SizedBox(height: 10),
              titles,
              if (note != null)
                Text(
                  note,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: p.muted),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final p = HomePalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: p.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: p.accent,
        ),
      ),
    );
  }
}

/// Sin trading ni música: cómo empezar.
class IdleCard extends StatelessWidget {
  const IdleCard({super.key, required this.state});

  final ReceiverState state;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = HomePalette.of(context);
    return GlassPanel(
      padding: const EdgeInsets.all(24),
      child: Row(
        children: [
          Icon(Icons.cast_rounded, size: 56, color: p.accent),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Manda un video o pon música desde el teléfono',
                  style: text.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  state.phones.isEmpty
                      ? 'Primero vincula el teléfono con el código QR (abajo, "Vincular teléfono").'
                      : 'En la app de control: Buscar, Playlists o Seguir a Spotify.',
                  style: text.titleMedium?.copyWith(color: p.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Wi-Fi (nombre) y Bluetooth conectados; cada 10 s. Sin Wi-Fi, en rojo.
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
    final p = HomePalette.of(context);
    final style = Theme.of(context).textTheme.bodyMedium
        ?.copyWith(color: p.muted);
    final wifi = _wifi;
    final level = (wifi?['level'] as num?)?.toInt() ?? 0;
    return Row(
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
                ][level.clamp(0, 4)],
          size: 18,
          color: wifi == null ? p.error : p.muted,
        ),
        const SizedBox(width: 4),
        Text(
          wifi == null ? 'Sin Wi-Fi' : '${wifi['ssid'] ?? 'Wi-Fi'}',
          style: wifi == null
              ? style?.copyWith(color: p.error)
              : style,
        ),
        for (final d in _bt) ...[
          const SizedBox(width: 14),
          Icon(
            d['kind'] == 'audio' ? Icons.headphones : Icons.bluetooth_connected,
            size: 18,
            color: p.bluetooth,
          ),
          const SizedBox(width: 4),
          Text('${d['name']}', style: style),
        ],
      ],
    );
  }
}

/// "Jueves 22 de octubre  11:46" del tamaño del clima, cada 15 s.
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
      'Lunes',
      'Martes',
      'Miércoles',
      'Jueves',
      'Viernes',
      'Sábado',
      'Domingo',
    ];
    const months = [
      'enero',
      'febrero',
      'marzo',
      'abril',
      'mayo',
      'junio',
      'julio',
      'agosto',
      'septiembre',
      'octubre',
      'noviembre',
      'diciembre',
    ];
    final p = HomePalette.of(context);
    final style = Theme.of(context).textTheme.titleMedium;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${days[now.weekday - 1]} ${now.day} de ${months[now.month - 1]}',
          style: style?.copyWith(color: p.muted),
        ),
        const SizedBox(width: 12),
        Text(
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
          style: style?.copyWith(color: p.text, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

/// App de la fila: rectángulo 16:9 con el banner de TV de la app a todo el
/// tile, sin nombre (queda para los lectores de pantalla). Con foco crece y
/// se marca el borde.
class AppTile extends StatefulWidget {
  const AppTile({
    super.key,
    required this.app,
    required this.onTap,
    this.focusNode,
  });

  /// Rectángulo 16:9, como los banners de Android TV.
  static const height = 96.0;
  static const width = height * 16 / 9;

  final TvApp app;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  State<AppTile> createState() => _AppTileState();
}

class _AppTileState extends State<AppTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final banner = widget.app.banner;
    final icon = widget.app.icon;
    final p = HomePalette.of(context);
    return Semantics(
      label: widget.app.label,
      button: true,
      child: AnimatedScale(
        scale: _focused ? 1.08 : 1,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          width: AppTile.width,
          height: AppTile.height,
          duration: const Duration(milliseconds: 120),
          decoration: glassDecoration(p, p.tile, focused: _focused),
          // El borde va encima del ícono: con foco se marca aunque el ícono
          // llene el tile.
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: _focused ? p.focus : p.edge,
              width: _focused ? 3 : 1.2,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // El banner llena el tile; sin banner, el ícono al centro del vidrio.
              if (banner != null)
                Image.memory(
                  banner,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                )
              else if (icon != null)
                Center(
                  child: Image.memory(
                    icon,
                    width: 64,
                    height: 64,
                    filterQuality: FilterQuality.medium,
                  ),
                )
              else
                const Icon(Icons.apps, size: 44, color: Colors.white),
              Material(
                type: MaterialType.transparency,
                child: InkWell(
                  focusNode: widget.focusNode,
                  onTap: widget.onTap,
                  onFocusChange: (f) => setState(() => _focused = f),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Botón redondo del inicio (Vincular, Ajustes, Temas): una bolita de vidrio
/// con su ícono; con el foco (o el mouse encima) crece y aparece su nombre al
/// lado. Sin ícono es la bolita de temas, del color del tema actual.
class RevealButton extends StatefulWidget {
  const RevealButton({
    super.key,
    required this.label,
    required this.color,
    required this.onTap,
    this.icon,
    this.autofocus = false,
    this.active,
  });

  final String label;
  final Color color;
  final IconData? icon;
  final VoidCallback onTap;
  final bool autofocus;

  /// Botón de prender/apagar algo: `true` lo resalta con un aro verde que
  /// brilla; null si no es de ese tipo.
  final bool? active;

  @override
  State<RevealButton> createState() => _RevealButtonState();
}

class _RevealButtonState extends State<RevealButton> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = HomePalette.of(context);
    final on = _focused || _hovered;
    final lit = widget.active == true;
    return Semantics(
      label: widget.label,
      button: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          autofocus: widget.autofocus,
          customBorder: const StadiumBorder(),
          onTap: widget.onTap,
          onFocusChange: (f) => setState(() => _focused = f),
          onHover: (h) => setState(() => _hovered = h),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedScale(
                  scale: on ? 1.1 : 1,
                  duration: const Duration(milliseconds: 120),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      // Brillo arriba, como el vidrio de los tiles.
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color.lerp(widget.color, Colors.white, 0.35)!,
                          widget.color,
                        ],
                      ),
                      border: Border.all(
                        color: on
                            ? p.focus
                            : (lit ? p.up : p.muted.withValues(alpha: 0.35)),
                        width: on ? 3 : (lit ? 2.5 : 1.5),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                        if (lit)
                          BoxShadow(
                            color: p.up.withValues(alpha: 0.55),
                            blurRadius: 14,
                            spreadRadius: 1,
                          ),
                      ],
                    ),
                    child: widget.icon == null
                        ? null
                        : Icon(widget.icon, size: 22, color: Colors.white),
                  ),
                ),
                if (on) ...[
                  const SizedBox(width: 8),
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: p.text,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
