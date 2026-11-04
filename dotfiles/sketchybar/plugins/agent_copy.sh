#!/bin/bash
# Clic en un agente del popup de Sketchybar: copia `bk say <ventana> ""` para contestarle desde el chat.
win="${1:?ventana}"
printf 'bk say %s ""' "$win" | pbcopy
sketchybar --set agents popup.drawing=off
osascript -e "display notification \"Pegalo en el chat y escribí la respuesta entre las comillas\" with title \"bk say $win copiado\"" >/dev/null 2>&1
