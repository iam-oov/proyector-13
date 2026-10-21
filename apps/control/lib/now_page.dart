import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

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
          ] else ...[
            ProjectorStatus(
              screen: model.selectedScreen,
              online: model.projectorOnline,
              mismatch: model.screenIdMismatch,
            ),
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
            NowPlayingCard(track: model.track),
            const SizedBox(height: 20),
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
            if (model.screenSpotifyLinked) ...[
              // El proyector tiene su propia sesión: sigue la música aunque el teléfono esté guardado.
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Seguir a Spotify'),
                subtitle: Text('${model.selectedScreen?.name ?? 'El proyector'} cambia el video solo, '
                    'aunque guardes el teléfono'),
                value: model.screenFollowing,
                onChanged: model.busy ? null : model.setScreenFollowing,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: model.busy ? null : model.unlinkSpotifyFromScreen,
                  child: const Text('Desvincular Spotify del proyector'),
                ),
              ),
            ] else ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Seguir a Spotify'),
                subtitle: const Text('Al cambiar la canción manda el video solo (con esta app abierta)'),
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
          if (model.status != null && model.error == null) Notice(model.status!),
          if (model.candidates.length > 1) ...[
            const SizedBox(height: 24),
            Text('Otras opciones', style: Theme.of(context).textTheme.titleMedium),
            for (final c in model.candidates.skip(1))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: c.video.thumbnailUrl == null ? null : Image.network(c.video.thumbnailUrl!, width: 64),
                title: Text(c.video.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(c.video.channel),
                trailing: Text('${c.score}'),
                onTap: model.busy ? null : () => model.sendVideo(c.video),
              ),
          ],
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

class NowPlayingCard extends StatelessWidget {
  const NowPlayingCard({super.key, required this.track});

  final Track? track;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final t = track;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: t == null
            ? Text('Nada sonando en Spotify', style: text.titleMedium?.copyWith(color: Colors.white54))
            : Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: t.artUrl == null
                        ? const SizedBox.square(dimension: 72, child: Icon(Icons.album, size: 40))
                        : Image.network(t.artUrl!, width: 72, height: 72, fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.title, style: text.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                        Text(t.artist, style: text.bodyMedium?.copyWith(color: Colors.white70)),
                        if (!t.isPlaying) Text('Pausado', style: text.bodySmall?.copyWith(color: Colors.white38)),
                      ],
                    ),
                  ),
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
