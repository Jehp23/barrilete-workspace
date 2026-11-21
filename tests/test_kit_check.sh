#!/usr/bin/env bash
# lib/kit_check.py y bk run: por qué no se puede lanzar en un proyecto, en palabras. El 2026-11-19, «Lanzar» de una
# épica de abra (barrilete-kit 0.9.0) fallaba con «no es un proyecto Barrilete», que no decía qué hacer.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
unset TMUX TMUX_PANE BK_ACCOUNT
export HOME="$TMP/home"; mkdir -p "$HOME"
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
repo() { git init -q -b main "$TMP/$1"; git -C "$TMP/$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; }
kc() { python3 "$ROOT/lib/kit_check.py" "$TMP/$1"; echo "rc=$?"; }
# bk --dry-run run 5 desde ese repo: lo primero que hace es mirar el kit (sin red ni tmux)
bkrun() { (cd "$TMP/$1" && "$ROOT/bin/bk" --dry-run run 5 2>&1; echo "rc=$?") | sed 's/\x1b\[[0-9;]*m//g' | sed -n '1p;$p'; }

repo nada
check_eq "$(kc nada)" "nada no es un proyecto Barrilete: no tiene barrilete-kit (.agent-kit.json)
rc=1" "sin kit: lo dice"
repo viejo; printf '{"proyecto": "Viejo", "version": "0.9.0"}\n' >"$TMP/viejo/.agent-kit.json"; mkdir -p "$TMP/viejo/scripts/agentes"
check_eq "$(kc viejo)" "viejo tiene el kit 0.9.0: para lanzar agentes hace falta barrilete-kit 2 o más nuevo. Actualizá el kit de viejo
rc=1" "kit 0.x: la versión y qué hacer"
repo sinver; mkdir -p "$TMP/sinver/scripts/agentes"
check_eq "$(kc sinver | sed -n 1p)" "sinver tiene un kit viejo (scripts/agentes/): para lanzar agentes hace falta barrilete-kit 2 o más nuevo. Actualizá el kit de sinver" "kit viejo sin .agent-kit.json: lo reconoce por scripts/agentes/"
repo roto; printf '{"version": "2.1.0"}\n' >"$TMP/roto/.agent-kit.json"
check_eq "$(kc roto | sed -n 1p)" "a roto le falta scripts/agents/guardrails.py de barrilete-kit 2.1.0: actualizá o reinstalá el kit" "kit 2 a medias: qué falta"
repo bueno; mkdir -p "$TMP/bueno/scripts/agents"; : >"$TMP/bueno/scripts/agents/guardrails.py"
check_eq "$(kc bueno)" "rc=0" "kit al día: nada que decir"
repo json; printf 'no es json' >"$TMP/json/.agent-kit.json"
check_eq "$(kc json | sed -n 1p)" "a json le falta scripts/agents/guardrails.py de barrilete-kit: actualizá o reinstalá el kit" "un .agent-kit.json roto no lo rompe"
check_eq "$(bkrun viejo)" "bk: viejo tiene el kit 0.9.0: para lanzar agentes hace falta barrilete-kit 2 o más nuevo. Actualizá el kit de viejo
rc=1" "bk run en un kit viejo: el motivo real, y falla"
check_eq "$(bkrun nada | sed -n 1p)" "bk: nada no es un proyecto Barrilete: no tiene barrilete-kit (.agent-kit.json)" "bk run sin kit: lo dice"

echo "1..$N"
[ "$FAILED" -eq 0 ]
