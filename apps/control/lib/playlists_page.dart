import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'app_theme.dart';
import 'model.dart';

/// Pestaña "Playlists" (2b): el catálogo de Spotify. Las fijadas van arriba en
/// tarjetas grandes; fijar o desfijar es mantener presionada una playlist.
class PlaylistsPage extends StatefulWidget {
  const PlaylistsPage({super.key, required this.model});

  final ControlModel model;

  @override
  State<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<PlaylistsPage> {
  @override
  void initState() {
    super.initState();
    if (widget.model.loggedIn) widget.model.loadPlaylists();
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        if (!model.loggedIn) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.queue_music_rounded, size: 44, color: Palette.text3),
                  const SizedBox(height: 12),
                  const Text('Conecta Spotify para ver tus playlists',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: model.busy ? null : model.login,
                    icon: const Icon(Icons.music_note_rounded),
                    label: const Text('Conectar Spotify'),
                  ),
                ],
              ),
            ),
          );
        }
        if (model.playlistsLoading && model.playlists.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        final pinned = [for (final p in model.playlists) if (model.isPinned(p.id)) p];
        final rest = [for (final p in model.playlists) if (!model.isPinned(p.id)) p];
        return RefreshIndicator(
          onRefresh: () => model.loadPlaylists(force: true),
          child: ListView(
            padding: const EdgeInsets.only(top: 12, bottom: 16),
            children: [
              ScreenRow(model: model),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (model.error != null) ...[Notice(model.error!, error: true), const SizedBox(height: 12)],
                    if (pinned.isNotEmpty) ...[
                      const SectionLabel('Fijadas'),
                      const SizedBox(height: 10),
                      GridView.count(
                        crossAxisCount: 2,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 14,
                        childAspectRatio: 0.78,
                        children: [for (final p in pinned) _PinnedCard(model: model, playlist: p)],
                      ),
                      const SizedBox(height: 18),
                      const SectionLabel('Todas'),
                      const SizedBox(height: 4),
                    ] else
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text('Mantén presionada una playlist para fijarla arriba.',
                            style: TextStyle(fontSize: 13, color: Palette.text3)),
                      ),
                    for (final p in rest) _PlaylistRow(model: model, playlist: p),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

void _openPlaylist(BuildContext context, ControlModel model, Playlist p) {
  if (p.isSpotifyOwned) return;
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TracksPage(model: model, playlist: p)));
}

Future<void> _togglePin(BuildContext context, ControlModel model, Playlist p) async {
  if (p.isSpotifyOwned) return;
  final pinned = model.isPinned(p.id);
  await model.togglePin(p.id);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(pinned ? '"${p.name}" ya no está fijada' : '"${p.name}" fijada arriba')));
}

class _PinnedCard extends StatelessWidget {
  const _PinnedCard({required this.model, required this.playlist});

  final ControlModel model;
  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    final p = playlist;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _openPlaylist(context, model, p),
      onLongPress: () => _togglePin(context, model, p),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) => Cover(
                url: p.imageUrl,
                width: c.maxWidth,
                height: c.maxHeight,
                radius: 18,
                icon: p.id == 'liked' ? Icons.favorite_rounded : Icons.queue_music_rounded,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          Text(p.total > 0 ? '${p.total} canciones' : (p.owner ?? ''),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Palette.text2)),
        ],
      ),
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({required this.model, required this.playlist});

  final ControlModel model;
  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    final p = playlist;
    final liked = p.id == 'liked';
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _openPlaylist(context, model, p),
      onLongPress: () => _togglePin(context, model, p),
      child: Opacity(
        // Spotify cerró sus playlists editoriales a las apps en modo desarrollo.
        opacity: p.isSpotifyOwned ? 0.45 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              liked
                  ? Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(color: Palette.surface2, borderRadius: BorderRadius.circular(10)),
                      child: const Icon(Icons.favorite_rounded, color: Palette.accent),
                    )
                  : Cover(url: p.imageUrl, width: 52, radius: 10, icon: Icons.queue_music_rounded),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    Text(
                      p.isSpotifyOwned
                          ? 'No disponible (editorial de Spotify)'
                          : [if (p.total > 0) '${p.total} canciones', if (p.owner != null) p.owner!].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: Palette.text2),
                    ),
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

/// Canciones de una playlist (2c), de la más reciente a la más vieja (o en el
/// orden de Spotify). Tocar una manda su video; "Aleatorio" arma una cola que
/// avanza sola; mantener presionada reproduce desde ahí en orden.
class TracksPage extends StatefulWidget {
  const TracksPage({super.key, required this.model, required this.playlist});

  final ControlModel model;
  final Playlist playlist;

  @override
  State<TracksPage> createState() => _TracksPageState();
}

class _TracksPageState extends State<TracksPage> {
  late final Future<List<Track>> _tracks = widget.model.tracksOf(widget.playlist.id);
  bool _newestFirst = true;

  List<Track> _sorted(List<Track> tracks) {
    if (!_newestFirst) return tracks;
    final out = [...tracks];
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    out.sort((a, b) => (b.addedAt ?? epoch).compareTo(a.addedAt ?? epoch));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final p = widget.playlist;
    return Scaffold(
      body: SafeArea(
        child: FutureBuilder<List<Track>>(
          future: _tracks,
          builder: (context, snap) {
            final raw = snap.data;
            final tracks = raw == null ? const <Track>[] : _sorted(raw);
            return ListenableBuilder(
              listenable: model,
              builder: (context, _) {
                final screen = model.selectedScreen?.name ?? 'la pantalla';
                return ListView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                  children: [
                    Row(
                      children: [
                        IconButton(
                          padding: EdgeInsets.zero,
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: _newestFirst ? 'Orden de Spotify' : 'Más recientes primero',
                          onPressed: () => setState(() => _newestFirst = !_newestFirst),
                          icon: Icon(_newestFirst ? Icons.schedule_rounded : Icons.format_list_numbered_rounded, color: Palette.text2),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Cover(url: p.imageUrl, width: 104, radius: 18, icon: p.id == 'liked' ? Icons.favorite_rounded : Icons.queue_music_rounded),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, height: 1.15)),
                              const SizedBox(height: 4),
                              Text(
                                raw == null
                                    ? 'Cargando…'
                                    : '${tracks.length} canciones${_newestFirst ? ' · más recientes primero' : ''}',
                                style: const TextStyle(fontSize: 14, color: Palette.text2),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: model.busy || !model.projectorOnline || tracks.isEmpty
                            ? null
                            : () => _queue(context, tracks, shuffle: true),
                        icon: model.busy
                            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.shuffle_rounded),
                        label: Text('Aleatorio en $screen', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                      ),
                    ),
                    if (!model.projectorOnline)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text('$screen no responde: elige otra pantalla en Ahora.',
                            textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: Palette.text3)),
                      ),
                    const SizedBox(height: 10),
                    if (snap.hasError) Notice('${snap.error}', error: true),
                    if (raw == null && !snap.hasError) const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
                    if (raw != null && raw.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('Esta playlist está vacía'))),
                    for (final (i, t) in tracks.indexed)
                      _TrackRow(
                        track: t,
                        sentTo: model.isSentTrack(t) ? screen : null,
                        enabled: !model.busy && model.projectorOnline,
                        onTap: () => _send(context, t),
                        onLongPress: () => _queue(context, tracks, startAt: i),
                      ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _send(BuildContext context, Track t) async {
    final messenger = ScaffoldMessenger.of(context);
    await widget.model.sendTrack(t);
    if (widget.model.error != null) _snack(messenger);
  }

  Future<void> _queue(BuildContext context, List<Track> tracks, {bool shuffle = false, int startAt = 0}) async {
    final messenger = ScaffoldMessenger.of(context);
    await widget.model.playQueue(tracks, name: widget.playlist.name, shuffle: shuffle, startAt: startAt);
    _snack(messenger);
  }

  void _snack(ScaffoldMessengerState messenger) {
    final model = widget.model;
    messenger.showSnackBar(SnackBar(
      content: Text(model.error ?? model.status ?? ''),
      backgroundColor: model.error == null ? null : Colors.red.shade900,
    ));
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({required this.track, required this.sentTo, required this.enabled, required this.onTap, required this.onLongPress});

  final Track track;
  final String? sentTo;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  static String _ago(DateTime d) {
    final days = DateTime.now().difference(d).inDays;
    if (days < 1) return 'agregada hoy';
    if (days < 30) return 'hace $days d';
    if (days < 365) return 'hace ${days ~/ 30} meses';
    return 'hace ${days ~/ 365} años';
  }

  @override
  Widget build(BuildContext context) {
    final t = track;
    final sent = sentTo != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: sent ? Color.alphaBlend(Palette.live.withValues(alpha: 0.09), Palette.surface) : Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: enabled ? onTap : null,
          onLongPress: enabled ? onLongPress : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Cover(url: t.artUrl, width: 52, radius: 10),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: enabled ? Palette.text : Palette.text3)),
                      Text([t.artist, if (t.addedAt != null) _ago(t.addedAt!)].join(' · '),
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Palette.text2)),
                    ],
                  ),
                ),
                if (sent) ...[const SizedBox(width: 8), LiveChip(sentTo!)],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
