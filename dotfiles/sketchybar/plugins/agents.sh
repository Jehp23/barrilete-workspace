#!/bin/bash
# Agrega el estado de todas las sesiones de agentes (Claude Code, y pi con BARRILETE_STATUS_HOOK) y actualiza:
#   agents       -> contador principal (color según prioridad)
#   agents.sub   -> subagentes activos + última herramienta
#   agents.s.N   -> filas del popup (una por sesión)

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
[ "$(cat "$HOME/.cache/sketchybar/mode" 2>/dev/null)" = "chill" ] && exit 0  # modo chill: no prender nada
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/sketchybar}"
source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/icons.sh"

DIR="$HOME/.cache/sketchybar/agents"
mkdir -p "$DIR"

# Sesiones sin actividad por más de 6 h se consideran muertas (p. ej. terminal cerrada sin SessionEnd)
find "$DIR" -name '*.json' -mmin +360 -delete 2>/dev/null

if [ "$SENDER" = "mouse.clicked" ]; then
  sketchybar --set agents popup.drawing=toggle
fi

# Lock: varios agent_update simultáneos no deben reconstruir el popup a la vez
# (si no, dos instancias crean agents.s.N duplicados). Se espera hasta ~3 s y
# se descarta un lock huérfano de más de 30 s.
LOCK="${TMPDIR:-/tmp}/sketchybar_agents.lock"
for _ in $(seq 1 60); do
  mkdir "$LOCK" 2>/dev/null && break
  LOCK_TS=$(stat -f %m "$LOCK" 2>/dev/null) && [ $(( $(date +%s) - LOCK_TS )) -gt 30 ] \
    && rmdir "$LOCK" 2>/dev/null
  sleep 0.05
done
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

FILES=("$DIR"/*.json)
if [ ! -e "${FILES[0]}" ]; then
  DATA='[]'
else
  DATA=$(jq -s 'sort_by(-.ts)' "${FILES[@]}" 2>/dev/null || echo '[]')
fi

read -r WORKING WAITING DONE ERROR TOTAL SUBS < <(printf '%s' "$DATA" | jq -r '
  [ (map(select(.state=="working" or .state=="background"))|length),
    (map(select(.state=="waiting"))|length),
    (map(select(.state=="done" or .state=="idle"))|length),
    (map(select(.state=="error"))|length),
    length,
    (map(.subagents // 0)|add // 0) ] | @tsv')
LAST_TOOL=$(printf '%s' "$DATA" | jq -r '[.[] | select(.state=="working" or .state=="waiting")][0].tool // "-"')

# ---- Item principal ----
# Compacto: el lado izquierdo del notch es angosto. Solo lo activo, ícono + número;
# el detalle (listos, herramienta, issue, modelo) está en el popup y en `bk ls`.
if [ "$TOTAL" -eq 0 ]; then
  COLOR=$SUBTEXT; LABEL=""
else
  if   [ "$WAITING" -gt 0 ]; then COLOR=$RED
  elif [ "$ERROR"   -gt 0 ]; then COLOR=$PEACH
  elif [ "$WORKING" -gt 0 ]; then COLOR=$YELLOW
  else COLOR=$GREEN; fi
  # Un solo número del color del estado más urgente (rojo esperando, durazno error,
  # amarillo trabajando, verde todos listos). Glifos sueltos en el label quedaban desalineados.
  ACTIVE=$((WORKING + WAITING + ERROR))
  [ "$ACTIVE" -gt 0 ] && LABEL="$ACTIVE" || LABEL="$DONE"
fi

BORDER_ARGS=(background.border_width=0)
[ "$WAITING" -gt 0 ] && BORDER_ARGS=(background.border_width=2 background.border_color=$RED)

if [ -z "$LABEL" ]; then LABEL_ARGS=(label.drawing=off); else LABEL_ARGS=(label.drawing=on label="$LABEL"); fi
sketchybar --set agents icon.color=$COLOR label.color=$COLOR "${LABEL_ARGS[@]}" "${BORDER_ARGS[@]}"

# ---- Subagentes (solo el número) ----
if [ "$SUBS" -gt 0 ]; then
  sketchybar --set agents.sub drawing=on label="$SUBS"
else
  sketchybar --set agents.sub drawing=off
fi

# ---- Popup: una fila por sesión ----
sketchybar --remove '/agents\.s\..*/' >/dev/null 2>&1
if [ "$TOTAL" -eq 0 ]; then
  sketchybar --add item agents.s.0 popup.agents \
             --set agents.s.0 icon="$ICON_DOT" icon.color=$SUBTEXT \
                   label="No hay sesiones de agentes activas" label.color=$SUBTEXT
  exit 0
fi

NOW=$(date +%s)
i=0
while IFS=$'\t' read -r STATE CWD TOOL SUB TS PHASE REF ROLE MODEL; do
  case "$STATE" in
    working) IC=$ICON_DOT;  C=$YELLOW; TXT="trabajando" ;;
    background) IC=$ICON_DOT; C=$YELLOW; TXT="en segundo plano (turno terminado)" ;;
    waiting) IC=$ICON_WAIT; C=$RED;    TXT="esperando permiso"
             [ "$TOOL" = "confianza" ] && TXT="esperando que confíes en la carpeta" ;;
    error)   IC=$ICON_ERR;  C=$PEACH;  TXT="error" ;;
    *)       IC=$ICON_DONE; C=$GREEN;  TXT="listo" ;;
  esac
  # Checkpoint humano: el plan se mostró (planner.py --draft) y el turno terminó
  if [ "$PHASE" = "plan_pending" ] && { [ "$STATE" = "done" ] || [ "$STATE" = "idle" ]; }; then
    IC=$ICON_WAIT; C=$MAUVE; TXT="plan esperando tu sí"
  fi
  AGE=$(( (NOW - TS) / 60 ))
  [ "$AGE" -lt 1 ] && AGO="ahora" || AGO="hace ${AGE}m"
  PROJ=$(basename "$CWD")
  # Cabecera: proyecto · #issue · rol · modelo (lo que se sepa)
  HEAD="$PROJ"
  [ "$REF" != "-" ]   && HEAD+=" $REF"
  [ "$ROLE" != "-" ]  && HEAD+=" · $ROLE"
  [ "$MODEL" != "-" ] && HEAD+=" · $MODEL"
  DETAIL="$TXT"
  [ "$TOOL" != "-" ] && [ "$STATE" != "done" ] && [ "$STATE" != "idle" ] && DETAIL+=" · $TOOL"
  [ "$SUB" -gt 0 ] && DETAIL+=" · $SUB sub"
  sketchybar --add item agents.s.$i popup.agents \
             --set agents.s.$i background.drawing=off icon.padding_left=10 label.padding_right=12 icon="$IC" icon.color=$C \
                   label="$HEAD  —  $DETAIL  ($AGO)" \
                   click_script="open \"$CWD\"; sketchybar --set agents popup.drawing=off"
  i=$((i+1))
done < <(printf '%s' "$DATA" | jq -r '
  def nz: if . == null or . == "" then "-" else tostring end;
  .[] | [ .state, .cwd, (.tool|nz), (.subagents // 0), .ts,
          (.phase|nz), (.ref|nz), (.role|nz),
          ((.model // "") | sub("^claude-";"") | sub("-[0-9]{8}$";"") | nz) ] | @tsv')
