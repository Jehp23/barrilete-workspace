#!/usr/bin/env python3
"""bk rail: riel derecho del workspace, a lo gentle-shell (Status → Agents → Checkpoints → Changes → radio).

Solo lectura; se redibuja cada 2 s. El detalle está en los overlays: alt+a agentes, alt+g cambios,
alt+k comandos, alt+s sesiones.
"""
import glob, json, os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from gentle import (AMBER, BOLD, FRAME, GREEN, IRIS, MUTED, PETAL, RED, ROSE, RST, TEXT,
                    card, cut, fit, lr, vlen)

HERE = os.path.dirname(os.path.realpath(__file__))
SESSION = os.environ.get("BK_SESSION", "agents")
STATE = os.path.expanduser("~/.cache/sketchybar/agents")
PRS = os.path.expanduser("~/.cache/sketchybar/checkpoints_prs.json")
LESSONS = os.path.join(os.environ.get("BARRILETE_VAULT", os.path.expanduser("~/Documents/Obsidian Vault")),
                       "agents/lessons")
SHELLS = {"zsh", "bash", "sh", "fish", "-zsh", "login"}

_usage = {"t": 0, "data": None}


def sh(*a, cwd=None):
    try:
        return subprocess.run(a, capture_output=True, text=True, timeout=4, cwd=cwd).stdout
    except Exception:
        return ""


def model(m):
    m = (m or "").replace("claude-", "")
    for fam in ("opus", "sonnet", "haiku", "fable"):
        if m.startswith(fam):
            return (fam + " " + m[len(fam):].strip("-").replace("-", ".")).strip()
    return m or "—"


def human(n):
    for u, d in (("M", 1e6), ("k", 1e3)):
        if n >= d:
            return f"{n / d:.1f}{u}"
    return str(int(n))


def ago(ts):
    m = int((time.time() - ts) // 60) if ts else 0
    return f"{m}m" if m < 60 else f"{m // 60}h{m % 60:02d}"


def usage():
    if time.time() - _usage["t"] > 30:
        try:
            _usage["data"] = json.loads(sh(sys.executable, os.path.join(HERE, "usage.py"), "--json"))
        except Exception:
            pass
        _usage["t"] = time.time()
    return _usage["data"] or {}


def states():
    by_pane, all_ = {}, []
    for f in glob.glob(os.path.join(STATE, "*.json")):
        try:
            s = json.load(open(f))
        except Exception:
            continue
        all_.append(s)
        p = s.get("pane")
        if p and (p not in by_pane or s.get("ts", 0) > by_pane[p].get("ts", 0)):
            by_pane[p] = s
    return by_pane, all_


def agents(by_pane):
    live, ended = [], []
    for l in sh("tmux", "list-panes", "-s", "-t", SESSION, "-F",
                "#{window_name}\t#{pane_id}\t#{pane_dead}\t#{pane_current_command}").splitlines():
        p = l.split("\t")
        if len(p) != 4:
            continue
        a = {"win": p[0], "pane": p[1], "s": by_pane.get(p[1], {})}
        (ended if p[2] == "1" or p[3] in SHELLS else live).append(a)
    return live, ended


STATE_UI = {  # estado -> (glifo, texto, color)
    "working": ("●", "working", IRIS), "background": ("◐", "2º plano", AMBER),
    "waiting": ("●", "te espera", RED), "done": ("✓", "listo", GREEN), "idle": ("·", "libre", MUTED),
    "error": ("✗", "error", RED),
}


def card_status(W, cwd, live):
    top = sh("git", "-C", cwd, "rev-parse", "--show-toplevel").strip()
    repo = os.path.basename(top) if top else os.path.basename(cwd)
    br = sh("git", "-C", cwd, "branch", "--show-current").strip()
    dirty = len([l for l in sh("git", "-C", cwd, "status", "--porcelain").splitlines() if l.strip()])
    u = usage()
    working = sum(1 for a in live if a["s"].get("state") in ("working", "background", "waiting"))
    rows = [
        f"{TEXT}{BOLD}{repo}{RST}  {PETAL}{br or '—'}{RST}" + (f" {AMBER}±{dirty}{RST}" if dirty else ""),
        f"{MUTED}hoy{RST} {TEXT}{human(u.get('tokens', 0))}{RST} {MUTED}tok ·{RST} "
        f"{AMBER}${u.get('cost_usd', 0):.2f}{RST} {MUTED}≈API{RST}",
    ]
    right = f"{len(live)} agente{'s' if len(live) != 1 else ''}" + (f" · {working} activo{'s' if working != 1 else ''}" if working else "")
    return card("Status", rows, W, right=right)


def card_agents(W, live, ended):
    if not live and not ended:
        return card("Agents", [f"{MUTED}nadie trabajando · {PETAL}alt+k{MUTED} para lanzar{RST}"], W, glyph="∗")
    rows = []
    inner = W - 4
    for a in live:
        s = a["s"]
        g, txt, col = STATE_UI.get(s.get("state"), ("·", s.get("state") or "—", MUTED))
        if s.get("tool") == "confianza":
            g, txt, col = "●", "confiá carpeta", RED
        if s.get("state") == "background" and s.get("background"):
            txt = f"{s['background']} en 2º plano"
        left = f"{col}{g}{RST} {TEXT}{BOLD}{a['win']}{RST} {MUTED}{s.get('role') or ''}{RST}"
        right = f"{PETAL}{model(s.get('model'))}{RST}  {col}{txt}{RST}  {MUTED}{ago(s.get('ts', 0)):>5}{RST}"
        rows.append(lr(left, right, inner))
        if s.get("state") == "working" and s.get("tool") not in (None, "-", "confianza"):
            rows.append(f"  {MUTED}↳ {s['tool']}{RST}")
    for a in ended:
        rows.append(f"{MUTED}✓ {a['win']} · terminó{RST}")
    active = sum(1 for a in live if a["s"].get("state") in ("working", "background", "waiting"))
    busy = any(a["s"].get("state") in ("working", "background") for a in live)
    waiting = any(a["s"].get("state") == "waiting" for a in live)
    color = RED if waiting else IRIS if busy else FRAME
    title = f"Agents {MUTED}· {active} active · {len(ended)} finished"
    return card(title, rows, W, color=color, accent=IRIS if busy else ROSE, glyph="∗")


def card_checkpoints(W, all_states):
    rows = []
    for s in all_states:
        if s.get("phase") == "plan_pending" and s.get("state") in ("done", "idle"):
            rows.append(f"{RED}●{RST} plan por aprobar {MUTED}· {os.path.basename(s.get('cwd', ''))}{RST}")
    try:
        prs = json.load(open(PRS))
    except Exception:
        prs = []
    for p in prs:
        if p.get("kind", "merge") == "merge":
            rows.append(f"{GREEN}●{RST} mergear {TEXT}{p['repo'].split('/')[-1]}#{p['number']}{RST} {MUTED}{p['title']}{RST}")
        else:
            rows.append(f"{AMBER}●{RST} review {TEXT}{p['repo'].split('/')[-1]}#{p['number']}{RST} {MUTED}{p['title']}{RST}")
    for f in glob.glob(os.path.join(LESSONS, "*.md")):
        try:
            head = open(f, encoding="utf-8").read(600)
        except OSError:
            continue
        if "status: proposed" in head:
            title = next((l[2:] for l in head.splitlines() if l.startswith("# ")), os.path.basename(f))
            rows.append(f"{AMBER}󰌵{RST} lección {MUTED}{title}{RST}")
    if not rows:
        return []
    return card(f"Checkpoints {MUTED}· {len(rows)} tuyos", rows, W, color=FRAME, glyph="◆")


def card_changes(W, roots, max_rows):
    rows, nfiles = [], 0
    for root in roots:
        top = sh("git", "-C", root, "rev-parse", "--show-toplevel").strip()
        if not top:
            continue
        st = [l for l in sh("git", "-C", top, "status", "--porcelain").splitlines() if l.strip()]
        if not st:
            continue
        num = {}
        for l in sh("git", "-C", top, "diff", "--numstat", "HEAD").splitlines():
            p = l.split("\t")
            if len(p) == 3:
                num[p[2]] = (p[0], p[1])
        br = sh("git", "-C", top, "branch", "--show-current").strip()
        name = os.path.basename(top)
        rows.append(f"{PETAL}▾{RST} {TEXT}{name}{RST} {MUTED}{br}{RST}")
        for l in st:
            code, path = l[:2].strip() or "M", l[3:]
            a, d = num.get(path, ("", ""))
            col = GREEN if code in ("A", "??") else RED if code == "D" else AMBER
            stat = (f"{GREEN}+{a}{RST} {RED}-{d}{RST}" if a and a != "-" else "")
            rows.append(lr(f"  {col}{'A' if code == '??' else code}{RST} {TEXT}{path}{RST}", stat, W - 4))
            nfiles += 1
    if not rows:
        return card("Changes", [f"{MUTED}sin cambios sin commitear{RST}"], W, glyph="✎")
    if len(rows) > max_rows:
        rows = rows[: max_rows - 1] + [f"{MUTED}… {PETAL}alt+g{MUTED} para ver todo{RST}"]
    return card(f"Changes {MUTED}· {nfiles} archivos", rows, W, glyph="✎")


def line_radio(W):
    song = os.path.join(HERE, "song.sh")
    if not os.access(song, os.X_OK):
        return []
    parts = sh(song, "bar-status").rstrip("\n").split("\t")
    if not parts or parts[0] not in ("playing", "paused"):
        return []
    state, station, title = (parts + ["", "", ""])[:3]
    icon = "♫" if state == "playing" else "⏸"
    return [cut(f" {ROSE}{icon}{RST} {TEXT}{station}{RST} {MUTED}{title}{RST}", W)]


def frame(W, H, cwd):
    by_pane, all_ = states()
    live, ended = agents(by_pane)
    out = []
    out += card_status(W, cwd, live)
    out += card_agents(W, live, ended)
    out += card_checkpoints(W, all_)
    radio = line_radio(W)
    room = H - len(out) - len(radio) - 2
    roots = [cwd] + [a["s"].get("cwd") for a in live if a["s"].get("cwd")]
    seen, uniq = set(), []
    for r in roots:
        top = sh("git", "-C", r, "rev-parse", "--show-toplevel").strip() if r else ""
        if top and top not in seen:
            seen.add(top); uniq.append(top)
    if room >= 3:
        out += card_changes(W, uniq, room - 2)
    out += [""] * max(0, H - len(out) - len(radio) - 1)
    out += radio
    out.append(fit(f"{PETAL}alt+a{RST} {MUTED}agentes{RST}  {PETAL}alt+g{RST} {MUTED}cambios{RST}  "
                   f"{PETAL}alt+k{RST} {MUTED}comandos{RST}  {PETAL}alt+s{RST} {MUTED}sesiones{RST}", W))
    return out[:H]


def main():
    cwd = os.getcwd()
    sys.stdout.write("\033[?25l\033[2J")
    try:
        while True:
            try:
                sz = os.get_terminal_size(sys.stdout.fileno())
                W, H = sz.columns, sz.lines
            except OSError:
                W, H = 50, 40
            lines = (frame(W, H, cwd) + [""] * H)[:H]
            sys.stdout.write("\033[H" + "\033[K\n".join(cut(l, W) for l in lines) + "\033[K")
            sys.stdout.flush()
            time.sleep(2)
    except KeyboardInterrupt:
        pass
    finally:
        sys.stdout.write("\033[?25h")


if __name__ == "__main__":
    main()
