#!/usr/bin/env bash
# lib/handoff.py, el aviso rojo de context_hook.py y bk chat --desde / bk handoff: el resumen para seguir en un chat
# nuevo. Todo en un directorio temporal (BK_HANDOFF_DIR): no toca ~/.local ni abre workspaces (bk --dry-run).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
export BK_HANDOFF_DIR="$TMP/h" BK_CONTEXT_HOOK_STATE="$TMP/state" BK_CONTEXT_FILE="$TMP/context"
unset TMUX TMUX_PANE HC_TERMINAL_ID BK_ACCOUNT BK_ACCOUNT_CLAUDE
export BK_BACKEND=tmux   # este test no cambia HOME: que no lea tu ~/.config/bk/backend
# Un tmux falso para bk: si algo se escapa del --dry-run (el 2026-11-05 un caso roto abrió cuatro workspaces
# reales), falla acá y queda anotado en vez de abrir chats en tu tmux
mkdir -p "$TMP/fake"; printf '#!/bin/sh\necho "$*" >> "%s/tmux.log"\nexit 1\n' "$TMP" >"$TMP/fake/tmux"; chmod +x "$TMP/fake/tmux"
: >"$TMP/tmux.log"
bk() { PATH="$TMP/fake:$PATH" "$ROOT/bin/bk" "$@"; }
H="$ROOT/lib/handoff.py"
N=0; FAILED=0
ok()  { N=$((N+1)); echo "ok $N - $1"; }
bad() { N=$((N+1)); echo "not ok $N - $1"; FAILED=$((FAILED+1)); }
check_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (no está «$2»)" ;; esac; }

REPO="$TMP/repo"; git init -q -b rama-x "$REPO"

# El aviso rojo pide el archivo con la plantilla
T="$TMP/t.jsonl"
printf '{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":0,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":410000}}}\n' >"$T"
out=$(printf '{"session_id":"s-rojo","transcript_path":"%s","hook_event_name":"UserPromptSubmit","cwd":"%s"}' "$T" "$REPO" \
      | python3 "$ROOT/lib/context_hook.py")
ctx=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["hookSpecificOutput"]["additionalContext"])' "$out" 2>/dev/null)
has "$ctx" "$TMP/h/s-rojo.md" "el rojo nombra el archivo del handoff de esa sesión"
for sec in "## Hecho" "## Falta (en orden)" "1. Primer paso:" "## Te espera a vos" "## No tocar" "## Archivos y comandos"; do
  has "$ctx" "$sec" "el rojo trae la plantilla: $sec"
done
has "$ctx" "De dónde: sesión s-rojo · fuera de un workspace · rama rama-x en $REPO · cuenta default" "la línea «De dónde» la completa bk (rama, carpeta, cuenta)"
has "$ctx" "bk chat --desde s-rojo" "el rojo dice cómo seguir"
has "$ctx" "BK_TASK_DIR" "un agente de bk sigue terminando con bk done"
[ -f "$TMP/h/s-rojo.json" ] && ok "el rojo deja el .json de dónde viene" || bad "el rojo deja el .json"
check_eq "$(BK_ACCOUNT_CLAUDE=otra python3 "$H" pedido --sid s-cta --cwd "$REPO" | grep -o 'cuenta [a-z]*' | head -1)" "cuenta otra" "la cuenta sale de BK_ACCOUNT_CLAUDE"

# find / take / list
python3 "$H" find s-rojo >/dev/null; check_eq "$?" "1" "sin el .md, no hay resumen listo"
printf '# Seguir desde ws 5: acentos ñ y `backticks` $(no) "comillas"\n- línea 2\n' >"$TMP/h/s-rojo.md"
python3 - "$TMP/h/s-rojo.json" <<'PY'
import json, sys; p = sys.argv[1]; m = json.load(open(p)); m.update(ws="5", session="bk-proj-3", name="mejoras"); json.dump(m, open(p, "w"))
PY
check_eq "$(python3 "$H" find s-rojo | cut -f1,2,3,4)" "s-rojo	$REPO	default	bk-proj-3" "find por sesión de Claude: sid, carpeta, cuenta y workspace"
check_eq "$(python3 "$H" find 5 | cut -f1)" "s-rojo" "find por número de workspace"
check_eq "$(python3 "$H" find 'ws 5' | cut -f1)" "s-rojo" "find con «ws 5»"
check_eq "$(python3 "$H" find bk-proj-3 | cut -f1)" "s-rojo" "find por nombre de la sesión de tmux"
python3 "$H" find 6 >/dev/null; check_eq "$?" "1" "otro número: no"
python3 "$H" pedido --sid s-sinws --cwd "$REPO" >/dev/null; printf 'x\n' >"$TMP/h/s-sinws.md"
python3 "$H" find "" >/dev/null; check_eq "$?" "1" "vacío: no agarra uno sin número de workspace"
check_eq "$(python3 "$H" find - | cut -f1)" "" "«-»: tampoco"
rm "$TMP/h/s-sinws".*
check_eq "$(python3 "$H" list)" "s-rojo	5	bk-proj-3	mejoras" "list: los listos"
check_eq "$(cd "$ROOT/lib" && python3 -c 'import new; print([i[2] for i in new.build_items(None, []) if i[0] == "desde"][0])')" "↪ Seguir desde ws 5 «mejoras» · repo" "alt+n ofrece «Seguir desde ws 5»"

# bk chat --desde: el comando del chat nuevo le pasa el resumen entero a claude y lo borra
row=$(bk --dry-run chat --desde 5)
check_eq "$(cut -f1,2,3 <<<"$row")" "bk-repo-2	$REPO	default" "bk chat --desde 5: un workspace más del proyecto, en la carpeta y con la cuenta del resumen"
want=$(cat "$TMP/h/s-rojo.md")
mkdir "$TMP/bin"; printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/args"\n' "$TMP" >"$TMP/bin/claude"; chmod +x "$TMP/bin/claude"
PATH="$TMP/bin:$PATH" sh -c "$(cut -f4 <<<"$row")"
check_eq "$(head -1 "$TMP/args")" "--" "claude recibe el resumen después de --"
check_eq "$(tail -n +2 "$TMP/args")" "$want" "claude recibe el resumen completo, con acentos, backticks y \$()"
[ ! -e "$TMP/h/s-rojo.md" ] && [ ! -e "$TMP/h/s-rojo.json" ] && ok "al tomarlo se borra (.md y .json)" || bad "al tomarlo se borra"
PATH="$TMP/bin:$PATH" sh -c "$(cut -f4 <<<"$row")"
check_eq "$(cat "$TMP/args")" "" "si ya lo tomó otro, claude arranca vacío"
err=$(bk --dry-run chat --desde 5 2>&1); rc=$?
check_eq "$rc" "1" "bk chat --desde sin resumen listo: falla"
has "$err" "no hay un resumen listo" "y dice por qué"
printf 'x\n' >"$TMP/h/s-cta.md"
python3 "$H" pedido --sid s-cta2 --cwd "$REPO" >/dev/null; printf 'x\n' >"$TMP/h/s-cta2.md"
sed -i '' 's/"account": "default"/"account": "otra"/' "$TMP/h/s-cta2.json"
check_eq "$(bk --dry-run chat --desde s-cta2 | cut -f3)" "otra" "--desde usa la cuenta del chat viejo"
check_eq "$(BK_ACCOUNT=default bk --dry-run chat --desde s-cta2 | cut -f3)" "default" "bk --account X chat --desde: manda la que pediste"

# Viejos sin resumen: se borran a las dos semanas
python3 "$H" pedido --sid s-viejo --cwd "$REPO" >/dev/null
touch -t 202001010000 "$TMP/h/s-viejo.json"; python3 "$H" list >/dev/null
[ ! -e "$TMP/h/s-viejo.json" ] && ok "un .json de hace dos semanas sin resumen se borra" || bad "el .json viejo se borra"

# bk handoff --pedido: el mismo pedido, para que lo corra el agente
has "$(bk handoff --pedido --sid s-man)" "$TMP/h/s-man.md" "bk handoff --pedido --sid: el pedido con el archivo de esa sesión"
check_eq "$(bk handoff --pedido >/dev/null 2>&1; echo $?)" "1" "bk handoff --pedido sin sesión ni pane: falla"

# Las marcas: la tira (sidebar.ready_ws) y bk s (sessions.mark_handoffs) con ↪ el chat que dejó un resumen
printf 'x\n' >"$TMP/h/s-marca.md"; python3 "$H" pedido --sid s-marca --cwd "$REPO" >/dev/null
check_eq "$(cd "$ROOT/lib" && python3 -c 'import sidebar as S, handoff as H; print(sorted(S.ready_ws([("bk-a", "s-marca"), ("bk-b", "otra"), ("bk-c", None)], H.ready_sids())))')" "['bk-a']" "la tira marca solo el workspace cuyo chat dejó el resumen"
check_eq "$(cd "$ROOT/lib" && python3 -c 'import sessions as S, handoff as H; print([r["handoff"] for r in S.mark_handoffs([{"sid": "s-marca"}, {"sid": "otra"}, {"sid": None}], H.ready_sids())])')" "[True, False, False]" "bk s marca la fila de esa sesión"
rm "$TMP/h/s-marca.md"
check_eq "$(cd "$ROOT/lib" && python3 -c 'import sessions as S, handoff as H; print(S.mark_handoffs([{"sid": "s-marca"}], H.ready_sids())[0]["handoff"])')" "False" "sin el .md (ya lo tomaron), sin marca"

# Quién lo pidió (via): bk handoff es la persona; el aviso rojo, el aviso. `listo` lo dice una sola vez
via() { jq -r '.via' "$TMP/h/$1.json"; }
has "$(python3 "$H" pedido --sid s-via --cwd "$REPO")" "bk abre solo el chat nuevo" "pedido por la persona: dice que el chat nuevo se abre solo"
check_eq "$(via s-via)" "persona" "bk handoff anota que lo pidió la persona"
case "$ctx" in *"bk abre solo"*) bad "el rojo no promete abrir solo" ;; *) ok "el rojo no promete abrir solo" ;; esac
rojo() { printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"UserPromptSubmit","cwd":"%s"}' "$1" "$T" "$REPO" | python3 "$ROOT/lib/context_hook.py" >/dev/null; }
rojo s-via; check_eq "$(via s-via)" "persona" "el rojo no pisa un pedido de la persona que todavía no se escribió"
rojo s-via2; check_eq "$(via s-via2)" "aviso" "el rojo anota que lo pidió el aviso"
python3 "$H" pedido --sid s-via2 --cwd "$REPO" >/dev/null; check_eq "$(via s-via2)" "persona" "bk handoff después del rojo: pasa a ser de la persona"
python3 "$H" listo s-via >/dev/null; check_eq "$?" "1" "listo sin el .md: no"
printf 'x\n' >"$TMP/h/s-via.md"
check_eq "$(python3 "$H" listo s-via)" "persona	s-via" "listo con el .md: quién lo pidió y de dónde"
python3 "$H" listo s-via >/dev/null; check_eq "$?" "1" "listo otra vez (el agente volvió a guardar): no repite"
: >"$TMP/h/s-via2.md"; python3 "$H" listo s-via2 >/dev/null; check_eq "$?" "1" "listo con el .md vacío: no"
printf 'x\n' >"$TMP/h/s-sinjson.md"; python3 "$H" listo s-sinjson >/dev/null; check_eq "$?" "1" "listo sin .json (nadie lo pidió): no"
rm "$TMP/h/s-sinjson.md" "$TMP/h/s-via2.md"

# El hook: cuando el agente guarda (Write) el resumen de su sesión, corre bk handoff --listo <sesión>
printf '#!/bin/sh\necho "$*" >> "%s/bk.log"\n' "$TMP" >"$TMP/fake/bk-falso"; chmod +x "$TMP/fake/bk-falso"; : >"$TMP/bk.log"
post() {   # post <sesión> <herramienta> <archivo>
  printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"PostToolUse","tool_name":"%s","tool_input":{"file_path":"%s"},"cwd":"%s"}' "$1" "$TMP/no-hay.jsonl" "$2" "$3" "$REPO" \
    | BK_HANDOFF_BK="$TMP/fake/bk-falso" python3 "$ROOT/lib/context_hook.py" >/dev/null
}
post s-hook Write "$TMP/h/otra-sesion.md"; post s-hook Write "$REPO/s-hook.md"; post s-hook Read "$TMP/h/s-hook.md"
sleep 1; check_eq "$(cat "$TMP/bk.log")" "" "el hook no dispara por otro archivo, el resumen de otra sesión ni por leerlo"
post s-hook Write "$TMP/h/s-hook.md"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/bk.log" ] && break; sleep 0.2; done
check_eq "$(cat "$TMP/bk.log")" "handoff --listo s-hook" "el hook corre bk handoff --listo cuando el agente guarda el resumen"

# bk handoff --listo con tmux, fuera de tmux: no abre nada (queda listo como siempre)
python3 "$H" pedido --sid s-fuera --cwd "$REPO" >/dev/null; printf 'x\n' >"$TMP/h/s-fuera.md"
bk handoff --listo s-fuera >/dev/null 2>&1
check_eq "$(grep -c 'new-session' "$TMP/tmux.log") $([ -f "$TMP/h/s-fuera.md" ] && echo sigue)" "0 sigue" "bk handoff --listo fuera de tmux: no abre un workspace y el resumen sigue listo"
rm -f "$TMP/h/s-fuera".* "$TMP/h/s-via".* "$TMP/h/s-via2".*
check_eq "$(grep -c 'new-session' "$TMP/tmux.log")" "0" "ningún caso intentó abrir un workspace"

echo "1..$N"
[ "$FAILED" -eq 0 ]
