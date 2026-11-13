#!/usr/bin/env bash
# bk _tasks (lib/herdr_tasks.py): las tareas con el título de su issue o PR, para los paneles de Herdr.
# Tareas, caché y HOME en un directorio temporal; gh es un falso que anota lo que le piden.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" BK_TASKS_DIR="$TMP/tasks" BK_CACHE_DIR="$TMP/cache" BK_STATE_DIR="$TMP/state"
unset BK_BACKEND BK_PROJECT GIT_DIR GIT_WORK_TREE BK_TASK_DIR
mkdir -p "$HOME" "$TMP/fake" "$BK_CACHE_DIR"
cat >"$TMP/fake/gh" <<FAKE
#!/bin/sh
echo "\$*" >>"$TMP/gh.log"
[ -f "$TMP/sin-red" ] && exit 1
case "\$2" in repos/o/r/issues/*) echo "Título de \${2##*/}" ;; *) exit 1 ;; esac
FAKE
chmod +x "$TMP/fake/gh"; : >"$TMP/gh.log"
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
tk() { python3 "$ROOT/lib/tasks.py" "$@" >/dev/null; }
bkt() { PATH="$TMP/fake:$PATH" "$ROOT/bin/bk" _tasks "$@"; }
calls() { wc -l <"$TMP/gh.log" | tr -d ' '; }

REPO="$TMP/proj"; git init -q -b main "$REPO"; git -C "$REPO" remote add origin "git@github.com:o/r.git"
tk create proj 7-implementer --role implementer --ref 7 --repo "$REPO"
tk create proj pr9-implementer --role implementer --ref 8 --pr 9 --repo "$REPO"
tk create proj pr5-reviewer --role reviewer --pr 5 --repo "$REPO"
tk create otro 3-implementer --role implementer --ref 3 --repo "$TMP/ya-no-existe"
sum() { cat "$BK_TASKS_DIR"/*/*/task.json | shasum | cut -d' ' -f1; }; before=$(sum)

check_eq "$(bkt | jq -c 'map({(.id): .title}) | add')" '{"7-implementer":"Título de 7","pr9-implementer":"Título de 8","pr5-reviewer":"Título de 5","3-implementer":""}' "título del issue de cada tarea (el issue antes que el PR; el PR si no hay issue); sin repo, vacío"
check_eq "$(sort "$TMP/gh.log" | tr '\n' '|')" "api repos/o/r/issues/5 --jq .title|api repos/o/r/issues/7 --jq .title|api repos/o/r/issues/8 --jq .title|" "le pide a GitHub solo lo que falta, y nada del repo que no existe"
n=$(calls); bkt >/dev/null
check_eq "$(calls)" "$n" "la segunda vez sale de la caché: no vuelve a pedir"
check_eq "$(sum)" "$before" "no cambia ninguna tarea"

for i in $(seq 20 32); do tk create proj "$i-implementer" --role implementer --ref "$i" --repo "$REPO"; done
: >"$TMP/gh.log"; bkt >/dev/null
check_eq "$(calls)" "8" "hasta 8 pedidos por corrida: el panel no se traba con el historial"
bkt >/dev/null; check_eq "$(calls) $(bkt | jq '[.[] | select(.title == "")] | length')" "13 1" "las corridas siguientes completan el resto"

touch "$TMP/sin-red"; tk create proj 40-implementer --role implementer --ref 40 --repo "$REPO"
check_eq "$(bkt | jq -r '.[] | select(.id == "40-implementer") | .title + "|" + .status')" "|in_progress" "sin red: la tarea sale igual, sin título"
check_eq "$(bkt | jq length) $(bkt --all | jq length)" "$(python3 "$ROOT/lib/tasks.py" list --json | jq length) $(python3 "$ROOT/lib/tasks.py" list --json --all | jq length)" "las mismas tareas que bk tasks, con y sin --all"

echo "1..$N"
[ "$FAILED" -eq 0 ]
