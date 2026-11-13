#!/usr/bin/env bash
# lib/check_test_fns.py: un test no corre su función bk a través de env, command, exec, xargs, sh -c… (correrían el
# bk real del PATH). Cada caso es un archivo de una línea más la función; nada se ejecuta, solo se lee.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
N=0; FAILED=0
C="$ROOT/lib/check_test_fns.py"
FN='bk() { env PATH="$TMP/fake:$PATH" HOME="$TMP/home" "$ROOT/bin/bk" "$@"; }'
# caso <quiere: mal|bien> <descripción> <línea…>
caso() {
  local want="$1" what="$2"; shift 2
  printf '%s\n' "$FN" "$@" >"$TMP/t.sh"
  local out rc; out=$(python3 "$C" "$TMP/t.sh"); rc=$?
  N=$((N+1))
  if { [ "$want" = mal ] && [ $rc -eq 1 ] && [ -n "$out" ]; } || { [ "$want" = bien ] && [ $rc -eq 0 ] && [ -z "$out" ]; }; then
    echo "ok $N - $want: $what"
  else echo "not ok $N - $want: $what (rc=$rc, salida='$out')"; FAILED=$((FAILED+1)); fi
}

# El caso real del 2026-11-10 y sus variantes: la función no corre, corre el bk del PATH
caso mal "env con -u y una asignación (el del 2026-11-10)" "(cd \"\$TMP/repo\" && env -u BK_NO_WARM FAKE_DISPLAY='otra|||x' bk review 9 >/dev/null)"
caso mal "env pelado" 'env bk ls'
caso mal "env con valores entre comillas y con \$(…)" 'env A="x y" B=$(pwd) C='"'"'z w'"'"' bk run 7'
caso mal "en un pipeline" 'echo x | env FOO=1 bk say i1 hola | cat'
caso mal "en una sustitución \$(…)" 'out=$(env FOO=1 bk ls 2>&1)'
caso mal "entre backticks" 'out=`env FOO=1 bk ls`'
caso mal "con la línea partida con \\" 'env -u TMUX \' '    FOO=1 \' '    bk review 9'
caso mal "dentro de otra función" 'lanza() { env FOO=1 bk review 7; }'
caso mal "command salta las funciones" 'command bk ls'
caso mal "exec también" 'exec bk ls'
caso mal "exec env" 'exec env FOO=1 bk ls'
caso mal "xargs" 'echo 9 | xargs bk review'
caso mal "xargs con opciones" 'echo 9 | xargs -n 1 bk review'
caso mal "timeout con su duración" 'timeout 5 bk ls'
caso mal "nohup y nice" 'nohup nice -n 5 bk ls &'
caso mal "sh -c sin llevar la función" 'sh -c "bk ls"'
caso mal "bash -c con comillas simples y una asignación" "bash -c 'FOO=1 bk review 9'"
caso mal "otra función del test, no solo bk" 'tasks() { python3 x "$@"; }' 'env FOO=1 tasks list'
P=plain   # por variable: si no, este archivo tendría el patrón que el chequeo busca
caso mal "función con la palabra function" "function $P() { x; }" "env A=1 $P ls"

# Lo que está bien no se marca
caso bien "la función sola" 'bk review 9'
caso bien "asignaciones delante de la función (sin env)" 'FOO=1 BAR=2 bk review 9'
caso bien "unset en un subshell (el arreglo del 2026-11-10)" "(unset BK_NO_WARM; cd \"\$TMP/repo\" && FAKE_DISPLAY='x' bk review 9 >/dev/null)"
caso bien "env con el programa por su ruta" 'env FOO=1 "$ROOT/bin/bk" review 9'
caso bien "env con otro programa" 'env -u BK_NO_WARM bash tests/x.sh'
caso bien "command -v pregunta, no corre" 'command -v bk >/dev/null'
caso bien "bash -c que lleva la función con declare -f" 'bash -c "$(declare -f bk); bk ls"'
caso bien "un comentario" '# antes decía: env -u X bk review 9'
caso bien "bk como argumento, no como comando" 'env FOO=1 echo bk'
caso bien "otra palabra que empieza igual" 'env FOO=1 bkt ls' 'exec bk-otro'
caso bien "sin esa función en el archivo, env bk es el programa" 'true'
printf 'env FOO=1 bk ls\n' >"$TMP/sin.sh"; out=$(python3 "$C" "$TMP/sin.sh"); rc=$?; N=$((N+1))
if [ $rc -eq 0 ] && [ -z "$out" ]; then echo "ok $N - bien: un archivo que no define bk puede llamar al programa con env"; else echo "not ok $N - archivo sin función"; FAILED=$((FAILED+1)); fi

# Dice dónde, y cada archivo se mira por separado
printf '%s\n' "$FN" 'true' 'env A=1 bk ls' >"$TMP/a.sh"; printf 'env A=1 bk ls\n' >"$TMP/b.sh"
out=$(python3 "$C" "$TMP/b.sh" "$TMP/a.sh"); N=$((N+1))
if [ "$out" = "$TMP/a.sh:3: \`env\` no corre funciones: \`bk\` es una función de este test y ahí se ejecuta el bk real del PATH" ]; then echo "ok $N - dice archivo y línea, y la función de un archivo no cuenta para otro"; else echo "not ok $N - mensaje (got '$out')"; FAILED=$((FAILED+1)); fi

# Los tests del repo pasan, y checks.sh lo corre
python3 "$C" "$ROOT"/tests/*.sh >/dev/null; rc=$?; N=$((N+1))
if [ $rc -eq 0 ]; then echo "ok $N - los tests del repo no tienen ese patrón"; else echo "not ok $N - los tests del repo"; FAILED=$((FAILED+1)); fi
N=$((N+1)); if grep -q 'check_test_fns.py tests/\*.sh || rc=1' "$ROOT/lib/checks.sh"; then echo "ok $N - lib/checks.sh lo corre y falla con él"; else echo "not ok $N - lib/checks.sh no lo corre"; FAILED=$((FAILED+1)); fi

echo "1..$N"
[ "$FAILED" -eq 0 ]
