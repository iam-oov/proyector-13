import 'package:flutter/material.dart';
import 'package:shared/shared.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'app_theme.dart';
import 'config.dart';
import 'model.dart';

/// Pestaña "Buscar" (2a). Escrito: canción o artista → resultados de YouTube y se
/// toca uno para mandarlo a la pantalla de arriba. Con el micrófono: el asistente
/// entiende lo que se pide ("música para la playa"), manda el mejor video solo y
/// deja los demás abajo por si no era. También entiende controles ("pausa",
/// "adelántalo 5 minutos"). Funciona sin Spotify, para el resto de la casa.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.model});

  final ControlModel model;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  final _speech = SpeechToText();
  bool _speechReady = false;
  bool _listening = false;

  @override
  void dispose() {
    _speech.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _mic() async {
    if (_listening) {
      await _speech.stop();
      return;
    }
    if (!_speechReady) {
      _speechReady = await _speech.initialize(
        onStatus: (s) {
          if (mounted) setState(() => _listening = s == SpeechToText.listeningStatus);
        },
        onError: (_) {
          if (mounted) setState(() => _listening = false);
        },
      );
      if (!_speechReady) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No pude usar el micrófono: revisa el permiso en Ajustes')),
          );
        }
        return;
      }
    }
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    setState(_controller.clear);
    await _speech.listen(
      onResult: _onSpeech,
      listenOptions: SpeechListenOptions(localeId: 'es_MX', partialResults: true, listenMode: ListenMode.confirmation),
    );
  }

  void _onSpeech(SpeechRecognitionResult r) {
    setState(() => _controller.text = r.recognizedWords);
    if (r.finalResult && r.recognizedWords.trim().isNotEmpty) widget.model.runAssistant(r.recognizedWords);
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final screen = model.selectedScreen?.name ?? 'la pantalla';
        final step = model.assistantStep;
        final working = step != null;
        final results = model.searchResults;
        final fromAssistant = model.searchFromAssistant && results.isNotEmpty;
        final enabled = !model.busy && !working && model.projectorOnline;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            ScreenRow(model: model),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      enabled: !working,
                      textInputAction: TextInputAction.search,
                      onSubmitted: model.search,
                      style: const TextStyle(fontSize: 16),
                      decoration: InputDecoration(
                        hintText: _listening ? 'Te escucho…' : 'Canción o artista',
                        prefixIcon: const Icon(Icons.search_rounded, color: Palette.text3),
                        suffixIcon: _controller.text.isEmpty || working
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close_rounded, color: Palette.text3, size: 20),
                                onPressed: () => setState(_controller.clear),
                              ),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  if (Config.hasAssistant) ...[
                    const SizedBox(width: 10),
                    Material(
                      color: _listening ? Palette.live : Palette.accent,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: working ? null : _mic,
                        child: SizedBox.square(
                          dimension: 52,
                          child: Icon(_listening ? Icons.graphic_eq_rounded : Icons.mic_rounded, color: Palette.onAccent, size: 26),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (working)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 20, 4),
                child: Row(
                  children: [
                    const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                    Text(step, style: const TextStyle(fontSize: 14, color: Palette.text2)),
                  ],
                ),
              )
            else if (model.assistantReply != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 8, 20, 4),
                child: Row(
                  children: [
                    const Icon(Icons.auto_awesome_rounded, size: 18, color: Palette.accent),
                    const SizedBox(width: 8),
                    Expanded(child: Text(model.assistantReply!, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
                  ],
                ),
              ),
            if (model.searching) const LinearProgressIndicator(minHeight: 2),
            if (model.error != null) Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 0), child: Notice(model.error!, error: true)),
            Expanded(
              child: results.isEmpty && !model.searching
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          Config.hasAssistant
                              ? 'Escribe una canción y elige el video, o toca el micrófono y pide algo: '
                                  '"música para la playa". Va a $screen.'
                              : 'Escribe qué quieres ver y toca un resultado para mandarlo a $screen.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 15, color: Palette.text3, height: 1.4),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
                      itemCount: results.length + (fromAssistant && results.length > 1 ? 1 : 0),
                      itemBuilder: (context, i) {
                        // Con el asistente, entre el elegido y los demás va el título de las otras opciones.
                        if (fromAssistant && i == 1) {
                          return const Padding(
                            padding: EdgeInsets.fromLTRB(10, 18, 10, 6),
                            child: SectionLabel('¿No es el video correcto?'),
                          );
                        }
                        final v = results[fromAssistant && i > 1 ? i - 1 : i];
                        final sent = v.id == model.lastSentVideoId;
                        return _ResultRow(
                          video: v,
                          sentTo: sent ? screen : null,
                          enabled: enabled,
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
    final details = [video.channel, ?video.duration].join(' · ');
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
                      Text(details, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Palette.text2)),
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
