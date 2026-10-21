import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'model.dart';
import 'scan_page.dart';
import 'screens.dart';

/// Pide una vez cómo se llama este teléfono (la pantalla muestra "Conectado: `nombre`").
Future<bool> ensurePhoneName(BuildContext context, ControlModel model) async {
  if (model.phoneName != null) return true;
  final name = await askPhoneName(context, initial: 'Mi teléfono');
  if (name == null || name.trim().isEmpty) return false;
  await model.setPhoneName(name);
  return true;
}

Future<String?> askPhoneName(BuildContext context, {required String initial}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('¿Cómo te llamas?'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(helperText: 'El proyector mostrará "Conectado: <tu nombre>"'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Guardar')),
      ],
    ),
  );
}

/// Abre la cámara, y si el QR es de un proyector lo guarda y lo activa.
Future<void> scanAndAddScreen(BuildContext context, ControlModel model) async {
  if (!await ensurePhoneName(context, model)) return;
  if (!context.mounted) return;
  final payload = await Navigator.of(context).push<PairingPayload>(
    MaterialPageRoute(builder: (_) => const ScanPage()),
  );
  if (payload == null) return;
  await model.addScreen(payload);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Conectado a "${payload.name}"')));
}

/// Botón del AppBar con la pantalla activa; abre el selector.
class ScreenChip extends StatelessWidget {
  const ScreenChip({super.key, required this.model});

  final ControlModel model;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final s = model.selectedScreen;
        return TextButton.icon(
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            builder: (_) => ScreensSheet(model: model),
          ),
          icon: Icon(
            Icons.circle,
            size: 10,
            color: s == null ? Colors.white38 : (model.projectorOnline ? Colors.greenAccent : Colors.redAccent),
          ),
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(s?.name ?? 'Sin pantalla', overflow: TextOverflow.ellipsis),
              ),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        );
      },
    );
  }
}

/// Lista de pantallas vinculadas: elegir, renombrar, eliminar, escanear otra.
class ScreensSheet extends StatelessWidget {
  const ScreensSheet({super.key, required this.model});

  final ControlModel model;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [Text('Pantallas', style: Theme.of(context).textTheme.titleLarge)],
              ),
            ),
            if (model.screens.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Text('Todavía no hay pantallas. Escanea el QR que muestra el proyector.'),
              ),
            for (final s in model.screens)
              ListTile(
                leading: Icon(
                  s.id == model.selectedScreenId ? Icons.check_circle : Icons.tv,
                  color: s.id == model.selectedScreenId ? Theme.of(context).colorScheme.primary : null,
                ),
                title: Text(s.name),
                subtitle: Text(s.address),
                trailing: PopupMenuButton<String>(
                  onSelected: (action) => _onAction(context, action, s),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('Renombrar')),
                    PopupMenuItem(value: 'remove', child: Text('Eliminar')),
                  ],
                ),
                onTap: () {
                  model.selectScreen(s.id);
                  Navigator.of(context).pop();
                },
              ),
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text('Mi nombre: ${model.phoneName ?? 'sin definir'}'),
              subtitle: const Text('Así te ve el proyector'),
              onTap: () async {
                final name = await askPhoneName(context, initial: model.phoneName ?? 'Mi teléfono');
                if (name != null) await model.setPhoneName(name);
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    scanAndAddScreen(context, model);
                  },
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Escanear QR'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onAction(BuildContext context, String action, Screen s) async {
    if (action == 'remove') {
      await model.removeScreen(s.id);
      return;
    }
    final controller = TextEditingController(text: s.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nombre de la pantalla'),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(hintText: 'Sala')),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Guardar')),
        ],
      ),
    );
    if (name != null) await model.renameScreen(s.id, name);
  }
}
