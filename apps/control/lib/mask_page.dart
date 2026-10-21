import 'dart:async';

import 'package:flutter/material.dart';

import 'model.dart';
import 'projector.dart';

/// Máscara de figura libre: dibujas con el dedo en un lienzo 16:9 que
/// representa la imagen del proyector; dentro de las figuras se ve la imagen
/// y el resto queda negro. Se actualiza en vivo mientras dibujas.
class MaskPage extends StatefulWidget {
  const MaskPage({super.key, required this.model});

  final ControlModel model;

  @override
  State<MaskPage> createState() => _MaskPageState();
}

class _MaskPageState extends State<MaskPage> {
  final List<List<Offset>> _shapes = [];
  List<Offset>? _current;
  double _feather = 0.015;
  bool _outline = true;
  String? _status;
  Timer? _throttle;
  bool _pending = false;
  bool _sending = false;

  ProjectorClient? get _client {
    final s = widget.model.selectedScreen;
    return s == null ? null : ProjectorClient(s);
  }

  @override
  void dispose() {
    _throttle?.cancel();
    super.dispose();
  }

  List<List<double>> _payload({bool includeCurrent = true}) => [
        for (final s in [..._shapes, if (includeCurrent && _current != null) _current!])
          if (s.length >= 3) [for (final p in s) ...[p.dx, p.dy]],
      ];

  /// Envía como mucho cada 120 ms mientras dibujas (el proyector es lento).
  void _sendLive() {
    _pending = true;
    if (_throttle?.isActive ?? false) return;
    _throttle = Timer(const Duration(milliseconds: 120), _flush);
  }

  Future<void> _flush({bool save = false}) async {
    if (_sending) {
      _pending = true;
      return;
    }
    final client = _client;
    if (client == null) return;
    _pending = false;
    _sending = true;
    try {
      final shapes = _payload();
      if (shapes.isEmpty) {
        await client.clearMask();
      } else {
        await client.mask(shapes: shapes, feather: _feather, outline: _outline, save: save);
      }
      if (mounted && _status != null && save) setState(() => _status = null);
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    } finally {
      _sending = false;
      if (_pending) _sendLive();
    }
  }

  Offset _norm(Offset local, Size size) =>
      Offset((local.dx / size.width).clamp(0.0, 1.0), (local.dy / size.height).clamp(0.0, 1.0));

  void _addPoint(Offset p) {
    final cur = _current!;
    // Descarta puntos muy juntos: polígonos más ligeros para el proyector.
    if (cur.isNotEmpty && (cur.last - p).distance < 0.006) return;
    setState(() => cur.add(p));
    _sendLive();
  }

  Future<void> _apply() async {
    setState(() => _outline = false);
    await _flush(save: true);
    if (mounted && _status == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Máscara guardada en el proyector')));
    }
  }

  Future<void> _remove() async {
    setState(() {
      _shapes.clear();
      _current = null;
    });
    try {
      await _client?.clearMask();
      if (mounted) setState(() => _status = 'Máscara quitada');
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final online = widget.model.projectorOnline;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Máscara'),
        actions: [
          IconButton(
            tooltip: 'Deshacer',
            onPressed: _shapes.isEmpty
                ? null
                : () {
                    setState(() => _shapes.removeLast());
                    _sendLive();
                  },
            icon: const Icon(Icons.undo),
          ),
          IconButton(tooltip: 'Quitar máscara', onPressed: _remove, icon: const Icon(Icons.layers_clear)),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                online
                    ? 'Dibuja con el dedo dónde quieres ver la imagen. Lo demás queda negro. '
                        'Mira la casa mientras dibujas: se actualiza en vivo.'
                    : 'La pantalla no responde: revisa que esté prendida.',
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 12),
              AspectRatio(
                aspectRatio: 16 / 9,
                child: LayoutBuilder(
                  builder: (context, c) {
                    final size = Size(c.maxWidth, c.maxHeight);
                    return GestureDetector(
                      onPanStart: online
                          ? (d) {
                              setState(() => _current = [_norm(d.localPosition, size)]);
                            }
                          : null,
                      onPanUpdate: online ? (d) => _addPoint(_norm(d.localPosition, size)) : null,
                      onPanEnd: online
                          ? (_) {
                              final cur = _current;
                              setState(() {
                                if (cur != null && cur.length >= 3) _shapes.add(cur);
                                _current = null;
                              });
                              _sendLive();
                            }
                          : null,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CustomPaint(
                          painter: _MaskPainter(shapes: _shapes, current: _current),
                          size: size,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('Borde suave'),
                  Expanded(
                    child: Slider(
                      value: _feather,
                      max: 0.06,
                      onChanged: (v) => setState(() => _feather = v),
                      onChangeEnd: (_) => _sendLive(),
                    ),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Contorno para calibrar'),
                subtitle: const Text('Línea blanca alrededor de cada figura mientras ajustas'),
                value: _outline,
                onChanged: (v) {
                  setState(() => _outline = v);
                  _sendLive();
                },
              ),
              const Spacer(),
              if (_status != null) Text(_status!, style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: online && _shapes.isNotEmpty ? _apply : null,
                icon: const Icon(Icons.check),
                label: const Text('Guardar máscara'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Vista previa: negro con las figuras "abiertas" en gris claro.
class _MaskPainter extends CustomPainter {
  _MaskPainter({required this.shapes, required this.current});

  final List<List<Offset>> shapes;
  final List<Offset>? current;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    final fill = Paint()..color = const Color(0xFF8E8AA8);
    final stroke = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    Path toPath(List<Offset> pts, {bool close = true}) {
      final p = Path()..moveTo(pts.first.dx * size.width, pts.first.dy * size.height);
      for (final o in pts.skip(1)) {
        p.lineTo(o.dx * size.width, o.dy * size.height);
      }
      if (close) p.close();
      return p;
    }

    for (final s in shapes) {
      final p = toPath(s);
      canvas.drawPath(p, fill);
      canvas.drawPath(p, stroke);
    }
    final cur = current;
    if (cur != null && cur.length >= 2) canvas.drawPath(toPath(cur, close: false), stroke);
    // Marco del área de proyección.
    canvas.drawRect(Offset.zero & size, Paint()
      ..color = Colors.white24
      ..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(_MaskPainter old) => true;
}
