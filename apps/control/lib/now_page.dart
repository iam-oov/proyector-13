import 'package:flutter/material.dart';

import 'config.dart';
import 'model.dart';
import 'screens.dart';
import 'screens_sheet.dart';

/// Pestaña "Ahora": qué suena en Spotify y el botón de enviar.
class NowPage extends StatelessWidget {
  const NowPage({super.key, required this.model});

  final ControlModel model;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (model.screens.isEmpty) ...[
            PairCallToAction(model: model),
            const SizedBox(height: 20),
          ] else if (model.selectedScreen == null || (model.screenChecked && !model.projectorOnline)) ...[
            // Con el proyector bien basta el punto verde de arriba; aquí solo los problemas.
            ProjectorStatus(
              screen: model.selectedScreen,
              online: model.projectorOnline,
              mismatch: model.screenIdMismatch,
            ),
            const SizedBox(height: 20),
          ],
          if (!model.loggedIn && model.projectorOnline) ...[
            NowCard(model: model),
            const SizedBox(height: 20),
          ],
          if (!Config.hasSpotify)
            const Notice('Falta SPOTIFY_CLIENT_ID: compila con --dart-define-from-file=../../.env')
          else if (!model.loggedIn)
            FilledButton.icon(
              onPressed: model.busy ? null : model.login,
              icon: const Icon(Icons.music_note),
              label: const Text('Conectar Spotify'),
            )
          else ...[
            NowCard(model: model),
            const SizedBox(height: 20),
            if (!model.showingTrack && model.track != null) ...[
              SizedBox(
                height: 56,
                child: FilledButton.icon(
                  onPressed: model.busy || model.track == null || !model.projectorOnline ? null : model.send,
                  icon: model.busy
                      ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.cast),
                  label: Text(
                    model.selectedScreen == null ? 'Enviar el video' : 'Enviar el video a ${model.selectedScreen!.name}',
                    style: const TextStyle(fontSize: 16),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (!model.screenChecked && model.selectedScreen != null)
              const SizedBox.shrink() // hasta que responda la pantalla no se sabe qué switch va
            else if (model.screenSpotifyLinked) ...[
              // El proyector tiene su propia sesión: sigue la música aunque el teléfono esté guardado.
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Seguir a Spotify'),
                subtitle: const Text('El proyector cambia el video solo'),
                value: model.screenFollowing,
                onChanged: model.busy ? null : model.setScreenFollowing,
              ),
            ] else ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Seguir a Spotify'),
                subtitle: const Text('El proyector cambia el video solo (con esta app abierta)'),
                value: model.autoFollow,
                onChanged: model.setAutoFollow,
              ),
              if (model.projectorOnline)
                OutlinedButton.icon(
                  onPressed: model.busy ? null : model.linkSpotifyToScreen,
                  icon: const Icon(Icons.link),
                  label: const Text('Que el proyector siga a Spotify solo'),
                ),
            ],
          ],
          const SizedBox(height: 16),
          if (model.error != null) Notice(model.error!, error: true),
          if (model.status != null && model.error == null && !model.statusIsSend) Notice(model.status!),
          if (model.candidates.length > 1)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              shape: const Border(),
              title: Text('¿No es el video correcto? (${model.candidates.length - 1})'),
              children: [
                for (final c in model.candidates.skip(1))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: c.video.thumbnailUrl == null ? null : Image.network(c.video.thumbnailUrl!, width: 64),
                    title: Text(c.video.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(c.video.channel),
                    onTap: model.busy ? null : () => model.sendVideo(c.video),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Tarjeta para cuando no hay ninguna pantalla vinculada.
class PairCallToAction extends StatelessWidget {
  const PairCallToAction({super.key, required this.model});

  final ControlModel model;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.qr_code_2, size: 40),
                const SizedBox(width: 12),
                Expanded(child: Text('Escanea el QR del proyector', style: text.titleMedium)),
              ],
            ),
            const SizedBox(height: 8),
            Text('El proyector muestra un QR en su pantalla de inicio. Escanéalo para conectar este teléfono.',
                style: text.bodyMedium?.copyWith(color: Colors.white70)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => scanAndAddScreen(context, model),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Escanear QR'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Volumen del proyector: silenciar, −/+ y deslizador (se aplica al soltar).
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
          icon: Icon(v.muted ? Icons.volume_off : Icons.volume_up),
        ),
        IconButton(onPressed: () => widget.model.changeVolume(delta: -1), icon: const Icon(Icons.remove)),
        Expanded(
          child: Slider(
            value: value.clamp(0, v.max.toDouble()),
            max: v.max.toDouble(),
            divisions: v.max,
            label: '${value.round()}',
            onChanged: (x) => setState(() => _dragging = x),
            onChangeEnd: (x) async {
              await widget.model.changeVolume(level: x.round());
              if (mounted) setState(() => _dragging = null);
            },
          ),
        ),
        IconButton(onPressed: () => widget.model.changeVolume(delta: 1), icon: const Icon(Icons.add)),
      ],
    );
  }
}

class ProjectorStatus extends StatelessWidget {
  const ProjectorStatus({super.key, required this.screen, required this.online, required this.mismatch});

  final Screen? screen;
  final bool online;
  final bool mismatch;

  @override
  Widget build(BuildContext context) {
    final s = screen;
    final String label;
    if (s == null) {
      label = 'Sin pantalla: elige una o escanea el QR del proyector';
    } else if (mismatch) {
      label = 'Otra pantalla responde en ${s.address}: vuelve a escanear';
    } else if (online) {
      label = '${s.name} lista (${s.address})';
    } else {
      label = '${s.name} sin respuesta (${s.address})';
    }
    return Row(
      children: [
        Icon(Icons.circle, size: 12, color: online ? Colors.greenAccent : Colors.redAccent),
        const SizedBox(width: 8),
        Expanded(child: Text(label)),
      ],
    );
  }
}

/// Lo que suena y sus controles, en una sola tarjeta: una cola de playlist en
/// el proyector, la canción de Spotify (y si se ve en el proyector) o un video
/// suelto en el proyector.
class NowCard extends StatelessWidget {
  const NowCard({super.key, required this.model});

  final ControlModel model;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final mode = model.projectorMode;
    final video = model.projectorOnline ? model.screenMediaTitle : null;
    final screen = model.selectedScreen?.name ?? 'el proyector';
    final t = model.track;
    final (String label, String title, String? subtitle, String? artUrl) = switch (mode) {
      ProjectorMode.queue => (model.screenQueueInfo!, video ?? 'Buscando el video…', null, null),
      ProjectorMode.spotify => (t!.isPlaying ? 'Sonando en Spotify' : 'Spotify en pausa', t.title, t.artist, t.artUrl),
      ProjectorMode.free => (video == null ? 'Sin música' : 'En $screen', video ?? 'Nada sonando', null, null),
    };
    final fallback = switch (mode) {
      ProjectorMode.queue => Icons.queue_music,
      ProjectorMode.spotify => Icons.album,
      ProjectorMode.free => Icons.smart_display,
    };
    // Solo en modo Spotify: etiqueta a la derecha del encabezado con si el
    // proyector está mostrando la canción (verde) o no (gris).
    final live = model.showingTrack;
    final String? onScreen = mode != ProjectorMode.spotify || !model.projectorOnline
        ? null
        : live
            ? 'En $screen'
            : model.followingSpotify
                ? 'Esperando canción'
                : 'No en $screen';
    final chipColor = live ? Colors.greenAccent : Colors.white54;
    final canPlay = mode == ProjectorMode.spotify || video != null;
    final canStop = mode != ProjectorMode.free || video != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(label, style: text.labelMedium?.copyWith(color: Colors.white54))),
                if (onScreen != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: chipColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(live ? Icons.circle : Icons.cast, size: live ? 8 : 12, color: chipColor),
                        const SizedBox(width: 6),
                        Text(onScreen, style: text.labelMedium?.copyWith(color: chipColor)),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: artUrl == null
                      ? SizedBox.square(dimension: 64, child: Icon(fallback, size: 36))
                      : Image.network(artUrl, width: 64, height: 64, fit: BoxFit.cover),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: text.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                      if (subtitle != null) Text(subtitle, style: text.bodyMedium?.copyWith(color: Colors.white70)),
                    ],
                  ),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  tooltip: model.isPlaying ? 'Pausar' : 'Reanudar',
                  iconSize: 32,
                  onPressed: model.busy || !canPlay ? null : model.togglePlay,
                  icon: Icon(model.isPlaying ? Icons.pause : Icons.play_arrow),
                ),
                IconButton(
                  tooltip: 'Siguiente',
                  iconSize: 32,
                  onPressed: model.busy || mode == ProjectorMode.free ? null : model.skip,
                  icon: const Icon(Icons.skip_next),
                ),
                IconButton(
                  tooltip: 'Detener',
                  iconSize: 32,
                  onPressed: model.busy || !canStop ? null : model.stopAll,
                  icon: const Icon(Icons.stop),
                ),
              ],
            ),
            // Volumen del proyector: junto a los demás controles.
            if (model.projectorOnline && model.volume != null) VolumeControl(model: model),
          ],
        ),
      ),
    );
  }
}

class Notice extends StatelessWidget {
  const Notice(this.message, {super.key, this.error = false});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Text(message, style: TextStyle(color: error ? Colors.redAccent : Colors.white70));
  }
}
