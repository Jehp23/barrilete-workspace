#!/usr/bin/env bash
# La épica del chat enfocado en la barra de agentes: bk _epica (lib/herdr_epica.py) con un gh falso, y el bloque
# ÉPICA de herdr/mods/agentes en node con Herdr falso. HOME y caché en un directorio temporal; no abre ventanas.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" BK_CACHE_DIR="$TMP/cache"
unset BK_BACKEND BK_PROJECT GIT_DIR GIT_WORK_TREE
mkdir -p "$HOME" "$TMP/fake"
# gh falso: #10 es la épica (sub-issues 2/5) de #11; #12 no tiene épica; #13 es épica sin padre. Sin red: falla.
cat >"$TMP/fake/gh" <<FAKE
#!/bin/sh
echo "\$*" >>"$TMP/gh.log"
[ -f "$TMP/sin-red" ] && { echo "error connecting to api.github.com" >&2; exit 1; }
case "\$2" in
  repos/o/r/issues/11/parent) echo '{"number":10,"title":"La épica","sub_issues_summary":{"completed":2,"total":5}}' ;;
  repos/o/r/issues/13) echo '{"number":13,"title":"Otra épica","sub_issues_summary":{"completed":1,"total":3}}' ;;
  repos/o/r/issues/12) echo '{"number":12,"title":"Suelto","sub_issues_summary":{"completed":0,"total":0}}' ;;
  repos/o/r/issues/*/parent) echo '{"message":"No parent issue found","status":"404"}'; echo "gh: No parent issue found (HTTP 404)" >&2; exit 1 ;;
  *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
esac
FAKE
chmod +x "$TMP/fake/gh"; : >"$TMP/gh.log"
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
ep() { PATH="$TMP/fake:$PATH" "$ROOT/bin/bk" _epica "$@"; }
calls() { wc -l <"$TMP/gh.log" | tr -d ' '; }

REPO="$TMP/proj"; git init -q -b main "$REPO"; git -C "$REPO" remote add origin "git@github.com:o/r.git"
mkdir -p "$TMP/proj-wt"; git -C "$REPO" commit -q --allow-empty -m x; git -C "$REPO" worktree add -q -b w "$TMP/proj-wt/11"

check_eq "$(ep "$REPO" claude/11-algo | jq -c .)" '{"issue":11,"epic":{"repo":"o/r","number":10,"title":"La épica","done":2,"total":5}}' "rama claude/<n>-…: la épica es el padre del issue, con su avance"
check_eq "$(ep "$REPO" claude/feat/11-algo | jq -c '[.issue, .epic.number]')" '[11,10]' "rama claude/<tipo>/<n>-…"
check_eq "$(ep "$TMP/proj-wt/11" w | jq -c '[.issue, .epic.number]')" '[11,10]' "worktree <repo>-wt/<n>: el issue sale de la carpeta"
check_eq "$(ep "$REPO" main 'Arreglar el login #11' | jq -c '[.issue, .epic.number]')" '[11,10]' "en main, el #<n> del nombre del chat"
check_eq "$(ep "$REPO" claude/13-x | jq -c '[.issue, .epic.number, .epic.done, .epic.total]')" '[13,13,1,3]' "un issue con sub-issues es su propia épica"
check_eq "$(ep "$REPO" claude/12-x | jq -c .)" '{"issue":12,"epic":null}' "issue sin épica: epic null"
: >"$TMP/gh.log"
check_eq "$(ep "$REPO" main 'sin número' | jq -c .) $(calls)" '{"issue":null,"epic":null} 0' "sin issue: null y no le pregunta nada a GitHub"
check_eq "$(ep "$REPO" release/2026-11 | jq -c .issue)" 'null' "una rama sin <n>- no es un issue"

: >"$TMP/gh.log"; ep "$REPO" claude/11-algo >/dev/null; ep "$REPO" claude/12-x >/dev/null
check_eq "$(calls)" "0" "la segunda vez sale de la caché (también el «no tiene épica»): no vuelve a pedir"
python3 - "$BK_CACHE_DIR/epica.json" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p))
for v in c.values(): v["at"] -= 3600
json.dump(c, open(p, "w"))
PY
ep "$REPO" claude/11-algo >/dev/null
check_eq "$(calls)" "1" "vencida la caché, vuelve a preguntar"

touch "$TMP/sin-red"
python3 - "$BK_CACHE_DIR/epica.json" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p))
for v in c.values(): v["at"] -= 3600
json.dump(c, open(p, "w"))
PY
check_eq "$(ep "$REPO" claude/11-algo | jq -c '[.epic.number, .offline]')" '[10,null]' "sin red: lo último guardado, aunque esté vencido"
check_eq "$(ep "$REPO" claude/14-x | jq -c .)" '{"issue":14,"epic":null,"offline":true}' "sin red y sin nada guardado: null y offline"
rm "$TMP/sin-red"
check_eq "$(ep "$REPO" claude/14-x | jq -c .epic)" 'null' "el error de red no se guardó como «no tiene épica»: con red vuelve a preguntar"
check_eq "$(tail -1 "$TMP/gh.log")" "api repos/o/r/issues/14" "…y pregunta de verdad"

# El bloque ÉPICA en la barra (herdr/mods/agentes), con Herdr falso
node --input-type=module - "$ROOT" <<'JS' && { N=$((N+1)); echo "ok $N - mod: el bloque ÉPICA de la barra"; } || { N=$((N+1)); FAILED=$((FAILED+1)); echo "not ok $N - mod: el bloque ÉPICA de la barra"; }
import fs from 'node:fs';
import assert from 'node:assert/strict';
const root = process.argv[2];
const src = fs.readFileSync(`${root}/herdr/mods/agentes/main.js`, 'utf8')
  .replace(/^import [\s\S]*?;$/gm, '').replace('export default class Agents', 'class Agents');
const node = () => {
  const n = { $id: null, $kids: [], $click: null, $tip: null, $color: [] };
  const p = new Proxy(n, { get: (o, k) => {
    if (typeof k === 'string' && k.startsWith('$')) return o[k];
    if (k === 'then') return undefined;   // que await no lo tome por una promesa
    return (...a) => {
      if (k === 'id') o.$id = a[0];
      else if (k === 'child') o.$kids.push(a[0]);
      else if (k === 'children') o.$kids.push(...a[0]);
      else if (k === 'when' && a[0]) a[1](p);
      else if (k === 'on_click') o.$click = a[0];
      else if (k === 'tooltip') o.$tip = a[0];
      else if (k === 'text_color') o.$color.push(a[0]);
      return p;
    };
  } });
  return p;
};
const walk = (n, out = []) => { if (n && n.$kids) { out.push(n); for (const k of n.$kids) walk(k, out); } return out; };
const text = (n) => walk(n).flatMap((x) => x.$kids).filter((k) => typeof k === 'string');
const block = (n) => walk(n).find((x) => x.$id === 'epic');
const colors = (b) => walk(b).flatMap((x) => x.$color);

let FOCUS = null, narrowNow = false, reply = null, execs = [], store = {};
const T = { foreground: 'FG', dim: 'DIM', accent: 'ACC', done: 'DONE' };
const deps = {
  View: class {}, div: node, svg: node, h_flex: node, v_flex: node,
  agents: () => [], terminals: () => [{ address: 't1', state: 'live', labels: { 'bk.name': 'Login #11' } }],
  focused: () => FOCUS, panes: () => [{ pane: 'p1', cwd: '/r', branch: 'main', title: 'claude' }],
  spaces: () => [], run: () => {}, theme: () => new Proxy(T, { get: (o, k) => o[k] ?? '#000' }), shared: () => undefined, setShared: () => {},
  setAgentOrder: () => {}, openOverlay: () => {}, closeOverlay: () => {}, props: () => ({}), window: () => ({}), layout: () => ({}),
  exec: async (cmd, args) => {
    execs.push([cmd, ...args]);
    if (args[0] === '_subagents') return { code: 0, stdout: '{"by_terminal":{}}' };
    if (args[0] === '_epica') return reply;
    return { code: 0, stdout: '' };
  },
  home: () => '/h', ICONS: '', PROSE: '', RANK: { blocked: 4, done: 3, working: 2, idle: 1 }, al: (c) => c, find: () => null,
  narrow: () => narrowNow, ago: () => '1m', ids: () => new Map(), said: (t) => t, picto: () => null, mark: () => '', keycap: () => '',
  iconButton: node, rule: node,
};
const Agents = new Function(...Object.keys(deps), src + '\nreturn Agents;')(...Object.values(deps));
globalThis.localStorage = { getItem: (k) => store[k] ?? null, setItem: (k, v) => { store[k] = v; }, removeItem: (k) => { delete store[k]; } };
let pending = [];
const cx = { spawn(f) { pending.push(f(cx)); }, timer: { every() {} }, notify() {} };
const settle = async () => { while (pending.length) await pending.shift(); };
const epicCalls = () => execs.filter((e) => e[1] === '_epica');
const draw = async (v) => { v.render(cx); await settle(); return v.render(cx); };

const E = { repo: 'o/r', number: 10, title: 'La épica', done: 2, total: 5 };
let v = new Agents(); v.init({}, cx); await settle();
assert.equal(block(v.render(cx)), undefined, 'sin chat enfocado ni épica vista: no hay bloque');
assert.equal(epicCalls().length, 0, 'sin chat enfocado no pregunta');

FOCUS = { terminal: 't1', pane: 'p1', cwd: '/x' };
reply = { code: 0, stdout: JSON.stringify({ issue: 11, epic: E }) };
let out = await draw(v);
assert.deepEqual(epicCalls()[0], ['bk', '_epica', '/r', 'main', 'Login #11 claude'], 'le pasa a bk _epica la carpeta y la rama del pane y el nombre del chat');
let b = block(out);
assert.ok(b, 'con épica: el bloque');
assert.deepEqual(text(b), ['ÉPICA', '#10 La épica', '▓▓▓▓░░░░░░', '2/5'], 'ÉPICA #N título, la barra y el avance');
assert.deepEqual(colors(b), ['ACC', 'FG', 'ACC', 'DIM'], 'la del chat enfocado: rótulo y barra en acento, título en primer plano (solo el 2/5 en gris)');
await draw(v); await draw(v);
assert.equal(epicCalls().length, 1, 'el mismo chat: no vuelve a preguntar en cada dibujo');
assert.equal(JSON.parse(store.epic).number, 10, 'guarda la última vista entre reinicios');

b.$click();
assert.deepEqual(execs.at(-1), ['open', 'https://github.com/o/r/issues/10'], 'clic: la épica en GitHub');

// Otro chat sin épica: queda la última vista, en gris
FOCUS = { terminal: 't2', pane: 'p2', cwd: '/otro' };
reply = { code: 0, stdout: JSON.stringify({ issue: null, epic: null }) };
out = await draw(v); b = block(out);
assert.equal(epicCalls().length, 2, 'cambió el chat enfocado: vuelve a preguntar');
assert.deepEqual(text(b).slice(0, 2), ['ÉPICA', '#10 La épica'], 'sin épica: la última vista, no se esconde');
assert.deepEqual(colors(b), ['DIM', 'DIM', 'DIM', 'DIM'], 'la última vista va toda en gris');
assert.match(b.$tip, /última vista/, 'y el tooltip dice que es la última vista');

// bk falla: no se sabe, va la última en gris (no la del chat anterior como si fuera de este)
FOCUS = { terminal: 't1', pane: 'p1', cwd: '/x' };
reply = { code: 0, stdout: JSON.stringify({ issue: 11, epic: E }) };
await draw(v);
FOCUS = { terminal: 't3', pane: 'p3', cwd: '/y' };
reply = { code: 1, stdout: '' };
b = block(await draw(v));
assert.deepEqual(colors(b), ['DIM', 'DIM', 'DIM', 'DIM'], 'si bk _epica falla, gris');

// Reinicio: la última vista vuelve aunque el chat enfocado no tenga épica; completa, la barra llena
store.epic = JSON.stringify({ ...E, done: 5 });
v = new Agents(); v.init({}, cx); await settle();
reply = { code: 0, stdout: JSON.stringify({ issue: null, epic: null }) };
b = block(await draw(v));
assert.deepEqual(text(b).slice(1), ['#10 La épica', '▓▓▓▓▓▓▓▓▓▓', '5/5'], 'después de reiniciar, la última vista guardada');

// El riel (angosto) no lleva el bloque
narrowNow = true;
assert.equal(block(await draw(v)), undefined, 'en el riel no hay bloque');

JS

echo "1..$N"
[ "$FAILED" -eq 0 ]
