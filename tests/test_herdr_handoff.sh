#!/usr/bin/env bash
# alt+h (herdr/mods/hub/handoff.js): además de pedir el resumen, elegir el umbral de contexto (bk context). En node,
# con Herdr y bk falsos: no abre ventanas ni escribe ~/.config.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
node --input-type=module - "$ROOT" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const src = fs.readFileSync(`${process.argv[2]}/herdr/mods/hub/handoff.js`, 'utf8')
  .replace(/^import .*;$/gm, '').replace('export default class Handoff', 'class Handoff');
const el = () => new Proxy({}, { get: (_, k) => (...a) => { if (k === 'when' && a[0]) a[1](el()); return el(); } });
class Panel {
  constructor() { this.query = ''; this.at = 0; this.setup?.(); }
  close() { calls.push(['close']); }
  async work(cx, label, fn) { try { await fn(cx); this.error = null; } catch (e) { this.error = String(e?.message ?? e); } }
}
let calls = [], focus = null, live = [], hprops = {}, ctx = { limit: 200000, warn: 150000, default: 200000, custom: false }, setCode = 0;
const bk = async (args, opts = {}) => {
  calls.push(['bk', ...args]);
  if (args[0] === '_hub') return { items: [] };
  if (args[0] === 'context' && args[1] === '--json') return ctx;
  if (args[0] === 'context') return setCode ? { code: 1, stdout: '', stderr: 'no es un umbral' } : { code: 0, stdout: `umbral de contexto: ${args[1]}`, stderr: '' };
  return { code: 0, stdout: '', stderr: '' };
};
const Handoff = new Function('div', 'h_flex', 'v_flex', 'focused', 'agents', 'notify', 'props', 'Panel', 'rank', 'bk', 'launch',
  'lastLine', 'ago', 'pill', src + '\nreturn Handoff;')(
  el, el, el, () => focus, () => live, (...a) => calls.push(['notify', ...a]), () => hprops, Panel,
  (items) => items.map((item) => ({ item, hits: [] })), bk, (...a) => calls.push(['launch', ...a]),
  (s) => (s ?? '').trim().split('\n').pop(), () => '1d', el);
const limits = (h) => h.rows().filter((r) => r.kind === 'limit');

// Fuera de un chat también se puede elegir el umbral; el por defecto (200k) marcado «en uso»
let h = new Handoff(); await h.load();
assert.deepEqual(limits(h).map((r) => r.n), [150000, 200000, 300000, 400000, 500000], 'opciones fijas del umbral');
assert.deepEqual(limits(h).filter((r) => r.on).map((r) => [r.title, r.note]), [['Umbral: 200k (por defecto)', 'en uso']], '200k en uso y marcado como el por defecto');
assert.equal(limits(h).find((r) => r.n === 300000).note, 'aviso desde 225k', 'cada opción dice desde cuándo avisa (3/4)');
assert.ok(h.rows().some((r) => r.head === 'Con cuánto contexto seguir en un chat nuevo'), 'la sección tiene su título');

// Enter sobre 300k: corre bk context 300000 y queda en uso
calls = [];
await h.enter(limits(h).find((r) => r.n === 300000), { notify() {} });
assert.deepEqual(calls.filter((c) => c[0] === 'bk'), [['bk', 'context', '300000']], 'Enter: bk context <n>');
assert.deepEqual(limits(h).filter((r) => r.on).map((r) => r.n), [300000], 'después de Enter, 300k en uso');
assert.equal(h.error, null, 'sin error');

// Si bk context falla: el error se muestra y el umbral en uso no cambia
setCode = 1; calls = [];
await h.enter(limits(h).find((r) => r.n === 500000), { notify() {} });
assert.match(h.error ?? '', /no es un umbral/, 'bk context que falla: el error en el panel');
assert.deepEqual(limits(h).filter((r) => r.on).map((r) => r.n), [300000], 'y el umbral en uso sigue igual');
setCode = 0;

// Un umbral elegido a mano (bk context 250k) aparece entre las opciones, en uso
ctx = { limit: 250000, warn: 187500, default: 200000, custom: true };
h = new Handoff(); await h.load();
assert.deepEqual(limits(h).map((r) => [r.n, r.on]), [[150000, false], [200000, false], [250000, true], [300000, false], [400000, false], [500000, false]], 'el umbral propio entra ordenado y en uso');

// Sin bk context (un bk viejo): sin la sección, y el resto del panel anda
ctx = null;
const old = bk; h = new Handoff(); await h.load();
assert.equal(limits(h).length, 0, 'sin bk context: sin opciones de umbral');

// Parado en un chat: las filas de pedir el resumen siguen primero
ctx = { limit: 200000, warn: 150000, default: 200000, custom: false };
focus = { terminal: 't9' }; live = [{ address: 't9', space_name: 'p', tab_name: 'x' }];
h = new Handoff(); await h.load();
assert.deepEqual(h.rows().filter((r) => !r.head).slice(0, 2).map((r) => r.key), ['seguir', 'cerrar'], 'en un chat, primero pedir el resumen');
assert.equal(h.at, 0, 'abierto con alt+h: el cursor en la primera fila');

// Desde la paleta (props section: limit): el cursor en el umbral en uso, aunque esté en un chat
hprops = { section: 'limit' };
h = new Handoff(); await h.load();
assert.deepEqual([h.rows().filter((r) => !r.head)[h.at].kind, h.rows().filter((r) => !r.head)[h.at].on], ['limit', true], 'desde la paleta: parado en el umbral en uso');
ctx = { limit: 400000, warn: 300000, default: 200000, custom: true }; focus = null;
h = new Handoff(); await h.load();
assert.equal(h.rows().filter((r) => !r.head)[h.at].n, 400000, 'desde la paleta, fuera de un chat: en el umbral en uso (400k)');
console.log('ok - alt+h: el umbral de contexto (14 casos)');

// alt+k: la entrada «Umbral de contexto» abre alt+h con section: limit y la forma de su popup (views.json)
const psrc = fs.readFileSync(`${process.argv[2]}/herdr/mods/hub/palette.js`, 'utf8')
  .replace(/^import .*;$/gm, '').replace(/export default class[\s\S]*$/, '');
const gotos = [];
const NATIVE = new Function('div', 'h_flex', 'run', 'openOverlay', 'focused', 'notify', 'Panel', 'rank', 'bk', 'bin', 'launch',
  'goto', 'termPopup', 'chips', 'keyOf', 'lit', 'cwd', 'lastLine', psrc + '\nreturn NATIVE;')(
  el, el, () => {}, () => {}, () => null, () => {}, class {}, () => [], async () => ({}), () => 'bk', () => {},
  (...a) => gotos.push(a), () => {}, () => {}, () => {}, el, () => '/h', (s) => s);
const entry = NATIVE.find((e) => e[0] === 'context');
assert.ok(entry, 'la paleta tiene la entrada context');
assert.equal(entry[4], 'mod.open:bk-handoff', 'muestra la tecla de alt+h');
entry[6]({ close() {} });
const views = JSON.parse(fs.readFileSync(`${process.argv[2]}/herdr/mods/hub/views.json`, 'utf8'));
assert.deepEqual(gotos, [['bk-handoff', { props: { section: 'limit' }, overlay: views.handoff.overlay }]], 'abre alt+h en el umbral, con la forma de su popup');
console.log('ok - alt+k: la entrada del umbral (3 casos)');
JS
