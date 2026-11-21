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
const env = { focus: null, panes: [], terms: [], layout: {}, ran: [], keys: [], clicks: {}, tips: {}, exec: async () => ({ code: 1, stdout: '' }) };
// Un elemento falso: cualquier método devuelve el mismo, para poder llamar a render()
// Anota el clic de cada elemento con id (env.clicks[id]), para poder apretarlo
const el = new Proxy(function () {}, { get: (_t, k) => (k === 'then' ? undefined : (...a) => {
  if (k === 'id') env.lastId = a[0];
  if (k === 'on_click') env.clicks[env.lastId] = a[0];
  if (k === 'tooltip') env.tips[env.lastId] = a[0];
  return el;
}), apply: () => el });
const store = new Map();
const M = new Function('env', 'el', 'localStorage', `
  const div = () => el, svg = div, image = div, h_flex = div, v_flex = div;
  class View {}
  const focused = () => env.focus, panes = () => env.panes, terminals = () => env.terms, home = () => '/h';
  const exec = (...a) => env.exec(...a), shared = () => null, layout = () => env.layout, agents = () => [], spaces = () => [];
  const run = (...a) => env.ran.push(a), theme = () => ({}), window = () => null, settings = () => ({}), keys = () => env.keys;
  ${kit}
  ${main}
  return { chatArgs, context, waiting, Pestanas, helperAlive, helperStatus, keyOfMod, helperTip, AYUDA, AYUDA_MOD, NOMBRE };`)(env, el, { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) });
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

// El botón «Ayudante»: abre (o esconde) el popup del ayudante del workspace, el mismo mod que alt+y
const bkSrc = fs.readFileSync(`${root}/herdr/mods/bk/main.js`, 'utf8');
assert.equal(bkSrc.match(/^const AYUDA = "([^"]+)";/m)?.[1], M.AYUDA);
const realKeys = Object.entries(JSON.parse(fs.readFileSync(`${root}/herdr/keys.json`, 'utf8')).global).map(([keys, action]) => ({ section: 'global', keys, action }));
assert.equal(realKeys.filter((b) => b.action === `mod.open:${M.AYUDA_MOD}`).length, 1);
assert.ok(bkSrc.includes(`if (c === "${M.AYUDA_MOD.slice(3)}") return this.ayuda();`));
ok('ayudante: la franja busca la terminal con la misma etiqueta que le pone mods/bk, y su mod tiene tecla y acción');
assert.deepEqual([M.helperAlive([]), M.helperAlive([{ state: 'live', labels: { 'bk.kind': 'term' } }]),
  M.helperAlive([{ state: 'exited', labels: { 'bk.kind': M.AYUDA } }]), M.helperAlive([{ state: 'live', labels: { 'bk.kind': M.AYUDA } }])],
  [false, false, false, true]);
ok('ayudante: encendido solo con su terminal viva (no con otra terminal ni con una que ya salió)');
assert.deepEqual([M.keyOfMod(M.AYUDA_MOD, realKeys), M.keyOfMod(M.AYUDA_MOD, []), M.keyOfMod('bk-go1', [{ section: 'global', keys: 'cmd-shift-1', action: 'mod.open:bk-go1' }])],
  ['⌥Y', '', '⌘⇧1']);
assert.match(M.helperTip(false, '⌥Y'), new RegExp(`^${M.NOMBRE}, el ayudante del workspace: .* · ⌥Y$`));
assert.equal(M.helperTip(true, ''), `${M.NOMBRE} (Codex): volver a su conversación`);
assert.equal(M.helperTip(true, '⌥Y', 'blocked'), `${M.NOMBRE} (Codex): volver a su conversación · te espera · ⌥Y`);
ok('ayudante: el botón dice su nombre, su tecla (la de keys.json) y, con la sesión abierta, que vuelve a su conversación y cómo está');
const helperT = (status, extra = {}) => [{ address: 't9', state: 'live', status, labels: { 'bk.kind': M.AYUDA }, ...extra }];
assert.deepEqual([M.helperStatus([]), M.helperStatus(helperT('idle')), M.helperStatus(helperT('working')), M.helperStatus(helperT('blocked')),
  M.helperStatus(helperT('done')), M.helperStatus(helperT('blocked', { labels: { 'bk.kind': 'chat' } })), M.helperStatus(helperT('blocked', { state: 'exited' }))],
  [null, null, 'working', 'blocked', 'done', null, null]);
ok('ayudante: el botón toma el estado de su terminal viva (trabaja, te espera, terminó), no el de otro chat');
env.keys = realKeys; env.ran = []; env.clicks = {}; env.tips = {};
bar.render({ spawn() {} });
assert.equal(typeof env.clicks.ayudante, 'function', 'la franja dibuja el botón');
env.clicks.ayudante();
assert.deepEqual([env.ran, env.tips.ayudante], [[['mod.open', { name: 'bk-ayuda' }]], M.helperTip(false, '⌥Y')]);
assert.ok(fs.existsSync(`${root}/herdr/mods/ayudante/piola.svg`) && main.includes('svg("mods/bk-ayudante/piola.svg")'));
ok('ayudante: la franja dibuja el botón con su icono y el clic abre bk-ayuda');

// La cabecera del popup de Piola (herdr/mods/ayudante → bk-ayudante): quién es, cómo está y cómo se esconde
const cab = { terms: [], keys: realKeys, ran: [], clicks: {}, texts: [], lastId: null, props: { terminal: 't9' } };
const cel = new Proxy(function () {}, { get: (_t, k) => (k === 'then' ? undefined : (...a) => {
  if (k === 'id') cab.lastId = a[0];
  if (k === 'on_click') cab.clicks[cab.lastId] = a[0];
  if (k === 'child' && typeof a[0] === 'string') cab.texts.push(a[0]);
  if (k === 'when' && a[0]) a[1](cel);
  return cel;
}), apply: () => cel });
const C = new Function('cab', 'el', `
  const div = () => el, svg = div, h_flex = div, v_flex = div;
  class View {}
  const terminals = () => cab.terms, keys = () => cab.keys, run = (...a) => cab.ran.push(a), props = () => cab.props, theme = () => ({});
  ${strip(fs.readFileSync(`${root}/herdr/mods/ayudante/main.js`, 'utf8'))}
  return { Ayudante, NOMBRE, LEMA, WORD, estado };`)(cab, cel);
const brief = fs.readFileSync(`${root}/lib/ayudante.md`, 'utf8');
const bkSh = fs.readFileSync(`${root}/bin/bk`, 'utf8');
assert.deepEqual([C.NOMBRE, JSON.parse(fs.readFileSync(`${root}/herdr/mods/ayudante/mod.json`, 'utf8')).title, brief.startsWith(`Sos ${C.NOMBRE}, `),
  bkSh.includes(`AYUDA_SALUDO="Hola, ${C.NOMBRE}."`)], [M.NOMBRE, M.NOMBRE, true, true]);
ok(`ayudante: se llama igual (${C.NOMBRE}) en el botón, en la cabecera, en su encargo y en el saludo`);
assert.deepEqual([C.estado('t9', helperT('working')), C.estado('t9', helperT('blocked', { state: 'exited' })), C.estado('t1', helperT('working')), C.estado('t9', [])],
  ['working', '', '', '']);
const draw = (terms) => { cab.terms = terms; cab.texts = []; cab.clicks = {}; new C.Ayudante().render(); return cab.texts; };
const quiet = draw(helperT('idle'));
assert.ok(quiet.includes(C.NOMBRE) && quiet.includes(C.LEMA) && quiet.includes('⌥Y') && quiet.includes('esconder'));
assert.deepEqual(Object.values(C.WORD).filter((w) => quiet.includes(w)), []);
assert.deepEqual([draw(helperT('blocked')).includes('te espera'), draw(helperT('working')).includes('trabajando'), draw(helperT('done')).includes('terminó')], [true, true, true]);
ok('cabecera: nombre, lema y tecla de esconder; el estado solo cuando trabaja, te espera o terminó');
cab.clicks['ay-hide']();
assert.deepEqual(cab.ran, [['mod.open', { name: 'bk-ayuda' }]]);
ok('cabecera: «esconder» pasa por el mismo mod que alt+y (así el popup y su estado quedan en orden)');
console.log(`1..${n}`);
JS
