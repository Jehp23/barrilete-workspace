#!/usr/bin/env bash
# lib/bitacora.py y bk bitacora: corren el scripts/agents/bitacora.py del kit en cada repo con retros
# (barrilete-kit#339). Los repos son de prueba, con un bitacora.py falso: no toca ~/barrilete-kit ni GitHub,
# HOME apunta al directorio temporal (retros.json de prueba) y BK_NO_OPEN evita abrir el navegador.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }

# Un repo con el kit nuevo: su bitacora.py falso deja la página y anota con qué argumentos lo corrieron.
nuevo() {
  mkdir -p "$1/scripts/agents"
  cat >"$1/scripts/agents/bitacora.py" <<'EOF'
import os, sys
repo = sys.argv[sys.argv.index("-C") + 1]
os.makedirs(os.path.join(repo, ".barrilete"), exist_ok=True)
open(os.path.join(repo, ".barrilete", "bitacora.html"), "w").write("pagina")
open(os.path.join(repo, "args.txt"), "w").write(" ".join(sys.argv[1:]))
print("ok: " + os.path.join(repo, ".barrilete", "bitacora.html"))
EOF
}
nuevo "$TMP/a"; nuevo "$TMP/b"; mkdir -p "$TMP/viejo"
mkdir -p "$TMP/roto/scripts/agents"; printf 'import sys\nsys.exit("bitacora.py: algo falló")\n' >"$TMP/roto/scripts/agents/bitacora.py"

out=$(python3 -I "$ROOT/lib/bitacora.py" "$TMP/a" 2>&1)
check_eq "$out" "ok: $TMP/a/.barrilete/bitacora.html" "con un repo como argumento, corre solo ese y dice dónde quedó"
check_eq "$(cat "$TMP/a/args.txt" 2>/dev/null)" "-C $TMP/a" "le pasa al script del kit el repo con -C"

mkdir -p "$TMP/.config/bk"
printf '{"repos": ["%s", "%s", "%s", "%s"]}\n' "$TMP/a" "$TMP/viejo" "$TMP/roto" "$TMP/b" >"$TMP/.config/bk/retros.json"
out=$(HOME="$TMP" python3 -I "$ROOT/lib/bitacora.py" 2>"$TMP/err"); rc=$?
check_eq "$out" "ok: $TMP/a/.barrilete/bitacora.html
ok: $TMP/b/.barrilete/bitacora.html" "sin argumentos, una página por cada repo de retros.json"
check_eq "$rc" "0" "con al menos una página, termina con 0"
check_eq "$(grep -c 'viejo no trae scripts/agents/bitacora.py' "$TMP/err")" "1" "un repo con el kit viejo lo dice en una línea y sigue"
check_eq "$(grep -c 'roto: bitacora.py: algo falló' "$TMP/err")" "1" "si el script de un repo falla, dice por qué y sigue"
check_eq "$(grep -c Traceback "$TMP/err")" "0" "sin traceback"

python3 -I "$ROOT/lib/bitacora.py" "$TMP/viejo" >/dev/null 2>&1; rc=$?
check_eq "$rc" "1" "si ningún repo da una página, termina con 1"

check_eq "$(HOME="$TMP" BK_NO_OPEN=1 "$ROOT/bin/bk" bitacora "$TMP/b" 2>&1)" "ok: $TMP/b/.barrilete/bitacora.html" \
  "bk bitacora corre el envoltorio con los repos que le pasan"
check_eq "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import palette as P
print(sum(1 for e in P.ENTRIES if e[2] == "bitacora" and e[4] == "show"))' "$ROOT/lib")" "1" "alt+k tiene la fila «Bitácora de agentes»"

echo "1..$N"
[ "$FAILED" -eq 0 ] || { echo "$FAILED fallaron"; exit 1; }
