import 'package:flutter/material.dart';

import 'apps.dart';
import 'state.dart';

/// Pantalla de inicio del proyector: tiles de apps + Trading + Vincular +
/// Ajustes, navegables con el control. Abajo, los últimos envíos.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.state});

  final ReceiverState state;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<TvApp> _apps = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final apps = await installedApps();
      if (mounted) setState(() => _apps = apps);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _open(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      widget.state.add('✕  $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 56, vertical: 40),
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(state.identity.name, style: text.headlineMedium),
                  const Spacer(),
                  Text(
                    state.phones.isEmpty ? 'Nadie conectado' : 'Conectado: ${state.phones.join(', ')}',
                    style: text.bodyMedium?.copyWith(color: Colors.white54),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final (i, app) in _apps.indexed)
                    HomeTile(
                      label: app.label,
                      icon: app.icon == null
                          ? const Icon(Icons.apps, size: 40)
                          : Image.memory(app.icon!, width: 56, height: 56, filterQuality: FilterQuality.medium),
                      autofocus: i == 0,
                      onTap: () => _open(() => launchPackage(app.package)),
                    ),
                  HomeTile(
                    label: 'Trading',
                    icon: const Icon(Icons.candlestick_chart_outlined, size: 40),
                    color: const Color(0xFF263238),
                    autofocus: _apps.isEmpty,
                    onTap: () => state.showPanel(ReceiverPanel.trading),
                  ),
                  HomeTile(
                    label: 'Vincular teléfono',
                    icon: const Icon(Icons.qr_code_2, size: 40),
                    color: const Color(0xFF2D2640),
                    onTap: () => state.showPanel(ReceiverPanel.qr),
                  ),
                  HomeTile(
                    label: 'Ajustes',
                    icon: const Icon(Icons.settings, size: 40),
                    color: const Color(0xFF2B2B2B),
                    onTap: () => _open(() => launchComponent('com.jixin.settings5', 'com.jixin.settings5.SettingsActivity')),
                  ),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!, style: text.bodyMedium?.copyWith(color: Colors.redAccent)),
                ),
              const Spacer(),
              Text('Últimos envíos', style: text.titleMedium),
              const SizedBox(height: 8),
              if (state.events.isEmpty)
                Text('Todavía nada. Manda un video desde el teléfono.',
                    style: text.bodyMedium?.copyWith(color: Colors.white38)),
              for (final e in state.events.take(3))
                Text(
                  '${_hhmm(e.at)}  ${e.message}',
                  style: text.bodyMedium?.copyWith(color: e.error ? Colors.redAccent : Colors.white70),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// Tile grande con resalte de foco para el D-pad. Enter/OK lo activa.
class HomeTile extends StatefulWidget {
  const HomeTile({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.color,
    this.autofocus = false,
  });

  final String label;
  final Widget icon;
  final VoidCallback onTap;
  final Color? color;
  final bool autofocus;

  @override
  State<HomeTile> createState() => _HomeTileState();
}

class _HomeTileState extends State<HomeTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedScale(
      scale: _focused ? 1.06 : 1,
      duration: const Duration(milliseconds: 120),
      child: Material(
        color: widget.color ?? scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          autofocus: widget.autofocus,
          borderRadius: BorderRadius.circular(16),
          onTap: widget.onTap,
          onFocusChange: (f) => setState(() => _focused = f),
          child: Container(
            width: 176,
            height: 120,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _focused ? Colors.white : Colors.transparent, width: 3),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                widget.icon,
                Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
