#!/usr/bin/env python3
"""Los pasos del issue de un chat, para la ventana TODO de Herdr (alt+t, herdr/mods/hub/todo.js).

  herdr_todo.py <carpeta> [rama] [texto] [terminal]        (bk _todo …)

El issue del chat sale igual que en la sección ÉPICAS (lib/herdr_epica.py): el worktree <repo>-wt/N, lo que la
conversación de Claude de esa terminal trabajó, la rama o un #N en el texto. Los pasos son las casillas del cuerpo
del issue (`- [ ]` y `- [x]`, como el «Hecho cuando»), cada una con el título de su sección. Imprime un JSON:

  {"issue": 17, "repo": "o/r", "title": "…", "state": "open", "url": "https://github.com/o/r/issues/17",
   "items": [{"text": "…", "done": true, "section": "Hecho cuando"}, …], "done": 2, "total": 4}

Sin issue: {"issue": null}. Un issue sin casillas: items vacío y total 0. Lo de GitHub se guarda unos minutos en
~/.cache/bk/todo.json (BK_CACHE_DIR); sin red, lo último guardado aunque esté vencido, y si no hay nada, "offline": true.
Solo lee: tildar un paso es del agente (con gh), no del panel.
"""
import json, os, re, sys, time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import agents as AG
import herdr_epica as HE

TTL = 120
CACHE = os.path.join(os.path.dirname(HE.CACHE), "todo.json")
BOX = re.compile(r"^\s*[-*+]\s+\[([ xX])\]\s+(.*\S)\s*$")
HEAD = re.compile(r"^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$")


def chat_issue(cwd, branch, text, terminal):
    """(número, repo) del issue del chat, como lo resuelve bk _epica; (None, "") sin issue."""
    session = None
    if terminal and not HE.worktree_issue(cwd) and cwd and os.path.isdir(cwd):
        top = AG.sh("git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir").strip()
        path = HE.transcript((AG.states().get(terminal) or {}).get("_sid"))
        if top and path:
            seen = HE.load(HE.SESSIONS)
            before = json.dumps(seen, sort_keys=True)
            session = HE.session_issue(path, os.path.dirname(top.rstrip("/")), seen)
            if json.dumps(seen, sort_keys=True) != before:
                HE.save(seen, HE.SESSIONS, prune=False)
    num = HE.issue_of(cwd, branch, text, session)
    repo = HE.repo_of(cwd) if num and cwd and os.path.isdir(cwd) else ""
    return (num, repo) if num and repo else (None, "")


def checklist(body):
    """Las casillas del cuerpo, con la sección (el último título) de cada una. Las de un bloque de código no cuentan."""
    items, section, fence = [], "", False
    for line in (body or "").splitlines():
        if line.lstrip().startswith(("```", "~~~")):
            fence = not fence
            continue
        if fence:
            continue
        h = HEAD.match(line)
        if h:
            section = h.group(1)
            continue
        m = BOX.match(line)
        if m:
            items.append({"text": m.group(2).replace("**", ""), "done": m.group(1) != " ", "section": section})
    return items


def fetch(repo, num):
    it, err = HE.gh(f"repos/{repo}/issues/{num}")
    if err == "error":
        raise LookupError
    if not it:
        return None
    return {"title": it.get("title") or "", "state": it.get("state") or "open", "url": it.get("html_url") or "",
            "items": checklist(it.get("body"))}


def todo(cwd, branch="", text="", terminal=""):
    num, repo = chat_issue(cwd, branch, text, terminal)
    if not num:
        return {"issue": None}
    out = {"issue": num, "repo": repo}
    key = f"{repo}#{num}"
    cache = HE.load(CACHE)
    hit = cache.get(key)
    if not hit or time.time() - hit.get("at", 0) >= TTL:
        try:
            got = fetch(repo, num)
            hit = {"at": time.time(), "issue": got}
            cache[key] = hit
            HE.save(cache, CACHE)
        except LookupError:
            if not hit:
                out["offline"] = True
                return out
    got = hit.get("issue")
    if not got:
        return out   # GitHub no lo conoce (404)
    out.update(got)
    out["done"] = sum(1 for i in got["items"] if i["done"])
    out["total"] = len(got["items"])
    return out


def main(argv):
    a = [str(x or "") for x in (argv + ["", "", "", ""])[:4]]
    print(json.dumps(todo(*a), ensure_ascii=False))


if __name__ == "__main__":
    main(sys.argv[1:])
