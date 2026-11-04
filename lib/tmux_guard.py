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


def decide(cmd):
    """None si pasa; ("deny"|"ask", motivo) si no."""
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
