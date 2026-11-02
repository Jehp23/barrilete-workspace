#!/bin/bash
# Modo de la barra:
#   work  -> todo: espacios, agentes, checkpoints, sistema, GitHub
#   chill -> solo lo del día a día: app al frente, volumen, batería, fecha y hora
#   uni   -> facultad: escritorios + próxima clase, próxima entrega y pomodoro (sin nada de trabajo)
# Uso: mode.sh [work|chill|uni|toggle|apply|status]   (toggle alterna work ↔ chill)   (apply = reaplicar el modo guardado, p. ej. tras un reload)
# El modo se guarda en ~/.cache/sketchybar/mode; los scripts dinámicos (agents, checkpoints, github)
# lo leen y no vuelven a prender nada en chill.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
STATE="$HOME/.cache/sketchybar/mode"
mkdir -p "$(dirname "$STATE")"
CURRENT=$(cat "$STATE" 2>/dev/null || echo work)

case "${1:-toggle}" in
  work|chill|uni) MODE="$1" ;;
  toggle)     [ "$CURRENT" = "chill" ] && MODE=work || MODE=chill ;;
  apply)      MODE="$CURRENT" ;;
  status)     echo "$CURRENT"; exit 0 ;;
  *) echo "uso: $(basename "$0") [work|chill|uni|toggle|apply|status]" >&2; exit 2 ;;
esac
echo "$MODE" > "$STATE"

# Items de trabajo. Los que se prenden/apagan según datos (agents.sub, agents.ckpt, github.ci)
# los decide su script al volver a work.
STATIC=(space.1 space.2 space.3 space.4 space.5 space.6 space.7 space.8 space.9 space.10
        agents spacer.sys cpu ram gpu system spacer.gh github.prs github)
DYNAMIC=(agents.sub agents.ckpt agents.tok github.ci)
POLLING=(cpu ram gpu github.prs agents agents.ckpt agents.tok)
SPACES=(space.1 space.2 space.3 space.4 space.5 space.6 space.7 space.8 space.9 space.10)
UNI=(uni.class uni.due uni.pomo)
UNI_STATIC=(uni.campus)   # sin script: solo se muestra u oculta

# Arma "--set a k=v --set b k=v ..." para una sola llamada a sketchybar
sets() { local kv="$1"; shift; for it in "$@"; do printf '%s\0' --set "$it" "$kv"; done; }
run()  { xargs -0 sketchybar 2>/dev/null; }

if [ "$MODE" = "chill" ] || [ "$MODE" = "uni" ]; then
  sketchybar --set agents popup.drawing=off --set agents.ckpt popup.drawing=off
  { sets drawing=off "${STATIC[@]}" "${DYNAMIC[@]}"; sets updates=off "${POLLING[@]}"; } | run
  if [ "$MODE" = "uni" ]; then
    # Escritorios a la vista; clase y entrega siempre, el pomodoro solo si hay uno corriendo (lo decide uni.sh)
    { sets drawing=on "${SPACES[@]}" uni.class uni.due "${UNI_STATIC[@]}"; sets updates=on "${UNI[@]}"; } | run
  else
    { sets drawing=off "${UNI[@]}" "${UNI_STATIC[@]}"; sets updates=off "${UNI[@]}"; } | run
  fi
  sketchybar --update   # el reloj cambia de formato (fuera de work muestra la fecha)
else
  { sets drawing=off "${UNI[@]}" "${UNI_STATIC[@]}"; sets updates=off "${UNI[@]}"; } | run
  { sets drawing=on "${STATIC[@]}"; sets updates=on "${POLLING[@]}"; } | run
  # Que cada script recalcule lo suyo (incluye agents.sub, agents.ckpt y github.ci)
  sketchybar --update
  sketchybar --trigger agent_update
fi
echo "modo: $MODE"
