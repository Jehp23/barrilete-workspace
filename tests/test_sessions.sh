#!/usr/bin/env bash
# bk s (lib/sessions.py): el número del workspace en cada chat y qué cierra x. Sin tmux: datos de prueba.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
py() { python3 - "$ROOT/lib" "$@" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import sessions as S
cmd, a = sys.argv[2], sys.argv[3:]
if cmd == "where":   # sesión ventana wsid
    print(S.where({"session": a[0], "window": a[1], "wsid": a[2] if len(a) > 2 else ""}))
elif cmd == "close":   # sesión actual
    it = {"session": a[0] or None, "target": f"{a[0]}:1", "pane": "%1"}
    print(*S.close_action(it, a[1] or None))
PY
}
check_eq "$(py where bk-barrilete-workspace main 3)" "ws 3" "chat de un workspace: su número fijo"
check_eq "$(py where agents i226)" "i226" "agente: su ventana"
check_eq "$(py where term-abra zsh)" "term-abra:zsh" "otra sesión sin número: sesión y ventana"
check_eq "$(py close agents bk-x)" "window agents:1" "x sobre un agente: cierra su ventana"
check_eq "$(py close bk-barrilete-workspace bk-otro)" "session bk-barrilete-workspace" "x sobre otro workspace: cierra el workspace (con confirmación)"
check_eq "$(py close bk-otro bk-otro | cut -d' ' -f1)" "error" "x sobre el workspace donde estás: no"
check_eq "$(py close term-abra bk-otro | cut -d' ' -f1)" "error" "x sobre otra sesión de tmux: no"
echo "1..$N"
[ "$FAILED" -eq 0 ]
