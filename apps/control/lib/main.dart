import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'model.dart';
import 'now_page.dart';
import 'playlists_page.dart';
import 'search_page.dart';
import 'sleep_timer.dart';
import 'trading_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SleepTimer.init();
  final model = ControlModel()..init();
  runApp(ControlApp(model: model));
}

class ControlApp extends StatelessWidget {
  const ControlApp({super.key, required this.model});

  final ControlModel model;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Proyector',
      debugShowCheckedModeBanner: false,
      theme: appTheme(),
      home: HomeShell(model: model),
    );
  }
}

/// Pestañas: Ahora (inicial), Playlists y Trading. Sin barra de arriba: cada
/// pestaña empieza con la fila de la pantalla, que trae la lupa de Buscar.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.model});

  final ControlModel model;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  int _statusSeq = 0;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_onModel);
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModel);
    super.dispose();
  }

  /// Cada aviso nuevo del modelo sale como toast. El de "enviado" no: la tarjeta
  /// de Ahora y la fila de Buscar ya marcan lo que se mandó.
  void _onModel() {
    final model = widget.model;
    if (model.statusSeq == _statusSeq) return;
    _statusSeq = model.statusSeq;
    final msg = model.status;
    if (msg == null || model.statusIsSend || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        // Los avisos largos (p. ej. cómo dar permiso en la Roku) necesitan más tiempo para leerse.
        duration: Duration(seconds: msg.length > 90 ? 6 : 3),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        // Buscar ya no es pestaña: es la lupa de arriba (ScreenRow → openSearch).
        child: switch (_tab) {
          0 => NowPage(model: model, onSearch: () => openSearch(context, model)),
          1 => PlaylistsPage(model: model),
          _ => TradingPage(model: model),
        },
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.play_circle_outline_rounded), selectedIcon: Icon(Icons.play_circle_rounded), label: 'Ahora'),
          NavigationDestination(icon: Icon(Icons.queue_music_rounded), label: 'Playlists'),
          NavigationDestination(icon: Icon(Icons.candlestick_chart_outlined), selectedIcon: Icon(Icons.candlestick_chart), label: 'Trading'),
        ],
      ),
    );
  }
}
