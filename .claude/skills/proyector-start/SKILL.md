---
name: proyector-start
description: >
  Instala el receptor de Proyector_13 (launcher "Familia HG", cola, Spotify→YouTube,
  trading, máscara) en un proyector o TV Android nuevo por ADB, dada su IP. Usar cuando el
  usuario escriba "/proyector-start <ip>" o pida "instala el proyector en <ip>",
  "configura otro proyector", "prepara esta TV". Pregunta antes de cada cambio al sistema.
argument-hint: <ip del proyector>
---

# /proyector-start $ARGUMENTS

Todo pasa por `tools/proyector-setup.sh <paso> <ip>` (en la raíz del repo). Cada paso es
idempotente: si algo ya está hecho, lo reporta y sigue. La IP es `$ARGUMENTS`; si viene
vacía, pídela.

Reglas:
- Nunca mostrar ni copiar el token de vinculación (`identity.json`) ni el `.env`: el repo es público.
- No reiniciar el equipo salvo que el usuario lo pida.
- Escribir en español, con el estado al final de cada paso ("Paso 3 de 7 listo: …").
- La IP del argumento puede traer basura (`192.168.68.192}`): quédate solo con dígitos y puntos.

## 1. Conectar

```
tools/proyector-setup.sh connect <ip>
```

Si falla, el mensaje dice cuál de estos casos es. Explícaselo al usuario y detente:
- **No responde en la red**: el equipo está apagado o tiene otra IP. Pide que lo prenda o que
  revise la IP en Ajustes → Red.
- **Responde pero sin ADB**: hay que activarlo a mano en el equipo.
  - Famifun / firmware Jixin: Ajustes generales → Configuración del sistema → Acerca de la
    proyección → tocar varias veces "Versión de Android". Escucha en el puerto 3333.
  - Otras marcas: Ajustes → Acerca de → tocar 7 veces "Compilación" → Opciones de
    desarrollador → Depuración por red (puerto 5555).
- **Pide autorización**: aceptar el aviso con la huella de la Mac en la pantalla del equipo.

## 2. Revisar (solo lectura)

```
tools/proyector-setup.sh inspect <ip>
```

Resume en una tabla corta: equipo, root sí/no, launcher actual (paquete del fabricante),
receptor y permisos, apps basura activas, bootup.sh y la IP. Las líneas `✓` ya están
hechas; las `•` son lo que falta.

## 2b. Seguridad primero (antes de instalar nada)

Los proyectores y TV box baratos pueden traer malware de fábrica (en 2026-10 un Rockchip
rk3326 traía un proxy residencial, un instalador disfrazado de Google y adware). Osvaldo
prioriza esto sobre todo lo demás.

```
tools/proyector-setup.sh scan <ip>
tools/proyector-setup.sh debloat <ip>     # lista de malware/basura conocida presente
```

- `scan` marca con ⚠: clases puestas directo en `com.google.android.` dentro de apps que no
  son de Google (disfraz), conexiones a internet de procesos que no son de Google/sistema, y
  malware conocido. Con •: apps que arrancan solas y no vienen de Play Store.
- Por cada ⚠ nuevo (que no esté en la lista de `debloat`), revisa sus componentes con
  `adb -s <serial> shell dumpsys package <pkg>` (servicios con nombres como
  "Persistence", "Ad", "Proxy", receptores de arranque, permiso INSTALL_PACKAGES) y explica
  qué parece. Revisa también `pm list packages -3`: apps con nombres mal escritos
  (`sevice`), proxys, tiendas del fabricante e IPTV pirata son sospechosas.
- Pregunta qué quitar (multiSelect). Osvaldo ya dijo que lo sospechoso se elimina,
  bloquea o neutraliza; aun así muestra la lista antes. Quita **primero los instaladores**
  (si no, alcanzan a reinstalar lo demás) y usa `debloat --apply` para los conocidos.
  Para lo nuevo: `pm uninstall <pkg>` si está en /data/app, `pm uninstall -k --user 0`
  si es del sistema (`disable-user` no basta: el fabricante lo reactiva).
- Después, `tools/proyector-setup.sh watch <ip>` en segundo plano (10 min). Si algo se
  instala solo, mira quién lo instaló (lo imprime), quítalo junto con su instalador y
  vigila otra vez. Si sigue volviendo, el malware está en el firmware: recomienda
  devolver el equipo o aislarlo en una red de invitados.
- Agrega lo nuevo a `UNINSTALL` en `tools/proyector-setup.sh` con un comentario, para el
  siguiente equipo.

Luego, una sola AskUserQuestion con dos preguntas:
- Pasos (multiSelect): instalar el receptor (siempre recomendado), hacerlo el inicio
  (nombra el launcher detectado), ADB al reiniciar (solo con root).
- Título del inicio: "¿Qué título quieres en el inicio?" con opciones "Familia HG"
  (el de la casa) y otra sugerencia; el usuario escribe el suyo en "Other".

## 3. Instalar el receptor

```
tools/proyector-setup.sh install <ip>
```

Compila `apps/proyector` (sin `.env`; el receptor no lo necesita), instala, da los 4
permisos (ventana encima, sesión de medios, ubicación para el Wi-Fi, Bluetooth) y abre la
app. Tarda ~1 min por la compilación. Se puede repetir sin riesgo.

## 4. Hacerlo el inicio

```
tools/proyector-setup.sh home <ip> <paquete-del-launcher-del-fabricante>
```

Solo con el sí del paso 2. El paquete sale de `inspect` ("launcher del fabricante: …").
Desactivar el del fabricante es lo único que funciona (set-home-activity y el rol HOME no
bastan). El script se niega si el receptor no está instalado, para no dejar el equipo sin
inicio, y verifica que el inicio cambió. Comparte la línea de cómo revertir.

## 4b. Título del inicio

```
tools/proyector-setup.sh title <ip> "<título>"
```

Con el título que eligió en el paso 2 (si eligió "Familia HG", no hace falta: es el de
por defecto). Funciona sin root: abre el receptor con el extra `homeTitle`, que lo guarda
en el equipo. Se puede cambiar cuando sea con el mismo comando.

## 4c. Hora

Si `inspect` dice que la hora no coincide con la Mac:

```
tools/proyector-setup.sh timezone <ip>          # America/Guatemala (UTC−6 todo el año)
tools/proyector-setup.sh timezone <ip> <zona>   # otra zona, p. ej. si el equipo está en otra región
```

Estos equipos traen datos de zona horaria anteriores a 2022 y creen que México todavía
cambia de horario: con "Ciudad de México" adelantan una hora. Requiere root; sin root,
explica cómo ponerla a mano (Ajustes → Fecha y hora → zona automática apagada → una zona
UTC−6 sin horario de verano, como Guatemala o Costa Rica).

## 5. Quitar apps basura

Ya cubierto en 2b (`debloat` trae la basura de Jixin y el malware de Rockchip). Nunca
quites el teclado, los ajustes, el Wi-Fi ni nada de Bluetooth (en Jixin,
`com.jixin.btspeaker` es parte del Bluetooth: sin él no empareja).

## 6. ADB al reiniciar

```
tools/proyector-setup.sh bootup <ip>
```

Solo con root. Es persistencia en el sistema: pide un sí explícito y muestra cómo quitarlo.
- Firmware Jixin (hay `/system/bin/jx_init.sh`): su `check_adb` apaga el ADB en cada
  arranque, así que se instala `/data/bootup.sh`, que lo vuelve a prender 40 s después y
  abre el inicio. Quitar: `su 0 rm /data/bootup.sh`.
- Otros (p. ej. Rockchip): basta `setprop persist.adb.tcp.port <puerto>`, que el script
  pone. Quitar: `su 0 setprop persist.adb.tcp.port ''`.
Sin esto, cada reinicio obliga a reactivar el ADB a mano.

## 7. Cierre

1. **IP fija** (siempre a mano, con el control; automatizarla editando
   WifiConfigStore.xml no funcionó porque el servicio de Wi-Fi reescribe el archivo desde
   memoria): Ajustes → Red → la red Wi-Fi → Ajustes de IP → Estática, con la IP elegida. Saca la máscara y el gateway de la línea "Red" de `inspect`
   (p. ej. `192.168.68.0/22` → máscara 255.255.252.0, prefijo 22, gateway y DNS
   `192.168.68.1`). Sin esto la IP cambia en cada reinicio (la MAC Wi-Fi es aleatoria).
2. **Vincular el teléfono**: una instalación nueva crea su propio código. En el proyector,
   elegir "Vincular teléfono" y escanear el QR desde la app de control (o "Pegar código").
   Si el teléfono no tiene la app: conectarlo por USB y
   `cd apps/control && flutter build apk --release --dart-define-from-file=../../.env`, luego
   `adb -s <serial-del-teléfono> install -r build/app/outputs/flutter-apk/app-release.apk`.
3. Correr `inspect` otra vez y mostrar el resultado: debería salir todo con `✓`.
