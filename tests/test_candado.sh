#!/usr/bin/env bash
# bk run suelta el candado del worktree antes de lanzar al agente, y bk done suelta el del agente (#5).
# Antes, bk run tomaba el candado (agent-lock del kit) como el proceso que llamó a bk y nadie lo soltaba:
# el agente que lanzaba, o una sesión de review, veía "held" en un worktree que era suyo.
# Acá bk ve un prepare.sh, un worktree-lock.sh y un tmux falsos que anotan lo que les piden.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
unset TMUX TMUX_PANE BK_ACCOUNT BK_ACCOUNT_CLAUDE BK_TASK_DIR WORKTREE_LOCK_AGENT WORKTREE_LOCK_PID
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" BK_FORCE=1 BK_BOT=0 LOG="$TMP/log" LOCK_SAYS=released
mkdir -p "$HOME" "$TMP/fake"
printf '#!/bin/sh\necho "tmux $1" >> "$LOG"\nexit 1\n' >"$TMP/fake/tmux"; chmod +x "$TMP/fake/tmux"
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }

# Un proyecto Barrilete mínimo, con origin, y los dos scripts del kit falsos
REPO="$TMP/proj"; WT="$TMP/proj-wt/7"
git init -q -b main "$REPO"; git init -q --bare "$TMP/origin.git"; git -C "$REPO" remote add origin "$TMP/origin.git"
mkdir -p "$REPO/scripts/agents" "$REPO/.claude/skills/implement-issue"; : >"$REPO/scripts/agents/guardrails.py"
cat >"$REPO/.claude/skills/implement-issue/prepare.sh" <<EOF
#!/bin/sh
echo "prepare \$* agent=\${WORKTREE_LOCK_AGENT:-}" >> "\$LOG"
mkdir -p "$WT"; echo "Worktree: $WT"
EOF
cat >"$REPO/scripts/agents/worktree-lock.sh" <<'EOF'
#!/bin/sh
echo "lock $* agent=${WORKTREE_LOCK_AGENT:-}" >> "$LOG"
echo "$LOCK_SAYS"
EOF
chmod +x "$REPO/.claude/skills/implement-issue/prepare.sh" "$REPO/scripts/agents/worktree-lock.sh"
git -C "$REPO" add -A; git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m init

bk() { PATH="$TMP/fake:$PATH" "$ROOT/bin/bk" "$@"; }
log() { cat "$LOG" 2>/dev/null; }

# --- bk run ---
: >"$LOG"; (cd "$REPO" && bk run 7 --role implementer >/dev/null 2>&1)
check_eq "$(log | sed -n 1p)" "prepare 7 --worktree agent=7-implementer" "bk run: prepare.sh corre con el nombre de la tarea"
check_eq "$(log | sed -n 2p)" "lock release $WT agent=7-implementer" "bk run: suelta el candado del worktree con ese nombre"
check_eq "$(log | grep -n '^tmux' | head -1 | cut -d: -f1)" "3" "bk run: lo suelta antes de lanzar al agente"

rm -rf "$XDG_STATE_HOME"; : >"$LOG"
out=$(cd "$REPO" && LOCK_SAYS="held: otro (pid 1, since x)" bk run 7 --role implementer 2>&1); rc=$?
check_eq "$rc" "1" "bk run: si el candado es de otro, no lanza (sale con 1)"
check_eq "$(log | grep -c '^tmux')" "0" "bk run: si el candado es de otro, no toca tmux"
check_eq "$(grep -c 'held: otro' <<<"$out")" "1" "bk run: si el candado es de otro, dice quién lo tiene"

rm -rf "$XDG_STATE_HOME"; : >"$LOG"; mv "$REPO/scripts/agents/worktree-lock.sh" "$TMP/lock.sh"
(cd "$REPO" && bk run 7 --role implementer >/dev/null 2>&1)
check_eq "$(log | grep -c '^tmux new-session')" "1" "bk run: un kit sin worktree-lock.sh se lanza igual"
mv "$TMP/lock.sh" "$REPO/scripts/agents/worktree-lock.sh"

# --- bk done ---
tarea() { rm -rf "$XDG_STATE_HOME"; python3 "$ROOT/lib/tasks.py" create proj 7-implementer --role implementer --repo "$REPO" --worktree "$WT"; }
: >"$LOG"; T=$(tarea)
out=$(BK_TASK_DIR="$T" bk done blockers 2>&1); rc=$?
check_eq "$rc" "0" "bk done: cierra la tarea"
check_eq "$(log)" "lock release $WT agent=7-implementer" "bk done: suelta el candado del agente con el nombre de la tarea"

: >"$LOG"; out=$(BK_TASK_DIR="$T" bk done blockers 2>&1); rc=$?
check_eq "$rc|$(log)" "64|" "bk done: si no cerró nada (ya estaba cerrada), no toca el candado"

: >"$LOG"; T=$(tarea)
out=$(BK_TASK_DIR="$T" LOCK_SAYS="held: otro (pid 1, since x)" bk done blockers 2>&1); rc=$?
check_eq "$rc" "0" "bk done: un candado de otro no hace fallar el cierre"
check_eq "$(grep -c 'held: otro' <<<"$out")" "1" "bk done: un candado de otro se avisa"

: >"$LOG"; T=$(tarea); rm -rf "$WT"
out=$(BK_TASK_DIR="$T" bk done blockers 2>&1); rc=$?
check_eq "$rc|$(log)" "0|" "bk done: sin worktree (ya borrado) cierra sin tocar el candado"

echo "1..$N"
[ "$FAILED" -eq 0 ]
