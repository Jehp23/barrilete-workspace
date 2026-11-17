#!/usr/bin/env bash
# La ventana TODO (alt+t): bk _todo (lib/herdr_todo.py) con un gh falso, y la vista herdr/mods/hub/todo.js en node
# con Herdr falso. HOME y caché en un directorio temporal; no abre ventanas ni sale a la red.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" BK_CACHE_DIR="$TMP/cache"
unset BK_BACKEND BK_PROJECT GIT_DIR GIT_WORK_TREE
mkdir -p "$HOME" "$TMP/fake"
# gh falso: #17 tiene dos secciones con casillas y una casilla dentro de un bloque de código; #18 no tiene casillas.
cat >"$TMP/fake/gh" <<FAKE
#!/bin/sh
echo "\$*" >>"$TMP/gh.log"
[ -f "$TMP/sin-red" ] && { echo "error connecting to api.github.com" >&2; exit 1; }
case "\$2" in
  repos/o/r/issues/17) jq -n '{number:17, title:"Elegir la carpeta", state:"open", html_url:"https://github.com/o/r/issues/17",
    body:"Texto.\n\n## Hecho cuando\n- [x] **Uno** listo\n- [ ] Dos\n\n\`\`\`\n- [ ] no cuenta\n\`\`\`\n### Después\n* [X] Tres\n"}' ;;
  repos/o/r/issues/18) echo '{"number":18,"title":"Sin pasos","state":"closed","html_url":"https://github.com/o/r/issues/18","body":"nada"}' ;;
  *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
esac
FAKE
chmod +x "$TMP/fake/gh"; : >"$TMP/gh.log"
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
td() { PATH="$TMP/fake:$PATH" "$ROOT/bin/bk" _todo "$@"; }
calls() { wc -l <"$TMP/gh.log" | tr -d ' '; }

REPO="$TMP/proj"; git init -q -b main "$REPO"; git -C "$REPO" remote add origin "git@github.com:o/r.git"
mkdir -p "$TMP/proj-wt"; git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
git -C "$REPO" worktree add -q -b w "$TMP/proj-wt/17"

check_eq "$(td "$TMP/proj-wt/17" w | jq -c '[.issue, .repo, .title, .done, .total]')" '[17,"o/r","Elegir la carpeta",2,3]' "worktree <repo>-wt/<n>: el issue, su título y cuántas casillas están tildadas"
check_eq "$(td "$TMP/proj-wt/17" w | jq -c '[.items[] | [.done, .section, .text]]')" '[[true,"Hecho cuando","Uno listo"],[false,"Hecho cuando","Dos"],[true,"Después","Tres"]]' "las casillas, con su sección y sin las de un bloque de código"
check_eq "$(td "$REPO" claude/17-algo | jq -c '[.issue, .total]')" '[17,3]' "el issue sale de la rama, como en ÉPICAS"
check_eq "$(td "$REPO" main "Chat de #18" | jq -c '[.issue, .state, .total, .items]')" '[18,"closed",0,[]]' "un issue sin casillas: total 0"
check_eq "$(td "$REPO" main "sin número" | jq -c .)" '{"issue":null}' "sin issue: issue null"
check_eq "$(td "$REPO" main "#99" | jq -c '[.issue, has("items"), has("offline")]')" '[99,false,false]' "un issue que GitHub no conoce: sin pasos y sin offline"

: >"$TMP/gh.log"; td "$TMP/proj-wt/17" w >/dev/null
check_eq "$(calls)" "0" "caché: dentro de los dos minutos no le pregunta a GitHub"
vencer() { jq '.["o/r#17"].at = 0' "$BK_CACHE_DIR/todo.json" >"$TMP/c.json" && mv "$TMP/c.json" "$BK_CACHE_DIR/todo.json"; }
vencer; td "$TMP/proj-wt/17" w >/dev/null
check_eq "$(calls)" "1" "caché vencida: vuelve a preguntarle a GitHub"
touch "$TMP/sin-red"; vencer
check_eq "$(td "$TMP/proj-wt/17" w | jq -c '[.done, .total, has("offline")]')" '[2,3,false]' "sin red y la caché vencida: lo último guardado"
rm -f "$BK_CACHE_DIR/todo.json"
check_eq "$(td "$TMP/proj-wt/17" w | jq -c '[.issue, .offline]')" '[17,true]' "sin red y sin nada guardado: offline"
rm -f "$TMP/sin-red"

node --input-type=module - "$ROOT" <<'JS' && { N=$((N+1)); echo "ok $N - mod: la ventana TODO (alt+t)"; } || { N=$((N+1)); FAILED=$((FAILED+1)); echo "not ok $N - mod: la ventana TODO (alt+t)"; }
import fs from 'node:fs';
import assert from 'node:assert/strict';
const root = process.argv[2];
const src = fs.readFileSync(`${root}/herdr/mods/hub/todo.js`, 'utf8')
  .replace(/^import .*;$/gm, '').replace('export default class Todo', 'class Todo');
const el = () => new Proxy({}, { get: (_, k) => (...a) => { if (k === 'when' && a[0]) a[1](el()); return el(); } });
class Panel {
  constructor() { this.query = ''; this.at = 0; this.setup?.(); }
  close() { calls.push(['close']); }
}
let calls = [], focus = null, reply = null;
const bk = async (args, opts = {}) => { calls.push(['bk', ...args]); return reply; };
const Todo = new Function('div', 'h_flex', 'focused', 'panes', 'terminals', 'Panel', 'rank', 'bk', 'openUrl', 'pill', src + '\nreturn Todo;')(
  el, el, () => focus, () => [{ pane: 'p1', branch: 'claude/17-a', title: 'Claude' }],
  () => [{ address: 't1', labels: { 'bk.name': 'Chat de #17' } }], Panel,
  (items, q) => items.filter((x) => !q.trim() || x.text.toLowerCase().includes(q.trim().toLowerCase())).map((item) => ({ item, hits: [] })),
  bk, (u) => calls.push(['open', u]), el);
const picks = (v) => v.rows().filter((r) => !r.head);

focus = { terminal: 't1', pane: 'p1', cwd: '/h/r' };
reply = { issue: 17, repo: 'o/r', title: 'Elegir la carpeta', state: 'open', url: 'https://github.com/o/r/issues/17',
  items: [{ text: 'Uno `x`', done: true, section: 'Hecho cuando' }, { text: 'Dos', done: false, section: 'Hecho cuando' }, { text: 'Tres', done: false, section: 'Después' }], done: 1, total: 3 };
let v = new Todo(); await v.load();
assert.deepEqual(calls[0], ['bk', '_todo', '/h/r', 'claude/17-a', 'Chat de #17 Claude', 't1'], 'le pasa a bk _todo la carpeta, la rama, el nombre y la terminal del chat enfocado');
assert.equal(v.subtitle(), '#17 · 1/3 hechas', 'arriba: el issue y cuántas hechas');
assert.deepEqual(v.rows().map((r) => r.head ?? [r.kind, r.text, r.done]),
  [['issue', 'Elegir la carpeta', undefined], 'Hecho cuando', ['item', 'Uno x', true], ['item', 'Dos', false], 'Después', ['item', 'Tres', false]],
  'el issue primero y una fila por casilla, agrupadas por sección');
v.query = 'tres';
assert.deepEqual(v.rows().map((r) => r.head ?? r.text), ['Después', 'Tres'], 'buscar filtra las casillas');
v.query = '';
assert.deepEqual(v.hints(), [['enter', 'GitHub'], ['escape', 'cerrar']], 'hints: enter GitHub y esc cerrar');
calls = []; v.enter(picks(v)[2]);
assert.deepEqual(calls, [['open', 'https://github.com/o/r/issues/17'], ['close']], 'Enter abre el issue y cierra');
assert.equal(picks(v)[1].h, 34, 'una casilla corta: una fila');
reply.items = [{ text: 'x'.repeat(200), done: false, section: '' }];
v = new Todo(); await v.load();
assert.ok(picks(v)[1].h > 34, 'una casilla larga ocupa una fila más alta');

reply = { issue: null };
v = new Todo(); await v.load();
assert.deepEqual([v.rows(), v.empty(), v.subtitle()], [[], 'Este chat no trabaja un issue', ''], 'sin issue: lo dice');

reply = { issue: 18, repo: 'o/r', title: 'Sin pasos', state: 'closed', url: 'https://github.com/o/r/issues/18', items: [], done: 0, total: 0 };
v = new Todo(); await v.load();
assert.deepEqual(picks(v).map((r) => [r.kind, r.text]), [['issue', 'Sin pasos'], ['none', 'El issue no tiene casillas (- [ ])']], 'sin casillas: lo dice');

calls = []; focus = { terminal: null, pane: null, cwd: '/h/r' };
v = new Todo(); await v.load();
assert.deepEqual([calls, v.rows(), v.hints()], [[], [], [['escape', 'cerrar']]], 'sin una terminal enfocada: no le pregunta a bk');
assert.match(v.empty(), /alt\+t/, 'y dice que te pares en un chat');

const views = JSON.parse(fs.readFileSync(`${root}/herdr/mods/hub/views.json`, 'utf8'));
assert.deepEqual(views.todo.overlay, { kind: 'popup', at: 'top', offset: 64, width: 640, height: 0.7 }, 'views.json: su popup');
assert.match(fs.readFileSync(`${root}/herdr/mods/hub/main.js`, 'utf8'), /\btodo: Todo\b/, 'main.js la registra');
assert.equal(JSON.parse(fs.readFileSync(`${root}/herdr/keys.json`, 'utf8')).global['alt-t'], 'mod.open:bk-todo', 'alt+t la abre');
assert.doesNotMatch(fs.readFileSync(`${root}/herdr/mods/lado/main.js`, 'utf8'), /_todo|TODO/, 'el panel derecho ya no tiene la tarjeta');
JS

echo "1..$N"
[ "$FAILED" -eq 0 ]
