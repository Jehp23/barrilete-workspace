#!/usr/bin/env python3
"""bk clean: limpiar los restos de bk, sin tocar nada vivo.

Restos:
  - procesos sin dueño: claude, codex o un lib/*.py de bk cuyo padre ya no existe (PPID 1). Quedan así
    cuando se cerró la terminal o el pane sin que el proceso se enterara, y siguen ocupando memoria.
  - estado de agentes (BK_STATE_DIR/*.json) de panes de tmux que ya no existen, y *.json.tmp viejos.

Nunca toca: tmux (el server se ve en ps como "tmux new-session …"), lo que tiene padre vivo (los chats de
otras terminales, los agentes), ghapp.py keep (se va solo) ni bk song (mpv). Sin --yes solo muestra.

  clean.py [--yes]
"""
import json
import os
import re
import signal
import subprocess
import sys
import time

WS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE_DIR = os.environ.get("BK_STATE_DIR") or os.path.expanduser("~/.cache/sketchybar/agents")
TMP_AGE = 60   # un .json.tmp más viejo que esto ya no es una escritura en curso


def procs():
    """[(pid, ppid, rss_kb, command)] de todos los procesos."""
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,rss=,command="], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), int(parts[2]) if parts[2].isdigit() else 0, parts[3]))
    return rows


def what(cmd):
    """Qué es el proceso, si es de los que bk limpia; None si no."""
    argv = cmd.split()
    if not argv:
        return None
    name = os.path.basename(argv[0])
    if name == "tmux" or "tmux" in name:
        return None
    if name in ("claude", "codex"):
        if "--chrome-native-host" in argv:   # lo lanza Chrome, no bk
            return None
        return name
    # python3 /…/lib/rail.py, …: un script de bk; el binario de python en macOS se llama Python
    if re.match(r"(?i)python[\d.]*$", name):
        for a in argv[1:3]:
            if a.startswith(os.path.join(WS, "lib") + os.sep) and a.endswith(".py"):
                script = os.path.basename(a)
                return None if script == "ghapp.py" else f"bk {script}"
    return None


def ancestors(rows):
    by = {pid: ppid for pid, ppid, _, _ in rows}
    seen, p = set(), os.getpid()
    while p and p not in seen:
        seen.add(p)
        p = by.get(p, 0)
    return seen


def orphans(rows):
    mine = ancestors(rows)
    out = []
    for pid, ppid, rss, cmd in rows:
        kind = what(cmd)
        if kind and ppid == 1 and pid not in mine:
            out.append((pid, rss, kind, cmd))
    return out


def live_panes():
    """Los panes vivos de tmux, o None si no se pudo preguntar (sin tmux no se borra estado)."""
    try:
        r = subprocess.run(["tmux", "list-panes", "-a", "-F", "#{pane_id}"], capture_output=True, text=True)
    except OSError:
        return None
    if r.returncode != 0:
        return None
    return {l.strip() for l in r.stdout.splitlines() if l.strip()}


def stale_state(panes):
    out = []
    try:
        names = sorted(os.listdir(STATE_DIR))
    except OSError:
        return out
    now = time.time()
    for n in names:
        f = os.path.join(STATE_DIR, n)
        if n.endswith(".json.tmp"):
            try:
                if now - os.path.getmtime(f) > TMP_AGE:
                    out.append((f, "escritura que no terminó"))
            except OSError:
                pass
        elif n.endswith(".json") and panes is not None:
            try:
                with open(f) as fh:
                    pane = (json.load(fh) or {}).get("pane") or ""
            except (OSError, ValueError, AttributeError):
                continue
            if pane and pane not in panes:
                out.append((f, f"pane {pane} cerrado"))
    return out


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def kill(pids, wait=3.0):
    """TERM, y KILL a los que sigan vivos después de wait segundos. Devuelve los que no se pudieron matar."""
    for p in pids:
        try:
            os.kill(p, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except PermissionError:
            pass
    end = time.time() + wait
    while time.time() < end and any(alive(p) for p in pids):
        time.sleep(0.1)
    for p in pids:
        if alive(p):
            try:
                os.kill(p, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
    time.sleep(0.1)
    return [p for p in pids if alive(p)]


def short(cmd, n=70):
    cmd = cmd.replace("\n", " ")
    return cmd if len(cmd) <= n else cmd[: n - 1] + "…"


def main(argv):
    if any(a not in ("--yes", "-y") for a in argv):
        print("uso: bk clean [--yes]", file=sys.stderr)
        return 2
    yes = bool(argv)
    procs_ = orphans(procs())
    panes = live_panes()
    state = stale_state(panes)

    if not procs_ and not state:
        print("nada para limpiar")
        return 0
    if procs_:
        mb = sum(r for _, r, _, _ in procs_) / 1024
        print(f"procesos sin dueño ({len(procs_)}, {mb:.0f} MB):")
        for pid, rss, kind, cmd in procs_:
            print(f"  {pid:>6}  {rss / 1024:>5.0f} MB  {kind:<14} {short(cmd)}")
    if state:
        print(f"estado de agentes viejo ({len(state)}):")
        for f, why in state:
            print(f"  {os.path.basename(f)}  ({why})")
    if panes is None:
        print("(sin tmux: el estado de agentes de panes cerrados no se revisó)")
    if not yes:
        print("Para limpiarlos: bk clean --yes")
        return 0

    left = kill([p for p, _, _, _ in procs_]) if procs_ else []
    for f, _ in state:
        try:
            os.remove(f)
        except FileNotFoundError:
            pass
    done = len(procs_) - len(left)
    print(f"listo: {done} proceso(s) cerrados, {len(state)} archivo(s) de estado borrados")
    if left:
        print(f"no pude cerrar: {' '.join(map(str, left))}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
