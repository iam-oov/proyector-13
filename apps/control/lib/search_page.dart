import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'model.dart';
import 'now_page.dart';

/// Pestaña "Buscar": canción o artista → resultados de YouTube → enviar.
/// Funciona sin Spotify, para el resto de la casa.
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
      builder: (context, _) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.search,
              onSubmitted: model.search,
              decoration: InputDecoration(
                hintText: 'Canción o artista',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: model.searching ? null : () => model.search(_controller.text),
                ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          if (model.searching) const LinearProgressIndicator(),
          if (model.error != null)
            Padding(padding: const EdgeInsets.all(20), child: Notice(model.error!, error: true)),
          Expanded(
            child: model.searchResults.isEmpty && !model.searching
                ? Center(
                    child: Text(
                      'Escribe qué quieres ver y toca un resultado para mandarlo al proyector.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
                    ),
                  )
                : ListView.builder(
                    itemCount: model.searchResults.length,
                    itemBuilder: (context, i) {
                      final v = model.searchResults[i];
                      return ListTile(
                        leading: v.thumbnailUrl == null
                            ? const SizedBox(width: 80, child: Icon(Icons.ondemand_video))
                            : ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Image.network(v.thumbnailUrl!, width: 80, fit: BoxFit.cover),
                              ),
                        title: Text(v.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(v.channel, maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.cast, size: 20),
                        enabled: !model.busy && model.projectorOnline,
                        onTap: () => _send(context, v),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _send(BuildContext context, VideoCandidate v) async {
    final model = widget.model;
    final messenger = ScaffoldMessenger.of(context);
    await model.sendVideo(v);
    messenger.showSnackBar(SnackBar(
      content: Text(model.error ?? model.status ?? ''),
      backgroundColor: model.error == null ? null : Colors.red.shade900,
    ));
  }
}
