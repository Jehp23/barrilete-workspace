#!/usr/bin/env bash
# bk clean: cierra claude/codex/scripts de bk cuyo padre ya no existe y borra el estado de agentes de panes
# cerrados; nunca toca lo que tiene padre vivo ni nada que se llame tmux.
# Aislado: un ps falso que solo muestra los procesos de esta prueba (los del sistema no se pueden matar), un
# tmux falso con los panes vivos, y HOME (y con él el estado de agentes) en un tmp.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P)
PIDS=()
cleanup() { for p in "${PIDS[@]+"${PIDS[@]}"}"; do kill -9 "$p" 2>/dev/null; done; pkill -9 -f "$TMP/" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
unset TMUX TMUX_PANE
export HOME="$TMP/home" PANES="$TMP/panes"
export BK_STATE_DIR="$HOME/.cache/sketchybar/agents"   # bin/bk la pone igual a partir de HOME
mkdir -p "$HOME" "$BK_STATE_DIR" "$TMP/fake" "$TMP/bin" "$TMP/srv"
REAL_PS=$(command -v ps)
printf '#!/bin/sh\n%s "$@" | grep -F "%s/"\nexit 0\n' "$REAL_PS" "$TMP" >"$TMP/fake/ps"
printf '#!/bin/sh\n[ -f "$PANES" ] || exit 1\ncat "$PANES"\n' >"$TMP/fake/tmux"
chmod +x "$TMP/fake/"*
export PATH="$TMP/fake:$PATH"
# Procesos con el nombre que bk mira: sleep con otro argv[0] (copiar el binario no sirve: macOS lo mata)
fake() { exec -a "$1" sleep 300; }   # corre en un & (subshell): el pid de $! es el del sleep
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
alive() { kill -0 "$1" 2>/dev/null && echo vivo || echo muerto; }
# Huérfano: lo lanza un subshell que se va enseguida, así queda con PPID 1
orphan() { ( fake "$1" </dev/null >/dev/null 2>&1 & echo $! >"$TMP/pid" ); cat "$TMP/pid"; }

O_CLAUDE=$(orphan "$TMP/bin/claude"); O_CODEX=$(orphan "$TMP/bin/codex")
O_OTHER=$(orphan "$TMP/bin/other"); O_TMUX=$(orphan "$TMP/srv/tmux")
fake "$TMP/bin/claude" </dev/null >/dev/null 2>&1 & LIVE=$!; disown
PIDS+=("$O_CLAUDE" "$O_CODEX" "$O_OTHER" "$O_TMUX" "$LIVE")
sleep 0.3
check_eq "$("$REAL_PS" -o ppid= -p "$O_CLAUDE" | tr -d ' ')" 1 "el claude huérfano quedó con PPID 1 (si no, la prueba no prueba nada)"

echo '%1' >"$PANES"
printf '{"pane": "%%1"}' >"$BK_STATE_DIR/vivo.json"
printf '{"pane": "%%9"}' >"$BK_STATE_DIR/muerto.json"
printf '{"cwd": "/x"}' >"$BK_STATE_DIR/sinpane.json"
: >"$BK_STATE_DIR/viejo.json.tmp"; touch -t 202001010000 "$BK_STATE_DIR/viejo.json.tmp"
: >"$BK_STATE_DIR/nuevo.json.tmp"

# Sin --yes solo muestra
out=$(bash "$ROOT/bin/bk" clean 2>&1); rc=$?
check_eq "$rc" 0 "bk clean sin --yes sale bien"
check_eq "$(grep -c "^ *$O_CLAUDE " <<<"$out")" 1 "muestra el claude huérfano"
check_eq "$(grep -c "^ *$O_CODEX " <<<"$out")" 1 "muestra el codex huérfano"
check_eq "$(grep -cE "^ *($LIVE|$O_OTHER|$O_TMUX) " <<<"$out")" 0 "no muestra el claude con padre vivo, ni other, ni tmux"
check_eq "$(grep -c 'muerto.json' <<<"$out")" 1 "muestra el estado del pane cerrado"
check_eq "$(alive "$O_CLAUDE")" vivo "sin --yes no cierra nada"
check_eq "$([ -f "$BK_STATE_DIR/muerto.json" ] && echo está)" está "sin --yes no borra nada"

# Sin tmux no se borra el estado de panes (no se sabe cuáles viven)
mv "$PANES" "$PANES.off"
out=$(bash "$ROOT/bin/bk" clean 2>&1)
check_eq "$(grep -c 'muerto.json' <<<"$out")" 0 "sin tmux no da por muerto ningún pane"
mv "$PANES.off" "$PANES"

out=$(bash "$ROOT/bin/bk" clean --yes 2>&1); rc=$?
check_eq "$rc" 0 "bk clean --yes sale bien"
check_eq "$(alive "$O_CLAUDE")" muerto "cerró el claude huérfano"
check_eq "$(alive "$O_CODEX")" muerto "cerró el codex huérfano"
check_eq "$(alive "$LIVE")" vivo "el claude con padre vivo sigue"
check_eq "$(alive "$O_OTHER")" vivo "un huérfano que no es de bk sigue"
check_eq "$(alive "$O_TMUX")" vivo "nada que se llame tmux se toca"
check_eq "$(cd "$BK_STATE_DIR" && ls | tr '\n' ' ')" "nuevo.json.tmp sinpane.json vivo.json " "borra el estado del pane cerrado y el .tmp viejo, deja el resto"

check_eq "$(bash "$ROOT/bin/bk" clean 2>&1)" "nada para limpiar" "la segunda vez no queda nada"
bash "$ROOT/bin/bk" clean --todo >/dev/null 2>&1; check_eq "$?" 2 "un argumento que no conoce es error"

# Qué reconoce como de bk: los scripts de lib salvo ghapp.py (keep se va solo); Chrome lanza su propio claude
check_eq "$(cd "$ROOT/lib" && python3 -c '
import clean, os
L = os.path.join(clean.WS, "lib")
for c in ["/opt/x/Python " + L + "/rail.py", "python3 " + L + "/ghapp.py keep d", "claude --chrome-native-host",
          "/usr/bin/python3 /otro/lib/rail.py", "tmux new-session -d -s agents claude", "/x/codex exec"]:
    print(clean.what(c))
' | tr '\n' ' ')" "bk rail.py None None None None codex " "what() distingue lo de bk"

echo "1..$N"; [ $FAILED -eq 0 ]
