#!/usr/bin/env bash
# bk _prs: baja de GitHub los PRs listos para mergear y las reviews pedidas a la caché que lee lib/checkpoints.py
# (bk checkpoints y "Te esperan" de bk monitor). Antes la bajaba el plugin de Sketchybar; sin la barra nadie la
# actualizaba. Acá bk ve un gh falso que anota lo que le piden y contesta lo que el test le deja: nada sale a
# GitHub, y HOME, la caché, el estado y las tareas son carpetas temporales.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
unset TMUX TMUX_PANE HC_TERMINAL_ID BK_ACCOUNT BK_ACCOUNT_CLAUDE BK_TASK_DIR BK_CHECKPOINTS_OFFLINE GH_RESP GH_RC
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" BK_STATE_DIR="$TMP/agents" BK_TASKS_DIR="$TMP/tasks" \
       BK_CACHE_DIR="$TMP/titles" BARRILETE_VAULT="$TMP/vault" GH_LOG="$TMP/gh.log" BK_BACKEND=tmux
CACHE="$TMP/cache/prs.json"; export BK_PRS_CACHE="$CACHE"   # la carpeta no existe: bk _prs la crea
mkdir -p "$HOME" "$TMP/fake" "$BK_STATE_DIR"
# gh falso: anota la llamada, imprime la respuesta que haya en GH_RESP y sale con GH_RC
printf '#!/bin/sh\necho "gh $*" >> "$GH_LOG"\n[ -n "${GH_RESP:-}" ] && cat "$GH_RESP"\nexit "${GH_RC:-0}"\n' >"$TMP/fake/gh"
chmod +x "$TMP/fake/gh"; : >"$GH_LOG"
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
bk()    { PATH="$TMP/fake:$PATH" "$ROOT/bin/bk" "$@"; }
ck()    { PATH="$TMP/fake:$PATH" python3 "$ROOT/lib/checkpoints.py" "$@"; }
calls() { grep -c '^gh api graphql' "$GH_LOG"; }
kinds() { jq -r '[.[] | "\(.kind):\(.number)"] | join(" ")' "$1" 2>/dev/null; }
old()   { touch -t "$(date -v-"$1"M +%Y%m%d%H%M.%S)" "$2"; }   # deja un archivo o carpeta con fecha de hace N minutos

# Lo que contesta GitHub: un PR por cada condición del filtro. Solo 1 y 7 están listos; 8 es una review pedida.
python3 - "$TMP/resp.json" <<'PY'
import json, sys, time
now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
REVIEW, ANTES, DESPUES = "2026-11-10T10:00:00Z", "2026-11-10T09:00:00Z", "2026-11-10T11:00:00Z"


def pr(n, title, reviews=1, decision=None, ci="SUCCESS", body="## Bloqueantes\nNinguno\n\n## Sugerencias\n- algo\n",
       commit=ANTES):
    return {"number": n, "title": title, "url": f"https://github.com/o/r/pull/{n}", "reviewDecision": decision,
            "updatedAt": now, "repository": {"nameWithOwner": "o/r"},
            "reviews": {"totalCount": reviews, "nodes": [{"body": body, "submittedAt": REVIEW}] if reviews else []},
            "commits": {"nodes": [{"commit": {"committedDate": commit or None,
                                              "statusCheckRollup": {"state": ci} if ci else None}}]}}


mine = [pr(1, "listo"),
        pr(2, "sin review", reviews=0, commit=""),   # sin fecha de commit: que lo frene no tener review, no las fechas
        pr(3, "cambios pedidos", decision="CHANGES_REQUESTED"),
        pr(4, "CI en rojo", ci="FAILURE"),
        pr(5, "con un bloqueante", body="## Bloqueantes\n- falta el test\n"),
        pr(6, "commit después de la review", commit=DESPUES),
        pr(7, "sin CI y review en inglés", ci=None, body="### Blocking\nNone\n\n### Suggestions\n- x\n")]
asked = [{"number": 8, "title": "revisame", "url": "https://github.com/o/otro/pull/8", "updatedAt": now,
          "repository": {"nameWithOwner": "o/otro"}}]
json.dump({"data": {"mine": {"nodes": mine}, "asked": {"nodes": asked}}}, open(sys.argv[1], "w"))
PY
echo '{"data": {"mine": {"nodes": []}, "asked": {"nodes": []}}}' >"$TMP/vacio.json"
echo '{"data": null, "errors": [{"message": "API rate limit exceeded"}]}' >"$TMP/error.json"

# --- el filtro: qué PRs llegan a la caché ---
GH_RESP="$TMP/resp.json" bk _prs; rc=$?
check_eq "$rc $(kinds "$CACHE")" "0 merge:1 merge:7 review:8" "bk _prs: solo los PRs listos (con review, sin cambios pedidos, CI verde, sin bloqueantes, sin commits después) y las reviews pedidas"
check_eq "$(jq -c '.[0]' "$CACHE" | jq -r '[.repo, .title, .url, (.updated | length | tostring)] | join("|")')" \
         "o/r|listo|https://github.com/o/r/pull/1|20" "bk _prs: cada PR con su repo, título, url y fecha"
check_eq "$(calls) $(grep -c 'author:@me archived:false draft:false' "$GH_LOG") $(grep -c 'review-requested:@me' "$GH_LOG")" "1 1 1" \
         "bk _prs: una sola consulta, por tus PRs que no son borrador y por las reviews que te pidieron"
check_eq "$([ -e "$CACHE.lock" ] || [ -e "$CACHE.tmp" ] && echo quedan || echo limpio)" "limpio" "bk _prs: no deja el candado ni el temporal"

# --- si GitHub no contesta bien, la caché queda como estaba ---
cp "$CACHE" "$TMP/antes.json"
GH_RC=1 bk _prs; rc=$?
check_eq "$rc $(cmp -s "$CACHE" "$TMP/antes.json" && echo igual)" "0 igual" "bk _prs: sin red (gh falla y no imprime nada) no toca la caché"
GH_RESP="$TMP/error.json" bk _prs
check_eq "$(cmp -s "$CACHE" "$TMP/antes.json" && echo igual) $([ -e "$CACHE.lock" ] || [ -e "$CACHE.tmp" ] && echo quedan || echo limpio)" \
         "igual limpio" "bk _prs: una respuesta con error tampoco, y suelta el candado"
GH_RESP="$TMP/vacio.json" bk _prs
check_eq "$(jq -c . "$CACHE")" "[]" "bk _prs: sin PRs que te esperen la caché queda vacía (un PR ya mergeado se va)"

# --- un solo fetch a la vez, y un candado abandonado no lo frena para siempre ---
: >"$GH_LOG"; mkdir "$CACHE.lock"
GH_RESP="$TMP/resp.json" bk _prs
check_eq "$(calls) $(jq -c . "$CACHE") $([ -d "$CACHE.lock" ] && echo sigue)" "0 [] sigue" "bk _prs: con otro fetch en curso no consulta ni toca su candado"
old 11 "$CACHE.lock"
GH_RESP="$TMP/resp.json" bk _prs
check_eq "$(calls) $(kinds "$CACHE") $([ -d "$CACHE.lock" ] && echo sigue || echo suelto)" "1 merge:1 merge:7 review:8 suelto" \
         "bk _prs: un candado de más de 10 min (una corrida que murió) se pisa"

# --- por defecto escribe donde checkpoints.py lee ---
lee=$(env -u BK_PRS_CACHE python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import checkpoints; print(checkpoints.PRS)' "$ROOT/lib")
(unset BK_PRS_CACHE; GH_RESP="$TMP/resp.json" bk _prs)
check_eq "$lee $(kinds "$lee")" "$HOME/.cache/bk/checkpoints_prs.json merge:1 merge:7 review:8" "sin BK_PRS_CACHE, bk _prs escribe la caché que lee checkpoints.py"

# --- el disparo: checkpoints.py pide los PRs cuando la caché es vieja ---
# lanza <veces> [args…]: corre checkpoints.py esa cantidad de veces en un mismo proceso (como el monitor, que
# refresca cada 2 s) con un Popen que solo anota, y dice cuántas veces lanzó algo y qué
lanza() {
  python3 - "$ROOT" "$@" <<'PY'
import contextlib, io, os, subprocess, sys
root, n, args = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
sys.path.insert(0, os.path.join(root, "lib"))
calls = []
subprocess.Popen = lambda *a, **k: calls.append(a[0])
import checkpoints as CK   # noqa: E402
with contextlib.redirect_stdout(io.StringIO()):
    for _ in range(n):
        CK.main(args)
print(len(calls), " ".join(os.path.relpath(c, root) if os.path.isabs(c) else c for c in (calls[0] if calls else [])))
PY
}
rm -f "$CACHE"
check_eq "$(lanza 1 --json)" "1 bin/bk _prs" "checkpoints: sin caché, lanza bk _prs"
check_eq "$(lanza 5)" "1 bin/bk _prs" "checkpoints: lo pide una vez cada tanto, no en cada refresco del monitor"
cp "$TMP/antes.json" "$CACHE"; old 3 "$CACHE"
check_eq "$(lanza 1)" "1 bin/bk _prs" "checkpoints: con la caché de hace más de 2 min, lanza bk _prs"
check_eq "$(lanza 1 --no-refresh)" "0 " "checkpoints --no-refresh: con la caché vieja no pide nada"
check_eq "$(BK_CHECKPOINTS_OFFLINE=1 lanza 1)" "0 " "checkpoints: con BK_CHECKPOINTS_OFFLINE tampoco"
touch "$CACHE"
check_eq "$(lanza 1)" "0 " "checkpoints: con la caché fresca no pide nada"

# De punta a punta: bk checkpoints con la caché vieja lanza el bk _prs de verdad (con el gh falso) y la próxima
# vez ya muestra los PRs
rm -f "$CACHE"; : >"$GH_LOG"
export GH_RESP="$TMP/resp.json"
primero=$(ck --json | jq -r '[.[] | "\(.kind):\(.number)"] | join(" ")')
for _ in $(seq 1 100); do [ -s "$CACHE" ] && [ ! -d "$CACHE.lock" ] && break; sleep 0.1; done
despues=$(ck --json | jq -r '[.[] | "\(.kind):\(.number)"] | join(" ")')
check_eq "[$primero] [$despues] $(calls)" "[] [review:8 merge:1 merge:7] 1" "bk checkpoints: sin caché no espera a GitHub, la pide en segundo plano y después lista los PRs"
check_eq "$(ck | grep -c 'gh pr merge 1 --squash --repo o/r')" "1" "bk checkpoints: cada PR listo con su comando"
unset GH_RESP

echo "1..$N"
[ "$FAILED" -eq 0 ]
