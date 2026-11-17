#!/usr/bin/env bash
# lib/bitacora.py y bk bitacora: la sección «Bitácora de agentes» del HTML de estado, desde las retros de la rama
# agents/retros. Un kit de prueba (con su origin) y un gh falso en un directorio temporal: no toca ~/barrilete-kit,
# GitHub ni el HTML de ~/Downloads, y BK_NO_OPEN evita abrir el navegador.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/src" 2>/dev/null
( cd "$TMP/src" && git checkout -q -b agents/retros && mkdir retros
  printf -- '---\nrole: implementer\nmodel: sonnet\nskill: implement-issue\npr: #12\nissue: #7\ndate: 2026-11-10\n---\n**Deviations:** usé `jq` <script>x</script>\n' >retros/a.md
  printf -- '---\nrole: reviewer\nmodel: opus\nskill: review-pr\npr: 12\ndate: 2026-11-11\n---\n**What the review found:** nada\n' >retros/b.md
  printf -- '---\nrole: implementer\nmodel: sonnet\nissue: 9\ndate: 2026-11-12\n---\nTexto suelto\n' >retros/c.md
  printf -- '---\nrole: reviewer\npr: 99\ndate: 2026-11-13\n---\nno es retro\n' >retros/x.txt
  git add -A && git commit -qm retros && git push -q origin agents/retros 2>/dev/null )
git clone -q "$TMP/origin.git" "$TMP/kit" 2>/dev/null

mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/bin/bash
echo '[{"number":12,"title":"feat: algo <b>","state":"MERGED","url":"https://example.invalid/pr/12"}]'
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

H="$TMP/estado.html"
printf '<nav><a href="#pendiente">12 pendiente</a></nav>\n<main>\n<section id="pendiente"></section>\n</main>\n' >"$H"

check_eq "$(python3 -I "$ROOT/lib/bitacora.py" "$TMP/kit" "$H")" "ok: $H" "regenera y dice dónde"
check_eq "$(grep -o '<article class="bit"' "$H" | wc -l | tr -d ' ')" "2" "una tarjeta por cambio: el PR 12 (dos retros) y el issue 9"
check_eq "$(grep -c 'no es retro' "$H")" "0" "lo que no es .md no es una retro, aunque tenga encabezado"
check_eq "$(grep -c 'feat: algo &lt;b&gt;' "$H")" "1" "el título del PR, de gh, escapado"
check_eq "$(grep -c 'usé <code>jq</code> &lt;script&gt;' "$H")" "1" "el texto de la retro va escapado (con su código)"
check_eq "$(grep -c '<b>3</b><span>reportes' "$H")" "1" "cuenta las tres retros"
check_eq "$(grep -c 'href="#bitacora"' "$H")" "1" "suma el enlace en la navegación"
check_eq "$(grep -n 'bitacora:end' "$H" | cut -d: -f1)" "$(( $(grep -n '</main>' "$H" | cut -d: -f1) - 1 ))" "la sección va antes de </main>"

python3 -I "$ROOT/lib/bitacora.py" "$TMP/kit" "$H" >/dev/null
check_eq "$(grep -c 'bitacora:start' "$H")/$(grep -c 'href="#bitacora"' "$H")" "1/1" "correrlo de nuevo reemplaza la sección: no la duplica"

check_eq "$(BK_BITACORA_REPO="$TMP/kit" BK_BITACORA_HTML="$H" BK_NO_OPEN=1 "$ROOT/bin/bk" bitacora)" "ok: $H" \
  "bk bitacora la corre (con el repo y el HTML de las variables)"
check_eq "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import palette as P
print(sum(1 for e in P.ENTRIES if e[2] == "bitacora" and e[4] == "show"))' "$ROOT/lib")" "1" "alt+k tiene la fila «Bitácora de agentes»"

err=$(BK_BITACORA_REPO="$TMP/kit" BK_BITACORA_HTML="$TMP/no-esta.html" BK_NO_OPEN=1 "$ROOT/bin/bk" bitacora 2>&1); rc=$?
check_eq "$rc|$err" "1|no encuentro el HTML de estado en $TMP/no-esta.html (pasá la ruta como segundo argumento o en BK_BITACORA_HTML)" \
  "sin el HTML: lo dice en una línea (sin traceback) y sale con error"
check_eq "$(grep -c 'barrilete-estado-2026-11-15.backup.html' "$ROOT/lib/bitacora.py")" "2" "el HTML por defecto es el .backup.html de Descargas"

echo "1..$N"
[ "$FAILED" -eq 0 ]
