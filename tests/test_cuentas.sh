#!/usr/bin/env bash
# Cambiar de cuenta con un clic (bk account use sin sesión de tmux, el panel «Cuentas» de Herdr): la cuenta activa
# de cada IA queda guardada para todo bk (accounts.py active / set-active), lo que se lance después la usa, y
# --relaunch --terminal tX relanza ese chat de Claude con la cuenta nueva retomando su conversación.
# Con un Herdr falso (tests/herdr_fake.py) y claude/codex falsos: nada toca tu Herdr, tus cuentas ni el llavero.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
unset TMUX TMUX_PANE HC_TERMINAL_ID BK_BACKEND BK_ACCOUNT BK_ACCOUNT_CLAUDE BK_ACCOUNT_CODEX CLAUDE_CONFIG_DIR CODEX_HOME \
      BK_PROJECT BK_WS_NAME BK_HC BK_HERDR_APP HERDR_APP_HOME BK_ACCOUNTS_DIR BK_HD_IDS_LOCK
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" BK_FORCE=1 BK_BOT=0 HD_FAKE="$TMP/hd" \
       BK_HERDR_WAIT=1 BK_HERDR_OPEN="touch $TMP/opened" BK_RELAUNCH_WAIT=2
mkdir -p "$HOME" "$TMP/fake" "$HD_FAKE"
for b in app hc; do
  n=$([ $b = app ] && echo herdr-app || echo hc)
  printf '#!/bin/sh\nexec python3 "%s/herdr_fake.py" %s "$@"\n' "$HERE" "$b" >"$TMP/fake/$n"
done
for b in tmux gh open; do printf '#!/bin/sh\nexit 1\n' >"$TMP/fake/$b"; done
# claude y codex falsos: auth status dice el mail según la carpeta de la cuenta
printf '#!/bin/sh\n[ "$1 $2" = "auth status" ] || exit 0\nd=${CLAUDE_CONFIG_DIR:-$HOME/.claude}\n[ -f "$d/logged" ] && echo "{\\"loggedIn\\": true, \\"email\\": \\"$(cat "$d/logged")\\"}" || echo "{\\"loggedIn\\": false}"\n' >"$TMP/fake/claude"
printf '#!/bin/sh\n[ "$1 $2" = "login status" ] && { echo "Not logged in"; exit 1; }\nexit 0\n' >"$TMP/fake/codex"
chmod +x "$TMP/fake"/*
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
has() { case "$1" in *"$2"*) echo si ;; *) echo no ;; esac; }
bk()  { PATH="$TMP/fake:$PATH" BK_BACKEND=herdr "$ROOT/bin/bk" "$@"; }
acc() { PATH="$TMP/fake:$PATH" python3 "$ROOT/lib/accounts.py" "$@"; }
st()  { jq "$@" "$HD_FAKE/state.json"; }
fst() { local j; j=$(jq "$@" "$HD_FAKE/state.json") && printf '%s' "$j" >"$HD_FAKE/state.json"; }
log() { cat "$HD_FAKE/log" 2>/dev/null; }

ACC="$XDG_STATE_HOME/bk/accounts"
mkdir -p "$HOME/.claude"; echo yo@ejemplo.com >"$HOME/.claude/logged"
acc new claude trabajo >/dev/null; acc new codex cdx >/dev/null
echo trabajo@ejemplo.com >"$ACC/trabajo/logged"
echo '{"oauthAccount": {"emailAddress": "trabajo@ejemplo.com"}}' >"$ACC/trabajo/.claude.json"

# --- la cuenta activa de cada IA ---
check_eq "$(acc active claude) $(acc active codex)" "default default" "active: sin elegir, la de siempre"
acc set-active trabajo; check_eq "$? $(acc active claude) $(acc active codex)" "0 trabajo default" "set-active: queda para su proveedor y no toca el otro"
acc set-active cdx; check_eq "$(acc active claude) $(acc active codex)" "trabajo cdx" "set-active: cada IA tiene la suya"
acc set-active nadie 2>/dev/null; check_eq "$? $(acc active claude)" "1 trabajo" "set-active de una cuenta que no existe: falla y no cambia nada"
acc set-active default 2>/dev/null; check_eq "$?" "1" "set-active default sin decir de qué IA: falla"
acc set-active default codex; check_eq "$(acc active claude) $(acc active codex)" "trabajo default" "set-active default codex: vuelve a la de siempre solo Codex"
L=$(acc list --json)
check_eq "$(jq -c 'map([.name, .provider, .logged_in, .who, .active])' <<<"$L")" \
  '[["default","claude",true,"yo@ejemplo.com",false],["default","codex",false,"Not logged in",true],["cdx","codex",false,"Not logged in",false],["trabajo","claude",true,"trabajo@ejemplo.com",true]]' \
  "list --json: cada cuenta dice si es la activa de su IA"

# --- bk account use sin tmux: elige la activa (Herdr) ---
acc set-active default claude
out=$(bk account use trabajo 2>&1); rc=$?
check_eq "$rc $(acc active claude)" "0 trabajo" "bk account use sin tmux: la deja activa para todo bk"
check_eq "$(has "$out" "trabajo")" "si" "bk account use: dice cuál quedó"
bk account use default claude >/dev/null 2>&1; check_eq "$(acc active claude)" "default" "bk account use default claude: vuelve a la de siempre"
bk account use nadie >/dev/null 2>&1; check_eq "$?" "1" "bk account use de una que no existe: falla"
bk account use trabajo >/dev/null 2>&1

# Lo que se lanza después usa la activa: un chat nuevo nace con su carpeta y su etiqueta
REPO="$TMP/proj"; git init -q -b main "$REPO"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
(cd "$REPO" && bk chat >/dev/null 2>&1)
T=$(st -r 'first(.terms | to_entries[] | select(.value.labels["bk.kind"] == "chat") | .key)')
check_eq "$(st -r --arg t "$T" '.terms[$t].labels["bk.account"] // "-"') $(has "$(st -c --arg t "$T" '.terms[$t].argv')" "CLAUDE_CONFIG_DIR=$ACC/trabajo")" \
  "trabajo si" "un chat nuevo nace con la cuenta activa"
(cd "$REPO" && BK_ACCOUNT_CLAUDE=default bk chat >/dev/null 2>&1)
T2=$(st -r --arg t "$T" 'last(.terms | to_entries[] | select(.value.labels["bk.kind"] == "chat" and .key != $t) | .key)')
check_eq "$(st -r --arg t "$T2" '.terms[$t].labels["bk.account"] // "-"')" "-" "la cuenta de la terminal de donde se lanza (BK_ACCOUNT_CLAUDE) manda sobre la activa"

# --- --relaunch --terminal: el chat que mirás pasa a la cuenta nueva, con la misma conversación ---
SD="$HOME/.cache/sketchybar/agents"; mkdir -p "$SD"
echo "{\"pane\": \"$T\", \"state\": \"idle\"}" >"$SD/sesion-1.json"
fst --arg t "$T" '.terms[$t].status = {"app": "claude-code", "state": "idle"}'
: >"$HD_FAKE/log"
out=$(bk account use default claude --relaunch --terminal "$T" 2>&1); rc=$?
check_eq "$rc $(acc active claude)" "0 default" "relaunch: la activa cambia igual"
check_eq "$(log | grep '^hc send' | sed "s#$T#T#")" \
  "hc send T /exit
hc send T env -u CLAUDE_CONFIG_DIR -u BK_ACCOUNT_CLAUDE claude --resume sesion-1" \
  "relaunch: sale de Claude y lo vuelve a abrir con la cuenta nueva, retomando la conversación"
check_eq "$(st -r --arg t "$T" '.terms[$t].labels["bk.account"]')" "" "relaunch: la etiqueta de la terminal dice la cuenta nueva (vacía: la de siempre)"
fst --arg t "$T" '.terms[$t].status = {"app": "claude-code", "state": "idle"}'; : >"$HD_FAKE/log"
bk account use trabajo --relaunch --terminal "$T" >/dev/null 2>&1
check_eq "$(log | grep '^hc send' | tail -1 | sed "s#$T#T#")" \
  "hc send T env CLAUDE_CONFIG_DIR=$ACC/trabajo BK_ACCOUNT_CLAUDE=trabajo claude --resume sesion-1" "relaunch a otra cuenta: con su carpeta"
check_eq "$(st -r --arg t "$T" '.terms[$t].labels["bk.account"]')" "trabajo" "relaunch: etiqueta con la cuenta nueva"

# No se toca un chat trabajando, una terminal sin Claude ni uno sin conversación que retomar: la activa cambia igual
fst --arg t "$T" '.terms[$t].status = {"app": "claude-code", "state": "working"}'; : >"$HD_FAKE/log"
out=$(bk account use default claude --relaunch --terminal "$T" 2>&1); rc=$?
check_eq "$rc $(acc active claude) $(log | grep -c '^hc send') $(has "$out" "trabajando")" "0 default 0 si" "relaunch con el chat trabajando: no lo toca y avisa"
fst --arg t "$T" '.terms[$t].status = null'; : >"$HD_FAKE/log"
out=$(bk account use trabajo --relaunch --terminal "$T" 2>&1); rc=$?
check_eq "$rc $(acc active claude) $(log | grep -c '^hc send')" "0 trabajo 0" "relaunch en una terminal sin Claude: solo cambia la activa"
fst --arg t "$T" '.terms[$t].status = {"app": "claude-code", "state": "idle"}'; rm -f "$SD/sesion-1.json"; : >"$HD_FAKE/log"
out=$(bk account use default claude --relaunch --terminal "$T" 2>&1); rc=$?
check_eq "$rc $(log | grep -c '^hc send') $(has "$out" "conversación")" "0 0 si" "relaunch sin saber qué conversación retomar: no lo cierra"
echo "{\"pane\": \"$T\", \"state\": \"idle\"}" >"$SD/sesion-1.json"; touch "$HD_FAKE/stuck"; : >"$HD_FAKE/log"
BK_RELAUNCH_WAIT=1 bk account use default claude --relaunch --terminal "$T" >/dev/null 2>&1
check_eq "$(log | grep -c '^hc send') $(log | grep -c 'claude --resume')" "1 0" "relaunch con un Claude que no sale: no le manda el comando como mensaje"
rm -f "$HD_FAKE/stuck"; bk account use default claude >/dev/null 2>&1
bk --dry-run account use trabajo >/dev/null 2>&1; check_eq "$(acc active claude)" "default" "--dry-run: no cambia nada"

# --- el panel y la barra ---
check_eq "$(jq -r '.cuentas.title' "$ROOT/herdr/mods/hub/views.json")" "Cuentas" "el panel Cuentas está entre las vistas de Herdr"
check_eq "$(grep -c '"b-account", "bk-cuentas"' "$ROOT/herdr/mods/barra/main.js")" "1" "un clic en la cuenta de la barra abre el panel Cuentas"

echo "1..$N"
[ "$FAILED" -eq 0 ]
