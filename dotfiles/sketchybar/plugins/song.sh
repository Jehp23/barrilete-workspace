#!/bin/bash
# Ítem "song": una nota musical mientras suena `bk song` (en work y en chill); en pausa o sin música se oculta.
# Clic: popup con la estación y el tema. No toca la reproducción (eso se maneja con `bk song`).
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# bk song vive en el workspace: este directorio es un symlink a dotfiles/sketchybar
SONG="$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)/lib/song.sh"
[ -x "$SONG" ] || { sketchybar --set "$NAME" drawing=off popup.drawing=off; exit 0; }

# Texto que viene de afuera (radio, app, PR, calendario): Sketchybar muestra "Malformed UTF-8 string" si recibe
# bytes que no son UTF-8 (un corte a mitad de una letra, una radio en Latin-1). iconv -c los descarta.
utf8() { printf '%s' "$1" | iconv -f utf-8 -t utf-8 -c 2>/dev/null; }
IFS=$'\t' read -r state station title < <("$SONG" bar-status 2>/dev/null)

if [ "$state" != playing ]; then
  sketchybar --set "$NAME" drawing=off popup.drawing=off
  exit 0
fi

# Las filas del popup se refrescan siempre, así quedan al día si está abierto
sketchybar --set "$NAME" drawing=on \
           --set song.station label="$(utf8 "${station:-?}")" \
           --set song.title label="$(utf8 "${title:-sin datos del tema}")" label.max_chars=60

[ "$SENDER" = "mouse.clicked" ] && sketchybar --set "$NAME" popup.drawing=toggle
exit 0
