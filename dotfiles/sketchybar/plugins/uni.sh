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
    sketchybar --set "$NAME" label="sin clases" label.color=$SUBTEXT icon.color=$SUBTEXT; exit 0
  fi
  IFS=$'\t' read -r START END TITLE LOC <<<"$LINE"
  if [ "$START" -le "$NOW" ]; then WHEN="hasta $(date -r "$END" +%H:%M)"; else WHEN="en $(human_in $(( START - NOW )))"; fi
  C=$TEXT
  echo "$TITLE" | grep -qiE 'parcial|examen|final|recuperatorio' && C=$RED
  LABEL="$TITLE $WHEN"; [ -n "$LOC" ] && LABEL+=" · $LOC"
  sketchybar --set "$NAME" label="${LABEL:0:42}" label.color=$C icon.color=$MAUVE
  ;;
uni.due)
  F="$VAULT/uni/entregas.md"
  NEXT=$(grep -E '^\s*- \[ \] [0-9]{4}-[0-9]{2}-[0-9]{2}' "$F" 2>/dev/null | sed -E 's/^\s*- \[ \] //' | sort | head -1)
  if [ -z "$NEXT" ]; then
    sketchybar --set "$NAME" label="sin entregas" label.color=$SUBTEXT; exit 0
  fi
  DAY=${NEXT%% *}; WHAT=${NEXT#* }
  DUE=$(date -j -f %Y-%m-%d "$DAY" +%s 2>/dev/null || echo "$NOW")
  DAYS=$(( (DUE - $(date -j -f %Y-%m-%d "$(date +%Y-%m-%d)" +%s)) / 86400 ))
  if   [ "$DAYS" -lt 0 ];  then WHEN="vencida"; C=$RED
  elif [ "$DAYS" -eq 0 ]; then WHEN="hoy"; C=$RED
  elif [ "$DAYS" -eq 1 ]; then WHEN="mañana"; C=$PEACH
  else WHEN="en ${DAYS}d"; C=$TEXT; [ "$DAYS" -le 3 ] && C=$YELLOW; fi
  sketchybar --set "$NAME" label="${WHAT:0:28} · $WHEN" label.color=$C
  ;;
uni.pomo)
  F="$HOME/.cache/bk/focus"
  if [ ! -s "$F" ]; then sketchybar --set "$NAME" drawing=off; exit 0; fi
  read -r END LABEL <"$F"
  LEFT=$(( END - NOW ))
  if [ "$LEFT" -le 0 ]; then
    rm -f "$F"
    osascript -e "display notification \"${LABEL:-Pomodoro} terminado: tomate 5 minutos\" with title \"bk focus\" sound name \"Glass\"" >/dev/null 2>&1
    sketchybar --set "$NAME" drawing=off; exit 0
  fi
  sketchybar --set "$NAME" drawing=on label="$(printf '%d:%02d' $(( LEFT / 60 )) $(( LEFT % 60 )))" label.color=$PEACH
  ;;
esac
