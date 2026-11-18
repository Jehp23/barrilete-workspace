#!/usr/bin/env bash
# usage.context_of: el contexto del último turno de una sesión, leyendo solo el final del transcript
# (lo usan la tira, el riel, bk monitor y bk land). Transcripts de prueba: no toca ~/.claude.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export BK_CONTEXT_FILE="$TMP/context"   # el umbral: sin archivo, el por defecto; nunca el de ~/.config
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }

ctx() { python3 - "$ROOT/lib" "$@" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import usage as U
cmd = sys.argv[2]
if cmd == "of":
    print(U.context_of(path=sys.argv[3]))
elif cmd == "level":
    print(U.ctx_level(int(sys.argv[3])) or "-")
elif cmd == "grow":   # lee, el archivo crece, vuelve a leer en el mismo proceso (la cache no puede quedar vieja)
    p = sys.argv[3]; a = U.context_of(path=p)
    open(p, "a").write(open(sys.argv[4]).read()); print(a, U.context_of(path=p))
PY
}

# Un turno del asistente con usage: in + cw (5m y 1h) + cr = contexto
turn() {  # in cw5 cw1h cr [extra]
  printf '{"type":"assistant","message":{"id":"m%s","model":"claude-opus-5-5","usage":{"input_tokens":%s,"output_tokens":50,"cache_creation_input_tokens":%s,"cache_creation":{"ephemeral_1h_input_tokens":%s},"cache_read_input_tokens":%s}}%s}\n' \
    "$RANDOM" "$1" "$(($2 + $3))" "$3" "$4" "${5:-}"
}

T="$TMP/a.jsonl"
{ turn 10 100 0 1000; turn 5 200 300 150000; } >"$T"
check_eq "$(ctx of "$T")" "150505" "toma el último turno y suma entrada + escrituras 5m y 1h + lectura de cache"

{ cat "$T"; turn 1 1 1 900000 ',"isSidechain":true'; } >"$TMP/b.jsonl"
check_eq "$(ctx of "$TMP/b.jsonl")" "150505" "ignora los turnos de un subagente (isSidechain)"

{ cat "$T"; printf '{"type":"assistant","message":{"id":"s","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}\n';
  printf '{"type":"user","message":{"content":"hola"},"usage":"no"}\n'; } >"$TMP/c.jsonl"
check_eq "$(ctx of "$TMP/c.jsonl")" "150505" "ignora los mensajes sintéticos y los del usuario"

# Más grande que lo que se lee del final (512 KB): la primera línea del pedazo queda cortada y no rompe
{ turn 1 0 0 7; head -c 700000 /dev/zero | tr '\0' 'x' | sed 's/.*/{"type":"user","message":{"content":"&"}}/'; echo; turn 2 0 0 333000; } >"$TMP/d.jsonl"
check_eq "$(ctx of "$TMP/d.jsonl")" "333002" "archivo grande: la primera línea del final leído viene cortada y no rompe"

# El último turno quedó a más de 512 KB del final (un tool_result enorme después): igual lo encuentra
{ turn 3 0 0 222000; head -c 700000 /dev/zero | tr '\0' 'y' | sed 's/.*/{"type":"user","message":{"content":"&"}}/'; echo; } >"$TMP/f.jsonl"
check_eq "$(ctx of "$TMP/f.jsonl")" "222003" "último turno lejos del final: lo busca en todo el archivo"

: >"$TMP/e.jsonl"
check_eq "$(ctx of "$TMP/e.jsonl")" "None" "sin turnos: None"
check_eq "$(ctx of "$TMP/no-existe.jsonl")" "None" "sin archivo: None"

turn 0 0 0 420000 >"$TMP/more.jsonl"
check_eq "$(ctx grow "$T" "$TMP/more.jsonl")" "150505 420000" "si el transcript crece, vuelve a leerlo"

check_eq "$(ctx level 149999)" "-" "umbral por defecto (200k): por debajo de 150k sin aviso"
check_eq "$(ctx level 150000)" "warn" "umbral por defecto: ámbar desde 150k (3/4)"
check_eq "$(ctx level 199999)" "warn" "umbral por defecto: 199k sigue ámbar"
check_eq "$(ctx level 200000)" "high" "umbral por defecto: rojo desde 200k"
echo 400k >"$BK_CONTEXT_FILE"
check_eq "$(ctx level 299999) $(ctx level 300000) $(ctx level 400000)" "- warn high" "umbral 400k (escrito «400k»): ámbar desde 300k, rojo desde 400k"
for bad in 40k 3m abc ''; do printf '%s' "$bad" >"$BK_CONTEXT_FILE"
  check_eq "$(ctx level 199999) $(ctx level 200000)" "warn high" "umbral «${bad}» (fuera de rango o no es número): el por defecto"; done
rm -f "$BK_CONTEXT_FILE"

# bk context: muestra, cambia y vuelve al por defecto (solo escribe en BK_CONTEXT_FILE)
BK="$ROOT/bin/bk"
check_eq "$("$BK" context --json | jq -c .)" '{"limit":200000,"warn":150000,"default":200000,"custom":false}' "bk context --json: sin archivo, 200k por defecto"
"$BK" context 350k >/dev/null
check_eq "$(cat "$BK_CONTEXT_FILE") $("$BK" context --json | jq -c '[.limit, .warn, .custom]')" "350000 [350000,262500,true]" "bk context 350k: lo guarda en tokens y vale"
check_eq "$("$BK" context 10k 2>&1 >/dev/null; echo "rc=$?")" "$(printf '«10k» no es un umbral: un número de tokens entre 50k y 2000k (200k, 350000, 1m)\nrc=1')" "bk context 10k: rechazado, código 1"
check_eq "$(cat "$BK_CONTEXT_FILE")" "350000" "un valor rechazado no pisa el umbral guardado"
"$BK" context default >/dev/null
check_eq "$([ -e "$BK_CONTEXT_FILE" ] && echo queda || echo borrado) $("$BK" context --json | jq -c .limit)" "borrado 200000" "bk context default: borra el archivo y vuelve a 200k"

echo "1..$N"
[ "$FAILED" -eq 0 ]
