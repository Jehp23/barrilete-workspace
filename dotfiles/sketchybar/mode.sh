#!/bin/bash
# Modo de la barra:
#   work  -> todo: espacios, agentes, checkpoints, sistema, GitHub
#   chill -> solo lo del día a día: app al frente, volumen, batería, fecha y hora
# Uso: mode.sh [work|chill|toggle|apply|status]   (apply = reaplicar el modo guardado, p. ej. tras un reload)
# El modo se guarda en ~/.cache/sketchybar/mode; los scripts dinámicos (agents, checkpoints, github)
# lo leen y no vuelven a prender nada en chill.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
STATE="$HOME/.cache/sketchybar/mode"
mkdir -p "$(dirname "$STATE")"
CURRENT=$(cat "$STATE" 2>/dev/null || echo work)

case "${1:-toggle}" in
  work|chill) MODE="$1" ;;
  toggle)     [ "$CURRENT" = "chill" ] && MODE=work || MODE=chill ;;
  apply)      MODE="$CURRENT" ;;
  status)     echo "$CURRENT"; exit 0 ;;
  *) echo "uso: $(basename "$0") [work|chill|toggle|apply|status]" >&2; exit 2 ;;
esac
echo "$MODE" > "$STATE"

# Items de trabajo. Los que se prenden/apagan según datos (agents.sub, agents.ckpt, github.ci)
# los decide su script al volver a work.
STATIC=(space.1 space.2 space.3 space.4 space.5 space.6 space.7 space.8 space.9 space.10
        agents spacer.sys cpu ram gpu system spacer.gh github.prs github)
DYNAMIC=(agents.sub agents.ckpt agents.tok github.ci)
POLLING=(cpu ram gpu github.prs agents agents.ckpt agents.tok)

# Arma "--set a k=v --set b k=v ..." para una sola llamada a sketchybar
sets() { local kv="$1"; shift; for it in "$@"; do printf '%s\0' --set "$it" "$kv"; done; }
run()  { xargs -0 sketchybar 2>/dev/null; }

if [ "$MODE" = "chill" ]; then
  sketchybar --set agents popup.drawing=off --set agents.ckpt popup.drawing=off
  { sets drawing=off "${STATIC[@]}" "${DYNAMIC[@]}"; sets updates=off "${POLLING[@]}"; } | run
  sketchybar --update   # el reloj cambia de formato (en chill muestra la fecha)
else
  { sets drawing=on "${STATIC[@]}"; sets updates=on "${POLLING[@]}"; } | run
  # Que cada script recalcule lo suyo (incluye agents.sub, agents.ckpt y github.ci)
  sketchybar --update
  sketchybar --trigger agent_update
fi
echo "modo: $MODE"
