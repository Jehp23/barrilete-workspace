#!/usr/bin/env bash
# bk ask (lib/ask.py) y bk models (lib/models.py). claude, codex y gemini son falsos y van primeros en el PATH:
# ningún test llama a un proveedor de verdad. HOME temporal: nada toca tu ~/.config/bk ni ~/.cache/bk.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
unset BK_BACKEND BK_PROJECT GIT_DIR GIT_WORK_TREE
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
B="$ROOT/bin/bk"; JQ=$(command -v jq)
REPO_SUM=$(shasum "$ROOT/tareas.yml" "$ROOT/models.yml")

# Los falsos: anotan cómo los llamaron (un argumento por renglón) en $TMP/<cli>.args
FAKE="$TMP/fake"; mkdir -p "$FAKE"
cat >"$FAKE/codex" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "debug models" ]; then
  [ -f "$HOME/codex-roto" ] && { echo "no json"; exit 0; }
  echo x >>"$HOME/codex-debug-llamadas"
  echo '{"models":[{"slug":"gpt-6.1-sol","visibility":"list","description":"workhorse"},{"slug":"oculto","visibility":"hide"}]}'; exit 0
fi
printf '%s\n' "$@" >"$HOME/codex.args"
while [ $# -gt 0 ]; do case "$1" in -o) o=$2; shift;; -C) c=$2; shift;; esac; shift; done
echo "listo" >"$o"; printf 'PNG' >"$c/barrilete.png"
EOF
cat >"$FAKE/claude" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$HOME/claude.args"; echo "respuesta de claude"
EOF
cat >"$FAKE/gemini" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$HOME/gemini.args"
echo 'Attempt 1 failed with status 429. RESOURCE_EXHAUSTED' >&2
sleep 30 & echo $! >"$HOME/gemini-hijo.pid"; wait
EOF
chmod +x "$FAKE"/*
export PATH="$FAKE:$PATH"

# ---------- bk models ----------
check_eq "$("$B" models codex --json | "$JQ" -c 'map(.model)')" '["gpt-6.1-sol"]' "models: codex sale de su CLI, sin los ocultos"
check_eq "$("$B" models --json | "$JQ" -c '[(map(.provider) | unique), (map(select(.provider == "gemini")) | length > 3)]')" '[["claude","codex","gemini"],true]' "models: claude y gemini de models.yml"
"$B" models >/dev/null; "$B" models >/dev/null
check_eq "$(wc -l <"$HOME/codex-debug-llamadas" | tr -d ' ')" "1" "models: lo de codex se guarda un día (una sola llamada)"
"$B" models --fresh >/dev/null
check_eq "$(wc -l <"$HOME/codex-debug-llamadas" | tr -d ' ')" "2" "models --fresh: vuelve a preguntarle a codex"
rm -rf "$HOME/.cache/bk"; touch "$HOME/codex-roto"
check_eq "$("$B" models codex --json)" "[]" "models: si codex devuelve algo roto, no rompe"
rm "$HOME/codex-roto"
mkdir -p "$HOME/.config/bk"; printf '# mío\ngemini/gemini-9-ultra   el nuevo\nfoo/bar no\n' >"$HOME/.config/bk/models.yml"
check_eq "$("$B" models gemini --json | "$JQ" -c 'map(select(.model == "gemini-9-ultra"))[0].desc') $("$B" models --json | "$JQ" 'map(select(.provider == "foo")) | length')" '"el nuevo" 0' "models: ~/.config/bk/models.yml suma los tuyos; un provider desconocido no entra"
"$B" models nadie >/dev/null 2>&1; check_eq "$?" "1" "models <provider> desconocido: error"

# ---------- bk ask: listar y editar ----------
check_eq "$("$B" ask --json | "$JQ" -c '[.tasks[] | [.name, .spec]]')" '[["imagenes","codex/gpt-6.1-sol"],["investigar","codex/gpt-6.1-sol"]]' "ask: las de fábrica (imágenes e investigar con codex)"
"$B" ask set resumir claude/haiku resumir textos largos >/dev/null
check_eq "$("$B" ask --json | "$JQ" -c '.tasks[] | select(.name == "resumir") | [.spec, .desc]')" '["claude/haiku","resumir textos largos"]' "ask set: una tarea nueva con su descripción"
"$B" ask set imagenes codex/gpt-6-luna >/dev/null
check_eq "$("$B" ask --json | "$JQ" -r '.tasks[] | select(.name == "imagenes") | .spec + " | " + (.desc | startswith("generar imágenes") | tostring)')" "codex/gpt-6-luna | true" "ask set sin descripción: cambia el modelo y la deja"
check_eq "$(grep -c '^# Tareas' "$HOME/.config/bk/tareas.yml")" "1" "ask set copia el de fábrica a ~/.config/bk y deja los comentarios"
"$B" ask rm resumir >/dev/null
check_eq "$("$B" ask --json | "$JQ" -r '.tasks | map(.name) | join(",")')" "imagenes,investigar" "ask rm la saca"
"$B" ask set mala foo/x >/dev/null 2>&1; r1=$?
"$B" ask set set claude/opus >/dev/null 2>&1; r2=$?
"$B" ask set Mal claude/opus >/dev/null 2>&1; r3=$?
"$B" ask set otra 'claude/x;rm -rf' >/dev/null 2>&1; r4=$?
"$B" ask rm nadie >/dev/null 2>&1; r5=$?
check_eq "$r1$r2$r3$r4$r5 $("$B" ask --json | "$JQ" -r '.tasks | map(.name) | join(",")')" "11111 imagenes,investigar" "provider, nombre reservado, mayúsculas, modelo raro o tarea que no existe: error y nada cambia"
check_eq "$(shasum "$ROOT/tareas.yml" "$ROOT/models.yml")" "$REPO_SUM" "tareas.yml y models.yml del repo quedan igual"

# ---------- bk ask: correr ----------
out=$("$B" ask imagenes 'un barrilete; $(touch '"$TMP"'/pwned) `id`'); rc=$?
dir=$(sed -n 's/^(carpeta: \(.*\))$/\1/p' <<<"$out")
check_eq "$rc $(head -1 <<<"$out") $(grep -c "^  $dir/barrilete.png$" <<<"$out")" "0 listo 1" "codex: imprime la respuesta y la imagen que dejó en su carpeta"
en_cache() { case "$1" in "$HOME/.cache/bk/ask/"*-imagenes-*) echo bien;; *) echo "$1";; esac; }
check_eq "$(en_cache "$dir") $(head -c 12 "$dir/pedido.txt")" "bien un barrilete" "cada pedido en su carpeta de ~/.cache/bk/ask, con el pedido guardado"
check_eq "$(grep -cx -- '-s' "$HOME/codex.args") $(grep -x -A1 -- '-s' "$HOME/codex.args" | tail -1) $(grep -x -A1 -- '-C' "$HOME/codex.args" | tail -1 | sed "s|$dir|DIR|") $(grep -c -- '--ephemeral' "$HOME/codex.args") $(grep -c 'dangerously' "$HOME/codex.args")" "1 workspace-write DIR 1 0" "codex: escribe solo en su carpeta, sin guardar sesión ni saltear el sandbox"
check_eq "$(sed -n 1,2p "$HOME/codex.args" | tr '\n' ' ')" "--search exec " "codex: con búsqueda web (--search va antes de exec)"
check_eq "$([ -e "$TMP/pwned" ] && echo corrió || echo literal) $(grep -c 'touch' "$HOME/codex.args")" "literal 1" "el pedido llega como texto: \$(…) y backticks no se ejecutan"
out=$("$B" ask set resumir claude/haiku resumir >/dev/null; "$B" ask resumir "hola"); rc=$?
check_eq "$rc $(head -1 <<<"$out") $(sed -n 2,3p "$HOME/claude.args" | tr '\n' ' ')" "0 respuesta de claude --model haiku " "claude: claude -p --model y la respuesta"
check_eq "$(grep -c -- 'dangerously\|--permission-mode' "$HOME/claude.args")" "0" "claude: sin saltear permisos"

"$B" ask set buscar gemini/gemini-2.5-flash buscar en la web >/dev/null   # una tarea de gemini (las de fábrica son de codex)
start=$(date +%s); err=$("$B" ask buscar "algo" --timeout 2 2>&1 >/dev/null); rc=$?; took=$(( $(date +%s) - start ))
check_eq "$rc $(grep -c 'pasaron 2 s' <<<"$err") $(grep -c '429' <<<"$err") $([ "$took" -lt 15 ] && echo rápido || echo "$took s")" "2 1 1 rápido" "gemini sin cuota que reintenta: corta a los --timeout segundos y dice que es la cuota (429)"
sleep 1; check_eq "$(kill -0 "$(cat "$HOME/gemini-hijo.pid")" 2>/dev/null && echo vivo || echo muerto)" "muerto" "al cortar mata también los procesos hijos de la CLI"
check_eq "$(grep -cx -- '-p' "$HOME/gemini.args") $(grep -cx -- '--yolo' "$HOME/gemini.args") $(grep -c 'approval-mode' "$HOME/gemini.args")" "1 0 0" "gemini: -p sin --yolo (lo que pide permiso no corre)"

"$B" ask nada "x" >/dev/null 2>&1; r1=$?
"$B" ask imagenes >/dev/null 2>&1; r2=$?
"$B" ask imagenes "x" --timeout >/dev/null 2>&1; r3=$?
check_eq "$r1$r2$r3" "111" "tarea que no existe, sin pedido o --timeout sin número: error"
PY=$(command -v python3); mkdir -p "$TMP/solo"; ln -s "$PY" "$TMP/solo/python3"
err=$(PATH="$TMP/solo:/usr/bin:/bin" "$B" ask buscar "x" 2>&1); rc=$?
check_eq "$rc $(grep -c 'no está instalada' <<<"$err")" "1 1" "sin la CLI del provider: lo dice y no corre"
check_eq "$(PATH="$TMP/solo:/usr/bin:/bin" "$B" ask --json | "$JQ" -c '[.tasks[] | .installed] | unique')" '[false]' "ask --json dice si falta la CLI"

echo "1..$N"
[ "$FAILED" -eq 0 ]
