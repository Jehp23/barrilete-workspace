#!/usr/bin/env bash
# El panel «Perfiles de modelos y tareas» (herdr/mods/hub/profiles.js) en node, con Herdr y GPUI falsos
# (tests/herdr_stub/stub.js) y el bk de verdad sobre un HOME temporal. Cada evento tiene su contexto y usarlo
# después de que terminó falla, como en Herdr: así se cayó «Nueva tarea» (2026-11-15). claude, codex, gemini y
# security son falsos: nadie le pregunta a un proveedor ni al llavero real.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
unset BK_BACKEND BK_PROJECT GIT_DIR GIT_WORK_TREE GEMINI_API_KEY GOOGLE_API_KEY
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
command -v node >/dev/null || { echo "1..0 # skip: sin node"; exit 0; }

FAKE="$TMP/fake"; mkdir -p "$FAKE"
# claude con sesión; codex sin sesión; gemini instalado; security dice si hay clave según $HOME/gemini-key
printf '#!/bin/sh\n[ "$1 $2" = "auth status" ] && { echo %s; exit 0; }\nexit 0\n' "'{\"loggedIn\": true, \"email\": \"a@b.c\"}'" >"$FAKE/claude"
printf '#!/bin/sh\n[ "$1 $2" = "login status" ] && { echo "Not logged in"; exit 1; }\n[ "$1 $2" = "debug models" ] && { echo %s; exit 0; }\nexit 0\n' "'{\"models\":[{\"slug\":\"gpt-6.1-sol\",\"visibility\":\"list\"}]}'" >"$FAKE/codex"
printf '#!/bin/sh\nexit 0\n' >"$FAKE/gemini"
printf '#!/bin/sh\n[ -f "$HOME/gemini-key" ] && [ "$3" = gemini-cli-api-key ]\n' >"$FAKE/security"
chmod +x "$FAKE"/*
export PATH="$FAKE:$ROOT/bin:$PATH"

# El panel y kit.js con sus imports apuntando a los falsos
SIM="$TMP/sim"; mkdir -p "$SIM"
cp "$ROOT/herdr/mods/hub/kit.js" "$ROOT/herdr/mods/hub/profiles.js" "$HERE/herdr_stub/stub.js" "$SIM/"
sed -i.bak 's#from "gpui-kit"#from "./stub.js"#; s#from "gpui-base"#from "./stub.js"#; s#from "herdr"#from "./stub.js"#' "$SIM/kit.js" "$SIM/profiles.js"
cat >"$SIM/run.mjs" <<'EOF'
import P from "./profiles.js";
import { CX, mkCX, renders } from "./stub.js";
const out = [];
const ev = (f) => { const c = mkCX(); try { f(c); } catch (e) { out.push("ERROR " + e.message); } c.alive = false; };
const settle = async () => { for (let i = 0; i < 50 && CX.p; i++) { const p = CX.p; await p; if (CX.p === p) break; } };
const pick = (pred) => { const i = p.picks().findIndex(pred); if (i < 0) throw new Error("no hay esa fila"); p.at = i; };
const p = new P(); p.init({}, CX); await settle();
const heads = () => p.rows().filter((r) => r.head).map((r) => r.head).join(",");
const step = process.argv[2];
if (step === "tarea") {
  pick((r) => r.newTask); const before = renders.n; ev((c) => p.submit(c));
  out.push("redibuja " + (renders.n > before ? "sí" : "no") + " " + (p.ask?.label ?? "-"));
  ev(() => p.input.set_value("traducir")); ev((c) => p.submit(c));
  ev(() => p.input.set_value("traducir textos al inglés")); ev((c) => p.submit(c));
  out.push("cabeceras " + heads());
  pick((r) => r.spec === "claude/haiku"); ev((c) => p.submit(c)); await settle();
  out.push("nivel " + (p.task ? "modelos" : "inicio"));
} else if (step === "otro") {
  pick((r) => r.t?.name === "imagenes"); ev((c) => p.submit(c));
  pick((r) => r.other); const before = renders.n; ev((c) => p.submit(c));
  out.push("redibuja " + (renders.n > before ? "sí" : "no") + " " + (p.ask ? "pregunta" : "-"));
  ev(() => p.input.set_value("claude/claude-opus-5-5")); ev((c) => p.submit(c)); await settle();
} else if (step === "perfil") {
  pick((r) => r.p?.name === "normal"); ev((c) => p.key({ key: "right", modifiers: {} }, p.current(), c));
  pick((r) => r.role === "reviewer"); ev((c) => p.submit(c));
  out.push("cabeceras " + heads());
}
out.push("error " + (p.error ?? "-"));
console.log(out.join("\n"));
EOF
sim() { (cd "$SIM" && node run.mjs "$1" 2>&1); }

o=$(sim tarea)
check_eq "$(grep '^redibuja' <<<"$o")" "redibuja sí tarea" "enter en «Nueva tarea…» con el buscador vacío abre la pregunta y redibuja (antes no se veía)"
check_eq "$(grep -c '^ERROR' <<<"$o")" "0" "nueva tarea: ningún paso usa un contexto viejo"
check_eq "$("$ROOT/bin/bk" ask --json | jq -c '.tasks[] | select(.name == "traducir") | [.spec, .desc]')" '["claude/haiku","traducir textos al inglés"]' "nueva tarea: nombre, descripción y modelo quedan guardados"
check_eq "$(grep '^nivel' <<<"$o")" "nivel inicio" "nueva tarea: al guardar vuelve al inicio"
check_eq "$(grep '^cabeceras' <<<"$o")" "cabeceras claude,otro" "tareas: solo los proveedores con sesión (claude sí, codex no, gemini sin clave)"

o=$(sim otro)
check_eq "$(grep '^redibuja' <<<"$o")" "redibuja sí pregunta" "enter en «Otro…» abre la pregunta y redibuja"
check_eq "$(grep -c '^ERROR' <<<"$o") $("$ROOT/bin/bk" ask --json | jq -r '.tasks[] | select(.name == "imagenes") | .spec')" "0 claude/claude-opus-5-5" "«Otro…»: escribir provider/modelo y guardar"

touch "$HOME/gemini-key"
o=$(sim tarea)
check_eq "$(grep '^cabeceras' <<<"$o")" "cabeceras claude,gemini,otro" "con la clave de gemini en el llavero, gemini aparece para las tareas"
o=$(sim perfil)
check_eq "$(grep '^cabeceras' <<<"$o") $(grep -c '^ERROR' <<<"$o")" "cabeceras claude,otro 0" "perfiles: gemini nunca (no ocupa roles) y codex sin sesión tampoco"

echo "1..$N"
[ "$FAILED" -eq 0 ]
