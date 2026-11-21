#!/usr/bin/env bash
# lib/palette.py (alt+k): cada entrada corre un comando que bk conoce, y están las del handoff.
# No abre la paleta ni corre comandos: lee ENTRIES y el case principal de bin/bk.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
N=0; FAILED=0
ok()  { N=$((N+1)); echo "ok $N - $1"; }
bad() { N=$((N+1)); echo "not ok $N - $1"; FAILED=$((FAILED+1)); }

out=$(python3 - "$ROOT" <<'EOF'
import re, sys, importlib.util
root = sys.argv[1]
spec = importlib.util.spec_from_file_location("palette", f"{root}/lib/palette.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
lines = open(f"{root}/bin/bk").read().splitlines()
# El case principal: desde la última línea `case "${1:-}" in` hasta su esac
start = max(i for i, l in enumerate(lines) if l.startswith('case "${1:-}" in'))
end = next(i for i in range(start, len(lines)) if lines[i].startswith("esac"))
known = set()
for l in lines[start + 1:end]:
    mm = re.match(r"^\s+([a-z][a-z0-9|-]*)\)", l)
    if mm:
        known.update(mm.group(1).split("|"))
for e in m.ENTRIES:
    print(f"cmd\t{e[2].split()[0] in known}\t{e[2]}")
cmds = {e[2]: e for e in m.ENTRIES}
for c, arg, kind in [("handoff", True, "show"), ("handoff --listos", False, "show"), ("chat --desde", True, "view")]:
    e = cmds.get(c)
    print(f"handoff\t{bool(e) and bool(e[3]) == arg and e[4] == kind}\t{c}")
ctx = sorted(bool(e[3]) for e in m.ENTRIES if e[2] == "context")
print(f"handoff\t{ctx == [False, True]}\tcontext (ver y cambiar el umbral)")
EOF
) || { echo "not ok - no pude leer la paleta o bin/bk"; exit 1; }

n_cmd=0; n_bad=0
while IFS=$'\t' read -r what good cmd; do
  case "$what" in
    cmd) n_cmd=$((n_cmd+1)); [ "$good" = True ] || { n_bad=$((n_bad+1)); bad "la paleta corre «bk ${cmd}», que bin/bk no conoce"; } ;;
    handoff) if [ "$good" = True ]; then ok "la paleta tiene «bk ${cmd}»"; else bad "falta «bk ${cmd}» en la paleta (o con otro argumento o tipo)"; fi ;;
  esac
done <<<"$out"
if [ "$n_cmd" -eq 0 ]; then bad "no leí ninguna entrada"; elif [ "$n_bad" -eq 0 ]; then ok "las $n_cmd entradas corren comandos que bin/bk conoce"; fi

echo "1..$N"
[ "$FAILED" -eq 0 ]
