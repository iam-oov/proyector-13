import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'home_screen.dart';
import 'identity.dart';
import 'mask.dart';
import 'server.dart';
import 'state.dart';
import 'trading.dart';
import 'trading_dashboard.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ReceiverIdentity identity;
  String? loadError;
  try {
    identity = await ReceiverIdentity.load();
  } catch (e) {
    identity = ReceiverIdentity.ephemeral();
    loadError = '$e';
  }
  final state = ReceiverState(identity);
  if (loadError != null) state.add('No pude guardar la identidad: $loadError', error: true);
  final trading = TradingController(state, await TradingStore.open());
  await trading.init();
  MaskController? mask;
  try {
    mask = await MaskController.open();
  } catch (e) {
    state.add('Máscara no disponible: $e', error: true);
  }
  ReceiverServer(state, onTradingChanged: trading.onChanged, mask: mask).start().catchError((Object e) {
    state.add('No pude abrir el puerto ${state.port}: $e', error: true);
  });
  runApp(ProyectorApp(state: state));
}

class ProyectorApp extends StatelessWidget {
  const ProyectorApp({super.key, required this.state});

  final ReceiverState state;

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
      home: ListenableBuilder(
        listenable: state,
        builder: (context, _) => switch (state.panel) {
          ReceiverPanel.home => HomeScreen(state: state),
          ReceiverPanel.qr => StatusScreen(state: state),
          ReceiverPanel.trading => TradingDashboard(state: state),
        },
      ),
    );
  }
}

/// Pantalla para la TV: el QR para vincularse, nombre, IP y los últimos envíos.
/// Atrás en el control vuelve al inicio.
class StatusScreen extends StatelessWidget {
  const StatusScreen({super.key, required this.state});

  final ReceiverState state;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (_, _) => state.showPanel(ReceiverPanel.home),
      child: Scaffold(
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 64, vertical: 48),
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) => LayoutBuilder(
            builder: (context, constraints) {
              final qrSize = math.min(constraints.maxHeight * 0.6, constraints.maxWidth * 0.35);
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _QrPanel(uri: state.pairingUri, size: qrSize),
                  const SizedBox(width: 48),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(state.identity.name, style: text.displaySmall),
                        const SizedBox(height: 8),
                        Text(
                          state.host == null ? 'Abriendo el puerto ${state.port}…' : '${state.host}:${state.port}',
                          style: text.titleLarge?.copyWith(color: Colors.white70),
                        ),
                        const SizedBox(height: 16),
                        Text('Escanea el QR con la app Proyector en tu teléfono', style: text.bodyLarge),
                        const SizedBox(height: 12),
                        Text(
                          state.phones.isEmpty ? 'Nadie conectado todavía' : 'Conectado: ${state.phones.join(', ')}',
                          style: text.bodyLarge?.copyWith(color: Colors.white70),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 36),
                        Text('Últimos envíos', style: text.titleMedium),
                        const SizedBox(height: 12),
                        if (state.events.isEmpty)
                          Text('Todavía nada. Manda un video desde el teléfono.',
                              style: text.bodyLarge?.copyWith(color: Colors.white38)),
                        for (final e in state.events)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(
                              '${_hhmm(e.at)}  ${e.message}',
                              style: text.bodyLarge?.copyWith(color: e.error ? Colors.redAccent : Colors.white70),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
      ),
    );
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// Caja blanca con margen: el QR necesita zona de silencio sobre el fondo oscuro.
class _QrPanel extends StatelessWidget {
  const _QrPanel({required this.uri, required this.size});

  final String? uri;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: uri == null
          ? SizedBox.square(
              dimension: size,
              child: const Center(child: Text('Buscando la red…', style: TextStyle(color: Colors.black54))),
            )
          : QrImageView(
              data: uri!,
              size: size,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
              backgroundColor: Colors.white,
            ),
    );
  }
}
