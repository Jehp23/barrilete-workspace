#!/usr/bin/env bash
# La tira dice con certeza quién lanzó a quién: debajo de cada ventana, sus subagentes (id corto de agent-<id>)
# y los agentes bk que lanzó; cada agente bk, de qué ventana viene (←3). bk lo anota al lanzar (@bk_parent).
# Sin tmux real: bk ve un tmux falso y la tira, un sh() falso.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }

# launcher <respuesta de tmux a display-message> [TMUX_PANE]: lo que bk anotaría como @bk_parent
mkdir -p "$TMP/fake"
cat >"$TMP/fake/tmux" <<'SH'
#!/bin/sh
case "$1" in display-message) printf '%s\n' "$FAKE_DISPLAY" ;; *) exit 1 ;; esac
SH
chmod +x "$TMP/fake/tmux"
launcher() { FAKE_DISPLAY="$1" TMUX_PANE="${2-%1}" PATH="$TMP/fake:$PATH" HOME="$TMP" "$ROOT/bin/bk" _launcher 2>&1; }
check_eq "$(launcher 'bk-kit-3|3||main')" "ws:bk-kit-3" "desde el chat de un workspace: su sesión (no el número, que se reusa)"
check_eq "$(launcher 'agents|||f268')" "ag:f268" "desde un agente bk: su ventana"
check_eq "$(launcher 'agents||bk-kit-3|f268')" "ws:bk-kit-3" "desde un chat de visita en la sesión de agentes: el workspace del chat"
check_eq "$(launcher 'otra|||x')" "" "desde una sesión de tmux que no es de bk: nada"
check_eq "$(launcher 'bk-kit-3|3||main' '')" "" "fuera de tmux: nada"

# filas: la tira (items) con dos workspaces y cuatro agentes bk; "tipo:texto" de cada fila, en orden
rows() { python3 - "$ROOT/lib" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import sidebar as S
S.AGENTS = "agents"
S.workspaces = lambda: [(3, "bk-kit-3"), (5, "bk-abra")]
S.states = lambda: {p: {"_sid": "s" + p[1:]} for p in ("%1", "%2", "%10", "%11", "%12", "%13", "%14")}
SUBS = {"s1": [("Review PR 268", True, "/p/s1/subagents/agent-a00d678b53460124b.jsonl")],
        "s10": [("Explorar", False, "/p/s10/subagents/agent-a2c5a2bd20cb67700.jsonl")]}
S.subagents = lambda sid: SUBS.get(sid, [])
S.AG.session_title = lambda sid: ""
S.U.context_of = lambda sid: None
S.HO.ready_sids = lambda: set()
def sh(*a, **k):
    if a[:2] == ("tmux", "list-panes") and a[3] == "bk-kit-3:main":
        return "%1\t2.1\t0\tclaude\tchat\t/kit\n"
    if a[:2] == ("tmux", "list-panes") and a[3] == "bk-abra:main":
        return "%2\t2.1\t0\tclaude\tchat\t/abra\n"
    if a[:2] == ("tmux", "list-panes") and "-s" in a:
        return ("f268\t%10\t2.1\t0\t\tt\t/kit\tws:bk-kit-3\n"
                "i147\t%11\t2.1\t0\t\tt\t/abra\tws:bk-abra\n"
                "r268\t%12\t2.1\t0\t\tt\t/kit\tag:f268\n"
                "viejo\t%13\t2.1\t0\t\tt\t/kit\t\n"
                "suelto\t%14\t2.1\t0\t\tt\t/kit\tws:bk-cerrado\n")
    return ""
S.sh = sh
S.project_name = lambda p: p.strip("/") or "?"
print(" ".join(f"{r[0]}:{S.row_label(r)}" for r in S.items()))
PY
}
check_eq "$(rows)" "ws:3 sub:a00d67 kid:f268 ws:5 kid:i147 ag:f268 ←3 sub:a2c5a2 kid:r268 ag:i147 ←5 ag:r268 ←f268 ag:viejo ag:suelto ←?" \
  "cada ventana con sus subagentes y los agentes que lanzó; cada agente, de dónde viene (←? si esa ventana ya se cerró)"

echo "1..$N"
[ "$FAILED" -eq 0 ]
