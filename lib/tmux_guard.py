#!/usr/bin/env python3
"""Baranda global (hook PreToolUse de Claude Code): que ningún agente tire tu tmux por error.

El 2026-11-04 un chat limpió su tmux de prueba con `TMUX_TMPDIR=$X/tmux tmux kill-server`. Corría dentro de
tu tmux, así que la variable TMUX apuntaba al servidor real; con TMUX definida, tmux usa ese servidor e ignora
TMUX_TMPDIR. Se cayeron todos los agentes, los workspaces y los chats.

Regla:
  - `tmux kill-server` solo pasa si esa llamada apunta a otro servidor: `-L <nombre>`, `-S <socket>`, o TMUX
    sacada antes en el mismo comando (`env -u TMUX tmux …`, `unset TMUX; …`, `TMUX= tmux …`). Si no: se frena.
  - `tmux kill-session` de tus sesiones (`agents`, `bk-…`) sin apuntar a otro servidor: te pregunta.

Instalado en ~/.claude/hooks/tmux_guard.py (copia estable; la fuente vive en barrilete-workspace/lib).
"""
import json
import re
import sys

ISOLATED = re.compile(r"(^|[\s;&|('\"`])(env\s+(-\S+\s+)*-u\s+TMUX\b|unset\s+(\S+\s+)*TMUX\b|TMUX=(\s|''|\"\"))")
TMUX_CALL = re.compile(r"(?<![\w/.-])tmux\b([^;&|\n]*)")
OWN_SESSION = re.compile(r"-t\s*['\"]?=?(agents|bk-[\w.-]+)")


def closed_groups_removed(text):
    """Saca los ( … ) que ya se cerraron: un `unset TMUX` dentro de un subshell no vale para lo que viene después."""
    prev = None
    while prev != text:
        prev = text
        text = re.sub(r"\([^()]*\)", " ", text)
    return text


def tmux_server_pids():
    """PIDs de los servers de tmux vivos. Ojo: el server conserva el argv del comando que lo arrancó
    (p. ej. "tmux new-session -d -s agents …"), así que en ps parece un cliente colgado y no lo es."""
    import subprocess
    try:
        out = subprocess.run(["ps", "-axo", "pid=,ppid=,comm="], capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return set()
    return {int(p) for p, pp, c in (l.split(None, 2) for l in out.splitlines() if len(l.split(None, 2)) == 3)
            if c.strip().endswith("tmux") and pp == "1"}


KILL_PIDS = re.compile(r"(?<![\w-])kill(\s+-\S+)*((\s+\d+)+)")


def decide(cmd):
    """None si pasa; ("deny"|"ask", motivo) si no."""
    for m in KILL_PIDS.finditer(cmd):
        pids = {int(x) for x in m.group(2).split()}
        hit = pids & tmux_server_pids()
        if hit:
            return ("deny", f"kill {' '.join(map(str, sorted(hit)))}: ese PID es el SERVER de tmux (aunque en ps se vea "
                            "como 'tmux new-session …': el server conserva el comando que lo arrancó). Matarlo cierra "
                            "todos los chats y agentes. Para cerrar una sesión usá bk stop o tmux kill-session -t <nombre>.")
    if re.search(r"\b(pkill|killall)\b[^;&|\n]*\btmux\b", cmd):
        return ("deny", "pkill/killall sobre tmux: mataría el server con todos los chats y agentes.")
    for m in TMUX_CALL.finditer(cmd):
        args = m.group(1)
        before = closed_groups_removed(cmd[: m.start()])
        # otro servidor: -L/-S en esta llamada, o TMUX sacada antes (en este comando o en el mismo env)
        other_server = re.search(r"(^|\s)-[LS]\s*\S", args) or ISOLATED.search(before)
        if other_server:
            continue
        if re.search(r"\bkill-server\b", args):
            return ("deny", "tmux kill-server sin apuntar a otro servidor: con la variable TMUX definida, tmux usa TU "
                            "servidor real (TMUX_TMPDIR no alcanza) y se caen todos los agentes y chats. Para un tmux de "
                            "prueba usá `env -u TMUX TMUX_TMPDIR=… tmux kill-server` o `tmux -L <nombre> kill-server`.")
        if re.search(r"\bkill-session\b", args) and OWN_SESSION.search(args):
            return ("ask", "tmux kill-session sobre una sesión tuya (agents o un workspace bk-…). ¿Seguro?")
    return None


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    if data.get("tool_name") != "Bash":
        return
    cmd = str((data.get("tool_input") or {}).get("command", ""))
    if "tmux" not in cmd:
        return
    d = decide(cmd)
    if d:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": d[0],
                                                 "permissionDecisionReason": "baranda tmux: " + d[1]}},
                         ensure_ascii=False))


if __name__ == "__main__":
    main()
