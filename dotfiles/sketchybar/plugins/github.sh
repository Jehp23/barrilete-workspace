#!/bin/bash
# GitHub del repo en el que se está trabajando: PRs abiertos, reviews pedidas a vos y CI.
#
# Repo "actual" = el de la sesión de agente más reciente (su cwd → remote de GitHub → rama).
# Si ninguna sesión está en un repo de GitHub, usa $SKETCHYBAR_GH_REPO (o AbraTickets/abra).
# CI = checks del último commit de la rama por defecto y, si es otra, de la rama de trabajo.
# Una sola consulta GraphQL; con agent_update solo se vuelve a consultar si cambió repo/rama
# o pasaron 2 min (los hooks disparan muy seguido).

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
[ "$(cat "$HOME/.cache/sketchybar/mode" 2>/dev/null)" = "chill" ] && exit 0  # modo chill: no prender nada
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/sketchybar}"
source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/icons.sh"

AGENTS_DIR="$HOME/.cache/sketchybar/agents"
CTX_FILE="$HOME/.cache/sketchybar/github_ctx"
FALLBACK="${SKETCHYBAR_GH_REPO:-AbraTickets/abra}"

# ---- Repo y rama actuales (sin red) ----
SLUG=""; BRANCH=""
for f in $(ls -t "$AGENTS_DIR"/*.json 2>/dev/null); do
  CWD=$(jq -r '.cwd // empty' "$f" 2>/dev/null)
  [ -d "$CWD" ] || continue
  URL=$(git -C "$CWD" remote get-url origin 2>/dev/null) || continue
  S=$(printf '%s' "$URL" | sed -nE 's#^(git@github\.com:|https://github\.com/)([^/]+/[^/]+)$#\2#p' | sed 's/\.git$//')
  [ -n "$S" ] || continue
  SLUG="$S"; BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)
  break
done
[ -z "$SLUG" ] && SLUG="$FALLBACK"
CTX="$SLUG $BRANCH"

# ---- ¿Hace falta consultar a GitHub? ----
if [ "$SENDER" = "agent_update" ] && [ -f "$CTX_FILE" ]; then
  AGE=$(( $(date +%s) - $(stat -f %m "$CTX_FILE") ))
  [ "$(cat "$CTX_FILE")" = "$CTX" ] && [ "$AGE" -lt 120 ] && exit 0
fi
# Un solo fetch a la vez
LOCK="${TMPDIR:-/tmp}/sketchybar_github.lock"
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
echo "$CTX" > "$CTX_FILE"

if ! gh auth status >/dev/null 2>&1; then
  sketchybar --set github.prs label="gh sin login" icon.color=$SUBTEXT \
             --set github.ci  drawing=off
  exit 0
fi

OWNER=${SLUG%%/*}; NAME_=${SLUG#*/}
REF="refs/heads/${BRANCH:-__none__}"
DATA=$(gh api graphql -F owner="$OWNER" -F name="$NAME_" -F ref="$REF" \
  -F q="repo:$SLUG is:pr is:open review-requested:@me" -f query='
  query($owner: String!, $name: String!, $ref: String!, $q: String!) {
    repository(owner: $owner, name: $name) {
      pullRequests(states: OPEN) { totalCount }
      defaultBranchRef { name target { ... on Commit { statusCheckRollup { state } } } }
      ref(qualifiedName: $ref) { name target { ... on Commit { statusCheckRollup { state } } } }
    }
    search(query: $q, type: ISSUE) { issueCount }
  }' 2>/dev/null)

if [ -z "$DATA" ] || [ "$(printf '%s' "$DATA" | jq -r '.data.repository // empty')" = "" ]; then
  sketchybar --set github.prs label="${NAME_} ?" icon.color=$SUBTEXT --set github.ci drawing=off
  exit 0
fi

read -r OPEN REVIEW DEF DEF_STATE WORK WORK_STATE < <(printf '%s' "$DATA" | jq -r '
  .data as $d
  | [ $d.repository.pullRequests.totalCount, $d.search.issueCount,
      $d.repository.defaultBranchRef.name,
      ($d.repository.defaultBranchRef.target.statusCheckRollup.state // "NONE"),
      "-",
      ($d.repository.ref.target.statusCheckRollup.state // "NONE") ] | @tsv')

# Rama de trabajo: la local (aunque no esté pusheada; sin checks muestra "–")
WORK="${BRANCH:--}"

# ---- PRs ----
# Las reviews pedidas se cuentan en checkpoints (izquierda); acá solo tiñen el ícono.
# El largo del nombre lo decide fit_to_notch() al final, según el espacio real.
PR_COLOR=$MAUVE
[ "$REVIEW" != "0" ] && PR_COLOR=$PEACH
sketchybar --set github.prs icon.color=$PR_COLOR \
           click_script="open 'https://github.com/$SLUG/pulls'"

# ---- CI ----
ci_icon() {
  case "$1" in
    SUCCESS)                  echo "$ICON_CI_OK" ;;
    FAILURE|ERROR)            echo "$ICON_CI_FAIL" ;;
    PENDING|EXPECTED)         echo "$ICON_CI_RUN" ;;
    *)                        echo "$ICON_BRANCH" ;;   # sin checks: ícono de rama neutro
  esac
}
# Ramas del kit: claude/42-algo -> #42; otras, tal cual (fit_to_notch las acorta si hace falta)
short_branch() {
  local n; n=$(printf '%s' "$1" | sed -nE 's#^[^/]+/([0-9]+)([-_].*)?$#\1#p')
  if [ -n "$n" ]; then echo "#$n"; else echo "$1"; fi
}

# Compacto (la derecha del notch es angosta): una sola rama, su estado como ícono.
# Se muestra la de trabajo si hay; si no, la principal. El color suma las dos:
# si la principal falla, el ícono se pone rojo aunque la de trabajo esté bien.
STATES="$DEF_STATE"
if [ "$WORK" != "-" ] && [ "$WORK" != "$DEF" ]; then
  CI_LABEL=$(short_branch "$WORK"); SHOWN_STATE="$WORK_STATE"
  STATES+=" $WORK_STATE"
else
  CI_LABEL="$DEF"; SHOWN_STATE="$DEF_STATE"
fi
CI_ICON=$(ci_icon "$SHOWN_STATE")

case "$STATES" in
  *FAILURE*|*ERROR*)     CI_COLOR=$RED ;;
  *PENDING*|*EXPECTED*)  CI_COLOR=$YELLOW ;;
  *SUCCESS*)             CI_COLOR=$GREEN ;;
  *)                     CI_COLOR=$SUBTEXT ;;
esac

ACTIONS="https://github.com/$SLUG/actions"
[ "$WORK" != "-" ] && [ "$WORK" != "$DEF" ] && ACTIONS+="?query=branch%3A$WORK"
sketchybar --set github.ci drawing=on icon="$CI_ICON" icon.color=$CI_COLOR \
           click_script="open '$ACTIONS'"

# ---- Ajuste al notch ----
# Nombres completos si entran; si el grupo queda a menos de MARGIN px del notch, se acortan
# por pasos (primero la rama, después el repo). Sin notch (monitor externo) no se acorta nada.
notch_right() {
  local f="$HOME/.cache/sketchybar/notch_right"
  [ -s "$f" ] || osascript -l JavaScript -e 'ObjC.import("AppKit");
    const r = $.NSScreen.mainScreen.auxiliaryTopRightArea; r.size.width > 0 ? Math.ceil(r.origin.x) : 0' > "$f" 2>/dev/null
  cat "$f" 2>/dev/null || echo 0
}
fit_to_notch() {
  local limit x n_r=$(notch_right) MARGIN=16 trunc
  trunc() { local s="$1" n="$2"; [ ${#s} -gt "$n" ] && echo "${s:0:$((n-1))}…" || echo "$s"; }
  for limit in "24 24" "16 16" "14 12" "12 10" "10 8" "8 6"; do
    set -- $limit
    sketchybar --set github.prs label="$(trunc "$NAME_" "$1")  $OPEN" \
               --set github.ci  label="$(trunc "$CI_LABEL" "$2")"
    [ "$n_r" -eq 0 ] && return
    sleep 0.05
    x=$(sketchybar --query github.prs | jq -r '.bounding_rects[]?.origin[0] // 9999 | floor' | head -1)
    [ "${x:-9999}" -ge $((n_r + MARGIN)) ] && return
  done
}
fit_to_notch
