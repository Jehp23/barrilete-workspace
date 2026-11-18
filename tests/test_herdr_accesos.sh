#!/usr/bin/env bash
# Los accesos directos de la cabecera de la barra izquierda (herdr/mods/marca/accesos.js y main.js). Corre en node
# con un herdr falso: qué entiende de lo que pegás, el nombre y la cara de cada uno, que agregar no repite, que
# abrir usa `open`, y cuántos entran en la cabecera.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

node --input-type=module - "$ROOT" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const [root] = process.argv.slice(2);
const strip = (s) => s.replace(/^import [\s\S]*?;$/gm, '').replace(/^export (default )?/gm, '');
const kit = strip(fs.readFileSync(`${root}/herdr/mods/marca/kit.js`, 'utf8'));
const acc = strip(fs.readFileSync(`${root}/herdr/mods/marca/accesos.js`, 'utf8'));
const main = strip(fs.readFileSync(`${root}/herdr/mods/marca/main.js`, 'utf8'));
const env = { files: {}, shared: {}, ran: [], notes: [], dirs: new Set(), opened: [], width: 288, props: {} };
// Un elemento falso que anota los id: cualquier método devuelve el mismo, para poder dibujar
const ids = [];
const el = new Proxy(function () {}, { get: (_t, k) => (k === 'then' ? undefined : k === 'id' ? (x) => { ids.push(x); return el; } : () => el), apply: () => el });
const M = new Function('env', 'el', `
  const div = () => el, svg = div, image = div, h_flex = div, v_flex = div, Input = { new: div };
  const InputState = { new: () => ({ on() {}, focus() {}, value: () => '', set_value() {} }) };
  class View {}
  const home = () => '/Users/yo', appHome = () => '/app', layout = () => ({ id: 'root', children: [{ id: 'sidebar', size: { px: env.width } }] });
  const terminals = () => [], agents = () => [], updates = () => null, theme = () => ({}), window = () => ({ platform: 'macos' });
  const props = () => env.props, shared = (k) => env.shared[k] ?? null, setShared = (k, v) => { env.shared[k] = v; };
  const run = (...a) => env.ran.push(a), openOverlay = (o) => env.ran.push(['overlay', o]), closeOverlay = () => {};
  const notify = (n) => env.notes.push(n), pickFolder = async () => null;
  const readTextFile = async (p) => env.files[p] ?? null;
  const writeTextFile = async (p, text, expected) => {
    if ((env.files[p] ?? null) !== expected) throw new Error('stale');
    env.files[p] = text; return null;
  };
  const exec = async (cmd, args) => {
    if (cmd === 'test') return { code: env.dirs.has(args[1]) ? 0 : 1, stdout: '' };
    if (cmd === 'open') { env.opened.push(args[0]); return args[0].includes('no-existe') ? { code: 1, stdout: '', stderr: 'does not exist' } : { code: 0, stdout: '' }; }
    return { code: 1, stdout: '' };
  };
  ${kit}
  ${acc}
  ${main}
  return { normalize, nameOf, iconOf, parse, add, remove, openTarget, change, KEY, Marca };`)(env, el);
let n = 0;
const ok = (msg) => console.log(`ok ${++n} - ${msg}`);

// Lo que pegás → lo que se abre
const cases = {
  'https://github.com/o/r': 'https://github.com/o/r',
  '  github.com/o/r ': 'https://github.com/o/r',
  'www.google.com': 'https://www.google.com',
  'localhost:3000/x': 'http://localhost:3000/x',
  'obsidian://open?vault=V': 'obsidian://open?vault=V',
  'mailto:a@b.com': 'mailto:a@b.com',
  '~/Documents': '/Users/yo/Documents',
  '~': '/Users/yo',
  '"/Applications/Safari.app/"': '/Applications/Safari.app',
  "'/tmp/con espacio.pdf'": '/tmp/con espacio.pdf',
  'file:///Users/yo/a%20b.txt': '/Users/yo/a b.txt',
  '/': '/',
};
for (const [raw, want] of Object.entries(cases)) assert.equal(M.normalize(raw), want, raw);
for (const raw of ['', '   ', 'hola', 'dos palabras', 'Documents/x', 'a\nb', 'file://%E0%A4%A']) assert.equal(M.normalize(raw), null, JSON.stringify(raw));
ok('normalize: URLs con y sin esquema, ~, comillas y file://; texto suelto no');

// Una entrada hostil no se cuelga (la regex de dominios no es cuadrática)
const t0 = Date.now();
M.normalize('a.'.repeat(20000) + '!');
M.normalize('a-'.repeat(20000) + '.c!');
assert.ok(Date.now() - t0 < 500, `normalize tardó ${Date.now() - t0} ms`);
ok('normalize: una entrada larga y rara no se cuelga');

assert.deepEqual(['https://www.github.com/x', 'http://localhost:3000', 'mailto:a@b.com', 'obsidian://open', '/Applications/Safari.app', '/Users/yo/Documents/', '/'].map(M.nameOf),
  ['github.com', 'localhost', 'a@b.com', 'obsidian', 'Safari', 'Documents', '/']);
assert.equal(M.iconOf('web'), null);
assert.match(M.iconOf('folder'), /folder\.svg$/);
assert.match(M.iconOf('app'), /bk-marca\/app\.svg$/);
assert.ok(fs.existsSync(`${root}/herdr/mods/marca/app.svg`));
ok('nombre e icono: el sitio sin www, la app sin .app, la carpeta por su nombre');

assert.deepEqual(M.parse('no es json'), []);
assert.deepEqual(M.parse('{"target":"x"}'), []);
assert.deepEqual(M.parse('[{"target":"x"},{"name":"sin target"},null]'), [{ target: 'x' }]);
ok('parse: un archivo roto o con basura no rompe la cabecera');

// Agregar: el tipo sale de mirar el disco, no repite y comparte la lista
env.dirs.add('/Users/yo/Documents');
await M.add(['https://github.com', '/Users/yo/Documents', '/Applications/Safari.app', '/Users/yo/a.pdf', 'obsidian://open']);
await M.add(['https://github.com', '/Users/yo/Documents']);
let list = JSON.parse(env.files['/app/bk-accesos.json']);
assert.deepEqual(list.map((x) => [x.name, x.kind]), [['github.com', 'web'], ['Documents', 'folder'], ['Safari', 'app'], ['a.pdf', 'file'], ['obsidian', 'link']]);
assert.deepEqual(env.shared[M.KEY], list);
ok('add: guarda en bk-accesos.json con su tipo, sin repetir, y avisa a las otras copias');

// Otra copia escribió en el medio: se vuelve a leer y no se pierde lo suyo
const real = env.files['/app/bk-accesos.json'];
let once = true;
const before = M.change;
await M.change((l) => { if (once) { once = false; env.files['/app/bk-accesos.json'] = JSON.stringify([...JSON.parse(real), { target: '/otro', name: 'otro', kind: 'file' }]); } return [...l, { target: '/mio', name: 'mio', kind: 'file' }]; });
list = JSON.parse(env.files['/app/bk-accesos.json']);
assert.deepEqual(list.slice(-2).map((x) => x.target), ['/otro', '/mio']);
ok('change: si otra copia escribió en el medio, se suma a lo suyo');

await M.remove('/otro'); await M.remove('/mio');
assert.equal(JSON.parse(env.files['/app/bk-accesos.json']).length, 5);
ok('remove: saca solo ese');

await M.openTarget('/Users/yo/Documents');
await M.openTarget('/no-existe');
assert.deepEqual(env.opened, ['/Users/yo/Documents', '/no-existe']);
assert.equal(env.notes.length, 1);
assert.match(env.notes[0].body, /no-existe/);
ok('abrir: usa open; si falla, avisa');

// Cuántos entran en la cabecera
const view = new M.Marca();
view.hovered = false;
const draw = (width) => { env.width = width; ids.length = 0; view.render(); return ids.filter((x) => /^acc-/.test(x)); };
assert.deepEqual(draw(288), ['acc-0', 'acc-more']);
assert.deepEqual(draw(400), ['acc-0', 'acc-1', 'acc-2', 'acc-3', 'acc-4']);
view.hovered = true;
assert.deepEqual(draw(400), ['acc-add', 'acc-0', 'acc-1', 'acc-2', 'acc-3', 'acc-4']);
assert.deepEqual(draw(170), []);
env.shared[M.KEY] = [];
view.hovered = false;
assert.deepEqual(draw(288), ['acc-add']);
ok('cabecera: los que entran y un +N; el + al pasar por encima (sin correr a los demás) o si no hay ninguno');
JS
