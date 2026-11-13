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

# --- Con Herdr: saltar a una sesión es mostrar su pestaña; retomar una reciente, un chat más de su proyecto ---
# hc, herdr-app y bk falsos: nada toca el Herdr real ni abre chats
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/hc" <<EOF
#!/bin/sh
echo "hc \$*" >>"$TMP/log"
case "\$1 \$2" in
  "ls --json") echo '{"terminals":[{"address":"t7","state":"live","where":"proj / chat"},{"address":"t8","state":"finished","where":"proj / 2"}]}' ;;
  "get t7")    echo '{"labels":{"herdr.space":"sp1","herdr.tab":"tb7"}}' ;;
  "get t9")    echo '{"labels":{}}' ;;
esac
EOF
printf '#!/bin/sh\necho "app $*" >>"%s/log"\necho "{}"\n' "$TMP" >"$TMP/herdr-app"
printf '#!/bin/sh\necho "bk $* | $BK_BACKEND | $BK_PROJECT | $WS_CHAT_CMD" >>"%s/log"\n' "$TMP" >"$TMP/bk"
printf '#!/bin/sh\necho "tmux $*" >>"%s/log"\nexit 1\n' "$TMP" >"$TMP/tmux"
chmod +x "$TMP"/*; mkdir -p "$TMP/dir con espacio"
hpy() { : >"$TMP/log"; PATH="$TMP:$PATH" BK_HC="$TMP/hc" BK_HERDR_APP="$TMP/herdr-app" BK_BACKEND="${BACK:-herdr}" python3 - "$ROOT/lib" "$TMP" "$@" <<'PY2'
import sys; sys.path.insert(0, sys.argv[1]); import sessions as S
tmp, cmd, a = sys.argv[2], sys.argv[3], sys.argv[4:]
S.BK = tmp + "/bk"
def run(res):
    err, steps = res
    for st in steps or []:
        st() if callable(st) else S.subprocess.run(st)
    print(err or "ok")
if cmd == "panes":
    print(sorted(S.herdr_panes()), S.where(S.herdr_panes()["t7"]))
elif cmd == "gone":   # pane, panes de tmux, terminales de Herdr
    print(S.gone(a[0], dict.fromkeys(a[1].split()), dict.fromkeys(a[2].split())))
elif cmd == "open":   # dirección de una sesión abierta en Herdr
    run(S.open_row({"sid": "s1", "pane": a[0], "target": a[0], "herdr": True, "state": "idle"}))
elif cmd == "resume":   # carpeta de una sesión reciente
    run(S.open_row({"sid": "abc-123", "cwd": a[0], "proj": "proj"}))
elif cmd == "close":
    print(S.close_action({"herdr": True, "pane": "t7", "target": "t7", "session": "herdr"}, None)[1].split(":")[0])
PY2
}
check_eq "$(hpy panes)" "['t7'] proj / chat" "Herdr: las terminales vivas, con su espacio y pestaña (una terminada no cuenta)"
check_eq "$(hpy gone t8 '%1' 't7')" "True" "una sesión cuya terminal de Herdr ya no está: se fue"
check_eq "$(hpy gone t7 '%1' 't7')" "False" "una sesión en una terminal viva de Herdr: sigue, aunque tmux no la conozca"
check_eq "$(hpy gone t7 '%1' '')" "False" "Herdr no respondió (o el backend es tmux): no se da por muerta una terminal suya"
check_eq "$(hpy gone '%5' '%1' 't7')" "True" "un pane de tmux que ya no está: se fue"
check_eq "$(hpy gone '%5' '' 't7')" "False" "tmux no respondió: no se da por muerto un pane suyo"
check_eq "$(hpy open t7)" "ok" "Herdr: enter sobre una sesión abierta no da error"
check_eq "$(grep -c '^tmux' "$TMP/log") $(grep '^app' "$TMP/log" | tr '\n' ';')" "0 app do space.select --id sp1;app do tab.select --id tb7;app do pane.focus --terminal t7;" "Herdr: muestra su espacio, su pestaña y la enfoca, sin tmux"
check_eq "$(hpy open t9 | cut -d' ' -f1-3) $(grep -c '^app' "$TMP/log")" "no encuentro su 0" "Herdr: una terminal sin pestaña avisa y no hace nada"
check_eq "$(hpy resume "$TMP/dir con espacio")" "ok" "Herdr: enter sobre una reciente no da error"
check_eq "$(grep -c '^tmux' "$TMP/log") $(grep '^bk' "$TMP/log")" "0 bk chat | herdr | $TMP/dir con espacio | cd '$TMP/dir con espacio' && claude --resume abc-123" "Herdr: retomar es bk chat en su proyecto, con claude --resume en la carpeta de la sesión, sin tmux"
BACK=tmux hpy resume "$TMP/dir con espacio" >/dev/null
check_eq "$(grep -c '^bk' "$TMP/log") $(grep -c '^tmux has-session' "$TMP/log")" "0 1" "con tmux, retomar sigue siendo una ventana de tmux"
check_eq "$(hpy close)" "vive en Herdr" "x sobre una sesión de Herdr: no cierra nada y dice dónde cerrarla"
echo "1..$N"
[ "$FAILED" -eq 0 ]
