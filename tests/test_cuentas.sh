#!/usr/bin/env bash
# El panel «Cuentas» de Herdr (clic en la cuenta de la barra): bk account --json lista las cuentas con su mail y la
# que usa el espacio de acá; agregar una sin nombre la nombra sola (claude-2…); y bk account use … --relaunch
# --terminal tX la elige para el espacio y relanza ese chat de Claude en su terminal, retomando su conversación.
# Lo de la cuenta por espacio en sí lo prueba tests/test_herdr_cuenta_espacio.sh.
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
REPO="$TMP/proj"; git init -q -b main "$REPO"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# --- la lista del panel: con el mail y la que usa el espacio ---
acc space-use proj trabajo
check_eq "$(acc list --json --space proj | jq -c 'map([.name, .provider, .logged_in, .who, .active])')" \
  '[["default","claude",true,"yo@ejemplo.com",false],["default","codex",false,"Not logged in",true],["cdx","codex",false,"Not logged in",false],["trabajo","claude",true,"trabajo@ejemplo.com",true]]' \
  "list --json --space: marca la que usa ese espacio, por IA"
check_eq "$(acc list --json --space otro | jq -c '[.[] | select(.active) | .name + ":" + .provider]')" '["default:claude","default:codex"]' \
  "list --json --space de otro espacio: la de siempre"
check_eq "$(acc list --json | jq -c '[.[] | select(.active)] | length')" "0" "list --json sin espacio: ninguna marcada"
check_eq "$(cd "$REPO" && bk account --json | jq -r '.[] | select(.active and .provider == "claude") | .name')" "trabajo" \
  "bk account --json en Herdr: con el espacio del proyecto de acá"
acc space-use proj default

# --- agregar una cuenta sin nombrarla (el panel): se nombra sola y se muestra por su mail ---
check_eq "$(basename "$(acc new claude)") $(basename "$(acc new claude)") $(basename "$(acc new codex)")" "claude-2 claude-3 codex-2" \
  "new sin nombre: claude-2, claude-3…, codex-2 (la de siempre es la 1)"
jwt() { printf 'x.%s.y' "$(printf '{"email": "%s"}' "$1" | base64 | tr -d '=\n' | tr '/+' '_-')"; }
printf '{"tokens": {"id_token": "%s"}}' "$(jwt cdx@ejemplo.com)" >"$ACC/cdx/auth.json"
printf '{"tokens": {"id_token": "roto"}}' >"$ACC/codex-2/auth.json"
check_eq "$(acc email cdx) $(acc email codex-2 || echo nada)" "cdx@ejemplo.com nada" "email de una cuenta de Codex: del id_token de su auth.json; uno roto, nada"
check_eq "$(acc list --json | jq -r '.[] | select(.name == "cdx") | .email')" "cdx@ejemplo.com" "list --json: el mail de las de Codex también"
rm -rf "$ACC/claude-2" "$ACC/claude-3" "$ACC/codex-2"
check_eq "$(bk --dry-run account new claude 2>&1 | grep -c 'crearía una cuenta de claude') $(ls "$ACC" | grep -c claude-)" "1 0" \
  "bk account new claude sin nombre: --dry-run no crea nada"

# --- --relaunch --terminal: el chat que mirás pasa a la cuenta, en su terminal, con la misma conversación ---
(cd "$REPO" && bk chat >/dev/null 2>&1)
T=$(st -r 'first(.terms | to_entries[] | select(.value.labels["bk.kind"] == "chat") | .key)')
SD="$HOME/.cache/sketchybar/agents"; mkdir -p "$SD"
echo "{\"pane\": \"$T\", \"state\": \"idle\"}" >"$SD/sesion-1.json"
fst --arg t "$T" '.terms[$t].status = {"app": "claude-code", "state": "idle"}'; : >"$HD_FAKE/log"
out=$(cd "$REPO" && bk account use trabajo --relaunch --terminal "$T" 2>&1); rc=$?
check_eq "$rc $(acc space proj claude)" "0 trabajo" "relaunch --terminal: la cuenta queda para el espacio"
check_eq "$(log | grep '^hc send' | sed "s#$T#T#")" \
  "hc send T /exit
hc send T env CLAUDE_CONFIG_DIR=$ACC/trabajo BK_ACCOUNT_CLAUDE=trabajo claude --resume sesion-1" \
  "relaunch --terminal: sale de Claude y lo vuelve a abrir en la misma terminal con la cuenta, retomando la conversación"
check_eq "$(st -r --arg t "$T" '.terms[$t].labels["bk.account"]') $(st -r '.terms | length')" "trabajo 1" \
  "relaunch --terminal: la etiqueta dice la cuenta nueva y no abre otro chat"
fst --arg t "$T" '.terms[$t].status = {"app": "claude-code", "state": "idle"}'; : >"$HD_FAKE/log"
(cd "$REPO" && bk account use default claude --relaunch --terminal "$T" >/dev/null 2>&1)
check_eq "$(log | grep '^hc send' | tail -1 | sed "s#$T#T#") $(st -r --arg t "$T" '.terms[$t].labels["bk.account"]')" \
  "hc send T env -u CLAUDE_CONFIG_DIR -u BK_ACCOUNT_CLAUDE claude --resume sesion-1 " "relaunch --terminal a la de siempre: sin carpeta y etiqueta vacía"

# No se toca un chat trabajando, una terminal sin Claude ni uno sin conversación que retomar: la cuenta cambia igual
fst --arg t "$T" '.terms[$t].status = {"app": "claude-code", "state": "working"}'; : >"$HD_FAKE/log"
out=$(cd "$REPO" && bk account use trabajo --relaunch --terminal "$T" 2>&1); rc=$?
check_eq "$rc $(acc space proj claude) $(log | grep -c '^hc send') $(has "$out" "trabajando")" "0 trabajo 0 si" "relaunch con el chat trabajando: no lo toca y avisa"
fst --arg t "$T" '.terms[$t].status = null'; : >"$HD_FAKE/log"
out=$(cd "$REPO" && bk account use default claude --relaunch --terminal "$T" 2>&1); rc=$?
check_eq "$rc $(acc space proj claude) $(log | grep -c '^hc send')" "0  0" "relaunch en una terminal sin Claude: solo cambia la del espacio"
fst --arg t "$T" '.terms[$t].status = {"app": "claude-code", "state": "idle"}'; rm -f "$SD/sesion-1.json"; : >"$HD_FAKE/log"
out=$(cd "$REPO" && bk account use trabajo --relaunch --terminal "$T" 2>&1); rc=$?
check_eq "$rc $(log | grep -c '^hc send') $(has "$out" "conversación")" "0 0 si" "relaunch sin saber qué conversación retomar: no lo cierra"
echo "{\"pane\": \"$T\", \"state\": \"idle\"}" >"$SD/sesion-1.json"; touch "$HD_FAKE/stuck"; : >"$HD_FAKE/log"
(cd "$REPO" && BK_RELAUNCH_WAIT=1 bk account use trabajo --relaunch --terminal "$T" >/dev/null 2>&1)
check_eq "$(log | grep -c '^hc send') $(log | grep -c 'claude --resume')" "1 0" "relaunch con un Claude que no sale: no le manda el comando como mensaje"
rm -f "$HD_FAKE/stuck"; acc space-use proj default
(cd "$REPO" && bk --dry-run account use trabajo --relaunch --terminal "$T" >/dev/null 2>&1); check_eq "$(acc space proj claude)" "" "--dry-run: no cambia nada"
(cd "$REPO" && bk account use trabajo --terminal 2>/dev/null); check_eq "$?" "1" "--terminal sin terminal: falla"

# --- el panel y la barra ---
check_eq "$(jq -r '.cuentas.title' "$ROOT/herdr/mods/hub/views.json")" "Cuentas" "el panel Cuentas está entre las vistas de Herdr"
check_eq "$(grep -c '"b-account", "bk-cuentas"' "$ROOT/herdr/mods/barra/main.js")" "1" "un clic en la cuenta de la barra abre el panel Cuentas"
check_eq "$(grep -c '"account", "use", a.name' "$ROOT/herdr/mods/hub/cuentas.js")" "1" "un clic en una cuenta del panel es bk account use (la del espacio)"

echo "1..$N"
[ "$FAILED" -eq 0 ]
