#!/usr/bin/env bash
# La tarjeta TODO del panel derecho: bk _todo (lib/herdr_todo.py) con un gh falso, y la tarjeta de herdr/mods/lado
# en node con Herdr falso. HOME y caché en un directorio temporal; no abre ventanas ni sale a la red.
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

node --input-type=module - "$ROOT" <<'JS' && { N=$((N+1)); echo "ok $N - mod: la tarjeta TODO del panel derecho"; } || { N=$((N+1)); FAILED=$((FAILED+1)); echo "not ok $N - mod: la tarjeta TODO del panel derecho"; }
import fs from 'node:fs';
import assert from 'node:assert/strict';
const root = process.argv[2];
const src = fs.readFileSync(`${root}/herdr/mods/lado/main.js`, 'utf8')
  .replace(/^import [\s\S]*?;$/gm, '').replace('export default class Lado', 'class Lado');
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
const card = (t, title, right, body) => node().id(`card-${title}`).child(title).child(right).children(body);
let execs = [], todoReply = null, focusedT = null;
const deps = {
  View: class {}, div: node, svg: node, h_flex: node, v_flex: node,
  exec: async (cmd, args) => {
    execs.push([cmd, ...args]);
    if (args[0] === '_side') return { code: 0, stdout: JSON.stringify({ project: 'r', path: '/h/r', branch: 'w', dirty: 0, profile: [], changes: [], context: null }) };
    if (args[0] === '_todo') return { code: 0, stdout: JSON.stringify(todoReply) };
    return { code: 1, stdout: '', stderr: '' };
  },
  focused: () => focusedT, panes: () => [{ pane: 'p1', branch: 'claude/17-a', title: 'Claude' }],
  terminals: () => [{ address: 't1', labels: { 'bk.name': 'Chat de #17' } }],
  theme: () => new Proxy({}, { get: (o, k) => k }), home: () => '/h', shared: () => null,
  ICONS: '', PROSE: '', al: (c) => c, card, pill: (t, s) => node().child(s),
};
const Lado = new Function(...Object.keys(deps), src + '\nreturn Lado;')(...Object.values(deps));
let pending = [];
const cx = { spawn(f) { pending.push(f(cx)); }, timer: { every() {} }, notify() {} };
const settle = async () => { while (pending.length) await pending.shift(); };
const todoCard = (o) => walk(o).find((x) => x.$id === 'card-TODO');

focusedT = { terminal: 't1', pane: 'p1', cwd: '/h/r' };
todoReply = { issue: 17, repo: 'o/r', title: 'Elegir la carpeta', state: 'open', url: 'https://github.com/o/r/issues/17',
  items: [{ text: 'Uno `x`', done: true, section: 'Hecho cuando' }, { text: 'Dos', done: false, section: 'Hecho cuando' }], done: 1, total: 2 };
const v = new Lado(); v.init({}, cx); await settle();
let o = v.render(cx), c = todoCard(o);
assert.ok(c, 'hay tarjeta TODO');
assert.deepEqual(execs.find((e) => e[1] === '_todo'), ['bk', '_todo', '/h/r', 'claude/17-a', 'Chat de #17 Claude', 't1'], 'le pasa a bk _todo la carpeta, la rama, el nombre y la terminal del chat enfocado');
const tx = text(c);
for (const s of ['1/2', '#17', 'Elegir la carpeta', 'Uno x', 'Dos']) assert.ok(tx.includes(s), `muestra «${s}»: ${JSON.stringify(tx)}`);
assert.ok(!tx.includes('Hecho cuando'), 'con una sola sección no repite su título');
const titles = walk(o).filter((x) => /^card-/.test(x.$id ?? '')).map((x) => x.$id);
assert.deepEqual(titles, ['card-SESIÓN', 'card-TODO', 'card-GITHUB', 'card-CAMBIOS'], 'TODO va entre SESIÓN y GITHUB');

const n = execs.length; await v.loadTodo(); assert.equal(execs.length, n, 'el mismo chat: no vuelve a pedir antes de TODO_EVERY');

todoReply = { issue: null };
focusedT = { terminal: 't1', pane: 'p1', cwd: '/h/otra' }; await v.loadTodo();
assert.ok(text(todoCard(v.render(cx))).includes('Este chat no trabaja un issue'), 'sin issue: lo dice');

todoReply = { issue: 18, repo: 'o/r', title: 'Sin pasos', state: 'closed', items: [], done: 0, total: 0 };
focusedT = { terminal: 't1', pane: 'p1', cwd: '/h/r2' }; await v.loadTodo();
const t18 = text(todoCard(v.render(cx)));
assert.ok(t18.includes('El issue no tiene casillas (- [ ])') && t18.includes('cerrado'), `sin casillas y cerrado: ${JSON.stringify(t18)}`);

focusedT = { terminal: null, pane: null, cwd: '/h/r' }; await v.loadTodo();
assert.ok(!todoCard(v.render(cx)), 'una pestaña que no es terminal: sin tarjeta TODO');
JS

echo "1..$N"
[ "$FAILED" -eq 0 ]
