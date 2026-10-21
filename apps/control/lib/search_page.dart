import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'app_theme.dart';
import 'model.dart';

/// Pestaña "Buscar" (2a): canción o artista → resultados de YouTube. Se toca el
/// resultado para mandarlo a la pantalla de la fila de arriba; el enviado queda
/// marcado. Funciona sin Spotify, para el resto de la casa.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.model});

  final ControlModel model;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final screen = model.selectedScreen?.name ?? 'la pantalla';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            ScreenRow(model: model),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: TextField(
                controller: _controller,
                textInputAction: TextInputAction.search,
                onSubmitted: model.search,
                style: const TextStyle(fontSize: 16),
                decoration: InputDecoration(
                  hintText: 'Canción o artista',
                  prefixIcon: const Icon(Icons.search_rounded, color: Palette.text3),
                  suffixIcon: _controller.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded, color: Palette.text3, size: 20),
                          onPressed: () => setState(_controller.clear),
                        ),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            if (model.searching) const LinearProgressIndicator(minHeight: 2),
            if (model.error != null) Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 0), child: Notice(model.error!, error: true)),
            Expanded(
              child: model.searchResults.isEmpty && !model.searching
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'Escribe qué quieres ver y toca un resultado para mandarlo a $screen.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 15, color: Palette.text3, height: 1.4),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
                      itemCount: model.searchResults.length,
                      itemBuilder: (context, i) {
                        final v = model.searchResults[i];
                        final sent = v.id == model.lastSentVideoId;
                        return _ResultRow(
                          video: v,
                          sentTo: sent ? screen : null,
                          enabled: !model.busy && model.projectorOnline,
                          onTap: () => _send(context, v),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _send(BuildContext context, VideoCandidate v) async {
    final model = widget.model;
    final messenger = ScaffoldMessenger.of(context);
    await model.sendVideo(v);
    if (model.error != null) {
      messenger.showSnackBar(SnackBar(content: Text(model.error!), backgroundColor: Colors.red.shade900));
    }
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.video, required this.sentTo, required this.enabled, required this.onTap});

  final VideoCandidate video;

  /// Nombre de la pantalla si este es el último enviado.
  final String? sentTo;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sent = sentTo != null;
    return Material(
      color: sent ? Color.alphaBlend(Palette.live.withValues(alpha: 0.09), Palette.surface) : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Cover(url: video.thumbnailUrl, width: 112, height: 63, radius: 10, icon: Icons.smart_display_rounded),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(video.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.25, color: enabled ? Palette.text : Palette.text3)),
                    const SizedBox(height: 4),
                    if (sent)
                      LiveChip('En $sentTo')
                    else
                      Text(video.channel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Palette.text2)),
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
