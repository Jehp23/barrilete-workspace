#!/usr/bin/env python3
"""bk watch --all: columna de agentes del workspace, en un solo panel que se adapta.

0 agentes  -> un estado vacío con qué hacer.
N agentes  -> N secciones parejas: encabezado (ventana · rol · modelo · estado) + lo último que
              dijo/hizo, sin el pie de Claude Code. Los terminados van abajo, en una línea.
Se redibuja cada segundo. Solo lectura: para escribirles, bk say o el chat.
"""
import glob, json, os, re, subprocess, sys, time, unicodedata

SESSION = os.environ.get("BK_SESSION", "agents")
STATE = os.path.expanduser("~/.cache/sketchybar/agents")
SHELLS = {"zsh", "bash", "sh", "fish", "-zsh", "login"}
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")

RST, BOLD, DIM = "\033[0m", "\033[1m", "\033[2m"
MAUVE, GREEN, YELLOW, RED, BLUE, GRAY = (f"\033[38;5;{c}m" for c in (183, 114, 222, 210, 111, 245))
STATE_STYLE = {"working": ("● trabajando", YELLOW), "waiting": ("● te espera", RED),
               "background": ("◐ en 2º plano", YELLOW),
               "done": ("✓ listo", GREEN), "idle": ("· libre", GRAY)}


def sh(*a):
    try:
        return subprocess.run(a, capture_output=True, text=True, timeout=3).stdout
    except Exception:
        return ""


def cw(ch):
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in "WF" else 1


def cut(line, width):
    """Corta a `width` columnas visibles conservando los códigos de color."""
    out, w, i = [], 0, 0
    while i < len(line):
        m = ANSI.match(line, i)
        if m:
            out.append(m.group(0)); i = m.end(); continue
        c = cw(line[i])
        if w + c > width:
            break
        out.append(line[i]); w += c; i += 1
    return "".join(out) + RST


def visible(line):
    return ANSI.sub("", line)


def states_by_pane():
    out = {}
    for f in glob.glob(os.path.join(STATE, "*.json")):
        try:
            s = json.load(open(f))
        except Exception:
            continue
        if s.get("pane"):
            # Si hay dos (pre-registro bk-* y el del hook), gana el más nuevo
            if s["pane"] not in out or s.get("ts", 0) > out[s["pane"]].get("ts", 0):
                out[s["pane"]] = s
    return out


def agents():
    live, ended = [], []
    st = states_by_pane()
    for l in sh("tmux", "list-panes", "-s", "-t", SESSION, "-F",
                "#{window_name}\t#{pane_id}\t#{pane_dead}\t#{pane_current_command}").splitlines():
        p = l.split("\t")
        if len(p) != 4:
            continue
        win, pane, dead, cmd = p
        a = {"win": win, "pane": pane, "state": st.get(pane, {})}
        (ended if dead == "1" or cmd in SHELLS else live).append(a)
    order = {"waiting": 0, "working": 1, "background": 1, "done": 2, "idle": 3}
    live.sort(key=lambda a: order.get(a["state"].get("state"), 9))
    return live, ended


def body(pane):
    lines = [l for l in sh("tmux", "capture-pane", "-p", "-e", "-t", pane).splitlines() if visible(l).strip()]
    seps = [i for i, l in enumerate(lines) if visible(l).startswith("─────")]
    if len(seps) >= 2:          # caja del prompt de Claude Code: fuera
        lines = lines[: seps[-2]]
    return lines


def model(m):
    m = (m or "").replace("claude-", "")
    for fam in ("opus", "sonnet", "haiku", "fable"):
        if m.startswith(fam):
            return (fam + " " + m[len(fam):].strip("-").replace("-", ".")).strip()
    return m


def header(a, W):
    s = a["state"]
    txt, col = STATE_STYLE.get(s.get("state"), (s.get("state") or "", GRAY))
    if s.get("tool") == "confianza":
        txt, col = "● confiá la carpeta", RED
    left = f"{MAUVE}{BOLD}▍{a['win']}{RST}"
    meta = " · ".join(x for x in (s.get("role"), model(s.get("model"))) if x)
    plain = f"▍{a['win']}  {meta}"
    pad = max(1, W - len(plain) - len(txt) - 1)
    return cut(f"{left}  {GRAY}{meta}{RST}" + " " * pad + f"{col}{txt}{RST}", W)


def frame(W, H):
    live, ended = agents()
    out = []
    if not live:
        mid = max(0, H // 2 - 3 - len(ended))
        out += [""] * mid
        out += [f"  {GRAY}sin agentes trabajando{RST}", "",
                f"  {BLUE}bk run <issue>{RST}   {GRAY}implementer{RST}",
                f"  {BLUE}bk review <pr>{RST}   {GRAY}reviewer{RST}",
                f"  {BLUE}C-a s{RST}            {GRAY}retomar una sesión{RST}"]
    else:
        room = H - (len(ended) + 1 if ended else 0)
        shown = live[: max(1, room // 5)]            # cada sección necesita al menos 5 filas
        each = room // len(shown)
        for k, a in enumerate(shown):
            last = k == len(shown) - 1
            n = room - each * k if last else each      # la última se queda con el resto
            sec = [header(a, W)]
            content = n - 1 - (0 if last else 1)        # menos encabezado y separador
            lines = body(a["pane"])[-content:] if content > 0 else []
            sec += [""] * (content - len(lines)) + [cut(l, W) for l in lines]
            if not last:
                sec.append(f"{GRAY}{'╌' * W}{RST}")
            out += sec
    if ended:
        out = out[: H - len(ended) - 1] + [""] * max(0, H - len(ended) - 1 - len(out))
        out.append(f"{GRAY}terminados · C-a s para retomar o cerrar{RST}")
        out += [cut(f"  {GRAY}✓ {a['win']}{RST}", W) for a in ended]
    return out[:H]


def main():
    sys.stdout.write("\033[?25l\033[2J")
    try:
        while True:
            try:
                sz = os.get_terminal_size(sys.stdout.fileno())
                W, H = sz.columns, sz.lines
            except OSError:
                W, H = 60, 30
            lines = (frame(W, H) + [""] * H)[:H]
            sys.stdout.write("\033[H" + "\033[K\n".join(cut(l, W) for l in lines) + "\033[K")
            sys.stdout.flush()
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        sys.stdout.write("\033[?25h")


if __name__ == "__main__":
    main()
