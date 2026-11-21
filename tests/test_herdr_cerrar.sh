#!/usr/bin/env bash
# Cerrar un chat con su cadena de «antes» (herdr/mods/cerrar → bk-cerrar): la cadena de bk.from, el popup con todos
# marcados y quién lo abre (el «Cerrar…» del clic derecho, herdr/mods/menu, y ctrl+x de Sesiones,
# herdr/mods/hub/sessions.js). En node, con Herdr y GPUI falsos: anota qué comandos correría, no cierra nada.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v node >/dev/null || { echo "1..0 # skip: sin node"; exit 0; }
node --input-type=module - "$ROOT" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const root = process.argv[2];
let n = 0;
const ok = (m) => console.log(`ok ${++n} - ${m}`);
const load = (path, cls, names, ret) => {
  const src = fs.readFileSync(`${root}/${path}`, 'utf8').replace(/^import [\s\S]*?;$/gm, '')
    .replace(`export default class ${cls}`, `class ${cls}`).replace(/^export /gm, '');
  return (deps) => new Function(...names, `${src}\nreturn ${ret};`)(...names.map((k) => deps[k]));
};

// Un elemento de gpui falso: anota id, textos, hijos y clic; el resto de los métodos no hace nada
const node = () => {
  const o = { $id: null, $kids: [], $click: null, $key: null };
  const p = new Proxy(o, { get: (x, k) => {
    if (typeof k === 'string' && k.startsWith('$')) return x[k];
    return (...a) => {
      if (k === 'id') x.$id = a[0];
      else if (k === 'child') x.$kids.push(a[0]);
      else if (k === 'children') x.$kids.push(...a[0]);
      else if (k === 'when' && a[0]) a[1](p);
      else if (k === 'on_click') x.$click = a[0];
      else if (k === 'on_key_down') x.$key = a[0];
      return p;
    };
  } });
  return p;
};
const walk = (x, out = []) => { if (x && x.$kids) { out.push(x); for (const k of x.$kids) walk(k, out); } return out; };
const text = (x) => walk(x).flatMap((y) => y.$kids).filter((k) => typeof k === 'string');
const byId = (x, id) => walk(x).find((y) => y.$id === id);

// Herdr falso: terminales con etiquetas, panes, agentes; anota run, exec, overlays y avisos
let TERMS = [], PANES = [], AGENTS = [], PROPS = {}, calls = [], execs = [], overlays = [], closed = [], notes = [];
const term = (address, labels = {}, extra = {}) => ({ address, state: 'live', labels, ...extra });
const herdr = {
  View: class {}, div: node, svg: node, v_flex: node, h_flex: node,
  agents: () => AGENTS, terminals: () => TERMS, panes: () => PANES, spaces: () => [{ id: 's1', tabs: [{ id: 'c1', name: 'Uno', named: true }] }],
  run: (...a) => calls.push(a), exec: async (...a) => { execs.push(a); return { code: 0, stdout: JSON.stringify({ open: [{ terminal: 't2', title: 'Dos de bk', age_min: 90 }] }) }; },
  props: () => PROPS, closeOverlay: (id) => closed.push(id), openOverlay: (o) => overlays.push(o), theme: () => new Proxy({}, { get: () => '#000000' }),
  notify: (x) => notes.push(x), shared: () => null,
  ICONS: '', PROSE: '', WORD: { blocked: 'te espera', done: 'listo', working: 'trabajando', idle: 'quieto' },
  ago: (ms) => `${ms / 60000}min`, ids: () => new Map([['t3', '3']]), said: (x) => x ?? '', mark: (_t, s) => `[${s}]`, keycap: (_t, k) => `#${k ?? '·'}`,
};
const C = load('herdr/mods/cerrar/main.js', 'Cerrar', Object.keys(herdr), '{ Cerrar, chain, shut, SIZE }')(herdr);
const reset = () => { calls = []; execs = []; overlays = []; closed = []; notes = []; };

// ---------- la cadena ----------
// t3 siguió de t2, que siguió de t1. t9 no tiene «antes».
const base = () => [term('t1'), term('t2', { 'bk.from': 't1' }), term('t3', { 'bk.from': 't2' }), term('t9')];
assert.deepEqual(C.chain('t3', base()), ['t3', 't2', 't1'], 'la cadena entera, del que cerrás hacia atrás');
assert.deepEqual(C.chain('t2', base()), ['t2', 't1'], 'desde el del medio: solo sus de antes');
assert.deepEqual(C.chain('t9', base()), ['t9'], 'sin «antes»: solo él');
assert.deepEqual(C.chain('t3', [term('t1', {}, { state: 'dead' }), term('t2', { 'bk.from': 't1' }), term('t3', { 'bk.from': 't2' })]), ['t3', 't2'], 'una terminal muerta corta la cadena');
assert.deepEqual(C.chain('t3', [term('t1', { 'herdr.pinned': 'true' }), term('t2', { 'bk.from': 't1' }), term('t3', { 'bk.from': 't2' })]), ['t3', 't2'], 'un viejo fijado conserva su fila: no entra (como lineage)');
assert.deepEqual(C.chain('t2', [term('t1', { 'bk.from': 't2' }), term('t2', { 'bk.from': 't1' })]), ['t2', 't1'], 'una vuelta se corta');
assert.deepEqual(C.chain('t1', [term('t1', { 'bk.from': 't1' })]), ['t1'], 'bk.from a sí mismo: nada');
assert.deepEqual(C.chain('t5', base()), [], 'una terminal que ya no está: nada que cerrar');
ok('cadena: sigue bk.from hacia atrás por terminales vivas; corta en fijados, muertas y vueltas');

// ---------- cómo cierra cada una ----------
TERMS = [term('t1'), term('t2'), term('t3'), term('t4', { 'bk.kind': 'agent', 'bk.win': 'w7' })];
PANES = [{ pane: 'p1', tab: 'c1', terminal: 't1' }, { pane: 'p2', tab: 'c2', terminal: 't2' }, { pane: 'p2b', tab: 'c2', terminal: 'tx' }];
reset(); for (const a of ['t1', 't2', 't3', 't4']) C.shut(a);
assert.deepEqual(calls, [['tab.close', { id: 'c1', confirmed: true }], ['pane.close', { pane: 'p2' }], ['terminal.kill', { terminal: 't3' }]]);
assert.deepEqual(execs.map((e) => e.slice(0, 2)), [['bk', ['stop', 'w7']]], 'un agente del kit: bk stop');
ok('cerrar: la pestaña si es su único pane, si no el pane, sin pane la terminal, un agente con bk stop (como Sesiones)');

// ---------- el popup ----------
TERMS = base(); PANES = ['t1', 't2', 't3'].map((a, i) => ({ pane: `p${i}`, tab: `c${i}`, terminal: a }));
AGENTS = [{ address: 't3', status: 'working', title: 'Tres' }, { address: 't2', status: 'blocked', title: '' }, { address: 't1', status: 'idle', title: 'Uno' }];
const cx = { focus_handle: () => ({ focus() {} }), spawn: (f) => f({ notify() {} }), notify() {} };
const open = async (t) => { PROPS = { terminal: t, overlay: 'ov1' }; reset(); const v = new C.Cerrar(); v.init({}, cx); await Promise.resolve(); await Promise.resolve(); return v; };
let v = await open('t3');
let out = v.render();
assert.deepEqual(walk(out).map((x) => x.$id).filter((i) => /^cc-t/.test(i ?? '')), ['cc-t3', 'cc-t2', 'cc-t1'], 'lista la cadena entera');
assert.deepEqual(v.marked(), ['t3', 't2', 't1'], 'todos marcados');
const s = text(out);
assert.ok(s.includes('Dos de bk') && s.includes('antes · te espera · 90min'), `título de bk, estado y cuándo: ${s.join(' | ')}`);
assert.ok(s.includes('este chat · trabajando') && s.includes('Cerrar todos (3)') && s.includes('Cerrar (3) ↵'), s.join(' | '));
ok('popup: la cadena con título, cuándo y estado, todos marcados');

const key = (k, mod = {}) => out.$key({ key: k, modifiers: mod }, { notify() {} });
key('enter');
assert.deepEqual(calls.map((c) => c[1].id), ['c2', 'c1', 'c0'], 'Enter cierra los tres, del que cerrás hacia atrás');
assert.deepEqual(closed, ['ov1'], 'y se cierra el popup');
ok('popup: Enter cierra los marcados');

v = await open('t3'); out = v.render();
key('down'); key('space'); out = v.render();
assert.deepEqual(v.marked(), ['t3', 't1'], 'espacio desmarca el elegido');
assert.ok(text(out).includes('Cerrar marcados (2) ↵') && text(out).includes('antes · te espera · 90min · queda abierto'));
byId(out, 'cc-t1').$click(null, { notify() {} });
assert.deepEqual(v.marked(), ['t3'], 'un clic también desmarca');
out = v.render(); key('enter');
assert.deepEqual(calls, [['tab.close', { id: 'c2', confirmed: true }]], 'cierra solo el marcado: los otros quedan');
assert.match(notes[0].body, /quedan abiertos 2/);
ok('popup: desmarcás (espacio o clic) los que guardás y Enter cierra el resto');

v = await open('t3'); key('space'); out = v.render();
byId(out, 'cc-all').$click();
assert.equal(calls.length, 3, '«Cerrar todos» cierra también los desmarcados');
v = await open('t3'); key('space'); key('enter', { control: true });
assert.equal(calls.length, 3, 'ctrl+enter: todos');
v = await open('t3'); key('escape');
assert.deepEqual([calls, closed], [[], ['ov1']], 'Esc no cierra nada');
v = await open('t3'); for (const a of ['t3', 't2', 't1']) v.toggle(a); out = v.render(); key('enter');
assert.deepEqual([calls, closed], [[], []], 'nada marcado: Enter no hace nada');
ok('popup: «Cerrar todos (N)» y ctrl+enter cierran todos; Esc cancela; sin marcados Enter no hace nada');

// ---------- quién lo abre: el clic derecho ----------
const mdeps = { ...herdr, keys: () => [], spaces: () => [] };
const M = load('herdr/mods/menu/main.js', 'Menu', ['View', 'div', 'svg', 'v_flex', 'h_flex', 'run', 'props', 'closeOverlay', 'openOverlay', 'theme', 'keys', 'terminals', 'spaces', 'panes', 'exec'],
  '{ items, before, Menu }')(mdeps);
TERMS = base(); PANES = [{ pane: 'p3', tab: 'c3', terminal: 't3' }, { pane: 'p9', tab: 'c9', terminal: 't9' }];
const last = (t, p) => M.items({ tab: 'pane', target: { pane: p, terminal: t } }).at(-1);
assert.deepEqual(last('t3', 'p3'), ['Cerrar…', 'cadena.close', { terminal: 't3' }, 'x'], 'con «antes»: Cerrar… abre la cadena');
assert.deepEqual(last('t9', 'p9'), ['Cerrar', 'pane.close', { pane: 'p9' }, 'x'], 'sin «antes»: como hoy');
reset(); PROPS = { tab: 'pane', target: { pane: 'p3', terminal: 't3' }, overlay: 'menu1' };
const m = new M.Menu(); m.choose(M.items(PROPS).length - 1);
assert.deepEqual([closed, overlays, calls], [['menu1'], [{ mod: 'bk-cerrar', ...C.SIZE, props: { terminal: 't3' } }], []], 'abre bk-cerrar y no cierra nada solo');
ok('clic derecho: «Cerrar…» abre bk-cerrar si hay «antes»; sin «antes», pane.close como siempre');

// ---------- quién lo abre: ctrl+x de Sesiones ----------
let gotos = [];
const sdeps = { div: node, h_flex: node, terminals: () => TERMS, spaces: () => [], panes: () => PANES, run: (...a) => calls.push(a), notify: (x) => notes.push(x),
  Panel: class {}, rank: null, bk: null, launch: null, chips: null, lit: null, pill: null, dot: null, ago: null, tilde: null, reveal: null, lastLine: null,
  goto: (...a) => gotos.push(a) };
const S = load('herdr/mods/hub/sessions.js', 'Sessions', Object.keys(sdeps), '{ Sessions, before }')(sdeps);
const sx = { timer: { after() {} }, notify() {} };
const sv = new S.Sessions(); sv.closing = new Set(); sv.confirm = null; sv.reload = () => {};
reset();
sv.shut({ term: TERMS.find((x) => x.address === 't3'), title: 'Tres', sid: 's3', s: {} }, sx);
assert.deepEqual([gotos, calls, sv.confirm], [[['bk-cerrar', { props: { terminal: 't3' }, overlay: C.SIZE }]], [], null], 'con «antes»: el primer ctrl+x abre la cadena');
gotos = []; const row9 = { term: TERMS.find((x) => x.address === 't9'), title: 'Nueve', sid: 's9', s: {} };
sv.shut(row9, sx);
assert.deepEqual([gotos, calls, sv.confirm], [[], [], 's9'], 'sin «antes»: el primer ctrl+x pregunta, como hoy');
sv.shut(row9, sx);
assert.deepEqual(calls, [['tab.close', { id: 'c9', confirmed: true }]], 'y el segundo cierra');
ok('Sesiones: ctrl+x con «antes» abre bk-cerrar; sin «antes», dos veces como siempre');

// ---------- las copias dicen lo mismo ----------
const lists = [base(), [term('t1', { 'herdr.pinned': 'true' }), term('t2', { 'bk.from': 't1' })], [term('t1', {}, { state: 'dead' }), term('t2', { 'bk.from': 't1' })],
  [term('t1', { 'bk.from': 't1' })], [term('t1', {}, { pinned: true }), term('t2', { 'bk.from': 't1' })]];
for (const all of lists) for (const x of all) {
  const want = C.chain(x.address, all).length > 1;
  assert.equal(M.before(x, all), want, `menú: ${x.address}`);
  assert.equal(S.before(x, all), want, `Sesiones: ${x.address}`);
}
const fn = (p) => fs.readFileSync(`${root}/${p}`, 'utf8').match(/export const before = [\s\S]*?\n};/)[0];
assert.equal(fn('herdr/mods/menu/main.js'), fn('herdr/mods/hub/sessions.js'), 'before() es el mismo texto en las dos copias');
const size = (p) => JSON.parse(fs.readFileSync(`${root}/${p}`, 'utf8').match(/const CERRAR = (\{[^}]*\})/)[1].replace(/(\w+):/g, '"$1":'));
const modJson = JSON.parse(fs.readFileSync(`${root}/herdr/mods/cerrar/mod.json`, 'utf8')).overlay;
assert.deepEqual([size('herdr/mods/menu/main.js'), size('herdr/mods/hub/sessions.js'), modJson], [C.SIZE, C.SIZE, C.SIZE]);
ok('copias: before() del menú y de Sesiones coincide con chain(), y el tamaño del popup es uno solo');
console.log(`1..${n}`);
JS
