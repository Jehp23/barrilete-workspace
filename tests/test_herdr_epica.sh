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

# Varios chats en una llamada (la barra pide los de todos los espacios juntos)
: >"$TMP/gh.log"; rm -f "$BK_CACHE_DIR/epica.json"
check_eq "$(ep --json "[[\"$REPO\",\"claude/11-a\",\"\"],[\"$REPO\",\"main\",\"nada\"],[\"$REPO\",\"claude/13-b\",\"\"],[\"$TMP/proj-wt/11\",\"w\",\"\"]]" | jq -c 'map(.epic.number)')" '[10,null,13,10]' "--json: una respuesta por chat, en el mismo orden"
check_eq "$(grep -c 'issues/11/parent' "$TMP/gh.log") $(calls)" "1 3" "--json: a GitHub una vez por issue (el #11 de dos chats, una vez; el #13, dos pedidos)"
check_eq "$(ep --json 'no es json' 2>&1; echo "rc=$?")" "bk _epica --json '[[carpeta, rama, texto, terminal], …]'
rc=1" "--json con algo que no es una lista: el uso, y falla"

# La conversación de Claude de la terminal: un chat abierto en el checkout principal implementa en un worktree sin
# mover su carpeta, y la rama del checkout puede ser de otro chat. Manda el último worktree o prepare.sh de sus comandos.
export BK_PROJECTS="$TMP/projects"   # el estado de los chats: bin/bk lo lee de $HOME/.cache/sketchybar/agents
mkdir -p "$HOME/.cache/sketchybar/agents" "$BK_PROJECTS/p"
echo '{"pane":"t9","ts":1}' >"$HOME/.cache/sketchybar/agents/s9.json"
cmd() { jq -cn --arg c "$1" '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:$c}}]}}'; }
out() { jq -cn --arg c "$1" '{type:"user",message:{content:[{type:"tool_result",tool_use_id:"toolu_1",content:$c}]}}'; }   # como las de verdad: dice tool_use
{ cmd ".claude/skills/implement-issue/prepare.sh 12"; cmd "cd $TMP/proj-wt/13 && git status"; out "$TMP/proj-wt/11 [w] $TMP/proj-wt/14"; } >"$BK_PROJECTS/p/s9.jsonl"
check_eq "$(ep "$REPO" claude/11-algo "" t9 | jq -c '[.issue, .epic.number]')" '[13,13]' "conversación: el último worktree de sus comandos manda sobre la rama del checkout; lo que le respondieron no cuenta"
cmd "cd $REPO && bash .claude/skills/implement-issue/prepare.sh 12" >>"$BK_PROJECTS/p/s9.jsonl"
check_eq "$(ep "$REPO" claude/11-algo "" t9 | jq -c .issue)" '12' "…el último: prepare.sh <n> también"
cmd "ls $TMP/otro-wt/77 $TMP/proj-wt/15x" >>"$BK_PROJECTS/p/s9.jsonl"
cmd "echo 'corré prepare.sh 16' && python3 - <<'EOF'\nx = 'prepare.sh 17'\nEOF" >>"$BK_PROJECTS/p/s9.jsonl"
check_eq "$(ep "$REPO" claude/11-algo "" t9 | jq -c .issue)" '12' "el worktree de otro repo, uno que no es <n> o un prepare.sh nombrado en un texto (no corrido) no cuentan"
check_eq "$(ep "$TMP/proj-wt/11" w "" t9 | jq -c .issue)" '11' "un chat en su propio worktree: manda la carpeta"
check_eq "$(ep "$REPO" claude/11-algo "" t8 | jq -c .issue)" '11' "una terminal sin conversación: la rama, como antes"
: >"$BK_PROJECTS/p/s9.jsonl"
check_eq "$(ep "$REPO" claude/11-algo "" t9 | jq -c .issue)" '11' "una conversación sin worktree: la rama"
check_eq "$(jq -r 'keys[0]' "$BK_CACHE_DIR/epica-sesiones.json")" "$BK_PROJECTS/p/s9.jsonl" "guarda lo leído de cada conversación (por tamaño: no relee si no creció)"
unset BK_PROJECTS

# Las épicas debajo de cada espacio (herdr/mods/agentes), con Herdr falso
node --input-type=module - "$ROOT" <<'JS' && { N=$((N+1)); echo "ok $N - mod: la épica debajo de su espacio"; } || { N=$((N+1)); FAILED=$((FAILED+1)); echo "not ok $N - mod: la épica debajo de su espacio"; }
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
const colors = (b) => walk(b).flatMap((x) => x.$color);
// La lista de espacios en orden: sp-<id> y epic-<espacio>-<repo>#<n>
const list = (out) => walk(walk(out).find((x) => x.$id === 'sp-list')).map((x) => x.$id).filter((i) => /^(sp|epic)-/.test(i ?? '') && i !== 'sp-list');
const row = (out, id) => walk(out).find((x) => x.$id === id);

// abra (s1) tiene dos chats; otro (s2), uno; vacio (s3), ninguno
let AG = [], narrowNow = false, reply = null, execs = [], store = {};
const T = { foreground: 'FG', muted: 'MUT', dim: 'DIM', accent: 'ACC', done: 'DONE' };
const SP = [{ id: 's1', name: 'abra', tabs: [] }, { id: 's2', name: 'otro', tabs: [] }, { id: 's3', name: 'vacio', tabs: [] }];
const deps = {
  View: class {}, div: node, svg: node, h_flex: node, v_flex: node,
  agents: () => AG, terminals: () => AG.map((a) => ({ address: a.address, state: 'live', labels: a.labels ?? {} })),
  focused: () => null, panes: () => AG.map((a) => ({ pane: a.pane, cwd: a.cwd, branch: a.branch, title: a.title })),
  spaces: () => SP, run: () => {}, theme: () => new Proxy(T, { get: (o, k) => o[k] ?? '#000' }), shared: () => undefined, setShared: () => {},
  setAgentOrder: () => {}, openOverlay: () => {}, closeOverlay: () => {}, props: () => ({}), window: () => ({}), layout: () => ({}),
  exec: async (cmd, args) => {
    execs.push([cmd, ...args]);
    if (args[0] === '_subagents') return { code: 0, stdout: '{"by_terminal":{}}' };
    if (args[0] === '_epica') return reply(JSON.parse(args[2]));
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
const agent = (address, space, cwd, branch, title, labels) => ({ address, space, space_name: space, pane: `p-${address}`, tab: `tab-${address}`, status: 'idle', cwd, branch, title, labels, seq: 0 });

const E10 = { repo: 'o/r', number: 10, title: 'La épica', done: 2, total: 5 };
const E13 = { repo: 'o/r', number: 13, title: 'Otra', done: 3, total: 3 };
// el falso de bk _epica: por la rama
const BY = { 'claude/11-a': E10, 'claude/12-b': E10, 'claude/14-c': E13 };
reply = (qs) => ({ code: 0, stdout: JSON.stringify(qs.map(([, b]) => ({ issue: 1, epic: BY[b] ?? null }))) });

AG = [agent('t1', 's1', '/abra', 'claude/11-a', 'uno'), agent('t2', 's1', '/abra', 'claude/12-b', 'dos', { 'bk.name': 'Dos #12' }), agent('t3', 's2', '/otro', 'main', 'tres')];
let v = new Agents(); v.init({}, cx); await settle();
let out = await draw(v);
assert.deepEqual(epicCalls()[0], ['bk', '_epica', '--json', JSON.stringify([['/abra', 'claude/11-a', 'uno', 't1'], ['/abra', 'claude/12-b', 'Dos #12 dos', 't2'], ['/otro', 'main', 'tres', 't3']])], 'una sola llamada con carpeta, rama y nombre de cada chat');
assert.deepEqual(list(out), ['sp-s1', 'epic-s1-o/r#10', 'sp-s2', 'sp-s3'], 'la épica va debajo de su espacio, una vez aunque la tengan dos chats; los espacios sin épica, sin línea');
let b = row(out, 'epic-s1-o/r#10');
assert.deepEqual(text(b), ['ÉPICA', '#10 La épica', '▓▓░░░░', '2/5'], 'ÉPICA #N título, la barra y el avance');
assert.deepEqual(colors(b), ['ACC', 'MUT', 'ACC', 'DIM'], 'la actual: rótulo y barra en acento');
b.$click();
assert.deepEqual(execs.at(-1), ['open', 'https://github.com/o/r/issues/10'], 'clic: la épica en GitHub');
await draw(v); await draw(v);
assert.equal(epicCalls().length, 1, 'los mismos chats: no vuelve a preguntar en cada dibujo');
assert.equal(JSON.parse(store.epics).s1.number, 10, 'guarda la última vista de cada espacio entre reinicios');

// Dos épicas en un espacio: una línea por cada una
AG.push(agent('t4', 's1', '/abra', 'claude/14-c', 'cuatro'));
out = await draw(v);
assert.equal(epicCalls().length, 2, 'cambiaron los chats: vuelve a preguntar');
assert.deepEqual(list(out), ['sp-s1', 'epic-s1-o/r#10', 'epic-s1-o/r#13', 'sp-s2', 'sp-s3'], 'dos épicas en abra: dos líneas');
assert.deepEqual(colors(row(out, 'epic-s1-o/r#13')).slice(2, 3), ['DONE'], 'completa: la barra en el color de listo');

// Los chats de abra dejan de tener épica: queda la última vista ahí, en gris
AG = [agent('t1', 's1', '/abra', 'main', 'uno'), agent('t3', 's2', '/otro', 'main', 'tres')];
out = await draw(v);
const last = JSON.parse(store.epics).s1.number;
assert.deepEqual(list(out), ['sp-s1', `epic-s1-o/r#${last}`, 'sp-s2', 'sp-s3'], 'sin épica ahora: la última vista de ese espacio, no se esconde');
b = row(out, `epic-s1-o/r#${last}`);
assert.deepEqual(colors(b), ['DIM', 'DIM', 'DIM', 'DIM'], 'la última vista va toda en gris');
assert.match(b.$tip, /última vista/, 'y el tooltip lo dice');

// bk falla: no sigue la épica anterior del chat como si fuera actual; las últimas vistas, en gris
AG = [agent('t1', 's1', '/abra', 'claude/11-a', 'uno')];
out = await draw(v);
assert.deepEqual(colors(row(out, 'epic-s1-o/r#10')).slice(0, 1), ['ACC'], 'antes de fallar: la #10, actual');
AG = [agent('t1', 's1', '/abra', 'claude/14-c', 'uno')];
reply = () => ({ code: 1, stdout: '' });
b = row(await draw(v), 'epic-s1-o/r#10');
assert.deepEqual(colors(b), ['DIM', 'DIM', 'DIM', 'DIM'], 'si bk _epica falla, la última vista en gris');

// Reinicio: vuelven las últimas vistas guardadas
reply = () => ({ code: 0, stdout: '[]' });
AG = [];
v = new Agents(); v.init({}, cx); await settle();
assert.deepEqual(list(await draw(v)), ['sp-s1', 'epic-s1-o/r#10', 'sp-s2', 'sp-s3'], 'después de reiniciar, la última vista de cada espacio');
assert.equal(epicCalls().filter((e) => e[3] === '[]').length, 0, 'sin chats no llama a bk');

// El riel (angosto): solo los espacios
narrowNow = true;
assert.equal(walk(await draw(v)).filter((x) => /^epic-/.test(x.$id ?? '')).length, 0, 'en el riel no hay épicas');
JS

echo "1..$N"
[ "$FAILED" -eq 0 ]
