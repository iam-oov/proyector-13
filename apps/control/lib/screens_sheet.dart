import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared/shared.dart';

import 'app_theme.dart';
import 'mask_page.dart';
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

/// Cambia la IP de una pantalla (el proyector se movió de red o el router le dio
/// otra). Para un proyector también ofrece buscarlo solo en la red.
Future<void> changeAddressDialog(BuildContext context, ControlModel model, Screen s) async {
  final controller = TextEditingController(text: s.isTv ? s.host : s.address);
  final action = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('IP de ${s.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: s.isTv ? 'IP' : 'IP:puerto', hintText: s.isTv ? '192.168.1.40' : '192.168.1.147:8080'),
          ),
          const SizedBox(height: 10),
          Text(
            s.isTv
                ? 'La ves en la TV: Ajustes → Red.'
                : 'La ves en el proyector, en "Vincular teléfono". O deja que la app lo busque en tu Wi-Fi.',
            style: const TextStyle(fontSize: 13, color: Palette.text2),
          ),
        ],
      ),
      actions: [
        if (!s.isTv) TextButton(onPressed: () => Navigator.of(context).pop('scan'), child: const Text('Buscar en mi Wi-Fi')),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.of(context).pop('save'), child: const Text('Guardar')),
      ],
    ),
  );
  if (action == null) return;
  final found = action == 'scan' ? await model.rediscover(s.id) : null;
  if (action == 'save') await model.changeAddress(s.id, controller.text);
  if (!context.mounted) return;
  final msg = found == false ? 'No encontré a ${s.name} en tu Wi-Fi: escribe su IP' : (model.error ?? model.status ?? '');
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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

/// Abre la hoja de Pantallas (2d), desde el "+" de la fila de equipos.
Future<void> showScreensSheet(BuildContext context, ControlModel model) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ScreensSheet(model: model),
    );

/// Pantallas (2d): cada equipo con su estado y sus acciones; agregar con tres
/// botones grandes; y "Tú": el nombre de este teléfono y la sesión de Spotify.
class ScreensSheet extends StatelessWidget {
  const ScreensSheet({super.key, required this.model});

  final ControlModel model;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Pantallas', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
              const SizedBox(height: 14),
              if (model.screens.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('Todavía no hay pantallas. Escanea el QR que muestra el proyector o agrega una TV por su IP.',
                      style: TextStyle(fontSize: 14, color: Palette.text2, height: 1.35)),
                ),
              for (final s in model.screens) ...[
                _DeviceRow(
                  screen: s,
                  selected: s.id == model.selectedScreenId,
                  online: model.isScreenOnline(s.id),
                  onTap: () {
                    model.selectScreen(s.id);
                    Navigator.of(context).pop();
                  },
                  onAction: (a) => _onAction(context, a, s),
                  spotifyLinked: s.id == model.selectedScreenId && model.screenSpotifyLinked,
                ),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 10),
              const SectionLabel('Agregar'),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _AddTile(icon: Icons.qr_code_scanner_rounded, label: 'Escanear QR', primary: true, onTap: () {
                      Navigator.of(context).pop();
                      scanAndAddScreen(context, model);
                    }),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    // Sin cámara: el código que otro teléfono copió y compartió.
                    child: _AddTile(icon: Icons.content_paste_rounded, label: 'Pegar código', onTap: () {
                      Navigator.of(context).pop();
                      pasteAndAddScreen(context, model);
                    }),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    // TVs sin receptor (no Android): DIAL + YouTube.
                    child: _AddTile(icon: Icons.live_tv_rounded, label: 'TV por IP', onTap: () {
                      Navigator.of(context).pop();
                      addTvDialog(context, model);
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const SectionLabel('Tú'),
              const SizedBox(height: 10),
              Tile(
                color: Palette.surface2,
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                onTap: () async {
                  final name = await askPhoneName(context, initial: model.phoneName ?? 'Mi teléfono');
                  if (name != null) await model.setPhoneName(name);
                },
                child: Row(
                  children: [
                    const Icon(Icons.smartphone_rounded, color: Palette.text2),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(model.phoneName ?? 'Sin nombre', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                          const Text('Así te ven las pantallas', style: TextStyle(fontSize: 13, color: Palette.text2)),
                        ],
                      ),
                    ),
                    const Icon(Icons.edit_rounded, color: Palette.text3, size: 20),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Tile(
                color: Palette.surface2,
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                child: Row(
                  children: [
                    const Icon(Icons.music_note_rounded, color: Palette.text2),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(model.loggedIn ? 'Spotify conectado' : 'Spotify sin conectar',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                    TextButton(
                      onPressed: model.busy ? null : (model.loggedIn ? model.logout : model.login),
                      child: Text(model.loggedIn ? 'Cerrar sesión' : 'Conectar'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onAction(BuildContext context, String action, Screen s) async {
    switch (action) {
      case 'mask':
        // El navegador se toma antes: la hoja se cierra y su contexto deja de servir.
        final nav = Navigator.of(context);
        await model.selectScreen(s.id);
        nav.pop();
        await nav.push(MaterialPageRoute<void>(builder: (_) => MaskPage(model: model)));
        return;
      case 'unlink':
        await model.unlinkSpotifyFromScreen();
        return;
      case 'copy':
        final code = PairingPayload(id: s.id, name: s.name, host: s.host, port: s.port, token: s.token).toUri().toString();
        await Clipboard.setData(ClipboardData(text: code));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Código copiado: mándalo por WhatsApp y en el otro teléfono toca "Pegar código"')),
          );
        }
        return;
      case 'remove':
        await model.removeScreen(s.id);
        return;
      case 'ip':
        Navigator.of(context).pop();
        await changeAddressDialog(context, model, s);
        return;
    }
    if (!context.mounted) return;
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

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.screen,
    required this.selected,
    required this.online,
    required this.onTap,
    required this.onAction,
    required this.spotifyLinked,
  });

  final Screen screen;
  final bool selected;
  final bool? online;
  final VoidCallback onTap;
  final ValueChanged<String> onAction;
  final bool spotifyLinked;

  @override
  Widget build(BuildContext context) {
    final s = screen;
    final on = online == true;
    return Material(
      color: Palette.surface2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: selected ? const BorderSide(color: Palette.accent, width: 2) : BorderSide.none,
      ),
      child: InkWell(
        customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
          child: Row(
            children: [
              Icon(s.isTv ? Icons.tv_rounded : Icons.videocam_rounded, color: selected ? Palette.accent : (on ? Palette.text2 : Palette.text3)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: on ? Palette.text : Palette.text2)),
                    Text(s.isTv ? 'TV · YouTube · ${s.host}' : 'Proyector · ${s.host}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Palette.text2)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              LiveChip(online == null ? 'Revisando…' : (on ? 'En línea' : 'Sin respuesta'), on: on),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded, color: Palette.text3),
                onSelected: onAction,
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'rename', child: Text('Renombrar')),
                  const PopupMenuItem(value: 'ip', child: Text('Cambiar IP')),
                  if (!s.isTv) const PopupMenuItem(value: 'mask', child: Text('Máscara de proyección')),
                  if (spotifyLinked) const PopupMenuItem(value: 'unlink', child: Text('Desvincular Spotify del proyector')),
                  if (!s.isTv) const PopupMenuItem(value: 'copy', child: Text('Copiar código (para otro teléfono)')),
                  const PopupMenuItem(value: 'remove', child: Text('Eliminar')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.icon, required this.label, required this.onTap, this.primary = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final fg = primary ? Palette.onAccent : Palette.text2;
    return Material(
      color: primary ? Palette.accent : Palette.surface2,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: SizedBox(
          height: 96,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 30, color: primary ? fg : Palette.text),
              const SizedBox(height: 8),
              Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}
