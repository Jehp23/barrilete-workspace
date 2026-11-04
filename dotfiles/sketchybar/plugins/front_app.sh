#!/bin/sh

# Some events send additional information specific to the event in the $INFO
# variable. E.g. the front_app_switched event sends the name of the newly
# focused application in the $INFO variable:
# https://felixkratz.github.io/SketchyBar/config/events#events-and-scripting

if [ "$SENDER" = "front_app_switched" ]; then
  # Tope de largo: nombres largos empujaban los items de agentes contra el notch
  export LC_ALL=en_US.UTF-8   # para cortar por caracteres, no por bytes
  LABEL="${INFO:0:18}"
  [ "$LABEL" != "$INFO" ] && LABEL="$LABEL…"
  LABEL=$(printf '%s' "$LABEL" | iconv -f utf-8 -t utf-8 -c 2>/dev/null)   # un corte a mitad de letra no llega roto
  sketchybar --set "$NAME" label="$LABEL"
fi
