---
name: proyector-start
description: >
  Instala el receptor de Proyector_13 (launcher "Familia HG" con trading, Spotify, clima,
  dólar y temas; cola, Spotify→YouTube, máscara) en un proyector o TV Android nuevo por
  ADB, dada su IP. Usar cuando el
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
- **No es Android** (sale de código 2 y lista lo que encontró: DIAL, Roku, Samsung Tizen,
  LG webOS): sin ADB no se instala el receptor ni se limpia. Explica qué sí se puede: con
  DIAL, `tools/proyector-setup.sh play <ip> <videoId>` abre YouTube con un video (si la TV
  pide elegir cuenta, se elige con su control). Ejemplo: Hyundai HYLED3249NiM (Linux MStar)
  solo abre DIAL en :56789 con YouTube y Netflix.
- **No responde** (ni ADB ni servicios de TV): apagado, otra IP u otra red. El mensaje dice
  la IP de la Mac: si es de otra red que la TV, hay que cambiar el Wi-Fi de la Mac. Muchas
  TVs no contestan ping, así que no lo uses para decidir que está apagada. Si el receptor ya
  estaba instalado, su IP actual sale en el proyector en "Vincular teléfono" (debajo del
  nombre): pídesela al usuario antes de barrer la red.
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
receptor y permisos, apps basura activas, bootup.sh, hora y la IP. Las líneas `✓` ya están
hechas; las `•` son lo que falta. Si sale `⚠ ADB sin autorización` (`ro.adb.secure` en 0 o vacío, como en el Famifun),
díselo claro: cualquier aparato del Wi-Fi entra al equipo (con root si lo tiene) mientras
el ADB por red esté abierto; se resuelve en el paso 8.

**Respaldo:** el primer paso que cambia algo (home, debloat --apply, timezone, bootup, dns,
adbclose) guarda antes el estado del equipo en `~/.proyector-setup/<modelo>-<serie>.txt`
(fuera del repo): estado de cada paquete de las listas, dueño del inicio, zona horaria, DNS,
bootup.sh y puerto de ADB. Se guarda una sola vez: en un equipo nuevo es el de fábrica; en uno
que ya se había limpiado antes (el Famifun), es el estado de ese momento.
`tools/proyector-setup.sh restore <ip>` lo regresa todo (lo borrado de /data/app no vuelve:
era malware sin copia en el sistema).

Si el equipo se **restableció de fábrica** después de ese respaldo, el archivo ya no sirve
(`inspect` igual dice "estado previo guardado"): revisa su línea `home` y su fecha; si el
inicio ya era `dev.valdo.proyector`, renómbralo a `….<fecha>.bak` antes del primer cambio
para que se guarde el estado de fábrica nuevo.

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
  bloquea o neutraliza, y prefiere **eliminar** a solo desactivar; aun así muestra la lista
  antes. Tras `debloat --apply`, quita también para el usuario los de la lista DISABLE
  (`pm uninstall -k --user 0 <pkg>`, `restore` los regresa).
- En un Jixin **recién restablecido**, desactivar `com.jixin.guide` (el asistente de primer
  arranque) le borró el Wi-Fi guardado y se cortó el ADB: avisa antes de aplicar que quizá
  tenga que volver a escribir la contraseña del Wi-Fi en el proyector (la IP se conservó). Quita **primero los instaladores**
  (si no, alcanzan a reinstalar lo demás) y usa `debloat --apply` para los conocidos.
  Para lo nuevo: `pm uninstall <pkg>` si está en /data/app, `pm uninstall -k --user 0`
  si es del sistema (`disable-user` no basta: el fabricante lo reactiva).
- Después, `tools/proyector-setup.sh watch <ip>` en segundo plano (10 min). Si algo se
  instala solo, mira quién lo instaló (lo imprime), quítalo junto con su instalador y
  vigila otra vez. Si sigue volviendo, el malware está en el firmware: recomienda
  devolver el equipo o aislarlo en una red de invitados.
- Agrega lo nuevo a `UNINSTALL` en `tools/proyector-setup.sh` con un comentario, para el
  siguiente equipo.

Nunca quites lo que está en `PROTECT` del script (keystone de Droidlogic: sin él se deforma
la imagen proyectada; btspeaker de Jixin; teclado; ajustes; Wi-Fi; Bluetooth): `debloat` ya
lo salta, y lo mismo vale para lo que propongas a mano.

Luego, una sola AskUserQuestion con dos preguntas:
- Pasos (multiSelect): instalar el receptor (siempre recomendado), hacerlo el inicio
  (nombra el launcher detectado), ADB al reiniciar (solo con root), DNS que bloquea
  anuncios (Android 9+), quitar las apps que no funcionan (paso 5b; nombra las que haya).
- Título del inicio: "¿Qué título quieres en el inicio?" con opciones "Familia HG"
  (el de la casa) y otra sugerencia; el usuario escribe el suyo en "Other".

## 3. Instalar el receptor

```
tools/proyector-setup.sh install <ip>
```

Compila `apps/proyector` (sin `.env`; el receptor no lo necesita), instala, da los 5
permisos (ventana encima, sesión de medios, ubicación para el Wi-Fi, Bluetooth y uso de
apps para ordenarlas por la última vez que se abrieron) y abre la app. Tarda ~1 min por la
compilación. Se puede repetir sin riesgo.

Qué trae el inicio (para explicárselo al usuario al final):
- Arriba: título, dólar en pesos (Yahoo), clima de la ubicación de la IP pública
  (Open-Meteo; si no hay ubicación, no se muestra), fecha y hora.
- Centro: las acciones (P&L del día, posiciones; con el control se entra a cada una y OK abre
  su detalle) y lo que suena en Spotify. Sin trading, Spotify ocupa el centro.
- Una fila de apps (banners de TV, la usada más reciente primero, Play Store al final) que se
  desplaza a lo ancho.
- Abajo, botones redondos que dicen su nombre con el foco: Trading ON/OFF (aro verde cuando
  está prendido), Vincular teléfono, Ajustes y la bolita de temas (rosa → blanco → carbón).
  El tema y el trading se guardan en cada equipo.
- Ya no existe "prender/apagar desde el teléfono": solo apagaba la imagen y gastaba la
  lámpara. Si un equipo tenía el administrador del dispositivo `.PowerAdmin`, Android lo
  quita solo al actualizar el receptor.

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

## 5b. Quitar las apps que no funcionan (opcional)

Estos equipos no están certificados por Google, y algunas apps de streaming instaladas no
sirven. Si `pm list packages` muestra alguna, ofrécela en la pregunta del paso 2b:
- **Netflix** (`com.netflix.ninja`, `com.netflix.mediaclient`): dice "no es compatible".
- **Disney+ de fábrica** (`com.disney.disneyplus` en `/odm/bundled_uninstall_back-app`):
  pide versión nueva y se cierra al tocar.

Con el sí del usuario:

```
adb -s <serial> shell pm uninstall <paquete>            # si está en /data/app
adb -s <serial> shell pm uninstall --user 0 <paquete>   # si viene de fábrica (/odm, /system)
```

Lo de fábrica se puede regresar con `adb -s <serial> shell cmd package install-existing <paquete>`.
El inicio se actualiza solo al volver a él.

Excepción: si lo instaló la Play Store (`dumpsys package <paquete> | grep installerPackageName`
dice `com.android.vending`, típico de `com.netflix.ninja`), **no lo borres**: la Play Store lo
reinstala sola a los pocos minutos (pasó en ProyectorBasico). Desactívalo:
`pm disable-user --user 0 <paquete>`. Instalado pero desactivado, la Play Store no lo toca y el
inicio no lo muestra. Regresar: `pm enable <paquete>`.

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

## 6b. DNS que bloquea anuncios (opcional)

```
tools/proyector-setup.sh dns <ip> on     # dns.adguard-dns.com en todo el equipo
tools/proyector-setup.sh dns <ip> off    # vuelve al automático
```

Bloquea anuncios y rastreadores de las apps y del sistema, y sobrevive reinicios. No quita
los anuncios de YouTube. Contra: AdGuard ve las consultas DNS del equipo. Si con él el
equipo se queda sin internet, el script regresa solo al DNS automático.

## 7. Cierre

1. **IP fija** (siempre a mano, con el control; automatizarla editando
   WifiConfigStore.xml no funcionó porque el servicio de Wi-Fi reescribe el archivo desde
   memoria): Ajustes → Red → la red Wi-Fi → Ajustes de IP → Estática. Dale los valores
   campo por campo, sacados de la línea "Red" de `inspect` (p. ej. `192.168.68.0/22`):
   Dirección IP = la actual, **Puerta de enlace** = `192.168.68.1`, **Longitud del prefijo
   de red** = `22`, DNS 1 = `192.168.68.1`. No digas "máscara": el formulario no la pide, y
   en el Famifun alguien la escribió en Puerta de enlace y el equipo se quedó sin internet
   (Android avisa "DNS privado"; `dumpsys wifi | grep "Static configuration"` muestra el
   gateway). Sin IP fija la IP cambia en cada reinicio (la MAC Wi-Fi es aleatoria).
2. **Vincular el teléfono**: una instalación nueva crea su propio código. En el proyector,
   elegir "Vincular teléfono" y escanear el QR desde la app de control (o "Pegar código").
   Si el teléfono no tiene la app: conectarlo por USB y
   `cd apps/control && flutter build apk --release --dart-define-from-file=../../.env`, luego
   `adb -s <serial-del-teléfono> install -r build/app/outputs/flutter-apk/app-release.apk`.
3. Correr `inspect` otra vez y mostrar el resultado: debería salir todo con `✓`.
4. Contarle al usuario qué trae el inicio (lista del paso 3) y que el trading se apaga con el
   primer botón de abajo si no le interesa.

## 8. Cerrar el ADB (seguridad)

Si `inspect` mostró `⚠ ADB sin autorización`, recomienda cerrarlo al terminar:

```
tools/proyector-setup.sh adbclose <ip>
```

Corta la conexión. En Jixin mueve `/data/bootup.sh` a `/data/bootup.sh.off` (su
`check_adb` lo deja apagado en cada arranque); en otros borra `persist.adb.tcp.port`. El
receptor, el inicio y el teléfono siguen funcionando sin ADB. Contra: para volver a
administrar el equipo hay que reactivar el ADB a mano (paso 1) y, en Jixin, regresar
`bootup.sh.off` a `bootup.sh`. Pregunta antes: es decisión del usuario dejarlo abierto
(cómodo) o cerrado (seguro).

## Restaurar

```
tools/proyector-setup.sh restore <ip>
```

Regresa lo guardado en el respaldo (ver paso 2). El receptor queda instalado; se quita en
Ajustes → Apps.

