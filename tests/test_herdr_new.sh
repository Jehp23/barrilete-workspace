#!/usr/bin/env bash
# alt+n (herdr/mods/hub/new.js): parado en un chat, ofrece su resumen y seguir (abre alt+h); Enter sobre un resumen
# listo corre bk chat --desde. En node, con Herdr falso: no abre ventanas ni corre bk.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
node --input-type=module - "$ROOT" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const src = fs.readFileSync(`${process.argv[2]}/herdr/mods/hub/new.js`, 'utf8')
  .replace(/^import .*;$/gm, '').replace('export default class New', 'class New');
const el = () => new Proxy({}, { get: (_, k) => (...a) => { if (k === 'when' && a[0]) a[1](el()); return el(); } });
class Panel { constructor() { this.query = ''; this.at = 0; this.setup?.(); } close() { calls.push(['close']); } }
let calls = [], focus = null, live = [];
const New = new Function('div', 'h_flex', 'exec', 'run', 'home', 'focused', 'agents', 'Panel', 'rank', 'bk', 'launch', 'goto',
  'cwd', 'tilde', 'lit', 'pill', 'ago', src + '\nreturn New;')(
  el, el, async () => ({ code: 1 }), (...a) => calls.push(['run', ...a]), () => '/h', () => focus, () => live, Panel,
  (items) => items.map((item) => ({ item, hits: [] })), async () => ({}), (...a) => calls.push(['launch', ...a]),
  (...a) => calls.push(['goto', ...a]), () => '/h/proj', (p) => p, el, el, () => '1d');
const keys = (n) => n.rows().filter((r) => !r.head).map((r) => r.key);

// Parado en un chat: la fila del resumen, segunda (después de Chat nuevo); Enter abre alt+h
focus = { terminal: 't9' }; live = [{ address: 't9' }];
let n = new New();
assert.deepEqual(keys(n).slice(0, 2), ['chat', 'resumen'], 'en un chat: «Resumen de este chat y seguir» después de Chat nuevo');
n.rows().find((r) => r.key === 'resumen').go();
assert.deepEqual(calls, [['goto', 'bk-handoff']], 'la fila del resumen abre alt+h (bk-handoff)');

// En una terminal que no es un chat, o sin terminal: no aparece
focus = { terminal: 't1' }; live = [{ address: 't9' }];
assert.ok(!keys(new New()).includes('resumen'), 'en una terminal común: sin la fila del resumen');
focus = null;
assert.ok(!keys(new New()).includes('resumen'), 'sin terminal en foco: sin la fila del resumen');

// Enter sobre un resumen listo: cierra y corre bk chat --desde <sid>
calls = []; n = new New(); n.handoffs = [{ sid: 'abcdef1234', name: '', project: 'kit', age_min: 5, session: '' }];
n.enter(n.rows().find((r) => r.kind === 'handoff'), { notify() {} });
assert.deepEqual(calls, [['close'], ['launch', 'Seguir desde abcdef12', ['chat', '--desde', 'abcdef1234'], '/h/proj']],
  'Enter sobre un resumen: bk chat --desde con su sid');
console.log('ok - alt+n: resumen del chat y seguir desde un resumen (5 casos)');
JS
