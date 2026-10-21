import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'model.dart';
import 'now_page.dart';

/// Pestaña "Playlists": el catálogo de Spotify para elegir qué video mandar.
/// Las fijadas (📌) van arriba.
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
    widget.model.loadPlaylists();
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        if (model.playlistsLoading && model.playlists.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        final pinned = [for (final p in model.playlists) if (model.isPinned(p.id)) p];
        final rest = [for (final p in model.playlists) if (!model.isPinned(p.id)) p];
        return RefreshIndicator(
          onRefresh: () => model.loadPlaylists(force: true),
          child: ListView(
            children: [
              if (model.error != null)
                Padding(padding: const EdgeInsets.all(20), child: Notice(model.error!, error: true)),
              if (pinned.isNotEmpty) ...[
                const _Header('Fijadas'),
                for (final p in pinned) _PlaylistTile(model: model, playlist: p),
                const _Header('Todas'),
              ],
              for (final p in rest) _PlaylistTile(model: model, playlist: p),
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Colors.white54)),
      );
}

class _PlaylistTile extends StatelessWidget {
  const _PlaylistTile({required this.model, required this.playlist});

  final ControlModel model;
  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    final p = playlist;
    final pinned = model.isPinned(p.id);
    return ListTile(
      leading: _cover(p.imageUrl, p.id == 'liked' ? Icons.favorite : Icons.queue_music),
      title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text([
        if (p.total > 0) '${p.total} canciones',
        if (p.owner != null) p.owner!,
        if (p.isSpotifyOwned) 'no disponible (editorial de Spotify)',
      ].join(' · ')),
      // Spotify cerró sus playlists editoriales a las apps en modo desarrollo.
      enabled: !p.isSpotifyOwned,
      trailing: p.isSpotifyOwned
          ? null
          : IconButton(
              tooltip: pinned ? 'Desfijar' : 'Fijar arriba',
              onPressed: () => model.togglePin(p.id),
              icon: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
            ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => TracksPage(model: model, playlist: p)),
      ),
    );
  }
}

/// Canciones de una playlist, de la más reciente a la más vieja (o en el orden
/// de Spotify). Tocar una manda su video; "Aleatorio" arma una cola en el
/// proyector que avanza sola al terminar cada video.
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
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.playlist.name),
        actions: [
          IconButton(
            tooltip: _newestFirst ? 'Orden de Spotify' : 'Más recientes primero',
            onPressed: () => setState(() => _newestFirst = !_newestFirst),
            icon: Icon(_newestFirst ? Icons.schedule : Icons.format_list_numbered),
          ),
        ],
      ),
      body: FutureBuilder<List<Track>>(
        future: _tracks,
        builder: (context, snap) {
          if (snap.hasError) {
            return Padding(padding: const EdgeInsets.all(20), child: Notice('${snap.error}', error: true));
          }
          final raw = snap.data;
          if (raw == null) return const Center(child: CircularProgressIndicator());
          if (raw.isEmpty) return const Center(child: Text('Esta playlist está vacía'));
          final tracks = _sorted(raw);
          return ListenableBuilder(
            listenable: model,
            builder: (context, _) => Column(
              children: [
                if (model.busy) const LinearProgressIndicator(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _newestFirst ? '${tracks.length} canciones · más recientes primero' : '${tracks.length} canciones',
                          style: const TextStyle(color: Colors.white54),
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: model.busy || !model.projectorOnline
                            ? null
                            : () => _queue(context, tracks, shuffle: true),
                        icon: const Icon(Icons.shuffle),
                        label: const Text('Aleatorio'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: tracks.length,
                    itemBuilder: (context, i) {
                      final t = tracks[i];
                      return ListTile(
                        leading: _cover(t.artUrl, Icons.album),
                        title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [t.artist, if (t.addedAt != null) _ago(t.addedAt!)].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.cast, size: 20),
                        enabled: !model.busy && model.projectorOnline,
                        onTap: () => _send(context, t),
                        // Mantener presionado: reproducir desde aquí en orden.
                        onLongPress: () => _queue(context, tracks, startAt: i),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _send(BuildContext context, Track t) async {
    final messenger = ScaffoldMessenger.of(context);
    await widget.model.sendTrack(t);
    _snack(messenger);
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

  static String _ago(DateTime d) {
    final days = DateTime.now().difference(d).inDays;
    if (days < 1) return 'agregada hoy';
    if (days < 30) return 'hace $days d';
    if (days < 365) return 'hace ${days ~/ 30} meses';
    return 'hace ${days ~/ 365} años';
  }
}

Widget _cover(String? url, IconData fallback) => ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: url == null
          ? SizedBox.square(dimension: 48, child: Icon(fallback))
          : Image.network(url, width: 48, height: 48, fit: BoxFit.cover),
    );
