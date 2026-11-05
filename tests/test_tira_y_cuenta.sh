#!/usr/bin/env bash
# La tira une los workspaces del mismo proyecto (sidebar.link_projects) y el riel muestra siempre la cuenta
# de la sesión, también la default (rail.session_account). Sin tmux ni cuentas reales: datos de prueba.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }

links() { python3 - "$ROOT/lib" "$1" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import sidebar as S
blocks = []
for tok in sys.argv[2].split():          # "1:a 2:b+ 3:a": número:proyecto, "+" = con un subagente
    n, proj = tok.split(":"); sub = proj.endswith("+"); proj = proj.rstrip("+")
    ws = ("ws", f"bk-{n}", f"bk-{n}", "idle", (proj, ""), int(n), None, proj)
    blocks.append((ws, [("sub", "d", f"sub:{n}", "working", ("", "d"), None, None)] if sub else []))
print(" ".join(f"{r[7] or '.'}{r[5] if r[0] == 'ws' else 's'}" for r in S.link_projects(blocks)))
PY
}
check_eq "$(links '1:c 2:a 3:c 4:b 5:a 6:c')" "╭1 │3 ╰6 ╭2 ╰5 .4" "junta cada proyecto donde está su número más bajo y los une con la línea"
check_eq "$(links '1:a 2:b')" ".1 .2" "un proyecto con un solo workspace: sin línea"
check_eq "$(links '1:a+ 2:a+')" "╭1 │s ╰2 .s" "los subagentes de adentro del grupo siguen la línea; los del último, no"
check_eq "$(links '')" "" "sin workspaces: nada"

acct() { python3 - "$ROOT/lib" "$1" "$2" <<'PY'
import re, sys; sys.path.insert(0, sys.argv[1]); import rail as R
opt, logged = sys.argv[2], sys.argv[3]
R.sh = lambda *a, **k: opt if a[0] == "tmux" and a[-1] == "@bk_account_claude" else ""
R._who = {"t": 9e12, "v": dict(kv.split("=") for kv in logged.split(",") if kv)}
print(re.sub(r"\x1b\[[0-9;]*m", "", R.session_account()))
PY
}
check_eq "$(acct '' 'default=multi@x.com,soporte=sop@x.com')" "multi@x.com" "sesión con la cuenta default: muestra su mail (antes no mostraba nada)"
check_eq "$(acct 'soporte' 'default=multi@x.com,soporte=sop@x.com')" "sop@x.com" "sesión con otra cuenta: su mail"
check_eq "$(acct 'nueva' 'default=multi@x.com')" "nueva" "cuenta sin login: el nombre de la carpeta"

echo "1..$N"
[ "$FAILED" -eq 0 ]
