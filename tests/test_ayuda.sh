#!/usr/bin/env bash
# bk _ayuda: el ayudante del workspace (alt+y en Herdr). Corre Codex en el repo de bk con el encargo de
# lib/ayudante.md como primer mensaje. Acá bk ve un codex falso que solo anota dónde y con qué lo llamaron.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
unset TMUX TMUX_PANE BK_ACCOUNT BK_BACKEND
export HOME="$TMP/home"; mkdir -p "$HOME" "$TMP/fake" "$TMP/otra"
cat >"$TMP/fake/codex" <<FAKE
#!/bin/sh
pwd -P >"$TMP/codex.cwd"; echo "\$#" >"$TMP/codex.argc"; printf '%s' "\$1" >"$TMP/codex.arg1"
FAKE
chmod +x "$TMP/fake/codex"
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
# run <args>: bk desde otra carpeta, con el codex falso primero en el PATH; sin colores
run() { (cd "$TMP/otra" && PATH="$TMP/fake:$PATH" "$ROOT/bin/bk" "$@" 2>&1) | sed 's/\x1b\[[0-9;]*m//g'; }
# sin_codex <args>: lo mismo sin ningún codex en el PATH
sin_codex() { (cd "$TMP/otra" && PATH="/usr/bin:/bin" "$ROOT/bin/bk" "$@" 2>&1; echo "rc=$?") | sed 's/\x1b\[[0-9;]*m//g'; }
REAL=$(cd "$ROOT" && pwd -P)

check_eq "$(run --dry-run _ayuda)" "(dry-run: abriría codex en $ROOT con el encargo de $ROOT/lib/ayudante.md)" "dry-run: dice qué abriría"
check_eq "$([ -e "$TMP/codex.cwd" ] && echo corrió || echo no)" "no" "dry-run: no corre codex"
run _ayuda >/dev/null
check_eq "$(cat "$TMP/codex.cwd" 2>/dev/null)" "$REAL" "corre codex en el repo de bk, se lo llame desde donde se lo llame"
check_eq "$(cat "$TMP/codex.argc" 2>/dev/null)" "1" "le pasa un solo argumento: el primer mensaje"
check_eq "$(cat "$TMP/codex.arg1" 2>/dev/null)" "$(cat "$ROOT/lib/ayudante.md")" "el primer mensaje es el encargo de lib/ayudante.md, entero"
if command -v codex >/dev/null 2>&1 && PATH="/usr/bin:/bin" command -v codex >/dev/null 2>&1; then
  echo "ok $((N+1)) - sin codex: # SKIP hay un codex en /usr/bin o /bin"; N=$((N+1))
else
  check_eq "$(sin_codex _ayuda)" "bk: el ayudante es una sesión de Codex: Codex CLI no está instalado
rc=1" "sin codex: lo dice y sale con error"
  check_eq "$(sin_codex --dry-run _ayuda | tail -1)" "rc=1" "sin codex: el dry-run también falla (el popup lo usa para saber si puede arrancar)"
fi
# El encargo nombra lo que el ayudante no debe hacer solo (AGENTS.md)
for palabra in 'bk land --wait' 'bk land --help' 'tmux kill-server' 'bk backend herdr' '--dry-run'; do
  check_eq "$(grep -c -F -- "$palabra" "$ROOT/lib/ayudante.md")" "1" "el encargo nombra: $palabra"
done

echo "1..$N"
[ "$FAILED" -eq 0 ]
