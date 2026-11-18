#!/usr/bin/env bash
# La franja de arriba de bk-lavanda (herdr/mods/pestanas): el contexto del chat enfocado. Corre en node con un herdr
# falso: qué muestra con y sin issue, quiénes te esperan y que al cambiar de chat
# nunca queda el issue del anterior.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

node --input-type=module - "$ROOT" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const [root] = process.argv.slice(2);
const strip = (s) => s.replace(/^import [\s\S]*?;$/gm, '').replace(/^export (default )?/gm, '');
const kit = strip(fs.readFileSync(`${root}/herdr/mods/pestanas/kit.js`, 'utf8'));
const main = strip(fs.readFileSync(`${root}/herdr/mods/pestanas/main.js`, 'utf8'));
const env = { focus: null, panes: [], terms: [], layout: {}, ran: [], exec: async () => ({ code: 1, stdout: '' }) };
// Un elemento falso: cualquier método devuelve el mismo, para poder llamar a render()
const el = new Proxy(function () {}, { get: (_t, k) => (k === 'then' ? undefined : () => el), apply: () => el });
const store = new Map();
const M = new Function('env', 'el', 'localStorage', `
  const div = () => el, svg = div, image = div, h_flex = div, v_flex = div;
  class View {}
  const focused = () => env.focus, panes = () => env.panes, terminals = () => env.terms, home = () => '/h';
  const exec = (...a) => env.exec(...a), shared = () => null, layout = () => env.layout, agents = () => [], spaces = () => [];
  const run = (...a) => env.ran.push(a), theme = () => ({}), window = () => null, settings = () => ({});
  ${kit}
  ${main}
  return { chatArgs, context, waiting, Pestanas };`)(env, el, { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) });
let n = 0;
const ok = (msg) => console.log(`ok ${++n} - ${msg}`);

// Sin issue: ni épica ni avance, aunque bk _epica diga una (no hay asociación real del chat)
assert.deepEqual(M.context(null, null), { issue: null, epic: null });
assert.deepEqual(M.context({ issue: null }, { issue: null, epic: { repo: 'o/r', number: 9, title: 'E' } }), { issue: null, epic: null });
ok('sin issue: no muestra épica');

// Con issue: el issue y su épica, si es otra
const todo = { issue: 7, title: 'Hacer X', url: 'https://github.com/o/r/issues/7', items: [] };
const c1 = M.context(todo, { issue: 7, epic: { repo: 'o/r', number: 3, title: 'Épica' } });
assert.deepEqual([c1.issue.number, c1.issue.title, c1.epic.number, c1.epic.url], [7, 'Hacer X', 3, 'https://github.com/o/r/issues/3']);
ok('con issue: issue y épica, con su enlace');
assert.equal(M.context(todo, { issue: 7, epic: { repo: 'o/r', number: 7, title: 'Hacer X' } }).epic, null);
ok('si el issue es la épica misma, no se repite');
const items = [{ text: 'a', done: true, section: 'S' }];

// Te esperan: solo blocked, sin el chat enfocado, por número de ventana
const list = [
  { address: 't1', pane: 'p1', status: 'blocked', title: 'Uno', tab_name: 'chat' },
  { address: 't2', pane: 'p2', status: 'working', title: 'Dos' },
  { address: 't3', pane: 'p3', status: 'blocked', title: '', tab_name: 'i3' },
  { address: 't4', pane: 'p4', status: 'blocked', title: 'Cuatro' },
];
const w = M.waiting(list, 't4', new Map([['t1', '12'], ['t3', '3'], ['t4', '1']]));
assert.deepEqual(w.map((a) => [a.address, a.n, a.name]), [['t3', '3', 'i3'], ['t1', '12', 'Uno']]);
ok('te esperan: solo los bloqueados, sin el enfocado, ordenados por número');

// Cambiar de chat: lo del anterior se borra antes de leer, y si bk falla no queda el issue de otro chat
assert.equal(M.chatArgs(null), null);
const bar = new M.Pestanas();
bar.init({}, { timer: { every: () => {} } });
env.terms = [{ address: 'tA', labels: { 'bk.name': '#7' } }, { address: 'tB', labels: {} }];
env.panes = [{ pane: 'pA', branch: 'claude/7-x', title: '' }, { pane: 'pB', branch: 'main', title: '' }];
env.focus = { terminal: 'tA', pane: 'pA', cwd: '/r' };
const asked = [];
env.exec = async (cmd, args) => {
  asked.push(args);
  return args[0] === '_todo' ? { code: 0, stdout: JSON.stringify({ ...todo, items }) } : { code: 0, stdout: JSON.stringify({ issue: 7, epic: null }) };
};
assert.equal(await bar.load(), true);
assert.deepEqual([bar.todo.issue, asked.map((a) => a[0]).sort(), asked[0].slice(1)], [7, ['_epica', '_todo'], ['/r', 'claude/7-x', '#7', 'tA']]);
ok('el chat enfocado: pide bk _todo y bk _epica con su carpeta, rama, nombre y terminal');
asked.length = 0;
assert.equal(await bar.load(), false);
assert.equal(asked.length, 0);
ok('el mismo chat: no vuelve a pedir hasta el próximo tick');
env.focus = { terminal: 'tB', pane: 'pB', cwd: '/r' };
env.exec = async () => ({ code: 1, stdout: '' });
assert.equal(await bar.load(), true);
assert.deepEqual([bar.todo, bar.epica], [null, null]);
ok('otro chat y bk falla: no queda el issue del chat anterior');
env.focus = null;
await bar.load();
assert.deepEqual([bar.key, bar.todo], ['-', null]);
ok('sin terminal enfocada: nada');
console.log(`1..${n}`);
JS
