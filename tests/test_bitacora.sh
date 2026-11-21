#!/usr/bin/env bash
# bk bitacora [--to <terminal>] [tema]: le escribe /bitacora [tema] al chat de Claude que mirás o al chat de bk de su
# espacio (la skill bitacora del kit, barrilete-kit#343). Con un Herdr falso (tests/herdr_fake.py) y HOME en un
# directorio temporal: no le escribe a ninguna terminal real ni lee el estado de los agentes de verdad.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
unset TMUX TMUX_PANE HC_TERMINAL_ID BK_BACKEND BK_HC BK_HERDR_APP HERDR_APP_HOME
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" HD_FAKE="$TMP/hd"
mkdir -p "$HOME" "$TMP/fake" "$HD_FAKE"
for b in app hc; do
  n=$([ $b = app ] && echo herdr-app || echo hc)
  printf '#!/bin/sh\nexec python3 "%s/herdr_fake.py" %s "$@"\n' "$HERE" "$b" >"$TMP/fake/$n"
done
for b in tmux open; do printf '#!/bin/sh\necho "%s $*" >> "%s/otros.log"\nexit 1\n' "$b" "$TMP" >"$TMP/fake/$b"; done
chmod +x "$TMP/fake"/*; : >"$TMP/otros.log"
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }

bk() { PATH="$TMP/fake:$PATH" BK_BACKEND=herdr "$ROOT/bin/bk" "$@"; }
has() { case "$1" in *"$2"*) echo si ;; *) echo "no: $1" ;; esac; }
sent() { grep '^hc send' "$HD_FAKE/log" 2>/dev/null; }
STATE="$HOME/.cache/sketchybar/agents"; mkdir -p "$STATE"

# Dos espacios. s1: t1 un agente de Claude (con estado del hook), t2 una shell, t3 el chat de bk. s2: t4 una shell, sin chat.
cat >"$HD_FAKE/state.json" <<'EOF'
{"n": 4, "tabs": 0, "spaces": [], "view": [null, null], "terms": {
 "t1": {"labels": {"herdr.space": "s1", "bk.kind": "agent"}, "cwd": "/p", "argv": []},
 "t2": {"labels": {"herdr.space": "s1"}, "cwd": "/p", "argv": []},
 "t3": {"labels": {"herdr.space": "s1", "bk.kind": "chat", "bk.win": "proj"}, "cwd": "/p", "argv": []},
 "t4": {"labels": {"herdr.space": "s2"}, "cwd": "/q", "argv": []}}}
EOF
echo '{"pane": "t1", "state": "done", "ts": 5}' >"$STATE/sesion-t1.json"

: >"$HD_FAKE/log"; bk bitacora --to t1 decidir la ruta >/dev/null 2>&1
check_eq "$(sent)" "hc send t1 /bitacora decidir la ruta" "mirando un Claude: le pide /bitacora <tema> a ese"

: >"$HD_FAKE/log"; bk bitacora --to t2 >/dev/null 2>&1
check_eq "$(sent)" "hc send t3 /bitacora" "mirando una shell: al chat de bk de su espacio, y sin tema solo /bitacora"

: >"$HD_FAKE/log"; bk bitacora --to t1 "   " >/dev/null 2>&1
check_eq "$(sent)" "hc send t1 /bitacora" "un tema en blanco no deja un espacio colgando"

: >"$HD_FAKE/log"; out=$(bk bitacora --to t4 algo 2>&1); rc=$?
check_eq "$rc $(sent)" "1 " "sin Claude a la vista ni chat en su espacio: falla y no le escribe a nadie"
check_eq "$(has "$out" "no es un chat de Claude")" "si" "y dice por qué"

: >"$HD_FAKE/log"; HC_TERMINAL_ID=t1 bk bitacora tema >/dev/null 2>&1
check_eq "$(sent)" "hc send t1 /bitacora tema" "sin --to: la terminal desde donde corre"

# Un menú abierto (pregunta con opciones): el Enter elegiría la opción marcada, así que no escribe
printf '  Elegí una\n  ❯ 1. Sí\n    2. No\n  Enter to select · Esc to cancel\n' >"$HD_FAKE/screen-t1"
: >"$HD_FAKE/log"; bk bitacora --to t1 tema >/dev/null 2>&1; rc=$?
check_eq "$rc $(sent)" "1 " "con un menú abierto en el chat no le escribe"
rm -f "$HD_FAKE/screen-t1"

check_eq "$(cat "$TMP/otros.log")" "" "nunca llama a tmux ni abre nada"
check_eq "$([ -e "$ROOT/lib/bitacora.py" ] && echo queda || echo borrado)" "borrado" "la bitácora generada (lib/bitacora.py) ya no está"

# Las dos paletas: la de tmux (lib/palette.py) acepta el tema vacío; la de Herdr pasa la terminal que mirás.
row=$(python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import palette as P; print([e for e in P.ENTRIES if e[2] == 'bitacora'])" "$ROOT/lib" 2>&1)
check_eq "$(has "$row" "vacío")" "si" "paleta de tmux: el tema es opcional"
check_eq "$(grep -c 'optional: true' "$ROOT/herdr/mods/hub/palette.js") $(grep -c '"--to", to' "$ROOT/herdr/mods/hub/palette.js")" "1 1" "alt+k en Herdr: tema opcional y --to con la terminal que mirás"

echo "1..$N"
[ "$FAILED" -eq 0 ]
