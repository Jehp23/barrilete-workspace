#!/usr/bin/env bash
# bk account use con Herdr: la cuenta va por espacio (el proyecto), no por sesión de tmux. bk ve un herdr-app y un hc
# falsos (tests/herdr_fake.py); las cuentas, el estado y HOME están en una carpeta temporal. Nada toca Herdr ni tu config.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
unset TMUX TMUX_PANE HC_TERMINAL_ID BK_BACKEND BK_ACCOUNT BK_ACCOUNT_CLAUDE BK_ACCOUNT_CODEX BK_TASK_DIR BK_PROJECT BK_WS_NAME \
      CLAUDE_CONFIG_DIR CODEX_HOME BK_HC BK_HERDR_APP HERDR_APP_HOME BK_HD_IDS_LOCK BK_ACCOUNTS_DIR
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" BK_FORCE=1 BK_BOT=0 HD_FAKE="$TMP/hd" \
       BK_HANDOFF_DIR="$TMP/handoff" BK_HERDR_WAIT=1 BK_HERDR_OPEN="touch $TMP/opened" \
       BK_CLAUDE_MAIN="$TMP/home/.claude" BK_CODEX_MAIN="$TMP/home/.codex"
mkdir -p "$HOME/.claude" "$HOME/.codex" "$TMP/fake" "$HD_FAKE"
for b in app hc; do
  n=$([ $b = app ] && echo herdr-app || echo hc)
  printf '#!/bin/sh\nexec python3 "%s/herdr_fake.py" %s "$@"\n' "$HERE" "$b" >"$TMP/fake/$n"
done
for b in tmux gh open; do printf '#!/bin/sh\necho "%s $*" >> "%s/otros.log"\nexit 1\n' "$b" "$TMP" >"$TMP/fake/$b"; done
chmod +x "$TMP/fake"/*
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
bk() { PATH="$TMP/fake:$PATH" BK_BACKEND=herdr "$ROOT/bin/bk" "$@"; }
acc() { python3 "$ROOT/lib/accounts.py" "$@"; }
st() { jq "$@" "$HD_FAKE/state.json"; }
A="$XDG_STATE_HOME/bk/accounts"

REPO="$TMP/proj"; git init -q -b main "$REPO"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
OTHER="$TMP/otro"; mkdir -p "$OTHER"
acc new claude trabajo >/dev/null; acc new codex cx >/dev/null

# --- lib/accounts.py: la cuenta de cada espacio ---
acc space-use proj trabajo
check_eq "$(acc space proj claude)|$(acc space proj codex)|$(acc space otro claude)" "trabajo||" "space-use: anota la cuenta para ese espacio y ese proveedor"
acc space-use proj cx
check_eq "$(acc space proj claude)|$(acc space proj codex)" "trabajo|cx" "space-use: cada proveedor por su lado"
acc space-use proj nada 2>/dev/null; check_eq "$?|$(acc space proj claude)" "1|trabajo" "space-use: una cuenta que no existe falla y no cambia nada"
acc space-use proj default codex
check_eq "$(acc space proj claude)|$(acc space proj codex)" "trabajo|" "space-use default codex: vuelve a la de siempre solo en codex"
acc space-use proj default
check_eq "$(jq -c . "$A/.espacios.json")|$(acc list --json 2>/dev/null | jq -r '[.[].name] | join(",")')" "{}|default,default,cx,trabajo" \
  "space-use default: el espacio queda sin cuenta; el archivo no aparece como cuenta"

# --- bk account use: con Herdr no hace falta tmux ---
out=$(cd "$REPO" && bk account use trabajo 2>&1); rc=$?
check_eq "$rc|$(acc space proj claude)" "0|trabajo" "bk account use trabajo: con Herdr la anota en el espacio del proyecto"
check_eq "$(grep -c 'tmux' "$TMP/otros.log" 2>/dev/null || echo 0)" "0" "bk account use: con Herdr no llama a tmux"
out=$(cd "$REPO" && bk account 2>&1 | tail -1)
check_eq "$(sed 's/\x1b\[[0-9;]*m//g' <<<"$out")" "en el espacio proj: claude trabajo · codex default" "bk account: dice la cuenta del espacio"
out=$(cd "$OTHER" && bk account 2>&1 | tail -1)
check_eq "$(sed 's/\x1b\[[0-9;]*m//g' <<<"$out")" "en el espacio otro: claude default · codex default" "bk account: otro espacio sigue con la de siempre"

# --- lo que se lanza en ese espacio corre con su cuenta ---
(cd "$REPO" && bk >/dev/null 2>&1)
check_eq "$(st -r '.terms.t1.argv | map(select(startswith("CLAUDE_CONFIG_DIR="))) | first // ""')" "CLAUDE_CONFIG_DIR=$A/trabajo" "el chat nuevo del espacio arranca con su cuenta"
check_eq "$(st -r '.terms.t1.labels["bk.account"] // ""')" "trabajo" "el chat queda etiquetado con la cuenta (la barra muestra su mail)"
(cd "$OTHER" && bk >/dev/null 2>&1)
check_eq "$(st -r '.terms.t2.argv | map(select(startswith("CLAUDE_CONFIG_DIR="))) | length')" "0" "un chat de otro espacio no la usa"

# --- --relaunch: el chat del espacio vuelve con la cuenta nueva y retoma su conversación ---
acc new claude otra >/dev/null
SD="$HOME/.cache/sketchybar/agents"; mkdir -p "$SD"
printf '{"pane": "t1", "state": "working"}' >"$SD/sesion-1.json"
out=$(cd "$REPO" && bk account use otra --relaunch 2>&1); rc=$?
check_eq "$rc|$(st -r '.terms | keys | join(",")')" "1|t1,t2" "--relaunch: con el chat trabajando no lo toca"
printf '{"pane": "t1", "state": "idle"}' >"$SD/sesion-1.json"
out=$(cd "$REPO" && BK_ACCOUNT_CLAUDE=trabajo bk account use otra --relaunch 2>&1); rc=$?
check_eq "$rc|$(st -r '.terms | keys | join(",")')" "0|t2,t3" "--relaunch: abre el chat nuevo y cierra el viejo"
check_eq "$(st -r '.terms.t3.argv | map(select(startswith("CLAUDE_CONFIG_DIR="))) | first // ""')|$(st -r '.terms.t3.argv[-1]')" \
  "CLAUDE_CONFIG_DIR=$A/otra|claude --resume 'sesion-1'" "--relaunch: con la cuenta nueva (no la del bk que lo pidió) y retomando la conversación"
check_eq "$(st -r '.terms.t3.labels | .["bk.kind"] + " " + .["bk.win"] + " " + .["bk.account"]')" "chat proj otra" "--relaunch: sigue siendo el chat del espacio"

(cd "$REPO" && bk chat >/dev/null 2>&1 && BK_ACCOUNT=default bk chat >/dev/null 2>&1)
check_eq "$(st -r '[.terms.t4, .terms.t5] | map(.argv | map(select(startswith("CLAUDE_CONFIG_DIR="))) | first // "-") | join("|")')" \
  "CLAUDE_CONFIG_DIR=$A/otra|-" "bk chat en el espacio usa su cuenta; bk --account default chat, la de siempre"

# --- alt+k: una fila por cuenta; los temas y fuentes de Ghostty no aparecen ---
H=$(cd "$REPO" && bk _hub palette)
check_eq "$(jq -c '.accounts | [.space, .using.claude, .using.codex, (.list | map(.name + ":" + .provider))]' <<<"$H")" \
  '["proj","otra","default",["cx:codex","otra:claude","trabajo:claude"]]' "bk _hub palette: las cuentas y cuál usa el espacio"
node --input-type=module - "$ROOT" "$H" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const [root, hub] = process.argv.slice(2);
const src = fs.readFileSync(`${root}/herdr/mods/hub/palette.js`, 'utf8')
  .replace(/^import .*;$/gm, '').replace('export default class Palette', 'class Palette');
const el = () => new Proxy({}, { get: () => () => el() });
const gotos = [];
const Palette = new Function('div', 'h_flex', 'run', 'openOverlay', 'focused', 'notify', 'Panel', 'rank', 'bk', 'bin', 'launch',
  'goto', 'termPopup', 'chips', 'keyOf', 'lit', 'cwd', 'lastLine', 'localStorage', src + '\nreturn Palette;')(
  el, el, () => {}, () => {}, () => null, () => {}, class { constructor() { this.setup?.(); } }, () => [], async () => JSON.parse(hub),
  () => 'bk', () => {}, (...a) => gotos.push(a), () => {}, () => {}, () => null, el, () => '/proj', (s) => s, { getItem: () => null });
const p = new Palette();
await p.load();
const acc = p.accountEntries();
assert.deepEqual(acc.map((e) => e.title), [
  'Usar la cuenta de Claude la de siempre en proj', 'Cuenta de Claude: otra · en uso en proj', 'Usar la cuenta de Claude trabajo en proj',
  'Cuenta de Codex: la de siempre · en uso en proj', 'Usar la cuenta de Codex cx en proj']);
acc[2].go(p); acc[3].go(p);
assert.deepEqual(gotos.map((g) => g[1].props.args), [['account', 'use', 'trabajo'], ['account', 'use', 'default', 'codex']]);
console.log('ok - alt+k: una fila por cuenta de cada proveedor, la que usa el espacio marcada, y enter corre bk account use');
const cmds = p.extra.map((e) => e.words);
assert.ok(!cmds.some((c) => /^(theme|font)\b/.test(c)), 'sin los temas ni las fuentes de Ghostty');
assert.ok(!cmds.includes('account use') && cmds.includes('account use --relaunch') && cmds.includes('account'), 'queda relanzar y la lista');
console.log('ok - alt+k: sin tema ni fuente de Ghostty ni «usar cuenta» escrita a mano; quedan la lista y relanzar');
JS
rc=$?; N=$((N+2)); [ "$rc" -eq 0 ] || FAILED=$((FAILED+1))

echo "1..$N"
[ "$FAILED" -eq 0 ]
