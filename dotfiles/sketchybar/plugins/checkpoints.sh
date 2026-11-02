#!/bin/bash
# Los dos nudos humanos de Barrilete Kit:
#   1. Planes esperando tu "sí"  -> sesiones con phase=plan_pending y el turno terminado (local, instantáneo)
#   2. PRs listos para mergear   -> tuyos, abiertos, no draft, CI verde, con >=1 review y sin cambios pedidos
#      (/review-pr nunca aprueba: la review es un comentario). Se consulta a GitHub cada ~2 min, con caché.
# Item: agents.ckpt (se oculta si no hay nada), popup: agents.ckpt.N

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
[ "$(cat "$HOME/.cache/sketchybar/mode" 2>/dev/null || echo work)" != "work" ] && exit 0  # solo en work (chill/uni: no prender nada)
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/sketchybar}"
source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/icons.sh"

AGENTS_DIR="$HOME/.cache/sketchybar/agents"
CACHE="$HOME/.cache/sketchybar/checkpoints_prs.json"
mkdir -p "$AGENTS_DIR"

if [ "$SENDER" = "mouse.clicked" ]; then
  sketchybar --set agents.ckpt popup.drawing=toggle
fi

# Lock: dos corridas a la vez reconstruían el popup en paralelo ("agents.ckpt.N already exists")
LOCK_UI="${TMPDIR:-/tmp}/sketchybar_ckpt_ui.lock"
for _ in $(seq 1 60); do
  mkdir "$LOCK_UI" 2>/dev/null && break
  LOCK_TS=$(stat -f %m "$LOCK_UI" 2>/dev/null) && [ $(( $(date +%s) - LOCK_TS )) -gt 30 ] && rmdir "$LOCK_UI" 2>/dev/null
  sleep 0.05
done
trap 'rmdir "$LOCK_UI" 2>/dev/null' EXIT

# ---- PRs listos (caché de 110 s; un solo fetch a la vez, en segundo plano si hay caché) ----
fetch_prs() {
  local lock="${TMPDIR:-/tmp}/sketchybar_ckpt_fetch.lock"
  mkdir "$lock" 2>/dev/null || return 0
  # kind=merge: tuyos listos para mergear · kind=review: te pidieron review (también es un nudo humano)
  gh api graphql -f query='
    { mine: search(query: "is:pr is:open author:@me archived:false draft:false", type: ISSUE, first: 30) {
        nodes { ... on PullRequest {
          number title url reviewDecision
          repository { nameWithOwner }
          reviews(last: 1) { totalCount nodes { body submittedAt } }
          commits(last: 1) { nodes { commit { committedDate statusCheckRollup { state } } } }
        } } }
      asked: search(query: "is:pr is:open review-requested:@me archived:false", type: ISSUE, first: 20) {
        nodes { ... on PullRequest { number title url repository { nameWithOwner } } } } }' 2>/dev/null \
  | jq '[(.data.mine.nodes[]
          # /review-pr publica siempre como comentario, aunque tenga bloqueantes: hay que leer la última
          # review. Listo = CI verde, última review sin sección "Bloqueante/Blocking" y sin commits
          # posteriores a esa review (si hubo arreglos, el kit pide revisar de nuevo).
          | .reviews.nodes[0] as $r
          | .commits.nodes[0].commit as $c
          | select(.reviews.totalCount > 0
                   and .reviewDecision != "CHANGES_REQUESTED"
                   and ($c.statusCheckRollup.state // "SUCCESS") == "SUCCESS"
                   # La sección existe siempre: bloquea solo si no dice "Ninguno/None"
                   and (($r.body // "") | test("(^|\\n)#+\\s*(Bloqueantes?|Blocking|Blockers?)\\b[^\\n]*\\n\\s*(?!(Ningun[oa]|None|No hay|Sin bloqueantes)\\b)\\S"; "i") | not)
                   and (($c.committedDate // "") <= ($r.submittedAt // "")))
          | {kind: "merge", repo: .repository.nameWithOwner, number, title, url}),
         (.data.asked.nodes[] | {kind: "review", repo: .repository.nameWithOwner, number, title, url})]' \
    > "$CACHE.tmp" 2>/dev/null \
    && [ -s "$CACHE.tmp" ] && mv "$CACHE.tmp" "$CACHE"
  rm -f "$CACHE.tmp"
  # Mismo ritmo (~2 min): registrar desvíos y proponer lecciones (incremental, ~50 ms)
  [ -x "$LEARN" ] && python3 "$LEARN" --quiet >/dev/null 2>&1
  rmdir "$lock" 2>/dev/null
  sketchybar --trigger agent_update >/dev/null 2>&1
}
LEARN="$HOME/barrilete-workspace/lib/learn.py"
LESSONS_DIR="${BARRILETE_VAULT:-$HOME/Documents/Obsidian Vault}/agents/lessons"

AGE=999999
[ -f "$CACHE" ] && AGE=$(( $(date +%s) - $(stat -f %m "$CACHE") ))
if [ "$AGE" -gt 110 ] || [ "$SENDER" = "forced" ] || [ "$SENDER" = "system_woke" ]; then
  if [ -f "$CACHE" ]; then fetch_prs >/dev/null 2>&1 & else fetch_prs; fi
fi
PRS=$(cat "$CACHE" 2>/dev/null || echo '[]')

# ---- Planes esperando aprobación ----
FILES=("$AGENTS_DIR"/*.json)
if [ -e "${FILES[0]}" ]; then
  PLANS=$(jq -s '[.[] | select(.phase=="plan_pending" and (.state=="done" or .state=="idle"))
                  | {cwd, ts}] | sort_by(-.ts)' "${FILES[@]}" 2>/dev/null || echo '[]')
else
  PLANS='[]'
fi

NP=$(printf '%s' "$PLANS" | jq length)
# Caché viejo (array sin "kind") cuenta como merge
NR=$(printf '%s' "$PRS" | jq '[.[] | select((.kind // "merge") == "merge")] | length')
NV=$(printf '%s' "$PRS" | jq '[.[] | select(.kind == "review")] | length')

# ---- Lecciones propuestas por revisar (vault de Obsidian) ----
LESSONS=()
for f in "$LESSONS_DIR"/*.md; do
  [ -e "$f" ] && grep -q '^status:[[:space:]]*proposed' "$f" && LESSONS+=("$f")
done
NL=${#LESSONS[@]}

if [ "$NP" -eq 0 ] && [ "$NR" -eq 0 ] && [ "$NV" -eq 0 ] && [ "$NL" -eq 0 ]; then
  sketchybar --set agents.ckpt drawing=off popup.drawing=off
  sketchybar --remove '/agents\.ckpt\.[0-9]*/' >/dev/null 2>&1
  exit 0
fi

# Compacto: 󰀦 N planes · 󰘬 N PRs (el detalle en el popup)
LABEL=""
[ "$NP" -gt 0 ] && LABEL+="$ICON_WAIT $NP  "
[ "$NR" -gt 0 ] && LABEL+="$ICON_PR $NR  "
[ "$NV" -gt 0 ] && LABEL+="$ICON_EYE $NV  "
[ "$NL" -gt 0 ] && LABEL+="$ICON_LESSON $NL"
LABEL="${LABEL%  }"
sketchybar --set agents.ckpt drawing=on icon.drawing=off label="$LABEL" label.color=$MAUVE \
           background.border_width=2 background.border_color=$MAUVE

# ---- Popup ----
sketchybar --remove '/agents\.ckpt\.[0-9]*/' >/dev/null 2>&1
i=0
# Filas compactas y sin píldora de fondo: "<qué> · <dónde> · <título>"
ROW=(background.drawing=off icon.padding_left=10 label.padding_right=12)
cut_to() { local s="$1" n="$2"; [ ${#s} -gt "$n" ] && echo "${s:0:$((n-1))}…" || echo "$s"; }

while IFS=$'\t' read -r CWD; do
  sketchybar --add item agents.ckpt.$i popup.agents.ckpt \
             --set agents.ckpt.$i "${ROW[@]}" icon="$ICON_WAIT" icon.color=$MAUVE \
                   label="plan por aprobar · $(basename "$CWD")" \
                   click_script="open \"$CWD\"; sketchybar --set agents.ckpt popup.drawing=off"
  i=$((i+1))
done < <(printf '%s' "$PLANS" | jq -r '.[] | [.cwd] | @tsv')

while IFS=$'\t' read -r KIND REPO NUM TITLE URL; do
  if [ "$KIND" = "review" ]; then IC=$ICON_EYE; C=$PEACH; WHAT="review"
  else IC=$ICON_PR; C=$GREEN; WHAT="mergear"; fi
  sketchybar --add item agents.ckpt.$i popup.agents.ckpt \
             --set agents.ckpt.$i "${ROW[@]}" icon="$IC" icon.color=$C \
                   label="$WHAT · ${REPO#*/} #$NUM · $(cut_to "$TITLE" 38)" \
                   click_script="open \"$URL\"; sketchybar --set agents.ckpt popup.drawing=off"
  i=$((i+1))
done < <(printf '%s' "$PRS" | jq -r '.[] | [(.kind // "merge"), .repo, (.number|tostring), .title, .url] | @tsv')

for f in "${LESSONS[@]}"; do
  # Título real de la nota (su primer "# "), no el nombre de archivo
  TITLE_L=$(sed -nE 's/^# (.+)$/\1/p' "$f" | head -1)
  [ -z "$TITLE_L" ] && TITLE_L=$(basename "$f" .md)
  SCOPE_L=$(sed -nE 's/^scope:[[:space:]]*([^[:space:]#]+).*/\1/p' "$f" | head -1)
  ENC=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$f")
  sketchybar --add item agents.ckpt.$i popup.agents.ckpt \
             --set agents.ckpt.$i "${ROW[@]}" icon="$ICON_LESSON" icon.color=$YELLOW \
                   label="lección · ${SCOPE_L:-global} · $(cut_to "$TITLE_L" 38)" \
                   click_script="open \"obsidian://open?path=$ENC\"; sketchybar --set agents.ckpt popup.drawing=off"
  i=$((i+1))
done
