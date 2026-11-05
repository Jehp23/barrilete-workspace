#!/usr/bin/env bash
# bk land: N ramas en paralelo sobre main protegido. Repo y claims de prueba; nada toca tu workspace.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
N=0; FAILED=0
check() { N=$((N+1)); if [ "$1" -eq 0 ]; then echo "ok $N - $2"; else echo "not ok $N - $2"; FAILED=$((FAILED+1)); fi; }
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }

export BK_CLAIMS_DIR="$TMP/claims" BK_LAND_POLL=0.2 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset BK_MAIN_OK BK_LANDING TMUX_PANE
L="$ROOT/lib/land.py"
M="$TMP/ws"; mkdir -p "$M/lib" "$M/githooks"
cp "$ROOT/githooks/reference-transaction" "$M/githooks/"
# checks de prueba: anotan cada corrida (rama y si x tiene el cambio de A); "fail" en y los hace fallar
cat >"$M/lib/checks.sh" <<EOF
#!/usr/bin/env bash
echo "\$(git branch --show-current) \$(tr '\n' ' ' < x)" >> "$TMP/checks.log"
! grep -q fail y 2>/dev/null
EOF
printf 'uno\ndos\ntres\n' >"$M/x"; echo y >"$M/y"; echo z >"$M/z"
git -C "$M" init -q -b main && git -C "$M" add -A && git -C "$M" commit -qm base
git -C "$M" config core.hooksPath githooks

# --- el hook de git ---
echo cambio >>"$M/z"; git -C "$M" commit -qam directo 2>/dev/null; check $(( $? == 0 )) "commit directo en main: rechazado"
git -C "$M" commit -qam directo --no-verify 2>/dev/null; check $(( $? == 0 )) "--no-verify no lo salta"
git -C "$M" checkout -q z
git -C "$M" branch tmp && git -C "$M" worktree add -q "$TMP/tmp" tmp && echo t >>"$TMP/tmp/z" && git -C "$TMP/tmp" commit -qam t
git -C "$M" merge -q --ff-only tmp 2>/dev/null; check $(( $? == 0 )) "merge --ff-only a mano (sin bk land): rechazado"
BK_LANDING=1 git -C "$M" merge -q --ff-only tmp; check $? "el fast-forward de bk land pasa"
BK_LANDING=1 git -C "$M" reset -q --hard HEAD~1 2>/dev/null; check $(( $? == 0 )) "main no retrocede ni con BK_LANDING"
BK_MAIN_OK=1 git -C "$M" reset -q --hard HEAD~1; check $? "BK_MAIN_OK=1: salida de emergencia"
git -C "$M" worktree remove --force "$TMP/tmp"; git -C "$M" branch -qD tmp

# --- tres ramas: A y B tocan x, C toca z ---
wt() { git -C "$M" worktree add -q -b "$1" "$TMP/$1" main; }
wt a; wt b; wt c
claim() { (cd "$TMP/$1" && python3 "$L" claim "$2" >/dev/null); }
claim a x; sleep 0.05; claim b x; sleep 0.05; claim c z
sed -i.bak 's/uno/UNO-a/' "$TMP/a/x" && rm "$TMP/a/x.bak" && git -C "$TMP/a" commit -qam a
sed -i.bak 's/tres/TRES-b/' "$TMP/b/x" && rm "$TMP/b/x.bak" && git -C "$TMP/b" commit -qam b
echo c >>"$TMP/c/z" && git -C "$TMP/c" commit -qam c
land() { (cd "$TMP/$1" && python3 "$L" land "${@:2}" 2>&1); }

out=$(land b); rc=$?
check_eq "$rc" 3 "B toca x después que A: queda en cola (sale 3)"
grep -q "esperando a a" <<<"$out"; check $? "B dice a quién espera"
[ ! -f "$TMP/checks.log" ]; check $? "B no corre checks mientras espera"
out=$(land c); check $? "C no comparte archivos: entra sin esperar"
check_eq "$(git -C "$M" log -1 --format=%s main)" c "main avanzó con C"
check_eq "$(cat "$M/z" | tail -1)" c "el checkout de main se actualizó (fast-forward)"

# A entra (rebasa sobre C), y B, que esperaba con --wait, entra después con los checks una vez
(cd "$TMP/b" && python3 "$L" land --wait --timeout 20 >"$TMP/b.out" 2>&1; echo $? >"$TMP/b.rc") &
sleep 0.6
out=$(land a); check $? "A entra (rebasa sobre lo de C)"
wait
check_eq "$(cat "$TMP/b.rc")" 0 "B, que esperaba con --wait, entra cuando A termina"
check_eq "$(grep -c '^b ' "$TMP/checks.log")" 1 "B corrió los checks una sola vez"
grep -q '^b UNO-a dos TRES-b' "$TMP/checks.log"; check $? "y los corrió sobre main con el cambio de A (rebasado)"
check_eq "$(git -C "$M" log --format=%s main | head -3 | tr '\n' ' ')" "b a c " "main: c, a, b en orden, lineal"
check_eq "$(tr '\n' ' ' < "$M/x")" "UNO-a dos TRES-b " "x tiene los dos cambios"
check_eq "$(cd "$M" && python3 "$L" claims)" "nadie está modificando nada" "las ramas que entraron sueltan sus claims"

# --- choque real: D y E cambian la misma línea ---
wt d; wt e
claim d y; sleep 0.05; claim e y
echo d >"$TMP/d/y" && git -C "$TMP/d" commit -qam d
echo e >"$TMP/e/y" && git -C "$TMP/e" commit -qam e
land d >/dev/null; check $? "D entra"
out=$(land e); check_eq "$?" 4 "E choca en el rebase: sale 4 y no toca main"
grep -q "Resolvelo en el worktree" <<<"$out"; check $? "le dice cómo seguir"
check_eq "$(git -C "$M" log -1 --format=%s main)" d "main quedó con D"
echo e >"$TMP/e/y" && git -C "$TMP/e" add y && GIT_EDITOR=true git -C "$TMP/e" rebase --continue >/dev/null 2>&1
land e >/dev/null; check $? "resuelto el choque, E entra"

# --- checks que fallan, cambios sin commitear, desde main ---
wt f; echo fail >"$TMP/f/y" && git -C "$TMP/f" commit -qam f
out=$(land f); check_eq "$?" 5 "checks en rojo: no entra (sale 5)"
check_eq "$(git -C "$M" log -1 --format=%s main)" e "main no cambió"
wt g; echo g >>"$TMP/g/z"
out=$(land g); check $(( $? == 0 )) "con cambios sin commitear no entra"
(cd "$M" && python3 "$L" land >/dev/null 2>&1); check $(( $? == 0 )) "bk land desde main: error"

# --- sin deadlock: H empieza con x, I con z; los dos tocan x y z ---
wt h; wt i
claim h x; sleep 0.05; claim i z; claim h z; claim i x
out=$(cd "$M" && python3 "$L" claims --json)
check_eq "$(jq -r '[.[] | select(.branch=="h") | .waits_for[]] | length' <<<"$out")" 0 "H (empezó antes) no espera a nadie"
check_eq "$(jq -r '.[] | select(.branch=="i") | .waits_for | join(",")' <<<"$out")" h "I espera a H: un solo orden, sin ciclo"

# --- claims que no bloquean: worktree borrado y rama vieja ---
git -C "$M" worktree remove --force "$TMP/h"
check_eq "$(cd "$M" && python3 "$L" claims --json | jq -r '.[] | select(.branch=="i") | .waits_for | length')" 0 \
  "si el worktree de H desaparece, I ya no espera"
wt j; wt k; claim j y; sleep 0.05; claim k y
check_eq "$(cd "$M" && BK_CLAIM_STALE=0 python3 "$L" claims --json | jq -r '.[] | select(.branch=="k") | .waits_for | length')" 0 \
  "una rama sin actividad (vieja) no bloquea"

# --- el hook de Claude Code ---
hook() { jq -n --arg e "$1" --arg f "$2" --arg c "$3" '{hook_event_name: $e, tool_name: "Edit", cwd: $c, tool_input: {file_path: $f}}' \
  | python3 "$L" hook; }
hook PreToolUse "$M/x" "$M" | jq -r .hookSpecificOutput.permissionDecision | grep -qx deny
check $? "editar el checkout de main: denegado"
check_eq "$(BK_MAIN_OK=1 hook PreToolUse "$M/x" "$M")" "" "con BK_MAIN_OK=1 se puede"
check_eq "$(hook PreToolUse "$TMP/k/y" "$TMP/k")" "" "editar en un worktree: permitido"
msg=$(hook PostToolUse "$TMP/k/y" "$TMP/k" | jq -r .hookSpecificOutput.additionalContext)
grep -q "j, que empezó antes" <<<"$msg" && grep -q "no corras los checks" <<<"$msg"
check $? "K edita y, que J tiene desde antes: el hook le avisa que no corra checks"
wt l
check_eq "$(hook PostToolUse "$TMP/l/nuevo" "$TMP/l")" "" "un archivo que nadie toca: sin aviso"
(cd "$M" && python3 "$L" claims --json) | jq -e '.[] | select(.branch=="l") | .files | index("nuevo")' >/dev/null
check $? "y queda reclamado por L"
check_eq "$(hook PostToolUse /tmp/fuera "$TMP")" "" "fuera de un repo: el hook no hace nada"

echo "1..$N"; [ "$FAILED" -eq 0 ]
