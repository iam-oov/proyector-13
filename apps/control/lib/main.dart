import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'model.dart';
import 'now_page.dart';
import 'playlists_page.dart';
import 'screens_sheet.dart';
import 'search_page.dart';

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

/// Pestañas: "Ahora" (lo que suena), "Buscar" (sin Spotify) y "Playlists" (con sesión).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.model});

  final ControlModel model;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  // "Ahora" va en el centro y es la pestaña inicial.
  int _tab = 1;

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final titles = ['Buscar', 'Proyector', if (model.loggedIn) 'Playlists'];
        final tab = math.min(_tab, titles.length - 1);
        return Scaffold(
          appBar: AppBar(
            title: Text(titles[tab]),
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
            child: switch (tab) {
              0 => SearchPage(model: model),
              1 => NowPage(model: model),
              _ => PlaylistsPage(model: model),
            },
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              const NavigationDestination(icon: Icon(Icons.search), label: 'Buscar'),
              const NavigationDestination(icon: Icon(Icons.play_circle_outline), label: 'Ahora'),
              if (model.loggedIn) const NavigationDestination(icon: Icon(Icons.queue_music), label: 'Playlists'),
            ],
          ),
        );
      },
    );
  }
}
