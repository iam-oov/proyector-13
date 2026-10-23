import 'dart:io';

import 'package:flutter/material.dart';

import 'identity.dart';

/// Temas del inicio. La bolita de abajo los recorre en este orden y el
/// elegido se guarda en `home_theme.txt`.
enum HomeThemeId { rosa, blanco, oscuro }

/// Colores de un tema del inicio. Va como extensión del ThemeData del inicio:
/// cada widget lo lee con [HomePalette.of].
class HomePalette extends ThemeExtension<HomePalette> {
  const HomePalette({
    required this.id,
    required this.label,
    required this.brightness,
    required this.background,
    required this.blobs,
    required this.tile,
    required this.system,
    required this.focus,
    required this.edge,
    required this.highlight,
    required this.shadow,
    required this.text,
    required this.muted,
    required this.accent,
    required this.panel,
    required this.panelOpacity,
    required this.error,
    required this.bluetooth,
    required this.swatch,
    required this.up,
    required this.down,
  });

  final HomeThemeId id;
  final String label;
  final Brightness brightness;

  /// Degradado diagonal del fondo (3 colores) y las 4 manchas difusas.
  final List<Color> background;
  final List<Color> blobs;

  /// Vidrio de las apps y de los accesos del sistema.
  final Color tile;
  final Color system;

  /// Borde del tile con el foco del control.
  final Color focus;

  /// Borde de luz del vidrio, brillo de arriba (alpha) y sombra (null = la del tinte).
  final Color edge;
  final double highlight;
  final Color? shadow;

  final Color text;
  final Color muted;

  /// Etiquetas y pastillas sobre los paneles ("SONANDO EN SPOTIFY").
  final Color accent;

  /// Vidrio de los paneles (música, cómo empezar).
  final Color panel;
  final double panelOpacity;

  final Color error;
  final Color bluetooth;

  /// Color de la bolita de temas.
  final Color swatch;

  /// Ganancia y pérdida (más oscuros en los temas claros para que se lean).
  final Color up;
  final Color down;

  /// El de siempre: rosa pastel, apps en lila y accesos en fucsia.
  static const rosa = HomePalette(
    id: HomeThemeId.rosa,
    label: 'Rosa',
    brightness: Brightness.light,
    background: [Color(0xFFFFE4F0), Color(0xFFFFD6E7), Color(0xFFF3D4F2)],
    blobs: [
      Color(0xFFFF5FA2),
      Color(0xFFB98BEA),
      Color(0xFFFF9EC7),
      Color(0xFFE88BD8),
    ],
    tile: Color(0xFF9B6BD6),
    system: Color(0xFFA8005C),
    focus: Color(0xFF4A0026),
    edge: Color(0x99FFFFFF),
    highlight: 0.32,
    shadow: null,
    text: Color(0xFF1B0A14),
    muted: Color(0xDD000000),
    accent: Color(0xFFA8005C),
    panel: Colors.white,
    panelOpacity: 0.35,
    error: Color(0xFFC62828),
    bluetooth: Color(0xFF1565C0),
    swatch: Color(0xFFFF8CC0),
    up: Color(0xFF1E8E3E),
    down: Color(0xFFD32F2F),
  );

  /// Blancos y grises perla; apps en pizarra y accesos en tinta.
  static const blanco = HomePalette(
    id: HomeThemeId.blanco,
    label: 'Blanco',
    brightness: Brightness.light,
    background: [Color(0xFFFFFFFF), Color(0xFFF6F5F8), Color(0xFFEDEBF1)],
    blobs: [
      Color(0xFFE4E1EC),
      Color(0xFFD9DCE6),
      Color(0xFFF1EEF6),
      Color(0xFFE2DDEA),
    ],
    tile: Color(0xFF4F4A63),
    system: Color(0xFF1F1B2A),
    focus: Color(0xFF000000),
    edge: Color(0xE6FFFFFF),
    highlight: 0.32,
    shadow: Color(0x261F1B2A),
    text: Color(0xFF15131A),
    muted: Color(0xFF34313D),
    accent: Color(0xFF3B3550),
    panel: Colors.white,
    panelOpacity: 0.6,
    error: Color(0xFFC62828),
    bluetooth: Color(0xFF1565C0),
    swatch: Color(0xFFF7F7F9),
    up: Color(0xFF1E8E3E),
    down: Color(0xFFD32F2F),
  );

  /// Carbón: grises grafito sin tinte, texto claro.
  static const oscuro = HomePalette(
    id: HomeThemeId.oscuro,
    label: 'Oscuro',
    brightness: Brightness.dark,
    background: [Color(0xFF1E1E21), Color(0xFF151517), Color(0xFF222225)],
    blobs: [
      Color(0xFF3A3A3F),
      Color(0xFF2F2F34),
      Color(0xFF35353A),
      Color(0xFF29292D),
    ],
    tile: Color(0xFF5C5C64),
    system: Color(0xFF4A4A52),
    focus: Color(0xFFFFFFFF),
    edge: Color(0x2EFFFFFF),
    highlight: 0.10,
    shadow: Color(0x80000000),
    text: Color(0xFFF2F2F3),
    muted: Color(0xB3FFFFFF),
    accent: Color(0xFFD6D6DA),
    panel: Colors.white,
    panelOpacity: 0.07,
    error: Color(0xFFFF6B6B),
    bluetooth: Color(0xFF82B1FF),
    swatch: Color(0xFF2B2B2E),
    up: Color(0xFF4CD964),
    down: Color(0xFFFF5A5F),
  );

  static HomePalette byId(HomeThemeId id) => switch (id) {
    HomeThemeId.rosa => rosa,
    HomeThemeId.blanco => blanco,
    HomeThemeId.oscuro => oscuro,
  };

  /// El que sigue al picar la bolita.
  HomePalette get next =>
      byId(HomeThemeId.values[(id.index + 1) % HomeThemeId.values.length]);

  /// Tema del inicio: el texto toma el color del tema.
  ThemeData get theme => ThemeData(
    brightness: brightness,
    colorSchemeSeed: tile,
    scaffoldBackgroundColor: background[1],
    useMaterial3: true,
    extensions: [this],
  );

  static HomePalette of(BuildContext context) =>
      Theme.of(context).extension<HomePalette>() ?? rosa;

  @override
  HomePalette copyWith() => this;

  @override
  HomePalette lerp(HomePalette? other, double t) =>
      other == null || t < 0.5 ? this : other;
}

Future<HomePalette> loadHomePalette() async {
  final dir = await appFilesDir();
  if (dir == null) return HomePalette.rosa;
  try {
    final name = (await File('$dir/home_theme.txt').readAsString()).trim();
    return HomePalette.byId(HomeThemeId.values.byName(name));
  } catch (_) {
    return HomePalette.rosa;
  }
}

Future<void> saveHomePalette(HomePalette p) async {
  final dir = await appFilesDir();
  if (dir == null) return;
  try {
    await File('$dir/home_theme.txt').writeAsString(p.id.name);
  } catch (_) {
    // Sin disco: el tema dura hasta que se reinicie la app.
  }
}

/// Vidrio teñido. Sin BackdropFilter a propósito: en proyectores de 1 GB el
/// desenfoque real se recalcula en cada animación de foco y se traba. Como el
/// fondo es fijo, basta con translucidez, brillo arriba, borde de luz y sombra.
BoxDecoration glassDecoration(
  HomePalette p,
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
      color: focused ? p.focus : p.edge,
      width: focused ? 3 : 1.2,
    ),
    boxShadow: [
      BoxShadow(
        color: p.shadow ?? tint.withValues(alpha: focused ? 0.45 : 0.25),
        blurRadius: focused ? 26 : 16,
        offset: const Offset(0, 8),
      ),
    ],
  );
}

/// Brillo del vidrio: luz blanca que cae desde arriba.
BoxDecoration glassHighlight(HomePalette p, {double radius = 20}) =>
    BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.center,
        colors: [
          Colors.white.withValues(alpha: p.highlight),
          Colors.white.withValues(alpha: 0),
        ],
      ),
    );
