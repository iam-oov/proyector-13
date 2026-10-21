import 'package:flutter/material.dart';

import 'model.dart';
import 'now_page.dart';
import 'playlists_page.dart';
import 'screens_sheet.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF7C4DFF),
        useMaterial3: true,
      ),
      home: HomeShell(model: model),
    );
  }
}

/// Dos pestañas: "Ahora" (lo que suena) y "Playlists" (el catálogo).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.model});

  final ControlModel model;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final tab = model.loggedIn ? _tab : 0;
        return Scaffold(
          appBar: AppBar(
            title: Text(tab == 0 ? 'Proyector' : 'Playlists'),
            actions: [
              ScreenChip(model: model),
              if (model.loggedIn)
                IconButton(
                  tooltip: 'Cerrar sesión de Spotify',
                  onPressed: model.busy ? null : model.logout,
                  icon: const Icon(Icons.logout),
                ),
            ],
          ),
          body: SafeArea(
            child: tab == 0 ? NowPage(model: model) : PlaylistsPage(model: model),
          ),
          bottomNavigationBar: model.loggedIn
              ? NavigationBar(
                  selectedIndex: tab,
                  onDestinationSelected: (i) => setState(() => _tab = i),
                  destinations: const [
                    NavigationDestination(icon: Icon(Icons.play_circle_outline), label: 'Ahora'),
                    NavigationDestination(icon: Icon(Icons.queue_music), label: 'Playlists'),
                  ],
                )
              : null,
        );
      },
    );
  }
}
