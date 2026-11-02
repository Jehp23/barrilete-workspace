#!/bin/bash
# Modo uni: tres ítems a la derecha, solo en ese modo (mode.sh los prende y apaga).
#   uni.class  próxima clase o parcial del Calendario de macOS ("Álgebra 25m · Aula 3"; parcial en rojo)
#   uni.due    próxima entrega sin hacer, de Obsidian: <vault>/uni/entregas.md  ("- [ ] 2026-11-05 TP2 Álgebra")
#   uni.pomo   pomodoro de `bk focus` (cuenta regresiva; al terminar avisa con una notificación)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
[ "$(cat "$HOME/.cache/sketchybar/mode" 2>/dev/null)" = "uni" ] || exit 0
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/sketchybar}"
source "$CONFIG_DIR/colors.sh"
WS="$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)"
VAULT="${BARRILETE_VAULT:-$HOME/Documents/Obsidian Vault}"
NOW=$(date +%s)

# Los labels completos se guardan y fit_uni los recorta hasta que uni.class (el de más a la
# izquierda) quede a 16 pt del notch. Mismo criterio que github.sh.
LBL="$HOME/.cache/sketchybar/uni"; mkdir -p "$LBL"
fit_uni() {
  local n_r x lim c d
  n_r=$(cat "$HOME/.cache/sketchybar/notch_right" 2>/dev/null || echo 0)
  c=$(cat "$LBL/class" 2>/dev/null || sketchybar --query uni.class | jq -r .label.value)
  d=$(cat "$LBL/due" 2>/dev/null || sketchybar --query uni.due | jq -r .label.value)
  trunc() { local t="$1" k="$2"; [ ${#t} -gt "$k" ] && echo "${t:0:$((k-1))}…" || echo "$t"; }
  for lim in "36 30" "28 24" "22 18" "18 14" "14 10" "10 8" "6 5"; do
    set -- $lim
    sketchybar --set uni.class label="$(trunc "$c" "$1")" --set uni.due label="$(trunc "$d" "$2")"
    [ "${n_r:-0}" -eq 0 ] && return
    sleep 0.05
    x=$(sketchybar --query uni.class | jq -r '.bounding_rects[]?.origin[0] // 9999 | floor' | head -1)
    [ "${x:-9999}" -ge $((n_r + 16)) ] && return
  done
}

human_in() {  # segundos -> "25m" / "2h10" / "3d"
  local s=$1
  if [ "$s" -lt 3600 ]; then echo "$(( s / 60 ))m"
  elif [ "$s" -lt 86400 ]; then printf '%dh%02d' $(( s / 3600 )) $(( s % 3600 / 60 ))
  else echo "$(( s / 86400 ))d"; fi
}

case "$NAME" in
uni.class)
  BIN="$HOME/.cache/bk/bin/nextevent"
  SRC="$WS/lib/swift/nextevent.swift"
  if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
    mkdir -p "$(dirname "$BIN")"
    swiftc -O -o "$BIN" "$SRC" -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
      -Xlinker "$WS/lib/swift/nextevent-Info.plist" >/dev/null 2>&1
  fi
  OUT=$("$BIN" 18 2>/dev/null); RC=$?
  if [ "$RC" -eq 3 ]; then
    sketchybar --set "$NAME" label="sin permiso de Calendario" label.color=$RED icon.color=$RED; exit 0
  fi
  LINE=$(head -1 <<<"$OUT")
  if [ -z "$LINE" ]; then
    echo "sin clases" >"$LBL/class"
    sketchybar --set "$NAME" label.color=$SUBTEXT icon.color=$SUBTEXT; fit_uni; exit 0
  fi
  IFS=$'\t' read -r START END TITLE LOC <<<"$LINE"
  if [ "$START" -le "$NOW" ]; then WHEN="hasta $(date -r "$END" +%H:%M)"; else WHEN="en $(human_in $(( START - NOW )))"; fi
  C=$TEXT
  echo "$TITLE" | grep -qiE 'parcial|examen|final|recuperatorio' && C=$RED
  LABEL="$TITLE $WHEN"; [ -n "$LOC" ] && LABEL+=" · $LOC"
  echo "$LABEL" >"$LBL/class"
  sketchybar --set "$NAME" label.color=$C icon.color=$MAUVE
  fit_uni
  ;;
uni.due)
  F="$VAULT/uni/entregas.md"
  NEXT=$(grep -E '^\s*- \[ \] [0-9]{4}-[0-9]{2}-[0-9]{2}' "$F" 2>/dev/null | sed -E 's/^\s*- \[ \] //' | sort | head -1)
  if [ -z "$NEXT" ]; then
    echo "sin entregas" >"$LBL/due"
    sketchybar --set "$NAME" label.color=$SUBTEXT; fit_uni; exit 0
  fi
  DAY=${NEXT%% *}; WHAT=${NEXT#* }
  DUE=$(date -j -f %Y-%m-%d "$DAY" +%s 2>/dev/null || echo "$NOW")
  DAYS=$(( (DUE - $(date -j -f %Y-%m-%d "$(date +%Y-%m-%d)" +%s)) / 86400 ))
  if   [ "$DAYS" -lt 0 ];  then WHEN="vencida"; C=$RED
  elif [ "$DAYS" -eq 0 ]; then WHEN="hoy"; C=$RED
  elif [ "$DAYS" -eq 1 ]; then WHEN="mañana"; C=$PEACH
  else WHEN="en ${DAYS}d"; C=$TEXT; [ "$DAYS" -le 3 ] && C=$YELLOW; fi
  # El cuándo va primero: es lo que importa si hay que recortar
  echo "$WHEN · $WHAT" >"$LBL/due"
  sketchybar --set "$NAME" label.color=$C
  fit_uni
  ;;
uni.pomo)
  F="$HOME/.cache/bk/focus"
  if [ ! -s "$F" ]; then
    [ "$(sketchybar --query uni.pomo | jq -r .geometry.drawing)" = on ] && { sketchybar --set "$NAME" drawing=off; fit_uni; }
    exit 0
  fi
  read -r END LABEL <"$F"
  LEFT=$(( END - NOW ))
  if [ "$LEFT" -le 0 ]; then
    rm -f "$F"
    osascript -e "display notification \"${LABEL:-Pomodoro} terminado: tomate 5 minutos\" with title \"bk focus\" sound name \"Glass\"" >/dev/null 2>&1
    sketchybar --set "$NAME" drawing=off; exit 0
  fi
  WAS=$(sketchybar --query uni.pomo | jq -r .geometry.drawing)
  sketchybar --set "$NAME" drawing=on label="$(printf '%d:%02d' $(( LEFT / 60 )) $(( LEFT % 60 )))" label.color=$PEACH
  [ "$WAS" = on ] || fit_uni
  ;;
esac
