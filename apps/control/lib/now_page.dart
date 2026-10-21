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
                              if (!screen.isTv)
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
                  else
                    _NowRow(model: model),
                  const SizedBox(height: 12),
                  if (!empty && model.loggedIn && model.track != null && !model.showingTrack && model.projectorOnline) ...[
                    SizedBox(
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: model.busy ? null : model.send,
                        icon: model.busy
                            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.cast_rounded),
                        label: Text('Enviar el video a ${screen?.name ?? 'la pantalla'}',
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                        style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  _Controls(model: model, dimmed: empty),
                  if (model.projectorOnline && model.volume != null) ...[
                    const SizedBox(height: 12),
                    VolumeControl(model: model),
                  ],
                  const SizedBox(height: 12),
                  _FollowTile(model: model),
                  if (model.error != null) ...[
                    const SizedBox(height: 12),
                    Notice(model.error!, error: true),
                  ] else if (model.status != null && !model.statusIsSend) ...[
                    const SizedBox(height: 12),
                    Notice(model.status!),
                  ],
                  if (model.candidates.length > 1 && !empty)
                    Theme(
                      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: EdgeInsets.zero,
                        title: Text('¿No es el video correcto? (${model.candidates.length - 1})',
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                        children: [
                          for (final c in model.candidates.skip(1))
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Cover(url: c.video.thumbnailUrl, width: 96, height: 54, radius: 10, icon: Icons.smart_display_rounded),
                              title: Text(c.video.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                              subtitle: Text(c.video.channel, style: const TextStyle(color: Palette.text2)),
                              onTap: model.busy ? null : () => model.sendVideo(c.video),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Lo que suena, compacto: portada, título, artista y si se ve en la pantalla.
class _NowRow extends StatelessWidget {
  const _NowRow({required this.model});

  final ControlModel model;

  @override
  Widget build(BuildContext context) {
    final mode = model.projectorMode;
    final video = model.projectorOnline ? model.screenMediaTitle : null;
    final screen = model.selectedScreen?.name ?? 'la pantalla';
    final t = model.track;
    final (String title, String? subtitle, String? art) = switch (mode) {
      ProjectorMode.queue => (video ?? 'Buscando el video…', model.screenQueueInfo, null),
      ProjectorMode.spotify => (t!.title, t.artist, t.artUrl),
      ProjectorMode.free => (video ?? 'Nada sonando', 'En $screen', null),
    };
    final live = mode == ProjectorMode.spotify ? model.showingTrack : video != null;
    return Tile(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Cover(url: art, width: 60, icon: mode == ProjectorMode.queue ? Icons.queue_music_rounded : Icons.album_rounded),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, height: 1.2)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, color: Palette.text2)),
                ],
                if (mode == ProjectorMode.spotify && model.projectorOnline) ...[
                  const SizedBox(height: 6),
                  LiveChip(
                    live ? 'En $screen' : (model.followingSpotify ? 'Esperando canción' : 'No en $screen'),
                    on: live,
                  ),
                ],
              ],
            ),
          ),
          if (mode != ProjectorMode.spotify) ...[
            const SizedBox(width: 10),
            StatusDot(on: live, size: 10),
          ],
        ],
      ),
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

/// Botones grandes: pausar/reanudar arriba a todo lo ancho; siguiente y detener abajo.
class _Controls extends StatelessWidget {
  const _Controls({required this.model, required this.dimmed});

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!dimmed) ...[
            _Pad(
              height: 150,
              primary: true,
              icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              iconSize: 56,
              label: playing ? 'Pausar' : 'Reanudar',
              onTap: canPlay ? model.togglePlay : null,
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Expanded(
                child: dimmed
                    ? _Pad(height: 96, icon: Icons.play_arrow_rounded, label: 'Reanudar', onTap: canPlay ? model.togglePlay : null)
                    : _Pad(height: 96, icon: Icons.skip_next_rounded, label: 'Siguiente', onTap: canSkip ? model.skip : null),
              ),
              const SizedBox(width: 12),
              Expanded(child: _Pad(height: 96, icon: Icons.stop_rounded, label: 'Detener', onTap: canStop ? model.stopAll : null)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Pad extends StatelessWidget {
  const _Pad({required this.height, required this.icon, required this.label, this.onTap, this.primary = false, this.iconSize = 32});

  final double height;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final fg = primary ? Palette.onAccent : Palette.text2;
    return Material(
      color: primary ? Palette.accent : Palette.surface,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: SizedBox(
          height: height,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: iconSize, color: primary ? fg : Palette.text),
              const SizedBox(height: 6),
              Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Volumen: − / deslizador (se aplica al soltar) / +, y silenciar tocando la bocina.
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
    Widget round(IconData icon, VoidCallback onTap) => Material(
          color: Palette.surface2,
          shape: const CircleBorder(),
          child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: SizedBox.square(dimension: 44, child: Icon(icon, color: Palette.text))),
        );
    return Tile(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Row(
        children: [
          round(Icons.remove_rounded, () => widget.model.changeVolume(delta: -1)),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => widget.model.changeVolume(mute: !v.muted),
                        child: Row(
                          children: [
                            Icon(v.muted ? Icons.volume_off_rounded : Icons.volume_up_rounded, size: 18, color: Palette.text3),
                            const SizedBox(width: 6),
                            SectionLabel(widget.model.selectedScreen?.isTv ?? false ? 'Volumen de YouTube' : 'Volumen'),
                          ],
                        ),
                      ),
                      const Spacer(),
                      Text(v.muted ? 'silencio' : '${value.round()}',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Palette.text2)),
                    ],
                  ),
                ),
                Slider(
                  value: value.clamp(0, v.max.toDouble()),
                  max: v.max.toDouble(),
                  divisions: v.max,
                  onChanged: (x) => setState(() => _dragging = x),
                  onChangeEnd: (x) async {
                    await widget.model.changeVolume(level: x.round());
                    if (mounted) setState(() => _dragging = null);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          round(Icons.add_rounded, () => widget.model.changeVolume(delta: 1)),
        ],
      ),
    );
  }
}

/// "Seguir a Spotify": el proyector con sesión propia lo hace solo; si no, el
/// teléfono con la app abierta.
class _FollowTile extends StatelessWidget {
  const _FollowTile({required this.model});

  final ControlModel model;

  @override
  Widget build(BuildContext context) {
    final screen = model.selectedScreen;
    if (!model.loggedIn || (!model.screenChecked && screen != null)) return const SizedBox.shrink();
    final own = model.screenSpotifyLinked;
    final who = screen?.isTv ?? false ? 'La TV' : 'El proyector';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Tile(
          padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
          child: Row(
            children: [
              const Icon(Icons.sync_rounded, color: Palette.accent),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Seguir a Spotify', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    Text(own ? '$who cambia el video solo' : '$who cambia el video (con esta app abierta)',
                        style: const TextStyle(fontSize: 13, color: Palette.text2)),
                  ],
                ),
              ),
              Switch(
                value: own ? model.screenFollowing : model.autoFollow,
                onChanged: own ? (model.busy ? null : model.setScreenFollowing) : model.setAutoFollow,
              ),
            ],
          ),
        ),
        // Un proyector con receptor puede seguir a Spotify por su cuenta; la TV no.
        if (!own && model.projectorOnline && !(screen?.isTv ?? false))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: TextButton.icon(
              onPressed: model.busy ? null : model.linkSpotifyToScreen,
              icon: const Icon(Icons.link_rounded, size: 18),
              label: const Text('Que el proyector siga a Spotify aunque guardes el teléfono'),
            ),
          ),
      ],
    );
  }
}

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
          TextButton(onPressed: () => showScreensSheet(context, model), child: const Text('Más opciones')),
        ],
      ),
    );
  }
}
