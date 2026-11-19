#!/usr/bin/env python3
"""La épica de un chat, su avance y sus sub-issues, para la sección ÉPICAS de la barra y su popup (herdr/mods/agentes).

  herdr_epica.py <carpeta> [rama] [texto] [terminal]        (bk _epica …)
  herdr_epica.py --json '[[carpeta, rama, texto, terminal], …]'   (varios chats: una lista de respuestas, en orden)

El issue del chat sale, en este orden:
  1. de la carpeta, si el chat está en un worktree <repo>-wt/1152 (o <repo>-wt/1152-algo);
  2. de la conversación de Claude de esa terminal: el último worktree <repo>-wt/N o `prepare.sh N` en los comandos
     que corrió (un chat abierto en el checkout principal implementa en un worktree sin mover su carpeta, y la
     rama del checkout puede ser de otro chat);
  3. de la rama (claude/1152-algo, claude/feat/1152-algo);
  4. de un #1152 en el texto (el nombre o el título automático del chat). La épica es su
padre en GitHub, o el issue mismo si tiene sub-issues. Imprime un JSON:

  {"issue": 1152, "repo": "o/r", "epic": {"repo": "o/r", "number": 1150, "title": "…", "done": 5, "total": 7,
    "subs": [{"repo": "o/r", "number": 1151, "title": "…", "state": "open", "blocked_by": [{"repo": "o/x", "number": 9}]}, …],
    "dirs": {"o/r": "/Users/yo/r", "o/x": "/Users/yo/x"}, "nolaunch": {"o/x": "x tiene el kit 0.9.0: …"}}}

`epic` es null si el chat no tiene issue o el issue no tiene épica; `issue` es null sin issue; `repo` es el del issue
(el de la carpeta del chat). `subs` son los sub-issues de la épica (pueden ser de otro repo), y de los abiertos, los
issues abiertos que los bloquean (`blocked_by`). `dirs` dice dónde lanzar un sub-issue de cada repo (`bk run N` corre
en esa carpeta): el checkout principal de los chats de esa épica, si no ~/<nombre del repo> si existe. `nolaunch`
dice, de esos repos, en cuáles no se puede lanzar y por qué (lib/kit_check.py: sin barrilete-kit 2 o más nuevo). Lo de GitHub se
guarda unos minutos en ~/.cache/bk/epica.json (BK_CACHE_DIR): la barra lo pide seguido y no debe pegarle a GitHub
en cada dibujo. Sin red, lo último guardado aunque esté vencido; si no hay nada, epic null y "offline": true. Los
sub-issues de cada épica, igual, en ~/.cache/bk/epica-subs.json (sin red y sin nada guardado, `subs` no está).
"""
import json, os, re, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import agents as AG
import kit_check

TTL = 300
CACHE = os.path.join(os.environ.get("BK_CACHE_DIR", os.path.expanduser("~/.cache/bk")), "epica.json")


SCAN = 1 << 20   # de la conversación, se lee el último mega
SESSIONS = os.path.join(os.path.dirname(CACHE), "epica-sesiones.json")
SUBS = os.path.join(os.path.dirname(CACHE), "epica-subs.json")


# <n> o <n>-<descripción> (818-avisos, como la rama del kit); no 15x ni 545-0087
WT_NAME = re.compile(r"(\d+)(?:-[a-z][\w-]*)?$")


def worktree_issue(cwd):
    if cwd:
        base, parent = os.path.basename(cwd.rstrip("/")), os.path.basename(os.path.dirname(cwd.rstrip("/")))
        m = WT_NAME.match(base)
        if m and parent.endswith("-wt"):
            return int(m.group(1))
    return None


def transcript(sid):
    import glob
    hits = glob.glob(os.path.join(AG.PROJECTS, "*", f"{sid}.jsonl")) if sid else []
    return hits[0] if hits else ""


def session_issue(path, repo_dir, seen):
    """El último issue en el que trabajó la conversación: los comandos de Claude (tool_use), no lo que le respondieron
    (un `git worktree list` nombra todos los worktrees). `seen` guarda {archivo: [tamaño, issue]}: sin cambios, no relee."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return None
    if seen.get(path, [None])[0] == size:
        return seen[path][1]
    base = re.escape(os.path.basename(repo_dir.rstrip("/")))
    wt = re.compile(rf"{base}-wt/(\d+)(?:-[a-z][\w-]*)?(?![\w-])")
    # prepare.sh corrido de verdad: al principio de un comando (o después de && ; |), no nombrado dentro de un texto
    prep = re.compile(r"(?:^|&&|;|\|)\s*(?:bash\s+)?(?:\S*/)?prepare\.sh\s+#?(\d+)\b", re.M)
    num = None
    try:
        with open(path, "rb") as f:
            f.seek(max(0, size - SCAN))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return None
    for line in lines:
        if '"tool_use"' not in line:
            continue
        try:
            msg = json.loads(line).get("message") or {}
        except ValueError:
            continue
        for c in msg.get("content") or []:
            if isinstance(c, dict) and c.get("type") == "tool_use":
                inp = c.get("input") or {}
                cmd = inp.get("command") if isinstance(inp, dict) else None
                # En un mismo comando, el worktree manda (prepare.sh N && cd <repo>-wt/N); si no hay, el prepare.sh
                found = [int(m.group(1)) for m in wt.finditer(json.dumps(inp, ensure_ascii=False))] \
                    or [int(m.group(1)) for m in prep.finditer(cmd if isinstance(cmd, str) else "")]
                if found:
                    num = found[-1]
    seen[path] = [size, num]
    return num


def issue_of(cwd, branch, text, session=None):
    wt = worktree_issue(cwd)
    if wt:
        return wt
    if session:
        return session
    if branch and branch not in ("main", "master"):
        # Las ramas de /implement-issue: claude/<n>-… o claude/<tipo>/<n>-… (el mismo patrón que available.sh del kit)
        m = re.match(r"(?!release/)[a-z]+/(?:[a-z]{1,20}/)?(\d+)-", branch)
        if m:
            return int(m.group(1))
    m = re.search(r"#(\d+)\b", text or "")
    return int(m.group(1)) if m else None


def gh(path):
    """(json, None) si respondió; (None, "none") si GitHub dice 404; (None, "error") si no se pudo preguntar."""
    env = {k: v for k, v in os.environ.items() if k not in ("GH_CONFIG_DIR", "GH_TOKEN")}
    try:
        r = subprocess.run(["gh", "api", path], capture_output=True, text=True, timeout=8, env=env)
    except (OSError, subprocess.SubprocessError):
        return None, "error"
    if r.returncode != 0:
        return None, "none" if "HTTP 404" in r.stderr else "error"
    try:
        return json.loads(r.stdout), None
    except ValueError:
        return None, "error"


def summary(repo, it):
    """El padre puede ser de otro repo (una épica que cruza repos): el suyo sale de repository_url."""
    s = it.get("sub_issues_summary") or {}
    return {"repo": repo_from_url(it.get("repository_url")) or repo, "number": it["number"], "title": it.get("title") or "",
            "done": s.get("completed") or 0, "total": s.get("total") or 0}


def fetch(repo, num):
    """La épica de repo#num, None si no tiene; lanza LookupError si GitHub no respondió."""
    parent, err = gh(f"repos/{repo}/issues/{num}/parent")
    if parent:
        return summary(repo, parent)
    if err == "error":
        raise LookupError
    it, err = gh(f"repos/{repo}/issues/{num}")
    if err == "error":
        raise LookupError
    if it and (it.get("sub_issues_summary") or {}).get("total"):
        return summary(repo, it)
    return None


def repo_from_url(url):
    m = re.search(r"/repos/([^/]+/[^/]+)$", url or "")
    return m.group(1) if m else ""


def fetch_subs(repo, num):
    """Los sub-issues de repo#num y, de los abiertos, sus bloqueos abiertos; lanza LookupError si GitHub no respondió."""
    items, err = gh(f"repos/{repo}/issues/{num}/sub_issues?per_page=100")
    if err == "error" or (items is not None and not isinstance(items, list)):
        raise LookupError
    subs = [{"repo": repo_from_url(it.get("repository_url")) or repo, "number": it["number"], "title": it.get("title") or "",
             "state": it.get("state") or "open", "blocked_by": []} for it in items or [] if isinstance(it, dict) and "number" in it]

    def blockers(s):
        got, err = gh(f"repos/{s['repo']}/issues/{s['number']}/dependencies/blocked_by")
        if err == "error":
            raise LookupError
        return [{"repo": repo_from_url(b.get("repository_url")) or s["repo"], "number": b["number"]}
                for b in got or [] if isinstance(b, dict) and "number" in b and b.get("state") == "open"]
    opened = [s for s in subs if s["state"] == "open"]
    with ThreadPoolExecutor(max_workers=6) as pool:
        for s, b in zip(opened, pool.map(blockers, opened)):
            s["blocked_by"] = b
    return subs


def load(path=CACHE):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save(cache, path=CACHE, prune=True):
    now = time.time()
    if prune:
        cache = {k: v for k, v in cache.items() if now - v.get("at", 0) < 7 * 86400}
    else:   # las conversaciones: las que ya no existen se van
        cache = {k: v for k, v in cache.items() if os.path.exists(k)}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(cache, f, ensure_ascii=False)
    os.replace(tmp, path)


def resolve(queries):
    """Las respuestas de varios chats; a GitHub, una vez por issue y en paralelo."""
    cache, now, keys, main_dirs = load(), time.time(), [], []
    states = AG.states() if any(q[3] for q in queries) else {}
    seen = load(SESSIONS)
    seen_before = json.dumps(seen, sort_keys=True)
    for cwd, branch, text, terminal in queries:
        session = None
        if terminal and not worktree_issue(cwd) and cwd and os.path.isdir(cwd):
            top = AG.sh("git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir").strip()
            path = transcript((states.get(terminal) or {}).get("_sid"))
            if top and path:
                session = session_issue(path, os.path.dirname(top.rstrip("/")), seen)
        num = issue_of(cwd, branch, text, session)
        repo = repo_of(cwd) if num and cwd and os.path.isdir(cwd) else ""
        keys.append((num, repo))
        main_dirs.append(checkout(cwd) if repo else "")
    if json.dumps(seen, sort_keys=True) != seen_before:
        save(seen, SESSIONS, prune=False)
    stale = sorted({(r, n) for n, r in keys if n and r
                    and not (cache.get(f"{r}#{n}") and now - cache[f"{r}#{n}"].get("at", 0) < TTL)})

    def ask(rn):
        try:
            return rn, fetch(*rn)
        except LookupError:
            return rn, LookupError
    with ThreadPoolExecutor(max_workers=6) as pool:
        fresh = dict(pool.map(ask, stale))
    failed = set()
    for rn, epic in fresh.items():
        if epic is LookupError:
            failed.add(rn)
        else:
            cache[f"{rn[0]}#{rn[1]}"] = {"at": time.time(), "epic": epic}
    if len(failed) < len(fresh):
        save(cache)
    out = []
    for num, repo in keys:
        o = {"issue": num, "repo": repo or None, "epic": None}
        hit = cache.get(f"{repo}#{num}") if num and repo else None
        if hit:
            o["epic"] = hit.get("epic")   # sin red, lo último guardado aunque esté vencido
        elif (repo, num) in failed:
            o["offline"] = True
        out.append(o)
    with_subs(out, main_dirs)
    return out


def repo_of(cwd):
    """El repo de GitHub de esa carpeta: el de origin; sin origin, el único remoto de GitHub (el workspace tiene
    solo `respaldo`)."""
    repo = AG.repo_of(cwd)
    if repo:
        return repo
    found = {m.group(1) for m in re.finditer(r"github\.com[:/]([^/\s]+/[^/\s]+?)(?:\.git)?\s", AG.sh("git", "-C", cwd, "remote", "-v"))}
    return found.pop() if len(found) == 1 else ""


def checkout(cwd):
    """El checkout principal del repo de esa carpeta (el de un worktree es el del repo): ahí corre `bk run`."""
    top = AG.sh("git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir").strip()
    return os.path.dirname(top.rstrip("/")) if top else ""


def with_subs(out, main_dirs):
    """Suma a cada épica sus sub-issues (caché propia, TTL) y dónde lanzar los de cada repo."""
    cache, now = load(SUBS), time.time()
    epics = {(o["epic"]["repo"], o["epic"]["number"]) for o in out if o["epic"]}
    stale = sorted(rn for rn in epics if not (cache.get(f"{rn[0]}#{rn[1]}") and now - cache[f"{rn[0]}#{rn[1]}"].get("at", 0) < TTL))

    def ask(rn):
        try:
            return rn, fetch_subs(*rn)
        except LookupError:
            return rn, LookupError
    with ThreadPoolExecutor(max_workers=4) as pool:
        fresh = dict(pool.map(ask, stale))
    got = {rn: subs for rn, subs in fresh.items() if subs is not LookupError}
    for rn, subs in got.items():
        cache[f"{rn[0]}#{rn[1]}"] = {"at": time.time(), "subs": subs}
    if got:
        save(cache, SUBS)
    dirs = {}
    for o, d in zip(out, main_dirs):
        if o["epic"] and o["repo"] and d:
            dirs.setdefault((o["epic"]["repo"], o["epic"]["number"]), {}).setdefault(o["repo"], d)
    for o in out:
        e = o["epic"]
        if not e:
            continue
        rn = (e["repo"], e["number"])
        e = o["epic"] = dict(e)   # la de la caché de épicas queda sin esto
        hit = cache.get(f"{rn[0]}#{rn[1]}")
        if hit:   # sin red, lo último guardado aunque esté vencido
            e["subs"] = hit.get("subs") or []
        d = dict(dirs.get(rn, {}))
        for r in {e["repo"], *(s["repo"] for s in e.get("subs", []))} - set(d):
            guess = os.path.join(os.path.expanduser("~"), r.split("/")[-1])
            if os.path.isdir(guess):
                d[r] = guess
        e["dirs"] = d
        # Los repos donde no se puede lanzar, con el motivo (un kit viejo): el popup lo dice en vez de «Lanzar»
        e["nolaunch"] = {r: why for r, dir_ in sorted(d.items()) if (why := kit_check.problem(dir_))}


def main(argv):
    if argv[:1] == ["--json"]:
        try:
            qs = [(list(q) + ["", "", "", ""])[:4] for q in json.loads(argv[1])]
        except (IndexError, ValueError, TypeError):
            sys.exit("bk _epica --json '[[carpeta, rama, texto, terminal], …]'")
        print(json.dumps(resolve([[str(x or "") for x in q] for q in qs]), ensure_ascii=False))
        return
    print(json.dumps(resolve([(argv + ["", "", "", ""])[:4]])[0], ensure_ascii=False))


if __name__ == "__main__":
    main(sys.argv[1:])
