#!/bin/bash
# Los nudos humanos de Barrilete Kit (la lista sale de lib/checkpoints.py, la misma que bk checkpoints):
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
          number title url reviewDecision updatedAt
          repository { nameWithOwner }
          reviews(last: 1) { totalCount nodes { body submittedAt } }
          commits(last: 1) { nodes { commit { committedDate statusCheckRollup { state } } } }
        } } }
      asked: search(query: "is:pr is:open review-requested:@me archived:false", type: ISSUE, first: 20) {
        nodes { ... on PullRequest { number title url updatedAt repository { nameWithOwner } } } } }' 2>/dev/null \
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
          | {kind: "merge", repo: .repository.nameWithOwner, number, title, url, updated: .updatedAt}),
         (.data.asked.nodes[] | {kind: "review", repo: .repository.nameWithOwner, number, title, url, updated: .updatedAt})]' \
    > "$CACHE.tmp" 2>/dev/null \
    && [ -s "$CACHE.tmp" ] && mv "$CACHE.tmp" "$CACHE"
  rm -f "$CACHE.tmp"
  # Mismo ritmo (~2 min): registrar desvíos y proponer lecciones (incremental, ~50 ms)
  [ -x "$LEARN" ] && python3 "$LEARN" --quiet >/dev/null 2>&1
  # Foto de workspaces y agentes para bk restore (sola se limita a una cada ~5 min si nada cambió)
  python3 "$HOME/barrilete-workspace/lib/snapshot.py" save --auto >/dev/null 2>&1
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
# ---- Lo que te espera: una sola fuente (lib/checkpoints.py, la misma lista que bk checkpoints y bk monitor) ----
# --no-refresh: este plugin es el que actualiza los PRs (fetch_prs); si no, se pediría a sí mismo.
CK=$(python3 "$HOME/barrilete-workspace/lib/checkpoints.py" --json --no-refresh 2>/dev/null)
printf '%s' "$CK" | jq -e 'type == "array"' >/dev/null 2>&1 || CK='[]'
count() { printf '%s' "$CK" | jq --arg k "$1" '[.[] | select(.kind == $k)] | length'; }
NP=$(count plan); NA=$(count reviewer); NV=$(count review); NR=$(count merge); NL=$(count lesson)

if [ "$NP" -eq 0 ] && [ "$NA" -eq 0 ] && [ "$NR" -eq 0 ] && [ "$NV" -eq 0 ] && [ "$NL" -eq 0 ]; then
  sketchybar --set agents.ckpt drawing=off popup.drawing=off
  sketchybar --remove '/agents\.ckpt\.[0-9]*/' >/dev/null 2>&1
  exit 0
fi

# Compacto: 󰀦 planes y reviewers propuestos · 󰈈 reviews · 󰘬 PRs · 󰌵 lecciones (el detalle en el popup)
LABEL=""
[ $((NP + NA)) -gt 0 ] && LABEL+="$ICON_WAIT $((NP + NA))  "
[ "$NV" -gt 0 ] && LABEL+="$ICON_EYE $NV  "
[ "$NR" -gt 0 ] && LABEL+="$ICON_PR $NR  "
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

# "-" en los campos vacíos: con IFS=tab, bash junta los tabs seguidos y corre las columnas
while IFS=$'\t' read -r KIND TITLE WHERE NUM URL CWD LPATH ID TODO; do
  case "$KIND" in
    plan)     IC=$ICON_WAIT; C=$MAUVE; LBL="plan por aprobar · $WHERE"
              CLICK="open \"$CWD\"" ;;
    reviewer) IC=$ICON_WAIT; C=$PEACH; LBL="reviewer propuesto · $WHERE · $ID"
              CLICK="printf '%s' \"$TODO\" | pbcopy" ;;   # copia "bk approve …": lanzar un agente es tuyo
    review)   IC=$ICON_EYE; C=$PEACH; LBL="review · ${WHERE} #$NUM · $(cut_to "$TITLE" 38)"
              CLICK="open \"$URL\"" ;;
    merge)    IC=$ICON_PR; C=$GREEN; LBL="mergear · ${WHERE} #$NUM · $(cut_to "$TITLE" 38)"
              CLICK="open \"$URL\"" ;;
    lesson)   IC=$ICON_LESSON; C=$YELLOW; LBL="lección · $WHERE · $(cut_to "$TITLE" 38)"
              ENC=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$LPATH")
              CLICK="open \"obsidian://open?path=$ENC\"" ;;
    *) continue ;;
  esac
  case "$CLICK" in *'"-"'*) CLICK=":" ;; esac   # sin URL ni carpeta: el clic solo cierra el popup
  sketchybar --add item agents.ckpt.$i popup.agents.ckpt \
             --set agents.ckpt.$i "${ROW[@]}" icon="$IC" icon.color=$C label="$LBL" \
                   click_script="$CLICK; sketchybar --set agents.ckpt popup.drawing=off"
  i=$((i+1))
done < <(printf '%s' "$CK" | jq -r '.[] | [.kind, (.title // "-"), (.where // "-"), ((.number // "-") | tostring),
                                         (.url // "-"), (.cwd // "-"), (.path // "-"), (.id // "-"), (.todo // "-")]
                                        | map(if . == "" then "-" else . end) | @tsv')
