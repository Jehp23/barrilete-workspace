#!/usr/bin/env bash
# La barra de agentes (herdr/mods/agentes) y los handoffs: el chat que siguió en otro (etiqueta bk.from del
# nuevo, lib/herdr.sh) va debajo de su nuevo, en una línea «antes» plegada. En node, con Herdr falso: dibuja la
# barra con agentes inventados y mira qué filas salen; no abre ventanas.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
node --input-type=module - "$ROOT" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const root = process.argv[2];
const src = fs.readFileSync(`${root}/herdr/mods/agentes/main.js`, 'utf8')
  .replace(/^import [\s\S]*?;$/gm, '').replace('export default class Agents', 'class Agents');

// Un elemento de gpui falso: anota id, textos, hijos, tooltip y clic; el resto de los métodos no hace nada.
const node = () => {
  const n = { $id: null, $kids: [], $click: null };
  const p = new Proxy(n, { get: (o, k) => {
    if (typeof k === 'string' && k.startsWith('$')) return o[k];
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
const ids = (n) => walk(n).map((x) => x.$id).filter((i) => /^(ag|prev|sub)-/.test(i ?? '') && i !== 'ag-list');
const text = (n) => walk(n).flatMap((x) => x.$kids).filter((k) => typeof k === 'string');

let AG = [], TERMS = [], calls = [], shared = {};
const RANK = { blocked: 4, done: 3, working: 2, idle: 1 };
const deps = {
  View: class {}, div: node, svg: node, h_flex: node, v_flex: node,
  agents: () => AG, terminals: () => TERMS, focused: () => null, panes: () => [], spaces: () => [{ id: 's1', name: 'proj', tabs: AG.map((a) => ({ id: a.tab, name: a.tabName, named: true })) }],
  run: (...a) => calls.push(a), theme: () => new Proxy({}, { get: () => '#000000' }), shared: (k) => shared[k], setShared: () => {},
  setAgentOrder: (o) => { shared.order = o; }, openOverlay: () => {}, closeOverlay: () => {}, props: () => ({}), window: () => ({}),
  layout: () => ({}), exec: async () => ({ code: 0, stdout: '{"by_terminal":{}}' }), home: () => '/h',
  ICONS: '', PROSE: '', RANK, al: (c) => c, find: () => null, narrow: () => false, ago: () => '1m',
  ids: (all) => new Map(all.map((t, i) => [t.address, i + 1])), said: (t) => t, picto: () => null,
  mark: (_t, s) => `[${s}]`, keycap: (_t, n) => `#${n}`, iconButton: node, rule: node,
  // La lista de espacios (lista.js) y su diálogo (editar.js) tienen su test (test_espacios.sh): acá, vacíos
  Lista: class { section() { return []; } railSection() { return []; } }, menu: () => {}, Editar: class {},
};
const Agents = new Function(...Object.keys(deps), src + '\nreturn Agents;')(...Object.values(deps));
globalThis.localStorage = { getItem: () => null, setItem: () => {}, removeItem: () => {} };
const cx = { spawn() {}, timer: { every() {} }, notify() {} };

// agentes: [address, status, título, {etiquetas}]
const setup = (rows) => {
  AG = rows.map(([address, status, title, , extra = {}], i) => ({ address, status, title, tab: `tab-${address}`, tabName: title, pane: `p-${address}`, space: 's1', space_name: 'proj', seq: i, ...extra }));
  TERMS = rows.map(([address, , , labels = {}]) => ({ address, state: 'live', labels }));
};
const draw = (v) => v.render(cx);

// El nuevo (t2) siguió del viejo (t1): una fila, con «antes» plegado debajo
setup([['t1', 'idle', 'Release #1095'], ['t2', 'working', 'Release #1095 (sigue)', { 'bk.from': 't1' }], ['t3', 'idle', 'Otro']]);
let v = new Agents(); v.init({}, cx);
let out = draw(v);
assert.deepEqual(ids(out).filter((i) => i.startsWith('ag-') || i.startsWith('prev-t')), ['ag-t2', 'prev-t1', 'ag-t3'], 'el viejo no tiene fila propia: va como «antes» debajo del nuevo');
assert.ok(text(out).includes('antes: Release #1095'), 'la línea «antes» dice el título del viejo');
assert.deepEqual(shared.order, ['t2', 't3'], 'alt+N recorre las filas visibles, sin el viejo');

// Clic en «antes»: se despliega con la fila entera del viejo; otro clic la pliega
walk(out).find((x) => x.$id === 'prev-t1').$click(null, cx);
out = draw(v);
assert.deepEqual(ids(out).filter((i) => i.startsWith('ag-') || i.startsWith('prev-t')), ['ag-t2', 'prev-t1', 'ag-t1', 'ag-t3'], 'desplegado: la fila del viejo, debajo de «antes»');
walk(out).find((x) => x.$id === 'prev-t1').$click(null, cx);
assert.ok(!ids(draw(v)).includes('ag-t1'), 'otro clic lo pliega');

// La cruz cierra la pestaña del viejo (con la confirmación de Herdr si sigue corriendo) y no despliega
calls = [];
walk(draw(v)).find((x) => x.$id === 'prev-x-t1').$click(null, { stop_propagation() {} });
assert.deepEqual(calls, [['tab.close', { id: 'tab-t1' }]], 'la cruz: tab.close de la pestaña del viejo, sin confirmed');

// Plegado igual avisa: si el viejo te espera, «antes» lleva la marca y el nuevo sube a «Te esperan»
setup([['t3', 'working', 'Otro'], ['t1', 'blocked', 'Viejo'], ['t2', 'idle', 'Nuevo', { 'bk.from': 't1' }]]);
v = new Agents(); v.init({}, cx); out = draw(v);
const prevRow = walk(out).find((x) => x.$id === 'prev-t1');
assert.ok(text(prevRow).includes('[blocked]'), 'el viejo te espera: la marca en «antes», aunque esté plegado');
assert.deepEqual(shared.order, ['t2', 't3'], 'el nuevo se ordena por lo más urgente de la cadena (te espera > trabajando)');

// Un viejo listo o quieto no hace ruido en «antes»
setup([['t1', 'done', 'Viejo'], ['t2', 'working', 'Nuevo', { 'bk.from': 't1' }]]);
v = new Agents(); v.init({}, cx);
assert.ok(!text(walk(draw(v)).find((x) => x.$id === 'prev-t1')).some((s) => /^\[/.test(s)), 'viejo listo: «antes» sin marca');

// Cadena: t3 viene de t2, que viene de t1. Una fila; desplegando aparece el «antes» del medio
setup([['t1', 'idle', 'Uno'], ['t2', 'idle', 'Dos', { 'bk.from': 't1' }], ['t3', 'working', 'Tres', { 'bk.from': 't2' }]]);
v = new Agents(); v.init({}, cx); out = draw(v);
assert.deepEqual(ids(out).filter((i) => i.startsWith('ag-') || i.startsWith('prev-t')), ['ag-t3', 'prev-t2'], 'cadena de tres: una fila y un «antes»');
walk(out).find((x) => x.$id === 'prev-t2').$click(null, cx);
assert.deepEqual(ids(draw(v)).filter((i) => i.startsWith('ag-') || i.startsWith('prev-t')), ['ag-t3', 'prev-t2', 'ag-t2', 'prev-t1'], 'desplegado: el del medio con su propio «antes»');

// Lo que no se anida: un viejo fijado, uno que ya no está, una vuelta y dos nuevos del mismo viejo
const lin = (rows) => { setup(rows); const x = new Agents(); x.init({}, cx); const l = x.lineage(AG, new Map(TERMS.map((t) => [t.address, t.labels]))); return [[...l.prev], [...l.hidden]]; };
assert.deepEqual(lin([['t1', 'idle', 'V', {}, { pinned: true }], ['t2', 'idle', 'N', { 'bk.from': 't1' }]]), [[], []], 'un viejo fijado conserva su fila');
assert.deepEqual(lin([['t2', 'idle', 'N', { 'bk.from': 't9' }]]), [[], []], 'bk.from a una terminal que ya no está: nada');
assert.deepEqual(lin([['t1', 'idle', 'A', { 'bk.from': 't2' }], ['t2', 'idle', 'B', { 'bk.from': 't1' }]]), [[['t1', 't2']], ['t2']], 'una vuelta (t1↔t2) se corta: no desaparecen los dos');
assert.deepEqual(lin([['t1', 'idle', 'V'], ['t2', 'idle', 'N', { 'bk.from': 't1' }], ['t3', 'idle', 'M', { 'bk.from': 't1' }]]), [[['t2', 't1']], ['t1']], 'dos nuevos del mismo viejo: lo toma el primero');
assert.deepEqual(lin([['t1', 'idle', 'A', { 'bk.from': 't1' }]]), [[], []], 'bk.from a sí mismo: nada');
console.log('ok - agentes: el chat viejo de un handoff va como «antes» debajo del nuevo (16 casos)');
JS
