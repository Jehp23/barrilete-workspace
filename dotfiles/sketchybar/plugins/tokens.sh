#!/bin/bash
# Tokens del día de Claude Code y costo equivalente en API (con suscripción es referencia, no gasto).
# El cálculo vive en ~/barrilete-workspace/lib/usage.py (incremental); detalle: `bk tokens`.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
[ "$(cat "$HOME/.cache/sketchybar/mode" 2>/dev/null)" = "chill" ] && exit 0  # modo chill: no prender nada
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/sketchybar}"
source "$CONFIG_DIR/colors.sh"

USAGE="$HOME/barrilete-workspace/lib/usage.py"
[ -x "$USAGE" ] || { sketchybar --set agents.tok drawing=off; exit 0; }

read -r TOKENS COST < <(python3 "$USAGE" --json 2>/dev/null | jq -r '"\(.tokens) \(.cost_usd)"')
[ -z "$TOKENS" ] && exit 0

if   [ "$TOKENS" -ge 1000000 ]; then T=$(awk -v n="$TOKENS" 'BEGIN{printf "%.1fM", n/1e6}')
elif [ "$TOKENS" -ge 1000 ];    then T=$(awk -v n="$TOKENS" 'BEGIN{printf "%.0fk", n/1e3}')
else T="$TOKENS"; fi
C=$(awk -v c="$COST" 'BEGIN{printf (c >= 10 ? "%.0f" : "%.1f"), c}')

sketchybar --set agents.tok drawing=on label="$T \$$C"
