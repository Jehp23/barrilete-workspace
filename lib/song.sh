#!/bin/bash
# bk song — radios de techno/house en segundo plano con mpv, manejadas desde la terminal.
# mpv corre desacoplado de la terminal con un socket IPC; los demás subcomandos le hablan por ahí.
set -euo pipefail

CACHE="$HOME/.cache/bk"
SOCK="$CACHE/song.sock"
NOW="$CACHE/song.station"   # "clave<TAB>nombre" de lo que está sonando
LOG="$CACHE/song.log"
VIZ='@viz:lavfi=[astats=metadata=1:reset=1]'   # niveles por canal para el gráfico de bk song ui
LIB="$(dirname "$(readlink -f "$0")")"

die()  { printf 'bk song: %s\n' "$*" >&2; exit 1; }
info() { printf '\033[2m%s\033[0m\n' "$*"; }
bar()  { sketchybar --trigger song_update >/dev/null 2>&1 || true; }   # ítem "song" de Sketchybar

# clave|nombre|url  (streams verificados; el primero es el default)
STATIONS='techno|Sunshine Live · Techno|http://stream.sunshine-live.de/techno/mp3-192/stream.sunshine-live.de/
technofm|Techno.FM|http://stream.techno.fm/radio.mp3
house|1.FM · Deep House|http://strm112.1.fm/deephouse_mobile_mp3
deeptech|1.FM · Deep Techno & Deep House|http://strm112.1.fm/deeptech_mobile_mp3
ibiza|Ibiza Global Radio|http://ibizaglobalradio.streaming-pro.com:8024/
dance|Intense Radio · We love Dance|https://secure.live-streams.nl/main'

usage() {
  cat <<'EOF'
uso: bk song [comando]

  bk song                 reproduce la radio default (techno)
  bk song <estación>      cambia de estación (ver bk song list)
  bk song <género>        si no es una estación: busca la radio más votada con ese tag
                          en radio-browser.info (minimal, trance, melodic techno...)
  bk song pause           pausa / reanuda
  bk song next | prev     siguiente / anterior estación de la lista
  bk song ui              pantalla en vivo: gráfico del sonido + control con teclas
  bk song now             qué estación y qué tema están sonando
  bk song vol [+N|-N|N]   volumen (sin argumento: el actual)
  bk song stop            corta la música
  bk song list            estaciones disponibles
EOF
}

# ---------- mpv ----------
# Sin pipes hacia grep -q/head: con pipefail, el SIGPIPE de nc da falsos "no está corriendo"
running() {
  [ -S "$SOCK" ] || return 1
  local r; r=$(ipc '{"command":["get_property","pid"]}')
  [[ "$r" == *'"error":"success"'* ]]
}

# ipc <json> -> primera línea de la respuesta de mpv
ipc() {
  local r; r=$(printf '%s\n' "$1" | nc -U -w 1 "$SOCK" 2>/dev/null) || true
  printf '%s\n' "${r%%$'\n'*}"
}

# prop <nombre> -> valor (vacío si no existe)
prop() { ipc "{\"command\":[\"get_property\",\"$1\"]}" | jq -r 'select(.error == "success") | .data // empty | tostring' 2>/dev/null; }

need_running() { running || die "no está sonando nada (bk song para arrancar)"; }

kill_player() {
  pkill -f -- "--input-ipc-server=$SOCK" 2>/dev/null || true
  rm -f "$SOCK" "$NOW"
}

# play <clave> <nombre> <url>
play() {
  command -v mpv >/dev/null || die "falta mpv (brew install mpv)"
  mkdir -p "$CACHE"
  # Cambiar de estación conserva el volumen que tenías
  local vol=100; running && vol=$(prop volume) && vol=${vol%.*}
  [[ "$vol" =~ ^[0-9]+$ ]] || vol=100
  kill_player
  nohup mpv --no-video --volume="$vol" --af="$VIZ" --no-terminal --idle=no --cache=yes --demuxer-max-bytes=2MiB \
    --input-ipc-server="$SOCK" --title="bk-song" "$3" >"$LOG" 2>&1 </dev/null &
  disown
  printf '%s\t%s\n' "$1" "$2" > "$NOW"
  # Esperar a que mpv levante el socket, así un error de red se ve acá y no en silencio
  local i
  for i in $(seq 1 30); do
    if running; then
      printf '♫ %s\n' "$2"; bar
      return 0
    fi
    sleep 0.2
  done
  kill_player
  die "mpv no arrancó (ver $LOG)"
}

# ---------- estaciones ----------
station_line() { awk -F'|' -v k="$1" '$1 == k { print; exit }' <<<"$STATIONS"; }

play_key() {
  local line; line=$(station_line "$1")
  [ -n "$line" ] || return 1
  IFS='|' read -r k name url <<<"$line"
  play "$k" "$name" "$url"
}

# Género que no es estación curada: la radio más votada de radio-browser con ese tag
play_tag() {
  local tag="$1" res name url
  info "buscando radios '$tag' en radio-browser.info…"
  res=$(curl -fsS -m 10 -A 'bk-song/1' -G 'https://de1.api.radio-browser.info/json/stations/search' \
          --data-urlencode "tag=$tag" -d order=votes -d reverse=true -d hidebroken=true -d limit=1) \
    || die "radio-browser.info no respondió"
  name=$(jq -r '.[0].name // empty' <<<"$res" | tr -d '\t\n' | cut -c1-60)
  url=$(jq -r '.[0].url_resolved // empty' <<<"$res")
  [[ "$url" =~ ^https?:// ]] || die "no encontré radios con el tag '$tag' (bk song list)"
  play "tag:$tag" "$name" "$url"
}

# cmd_step <1|-1>: estación siguiente o anterior (circular; si venía de un tag, arranca por la primera)
cmd_step() {
  local cur="" keys n i
  [ -f "$NOW" ] && cur=$(cut -f1 "$NOW")
  keys=$(cut -d'|' -f1 <<<"$STATIONS")
  n=$(wc -l <<<"$keys" | tr -d ' ')
  i=$(awk -v c="$cur" '$0 == c { print NR; exit }' <<<"$keys")
  if [ -z "$i" ]; then i=1; else i=$(( (i - 1 + $1 + n) % n + 1 )); fi
  play_key "$(sed -n "${i}p" <<<"$keys")"
}

cmd_now() {
  need_running
  local name title paused vol
  name=$(cut -f2 "$NOW" 2>/dev/null || true)
  title=$(prop metadata | jq -r '."icy-title" // empty' 2>/dev/null || true)
  paused=$(prop pause); vol=$(prop volume)
  printf '♫ %s%s\n' "${name:-?}" "$([ "$paused" = true ] && echo '  (en pausa)')"
  [ -n "$title" ] && printf '  %s\n' "$title"
  printf '  vol %s%%\n' "${vol%.*}"
}

# Para Sketchybar: "estado<TAB>estación<TAB>tema" (estado: playing | paused | off)
cmd_bar_status() {
  if ! running; then
    # mpv murió solo (se cortó el stream): no dejar un socket viejo
    [ -e "$SOCK" ] && kill_player
    printf 'off\t\t\n'; return
  fi
  local name title state=playing
  name=$(cut -f2 "$NOW" 2>/dev/null || true)
  title=$(prop metadata | jq -r '."icy-title" // empty' 2>/dev/null | tr -d '\t\n' || true)
  [ "$(prop pause)" = true ] && state=paused
  printf '%s\t%s\t%s\n' "$state" "$name" "$title"
}

cmd_vol() {
  need_running
  local v="${1:-}"
  case "$v" in
    "")              ;;
    [+-][0-9]*)      [[ "$v" =~ ^[+-][0-9]{1,3}$ ]] || die "volumen inválido: $v"
                     ipc "{\"command\":[\"add\",\"volume\",${v#+}]}" >/dev/null ;;
    *)               [[ "$v" =~ ^[0-9]{1,3}$ ]] || die "volumen inválido: $v (0-130, +N o -N)"
                     ipc "{\"command\":[\"set_property\",\"volume\",$v]}" >/dev/null ;;
  esac
  local cur; cur=$(prop volume); printf 'vol %s%%\n' "${cur%.*}"
}

cmd_list() {
  local cur=""; [ -f "$NOW" ] && running && cur=$(cut -f1 "$NOW")
  awk -F'|' -v c="$cur" '{ printf "%s %-9s %s\n", ($1 == c ? "♫" : " "), $1, $2 }' <<<"$STATIONS"
  info "otro género: bk song <tag> (busca en radio-browser.info)"
}

case "${1:-}" in
  "")              play_key techno ;;
  stop)            running || [ -f "$NOW" ] || { echo "no estaba sonando nada"; exit 0; }
                   kill_player; bar; echo "■ música cortada" ;;
  pause)           need_running; ipc '{"command":["cycle","pause"]}' >/dev/null; bar
                   [ "$(prop pause)" = true ] && echo "⏸ en pausa" || echo "▶ sonando" ;;
  bar-status)      cmd_bar_status ;;
  next)            cmd_step 1 ;;
  prev)            cmd_step -1 ;;
  stations)        awk -F'|' '{ print $1 "\t" $2 }' <<<"$STATIONS" ;;
  ui)              command -v mpv >/dev/null || die "falta mpv (brew install mpv)"
                   running || play_key techno >/dev/null
                   # Si mpv lo arrancó una versión vieja de bk song, sumarle el medidor en caliente
                   prop af | grep -q '"viz"' || ipc "{\"command\":[\"af\",\"add\",\"$VIZ\"]}" >/dev/null
                   exec python3 "$LIB/song_ui.py" "$SOCK" "$LIB/song.sh" ;;
  now|status)      cmd_now ;;
  vol|volume)      shift; cmd_vol "${1:-}" ;;
  list|ls)         cmd_list ;;
  -h|--help|help)  usage ;;
  *)               play_key "$1" || play_tag "$*" ;;
esac
