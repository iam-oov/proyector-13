import 'package:flutter/material.dart';

import 'model.dart';
import 'screens_sheet.dart';

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
  const LiveChip(this.text, {super.key, this.on = true});

  final String text;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final c = on ? Palette.live : Palette.text3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: on ? c.withValues(alpha: 0.14) : Palette.surface,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(on: on),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c)),
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
        child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
      );
}

/// Selector de pantalla arriba de cada pestaña: solo la elegida, grande, con su
/// estado; al tocarla se abre la hoja de Pantallas para cambiar o agregar.
class ScreenRow extends StatelessWidget {
  const ScreenRow({super.key, required this.model});

  final ControlModel model;

  @override
  Widget build(BuildContext context) {
    final s = model.selectedScreen;
    final online = s == null ? null : model.isScreenOnline(s.id);
    final state = online == null ? 'revisando…' : (online ? 'en línea' : 'sin respuesta');
    final kind = s == null ? '' : (s.isTv ? 'TV · YouTube' : 'Proyector');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => showScreensSheet(context, model),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionLabel('Pantalla'),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (s != null) ...[StatusDot(on: online == true, size: 10), const SizedBox(width: 10)],
                        Flexible(
                          child: Text(s?.name ?? 'Elige una pantalla',
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.expand_more_rounded, color: Palette.text3, size: 28),
                      ],
                    ),
                    if (s != null)
                      Text('$kind · $state', style: TextStyle(fontSize: 13, color: online == false ? Palette.text3 : Palette.text2)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
