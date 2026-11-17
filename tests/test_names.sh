#!/usr/bin/env bash
# lib/names.py y su llamada desde hooks/agent_state.sh: el título de la pestaña y el estado de la barra salen de lo
# último del chat. hc, herdr-app y claude son falsos (BK_HC, BK_HERDR_APP, BK_NAMES_CLAUDE): no toca Herdr ni
# llama a un modelo. Caché, transcripts y el estado del hook en un directorio temporal.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }

mkdir -p "$TMP/bin"
# hc get <t> --json: las etiquetas de $TMP/labels.json · hc label <t> k=v…: se anotan en $TMP/hc.log
cat >"$TMP/bin/hc" <<EOF
#!/bin/bash
case "\$1" in
  get)   printf '{"address":"%s","labels":%s}\n' "\$2" "\$(cat "$TMP/labels.json")" ;;
  label) shift; echo "label \$*" >>"$TMP/hc.log" ;;
esac
EOF
# herdr-app ls: una pestaña tbX con el nombre de $TMP/tab · do …: se anota
cat >"$TMP/bin/herdr-app" <<EOF
#!/bin/bash
case "\$1" in
  ls) printf '{"spaces":[{"name":"abra","tabs":[{"id":"tbX","name":"%s"}]}]}\n' "\$(cat "$TMP/tab")" ;;
  do) shift; echo "do \$*" >>"$TMP/app.log" ;;
esac
EOF
# claude -p …: anota que lo llamaron y responde $TMP/reply
cat >"$TMP/bin/claude" <<EOF
#!/bin/bash
echo call >>"$TMP/claude.log"; cat "$TMP/reply"
EOF
chmod +x "$TMP/bin/"*
export BK_HC="$TMP/bin/hc" BK_HERDR_APP="$TMP/bin/herdr-app" BK_NAMES_CLAUDE="$TMP/bin/claude"
export XDG_CACHE_HOME="$TMP/cache" BK_NAMES_QUIET=0
unset BK_NAMES_OFF

T="$TMP/t.jsonl"
transcript() {  # transcript con el título viejo, un recap, un pedido y una respuesta (+ líneas extra en $1)
  {
    echo '{"type":"ai-title","aiTitle":"PR #1090 escáner de staff"}'
    echo '{"type":"user","message":{"role":"user","content":"revisá si ya desplegó Vercel"}}'
    echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"salida"}]}}'
    echo '{"type":"user","message":{"role":"user","content":"<local-command-stdout>aviso</local-command-stdout>"}}'
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Sí, desplegó el release #1095."}]}}'
    echo '{"type":"system","subtype":"away_summary","content":"Llevamos el release #1095 a producción."}'
    printf '%s' "${1:-}"
  } >"$T"
}
reset() {  # reset <etiquetas json> <nombre de la pestaña>
  rm -rf "$TMP/cache" "$TMP/hc.log" "$TMP/app.log" "$TMP/claude.log"
  printf '%s' "$1" >"$TMP/labels.json"; printf '%s' "$2" >"$TMP/tab"
  printf '{"titulo": "Release #1095 en producción.", "estado": "? Falta enviar el sitemap"}\n' >"$TMP/reply"
}
run() { python3 "$ROOT/lib/names.py" update s1 "$T" t9 "$@"; }
log() { cat "$TMP/$1" 2>/dev/null | tr '\n' '|'; }
CHAT='{"bk.kind":"chat","herdr.tab":"tbX"}'

# Lo que ve el modelo: el recap, el pedido de la persona y la respuesta; no el resultado de una herramienta
transcript
P=$(python3 "$ROOT/lib/names.py" show "$T")
check_eq "$(grep -c 'Llevamos el release #1095\|revisá si ya desplegó\|desplegó el release #1095' <<<"$P")" "3" "el prompt lleva recap, pedido y respuesta"
check_eq "$(grep -c 'salida' <<<"$P")" "0" "el prompt no lleva resultados de herramientas"
check_eq "$(grep -c 'aviso' <<<"$P")" "0" "el prompt no lleva salidas de comandos ni avisos del sistema (<…>)"

reset "$CHAT" "chat-3"
check_eq "$(run)" 'pestaña «Release #1095 en producción», bk.status=? Falta enviar el sitemap, bk.autotitle=Release #1095 en producción' \
  "pestaña automática (chat-3): la renombra, sin el punto final, y anota estado y título"
check_eq "$(log app.log)" 'do tab.rename {"id": "tbX", "name": "Release #1095 en producción"}|' "renombra la pestaña tbX"
check_eq "$(log hc.log)" 'label t9 bk.status=? Falta enviar el sitemap bk.autotitle=Release #1095 en producción|' "las etiquetas van a la terminal"

check_eq "$(run --now)" "sin cambios" "mismo transcript que la vez anterior: no vuelve a llamar al modelo"
check_eq "$(log claude.log)" "call|" "una sola llamada al modelo"

reset '{"bk.kind":"chat","herdr.tab":"tbX","bk.autotitle":"Viejo"}' "Viejo"
run >/dev/null
check_eq "$(log app.log | grep -c rename)" "1" "la pestaña tiene el título que pusimos antes: la renombra"

reset "$CHAT" "Lo mío"
check_eq "$(run)" 'bk.status=? Falta enviar el sitemap, bk.autotitle=Release #1095 en producción' \
  "pestaña renombrada a mano: no la toca, solo el estado y el título sugerido"

reset '{"bk.kind":"chat","herdr.tab":"tbX","bk.name":"deploy"}' "deploy"
check_eq "$(run)" 'bk.status=? Falta enviar el sitemap' "con bk name: solo el estado"
check_eq "$(log app.log)" "" "con bk name: no renombra la pestaña"

transcript '{"type":"custom-title","customTitle":"mi nombre"}'
reset "$CHAT" "chat-3"
check_eq "$(run)" 'bk.status=? Falta enviar el sitemap' "con /rename en Claude: solo el estado"
transcript

reset '{"bk.kind":"agent","herdr.tab":"tbX"}' "chat-3"
check_eq "$(run)" "no es un chat de bk" "un agente (no un chat): nada"
check_eq "$(log claude.log)" "" "un agente: no llama al modelo"

reset "$CHAT" "chat-3"
check_eq "$(BK_NAMES_OFF=1 run)" "apagado" "BK_NAMES_OFF=1 lo apaga"

reset "$CHAT" "chat-3"
( sleep 0.3; echo '{"type":"user","message":{"content":"otra cosa"}}' >>"$T" ) &
check_eq "$(BK_NAMES_QUIET=1 run)" "siguió trabajando" "si el chat sigue escribiendo en la espera: no nombra (lo hace el próximo Stop)"
wait; transcript

reset "$CHAT" "chat-3"; echo 'no sé' >"$TMP/reply"
check_eq "$(run)" "el modelo no respondió" "respuesta sin JSON: no cambia nada"
check_eq "$(log hc.log)$(log app.log)" "" "respuesta sin JSON: ni etiquetas ni pestaña"

reset "$CHAT" "chat-3"
printf '{"titulo": "%s", "estado": "ok"}\n' "$(printf 'x%.0s' $(seq 80))" >"$TMP/reply"
run >/dev/null
check_eq "$(sed -n 's/.*bk.autotitle=\(x*…\).*/\1/p' "$TMP/hc.log" | wc -m | tr -d ' ')" "41" "título largo: se corta a 40 con …"

# El hook: un Stop en una terminal de Herdr lanza names.py en segundo plano; sin terminal de Herdr, no
cat >"$TMP/bin/names.py" <<EOF
import sys; open("$TMP/names.log", "a").write(" ".join(sys.argv[1:]) + "\n")
EOF
hook() {  # hook <evento> [HC_TERMINAL_ID]
  printf '{"session_id":"s1","hook_event_name":"%s","cwd":"%s","transcript_path":"%s"}' "$1" "$TMP" "$T" \
    | env -u TMUX_PANE HOME="$TMP/home" BK_NAMES_PY="$TMP/bin/names.py" HC_TERMINAL_ID="${2:-}" bash "$ROOT/hooks/agent_state.sh"
}
mkdir -p "$TMP/home"; rm -f "$TMP/names.log"
hook Stop t9; hook Stop; hook UserPromptSubmit t9
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/names.log" ] && break; sleep 0.2; done
check_eq "$(cat "$TMP/names.log" 2>/dev/null)" "update s1 $T t9" "el hook lo lanza solo en Stop y en una terminal de Herdr"

echo "1..$N"
[ "$FAILED" -eq 0 ]
