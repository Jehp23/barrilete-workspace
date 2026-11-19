#!/usr/bin/env bash
# alt+k: agregar una cuenta de Claude o Codex (y volver a iniciar sesión en una) sin tipear bk account. En node, con
# Herdr y la paleta falsos: no abre popups ni hace logins. El comando que arma se prueba con el bk del repo en
# --dry-run y las cuentas en una carpeta temporal.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" BK_ACCOUNTS_DIR="$TMP/accounts" XDG_CONFIG_HOME="$TMP/config" XDG_CACHE_HOME="$TMP/cache"
mkdir -p "$HOME"
bk() { "$ROOT/bin/bk" "$@"; }

node --input-type=module - "$ROOT" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const root = process.argv[2];
const psrc = fs.readFileSync(`${root}/herdr/mods/hub/palette.js`, 'utf8')
  .replace(/^import .*;$/gm, '').replace(/export default class[\s\S]*$/, '');
const el = () => new Proxy({}, { get: () => () => el() });
const pops = [];
const NATIVE = new Function('div', 'h_flex', 'run', 'openOverlay', 'focused', 'notify', 'Panel', 'rank', 'bk', 'bin', 'launch',
  'goto', 'termPopup', 'chips', 'keyOf', 'lit', 'cwd', 'lastLine', psrc + '\nreturn NATIVE;')(
  el, el, () => {}, () => {}, () => null, () => {}, class {}, () => [], async () => ({}), () => '/repo/bin/bk', () => {},
  () => {}, (...a) => pops.push(a), () => {}, () => {}, el, () => '/proj', (s) => s);
let n = 0;
const ok = (what) => console.log(`ok ${++n} - ${what}`);
// Una paleta falsa: askFor guarda la pregunta; responder la corre como el enter del panel
const panel = () => ({ asks: [], closed: 0, askFor(a) { this.asks.push(a); }, close() { this.closed++; } });
const answer = (p, text) => p.asks.at(-1).run(text);
const entry = (id) => NATIVE.find((e) => e[0] === id) ?? assert.fail(`falta la entrada ${id}`);

for (const [prov, Prov] of [['claude', 'Claude'], ['codex', 'Codex']]) {
  const e = entry(`account-${prov}`);
  assert.deepEqual([e[1], e[2], e[3]], ['Sesión', `Agregar una cuenta de ${Prov}…`, `bk account new ${prov}`]);
  const p = panel(); pops.length = 0;
  e[6](p);
  assert.equal(p.asks.length, 1, 'pregunta el nombre');
  answer(p, 'trabajo');
  assert.deepEqual(pops, [['account', `'/repo/bin/bk' account new ${prov} trabajo`, '/proj', [0.7, 0.6]]]);
  assert.equal(p.closed, 1, 'cierra la paleta: el login va en una terminal sobre la ventana');
  ok(`«Agregar una cuenta de ${Prov}…» pide el nombre y abre bk account new ${prov} <nombre> en un popup`);
}
{
  const p = panel(); pops.length = 0;
  entry('account-claude')[6](p);
  for (const bad of ['Trabajo', 'mi cuenta', 'x;rm -rf ~', '$(id)', '-a', 'default', 'a'.repeat(32), "o'k"]) answer(p, bad);
  assert.deepEqual([pops.length, p.closed, p.asks.length], [0, 0, 9], 'un nombre que no sirve vuelve a preguntar y no llega al shell');
  assert.match(p.asks.at(-1).help, /no sirve/);
  ok('un nombre que no sirve (mayúsculas, espacios, comillas, $( ), default) no corre nada y vuelve a preguntar con el motivo');
}
{
  const e = entry('account-login');
  const p = panel(); pops.length = 0;
  e[6](p); answer(p, 'default');
  e[6](p); answer(p, 'trabajo');
  e[6](p); answer(p, 'x y');
  assert.deepEqual(pops.map((x) => x[1]), ["'/repo/bin/bk' account login default", "'/repo/bin/bk' account login trabajo"]);
  ok('«Volver a iniciar sesión en una cuenta…» abre bk account login <nombre> (también default) y no deja pasar otra cosa');
}
// El nombre se valida igual que en lib/accounts.py (NAME): si cambia uno, este test avisa
const py = /^NAME = re\.compile\(r"(.*)"\)$/m.exec(fs.readFileSync(`${root}/lib/accounts.py`, 'utf8'))[1];
const js = /^const NOMBRE = \/(.*)\/;$/m.exec(psrc)[1];
assert.equal(js, py);
ok('el nombre se valida con la misma regla que lib/accounts.py');
JS

# El comando que arma la paleta es uno que bk conoce (en --dry-run no crea la carpeta ni hace el login)
N=5
for prov in claude codex; do
  N=$((N+1))
  out=$(bk --dry-run account new "$prov" trabajo 2>&1) && [[ "$out" == *"crearía la cuenta $prov/trabajo"* ]] && [ ! -e "$BK_ACCOUNTS_DIR/trabajo" ] \
    && echo "ok $N - bk account new $prov trabajo es un comando de bk" \
    || { echo "not ok $N - bk --dry-run account new $prov trabajo: $out"; exit 1; }
done
echo "1..$N"
