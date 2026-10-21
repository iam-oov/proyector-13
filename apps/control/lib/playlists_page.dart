import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'model.dart';
import 'now_page.dart';

/// Pestaña "Playlists": el catálogo de Spotify para elegir qué video mandar.
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
        return RefreshIndicator(
          onRefresh: () => model.loadPlaylists(force: true),
          child: ListView(
            children: [
              if (model.error != null)
                Padding(padding: const EdgeInsets.all(20), child: Notice(model.error!, error: true)),
              for (final p in model.playlists)
                ListTile(
                  leading: _cover(p.imageUrl, p.id == 'liked' ? Icons.favorite : Icons.queue_music),
                  title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text([
                    if (p.total > 0) '${p.total} canciones',
                    if (p.owner != null) p.owner!,
                    if (p.isSpotifyOwned) 'no disponible (editorial de Spotify)',
                  ].join(' · ')),
                  // Spotify cerró sus playlists editoriales a las apps en modo desarrollo.
                  enabled: !p.isSpotifyOwned,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => TracksPage(model: model, playlist: p)),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Canciones de una playlist. Tocar una manda su video al proyector.
class TracksPage extends StatelessWidget {
  const TracksPage({super.key, required this.model, required this.playlist});

  final ControlModel model;
  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(playlist.name)),
      body: FutureBuilder<List<Track>>(
        future: model.tracksOf(playlist.id),
        builder: (context, snap) {
          if (snap.hasError) {
            return Padding(padding: const EdgeInsets.all(20), child: Notice('${snap.error}', error: true));
          }
          final tracks = snap.data;
          if (tracks == null) return const Center(child: CircularProgressIndicator());
          if (tracks.isEmpty) return const Center(child: Text('Esta playlist está vacía'));
          return ListenableBuilder(
            listenable: model,
            builder: (context, _) => Column(
              children: [
                if (model.busy) const LinearProgressIndicator(),
                Expanded(
                  child: ListView.builder(
                    itemCount: tracks.length,
                    itemBuilder: (context, i) {
                      final t = tracks[i];
                      return ListTile(
                        leading: _cover(t.artUrl, Icons.album),
                        title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.cast, size: 20),
                        enabled: !model.busy && model.projectorOnline,
                        onTap: () => _send(context, t),
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
    await model.sendTrack(t);
    messenger.showSnackBar(SnackBar(
      content: Text(model.error ?? model.status ?? ''),
      backgroundColor: model.error == null ? null : Colors.red.shade900,
    ));
  }
}

Widget _cover(String? url, IconData fallback) => ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: url == null
          ? SizedBox.square(dimension: 48, child: Icon(fallback))
          : Image.network(url, width: 48, height: 48, fit: BoxFit.cover),
    );
