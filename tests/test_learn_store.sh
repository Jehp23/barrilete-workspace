#!/usr/bin/env bash
# bk learn → store del proyecto (ws#11, ADR-007 del kit): los desvíos de una sesión de Claude Code y los hallazgos de las
# reviews caen en el store del proyecto donde pasaron, con el learning.py del kit, y pasan su validador.
# Todo en un HOME de prueba: no toca GitHub (gh falso), la red (git solo con file://), tu vault ni tu caché.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(mktemp -d); trap '[ -n "${KEEP:-}" ] || rm -rf "$TMP"' EXIT
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }

# El learning.py del kit, tal como está en su main (el adaptador usa el del proyecto, nunca uno propio)
KIT="${BK_KIT_REPO:-$HOME/barrilete-kit}"
LEARNING="$TMP/learning.py"
if ! git -C "$KIT" show origin/main:scripts/agents/learning.py >"$LEARNING" 2>/dev/null || ! grep -q 'def contexto' "$LEARNING"; then
  echo "1..0 # SKIP sin el learning.py del kit en $KIT (BK_KIT_REPO)"; exit 0
fi

export HOME="$TMP/home"; mkdir -p "$HOME"
export BARRILETE_VAULT="$TMP/vault"; mkdir -p "$BARRILETE_VAULT/agents"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_ALLOW_PROTOCOL=file          # el fetch de retros a github.com falla al toque, sin red
export BK_LEARN_TEST_CWD=1              # learn ignora las sesiones en /tmp (fixtures); acá son las de prueba
unset CLAUDECODE BK_HARNESS BARRILETE_MODEL BARRILETE_PROVIDER BK_PROVIDER
export BK_MODEL=claude-opus-9-9         # el de quien corre learn: no tiene que llegar a ningún evento
TASK="$TMP/task"; mkdir -p "$TASK"; echo '{"id": "99-reviewer", "role": "reviewer", "pr": 99}' >"$TASK/task.json"
export BK_TASK_DIR="$TASK"              # learn corriendo dentro de una tarea de bk: tampoco

# gh falso: el label del issue 7 y dos PRs con review (el 9 lo abrió la sesión de prueba; el 10, nadie que se sepa)
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "issue view 7 "*) echo '{"labels": [{"name": "type:bug"}, {"name": "area:infra"}]}' ;;
  "issue view 8 "*) echo x >>"$GH_CALLS"; exit 1 ;;   # gh que falla (sin red, sin auth)
  "issue view "*) echo '{"labels": []}' ;;
  "pr list "*) cat "$GH_PRS" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP/bin/gh"; export PATH="$TMP/bin:$PATH" GH_PRS="$TMP/prs.json" GH_CALLS="$TMP/gh-calls"
cat >"$GH_PRS" <<JSON
[{"number": 9, "headRefName": "claude/7-arreglar", "reviews": [{"id": "PRR_nueve", "submittedAt": "2099-01-01T09:00:00Z",
  "body": "### Bloqueantes\n1. \`[pr-metadata] PR\`: el cuerpo dice SECRETO_REVIEW y no coincide."}]},
 {"number": 10, "headRefName": "claude/8-otra", "reviews": [{"id": "PRR_diez", "submittedAt": "2099-01-01T09:00:00Z",
  "body": "### Bloqueantes\n1. \`[stale-docs] README\`: quedó viejo."}]}]
JSON

# El proyecto con el kit (origin en github, un worktree del issue 7) y uno sin el kit
P="$HOME/code/demo"; W="$HOME/code/demo-wt/7"; PLAIN="$HOME/code/plain"
mkdir -p "$P/scripts/agents" "$P/.barrilete" "$PLAIN"
cp "$LEARNING" "$P/scripts/agents/learning.py"; echo '{"store": "local"}' >"$P/.barrilete/learning.json"
git -C "$P" init -q -b main && git -C "$P" add -A && git -C "$P" commit -qm init
git -C "$P" remote add origin https://github.com/acme/demo.git
git -C "$P" worktree add -q -b claude/7-arreglar "$W"
git -C "$PLAIN" init -q -b main && git -C "$PLAIN" commit -q --allow-empty -m init
mkdir -p "$HOME/.config/bk"; echo "{\"repos\": [\"$P\"]}" >"$HOME/.config/bk/retros.json"

# Transcripts de Claude Code: en el worktree abre el PR del 9 y la persona lo corrige y lo interrumpe; en plain, una corrección
transcript() {  # archivo, cwd, rama, sesión
  python3 - "$@" <<'PY'
import json, sys
path, cwd, branch, sid = sys.argv[1:5]
base = {"cwd": cwd, "gitBranch": branch, "sessionId": sid}
def line(t, msg, ts):
    return json.dumps({**base, "type": t, "timestamp": ts, "message": msg}, separators=(",", ":"))
lines = [
    line("user", {"content": [{"type": "text", "text": "[Request interrupted by user]"}]}, "2020-01-01T00:00:00Z"),
    line("assistant", {"model": "claude-sonnet-5-5", "content": [{"type": "tool_use", "id": "toolu_1", "name": "Bash",
         "input": {"command": "gh pr create --title x --body y"}}]}, "2099-01-01T10:00:00.123Z"),
    line("user", {"content": "no, te dije que no toques SECRETO_PERSONA"}, "2099-01-01T10:01:00.000Z"),
    line("user", {"content": [{"type": "text", "text": "[Request interrupted by user]"}]}, "2099-01-01T10:02:00Z"),
    # la persona cambia de modelo y el agente solo nombra el comando: eso no es abrir el PR
    line("assistant", {"model": "claude-haiku-5-5", "content": [{"type": "text", "text": "el PR ya se abrió con gh pr create"}]},
         "2099-01-01T10:03:00Z"),
]
with open(path, "a") as f:
    f.write("\n".join(lines) + "\n")
PY
}
mkdir -p "$HOME/.claude/projects/demo" "$HOME/.claude/projects/plain"
transcript "$HOME/.claude/projects/demo/s1.jsonl" "$W" claude/7-arreglar aaaa1111-0000
transcript "$HOME/.claude/projects/plain/s2.jsonl" "$PLAIN" main bbbb2222-0000

learn() { python3 "$ROOT/lib/learn.py" --quiet "$@" 2>"$TMP/learn.err"; }
STORE="$P/.barrilete/learning/events.jsonl"
q() {  # filtro de python sobre los eventos del store → una línea
  python3 - "$STORE" "$1" <<'PY'
import json, sys
evs = []
try:
    evs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
except OSError:
    pass
print(eval(sys.argv[2], {"evs": evs, "dev": [e for e in evs if e.get("kind") == "deviation"],
                         "fin": [e for e in evs if e.get("kind") == "finding"]}))
PY
}

learn
check_eq "$(q 'len(dev)')" 2 "los desvíos de la sesión del proyecto con kit caen en su store, sin la historia de antes de la primera corrida"
check_eq "$(cat "$TMP/learn.err")" "" "learn no dice nada en stderr"
check_eq "$(python3 "$P/scripts/agents/learning.py" validate "$STORE" | cut -d' ' -f1)" ok: "el store pasa el validador del kit"
check_eq "$(q 'sorted(e["class"] for e in dev)')" "['interrupt', 'user-correction']" "class es el tipo del desvío, como slug"
check_eq "$(q '{e["model"] for e in dev}')" "{'claude-sonnet-5-5'}" "model es el de la sesión, no el de quien corre learn"
check_eq "$(q '{e["harness"] for e in evs}')" "{'claude-code'}" "harness claude-code siempre"
check_eq "$(q '{e["project"] for e in evs}')" "{'demo'}" "project es el repo del proyecto"
check_eq "$(q '{e.get("area") for e in dev}')" "{'infra'}" "area sale del label area: del issue de la rama"
check_eq "$(q 'sorted(e["ts"] for e in dev)')" "['2099-01-01T10:01:00.000Z', '2099-01-01T10:02:00Z']" "ts es el del desvío, no el de la corrida"
check_eq "$(q '{e.get("evidence_ref") for e in dev}')" "{'~/.claude/projects/demo/s1.jsonl'}" "evidence_ref es la ruta del transcript, relativa a ~"
check_eq "$(q '[k for e in evs for k in ("task_id", "rules_ref", "pr") if k in e and e["kind"] == "deviation"]')" "[]" "sin task_id, rules_ref ni pr de la tarea de quien corre learn"
check_eq "$(grep -c SECRETO "$STORE")" 0 "ningún texto de la persona ni de la review en el store"
check_eq "$(grep -h '"project": "demo#7"' "$BARRILETE_VAULT"/agents/data/events-*.jsonl | grep -c SECRETO_PERSONA)" 1 "el texto sigue en el vault (vista personal)"
check_eq "$(grep -c '"_' "$BARRILETE_VAULT"/agents/data/events-*.jsonl | awk -F: '{s+=$NF} END {print s}')" 0 "el vault no se lleva los campos internos del adaptador"
check_eq "$([ -e "$W/.barrilete/learning" ] && echo si || echo no)" no "desde el worktree escribe en el checkout principal"
check_eq "$([ -e "$PLAIN/.barrilete/learning" ] && echo si || echo no)" no "un proyecto sin el kit no recibe nada"
check_eq "$(grep -h '"project": "plain"' "$BARRILETE_VAULT"/agents/data/events-*.jsonl | grep -c user_correction)" 1 "el desvío del proyecto sin kit queda solo en el vault"

check_eq "$(q 'len(fin)')" 2 "los hallazgos de las reviews caen como finding"
check_eq "$(q '{e["pr"]: e["class"] for e in fin}')" "{9: 'pr-metadata', 10: 'stale-docs'}" "finding lleva el pr y la clase de classes.yml"
check_eq "$(q '{e["pr"]: e["model"] for e in fin}')" "{9: 'claude-sonnet-5-5', 10: 'unknown'}" "finding lleva el modelo de la sesión que corrió gh pr create (no la que solo lo nombra), o unknown"
check_eq "$(q '{e["pr"]: e["evidence_ref"] for e in fin}')" "{9: 'https://github.com/acme/demo/pull/9', 10: 'https://github.com/acme/demo/pull/10'}" "evidence_ref del hallazgo es la URL del PR"
check_eq "$(q '{e["pr"]: e.get("area") for e in fin}')" "{9: 'infra', 10: None}" "area del hallazgo sale del issue de la rama del PR"
check_eq "$(q '{e.get("role") for e in fin}')" "{'implementer'}" "el hallazgo es del implementer"

# Otra corrida sin nada nuevo, y una reconstrucción del vault: nada se duplica
learn; learn --rebuild
check_eq "$(q 'len(evs)')" 4 "ni otra corrida ni --rebuild duplican eventos"

# Un desvío nuevo después llega en la próxima corrida
python3 - "$HOME/.claude/projects/demo/s1.jsonl" "$W" <<'PY'
import json, sys
with open(sys.argv[1], "a") as f:
    f.write(json.dumps({"cwd": sys.argv[2], "gitBranch": "claude/7-arreglar", "sessionId": "aaaa1111-0000", "type": "user",
                        "timestamp": "2099-01-01T11:00:00Z",
                        "message": {"content": [{"type": "text", "text": "[Request interrupted by user]"}]}},
                       separators=(",", ":")) + "\n")
PY
learn
check_eq "$(q 'len(dev)')" 3 "un desvío nuevo cae en la próxima corrida"

# Un store roto (learning.json inválido) no frena learn ni el vault
echo '{"store": "nube"}' >"$P/.barrilete/learning.json"
python3 - "$HOME/.claude/projects/demo/s1.jsonl" "$W" <<'PY'
import json, sys
with open(sys.argv[1], "a") as f:
    f.write(json.dumps({"cwd": sys.argv[2], "gitBranch": "claude/7-arreglar", "sessionId": "aaaa1111-0000", "type": "user",
                        "timestamp": "2099-01-01T12:00:00Z",
                        "message": {"content": [{"type": "text", "text": "[Request interrupted by user]"}]}},
                       separators=(",", ":")) + "\n")
PY
learn; rc=$?
check_eq "$rc" 0 "con un store inválido learn termina bien"
check_eq "$(grep -c '2099-01-01T12:00:00Z' "$BARRILETE_VAULT"/agents/data/events-*.jsonl | awk -F: '{s+=$NF} END {print s}')" 1 "y el desvío queda en el vault"

# Si gh falla, se prueba una sola vez por issue en la corrida (cada intento puede esperar 30 s), y en la próxima de nuevo
: >"$GH_CALLS"
check_eq "$(BK_LEARN_STORE_STATE="$TMP/st-gh.json" python3 -c "
import sys; sys.path.insert(0, '$ROOT/lib'); import learn_store as L
s = L.Store(); print([s.area('$P', 8) for _ in range(3)])")" "['', '', '']" "con gh caído el area queda vacía"
check_eq "$(wc -l <"$GH_CALLS" | tr -d ' ')" 1 "con gh caído, una sola llamada por issue en la corrida"
check_eq "$(python3 -c "import json; print('acme/demo#8' in json.load(open('$TMP/st-gh.json')).get('areas', {}))" 2>/dev/null || echo False)" False \
  "el fallo de gh no queda en la caché: se reintenta en otra corrida"

# El recorte de los ya enviados se queda con los más nuevos, no con los de hash más alto
kept=$(BK_LEARN_STORE_STATE="$TMP/st-max.json" python3 - "$ROOT/lib" <<'PY2'
import sys
sys.path.insert(0, sys.argv[1])
import learn_store as L
L.SENT_MAX = 2
s = L.Store()
s.sent = {"a": "2099-01-03T00:00:00Z", "z": "2099-01-01T00:00:00Z", "m": "2099-01-02T00:00:00Z"}
s.save()
print(sorted(L.Store().sent))
PY2
)
check_eq "$kept" "['a', 'm']" "al recortar los enviados quedan los más nuevos"

echo "1..$N"; [ "$FAILED" -eq 0 ]
