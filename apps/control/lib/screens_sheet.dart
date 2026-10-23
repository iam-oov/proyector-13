import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared/shared.dart';

import 'app_theme.dart';
import 'mask_page.dart';
import 'model.dart';
import 'roku.dart';
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
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Nombre', hintText: 'Recámara'),
          ),
          const SizedBox(height: 12),
          const Text(
            'Para TVs sin el receptor: la app abre YouTube con el video y sigue a Spotify. '
            'El teléfono tiene que estar en el mismo Wi-Fi que la TV.',
          ),
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
  if (model.error != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(model.error!)));
}

/// Roku TV: busca las que haya en el Wi-Fi del teléfono y, si no aparece, se
/// escribe su IP (Configuración → Red → Acerca de, en la Roku).
Future<void> addRokuDialog(BuildContext context, ControlModel model) async {
  final ip = TextEditingController();
  final name = TextEditingController();
  List<RokuFound>? found;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        if (found == null) {
          found = const [];
          model.discoverRokus().then((f) {
            if (context.mounted) setState(() => found = f);
          });
        }
        return AlertDialog(
          title: const Text('Agregar Roku TV'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final f in found!)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.tv_rounded),
                  title: Text(f.name),
                  subtitle: Text(f.host),
                  onTap: () => setState(() {
                    ip.text = f.host;
                    if (name.text.isEmpty) name.text = f.name;
                  }),
                ),
              if (found!.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Buscando Rokus en tu Wi-Fi… Si no aparece, escribe su IP.',
                    style: TextStyle(fontSize: 13, color: Palette.text2),
                  ),
                ),
              TextField(
                controller: ip,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'IP de la Roku', hintText: '192.168.100.20'),
              ),
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Nombre', hintText: 'Sala'),
              ),
              const SizedBox(height: 12),
              const Text(
                'La Roku se controla entera por red: prender, apagar, volumen, entradas y abrir '
                'Netflix, Disney+, Prime o YouTube directo en lo que pidas por voz.',
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Agregar')),
          ],
        );
      },
    ),
  );
  if (ok != true) return;
  await model.addRoku(ip.text.replaceAll(RegExp(r'[^0-9.]'), ''), name: name.text);
  if (!context.mounted) return;
  if (model.error != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(model.error!)));
}

/// Cambia la IP de una pantalla (el proyector se movió de red o el router le dio
/// otra). Para un proyector también ofrece buscarlo solo en la red.
Future<void> changeAddressDialog(BuildContext context, ControlModel model, Screen s) async {
  final controller = TextEditingController(text: s.hasReceiver ? s.address : s.host);
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
            decoration: InputDecoration(
              labelText: s.hasReceiver ? 'IP:puerto' : 'IP',
              hintText: s.hasReceiver ? '192.168.1.147:8080' : '192.168.1.40',
            ),
          ),
          const SizedBox(height: 10),
          Text(
            s.hasReceiver
                ? 'La ves en el proyector, en "Vincular teléfono". O deja que la app lo busque en tu Wi-Fi.'
                : s.isRoku
                    ? 'La ves en la Roku: Configuración → Red → Acerca de.'
                    : 'La ves en la TV: Ajustes → Red.',
            style: const TextStyle(fontSize: 13, color: Palette.text2),
          ),
        ],
      ),
      actions: [
        if (s.hasReceiver) TextButton(onPressed: () => Navigator.of(context).pop('scan'), child: const Text('Buscar en mi Wi-Fi')),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.of(context).pop('save'), child: const Text('Guardar')),
      ],
    ),
  );
  if (action == null) return;
  final found = action == 'scan' ? await model.rediscover(s.id) : null;
  if (action == 'save') await model.changeAddress(s.id, controller.text);
  if (!context.mounted) return;
  // Lo que salió bien llega como toast desde el modelo; aquí solo los fallos.
  final msg = found == false ? 'No encontré a ${s.name} en tu Wi-Fi: escribe su IP' : model.error;
  if (msg != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

/// Abre la cámara, y si el QR es de un proyector lo guarda y lo activa.
Future<void> scanAndAddScreen(BuildContext context, ControlModel model) async {
  if (!await ensurePhoneName(context, model)) return;
  if (!context.mounted) return;
  final payload = await Navigator.of(context).push<PairingPayload>(MaterialPageRoute(builder: (_) => const ScanPage()));
  if (payload == null) return;
  await model.addScreen(payload);
}

/// Abre la hoja de Pantallas: solo la lista para cambiar de equipo (se toca el
/// nombre de la pantalla arriba de cada pestaña).
Future<void> showScreensSheet(BuildContext context, ControlModel model) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ScreensSheet(model: model),
    );

/// Abre la hoja para agregar una pantalla (el "+" junto al nombre).
Future<void> showAddScreenSheet(BuildContext context, ControlModel model) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AddScreenSheet(model: model),
    );

/// Pantallas: cada equipo con su estado y sus acciones (menú ⋮).
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
                  child: Text(
                    'Todavía no hay pantallas. Agrega una con el + junto al nombre.',
                    style: TextStyle(fontSize: 14, color: Palette.text2, height: 1.35),
                  ),
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
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Código copiado: mándalo por WhatsApp y en el otro teléfono toca "Pegar código"')));
        }
        return;
      case 'remove':
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('¿Eliminar ${s.name}?'),
            content: Text(
              s.hasReceiver
                  ? 'El proyector deja de seguir a Spotify y se corta su cola. Para volver a usarlo hay que escanear su QR.'
                  : 'Para volver a usarla hay que agregarla otra vez por su IP.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Eliminar')),
            ],
          ),
        );
        if (ok != true || !context.mounted) return;
        // La hoja se cierra para que se vea el aviso de cómo quedó.
        final nav = Navigator.of(context);
        await model.removeScreen(s.id);
        nav.pop();
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
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Sala'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Guardar')),
        ],
      ),
    );
    if (name != null) await model.renameScreen(s.id, name);
  }
}

/// Agregar una pantalla: QR, código pegado, TV por IP o Roku; y "Tú": el nombre
/// con que te ven las pantallas y la sesión de Spotify de este teléfono.
class AddScreenSheet extends StatelessWidget {
  const AddScreenSheet({super.key, required this.model});

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
              const Text('Agregar pantalla', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _AddTile(
                      icon: Icons.qr_code_scanner_rounded,
                      label: 'Escanear QR',
                      onTap: () {
                        Navigator.of(context).pop();
                        scanAndAddScreen(context, model);
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    // Sin cámara: el código que otro teléfono copió y compartió.
                    child: _AddTile(
                      icon: Icons.content_paste_rounded,
                      label: 'Pegar código',
                      onTap: () {
                        Navigator.of(context).pop();
                        pasteAndAddScreen(context, model);
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    // TVs sin receptor (no Android): DIAL + YouTube.
                    child: _AddTile(
                      icon: Icons.live_tv_rounded,
                      label: 'TV por IP',
                      onTap: () {
                        Navigator.of(context).pop();
                        addTvDialog(context, model);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Roku TV: control completo por red, se encuentra sola en el Wi-Fi.
              _AddTile(
                icon: Icons.connected_tv_rounded,
                label: 'Roku TV (se busca sola en el Wi-Fi)',
                onTap: () {
                  Navigator.of(context).pop();
                  addRokuDialog(context, model);
                },
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
                      child: Text(
                        model.loggedIn ? 'Spotify conectado' : 'Spotify sin conectar',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
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
              Icon(
                s.isRoku
                    ? Icons.connected_tv_rounded
                    : s.isTv
                        ? Icons.tv_rounded
                        : Icons.videocam_rounded,
                color: selected ? Palette.accent : (on ? Palette.text2 : Palette.text3),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: on ? Palette.text : Palette.text2),
                    ),
                    Text(
                      '${s.kindLabel} · ${s.host}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: Palette.text2),
                    ),
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
                  if (s.hasReceiver) const PopupMenuItem(value: 'mask', child: Text('Máscara de proyección')),
                  if (spotifyLinked) const PopupMenuItem(value: 'unlink', child: Text('Desvincular Spotify del proyector')),
                  if (s.hasReceiver) const PopupMenuItem(value: 'copy', child: Text('Copiar código (para otro teléfono)')),
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
  const _AddTile({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Palette.surface2,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: SizedBox(
          height: 96,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 30, color: Palette.text),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Palette.text2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
