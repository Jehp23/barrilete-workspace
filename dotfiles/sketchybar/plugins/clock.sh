#!/bin/sh
# Work: solo la hora (la derecha del notch es angosta). Chill y uni: fecha y hora.
if [ "$(cat "$HOME/.cache/sketchybar/mode" 2>/dev/null || echo work)" != "work" ]; then
  sketchybar --set "$NAME" label="$(date '+%d/%m %H:%M')"
else
  sketchybar --set "$NAME" label="$(date '+%H:%M')"
fi
