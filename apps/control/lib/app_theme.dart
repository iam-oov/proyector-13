import 'package:flutter/material.dart';

import 'model.dart';
import 'screens_sheet.dart';
import 'search_page.dart';

/// Colores del rediseño "oscuro pulido" (Claude Design, dirección 1c): neutros
/// con un toque de morado, un solo acento lila y verde solo para "en vivo".
/// Salen de oklch (ver el proyecto de diseño) convertidos a sRGB.
abstract final class Palette {
  static const bg = Color(0xFF0F0F14);
  static const surface = Color(0xFF191820);
  static const surface2 = Color(0xFF23222A);
  static const line = Color(0xFF32323B);
  static const text = Color(0xFFF1F1F6);
  static const text2 = Color(0xFFB7B6BF);
  static const text3 = Color(0xFF8C8B93);
  static const accent = Color(0xFFB89EFF);
  static const onAccent = Color(0xFF171226);
  static const live = Color(0xFF63D18F);
  static const danger = Color(0xFFF47B74);
}

ThemeData appTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF7C4DFF), brightness: Brightness.dark).copyWith(
    primary: Palette.accent,
    onPrimary: Palette.onAccent,
    surface: Palette.bg,
    onSurface: Palette.text,
    onSurfaceVariant: Palette.text2,
    surfaceContainerLowest: Palette.bg,
    surfaceContainerLow: Palette.surface,
    surfaceContainer: Palette.surface,
    surfaceContainerHigh: Palette.surface2,
    surfaceContainerHighest: Palette.surface2,
    outline: Palette.line,
    outlineVariant: Palette.line,
    error: Palette.danger,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, fontFamily: 'Figtree');
  return base.copyWith(
    scaffoldBackgroundColor: Palette.bg,
    textTheme: base.textTheme.apply(bodyColor: Palette.text, displayColor: Palette.text),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Palette.surface,
      indicatorColor: Palette.accent.withValues(alpha: 0.24),
      height: 76,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontFamily: 'Figtree',
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: s.contains(WidgetState.selected) ? Palette.text : Palette.text3,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(color: s.contains(WidgetState.selected) ? Palette.accent : Palette.text3),
      ),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: Palette.accent,
      inactiveTrackColor: Palette.surface2,
      thumbColor: Palette.text,
      trackHeight: 6,
      overlayShape: RoundSliderOverlayShape(overlayRadius: 18),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Palette.accent : Palette.surface2),
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Palette.onAccent : Palette.text3),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Palette.surface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      hintStyle: const TextStyle(color: Palette.text3),
    ),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: Palette.surface, showDragHandle: true),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

/// Etiqueta de sección: "FIJADAS", "AGREGAR"…
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: Palette.text3),
      );
}

/// Chip verde de "en vivo" ("● En Sala"), o gris si [on] es falso.
class LiveChip extends StatelessWidget {
  const LiveChip(this.text, {super.key, this.on = true, this.icon});

  final String text;
  final bool on;

  /// Ícono en lugar del punto de estado (p. ej. proyectar en "En vivo").
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = on ? Palette.live : Palette.text3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: on ? c.withValues(alpha: 0.14) : Palette.surface, borderRadius: BorderRadius.circular(99)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) Icon(icon, size: 14, color: c) else StatusDot(on: on),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c),
          ),
        ],
      ),
    );
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, this.on = true, this.size = 8, this.color});

  final bool on;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color ?? (on ? Palette.live : Palette.text3)),
      );
}

/// Portada o miniatura con esquinas redondeadas; si no hay imagen, un ícono.
class Cover extends StatelessWidget {
  const Cover({super.key, required this.url, required this.width, this.height, this.radius = 12, this.icon = Icons.album_rounded});

  final String? url;
  final double width;
  final double? height;
  final double radius;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final h = height ?? width;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: url == null
          ? Container(
              width: width,
              height: h,
              color: Palette.surface2,
              child: Icon(icon, color: Palette.text3, size: (h * 0.42).clamp(18, 48)),
            )
          : Image.network(url!, width: width, height: h, fit: BoxFit.cover),
    );
  }
}

/// Contenedor de superficie con esquinas de 20.
class Tile extends StatelessWidget {
  const Tile({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.color = Palette.surface, this.onTap});

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: color,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      );
}

/// Selector de pantalla arriba de cada pestaña: solo la elegida, grande, con su
/// estado; al tocarla se abre la hoja de Pantallas para cambiar o agregar. A la
/// derecha, el + para agregar y la lupa (abre Buscar, como en YouTube).
class ScreenRow extends StatelessWidget {
  const ScreenRow({super.key, required this.model, this.inSearch = false});

  final ControlModel model;

  /// Dentro de Buscar: flecha para regresar en lugar de la lupa.
  final bool inSearch;

  @override
  Widget build(BuildContext context) {
    final s = model.selectedScreen;
    final online = s == null ? null : model.isScreenOnline(s.id);
    // Solo se avisa cuando algo no está bien: en línea ya lo dice el punto verde.
    final problem = online == null ? 'revisando…' : (online ? null : 'sin respuesta');
    final kind = s?.kindLabel ?? 'Pantalla';
    return Padding(
      padding: EdgeInsets.only(left: inSearch ? 8 : 20, right: 20),
      child: Row(
        children: [
          if (inSearch) ...[
            IconButton(
              tooltip: 'Regresar',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back_rounded, color: Palette.text, size: 26),
            ),
            const SizedBox(width: 4),
          ],
          // El nombre abre la lista para cambiar de pantalla; el + agrega otra.
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => showScreensSheet(context, model),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // El tipo arriba ("Proyector", "TV", "Roku") en lugar de "Pantalla".
                    SectionLabel(kind),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (s != null) ...[StatusDot(on: online == true, size: 10), const SizedBox(width: 10)],
                        Flexible(
                          child: Text(
                            s?.name ?? 'Elige una pantalla',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.expand_more_rounded, color: Palette.text3, size: 28),
                      ],
                    ),
                    if (s != null && problem != null)
                      Text(problem, style: const TextStyle(fontSize: 13, color: Palette.text3)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Material(
            color: Palette.surface,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => showAddScreenSheet(context, model),
              child: const Tooltip(
                message: 'Agregar pantalla',
                child: SizedBox.square(dimension: 48, child: Icon(Icons.add_rounded, color: Palette.text, size: 28)),
              ),
            ),
          ),
          // La lupa hasta la derecha, como en YouTube.
          if (!inSearch) ...[
            const SizedBox(width: 12),
            _RoundButton(
              tooltip: 'Buscar',
              icon: Icons.search_rounded,
              onTap: () => openSearch(context, model),
            ),
          ],
        ],
      ),
    );
  }
}

/// Botón redondo de la barra de arriba (lupa).
class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.tooltip, required this.icon, required this.onTap});

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Palette.surface,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Tooltip(
            message: tooltip,
            child: SizedBox.square(dimension: 48, child: Icon(icon, color: Palette.text, size: 26)),
          ),
        ),
      );
}

/// Aviso de una línea (error en rojo).
class Notice extends StatelessWidget {
  const Notice(this.message, {super.key, this.error = false});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) =>
      Text(message, style: TextStyle(fontSize: 14, height: 1.35, color: error ? Palette.danger : Palette.text2));
}
