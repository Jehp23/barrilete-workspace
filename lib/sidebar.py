#!/usr/bin/env python3
"""bk sidebar: tira izquierda del workspace con las sesiones activas, a lo Gentle Shell 4.

    1 ●     arriba: los workspaces (sesiones bk-*), en orden de creación; alt+1…9 salta a cada uno
    2 ○     abajo: los agentes (ventanas de la sesión "agents")
    ─       ● trabajando · ● rojo te espera · ○ libre/listo · · sin claude
    └⠋      debajo de un chat o agente: sus subagentes vivos (herramienta Agent); clic = su sesión en un popup
    1 ●     el actual va resaltado. Clic en una fila para ir ahí; con el mouse encima, su nombre
            (proyecto · feature) aparece en la barra de tmux, como un tooltip.
"""
import curses, glob, json, os, re, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import agents as AG  # noqa: E402  (nombre de los chats: bk name, /rename o el título de Claude)

TIP_MS = 2500           # cuánto queda el nombre en la barra de tmux al pasar el mouse

STATE = os.path.expanduser("~/.cache/sketchybar/agents")
AGENTS = os.environ.get("BK_SESSION", "agents")


def sh(*a):
    try:
        return subprocess.run(a, capture_output=True, text=True, timeout=3).stdout
    except Exception:
        return ""


def states():
    out = {}
    for f in glob.glob(os.path.join(STATE, "*.json")):
        try:
            s = json.load(open(f))
        except Exception:
            continue
        p = s.get("pane")
        s["_sid"] = os.path.basename(f)[:-5]
        if p and (p not in out or s.get("ts", 0) > out[p].get("ts", 0)):
            out[p] = s
    return out


PROJECTS = os.path.expanduser("~/.claude/projects")
_subdirs = {}


def subagents(sid):
    """Subagentes vivos de una sesión de Claude Code: (descripción, en segundo plano?).
    Vivo = su meta.json no dice finished y su transcript se escribió hace menos de 10 min
    (uno que murió sin avisar no queda para siempre)."""
    if not sid:
        return []
    d = _subdirs.get(sid)
    if d is None or not os.path.isdir(d):
        hit = glob.glob(os.path.join(PROJECTS, "*", sid, "subagents"))
        d = _subdirs[sid] = hit[0] if hit else ""
    if not d:
        return []
    out, now = [], time.time()
    for m in glob.glob(os.path.join(d, "agent-*.meta.json")):
        j = m[:-len(".meta.json")] + ".jsonl"
        try:
            if now - os.path.getmtime(j) > 600:
                continue
            meta = json.load(open(m))
        except Exception:
            continue
        if meta.get("finished"):
            continue
        desc = meta.get("description") or meta.get("agentType") or "subagente"
        out.append((desc, meta.get("requestShape") == "background", os.path.getmtime(j), j))
    return [(d_, bg, j) for d_, bg, _, j in sorted(out, key=lambda x: -x[2])]


def feature(title, path):
    """En qué trabaja: el título de la sesión de Claude (sin el glifo de estado); si no hay, la rama."""
    t = (title or "").strip()
    while t and not t[0].isalnum() and t[0] not in "#/":
        t = t[1:].lstrip()
    if t and t not in ("chat", "rail") and not t.endswith(".local"):
        return t
    br = sh("git", "-C", path, "branch", "--show-current").strip() if path else ""
    return br


def project_name(path):
    top = sh("git", "-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir").strip() if path else ""
    if top.endswith("/.git"):
        return os.path.basename(top[:-5])
    return os.path.basename(path or "") or "?"


def workspaces():
    rows = []
    for l in sh("tmux", "list-sessions", "-F", "#{session_created}\t#{session_name}").splitlines():
        t, _, name = l.partition("\t")
        if name.startswith("bk"):
            rows.append((int(t or 0), name))
    return [n for _, n in sorted(rows)]


def claude_in(pane):
    """¿Corre un claude dentro de este pane? Con `claude …; exec $SHELL` (como lo lanzan bk ws y bk restore)
    tmux muestra zsh como comando aunque claude esté vivo adentro."""
    pid = sh("tmux", "display-message", "-p", "-t", pane, "#{pane_pid}").strip()
    if not pid:
        return False
    return any(re.search(r"(^|[\s/])claude(\s|$)", l) for l in sh("ps", "-o", "command=", "-g", pid).splitlines())


def pane_state(st, pane, cmd, dead):
    if dead == "1":
        return "none"
    if cmd in ("zsh", "bash", "sh", "fish", "-zsh", "login", "") and not claude_in(pane):
        return "none"
    d = st.get(pane) or {}
    state = d.get("state", "idle")
    # "working" sin ningún evento del hook en 5 min: probablemente trabado
    if state == "working" and d.get("tool") != "confianza" and time.time() - d.get("ts", time.time()) > 300:
        return "stale"
    if state == "waiting":
        return "question" if (d.get("wait") or ("question" if d.get("tool") == "AskUserQuestion" else "")) == "question" else "permission"
    return state


def items():
    st = states()
    out = []
    for name in workspaces():
        # Estado del chat del workspace (el pane que corre claude en la ventana main)
        state, subs, info = "none", [], ""
        for l in sh("tmux", "list-panes", "-t", f"{name}:main", "-F",
                    "#{pane_id}\t#{pane_current_command}\t#{pane_dead}\t#{pane_start_command}\t#{pane_title}\t#{pane_current_path}").splitlines():
            pid, cmd, dead, start, title, path = (l.split("\t") + [""] * 6)[:6]
            if "bk rail" in start or "bk sidebar" in start:
                continue
            # el nombre del chat: bk name / --nombre, si no el de /rename o el título que le puso Claude
            nm = sh("tmux", "show-options", "-qv", "-t", name, "@bk_name").strip() \
                or AG.session_title((st.get(pid) or {}).get("_sid"))
            info = (project_name(path), nm or feature(title, path))
            s = pane_state(st, pid, cmd, dead)
            if s != "none":
                state = s
                subs = subagents((st.get(pid) or {}).get("_sid"))
        out.append(("ws", name, name, state, info or (name[3:], "")))
        out += [("sub", d, "sub:" + j, "background" if bg else "working", ("", d)) for d, bg, j in subs]
    for l in sh("tmux", "list-panes", "-s", "-t", AGENTS, "-F",
                "#{window_name}\t#{pane_id}\t#{pane_current_command}\t#{pane_dead}\t#{@bk_ws}\t#{pane_title}\t#{pane_current_path}").splitlines():
        win, pid, cmd, dead, ws, title, path = (l.split("\t") + [""] * 7)[:7]
        if ws:      # el chat de un workspace, de visita mientras un agente ocupa su lugar
            continue
        state = pane_state(st, pid, cmd, dead)
        ref = (st.get(pid) or {}).get("ref") or ""
        out.append(("ag", win, f"{AGENTS}:{win}", state,
                    (f"{project_name(path)} · {win}", " ".join(x for x in (ref, feature(title, path)) if x))))
        if state != "none":
            out += [("sub", d, "sub:" + j, "background" if bg else "working", ("", d))
                    for d, bg, j in subagents((st.get(pid) or {}).get("_sid"))]
    return out


def current():
    pane = os.environ.get("TMUX_PANE", "")
    return sh("tmux", "display-message", "-p", "-t", pane, "#{session_name}").strip()


def go(target):
    # El cliente que mira este pane es el que cambia (no otro cliente conectado a otra ventana)
    pane = os.environ.get("TMUX_PANE", "")
    client = sh("tmux", "display-message", "-p", "-t", pane, "#{client_name}").strip()
    c = ["-c", client] if client else []
    if target == "__new__":
        sess = sh("tmux", "display-message", "-p", "-t", pane, "#{session_name}").strip()
        subprocess.Popen(["tmux", "display-popup"] + c + ["-w", "70%", "-h", "60%", "-E",
                          f"BK_CLIENT='{client}' BK_FROM='{sess}' bk new"])
        return
    if target.startswith("sub:"):
        # Subagente: su sesión en vivo, de solo lectura (bk sub). q/esc cierra.
        path = target[4:].replace("'", "")
        subprocess.Popen(["tmux", "display-popup"] + c + ["-w", "92%", "-h", "88%", "-T", " ↳ subagente ", "-E",
                          f"bk sub '{path}'"])
        return
    if target.startswith(AGENTS + ":"):
        # El agente se ve encima, en un popup de solo lectura (bk watch): q/esc lo cierra, enter va a
        # su ventana para escribirle. Antes era un tmux dentro del popup y las teclas no le llegaban.
        win = target.split(":", 1)[1]
        subprocess.Popen(["tmux", "display-popup"] + c + ["-w", "92%", "-h", "88%", "-E",
                          f"BK_WATCH_KEYS=1 BK_WATCH_CLIENT='{client}' bk watch '{win}'"])
        return
    subprocess.run(["tmux", "switch-client"] + c + ["-t", target], capture_output=True)


def ui(scr):
    curses.curs_set(0)
    curses.use_default_colors()
    curses.mousemask(curses.ALL_MOUSE_EVENTS | curses.REPORT_MOUSE_POSITION)
    # Movimiento del mouse sin botones (modo 1003): ncurses no siempre lo pide solo. Sin SGR (1006):
    # el terminfo de tmux espera el formato X10 (kmous=\E[M) y curses leería mal el otro.
    sys.stdout.write("\033[?1003h"); sys.stdout.flush()
    me = os.environ.get("TMUX_PANE", "")
    client = sh("tmux", "display-message", "-p", "-t", me, "#{client_name}").strip() if me else ""
    hover_y, hover_t, tips = -1, 0.0, {}
    try:   # de día, tonos oscuros y apagados (los de noche son pastel y sobre fondo claro gritan)
        from gentle import is_day
        day = is_day()
    except Exception:
        day = False
    colors = {1: 137, 2: 131, 3: 243, 4: 132, 5: 60} if day else {1: 222, 2: 210, 3: 244, 4: 218, 5: 147}
    for k, v in colors.items():
        curses.init_pair(k, v, -1)
    WORK, WAIT, MUTED, ROSE, IRIS = (curses.color_pair(i) for i in range(1, 6))

    def tooltip(text):
        """El nombre de la fila, como tooltip en la barra de tmux (la tira no cambia de ancho)."""
        if text:
            sh("tmux", "display-message", *(["-c", client] if client else []), "-d", str(TIP_MS), text)

    scr.timeout(250)          # 4 cuadros por segundo para el spinner; los datos, cada 1 s
    rowmap = {}
    tick, cache, cache_t = 0, [], 0
    while True:
        tick += 1
        if time.time() - cache_t > 1:
            cache, cache_t = items(), time.time()
        H, W = scr.getmaxyx()
        scr.erase()
        cur = current()
        rowmap.clear()
        y, n_ws, n_ag, sep = 1, 0, 0, False
        tips.clear()
        if hover_y >= 0 and time.time() - hover_t > TIP_MS / 1000:   # se fue el mouse: sacar el resaltado
            hover_y = -1
        for kind, label, target, state, info in cache:
            if kind == "ag" and not sep:
                if y < H - 1:
                    scr.addnstr(y, 1, "─" * max(1, W - 2), W - 2, MUTED)
                y += 1
                sep = True
            if y >= H - 1:
                break
            hl = curses.A_REVERSE if y == hover_y else 0
            if kind == "sub":   # subagente: rama debajo de su chat, sin número; clic = su sesión
                scr.addnstr(y, 1, "└", 1, MUTED | hl)
                dot = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"[tick % 10] if state == "working" else "◐◓◑◒"[(tick // 2) % 4]
                scr.addnstr(y, 3, dot, 1, WORK)
                tips[y] = f"↳ subagente · {info[1]}"
                rowmap[y] = target
                y += 1
                continue
            if kind == "ws":
                n_ws += 1; num = n_ws
            else:
                n_ag += 1; num = n_ag
            if state == "working":
                dot, col = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"[tick % 10], WORK
            elif state == "background":
                dot, col = "◐◓◑◒"[(tick // 2) % 4], WORK
            elif state == "stale":
                dot, col = "~", WAIT
            elif state == "question":
                dot, col = "?", WAIT
            elif state == "permission":
                dot, col = "!", WAIT
            elif state == "waiting":
                dot, col = "●", WAIT
            elif state == "none":
                dot, col = "·", MUTED
            else:
                dot, col = "○", MUTED
            here = kind == "ws" and label == cur
            numattr = (ROSE | curses.A_BOLD | curses.A_REVERSE) if here else (IRIS if kind == "ag" else 0)
            scr.addnstr(y, 1, f"{num:>1}", 2, numattr | hl)
            scr.addnstr(y, 3, dot, 1, col)
            proj, feat = info
            tips[y] = (f"{'workspace' if kind == 'ws' else 'agente'} {num} · {proj}" + (f" · {feat}" if feat else ""))
            rowmap[y] = target
            y += 1
        # "+" al pie: Nuevo (chat o workspace), igual que alt+n
        if H - 2 > y:
            scr.addnstr(H - 2, 1, " + ", W - 1, ROSE | curses.A_BOLD)
            rowmap[H - 2] = "__new__"
        scr.refresh()
        k = scr.getch()
        if k == curses.KEY_MOUSE:
            try:
                _, mx, my, _, b = curses.getmouse()
            except curses.error:
                continue
            CLICK = (curses.BUTTON1_CLICKED | curses.BUTTON1_PRESSED | curses.BUTTON1_RELEASED
                     | curses.BUTTON1_DOUBLE_CLICKED)
            # Movimiento: el curses de macOS no lo marca con REPORT_MOUSE_POSITION sino con otros bits;
            # todo evento que no sea un clic izquierdo cuenta como "el mouse está acá"
            if not b & CLICK:
                if my != hover_y:          # entró a otra fila: mostrar su nombre una vez
                    tooltip(tips.get(my, ""))
                hover_y, hover_t = my, time.time()
                continue
            if my in rowmap and b & (curses.BUTTON1_CLICKED | curses.BUTTON1_PRESSED | curses.BUTTON1_RELEASED):
                go(rowmap[my])


if __name__ == "__main__":
    # Nunca cerrarse: si algo falla (un clic raro, tmux ocupado), anotar el error y volver a dibujar.
    # Si el proceso termina, tmux cierra el pane y la tira desaparece del workspace.
    import traceback
    log = os.path.expanduser("~/.cache/bk/sidebar.log")
    while True:
        try:
            curses.wrapper(ui)
        except KeyboardInterrupt:
            break
        except Exception:
            os.makedirs(os.path.dirname(log), exist_ok=True)
            with open(log, "a") as f:
                f.write(time.strftime("%F %T ") + traceback.format_exc() + "\n")
            time.sleep(1)
