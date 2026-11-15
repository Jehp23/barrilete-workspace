#!/usr/bin/env bash
# lib/branches.py y los temas branches, branch-rm, branch-open y branch-sweep de bk _hub: qué rama está terminada y
# cuándo se puede borrar sin perder nada. Todo en un directorio temporal: un repo con su remoto (un repo bare al que
# se llega por pushInsteadOf, así su URL es de github.com), worktrees y un gh falso que contesta desde un archivo.
# Nada toca GitHub: GIT_SSH_COMMAND=false hace fallar cualquier fetch.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); SLEEPER=""
trap '[ -z "$SLEEPER" ] || kill "$SLEEPER" 2>/dev/null; rm -rf "$TMP"' EXIT
unset TMUX TMUX_PANE HC_TERMINAL_ID BK_BACKEND BK_CACHE_DIR XDG_CACHE_HOME GIT_DIR GIT_WORK_TREE BK_DRY BK_NO_SWEEP
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" HD_FAKE="$TMP/hd" BK_HERDR_APP=herdr-app BK_HC=hc GIT_SSH_COMMAND=false GIT_TERMINAL_PROMPT=0 \
       BK_PROJECTS="$TMP/proj" GIT_CONFIG_GLOBAL="$TMP/gitconfig"
mkdir -p "$HOME" "$TMP/fake"
cat >"$TMP/gitconfig" <<EOF
[user]
  name = t
  email = t@t
[commit]
  gpgsign = false
[init]
  defaultBranch = main
[url "$TMP/remote.git"]
  pushInsteadOf = git@github.com:o/r.git
EOF
cat >"$TMP/fake/gh" <<FAKE
#!/bin/sh
echo "\$*" >>"$TMP/gh.log"
case "\$1 \$2" in "pr list") cat "$TMP/prs.json" ;; *) exit 1 ;; esac
FAKE
for b in herdr-app hc tmux open; do printf '#!/bin/sh\necho "%s $*" >>"%s/otros.log"\nexit 1\n' "$b" "$TMP" >"$TMP/fake/$b"; done
printf '#!/bin/sh\nexit 3\n' >"$TMP/lsof-roto"
printf '#!/bin/sh\necho "$*" >>"%s/notice.log"\n' "$TMP" >"$TMP/fake/bk-notice"
chmod +x "$TMP/fake"/* "$TMP/lsof-roto"; : >"$TMP/gh.log"
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
br() { PATH="$TMP/fake:$PATH" python3 "$ROOT/lib/branches.py" "$@"; }
hub() { PATH="$TMP/fake:$PATH" BK_BACKEND=herdr "$ROOT/bin/bk" _hub "$@"; }
row() { br list "$REPO" | jq -r --arg b "$1" '.projects[0].items[] | select(.name == $b) | '"$2"; }
exists() { git -C "$REPO" show-ref -q --verify "refs/heads/$1" && echo si || echo no; }
on_remote() { git -C "$TMP/remote.git" show-ref -q --verify "refs/heads/$1" && echo si || echo no; }
REPO="$TMP/proj"; W="$TMP/proj-wt"

# ---------- un repo con su remoto y ramas en cada estado ----------
git init -q --bare "$TMP/remote.git"
git init -q "$REPO" && git -C "$REPO" commit -q --allow-empty -m base
git -C "$REPO" remote add origin git@github.com:o/r.git
git -C "$REPO" push -q -u origin main
# rama <nombre> [worktree]: un commit propio, subido al remoto
rama() {
  git -C "$REPO" branch "$1" main
  if [ -n "${2:-}" ]; then git -C "$REPO" worktree add -q "$W/$2" "$1"; d="$W/$2"; else d=""; fi
  if [ -n "$d" ]; then (cd "$d" && echo "$1" >"f-$2" && git add . && git commit -qm "$1"); else
    git -C "$REPO" checkout -q "$1" && echo "$1" >"$REPO/f" && git -C "$REPO" add . && git -C "$REPO" commit -qm "$1" && git -C "$REPO" checkout -q main; fi
  git -C "$REPO" push -q origin "$1"
}
rama mergeada m1
rama movida m2
rama abierta m3
rama sucia m4
rama nueva-archivo m5
rama en-uso m6
rama sin-wt
rama cerrada
rama landeada l1
rama landeada-movida l2
git -C "$REPO" worktree add -q -b vacia "$W/v" main    # recién creada: sin commits propios
sha() { git -C "$REPO" rev-parse "$1"; }
# los PRs: mergeada, movida (el PR se mergeó antes del último commit), abierta, sucia, nueva-archivo, en-uso, sin-wt
# y cerrada (sin mergear)
pr() { printf '{"number":%s,"state":"%s","headRefName":"%s","headRefOid":"%s","url":"https://github.com/o/r/pull/%s","title":"PR de %s"}' "$1" "$2" "$3" "$4" "$1" "$3"; }
OLD_MOVIDA=$(sha movida); (cd "$W/m2" && echo más >>f-m2 && git commit -qam "después del merge")
{ echo "["; pr 1 MERGED mergeada "$(sha mergeada)"; echo ","; pr 2 MERGED movida "$OLD_MOVIDA"; echo ",";
  pr 3 OPEN abierta "$(sha abierta)"; echo ","; pr 4 MERGED sucia "$(sha sucia)"; echo ",";
  pr 5 MERGED nueva-archivo "$(sha nueva-archivo)"; echo ","; pr 6 MERGED en-uso "$(sha en-uso)"; echo ",";
  pr 7 MERGED sin-wt "$(sha sin-wt)"; echo ","; pr 8 CLOSED cerrada "$(sha cerrada)"; echo "]"; } >"$TMP/prs.json"
echo cambio >>"$W/m4/f-m4"            # sucia: un cambio sin commitear
echo nuevo >"$W/m5/nuevo.txt"         # nueva-archivo: solo un archivo sin seguir
python3 -c "import sys; sys.path.insert(0, '$ROOT/lib'); import branches as B
B.note_landed('$REPO', 'landeada', '$(sha landeada)'); B.note_landed('$REPO', 'landeada-movida', '$(sha landeada-movida)')"
(cd "$W/l2" && echo más >>f-l2 && git commit -qam "después del land")
(cd "$W/m6/" && exec sleep 60) & SLEEPER=$!
sleep 0.3

# ---------- qué dice de cada una ----------
check_eq "$(br list "$REPO" | jq -r '[.projects[0].items[].name] | index("main")')" "null" "la rama principal no se lista"
check_eq "$(row mergeada '"\(.done) \(.can_rm) \(.how)"')" "true true PR #1 mergeado" "PR mergeado en el mismo commit: terminada y se puede borrar"
check_eq "$(row movida '"\(.done) \(.can_rm)"')" "false false" "PR mergeado pero la rama sumó un commit después: no está terminada"
check_eq "$(row movida .why)" "tiene 2 commits que no están en main" "y dice cuántos commits perdería"
check_eq "$(row abierta '"\(.can_rm) \(.why)"')" "false PR #3 abierto" "PR abierto: no se borra"
check_eq "$(row sucia '"\(.done) \(.can_rm) \(.why)"')" "true false su worktree tiene 1 cambio sin commitear" "terminada con un cambio sin commitear: no se borra"
check_eq "$(row nueva-archivo '"\(.can_rm) \(.dirty)"')" "false 1" "un archivo nuevo sin seguir también frena"
check_eq "$(row en-uso '"\(.can_rm) \(.busy) \(.why)"')" "false true hay un proceso trabajando en su worktree" "un proceso con su carpeta adentro del worktree: no se borra"
check_eq "$(row sin-wt '"\(.done) \(.can_rm) \(.worktree)"')" "true true " "terminada sin worktree: se puede borrar"
check_eq "$(row cerrada '"\(.done) \(.can_rm) \(.pr.state)"')" "false false closed" "PR cerrado sin mergear: no está terminada"
check_eq "$(row landeada '"\(.done) \(.how)"')" "true entró con bk land" "la que entró con bk land, en ese commit: terminada"
check_eq "$(row landeada-movida .done)" "false" "la que entró con bk land y después sumó un commit: no"
check_eq "$(row vacia '"\(.done) \(.contained) \(.can_rm)"')" "false true true" "recién creada (sin commits): no terminada, pero borrarla a mano no pierde nada"
check_eq "$(row mergeada .remote)" "true" "sabe que la del remoto apunta al mismo commit"
check_eq "$(PATH="$TMP/fake:$PATH" BK_CACHE_DIR="$TMP/c2" python3 -c "import sys; sys.path.insert(0, '$ROOT/lib'); import branches as B
print(B.info('$REPO', with_busy=False, busy=None)['items'] and 'ok')")" "ok" "info sin mirar procesos no se cae"

# ---------- la limpieza sola ----------
n=$(wc -l <"$TMP/gh.log")
check_eq "$(PATH="$TMP/lsof-roto:$PATH" br sweep --dry-run >/dev/null; PATH="$TMP/fake:$PATH" python3 -c "
import os, sys; sys.path.insert(0, '$ROOT/lib'); import branches as B, subprocess
real = subprocess.run
def roto(a, **k):
    if a[0] == 'lsof': return subprocess.CompletedProcess(a, 3, '', 'no')
    return real(a, **k)
subprocess.run = roto
print(' '.join(sorted(r['branch'] for r in B.sweep()['removed'])))")" "sin-wt" "si lsof falla no borra ningún worktree (no sabe quién trabaja dónde): solo la terminada sin worktree"
check_eq "$(exists mergeada) $(exists landeada) $(exists sin-wt)" "si si no" "las que tienen worktree siguen"
check_eq "$(br sweep --dry-run | jq -r '[.removed[].branch] | sort | join(" ")')" "landeada mergeada" "sweep --dry-run: solo las terminadas que se pueden borrar"
check_eq "$(exists mergeada) $([ -d "$W/m1" ] && echo wt)" "si wt" "--dry-run no borra nada"
out=$(br sweep)
check_eq "$(jq -r '[.removed[].branch] | sort | join(" ")' <<<"$out") $(jq -r '.failed | length' <<<"$out")" "landeada mergeada 0" "sweep borra las terminadas"
check_eq "$(exists mergeada) $(exists sin-wt) $(exists landeada) $([ -d "$W/m1" ] && echo wt || echo sin-wt)" "no no no sin-wt" "su rama y su worktree ya no están"
check_eq "$(on_remote mergeada) $(on_remote sin-wt)" "no no" "y la del remoto, que apuntaba al mismo commit, tampoco"
check_eq "$(exists movida) $(exists abierta) $(exists sucia) $(exists nueva-archivo) $(exists en-uso) $(exists cerrada) $(exists landeada-movida) $(exists vacia)" "si si si si si si si si" "no toca ninguna de las otras"
check_eq "$(cat "$W/m4/f-m4" | tail -1) $(cat "$W/m5/nuevo.txt")" "cambio nuevo" "lo sin commitear sigue ahí"
check_eq "$(git -C "$REPO" branch --show-current)" "main" "el checkout principal sigue en main"

# ---------- a mano: branch-rm (ctrl+x en alt+b) ----------
check_eq "$(hub branch-rm "$REPO" abierta 2>&1 >/dev/null; echo "salió $?")" "bk: abierta: PR #3 abierto
salió 1" "branch-rm no borra la de un PR abierto y dice por qué"
check_eq "$(hub branch-rm "$REPO" sucia 2>&1 >/dev/null)" "bk: sucia: su worktree tiene 1 cambio sin commitear" "ni la que tiene cambios sin commitear"
check_eq "$(PATH="$TMP/fake:$PATH" python3 -c "import sys; sys.path.insert(0, '$ROOT/lib'); import branches as B
print(B.remove('$REPO', 'vacia', sweep=True)[1])")" "vacia: no está terminada" "la limpieza sola no borra una recién creada aunque se pueda borrar sin perder nada"
git -C "$REPO" branch otra-en-remoto main
git -C "$REPO" push -q origin "$(git -C "$REPO" rev-parse abierta):refs/heads/otra-en-remoto"
check_eq "$(hub branch-rm "$REPO" otra-en-remoto | jq -r .ok) $(exists otra-en-remoto) $(on_remote otra-en-remoto)" "true no si" "branch-rm no borra la del remoto si apunta a otro commit"
check_eq "$(hub branch-rm "$REPO" vacia | jq -r .ok) $(exists vacia) $([ -d "$W/v" ] && echo wt || echo sin-wt)" "true no sin-wt" "branch-rm borra una recién creada (no se pierde nada)"
check_eq "$(hub branch-rm "$REPO" no-existe 2>&1 >/dev/null)" "bk: no existe la rama no-existe" "branch-rm de una rama que no existe"
check_eq "$(hub branch-rm "$REPO" main 2>&1 >/dev/null)" "bk: no existe la rama main" "branch-rm nunca toca la principal"

# ---------- branch-open: dónde abrir un chat (Enter en alt+b) ----------
check_eq "$(hub branch-open "$REPO" movida | jq -r '"\(.path) \(.created)"')" "$W/m2 false" "branch-open: la que tiene worktree, su worktree"
check_eq "$(hub branch-open "$REPO" cerrada | jq -r '"\(.path) \(.created)"') $(git -C "$W/cerrada" branch --show-current)" "$W/cerrada true cerrada" "branch-open: la que no tiene, le crea uno en ../<repo>-wt/<rama>"
git -C "$REPO" branch claude/9-algo main
mkdir -p "$W/9-algo"
check_eq "$(hub branch-open "$REPO" claude/9-algo | jq -r .path)" "$W/9-algo-2" "branch-open: usa el último tramo del nombre y no pisa una carpeta que ya existe"
check_eq "$(hub branch-open "$REPO" no-existe 2>&1 >/dev/null)" "bk: no existe la rama no-existe" "branch-open de una rama que no existe"

# ---------- el panel: branches ----------
out=$(hub branches "$REPO")
check_eq "$(jq -r '.projects[0].name + " " + .projects[0].base + " " + .projects[0].repo' <<<"$out")" "proj main o/r" "branches: el proyecto, su rama principal y su repo"
check_eq "$(jq -r '[.projects[0].items[].done] | . == (sort | reverse)' <<<"$out")" "true" "branches: las terminadas primero"

# ---------- status dispara la limpieza, cada 10 min como mucho ----------
rm -f "$HOME/.cache/bk/branches-sweep.stamp"
BK_PROJECTS="$TMP/nada" hub status "$REPO" >/dev/null
check_eq "$([ -f "$HOME/.cache/bk/branches-sweep.stamp" ] && echo marcó)" "marcó" "status marca la hora de la limpieza"
python3 -c "import os,time; p='$HOME/.cache/bk/branches-sweep.stamp'; os.utime(p, (time.time()-30, time.time()-30))"
BK_PROJECTS="$TMP/nada" hub status "$REPO" >/dev/null
check_eq "$(python3 -c "import os,time; print(int(time.time()-os.path.getmtime('$HOME/.cache/bk/branches-sweep.stamp')) >= 29)")" "True" "y no vuelve a marcarla antes de 10 min"
rm -f "$HOME/.cache/bk/branches-sweep.stamp"
BK_NO_SWEEP=1 hub status "$REPO" >/dev/null
check_eq "$([ -f "$HOME/.cache/bk/branches-sweep.stamp" ] && echo marcó || echo no)" "no" "BK_NO_SWEEP=1: status no la dispara"

# ---------- bk land anota la rama que entró ----------
python3 -c "import sys; sys.path.insert(0, '$ROOT/lib'); import branches as B; B.note_landed('$REPO', 'x', 'abc')"
check_eq "$(jq -r --arg r "$REPO" '.[$r].x' "$HOME/.cache/bk/landed.json")" "abc" "note_landed guarda la rama y su commit por repo"
check_eq "$(grep -c 'note_landed' "$ROOT/lib/land.py")" "1" "bk land llama a note_landed al entrar"

echo "1..$N"
[ "$FAILED" -eq 0 ]
