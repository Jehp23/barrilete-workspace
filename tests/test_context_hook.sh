#!/usr/bin/env bash
# lib/context_hook.py: el aviso de contexto al agente (UserPromptSubmit y PostToolUse). Transcripts y estado de
# prueba en un directorio temporal: no toca ~/.claude ni ~/.cache.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export BK_CONTEXT_HOOK_STATE="$TMP/state"
export BK_CONTEXT_FILE="$TMP/context"   # sin archivo: el umbral por defecto (rojo 200k, ámbar 150k), no el de ~/.config
export BK_HANDOFF_DIR="$TMP/handoffs"; unset TMUX_PANE   # el rojo deja el .json del handoff: acá, no en ~/.local
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }

T="$TMP/t.jsonl"; : >"$T"
turn() {  # cache_read: el contexto del último turno
  printf '{"type":"assistant","message":{"id":"m%s","model":"claude-opus-5-5","usage":{"input_tokens":0,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":%s}}}\n' "$RANDOM" "$1" >>"$T"
}
# hook [evento] [sid] [extra json]: salida del hook (additionalContext, o "-" si no imprimió nada) y código
hook() {
  local out rc
  out=$(printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"%s"%s}' \
        "${2:-s1}" "$T" "${1:-UserPromptSubmit}" "${3:-}" | python3 "$ROOT/lib/context_hook.py"); rc=$?
  [ -z "$out" ] && { echo "- rc=$rc"; return; }
  python3 -c 'import json,sys; o=json.loads(sys.argv[1])["hookSpecificOutput"]; print(o["hookEventName"], o["additionalContext"].split(":")[0].split(" y ")[0])' "$out"
}

turn 149999
check_eq "$(hook)" "- rc=0" "abajo de 150k: nada"
turn 150000
check_eq "$(hook)" "UserPromptSubmit Llevás 150k de contexto" "cruza 150k (3/4 del umbral): aviso ámbar en additionalContext"
check_eq "$(printf '{"session_id":"s1","transcript_path":"%s","hook_event_name":"UserPromptSubmit"}' "$T" | python3 "$ROOT/lib/context_hook.py" | wc -c | tr -d ' ')" "0" "no repite en el turno siguiente"
turn 199999
check_eq "$(hook PostToolUse)" "- rc=0" "sigue ámbar (199k): no repite, tampoco por PostToolUse"
turn 200000
check_eq "$(hook PostToolUse)" "PostToolUse Llevás 200k de contexto" "cruza 200k (el umbral): aviso rojo por PostToolUse"
N=$((N+1)); if printf '{"session_id":"s9","transcript_path":"%s","hook_event_name":"UserPromptSubmit"}' "$T" \
  | python3 "$ROOT/lib/context_hook.py" | grep -q 'BK_TASK_DIR'; then echo "ok $N - el rojo nombra BK_TASK_DIR y bk done"; else echo "not ok $N - el rojo nombra BK_TASK_DIR"; FAILED=$((FAILED+1)); fi
turn 299999
check_eq "$(hook)" "- rc=0" "rojo hasta 299k: no repite"
turn 300000
check_eq "$(hook)" "UserPromptSubmit Llevás 300k de contexto" "+100k (300k): vuelve a avisar"
turn 400001
check_eq "$(hook)" "UserPromptSubmit Llevás 400k de contexto" "+100k (400k): vuelve a avisar"
check_eq "$(hook UserPromptSubmit s2)" "UserPromptSubmit Llevás 400k de contexto" "otra sesión tiene su propio estado"
check_eq "$(hook PostToolUse s3 ',"agent_id":"a1"')" "- rc=0" "dentro de un subagente: nada"
check_eq "$(hook SessionStart s4)" "- rc=0" "otro evento: nada"
turn 100000
check_eq "$(hook)" "- rc=0" "baja (compact) a 100k: nada"
turn 160000
check_eq "$(hook)" "UserPromptSubmit Llevás 160k de contexto" "después de bajar, vuelve a avisar al cruzar el ámbar"

# Errores: siempre salida vacía y código 0
check_eq "$(echo 'no es json' | python3 "$ROOT/lib/context_hook.py"; echo "rc=$?")" "rc=0" "stdin que no es JSON: nada, código 0"
check_eq "$(printf '{"session_id":"s5","transcript_path":"%s/no-existe","hook_event_name":"UserPromptSubmit"}' "$TMP" | python3 "$ROOT/lib/context_hook.py"; echo "rc=$?")" "rc=0" "transcript que no existe: nada, código 0"
: >"$TMP/ro"; check_eq "$(BK_CONTEXT_HOOK_STATE="$TMP/ro/x" hook UserPromptSubmit s6)" "- rc=0" "no puede escribir el estado: nada, código 0"

# Cómo seguir en un chat nuevo: con Herdr, alt+h (pide el resumen); con tmux, alt+n. HOME de prueba: sin backend propio
nc() { (cd "$ROOT/lib" && HOME="$TMP/home" python3 -c 'import context_hook as C; print(C.next_chat())'); }
check_eq "$(BK_BACKEND=herdr nc)" "en un chat nuevo con su resumen (alt+h)" "con Herdr, el aviso ámbar manda a alt+h"
check_eq "$(BK_BACKEND=tmux nc)" "en un chat nuevo (alt+n)" "con tmux, el aviso ámbar sigue en alt+n"
mkdir -p "$TMP/home/.config/bk"; echo herdr >"$TMP/home/.config/bk/backend"
check_eq "$(env -u BK_BACKEND bash -c "$(declare -f nc); TMP='$TMP' ROOT='$ROOT' nc")" "en un chat nuevo con su resumen (alt+h)" "sin BK_BACKEND: el de ~/.config/bk/backend"
turn 0; turn 160000
check_eq "$(printf '{"session_id":"s7","transcript_path":"%s","hook_event_name":"UserPromptSubmit"}' "$T" | BK_BACKEND=herdr python3 "$ROOT/lib/context_hook.py" | grep -c 'alt+h')" "1" "el aviso ámbar de verdad dice alt+h con Herdr"

# El umbral que eligió la persona (bk context 300k): ámbar en 225k, rojo en 300k, después cada +100k
echo 300000 >"$BK_CONTEXT_FILE"; : >"$T"
turn 224999; check_eq "$(hook UserPromptSubmit u1)" "- rc=0" "umbral 300k: 224k todavía sin aviso"
turn 225000; check_eq "$(hook UserPromptSubmit u1)" "UserPromptSubmit Llevás 225k de contexto" "umbral 300k: ámbar en 225k (3/4)"
turn 299999; check_eq "$(hook UserPromptSubmit u1)" "- rc=0" "umbral 300k: 299k sigue ámbar"
turn 300000; N=$((N+1)); out=$(printf '{"session_id":"u1","transcript_path":"%s","hook_event_name":"UserPromptSubmit"}' "$T" | python3 "$ROOT/lib/context_hook.py")
if grep -q 'BK_TASK_DIR' <<<"$out"; then echo "ok $N - umbral 300k: rojo (pide el resumen) en 300k"; else echo "not ok $N - umbral 300k: rojo en 300k (got '$out')"; FAILED=$((FAILED+1)); fi
turn 400000; check_eq "$(hook UserPromptSubmit u1)" "UserPromptSubmit Llevás 400k de contexto" "umbral 300k: +100k (400k) vuelve a avisar"
echo 'cualquier cosa' >"$BK_CONTEXT_FILE"; : >"$T"
turn 150000; check_eq "$(hook UserPromptSubmit u2)" "UserPromptSubmit Llevás 150k de contexto" "archivo que no se entiende: el umbral por defecto (ámbar 150k)"
rm -f "$BK_CONTEXT_FILE"

echo "1..$N"
[ "$FAILED" -eq 0 ]
