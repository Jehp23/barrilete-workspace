#!/usr/bin/env bash
# La pestaña TODO del panel derecho (alt+t): bk _todo (lib/herdr_todo.py) con un gh falso, y en node, con Herdr
# falso, la pestaña de herdr/mods/lado y el comando todo de herdr/mods/bk. HOME y caché en un directorio temporal; no abre ventanas ni sale a la red.
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

node --input-type=module - "$ROOT" <<'JS' && { N=$((N+1)); echo "ok $N - mod: la pestaña TODO del panel derecho y alt+t"; } || { N=$((N+1)); FAILED=$((FAILED+1)); echo "not ok $N - mod: la pestaña TODO del panel derecho y alt+t"; }
import fs from 'node:fs';
import assert from 'node:assert/strict';
const root = process.argv[2];
const strip = (f, cls) => fs.readFileSync(`${root}/${f}`, 'utf8').replace(/^import [\s\S]*?;$/gm, '').replace(`export default class ${cls}`, `class ${cls}`);
const node = () => {
  const n = { $id: null, $kids: [], $click: null };
  const p = new Proxy(n, { get: (o, k) => {
    if (typeof k === 'string' && k.startsWith('$')) return o[k];
    if (k === 'then') return undefined;
    return (...a) => {
      if (k === 'id') o.$id = a[0];
      else if (k === 'child') o.$kids.push(a[0]);
      else if (k === 'children') o.$kids.push(...a[0]);
      else if (k === 'when' && a[0]) a[1](p);
      else if (k === 'on_click') o.$click = a[0];
      return p;
    };
  } });
  return p;
};
const walk = (n, out = []) => { if (n && n.$kids) { out.push(n); for (const k of n.$kids) walk(k, out); } return out; };
const text = (n) => walk(n).flatMap((x) => x.$kids).filter((k) => typeof k === 'string');
const byId = (o, id) => walk(o).find((x) => x.$id === id);
const card = (t, title, right, body) => node().id(`card-${title}`).child(title).child(right).children(body);
let execs = [], todoReply = null, focusedT = null, store = {}, runs = [], sideChanges = [];
const deps = {
  View: class {}, div: node, svg: node, h_flex: node, v_flex: node,
  exec: async (cmd, args) => {
    execs.push([cmd, ...args]);
    if (args[0] === '_side') return { code: 0, stdout: JSON.stringify({ project: 'r', path: '/h/r', branch: 'w', dirty: 0, profile: [], changes: sideChanges, context: null }) };
    if (args[0] === '_todo') return { code: 0, stdout: JSON.stringify(todoReply) };
    return { code: 1, stdout: '', stderr: '' };
  },
  run: (...a) => runs.push(a), focused: () => focusedT, panes: () => [{ pane: 'p1', branch: 'claude/17-a', title: 'Claude' }],
  terminals: () => [{ address: 't1', labels: { 'bk.name': 'Chat de #17' } }],
  theme: () => new Proxy({}, { get: (o, k) => k }), home: () => '/h',
  shared: (k) => store[k] ?? null, setShared: (k, v) => { store[k] = v; },
  ICONS: '', PROSE: '', al: (c) => c, card, pill: (t, s) => node().child(s),
};
const Lado = new Function(...Object.keys(deps), strip('herdr/mods/lado/main.js', 'Lado') + '\nreturn Lado;')(...Object.values(deps));
let pending = [];
const cx = { spawn(f) { pending.push(f(cx)); }, timer: { every() {} }, notify() {} };
const settle = async () => { while (pending.length) await pending.shift(); };
const todoCalls = () => execs.filter((e) => e[1] === '_todo');

focusedT = { terminal: 't1', pane: 'p1', cwd: '/h/r' };
todoReply = { issue: 17, repo: 'o/r', title: 'Elegir la carpeta', state: 'open', url: 'https://github.com/o/r/issues/17',
  items: [{ text: 'Uno `x`', done: true, section: 'Hecho cuando' }, { text: 'Dos', done: false, section: 'Hecho cuando' }, { text: 'Tres', done: false, section: 'Después' }], done: 1, total: 3 };
const v = new Lado(); v.init({}, cx); await settle();
let o = v.render(cx); await settle();
assert.ok(byId(o, 'tab-estado') && byId(o, 'tab-todo'), 'arriba, las pestañas Estado y TODO');
assert.deepEqual(walk(o).filter((x) => /^card-/.test(x.$id ?? '')).map((x) => x.$id), ['card-SESIÓN', 'card-GITHUB'], 'en Estado, sesión y GitHub (los cambios tienen su pestaña)');
assert.ok(byId(o, 'tab-cambios'), 'arriba, también la pestaña Cambios');
assert.equal(todoCalls().length, 0, 'en Estado no le pregunta a bk _todo');

byId(o, 'tab-todo').$click();
assert.equal(store['bk.lado.tab'], 'todo', 'el clic en TODO la elige (shared bk.lado.tab)');
o = v.render(cx); await settle(); o = v.render(cx);
assert.deepEqual(todoCalls()[0], ['bk', '_todo', '/h/r', 'claude/17-a', 'Chat de #17 Claude', 't1'], 'al elegir TODO pide los pasos del chat enfocado, sin esperar el tick');
assert.ok(!walk(o).some((x) => /^card-/.test(x.$id ?? '')), 'en TODO no están las tarjetas');
const tx = text(byId(o, 'lado-todo'));
for (const s of ['#17', 'Elegir la carpeta', 'Hecho cuando', 'Uno x', 'Dos', 'Después', 'Tres']) assert.ok(tx.includes(s), `muestra «${s}»: ${JSON.stringify(tx)}`);
assert.ok(text(byId(o, 'tab-todo')).includes('1/3'), 'la pestaña dice cuántas hechas');
assert.ok(tx.indexOf('Después') > tx.indexOf('Dos') && tx.indexOf('Tres') > tx.indexOf('Después'), 'agrupadas por sección, en orden');
execs = []; byId(o, 'todo-issue').$click();
assert.deepEqual(execs, [['open', 'https://github.com/o/r/issues/17']], 'el clic en el issue lo abre en GitHub');

const n = todoCalls().length; v.render(cx); await settle(); await v.loadTodo();
assert.equal(todoCalls().length, n, 'el mismo chat: no vuelve a pedir antes de TODO_EVERY');

todoReply = { issue: null };
focusedT = { terminal: 't1', pane: 'p1', cwd: '/h/otra' }; v.render(cx); await settle();
assert.ok(text(byId(v.render(cx), 'lado-todo')).includes('Este chat no trabaja un issue'), 'sin issue: lo dice');

todoReply = { issue: 18, repo: 'o/r', title: 'Sin pasos', state: 'closed', items: [], done: 0, total: 0 };
focusedT = { terminal: 't1', pane: 'p1', cwd: '/h/r2' }; v.render(cx); await settle();
const t18 = text(byId(v.render(cx), 'lado-todo'));
assert.ok(t18.includes('El issue no tiene casillas (- [ ])') && t18.includes('cerrado'), `sin casillas y cerrado: ${JSON.stringify(t18)}`);

execs = []; focusedT = { terminal: null, pane: null, cwd: '/h/r' }; v.render(cx); await settle();
assert.ok(text(byId(v.render(cx), 'lado-todo')).includes('Parate en un chat para ver sus pasos'), 'sin una terminal enfocada: lo dice');
assert.equal(todoCalls().length, 0, 'y no le pregunta a bk _todo');

byId(v.render(cx), 'tab-estado').$click();
assert.equal(store['bk.lado.tab'], 'estado', 'el clic en Estado vuelve');
assert.ok(walk(v.render(cx)).some((x) => x.$id === 'card-SESIÓN'), 'y vuelven las tarjetas');

// La pestaña Cambios: todos los archivos (no solo 14) y el clic abre el diff en un pane al lado del enfocado
sideChanges = [{ name: 'r', branch: 'main', path: '/h/r', more: 2, files: Array.from({ length: 20 }, (_, i) => ({ code: i ? 'M' : 'D', path: `f${i}.js`, add: String(i), del: '0' })) },
  { name: '7', branch: 'w7', path: '/h/r-wt/7', more: 0, files: [{ code: 'A', path: 'nuevo.py', add: '5', del: '0' }] }];
v.busy = false; v.data = null; await v.load(); store['bk.lado.tab'] = 'cambios';
o = v.render(cx);
assert.ok(!byId(o, 'card-SESIÓN') && byId(o, 'lado-cambios'), 'en Cambios, la lista en lugar de las tarjetas');
assert.equal(walk(o).filter((x) => /^cambio-/.test(x.$id ?? '')).length, 21, 'todos los archivos de cada worktree');
assert.ok(text(o).includes('… y 2 más') && text(byId(o, 'tab-cambios')).includes('23'), 'los que bk _side no mandó se cuentan, y la pestaña dice el total');
const keepF = focusedT; focusedT = null; runs = []; byId(o, 'cambio-7-0').$click();
assert.deepEqual(runs.map((r) => [r[0], r[1].name, r[1].mod]), [['tab.new', 'nuevo.py', 'bk-changes']], 'sin pane en foco: el diff en una pestaña');
focusedT = { terminal: 't1', pane: 'p1', cwd: '/h/r' }; runs = []; byId(o, 'cambio-7-0').$click();
assert.deepEqual(runs, [['pane.split', { direction: 'right', pane: 'p1', mod: 'bk-changes', props: { diff: { root: '/h/r-wt/7', path: 'nuevo.py', code: 'A', add: 5, del: 0 } } }]], 'el clic en un archivo: su diff en un pane a la derecha');
sideChanges = []; await v.load(); o = v.render(cx);
assert.ok(text(o).includes('Todo guardado en Git'), 'sin cambios: todo guardado');
focusedT = keepF; store['bk.lado.tab'] = 'estado';

// alt+t (mods/bk, comando todo): el panel a la vista y en TODO; otra vez, en Estado
const Bk = new Function('View', 'div', 'hc', 'exec', 'run', 'props', 'openOverlay', 'closeOverlay', 'focused', 'terminals', 'spaces', 'agents', 'home', 'notify', 'shared', 'setShared', 'readTextFile',
  strip('herdr/mods/bk/main.js', 'Bk') + '\nreturn Bk;')(class {}, node, null, null, (...a) => runs.push(a), () => ({}), null, null, () => null, () => [], () => [], () => [], () => '/h',
  (...a) => runs.push(['notify', ...a]), deps.shared, deps.setShared, null);
const bk = new Bk();
store = {}; runs = []; await bk.handle('todo');
assert.deepEqual([store['bk.lado.tab'], runs], ['todo', [['layout.show', { id: 'lado' }]]], 'alt+t: muestra el panel derecho en TODO');
runs = []; await bk.handle('todo');
assert.deepEqual([store['bk.lado.tab'], runs], ['estado', [['layout.show', { id: 'lado' }]]], 'alt+t otra vez: vuelve a Estado');

assert.equal(JSON.parse(fs.readFileSync(`${root}/herdr/keys.json`, 'utf8')).global['alt-t'], 'mod.open:bk-todo', 'alt+t abre bk-todo');
store = {}; runs = []; await bk.handle('cambios');
assert.deepEqual([store['bk.lado.tab'], runs], ['cambios', [['layout.show', { id: 'lado' }]]], 'alt+g: muestra el panel derecho en Cambios');
store['bk.lado.tab'] = 'todo'; runs = []; await bk.handle('cambios');
assert.equal(store['bk.lado.tab'], 'cambios', 'alt+g desde TODO: va a Cambios');
await bk.handle('cambios');
assert.equal(store['bk.lado.tab'], 'estado', 'alt+g otra vez: vuelve a Estado');
assert.equal(JSON.parse(fs.readFileSync(`${root}/herdr/keys.json`, 'utf8')).global['alt-g'], 'mod.open:bk-cambios', 'alt+g abre bk-cambios');
assert.ok(!JSON.parse(fs.readFileSync(`${root}/herdr/mods/hub/views.json`, 'utf8')).changes.overlay, 'la ventana grande de Cambios se va: bk-changes queda solo para los panes');
assert.ok(!('todo' in JSON.parse(fs.readFileSync(`${root}/herdr/mods/hub/views.json`, 'utf8'))), 'bk-todo no es una ventana del hub: es un comando de mods/bk');
JS

echo "1..$N"
[ "$FAILED" -eq 0 ]
