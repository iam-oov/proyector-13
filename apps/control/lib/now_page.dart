import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_theme.dart';
import 'config.dart';
import 'model.dart';
import 'screens_sheet.dart';

/// Pestaña "Ahora" (diseño 1c, "control remoto"): fila de equipos, lo que suena,
/// botones grandes, volumen y "Seguir a Spotify".
class NowPage extends StatelessWidget {
  const NowPage({super.key, required this.model, required this.onSearch});

  final ControlModel model;

  /// Cambia a la pestaña Buscar (desde el estado "Nada sonando").
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final screen = model.selectedScreen;
        final offline = screen != null && model.screenChecked && !model.projectorOnline;
        final empty = model.projectorMode == ProjectorMode.free && (!model.projectorOnline || model.screenMediaTitle == null);
        return ListView(
          padding: const EdgeInsets.only(top: 12, bottom: 24),
          children: [
            if (model.screens.isEmpty)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: PairCallToAction(model: model))
            else
              ScreenRow(model: model),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (offline) ...[
                    Tile(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              model.rediscovering
                                  ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const StatusDot(on: false, size: 10),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  model.rediscovering
                                      ? 'Buscando a ${screen.name} en tu Wi-Fi…'
                                      : model.screenIdMismatch
                                          ? 'Otra pantalla responde en ${screen.address}: vuelve a escanear su QR'
                                          : '${screen.name} no responde en ${screen.host}. ¿Cambió de red o de IP?',
                                  style: const TextStyle(fontSize: 14, color: Palette.text2, height: 1.35),
                                ),
                              ),
                            ],
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (screen.hasReceiver)
                                TextButton(
                                  onPressed: model.rediscovering ? null : () => model.rediscover(screen.id),
                                  child: const Text('Buscar en mi Wi-Fi'),
                                ),
                              TextButton(
                                onPressed: model.rediscovering ? null : () => changeAddressDialog(context, model, screen),
                                child: const Text('Cambiar IP'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (!Config.hasSpotify)
                    const Notice('Falta SPOTIFY_CLIENT_ID: compila con --dart-define-from-file=../../.env', error: true)
                  else if (!model.loggedIn) ...[
                    _ConnectSpotify(model: model),
                    const SizedBox(height: 12),
                  ],
                  if (empty)
                    _EmptyCard(model: model, onSearch: onSearch)
                  else ...[
                    _Hero(model: model),
                    const SizedBox(height: 14),
                    _TitleBlock(model: model),
                  ],
                  const SizedBox(height: 18),
                  _Transport(model: model, dimmed: empty),
                  if (model.projectorOnline && model.volume != null) ...[
                    const SizedBox(height: 14),
                    VolumeControl(model: model),
                  ],
                  const SizedBox(height: 14),
                  _Chips(model: model, empty: empty),
                  if (model.error != null) ...[
                    const SizedBox(height: 12),
                    Notice(model.error!, error: true),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// "Nada sonando": qué hacer, en vez de una tarjeta vacía.
class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.model, required this.onSearch});

  final ControlModel model;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final screen = model.selectedScreen?.name ?? 'la pantalla';
    return Tile(
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 20),
      child: Column(
        children: [
          const Icon(Icons.music_off_rounded, size: 44, color: Palette.text3),
          const SizedBox(height: 10),
          const Text('Nada sonando', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            'Pon música en Spotify y $screen cambia el video sola, o busca un video para mandarlo.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Palette.text2, height: 1.35),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _BigButton(
                  icon: Icons.open_in_new_rounded,
                  label: 'Spotify',
                  primary: true,
                  onTap: () => launchUrl(Uri.parse('spotify:'), mode: LaunchMode.externalApplication),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: _BigButton(icon: Icons.search_rounded, label: 'Buscar', onTap: onSearch)),
            ],
          ),
        ],
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({required this.icon, required this.label, this.onTap, this.primary = false});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final fg = primary ? Palette.onAccent : Palette.text;
    return Material(
      color: primary ? Palette.accent : Palette.surface2,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: SizedBox(
          height: 52,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: fg, size: 22),
              const SizedBox(width: 8),
              Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lo que se ve en la pantalla, en 16:9: la miniatura del video mandado, la
/// portada de Spotify sobre su propio fondo difuminado, o un ícono. Encima, si
/// está en la pantalla o, si no, el botón para mandarlo.
class _Hero extends StatelessWidget {
  const _Hero({required this.model});

  final ControlModel model;

  @override
  Widget build(BuildContext context) {
    final mode = model.projectorMode;
    final video = model.projectorOnline ? model.screenMediaTitle : null;
    final screen = model.selectedScreen?.name ?? 'la pantalla';
    final t = model.track;
    final sent = model.lastSentVideo;
    // La miniatura solo si ese video es el que está sonando (si no, engañaría).
    final thumb = switch (mode) {
      ProjectorMode.spotify => t != null && model.isSentTrack(t) ? sent?.thumbnailUrl : null,
      ProjectorMode.free => sent != null && video != null && _sameTitle(sent.title, video) ? sent.thumbnailUrl : null,
      ProjectorMode.queue => null,
    };
    final art = mode == ProjectorMode.spotify ? t?.artUrl : null;
    final live = mode == ProjectorMode.spotify ? model.showingTrack : video != null;
    final sendable = mode == ProjectorMode.spotify && model.loggedIn && t != null && !model.showingTrack && model.projectorOnline;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _HeroImage(thumb: thumb, art: art, icon: mode == ProjectorMode.queue ? Icons.queue_music_rounded : Icons.smart_display_rounded),
            if (sendable) ...[
              ColoredBox(color: Palette.bg.withValues(alpha: 0.62)),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('No está en $screen', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: model.busy ? null : model.send,
                    icon: model.busy
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.cast_rounded, size: 20),
                    label: const Text('Enviar el video', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ] else if (model.projectorOnline)
              Positioned(
                left: 12,
                top: 12,
                child: DecoratedBox(
                  // Fondo oscuro para que el chip se lea sobre cualquier imagen.
                  decoration: BoxDecoration(color: Palette.bg.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(99)),
                  child: LiveChip(
                    live ? 'En vivo' : (mode == ProjectorMode.spotify && model.followingSpotify ? 'Esperando canción' : 'No en $screen'),
                    on: live,
                    icon: live ? Icons.cast_rounded : null,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// El título de la sesión de medios de YouTube casi siempre es el del video;
  /// basta con que empiecen igual.
  static bool _sameTitle(String a, String b) {
    String norm(String x) => x.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final na = norm(a), nb = norm(b);
    final n = [na.length, nb.length, 16].reduce((x, y) => x < y ? x : y);
    return n > 0 && na.substring(0, n) == nb.substring(0, n);
  }
}

class _HeroImage extends StatelessWidget {
  const _HeroImage({required this.thumb, required this.art, required this.icon});

  final String? thumb;
  final String? art;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    Widget placeholder() => ColoredBox(color: Palette.surface2, child: Icon(icon, size: 48, color: Palette.text3));
    final t = thumb, a = art;
    if (t != null) return Image.network(t, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder());
    if (a == null) return placeholder();
    // Portada cuadrada: ella misma, difuminada, de fondo.
    return Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Image.network(a, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder()),
        ),
        ColoredBox(color: Palette.bg.withValues(alpha: 0.35)),
        Center(
          child: FractionallySizedBox(
            heightFactor: 0.78,
            child: AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(a, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder()),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Título y artista (o la cola) centrados debajo de la imagen.
class _TitleBlock extends StatelessWidget {
  const _TitleBlock({required this.model});

  final ControlModel model;

  @override
  Widget build(BuildContext context) {
    final video = model.projectorOnline ? model.screenMediaTitle : null;
    final screen = model.selectedScreen?.name ?? 'la pantalla';
    final t = model.track;
    final (String title, String? subtitle) = switch (model.projectorMode) {
      ProjectorMode.queue => (video ?? 'Buscando el video…', model.screenQueueInfo),
      ProjectorMode.spotify => (t!.title, t.artist),
      ProjectorMode.free => (video ?? 'Nada sonando', 'En $screen'),
    };
    return Column(
      children: [
        Text(title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, height: 1.2)),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(subtitle,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, color: Palette.text2)),
        ],
      ],
    );
  }
}

/// Detener · pausar/reanudar · siguiente, en una fila de botones redondos.
class _Transport extends StatelessWidget {
  const _Transport({required this.model, required this.dimmed});

  final ControlModel model;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final mode = model.projectorMode;
    final video = model.projectorOnline ? model.screenMediaTitle : null;
    final canPlay = !model.busy && (mode == ProjectorMode.spotify || video != null);
    final canSkip = !model.busy && mode != ProjectorMode.free;
    final canStop = !model.busy && (mode != ProjectorMode.free || video != null);
    final playing = model.isPlaying;
    return Opacity(
      opacity: dimmed ? 0.4 : 1,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _Round(icon: Icons.stop_rounded, tooltip: 'Detener', onTap: canStop ? model.stopAll : null),
          const SizedBox(width: 28),
          _Round(
            icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            tooltip: playing ? 'Pausar' : 'Reanudar',
            size: 76,
            iconSize: 42,
            primary: true,
            onTap: canPlay ? model.togglePlay : null,
          ),
          const SizedBox(width: 28),
          _Round(icon: Icons.skip_next_rounded, tooltip: 'Siguiente', onTap: canSkip ? model.skip : null),
        ],
      ),
    );
  }
}

class _Round extends StatelessWidget {
  const _Round({required this.icon, required this.tooltip, this.onTap, this.size = 52, this.iconSize = 30, this.primary = false});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final fg = onTap == null ? Palette.text3 : (primary ? Palette.onAccent : Palette.text);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: primary ? Palette.accent : Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox.square(dimension: size, child: Icon(icon, size: iconSize, color: fg)),
        ),
      ),
    );
  }
}

/// Volumen en una línea: bocina (silenciar) / deslizador (se aplica al soltar) / nivel.
class VolumeControl extends StatefulWidget {
  const VolumeControl({super.key, required this.model});

  final ControlModel model;

  @override
  State<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<VolumeControl> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final v = widget.model.volume!;
    final value = _dragging ?? v.level.toDouble();
    return Row(
      children: [
        IconButton(
          tooltip: v.muted ? 'Quitar silencio' : 'Silenciar',
          onPressed: () => widget.model.changeVolume(mute: !v.muted),
          icon: Icon(v.muted ? Icons.volume_off_rounded : Icons.volume_mute_rounded, size: 22, color: Palette.text3),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(0, v.max.toDouble()),
            max: v.max.toDouble(),
            divisions: v.max,
            onChanged: (x) => setState(() => _dragging = x),
            onChangeEnd: (x) async {
              await widget.model.changeVolume(level: x.round());
              if (mounted) setState(() => _dragging = null);
            },
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(v.muted ? '—' : '${value.round()}',
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Palette.text2)),
        ),
      ],
    );
  }
}

/// Chips debajo de los controles: "Seguir a Spotify" (prendido/apagado) y
/// "Otro video", que abre las otras opciones de YouTube.
class _Chips extends StatelessWidget {
  const _Chips({required this.model, required this.empty});

  final ControlModel model;
  final bool empty;

  @override
  Widget build(BuildContext context) {
    final screen = model.selectedScreen;
    final canFollow = model.loggedIn && (model.screenChecked || screen == null);
    final own = model.screenSpotifyLinked;
    final following = own ? model.screenFollowing : model.autoFollow;
    final others = empty ? 0 : model.candidates.length - 1;
    if (!canFollow && others <= 0) return const SizedBox.shrink();
    return Column(
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 10,
          children: [
            if (canFollow)
              _ChipButton(
                icon: Icons.sync_rounded,
                label: following ? 'Siguiendo Spotify' : 'Seguir a Spotify',
                // Sin sesión propia, el que cambia el video es este teléfono.
                detail: own ? null : 'con esta app abierta',
                on: following,
                onTap: own
                    ? (model.busy ? null : () => model.setScreenFollowing(!following))
                    : () => model.setAutoFollow(!following),
              ),
            if (others > 0)
              _ChipButton(icon: Icons.video_library_outlined, label: 'Otro video ($others)', onTap: () => _showOtherVideos(context, model)),
          ],
        ),
        // Un proyector con receptor puede seguir a Spotify por su cuenta; la TV no.
        // Botón con borde (como "Quitar del video" en Trading): antes era texto y no parecía botón.
        if (canFollow && !own && model.projectorOnline && (screen?.hasReceiver ?? false)) ...[
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: model.busy ? null : model.linkSpotifyToScreen,
              icon: const Icon(Icons.link_rounded, size: 20),
              label: const Text(
                'Que el proyector siga a Spotify aunque guardes el teléfono',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ChipButton extends StatelessWidget {
  const _ChipButton({required this.icon, required this.label, this.detail, this.onTap, this.on = false});

  final IconData icon;
  final String label;

  /// Segunda línea chica debajo de [label].
  final String? detail;
  final VoidCallback? onTap;
  final bool on;

  @override
  Widget build(BuildContext context) {
    // Verde "en vivo", como el chip "En <pantalla>": está haciendo algo.
    final fg = on ? Palette.live : Palette.text2;
    return Material(
      color: on ? Palette.live.withValues(alpha: 0.16) : Palette.surface,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Container(
          // Misma altura con o sin segunda línea.
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: fg)),
                  if (detail != null)
                    Text(detail!, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: fg.withValues(alpha: 0.75))),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "¿No es el video correcto?": las otras opciones de YouTube en una hoja.
Future<void> _showOtherVideos(BuildContext context, ControlModel model) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            children: [
              const Text('¿No es el video correcto?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              for (final c in model.candidates.skip(1))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Cover(url: c.video.thumbnailUrl, width: 96, height: 54, radius: 10, icon: Icons.smart_display_rounded),
                  title: Text(c.video.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(c.video.channel, style: const TextStyle(color: Palette.text2)),
                  onTap: () {
                    Navigator.of(context).pop();
                    model.sendVideo(c.video);
                  },
                ),
            ],
          ),
        ),
      ),
    );

class _ConnectSpotify extends StatelessWidget {
  const _ConnectSpotify({required this.model});

  final ControlModel model;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 52,
        child: FilledButton.icon(
          onPressed: model.busy ? null : model.login,
          icon: const Icon(Icons.music_note_rounded),
          label: const Text('Conectar Spotify', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
        ),
      );
}

/// Para cuando no hay ninguna pantalla vinculada.
class PairCallToAction extends StatelessWidget {
  const PairCallToAction({super.key, required this.model});

  final ControlModel model;

  @override
  Widget build(BuildContext context) {
    return Tile(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.qr_code_2_rounded, size: 40, color: Palette.accent),
              SizedBox(width: 12),
              Expanded(child: Text('Escanea el QR del proyector', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
            ],
          ),
          const SizedBox(height: 8),
          const Text('El proyector muestra un QR en "Vincular teléfono". Escanéalo para conectar este teléfono; '
              'para una TV sin receptor, agrégala por su IP.',
              style: TextStyle(fontSize: 14, color: Palette.text2, height: 1.35)),
          const SizedBox(height: 16),
          SizedBox(
            height: 52,
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => scanAndAddScreen(context, model),
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: const Text('Escanear QR', style: TextStyle(fontWeight: FontWeight.w700)),
              style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
            ),
          ),
          TextButton(onPressed: () => showAddScreenSheet(context, model), child: const Text('Más opciones')),
        ],
      ),
    );
  }
}
