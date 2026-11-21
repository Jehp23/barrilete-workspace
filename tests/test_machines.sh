#!/usr/bin/env bash
# bk machines sync (lib/machines.py): deja en cada máquina conectada el mismo commit de bk que esta, en su propio
# worktree (<repo>-wt/bk-sync), apunta ~/.local/bin/bk ahí y corre bk backend herdr allá. Todo es falso y local: hc
# (BK_HC) corre cada "máquina" en su carpeta de $TMP/m/<nombre> con HOME ahí; el repo de bk es uno de prueba
# (BK_SYNC_REPO) cuyo bin/bk solo anota con qué lo llamaron. Nada toca ~/.local/bin, Herdr ni el repo real.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
. "$ROOT/scripts/agents/tap.sh"
tap_begin "tests/test_machines.sh"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
tap_at_exit 'rm -rf "$TMP"'

export HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset XDG_CONFIG_HOME XDG_CACHE_HOME XDG_STATE_HOME
mkdir -p "$HOME" "$TMP/bin"

# hc machine ls --json: $TMP/machines.json · hc exec [-i] [--timeout n] --on <m> -- prog…: corre prog con HOME y
# cwd en $TMP/m/<m>; sin -i, sin stdin (como el de verdad)
cat >"$TMP/bin/hc" <<EOF
#!/usr/bin/env bash
case "\$1" in
  machine) cat "$TMP/machines.json" ;;
  exec) shift; stdin=0; on=
    while [ \$# -gt 0 ]; do case "\$1" in
      -i|--stdin) stdin=1; shift ;; --on) on=\$2; shift 2 ;; --timeout) shift 2 ;; --) shift; break ;; *) break ;;
    esac; done
    home="$TMP/m/\$on"; cd "\$home" || exit 1
    if [ \$stdin = 1 ]; then HOME="\$home" exec "\$@"; else HOME="\$home" exec "\$@" </dev/null; fi ;;
  *) echo "hc falso: no sé \$1" >&2; exit 2 ;;
esac
EOF
chmod +x "$TMP/bin/hc"
export BK_HC="$TMP/bin/hc" BK_SYNC_REPO="$TMP/local"

M1="$TMP/m/m1"; KIT="$M1/Projects/kit"; WT="$M1/Projects/kit-wt/bk-sync"

# El mundo de cada caso: un repo de origen; el bk de esta máquina (un clon con un commit que no pusheó) y la
# máquina m1 conectada, con su clon, su ~/.local/bin/bk apuntando a él y un cambio sin commitear; m2 desconectada.
world() {
  rm -rf "$TMP/src" "$TMP/local" "$TMP/m"
  mkdir -p "$TMP/src/bin" "$M1/.local/bin" "$M1/Projects"
  git init -q -b main "$TMP/src"
  printf '#!/bin/sh\necho "$*" >>"$HOME/bk.log"\n' >"$TMP/src/bin/bk"; chmod +x "$TMP/src/bin/bk"
  echo uno >"$TMP/src/README"
  git -C "$TMP/src" add -A; git -C "$TMP/src" commit -q -m uno
  git clone -q "$TMP/src" "$TMP/local"
  git clone -q "$TMP/src" "$KIT"
  ln -s "$KIT/bin/bk" "$M1/.local/bin/bk"
  : >"$M1/bk.log"
  echo "a medias" >>"$KIT/README"
  echo dos >>"$TMP/local/README"; git -C "$TMP/local" commit -q -am "dos, sin pushear"
  WANT=$(git -C "$TMP/local" rev-parse HEAD 2>&1)
  OLD=$(git -C "$KIT" rev-parse HEAD 2>&1)
  printf '%s' '{"machines":[{"name":"m1","host":"h1","state":"connected"},{"name":"m2","host":"h2","state":"disconnected"}]}' >"$TMP/machines.json"
}

# --- sync: el commit viaja, el worktree propio queda en él, bk apunta ahí y corre backend herdr
world
tap_run out 0 python3 "$ROOT/lib/machines.py" sync
wl=$(git -C "$KIT" worktree list --porcelain 2>&1)
[[ "$wl" == *"worktree $WT"$'\n'"HEAD $WANT"* ]]
tap_check $? "sync deja en bk-sync de la otra máquina el commit de esta, aunque no esté pusheado" "$out"
link=$(readlink "$M1/.local/bin/bk" 2>&1)
[ "$link" = "$WT/bin/bk" ]
tap_check $? "sync apunta ~/.local/bin/bk de la otra máquina a bk-sync"
grep -qx "backend herdr" "$M1/bk.log"
tap_check $? "sync corre bk backend herdr en la otra máquina"
st=$(git -C "$KIT" status --porcelain 2>&1); head=$(git -C "$KIT" rev-parse HEAD 2>&1)
[[ "$st" = " M README" && "$head" = "$OLD" ]]
tap_check $? "sync no toca el checkout de la persona en la otra máquina" "$st"
[[ "$out" == *m2*desconectada* ]]
tap_check $? "sync salta una máquina desconectada y lo dice" "$out"

# --- otra vez, sin cambios: ya está al día y no vuelve a correr backend herdr
: >"$M1/bk.log"
tap_run out 0 python3 "$ROOT/lib/machines.py" sync
[[ "$out" == *"m1"*"al día"* && ! -s "$M1/bk.log" ]]
tap_check $? "sync otra vez dice que la máquina ya está al día" "$out"

# --- --dry-run: dice qué haría y no cambia nada
world
tap_run out 0 python3 "$ROOT/lib/machines.py" sync --dry-run
[[ "$out" == *m1*bk-sync* ]]
tap_check $? "dry-run dice qué haría en cada máquina" "$out"
link=$(readlink "$M1/.local/bin/bk" 2>&1)
[[ ! -e "$WT" && "$link" = "$KIT/bin/bk" && ! -s "$M1/bk.log" ]]
tap_check $? "dry-run no cambia nada en la otra máquina"

# --- bk-sync con cambios a mano: frena esa máquina, no la mueve y sale con 3
world
git -C "$KIT" worktree add -q --detach "$WT" HEAD
echo "a mano" >>"$WT/README"
tap_run out 3 python3 "$ROOT/lib/machines.py" sync
[[ "$TAP_RC" = 3 && "$out" == *m1*"cambios sin commitear"* ]]
tap_check $? "bk-sync con cambios sin commitear frena esa máquina y sale con 3" "rc=$TAP_RC $out"
head=$(git -C "$WT" rev-parse HEAD 2>&1); link=$(readlink "$M1/.local/bin/bk" 2>&1)
[[ "$head" = "$OLD" && "$link" = "$KIT/bin/bk" ]]
tap_check $? "bk-sync con cambios sin commitear no se mueve"

# --- bin/bk: bk --dry-run machines sync llega a lib/machines.py
world
tap_run out 0 "$ROOT/bin/bk" --dry-run machines sync
[[ "$out" == *m1*bk-sync* && ! -e "$WT" ]]
tap_check $? "bk --dry-run machines sync pasa por bin/bk" "$out"

tap_done
