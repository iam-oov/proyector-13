import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared/shared.dart';

/// Cámara a pantalla completa. Devuelve (con `Navigator.pop`) el
/// [PairingPayload] del QR que muestra el proyector.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;
  String? _hint;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final raw = capture.barcodes.isEmpty ? '' : (capture.barcodes.first.rawValue ?? '');
    final payload = PairingPayload.tryParse(raw);
    if (payload == null) {
      setState(() => _hint = 'Este QR no es de Proyector');
      return;
    }
    _done = true;
    Navigator.of(context).pop(payload);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Escanear QR')),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _ScanError(error: error),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 40,
            child: Text(
              _hint ?? 'Apunta la cámara al QR que muestra el proyector',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16, shadows: [Shadow(blurRadius: 8)]),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanError extends StatelessWidget {
  const _ScanError({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          denied
              ? 'Sin permiso de cámara. Actívalo en Ajustes › Aplicaciones › Proyector › Permisos.'
              : 'Cámara no disponible: ${error.errorDetails?.message ?? error.errorCode.name}',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
