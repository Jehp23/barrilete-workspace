#!/usr/bin/env python3
"""La épica del chat enfocado y su avance, para el bloque ÉPICA de la barra de agentes (herdr/mods/agentes).

  herdr_epica.py <carpeta> [rama] [texto]        (bk _epica …)

El issue del chat sale, en este orden, de la rama (claude/1152-algo, claude/feat/1152-algo), de la carpeta (un
worktree <repo>-wt/1152) o de un #1152 en el texto (el nombre o el título automático del chat). La épica es su
padre en GitHub, o el issue mismo si tiene sub-issues. Imprime un JSON:

  {"issue": 1152, "epic": {"repo": "o/r", "number": 1150, "title": "…", "done": 5, "total": 7}}

`epic` es null si el chat no tiene issue o el issue no tiene épica; `issue` es null sin issue. Lo de GitHub se
guarda unos minutos en ~/.cache/bk/epica.json (BK_CACHE_DIR): la barra lo pide seguido y no debe pegarle a GitHub
en cada dibujo. Sin red, lo último guardado aunque esté vencido; si no hay nada, epic null y "offline": true.
"""
import json, os, re, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import agents as AG

TTL = 300
CACHE = os.path.join(os.environ.get("BK_CACHE_DIR", os.path.expanduser("~/.cache/bk")), "epica.json")


def issue_of(cwd, branch, text):
    if branch and branch not in ("main", "master"):
        # Las ramas de /implement-issue: claude/<n>-… o claude/<tipo>/<n>-… (el mismo patrón que available.sh del kit)
        m = re.match(r"(?!release/)[a-z]+/(?:[a-z]{1,20}/)?(\d+)-", branch)
        if m:
            return int(m.group(1))
    if cwd:
        base, parent = os.path.basename(cwd.rstrip("/")), os.path.basename(os.path.dirname(cwd.rstrip("/")))
        if base.isdigit() and parent.endswith("-wt"):
            return int(base)
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
    s = it.get("sub_issues_summary") or {}
    return {"repo": repo, "number": it["number"], "title": it.get("title") or "",
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


def load():
    try:
        with open(CACHE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save(cache):
    now = time.time()
    cache = {k: v for k, v in cache.items() if now - v.get("at", 0) < 7 * 86400}
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    tmp = f"{CACHE}.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(cache, f, ensure_ascii=False)
    os.replace(tmp, CACHE)


def main(argv):
    cwd, branch, text = (argv + ["", "", ""])[:3]
    num = issue_of(cwd, branch, text)
    out = {"issue": num, "epic": None}
    repo = AG.repo_of(cwd) if num and cwd and os.path.isdir(cwd) else ""
    if num and repo:
        key, cache = f"{repo}#{num}", load()
        hit = cache.get(key)
        if hit and time.time() - hit.get("at", 0) < TTL:
            out["epic"] = hit.get("epic")
        else:
            try:
                out["epic"] = fetch(repo, num)
                cache[key] = {"at": time.time(), "epic": out["epic"]}
                save(cache)
            except LookupError:
                out["epic"] = hit.get("epic") if hit else None
                if not hit:
                    out["offline"] = True
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main(sys.argv[1:])
