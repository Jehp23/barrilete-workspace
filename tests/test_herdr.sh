#!/usr/bin/env bash
# bk sobre Herdr (bk backend herdr, lib/herdr.sh): cada proyecto es un espacio y cada chat o agente una pestaña.
# bk ve un herdr-app y un hc falsos (tests/herdr_fake.py) que guardan espacios, pestañas y terminales en un
# archivo y anotan lo que les piden; también un tmux, un gh, un open y un sketchybar falsos. Nada toca el Herdr
# real ni tu config: HOME es un directorio temporal.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
unset TMUX TMUX_PANE HC_TERMINAL_ID BK_BACKEND BK_ACCOUNT BK_ACCOUNT_CLAUDE BK_TASK_DIR BK_PROJECT BK_WS_NAME \
      WORKTREE_LOCK_AGENT WORKTREE_LOCK_PID BK_HC BK_HERDR_APP
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" BK_FORCE=1 BK_BOT=0 HD_FAKE="$TMP/hd" \
       BK_HANDOFF_DIR="$TMP/handoff" BK_HERDR_WAIT=1 BK_HERDR_OPEN="touch $TMP/opened"
mkdir -p "$HOME" "$TMP/fake" "$HD_FAKE"
for b in app hc; do
  n=$([ $b = app ] && echo herdr-app || echo hc)
  printf '#!/bin/sh\nexec python3 "%s/herdr_fake.py" %s "$@"\n' "$HERE" "$b" >"$TMP/fake/$n"
done
for b in tmux gh open sketchybar; do printf '#!/bin/sh\necho "%s $*" >> "%s/otros.log"\nexit 1\n' "$b" "$TMP" >"$TMP/fake/$b"; done
chmod +x "$TMP/fake"/*; : >"$TMP/otros.log"
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
has() { case "$1" in *"$2"*) echo si ;; *) echo no ;; esac; }

STATE="$HOME/.cache/sketchybar/agents"
plain() { PATH="$TMP/fake:$PATH" "$ROOT/bin/bk" "$@"; }                    # sin BK_BACKEND: decide la config
bk()    { PATH="$TMP/fake:$PATH" BK_BACKEND=herdr "$ROOT/bin/bk" "$@"; }
log()   { cat "$HD_FAKE/log" 2>/dev/null; }
st()    { jq "$@" "$HD_FAKE/state.json"; }
tasks() { python3 "$ROOT/lib/tasks.py" "$@"; }

# Un proyecto Barrilete mínimo, con origin y un prepare.sh falso (como tests/test_candado.sh)
REPO="$TMP/proj"
git init -q -b main "$REPO"; git init -q --bare "$TMP/origin.git"; git -C "$REPO" remote add origin "$TMP/origin.git"
mkdir -p "$REPO/scripts/agents" "$REPO/.claude/skills/implement-issue"; : >"$REPO/scripts/agents/guardrails.py"
# prepare.sh crea un worktree de verdad: bk saca el proyecto del repo principal del worktree (<repo>-wt/<n>)
cat >"$REPO/.claude/skills/implement-issue/prepare.sh" <<EOF
#!/bin/sh
[ -d "$TMP/proj-wt/\$1" ] || git -C "$REPO" worktree add -q -b "w\$1" "$TMP/proj-wt/\$1" >/dev/null 2>&1
echo "Worktree: $TMP/proj-wt/\$1"
EOF
chmod +x "$REPO/.claude/skills/implement-issue/prepare.sh"
git -C "$REPO" add -A; git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m init

# --- bk backend: tmux salvo que la config o BK_BACKEND digan herdr ---
check_eq "$(plain backend)" "tmux" "backend: sin config es tmux"
plain backend herdr >/dev/null
check_eq "$(cat "$HOME/.config/bk/backend")" "herdr" "backend herdr: queda en ~/.config/bk/backend"
check_eq "$(plain backend)" "herdr" "backend: lee la config"
check_eq "$(BK_BACKEND=tmux plain backend)" "tmux" "backend: BK_BACKEND manda sobre la config"
plain backend otro >/dev/null 2>&1; check_eq "$?" "1" "backend: un valor desconocido falla"
check_eq "$(cat "$HOME/.config/bk/backend")" "herdr" "backend: un valor desconocido no cambia la config"
plain backend tmux >/dev/null; check_eq "$(plain backend)" "tmux" "backend tmux: vuelve"

# --- bk (sin comando): el espacio del proyecto con su chat ---
(cd "$REPO" && bk >/dev/null 2>&1); check_eq "$?" "0" "bk: abre el workspace"
check_eq "$(log | grep -c '^app do space.new')" "1" "bk: crea el espacio"
check_eq "$(st -r '.spaces[0].name + " " + .spaces[0].tabs[0].name')" "proj chat" "bk: el espacio se llama como el proyecto y su pestaña, chat"
check_eq "$(st -c '.terms.t1.argv')" "[\"env\",\"BK_BACKEND=herdr\",\"BK_PROJECT=$REPO\",\"claude\"]" "bk: el chat es un claude con BK_PROJECT"
check_eq "$(st -r '.terms.t1.labels | .["bk.kind"] + " " + .["bk.win"] + " " + .["bk.project"]')" "chat proj proj" "bk: la terminal del chat queda etiquetada"
: >"$HD_FAKE/log"; (cd "$REPO" && bk >/dev/null 2>&1)
check_eq "$(log | grep -c -e 'space.new' -e 'tab.new')" "0" "bk otra vez: no crea otro espacio ni otro chat"
check_eq "$(log | grep -c 'tab.select {"id": "tb1"}')" "1" "bk otra vez: muestra el chat que ya estaba"

# --- bk run: el agente en una pestaña del espacio, con sus variables y etiquetas ---
: >"$HD_FAKE/log"; (cd "$REPO" && bk run 7 --role implementer >"$TMP/out" 2>&1); check_eq "$?" "0" "bk run: lanza"
WT="$TMP/proj-wt/7"; TD="$XDG_STATE_HOME/bk/tasks/proj/7-implementer"
check_eq "$(grep -c '^tmux' "$TMP/otros.log")" "0" "bk run: no llama a tmux"
check_eq "$(log | grep -c '^app do space.new')" "0" "bk run: no crea otro espacio"
check_eq "$(st -r '.spaces[0].tabs[1].name + " " + .terms.t2.cwd')" "i7 $WT" "bk run: pestaña i7 en el espacio del proyecto, en su worktree"
A=$(st -r '.terms.t2.argv | join("\n")')
check_eq "$(sed -n 1p <<<"$A")" "env" "bk run: las variables van con env"
for v in "BK_BACKEND=herdr" "BARRILETE_ROLE=implementer" "BARRILETE_MODEL=sonnet" "BARRILETE_ISSUE=#7" "BK_TASK_DIR=$TD"; do
  check_eq "$(grep -cxF "$v" <<<"$A")" "1" "bk run: el agente recibe $v"
done
check_eq "$(st -r '.terms.t2.argv[-3:] | .[0] + " " + .[1]')" "bash -c" "bk run: el comando corre en bash -c"
check_eq "$(st -r '.terms.t2.argv[-1]')" "claude --model sonnet '/implement-issue 7'; '$ROOT/bin/bk' _ended '$TD'" "bk run: claude con el prompt, y después cierra la tarea"
check_eq "$(st -c '.terms.t2.labels | [.["bk.kind"], .["bk.win"], .["bk.project"], .["bk.role"], .["bk.ref"]]')" '["agent","i7","proj","implementer","#7"]' "bk run: la terminal queda etiquetada"
check_eq "$(jq -r '.pane + " " + .state' "$STATE/bk-i7.json")" "t2 waiting" "bk run: el pre-registro anota la terminal como pane"
check_eq "$(st -c '.view')" '["sp1","tb1"]' "bk run: no te saca de lo que estabas mirando"
check_eq "$(tasks state proj 7-implementer)" "in_progress" "bk run: la tarea queda en curso"
check_eq "$(jq -r .window "$TD/task.json")" "i7" "bk run: la tarea anota la ventana"

: >"$HD_FAKE/log"; (cd "$REPO" && bk run 7 --role implementer >/dev/null 2>&1)
check_eq "$(log | grep -c 'tab.new')" "0" "bk run otra vez: con la tarea activa no lanza otro agente"

# Si no se puede etiquetar la terminal, bk no la encontraría más: la cierra y no deja la tarea abierta
: >"$HD_FAKE/log"; : >"$HD_FAKE/fail-label"
out=$(cd "$REPO" && bk review 11 2>&1); rc=$?; rm -f "$HD_FAKE/fail-label"
check_eq "$rc" "1" "bk review sin poder etiquetar: falla"
check_eq "$(has "$out" "no pude lanzar pr11 en Herdr")" "si" "bk review sin poder etiquetar: lo dice"
check_eq "$(st -r '[.spaces[0].tabs[].name] | index("pr11") // "no"')" "no" "bk review sin poder etiquetar: no deja la pestaña"
check_eq "$(tasks state proj pr11-reviewer)" "cancelled" "bk review sin poder etiquetar: no deja la tarea en curso"

(cd "$REPO" && bk review 9 >/dev/null 2>&1); check_eq "$?" "0" "bk review: lanza"
R=$(st -r '.terms | to_entries[] | select(.value.labels["bk.win"] == "pr9") | .key')
check_eq "$(st -r --arg t "$R" '.terms[$t].labels | .["bk.role"] + " " + .["bk.ref"]')" "reviewer #9" "bk review: reviewer del PR"
out=$(cd "$REPO" && bk plan una idea 2>&1 && cd "$REPO" && bk plan otra idea 2>&1); rc=$?
check_eq "$rc" "1" "bk plan dos veces: la segunda falla"
check_eq "$(has "$out" "ya existe la ventana 'plan'")" "si" "bk plan dos veces: dice que la ventana ya existe"

# --- bk ls / go / peek ---
out=$(bk ls 2>&1)
check_eq "$(grep -c -e '^. i7 ' -e '^. pr9 ' <<<"$out")" "2" "bk ls: muestra los agentes de Herdr"
check_eq "$(grep -c '^chats' <<<"$out")" "1" "bk ls: muestra los chats"
: >"$HD_FAKE/log"; bk go i7 >/dev/null 2>&1
check_eq "$(log | grep -c -e 'space.select {"id": "sp1"}' -e 'tab.select {"id": "tb2"}')" "2" "bk go: muestra la pestaña del agente"
: >"$HD_FAKE/log"; bk go proj >/dev/null 2>&1
check_eq "$(log | grep -c 'tab.select {"id": "tb1"}')" "1" "bk go <chat>: muestra la pestaña del chat"
printf 'línea vieja\n⏺ Terminé el paso 2\n' >"$HD_FAKE/screen-t2"
check_eq "$(bk peek i7 2>&1 | tail -1)" "⏺ Terminé el paso 2" "bk peek: lee la pantalla de la terminal"

# --- bk say: escribe, respeta los menús y encola si el agente trabaja ---
: >"$HD_FAKE/log"; bk say i7 "hola agente" >/dev/null 2>&1
check_eq "$(log)" "hc send t2 hola agente" "bk say: le escribe a la terminal del agente"
printf '¿Aprobar?\n❯ 1. Sí\n  2. No\nEnter to select · Esc to cancel\n' >"$HD_FAKE/screen-t2"
: >"$HD_FAKE/log"; out=$(bk say i7 "mejor explicame" 2>&1); rc=$?
check_eq "$rc $(log | grep -c send)" "1 0" "bk say con un menú abierto: no manda texto"
check_eq "$(has "$out" "tiene un menú abierto")" "si" "bk say con un menú abierto: avisa"
: >"$HD_FAKE/log"; bk say i7 2 >/dev/null 2>&1
check_eq "$(log)" "hc send --force t2 2" "bk say con un menú abierto: un número pasa, forzado"
rm -f "$HD_FAKE/screen-t2"; mkdir -p "$STATE"
echo "{\"pane\": \"t2\", \"state\": \"working\", \"ts\": $(date +%s)}" >"$STATE/sesion-i7.json"
: >"$HD_FAKE/log"; out=$(bk say i7 "para después" 2>&1)
check_eq "$(log | grep -c send) $(has "$out" encolado)" "0 si" "bk say a un agente que trabaja: lo encola"
bk _drain "$TD" t2 >/dev/null 2>&1
check_eq "$(log)" "hc send t2 para después" "bk _drain: escribe lo encolado en su terminal"

# --- bk stop ---
echo "{\"pane\": \"$R\", \"state\": \"idle\", \"ts\": 1}" >"$STATE/sesion-pr9.json"
: >"$HD_FAKE/log"; bk stop i7 >/dev/null 2>&1; check_eq "$?" "0" "bk stop: cierra"
check_eq "$(log)" "hc kill t2" "bk stop: cierra la terminal del agente"
check_eq "$(tasks state proj 7-implementer)" "cancelled" "bk stop: cancela su tarea"
check_eq "$(ls "$STATE" | tr '\n' ' ')" "bk-plan.json bk-pr9.json sesion-pr9.json " "bk stop: borra el estado de ese agente y no el de otros"

# --- bk chat ---
: >"$HD_FAKE/log"; (cd "$REPO" && bk chat >/dev/null 2>&1)
check_eq "$(log | grep -c '^app do tab.new')" "1" "bk chat: otra pestaña del mismo espacio"
C=$(st -r '.terms | to_entries[] | select(.value.labels["bk.win"] == "proj-2") | .key')
check_eq "$(st -r --arg t "$C" '[.spaces[0].tabs[] | select(.terminals[0] == $t) | .name][0]')" "chat-2" "bk chat: se llama chat-2 y su chat, proj-2"
(cd "$REPO" && bk chat --nombre Idea >/dev/null 2>&1)
check_eq "$(st -r '.terms | to_entries[] | select(.value.labels["bk.win"] == "proj-3") | .value.labels["bk.name"]')" "Idea" "bk chat --nombre: el chat lleva ese nombre"
check_eq "$(st -r '[.spaces[0].tabs[].name] | index("Idea") != null')" "true" "bk chat --nombre: la pestaña también"
(cd "$REPO" && bk chat --suelto >/dev/null 2>&1)
check_eq "$(st -r '.spaces[1].name + " " + .spaces[1].folder')" "chats $HOME/.bk/chats" "bk chat --suelto: en el espacio chats, en su carpeta"
cp "$HD_FAKE/state.json" "$TMP/antes.json"; : >"$HD_FAKE/log"
out=$(cd "$REPO" && bk --dry-run chat --rama "Un cambio" 2>&1)
check_eq "$(log | wc -l | tr -d ' ') $(cmp -s "$HD_FAKE/state.json" "$TMP/antes.json" && echo igual)" "0 igual" "bk --dry-run chat --rama: no toca Herdr"
check_eq "$([ -d "$TMP/proj-wt/chat-un-cambio" ] && echo hay || echo no)" "no" "bk --dry-run chat --rama: no crea el worktree"
(cd "$REPO" && bk chat --rama "Un cambio" >/dev/null 2>&1)
check_eq "$(st -r '.spaces[2].name + " " + .spaces[2].folder')" "proj-un-cambio $TMP/proj-wt/chat-un-cambio" "bk chat --rama: un espacio propio en el worktree de la rama"
check_eq "$(git -C "$TMP/proj-wt/chat-un-cambio" branch --show-current)" "chat/un-cambio" "bk chat --rama: en la rama chat/<nombre>"

# --- handoff desde Herdr: el origen es el chat de la terminal ---
PATH="$TMP/fake:$PATH" BK_BACKEND=herdr HC_TERMINAL_ID=t1 "$ROOT/bin/bk" handoff --pedido --sid abc123 >/dev/null 2>&1
check_eq "$(jq -r '.session' "$BK_HANDOFF_DIR/abc123.json" 2>/dev/null)" "proj" "bk handoff --pedido en Herdr: anota de qué chat viene"

# --- Herdr cerrado: lo abre y espera; si no responde, no lanza ni deja una tarea ---
: >"$HD_FAKE/closed"; rm -f "$TMP/opened"
out=$(cd "$REPO" && bk run 12 --role implementer 2>&1); rc=$?
check_eq "$rc $(has "$out" "Herdr no respondió")" "1 si" "Herdr cerrado: bk run falla y lo dice"
check_eq "$([ -f "$TMP/opened" ] && echo si || echo no)" "si" "Herdr cerrado: intenta abrirlo"
tasks state proj 12-implementer >/dev/null 2>&1; check_eq "$?" "4" "Herdr cerrado: no crea la tarea"
out=$(cd "$REPO" && BK_HERDR_OPEN="rm -f $HD_FAKE/closed" bk run 12 --role implementer 2>&1); rc=$?
check_eq "$rc $(st -r '[.spaces[0].tabs[].name] | index("i12") != null')" "0 true" "Herdr cerrado: si abre a tiempo, lanza"

# --- lo que es del workspace de tmux no corre con Herdr ---
for c in rail sidebar restore snapshot dash; do
  out=$(bk "$c" 2>&1); rc=$?
  check_eq "$rc $(has "$out" "es del workspace de tmux")" "1 si" "bk $c con Herdr: avisa y no abre nada de tmux"
done
check_eq "$(grep -c '^tmux' "$TMP/otros.log")" "0" "con Herdr, ningún comando de esta prueba llamó a tmux"
check_eq "$(grep -c '^open' "$TMP/otros.log")" "0" "ni abrió la app real (open)"

# --- el hook de estado anota la terminal de Herdr como pane ---
HOOK="$TMP/agent_hook.sh"
sed "s#^export PATH=.*#export PATH=\"$TMP/fake:\$PATH\"#" "$ROOT/dotfiles/sketchybar/plugins/agent_hook.sh" >"$HOOK"
ev() { printf '{"session_id":"%s","hook_event_name":"%s","cwd":"%s"}' "$1" "$2" "$REPO"; }
echo '{"pane": "t9", "state": "waiting"}' >"$STATE/bk-i99.json"
ev s1 SessionStart | HC_TERMINAL_ID=t9 bash "$HOOK"
check_eq "$(jq -r .pane "$STATE/s1.json")" "t9" "hook: en Herdr el pane es HC_TERMINAL_ID"
check_eq "$([ -f "$STATE/bk-i99.json" ] && echo queda || echo borrado)" "borrado" "hook: al arrancar la sesión borra el pre-registro de esa terminal"
ev s2 SessionStart | TMUX_PANE=%3 HC_TERMINAL_ID=t9 bash "$HOOK"
check_eq "$(jq -r .pane "$STATE/s2.json")" "%3" "hook: dentro de tmux manda TMUX_PANE"
ev s3 SessionStart | bash "$HOOK"
check_eq "$(jq -r '.pane // "nada"' "$STATE/s3.json")" "nada" "hook: fuera de tmux y de Herdr no anota pane"

echo "1..$N"
[ "$FAILED" -eq 0 ]
