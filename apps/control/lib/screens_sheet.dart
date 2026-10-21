import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Vincula sin cámara: toma el código del portapapeles (o lo pide escrito).
Future<void> pasteAndAddScreen(BuildContext context, ControlModel model) async {
  if (!await ensurePhoneName(context, model)) return;
  final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
  var payload = PairingPayload.tryParse(clip);
  if (payload == null && context.mounted) {
    final controller = TextEditingController(text: clip.trim().startsWith('proyector://') ? clip.trim() : '');
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pegar código'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(hintText: 'proyector://pair?…'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Vincular')),
        ],
      ),
    );
    if (text == null) return;
    payload = PairingPayload.tryParse(text);
  }
  if (!context.mounted) return;
  if (payload == null) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ese código no es de Proyector')));
    return;
  }
  await model.addScreen(payload);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Conectado a "${payload.name}"')));
}

/// TV sin receptor (DIAL + YouTube): se agrega con su IP, que se ve en Ajustes → Red
/// de la TV. El teléfono tiene que estar en el mismo Wi-Fi.
Future<void> addTvDialog(BuildContext context, ControlModel model) async {
  final ip = TextEditingController();
  final name = TextEditingController(text: 'TV');
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Agregar TV'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: ip,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'IP de la TV', hintText: '192.168.100.25'),
          ),
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Nombre', hintText: 'Recámara')),
          const SizedBox(height: 12),
          const Text('Para TVs sin el receptor: la app abre YouTube con el video y sigue a Spotify. '
              'El teléfono tiene que estar en el mismo Wi-Fi que la TV.'),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Agregar')),
      ],
    ),
  );
  if (ok != true) return;
  await model.addTv(ip.text.replaceAll(RegExp(r'[^0-9.]'), ''), name: name.text);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(model.error ?? model.status ?? '')));
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
                subtitle: Text(s.isTv ? '${s.host} · TV (YouTube)' : s.address),
                trailing: PopupMenuButton<String>(
                  onSelected: (action) => _onAction(context, action, s),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'rename', child: Text('Renombrar')),
                    if (!s.isTv) const PopupMenuItem(value: 'copy', child: Text('Copiar código (para otro teléfono)')),
                    const PopupMenuItem(value: 'remove', child: Text('Eliminar')),
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
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        scanAndAddScreen(context, model);
                      },
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Escanear QR'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Sin cámara: pegar el código que otro teléfono copió y compartió.
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      pasteAndAddScreen(context, model);
                    },
                    icon: const Icon(Icons.content_paste),
                    label: const Text('Pegar código'),
                  ),
                ],
              ),
            ),
            // TVs sin receptor (no Android): se controlan por DIAL + YouTube.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    addTvDialog(context, model);
                  },
                  icon: const Icon(Icons.live_tv),
                  label: const Text('Agregar TV sin receptor (por IP)'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onAction(BuildContext context, String action, Screen s) async {
    if (action == 'copy') {
      final code = PairingPayload(id: s.id, name: s.name, host: s.host, port: s.port, token: s.token).toUri().toString();
      await Clipboard.setData(ClipboardData(text: code));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Código copiado: mándalo por WhatsApp y en el otro teléfono toca "Pegar código"')),
        );
      }
      return;
    }
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
