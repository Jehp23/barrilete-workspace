#!/usr/bin/env bash
# Los mods de bk en Herdr que se pueden probar sin abrir Herdr: el mod de las acciones (herdr/mods/bk/main.js) corre
# en node con un herdr falso. Sus avisos: muestra la cola que deja hd_notice (lib/herdr.sh) y la vacía, sobre una
# cola en una carpeta temporal; ls y rm son los de verdad y los avisos los escribe el hd_notice real. Su despacho:
# qué nombres atiende. Y la fila de la lista de agentes.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
Q="$HOME/.cache/bk/herdr-avisos"

# hd_notice de verdad, con un herdr-app que no abre nada (anota que lo llamaron)
WS="$ROOT"; info() { :; }; hd_app() { echo "$*" >>"$TMP/app.log"; }
eval "$(sed -n '/^hd_notice() {$/,/^}$/p' "$ROOT/lib/herdr.sh")"   # (bash 3.2 no lee un . <(…))
declare -F hd_notice >/dev/null || { echo "not ok - no encontré hd_notice en lib/herdr.sh"; exit 1; }
hd_notice "Resumen listo: proj" "Clic para seguir en un chat nuevo" bk-seguir
hd_notice "Chat nuevo" "listo" "" success "$TMP/a.log"
hd_notice "bk run 42" "prepare.sh rechazó #42" "" error "$TMP/b.log"
[ "$(ls "$Q" | wc -l | tr -d ' ')" = 3 ] || { echo "not ok - hd_notice no dejó los tres avisos en la cola"; exit 1; }

node --input-type=module - "$ROOT" "$HOME" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
const [root, home] = process.argv.slice(2);
const Q = `${home}/.cache/bk/herdr-avisos`;
const source = fs.readFileSync(`${root}/herdr/mods/bk/main.js`, 'utf8')
  .replace(/^import .*;$/gm, '').replace('export default class Bk', 'class Bk');
let notes = [], ran = [], onExec = null;
const exec = async (cmd, args) => {
  ran.push([cmd, ...args]);
  assert.ok(['ls', 'rm'].includes(cmd) && args.every((a) => a === '-f' || a.startsWith(Q)), `el mod solo lista y borra en la cola: ${cmd} ${args.join(' ')}`);
  if (onExec) await onExec(cmd, args);
  try {
    return { code: 0, stdout: execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }), stderr: '' };
  } catch (e) {
    return { code: e.status ?? 1, stdout: e.stdout ?? '', stderr: e.stderr ?? '' };
  }
};
const readTextFile = async (p) => (fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : null);
const nope = (name) => () => { throw Error(`aviso no usa ${name}`); };
const Bk = new Function('View', 'div', 'hc', 'exec', 'run', 'props', 'openOverlay', 'closeOverlay', 'focused', 'terminals',
  'spaces', 'agents', 'home', 'notify', 'shared', 'setShared', 'readTextFile', source + '\nreturn Bk;')(
  class {}, () => ({}), nope('hc'), exec, nope('run'), () => ({}), nope('openOverlay'), nope('closeOverlay'), () => null,
  () => [], () => [], () => [], () => home, (n) => notes.push(n), () => null, nope('setShared'), readTextFile);
const bk = new Bk();
const queue = () => fs.readdirSync(Q).sort();
const put = (name, obj) => fs.writeFileSync(`${Q}/${name}`, typeof obj === 'string' ? obj : JSON.stringify(obj));
const now = Math.floor(Date.now() / 1000);
let n = 0;
const ok = (what) => console.log(`ok ${++n} - ${what}`);

// 1-4: los tres avisos de hd_notice, en el orden en que se pidieron
await bk.handle('aviso');
assert.deepEqual(notes.map((x) => x.title), ['Resumen listo: proj', 'Chat nuevo', 'bk run 42']);
ok('muestra todos los avisos de la cola, del más viejo al más nuevo');
assert.deepEqual([notes[0].level, notes[0].timeout, notes[0].action], ['info', 600000, { name: 'mod.open', args: { name: 'bk-seguir' } }]);
ok('el que trae un mod: su clic lo abre y espera diez minutos');
assert.deepEqual(notes.slice(1).map((x) => [x.level, x.body, x.timeout, x.action]),
  [['success', 'listo', 5000, undefined], ['error', 'prepare.sh rechazó #42', 15000, undefined]]);
ok('los de bk _do: con su nivel y su texto, sin clic, y el error queda más tiempo a la vista');
assert.deepEqual(queue(), []);
ok('la cola queda vacía');

// 5: sin nada que mostrar
notes = [];
await bk.handle('aviso');
assert.deepEqual(notes, []);
fs.rmSync(Q, { recursive: true });
await bk.handle('aviso');
assert.deepEqual(notes, []);
ok('con la cola vacía, o sin la carpeta, no avisa nada ni falla');
fs.mkdirSync(Q, { recursive: true });

// 6: los viejos se borran sin mostrarse
put('1000000000-1.json', { title: 'viejo', body: 'de ayer', mod: '', level: 'info', ts: now - 601 });
put('1000000001-1.json', { title: 'justo', body: '', mod: '', level: 'info', ts: now - 590 });
await bk.handle('aviso');
assert.deepEqual([notes.map((x) => x.title), queue()], [['justo'], []]);
ok('un aviso de hace más de diez minutos se borra sin mostrarse; uno de menos, se muestra');

// 7: lo que no es un aviso
notes = [];
put('1-1.json', '{"title": "cortado');
put('2-1.json', '[1, 2]');
put('3-1.json', { body: 'sin título', ts: now });
put('4-1.json', { title: 'raro', level: 'toString', mod: { name: 'x' }, ts: now });
put('5-1.json.tmp', { title: 'a medio escribir', ts: now });
put('notas.txt', 'no es de la cola');
await bk.handle('aviso');
assert.deepEqual(notes, [{ title: 'raro', body: '', level: 'info', timeout: 5000 }]);
ok('un archivo roto, uno sin título y un nivel o un mod que no son tales: no rompen, y el nivel cae en info');
assert.deepEqual(queue(), ['5-1.json.tmp', 'notas.txt']);
ok('borra solo los .json de la cola: el .tmp que hd_notice está escribiendo y lo ajeno quedan');
fs.rmSync(`${Q}/5-1.json.tmp`); fs.rmSync(`${Q}/notas.txt`);

// 9: avisa antes de borrar, de a uno
notes = []; ran = [];
put('1-1.json', { title: 'uno', ts: now }); put('2-1.json', { title: 'dos', ts: now });
const seen = [];
onExec = (cmd, args) => { if (cmd === 'rm') seen.push([args.at(-1).split('/').pop(), notes.map((x) => x.title).join('+'), queue().join('+')]); };
await bk.handle('aviso');
onExec = null;
assert.deepEqual(seen, [['1-1.json', 'uno', '1-1.json+2-1.json'], ['2-1.json', 'uno+dos', '2-1.json']]);
ok('cada aviso se muestra antes de borrar su archivo: si la copia se cierra en el medio, el resto queda en la cola');

// 10: un aviso que llega mientras se muestra la cola no se pierde
notes = [];
put('1-1.json', { title: 'uno', ts: now });
onExec = (cmd) => { if (cmd === 'rm') put('9-1.json', { title: 'tarde', ts: now }); };
await bk.handle('aviso');
onExec = null;
assert.deepEqual([notes.map((x) => x.title), queue()], [['uno'], ['9-1.json']]);
await bk.handle('aviso');
assert.deepEqual([notes.map((x) => x.title), queue()], [['uno', 'tarde'], []]);
ok('uno que llega mientras tanto queda en la cola y sale en la próxima apertura');

// Despacho: este mod se instala con el nombre de cada tecla que no es una vista del hub, más aviso y seguir
// (lib/herdr_install.py). Cada uno de esos nombres tiene su acción; una vista del hub nunca pasa por acá.
const keys = JSON.parse(fs.readFileSync(`${root}/herdr/keys.json`, 'utf8'));
const views = Object.keys(JSON.parse(fs.readFileSync(`${root}/herdr/mods/hub/views.json`, 'utf8')));
const byKey = Object.values(keys).flatMap((b) => Object.values(b))
  .filter((a) => typeof a === 'string' && a.startsWith('mod.open:bk-')).map((a) => a.slice('mod.open:bk-'.length));
const mine = [...new Set([...byKey.filter((c) => !views.includes(c)), 'aviso', 'seguir'])].sort();
let said = [], hcs = [], overlays = [];
const Bk2 = new Function('View', 'div', 'hc', 'exec', 'run', 'props', 'openOverlay', 'closeOverlay', 'focused', 'terminals',
  'spaces', 'agents', 'home', 'notify', 'shared', 'setShared', 'readTextFile', source + '\nreturn Bk;')(
  class {}, () => ({}), async (a) => { hcs.push(a); return { code: 0, stdout: '{"address":"t9"}', stderr: '' }; },
  async () => ({ code: 0, stdout: '', stderr: '' }), () => {}, () => ({}), (o) => { overlays.push(o); return 'o1'; }, () => {},
  () => ({ space: 's1', tab: 'tb1', cwd: '/proj', terminal: 't1' }), () => [], () => [], () => [], () => '/home/yo',
  (x) => said.push(x), () => null, () => {}, async () => null);
const bk2 = new Bk2();
assert.ok(mine.length >= 20 && views.length >= 10, `teclas y vistas leídas: ${mine.length} y ${views.length}`);
for (const c of mine) {
  said = [];
  await bk2.handle(c);
  assert.deepEqual(said.filter((x) => String(x.body).startsWith('comando desconocido')), [], `bk-${c} tiene su acción`);
}
ok(`cada nombre con que se instala el mod tiene su acción (${mine.length}: ${mine.filter((c) => !/\d$/.test(c)).join(', ')}, go1…9, agent1…9)`);
hcs = []; overlays = [];
await bk2.handle('seguir');
assert.ok(hcs.length === 1 && hcs[0].at(-1).includes('bk handoff --seguir'), 'seguir corre bk handoff --seguir en una terminal');
assert.deepEqual([overlays.length, overlays[0]?.width, overlays[0]?.height, overlays[0]?.layout?.content?.terminal], [1, 0.6, 0.3, 't9']);
ok('seguir (el clic de «Resumen listo») abre bk handoff --seguir en un popup sobre la ventana');
hcs = []; overlays = [];
for (const v of views) {
  said = [];
  await bk2.handle(v);
  assert.deepEqual(said.map((x) => x.body), [`comando desconocido: ${v}`], `la vista ${v} es del hub: este mod no le abre un popup`);
}
assert.deepEqual([hcs, overlays], [[], []]);
ok(`las ${views.length} vistas del hub (comandos, cambios, sesiones…) no son popups de terminal de este mod`);
console.log(`1..${n}`);
JS
# La lista de agentes (herdr/mods/agentes): la antigüedad de la fila no va en una caja de ancho fijo. En 28 px
# entraba «12m» y «ahora» se partía en dos renglones (2026-11-15).
row=$(grep -c 'ago(now - when)' "$ROOT/herdr/mods/agentes/main.js")
fit=$(grep 'ago(now - when)' "$ROOT/herdr/mods/agentes/main.js" | grep -c 'div()\.flex_none()\.min_w(28)\.whitespace_nowrap()\.text_right()[^()]*(timeColor)\.child(ago(now - when))')
[ "$row $fit" = "1 1" ] || { echo "not ok - agentes: la antigüedad de la fila va en una caja de ancho fijo o se puede partir ($row $fit)"; exit 1; }
echo "ok - agentes: la antigüedad de la fila no se parte (ancho mínimo, sin salto de renglón)"
[ "$(grep -c 'mod.open --name bk-aviso' "$TMP/app.log")" = 3 ] || { echo "not ok - hd_notice no abrió bk-aviso por cada aviso"; exit 1; }
echo "ok - hd_notice abre bk-aviso una vez por aviso"
