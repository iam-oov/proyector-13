#!/bin/zsh
# Instala el receptor (apps/proyector) en un proyector o TV Android nuevo por ADB.
# Lo orquesta la skill /proyector-start; cada paso se puede correr solo y es
# idempotente (correrlo otra vez no rompe nada).
#
#   tools/proyector-setup.sh connect <ip>           conecta (prueba :5555 y :3333)
#   tools/proyector-setup.sh inspect <ip>           solo lectura: qué hay y qué falta
#   tools/proyector-setup.sh install <ip>           compila, instala, da permisos y abre la app
#   tools/proyector-setup.sh home    <ip> <pkg>     desactiva el launcher del fabricante
#   tools/proyector-setup.sh title   <ip> "<texto>" título del inicio (por defecto "Familia HG")
#   tools/proyector-setup.sh debloat <ip> [--apply] quita apps basura/malware conocidas (sin --apply solo lista)
#   tools/proyector-setup.sh bootup  <ip>           ADB por red al arrancar (con root)
#   tools/proyector-setup.sh timezone <ip> [zona]   zona horaria fija (con root; ver TZ_DEFAULT)
#   tools/proyector-setup.sh scan    <ip>           busca malware: apps disfrazadas, arranque sin Play, conexiones
#   tools/proyector-setup.sh watch   <ip> [seg]     vigila si algo se instala solo (600 s por defecto)
#   tools/proyector-setup.sh dns     <ip> on|off    DNS privado que bloquea anuncios y rastreadores (AdGuard)
#   tools/proyector-setup.sh adbclose <ip>          cierra el ADB por red (seguridad; se reabre a mano en el equipo)
#   tools/proyector-setup.sh restore <ip>           regresa el equipo al estado guardado antes del primer cambio
#   tools/proyector-setup.sh probe   <ip>           sin ADB: identifica la TV (DIAL, Roku, Samsung, LG)
#   tools/proyector-setup.sh play    <ip> <videoId> sin ADB: abre un video de YouTube por DIAL
#
# Antes del primer cambio guarda el estado del equipo en ~/.proyector-setup/ (fuera
# del repo) para que `restore` lo pueda deshacer.
# Nunca imprime el token de vinculación (identity.json) ni nada del .env.

set -u

ROOT=${0:A:h:h}
APP=dev.valdo.proyector
PORTS=(5555 3333)

# Apps basura y malware conocidos. Solo se tocan las que estén instaladas.
# - DISABLE: `pm disable-user` (se revierte con `pm enable <pkg>`).
# - UNINSTALL: reviven solas tras desactivarlas. Las de /data/app se borran del
#   todo (`pm uninstall`); las del sistema solo para el usuario
#   (`pm uninstall -k --user 0`, se revierte con `cmd package install-existing`).
#   Los instaladores van primero: si no, alcanzan a reinstalar lo que se quita.
# Jixin/Amlogic (Famifun V1): NO tocar com.jixin.btspeaker, sin sus servicios el
# Bluetooth deja de emparejar.
# Rockchip rk3326 "txbox"/"txcz" (2026-10): traía malware tipo BadBox, ver
# comentarios en UNINSTALL.
DISABLE=(
  # Sistema de anuncios de Android y su personalización (Android 13+); no los usa nada
  # de lo que se ve en un proyector (lista de cleanyourtv, Stellamore T950S).
  com.android.adservices.api com.android.ondevicepersonalization.services
  com.jixin.analytics com.jixin.ota com.jixin.appstore2 com.jixin.music
  com.jixin.guide com.jixin.factorytest com.jixin.launcher2
  cn.wps.moffice_i18n_TV com.droidlogic.exoplayer2.demo
  com.google.android.feedback com.android.printspooler
  com.google.android.marvin.talkback
)
UNINSTALL=(
  # Rockchip: instaladores primero (bajan e instalan apps en silencio)
  com.shzhtxcz.txbox com.sszztxr.app com.sszztxr.oott
  com.android.rk com.rockchip.itvbox   # RkService disfrazado de com.google.android
  # Rockchip: lo que instalan y el resto del software de fábrica
  com.driots.sevice                    # UltraPersistenceService, se instala al conectar al Wi-Fi
  com.proxypeer.peerapp                # proxy residencial: vende tu conexión
  com.aispeech.tvui                    # asistente de voz con AdService
  com.android.mgstv                    # Magis TV (pirata)
  com.oranth.accessibility com.shzhtxcz.txcz.test com.rockchip.devicetest
  # Jixin
  com.google.android.katniss com.google.android.tvrecommendations
  com.define.shellservice com.jixin.filebrowser
  com.toofifi.miracast com.android.toofifi com.clap.netflix
)

# Nunca se tocan, aunque aparezcan en una lista o los proponga alguien:
# - com.droidlogic.keystone: corrección de trapecio; sin él se deforma la imagen proyectada.
# - com.jixin.btspeaker: parte del Bluetooth de Jixin; sin él no empareja.
# - teclado, ajustes, Wi-Fi y Bluetooth del sistema.
PROTECT=(
  com.droidlogic.keystone com.jixin.btspeaker com.jixin.settings5 com.jixin.wifi
  org.liskovsoft.androidtv.rukeyboard com.android.inputmethod.latin
  com.android.tv.settings com.android.settings com.android.bluetooth
  com.android.vending dev.valdo.proyector
)

# DNS privado que bloquea anuncios y rastreadores en todo el equipo (Android 9+). No
# quita los anuncios de YouTube (salen de los mismos servidores que los videos).
DNS_HOST=dns.adguard-dns.com

# Registro del estado previo, uno por equipo (modelo-serie), fuera del repo.
RECORD_DIR=$HOME/.proyector-setup

# México quitó el horario de verano en 2022, pero estos equipos traen datos de zona
# horaria más viejos (2021a, 2022a): con America/Mexico_City adelantan una hora y con
# America/Chihuahua se atrasan al acabar octubre. Guatemala es UTC−6 todo el año
# (la hora del centro de México) en cualquier versión de esos datos.
TZ_DEFAULT=America/Guatemala

die() { print -u2 "✕ $*"; exit 1; }
ok() { print "✓ $*"; }
todo() { print "• $*"; }

# Serial ya conectado para la IP (ip:puerto), o vacío.
serial_for() {
  adb devices | awk -v ip="$1" 'index($1, ip":") == 1 && $2 == "device" { print $1; exit }'
}

connect() {
  local ip=$1 s
  s=$(serial_for "$ip")
  if [[ -n $s ]]; then print "$s"; return 0; fi
  for p in $PORTS; do
    # nc primero: `adb connect` a un puerto cerrado tarda más de un minuto en rendirse.
    nc -z -G 2 "$ip" "$p" 2>/dev/null || continue
    adb connect "$ip:$p" >/dev/null 2>&1
    s=$(serial_for "$ip")
    if [[ -n $s ]]; then print "$s"; return 0; fi
    # Algunas TVs piden aceptar la huella de la Mac en pantalla.
    if adb devices | grep -q "^$ip:$p[[:space:]]unauthorized"; then
      die "$ip:$p pide autorización: acepta el aviso en la pantalla y vuelve a correr"
    fi
  done
  return 1
}

sh_() { adb -s "$S" shell "$@" 2>/dev/null | tr -d '\r'; }
has_root() { [[ $(sh_ 'su 0 id -u' 2>/dev/null) == 0 ]]; }
# Instalada para el usuario 0 (activa o desactivada; no cuenta si se quitó con uninstall -k).
installed() { sh_ pm list packages "$1" | grep -qx "package:$1"; }
home_activity() { sh_ cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1; }

protected() { (( ${PROTECT[(Ie)$1]} )); }

# Identifica una TV sin ADB por los servicios que abre. Imprime lo que se puede hacer.
probe() {
  local ip=$1 found=0 p
  print "Sin ADB en $ip. Buscando otros servicios…"
  for p in 56789 8008 8060 7676; do
    nc -z -G 2 "$ip" $p 2>/dev/null || continue
    local apps=()
    for a in YouTube Netflix; do
      curl -s -m 3 "http://$ip:$p/apps/$a" | grep -q "<name>$a</name>" && apps+=($a)
    done
    if (( ${#apps} )); then
      found=1; ok "DIAL en :$p con ${apps[*]}: se puede abrir un video (\`play $ip <videoId>\`)"
    fi
  done
  if nc -z -G 2 "$ip" 8060 2>/dev/null; then
    found=1; ok "Roku (ECP :8060): $(curl -s -m 3 http://$ip:8060/query/device-info | sed -n 's:.*<model-name>\(.*\)</model-name>.*:\1:p')"
  fi
  if nc -z -G 2 "$ip" 8001 2>/dev/null; then
    found=1; ok "Samsung Tizen (:8001): $(curl -s -m 3 http://$ip:8001/api/v2/ | sed -n 's/.*"modelName":"\([^"]*\)".*/\1/p')"
  fi
  if nc -z -G 2 "$ip" 3000 2>/dev/null || nc -z -G 2 "$ip" 3001 2>/dev/null; then
    found=1; ok "LG webOS (SSAP :3000/:3001)"
  fi
  if (( found )); then
    print "No es Android: sin ADB no se instala el receptor ni se limpia. Se controla por la red."
    return 0
  fi
  return 1
}

# YouTube por DIAL: abre la app con el video. Si la TV pide elegir cuenta, se queda ahí.
dial_play() {
  local ip=$1 vid=$2 p
  for p in 56789 8008; do
    curl -s -m 3 "http://$ip:$p/apps/YouTube" | grep -q '<name>YouTube</name>' || continue
    local code; code=$(curl -s -m 8 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: text/plain; charset=utf-8' --data "v=$vid" "http://$ip:$p/apps/YouTube")
    [[ $code == 201 || $code == 200 ]] || die "la TV respondió $code"
    ok "YouTube abierto en $ip con el video $vid (si pide cuenta, hay que elegirla con el control)"
    return
  done
  die "$ip no tiene YouTube por DIAL"
}

# Guarda el estado previo una sola vez por equipo: el primero es el de fábrica.
record() {
  local f="$RECORD_DIR/$(sh_ getprop ro.product.model | tr ' /' '__')-$(sh_ getprop ro.serialno).txt"
  [[ -f $f ]] && return
  mkdir -p "$RECORD_DIR"
  {
    print "# Estado antes de /proyector-start, $(date '+%Y-%m-%d %H:%M'), $S"
    print "home $(home_activity)"
    print "tz $(sh_ getprop persist.sys.timezone)"
    print "autotz $(sh_ settings get global auto_time_zone)"
    print "dns $(sh_ settings get global private_dns_mode) $(sh_ settings get global private_dns_specifier)"
    print "bootup $([[ -n $(sh_ 'su 0 ls /data/bootup.sh' 2>/dev/null) ]] && print yes || print no)"
    print "adbport $(sh_ getprop persist.adb.tcp.port)"
    local disabled; disabled=$(sh_ pm list packages -d)
    local oem=${$(home_activity)%%/*}
    for p in $DISABLE $UNINSTALL $oem; do
      [[ -n $p && $p != $APP ]] || continue
      if ! installed $p; then print "pkg $p absent"
      elif [[ $disabled == *"package:$p"* ]]; then print "pkg $p disabled"
      else print "pkg $p enabled"; fi
    done
  } > "$f"
  ok "estado previo guardado en $f"
}

record_file() { print "$RECORD_DIR/$(sh_ getprop ro.product.model | tr ' /' '__')-$(sh_ getprop ro.serialno).txt"; }

restore() {
  local f; f=$(record_file)
  [[ -f $f ]] || die "no hay registro de este equipo en $RECORD_DIR"
  local key a b
  while read key a b; do
    case $key in
      pkg)
        [[ $b == enabled ]] || continue
        if installed $a; then sh_ pm enable $a >/dev/null && ok "reactivada $a"
        elif [[ -n $(sh_ cmd package install-existing $a 2>&1 | grep -i 'installed') ]]; then ok "reinstalada $a"
        else todo "$a no se puede regresar (se borró del todo: no venía del sistema)"; fi ;;
      home)
        [[ -n $a && $a != $APP/* ]] || continue
        sh_ pm enable ${a%%/*} >/dev/null
        sh_ cmd package set-home-activity $a >/dev/null
        ok "inicio del fabricante de vuelta: $a" ;;
      tz) [[ -n $a ]] && has_root && sh_ "su 0 cmd time_zone_detector suggest_manual_time_zone --zone_id $a" >/dev/null && ok "zona horaria $a" ;;
      autotz) [[ -n $a ]] && sh_ settings put global auto_time_zone $a ;;
      dns)
        # "null" = nunca se configuró: se borra y Android usa su automático.
        if [[ -z $a || $a == null ]]; then sh_ settings delete global private_dns_mode >/dev/null
        else sh_ settings put global private_dns_mode $a; fi
        if [[ -z $b || $b == null ]]; then sh_ settings delete global private_dns_specifier >/dev/null
        else sh_ settings put global private_dns_specifier $b; fi
        ok "DNS como estaba (${a/null/automático})" ;;
      bootup) [[ $a == no ]] && has_root && sh_ 'su 0 rm -f /data/bootup.sh' && ok "bootup.sh quitado" ;;
      adbport) [[ -z $a ]] && has_root && sh_ "su 0 setprop persist.adb.tcp.port ''" ;;
    esac
  done < <(grep -v '^#' "$f")
  print "El receptor sigue instalado: quítalo en Ajustes → Apps si ya no lo quieres."
}

set_dns() {
  local mode=${1:-on}
  (( $(sh_ getprop ro.build.version.sdk) >= 28 )) || die "el DNS privado necesita Android 9 o más"
  record
  if [[ $mode == off ]]; then
    sh_ settings put global private_dns_mode opportunistic
    ok "DNS privado apagado (automático)"; return
  fi
  sh_ settings put global private_dns_specifier $DNS_HOST
  sh_ settings put global private_dns_mode hostname
  # Android tarda ~10 s en validar el DNS privado: se reintenta hasta 30 s. Si nunca
  # responde, el equipo se queda "sin internet": se revierte solo.
  local i
  for i in 1 2 3 4 5 6; do
    sleep 5
    if sh_ ping -c 1 -W 4 www.google.com | grep -q '1 received\|1 packets received'; then
      ok "DNS bloqueador activo ($DNS_HOST) · quitar: dns <ip> off"
      return
    fi
  done
  sh_ settings put global private_dns_mode opportunistic
  die "con $DNS_HOST el equipo se quedó sin internet; regresé al DNS automático"
}

# Cierra el ADB por red. En equipos con ro.adb.secure=0 cualquier aparato del Wi-Fi
# entra sin pedir permiso, así que conviene cerrarlo al terminar. Corta esta conexión.
adb_close() {
  record
  local port=${S##*:}
  if [[ -n $(sh_ 'su 0 ls /data/bootup.sh' 2>/dev/null) ]]; then
    # Sin bootup.sh, check_adb de Jixin lo deja apagado en cada arranque.
    sh_ 'su 0 mv /data/bootup.sh /data/bootup.sh.off'
    ok "bootup.sh desactivado (queda en /data/bootup.sh.off)"
  fi
  has_root && sh_ "su 0 setprop persist.adb.tcp.port ''"
  sh_ settings put global adb_enabled 0
  print "Cerrando el ADB por red en el puerto $port…"
  sh_ "su 0 sh -c 'setprop service.adb.tcp.port -1; stop adbd; start adbd' &" 
  sleep 4
  if nc -z -G 2 ${S%%:*} $port 2>/dev/null; then todo "el puerto $port sigue abierto: apágalo en el equipo (depuración)"
  else ok "ADB por red cerrado. Para volver a entrar hay que reactivarlo en el equipo."; fi
}

inspect() {
  print "Equipo:   $(sh_ getprop ro.product.manufacturer) $(sh_ getprop ro.product.model) · Android $(sh_ getprop ro.build.version.release) · $(sh_ getprop ro.product.cpu.abi)"
  print "Conexión: $S"
  if has_root; then ok "root disponible (su)"
  else todo "sin root (ro.debuggable=$(sh_ getprop ro.debuggable)): debloat sí, bootup no"; fi
  # adbd pide autorización solo con ro.adb.secure=1; vacío (Famifun) o 0 = entra cualquiera.
  local secure; secure=$(sh_ getprop ro.adb.secure)
  if [[ $secure != 1 ]]; then
    print "⚠ ADB sin autorización (ro.adb.secure=${secure:-vacío}): cualquier aparato de tu Wi-Fi entra$(has_root && print ' con root'). Al terminar: \`adbclose\`"
  fi
  [[ -f $(record_file) ]] && ok "estado previo guardado (\`restore\` lo regresa)"

  local home; home=$(home_activity)
  if [[ $home == $APP/* ]]; then ok "el inicio ya es nuestro launcher"
  else todo "inicio actual: ${home:-ninguno/selector} (launcher del fabricante: ${home%%/*})"; fi

  if installed $APP; then
    ok "receptor instalado"
    [[ $(sh_ appops get $APP SYSTEM_ALERT_WINDOW) == *allow* ]] && ok "permiso: ventana encima" || todo "falta permiso: ventana encima"
    [[ $(sh_ settings get secure enabled_notification_listeners) == *$APP* ]] && ok "permiso: sesión de medios (cola)" || todo "falta permiso: sesión de medios"
    local perms; perms=$(sh_ dumpsys package $APP)
    for p in ACCESS_FINE_LOCATION BLUETOOTH_CONNECT; do
      print -r -- "$perms" | grep -q "android.permission.$p: granted=true" && ok "permiso: $p" || todo "falta permiso: $p"
    done
    [[ $(sh_ appops get $APP GET_USAGE_STATS) == *allow* ]] && ok "permiso: uso de apps (orden del inicio)" || todo "falta permiso: uso de apps (orden del inicio)"
  else
    todo "receptor NO instalado"
  fi

  local present=() disabled; disabled=$(sh_ pm list packages -d)
  for p in $DISABLE; do
    installed $p && [[ $disabled != *"package:$p"* ]] && present+=($p)
  done
  for p in $UNINSTALL; do
    installed $p && present+=($p)
  done
  if (( ${#present} )); then todo "apps basura activas: ${present[*]}"
  else ok "sin apps basura conocidas activas"; fi

  if [[ -n $(sh_ 'ls /system/bin/jx_init.sh') ]]; then
    if [[ -n $(sh_ 'su 0 ls /data/bootup.sh') ]]; then ok "bootup.sh instalado (ADB vuelve solo al reiniciar)"
    else todo "firmware Jixin sin bootup.sh: el ADB se apaga en cada reinicio"; fi
  fi
  local dev_t mac_t
  dev_t=$(sh_ date +%H:%M); mac_t=$(date +%H:%M)
  if [[ $dev_t == $mac_t ]]; then ok "hora correcta ($dev_t, $(sh_ getprop persist.sys.timezone))"
  else todo "hora del equipo $dev_t ≠ Mac $mac_t ($(sh_ getprop persist.sys.timezone)): falta \`timezone\`"; fi
  print "Red:      $(sh_ ip route | awk '/wlan0|eth0/ && /src/ { print $1, "→ IP", $NF; exit }')"
}

install_app() {
  (cd "$ROOT/apps/proyector" && flutter build apk --release >/dev/null) || die "falló flutter build"
  local apk="$ROOT/apps/proyector/build/app/outputs/flutter-apk/app-release.apk"
  adb -s "$S" install -r "$apk" | tail -1
  # Lanzar YouTube desde segundo plano, la máscara y la tarjeta de trading.
  sh_ appops set $APP SYSTEM_ALERT_WINDOW allow
  # Cola: leer la sesión de medios de YouTube.
  sh_ cmd notification allow_listener $APP/$APP.MediaListener
  # Wi-Fi y Bluetooth en el inicio.
  sh_ pm grant $APP android.permission.ACCESS_FINE_LOCATION
  sh_ pm grant $APP android.permission.BLUETOOTH_CONNECT
  # Ordenar las apps del inicio por la última vez que se abrieron.
  sh_ appops set $APP GET_USAGE_STATS allow
  # Abrirla una vez: BOOT_COMPLETED solo llega a apps que ya se abrieron.
  sh_ am start -n $APP/.MainActivity >/dev/null
  ok "receptor instalado con permisos y abierto"
}

set_home() {
  local oem=$1
  installed $APP || die "primero instala el receptor (sin él el equipo se queda sin inicio)"
  [[ $oem == $APP ]] && { ok "el inicio ya es nuestro launcher"; return; }
  record
  # set-home-activity y el rol HOME no bastan: hay que desactivar el del fabricante.
  sh_ pm disable-user --user 0 "$oem"
  sh_ input keyevent KEYCODE_HOME
  [[ $(home_activity) == $APP/* ]] || die "el inicio no cambió (revertir: adb -s $S shell pm enable $oem)"
  ok "inicio = nuestro launcher · revertir: adb -s $S shell pm enable $oem"
}

set_timezone() {
  local zone=${1:-$TZ_DEFAULT}
  has_root || die "sin root: cambia la zona a mano en Ajustes → Fecha y hora"
  record
  # Sin root el shell no tiene SUGGEST_MANUAL_TIME_AND_ZONE.
  sh_ settings put global auto_time_zone 0
  sh_ "su 0 cmd time_zone_detector suggest_manual_time_zone --zone_id $zone" >/dev/null
  [[ $(sh_ getprop persist.sys.timezone) == $zone ]] || die "no se aplicó la zona $zone"
  ok "zona horaria $zone · hora del equipo $(sh_ date +%H:%M), Mac $(date +%H:%M)"
}

set_title() {
  local t=$1
  [[ -n $t ]] || die "falta el título"
  installed $APP || die "primero instala el receptor"
  # (qq): el texto llega como un solo argumento al shell del equipo, con espacios y acentos.
  sh_ "am start -n $APP/.MainActivity --es homeTitle ${(qq)t}" >/dev/null
  sh_ input keyevent KEYCODE_HOME
  ok "título del inicio: $t"
}

debloat() {
  local apply=${1:-} disabled; disabled=$(sh_ pm list packages -d)
  # `where` se declara aquí: en zsh, `local` repetido dentro del ciclo imprime su valor.
  local n=0 where
  [[ $apply == --apply ]] && record
  for p in $DISABLE; do
    protected $p && continue
    installed $p && [[ $disabled != *"package:$p"* ]] || continue
    (( n++ ))
    if [[ $apply == --apply ]]; then sh_ pm disable-user --user 0 $p >/dev/null; ok "desactivada $p · revertir: pm enable $p"
    else todo "desactivar $p"; fi
  done
  for p in $UNINSTALL; do
    protected $p && continue
    installed $p || continue
    (( n++ ))
    where=$(sh_ pm path $p)
    if [[ $apply != --apply ]]; then todo "quitar $p"
    elif [[ $where == *package:/data/app/* ]]; then
      sh_ am force-stop $p; sh_ pm uninstall $p >/dev/null; ok "borrada $p (no viene del sistema)"
    else
      sh_ am force-stop $p; sh_ pm uninstall -k --user 0 $p >/dev/null; ok "quitada $p · revertir: cmd package install-existing $p"
    fi
  done
  (( n )) || ok "nada que limpiar de la lista conocida"
  [[ $apply == --apply || $n == 0 ]] || print "(solo lista; con --apply se aplica)"
}

bootup() {
  has_root || die "sin root: el ADB por red no se puede dejar fijo"
  record
  local port=${S##*:}
  if [[ -z $(sh_ 'ls /system/bin/jx_init.sh') ]]; then
    # Sin el apagado de check_adb (p. ej. Rockchip) basta la propiedad persistente.
    sh_ "su 0 setprop persist.adb.tcp.port $port"
    sh_ "su 0 settings put global adb_enabled 1"
    [[ $(sh_ getprop persist.adb.tcp.port) == $port ]] || die "no se pudo fijar persist.adb.tcp.port"
    ok "ADB por red fijo en el puerto $port · quitar: adb -s $S shell su 0 setprop persist.adb.tcp.port ''"
    return
  fi
  # jx_init.sh lo ejecuta como root en cada arranque; check_adb apaga el ADB antes.
  adb -s "$S" shell "su 0 sh -c 'cat > /data/bootup.sh && chmod 755 /data/bootup.sh'" <<EOF
#!/system/bin/sh
# Lo ejecuta jx_init.sh como root en cada arranque. Para quitarlo: rm /data/bootup.sh
# 1) Reactiva ADB por red en el puerto $port (check_adb lo apaga al arrancar).
# 2) Abre la pantalla de inicio (HOME = nuestro launcher $APP).
(
  sleep 40
  setprop service.adb.tcp.port $port
  settings put global adb_enabled 1
  start adbd
  am start -a android.intent.action.MAIN -c android.intent.category.HOME
) &
EOF
  [[ -n $(sh_ 'su 0 ls /data/bootup.sh') ]] || die "no se pudo escribir /data/bootup.sh"
  ok "bootup.sh instalado (puerto $port) · quitar: adb -s $S shell su 0 rm /data/bootup.sh"
}

# Busca señales de malware sin tocar nada. No es un antivirus: marca lo que vale
# la pena revisar a mano.
scan() {
  local p cls inst
  # 1) Clases puestas directo en com.google.android. dentro de apps que no son de
  #    Google: así se escondían com.android.rk e itvbox (com.google.android.RkService)
  #    y el adware de aispeech (com.google.android.AdService). Las librerías
  #    legítimas viven más adentro (com.google.android.gms.…, .tv.settings.…).
  sh_ dumpsys package r | sed -n 's/^ *[0-9a-f]\{6,\} \([^/ ]*\)\/\([^ ]*\).*/\1 \2/p' | sort -u |
    while read p cls; do
      [[ $cls == .* ]] && cls=$p$cls
      [[ $cls == com.google.android.[A-Z]* && $p != com.google.* ]] || continue
      print "⚠ disfrazada: $p trae $cls"
    done | sort -u
  # 2) Apps que arrancan solas al prender y no vinieron de Play Store ni del sistema base.
  for p in $(sh_ cmd package query-receivers --brief -a android.intent.action.BOOT_COMPLETED | sed -n 's/^ *\([^/ ]*\)\/.*/\1/p' | sort -u); do
    [[ $p == com.android.* || $p == com.google.* || $p == android || $p == $APP ]] && continue
    inst=$(sh_ dumpsys package $p | sed -n 's/.*installerPackageName=\([^ ]*\).*/\1/p' | head -1)
    [[ $inst == com.android.vending ]] && continue
    print "• arranca sola: $p (instalada por: ${inst:-el sistema})"
  done
  # 3) Conexiones a internet abiertas por procesos que no son de Google ni del sistema.
  if has_root; then
    sh_ "su 0 netstat -tnp" | awk '$6 == "ESTABLISHED" && $5 !~ /^(127\.|::1|::ffff:127\.)/ { print $5, $7 }' |
      grep -vE ' [0-9]+/(com\.google\.|com\.android\.|adbd|netd|system_server|dev\.valdo)' |
      while read dest proc; do
        # Las apps de Play Store (Spotify, Disney+…) se conectan a lo suyo: solo aviso.
        inst=$(sh_ dumpsys package ${proc#*/} | sed -n 's/.*installerPackageName=\([^ ]*\).*/\1/p' | head -1)
        if [[ $inst == com.android.vending ]]; then print "• conexión (app de Play Store): $proc → $dest"
        else print "⚠ conexión: $proc → $dest"; fi
      done
  fi
  # 4) Malware ya conocido.
  for p in $UNINSTALL; do installed $p && print "⚠ conocido: $p"; done
  print "(revisión terminada; ⚠ = revisar o quitar, • = probablemente del fabricante)"
}

# Vigila si se instala algo solo (los droppers reinstalan lo que se quita).
watch_() {
  local secs=${1:-600} before after i new
  before=$(sh_ pm list packages | sort)
  print "Vigilando ${secs} s…"
  for (( i = 0; i < secs; i += 30 )); do
    sleep 30
    after=$(sh_ pm list packages | sort)
    # El receptor se puede instalar mientras se vigila: no cuenta como sospechoso.
    new=$(comm -13 <(print -r -- "$before") <(print -r -- "$after") | sed 's/package://' | grep -vx "$APP")
    if [[ -n $new ]]; then
      for p in ${(f)new}; do
        print "⚠ se instaló sola: $p ($(sh_ dumpsys package $p | grep -m1 -oE 'installerPackageName=[^ ]*'))"
      done
      return 1
    fi
  done
  ok "$secs s sin instalaciones nuevas"
}

cmd=${1:-}; ip=${2//[^0-9.]/}
[[ -n $cmd && -n $ip ]] || die "uso: $0 <paso> <ip> [...] (ver la cabecera del script)"
# TVs sin ADB: no hace falta conectar.
case $cmd in
  probe) probe "$ip" || die "$ip no abre ADB ni servicios de TV conocidos"; exit 0 ;;
  play) [[ -n ${3:-} ]] || die "falta el id del video"; dial_play "$ip" "$3"; exit 0 ;;
esac
if ! S=$(connect "$ip"); then
  # Muchas TVs no contestan ping: antes de decir "apagado", buscar sus servicios.
  probe "$ip" && exit 2
  if ping -c 1 -t 2 "$ip" >/dev/null 2>&1; then
    die "$ip responde pero sin ADB (puertos ${PORTS[*]}): actívalo en el equipo"
  fi
  die "$ip no responde (ni ADB ni servicios de TV). ¿Apagado, otra IP u otra red? La Mac está en $(ipconfig getifaddr en0 2>/dev/null)"
fi
case $cmd in
  connect) print "$S" ;;
  inspect) inspect ;;
  install) install_app ;;
  home) [[ -n ${3:-} ]] || die "falta el paquete del launcher del fabricante"; set_home "$3" ;;
  debloat) debloat "${3:-}" ;;
  title) set_title "${3:-}" ;;
  timezone) set_timezone "${3:-}" ;;
  bootup) bootup ;;
  scan) scan ;;
  watch) watch_ "${3:-600}" ;;
  dns) set_dns "${3:-on}" ;;
  adbclose) adb_close ;;
  restore) restore ;;
  *) die "comando desconocido: $cmd" ;;
esac
