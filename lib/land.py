#!/usr/bin/env python3
"""bk land / bk claims: N sesiones en paralelo sobre barrilete-workspace sin pisarse.

Modelo (condición de carrera sobre los archivos de main):
  - Nadie edita ni commitea main. Cada sesión trabaja en su rama y su worktree.
  - Claim = "esta rama está modificando este archivo". Lo registra solo el hook de Claude Code al editar
    (Edit/Write) y bk land con lo que la rama cambió. Una rama arranca su turno con su primer claim.
  - Orden: una rama espera a toda rama activa que empezó antes y comparte algún archivo con ella. Es un
    orden total por hora de inicio, así que no hay deadlock (A espera a B en x y B a A en y no puede pasar).
  - Mutex de main: bk land toma un flock global; adentro rebasa sobre main, corre los checks y hace el
    fast-forward. El hook de git (githooks/reference-transaction) solo deja mover main desde bk land.
  - El segundo no corre los checks de más: bk land espera a que el anterior entre (o se libere) y recién
    ahí rebasa y corre los checks, una vez.

  land.py land [--wait] [--timeout S] [--force]   desde el worktree de la rama
  land.py claim <archivo>…                        reclamar a mano (lo hace el hook al editar)
  land.py claims [--json]                         ramas activas, sus archivos y quién espera a quién
  land.py release [rama]                          soltar los claims de una rama (sin rama: la actual)
  land.py hook                                    hook de Claude Code (PreToolUse/PostToolUse), JSON por stdin

Salida de land: 0 entró · 3 espera a otra rama · 4 choque en el rebase (resolvelo en el worktree) ·
5 fallaron los checks · 6 no se pudo hacer el fast-forward · 1 otro error.
"""
import fcntl
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import usage as U   # noqa: E402  contexto de la sesión que corrió bk land (context_of y los umbrales)

STATE_DIR = os.path.expanduser("~/.cache/sketchybar/agents")   # los estados del hook: pane → sesión de Claude


def context_hint():
    """Después de entrar a main, si el chat que corrió bk land ya carga mucho contexto: sugerir cortar. Cada
    llamada vuelve a leer todo el contexto, así que lo próximo sale más barato en una sesión nueva. Nunca
    frena ni rompe el land: ante cualquier duda, no dice nada."""
    pane = os.environ.get("TMUX_PANE", "")
    if not pane:
        return ""
    try:
        best = None
        for n in os.listdir(STATE_DIR):
            if not n.endswith(".json"):
                continue
            f = os.path.join(STATE_DIR, n)
            st = json.load(open(f))
            if st.get("pane") == pane and (best is None or st.get("ts", 0) > best[1]):
                best = (n[:-5], st.get("ts", 0))
        tokens = U.context_of(best[0]) if best else None
    except Exception:
        return ""
    if not U.ctx_level(tokens):
        return ""
    return (f"este chat lleva {U.human_ctx(tokens)} de contexto y cada llamada lo vuelve a leer: para lo próximo, "
            "/clear o un chat nuevo (alt+n)")

HERE = os.path.dirname(os.path.realpath(__file__))
STATE = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
CLAIMS_DIR = os.environ.get("BK_CLAIMS_DIR") or os.path.join(STATE, "bk", "claims")
STALE = int(os.environ.get("BK_CLAIM_STALE", 3 * 3600))   # sin actividad en 3 h: ya no bloquea a nadie
POLL = float(os.environ.get("BK_LAND_POLL", 5))
MAIN_BRANCH = "main"
EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")


def git(*args, cwd=None, check=False, env=None):
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, env=env)
    if check and r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip())
    return r


def out(*args, cwd=None):
    r = git(*args, cwd=cwd)
    return r.stdout.strip() if r.returncode == 0 else ""


def repo_of(path):
    """(checkout de main, worktree, rama) de un archivo o carpeta; None si no está en un repo."""
    d = path if os.path.isdir(path) else os.path.dirname(path)
    while d and not os.path.isdir(d):
        d = os.path.dirname(d)
    if not d:
        return None
    common = out("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=d)
    top = out("rev-parse", "--show-toplevel", cwd=d)
    if not common or not top:
        return None
    main = os.path.dirname(common) if os.path.basename(common) == ".git" else common
    return os.path.realpath(main), os.path.realpath(top), out("branch", "--show-current", cwd=d)


class Store:
    """Los claims de un repo, en un JSON con flock (varias sesiones lo tocan a la vez)."""

    def __init__(self, main):
        self.main = main
        os.makedirs(CLAIMS_DIR, exist_ok=True)
        base = os.path.join(CLAIMS_DIR, os.path.basename(main))
        self.path, self.lock_path, self.land_lock = base + ".json", base + ".lock", base + ".land.lock"

    def __enter__(self):
        self.fd = open(self.lock_path, "a")
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        try:
            with open(self.path) as f:
                self.data = json.load(f)
        except (OSError, ValueError):
            self.data = {}
        self.prune()
        return self

    def __exit__(self, *exc):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.data, f, indent=1, ensure_ascii=False)
        os.replace(tmp, self.path)
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        self.fd.close()

    def prune(self):
        """Fuera las ramas que ya entraron a main, las borradas y las que perdieron su worktree."""
        for b in list(self.data):
            c = self.data[b]
            tip = out("rev-parse", "--verify", "-q", f"refs/heads/{b}", cwd=self.main)
            gone = not tip or not os.path.isdir(c.get("worktree", ""))
            # Entró: su punta ya está en main y tiene commits propios (punta == base es una rama que todavía
            # no commiteó: sus cambios están en el worktree)
            landed = tip and tip != c.get("base") and \
                git("merge-base", "--is-ancestor", tip, MAIN_BRANCH, cwd=self.main).returncode == 0
            if gone or landed:
                del self.data[b]

    def claim(self, branch, worktree, files, pane=""):
        now = time.time()
        c = self.data.setdefault(branch, {"since": now, "worktree": worktree, "files": {},
                                          "base": out("rev-parse", MAIN_BRANCH, cwd=self.main)})
        c["seen"], c["worktree"] = now, worktree
        if pane:
            c["pane"] = pane
        for f in files:
            c["files"].setdefault(f, now)
        return c

    def active(self, b):
        c = self.data.get(b) or {}
        return time.time() - c.get("seen", 0) < STALE

    def ahead_of(self, branch, files=None):
        """Las ramas activas que empezaron antes que esta y comparten archivos: [(rama, [archivos])]."""
        me = self.data.get(branch)
        if not me:
            return []
        mine = set(files or []) | set(me["files"])
        res = []
        for b, c in sorted(self.data.items(), key=lambda kv: kv[1]["since"]):
            if b == branch or c["since"] >= me["since"] or not self.active(b):
                continue
            shared = sorted(mine & set(c["files"]))
            if shared:
                res.append((b, shared))
        return res


def rel(main, worktree, path):
    p = os.path.realpath(path)
    return os.path.relpath(p, worktree) if p.startswith(worktree + os.sep) else None


def changed_files(worktree):
    base = out("merge-base", MAIN_BRANCH, "HEAD", cwd=worktree)
    files = set(out("diff", "--name-only", base, "HEAD", cwd=worktree).splitlines()) if base else set()
    files |= set(out("diff", "--name-only", "HEAD", cwd=worktree).splitlines())
    return sorted(f for f in files if f)


def checks(worktree):
    script = os.path.join(worktree, "lib", "checks.sh")
    if not os.path.exists(script):
        return True, "sin lib/checks.sh"
    r = subprocess.run(["bash", script], cwd=worktree, capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr).strip()


def say(msg):
    print(msg, flush=True)


def land(args):
    wait = "--wait" in args
    force = "--force" in args
    timeout = 540
    if "--timeout" in args:
        timeout = int(args[args.index("--timeout") + 1])
    info = repo_of(os.getcwd())
    if not info:
        sys.exit("bk land: no estás en un repo git")
    main, wt, branch = info
    if not branch or branch == MAIN_BRANCH or wt == main:
        sys.exit("bk land: corrélo desde el worktree de tu rama, no desde main")
    if out("status", "--porcelain", "--untracked-files=no", cwd=wt):
        sys.exit("bk land: hay cambios sin commitear en el worktree; commitealos primero")

    files = changed_files(wt)
    if not files:
        say(f"{branch} no tiene cambios respecto de main")
        return 0
    deadline = time.time() + timeout
    announced = set()
    while True:
        with Store(main) as st:
            st.claim(branch, wt, files, os.environ.get("TMUX_PANE", ""))
            ahead = [] if force else st.ahead_of(branch, files)
        if not ahead:
            break
        for b, shared in ahead:
            if b not in announced:
                say(f"esperando a {b}: también modifica {', '.join(shared)} y empezó antes."
                    " No corras checks todavía: cuando entre, bk land rebasa y los corre una vez.")
                announced.add(b)
        if not wait or time.time() > deadline:
            say("sigue en cola: volvé a correr bk land --wait (o bk claims para ver quién va primero)")
            return 3
        time.sleep(POLL)

    with Store(main) as st:
        lock_path = st.land_lock
    lk = open(lock_path, "a")
    fcntl.flock(lk, fcntl.LOCK_EX)   # mutex de main: un land a la vez
    try:
        if git("merge-base", "--is-ancestor", MAIN_BRANCH, "HEAD", cwd=wt).returncode != 0:
            say(f"main avanzó: rebaso {branch} sobre main")
            r = git("rebase", MAIN_BRANCH, cwd=wt)
            if r.returncode != 0:
                say("choque en el rebase. Resolvelo en el worktree (git status), git rebase --continue y"
                    " bk land de nuevo. Tu turno se conserva.")
                return 4
        ok, log = checks(wt)
        if not ok:
            say("fallaron los checks; no entra:\n" + log)
            return 5
        r = git("merge", "--ff-only", "-q", branch, cwd=main, env={**os.environ, "BK_LANDING": "1"})
        if r.returncode != 0:
            say("no se pudo hacer el fast-forward en el checkout de main:\n" + (r.stderr or r.stdout).strip())
            return 6
        sha = out("rev-parse", "--short", MAIN_BRANCH, cwd=main)
        with Store(main) as st:
            st.data.pop(branch, None)
        try:   # la limpieza sola (lib/branches.py) borra el worktree y la rama cuando nadie trabaja ahí
            import branches as BR
            BR.note_landed(main, branch, out("rev-parse", branch, cwd=main))
        except Exception:
            pass
        say(f"{branch} entró a main ({sha}). bk borra el worktree y la rama solos cuando cierres lo que corre"
            " ahí (o ya: ctrl+x en alt+b)")
        hint = context_hint()
        if hint:
            say(hint)
        return 0
    finally:
        fcntl.flock(lk, fcntl.LOCK_UN)
        lk.close()


def claims(args):
    info = repo_of(os.getcwd())
    if not info:
        sys.exit("bk claims: no estás en un repo git")
    with Store(info[0]) as st:
        data = st.data
        rows = []
        for b, c in sorted(data.items(), key=lambda kv: kv[1]["since"]):
            rows.append({"branch": b, "since": c["since"], "files": sorted(c["files"]),
                         "stale": not st.active(b), "waits_for": [x for x, _ in st.ahead_of(b)]})
    if "--json" in args:
        print(json.dumps(rows, ensure_ascii=False))
        return 0
    if not rows:
        print("nadie está modificando nada")
    for i, r in enumerate(rows, 1):
        t = time.strftime("%H:%M", time.localtime(r["since"]))
        state = "vieja (no bloquea)" if r["stale"] else ("espera a " + ", ".join(r["waits_for"]) if r["waits_for"] else "puede entrar")
        print(f"{i}. {r['branch']}  desde {t} · {state}")
        for f in r["files"]:
            print(f"     {f}")
    return 0


def claim_cmd(args):
    info = repo_of(os.getcwd())
    if not info or info[2] in ("", MAIN_BRANCH):
        sys.exit("bk claim: corrélo desde el worktree de tu rama")
    main, wt, branch = info
    files = [rel(main, wt, os.path.abspath(f)) or f for f in args]
    with Store(main) as st:
        st.claim(branch, wt, files, os.environ.get("TMUX_PANE", ""))
        ahead = st.ahead_of(branch, files)
    for b, shared in ahead:
        print(f"{b} también modifica {', '.join(shared)} y empezó antes: entra primero")
    return 0


def release(args):
    info = repo_of(os.getcwd())
    if not info:
        sys.exit("bk release: no estás en un repo git")
    b = args[0] if args else info[2]
    with Store(info[0]) as st:
        st.data.pop(b, None)
    print(f"{b}: claims soltados")
    return 0


def hook():
    """PreToolUse: no editar los archivos del checkout de main. PostToolUse: reclamar el archivo y avisar
    si otra rama que empezó antes lo está modificando."""
    try:
        ev = json.load(sys.stdin)
    except ValueError:
        return 0
    if ev.get("tool_name") not in EDIT_TOOLS:
        return 0
    ti = ev.get("tool_input") or {}
    path = ti.get("file_path") or ti.get("notebook_path") or ""
    if not path:
        return 0
    path = os.path.abspath(os.path.join(ev.get("cwd") or os.getcwd(), path))
    info = repo_of(path)
    if not info:
        return 0
    main, wt, branch = info
    if os.environ.get("BK_LAND_REPO") and os.path.realpath(os.environ["BK_LAND_REPO"]) != main:
        return 0
    name = ev.get("hook_event_name")
    if name == "PreToolUse" and wt == main and branch == MAIN_BRANCH and os.environ.get("BK_MAIN_OK") != "1":
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse", "permissionDecision": "deny",
            "permissionDecisionReason":
                "main está protegido: nadie edita su checkout. Trabajá en tu rama y worktree "
                f"(git -C {main} worktree add -b <rama> ../barrilete-workspace-wt/<rama> main) "
                "y entrá con bk land."}}))
        return 0
    if name != "PostToolUse" or branch in ("", MAIN_BRANCH):
        return 0
    f = rel(main, wt, path)
    if not f:
        return 0
    with Store(main) as st:
        st.claim(branch, wt, [f], os.environ.get("TMUX_PANE", ""))
        ahead = [(b, s) for b, s in st.ahead_of(branch, [f]) if f in s]
    if ahead:
        who = ", ".join(b for b, _ in ahead)
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext":
                f"{f} también lo está modificando {who}, que empezó antes y entra a main primero. "
                "Seguí con tu cambio, pero no corras los checks todavía: van a quedar viejos. "
                "Cuando termines, commiteá y corré bk land --wait: espera a que entre, rebasa y corre los checks una vez."}}))
    return 0


def main(argv):
    cmd = argv[0] if argv else ""
    if cmd == "land":
        return land(argv[1:])
    if cmd == "claims":
        return claims(argv[1:])
    if cmd == "claim":
        return claim_cmd(argv[1:])
    if cmd == "release":
        return release(argv[1:])
    if cmd == "hook":
        return hook()
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
