#!/usr/bin/env python3
"""Los datos del panel derecho de bk en Herdr (herdr/mods/lado), en un JSON: lo que mostraba el riel de tmux
(lib/rail.py: Status y Changes), sin dibujar nada.

  herdr_side.py <carpeta> [--usage]     (bk _side <carpeta> [--usage])

  project, path   el proyecto de esa carpeta: su repo principal aunque la carpeta sea un worktree
  branch, dirty   la rama de la carpeta y cuántos archivos tiene sin commitear
  profile         [{role, model, mode}] de `bk roles` en el proyecto
  changes         [{name, branch, path, files: [{code, path, add, del}], more}] por cada worktree del proyecto con
                  algo sin commitear (hasta MAX_FILES archivos; `more` dice cuántos quedaron afuera)
  context         {tokens, level} de la sesión de Claude más reciente de esa carpeta (level: "", "warn" desde
                  200k, "high" desde 400k), o null si no tiene ninguna
  usage           solo con --usage (lee los transcripts, tarda más): tokens y costo de hoy, acá y en total

Fuera de un repo de git: project y branch vacíos, sin changes. Nunca escribe nada.
"""
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.realpath(__file__))
MAX_FILES = 40


def sh(*a, cwd=None, timeout=6):
    try:
        return subprocess.run(a, capture_output=True, text=True, timeout=timeout, cwd=cwd).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def project_top(cwd):
    """El repo principal: el mismo aunque cwd sea un worktree (como project_top de bin/bk)."""
    common = sh("git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir").strip()
    if common.endswith("/.git"):
        return common[: -len("/.git")]
    return sh("git", "-C", cwd, "rev-parse", "--show-toplevel").strip()


def worktrees(top):
    out = [l[len("worktree "):] for l in sh("git", "-C", top, "worktree", "list", "--porcelain").splitlines()
           if l.startswith("worktree ")]
    return out or [top]


def changes_of(root):
    st = [l for l in sh("git", "-C", root, "status", "--porcelain").splitlines() if l.strip()]
    if not st:
        return None
    num = {}
    for l in sh("git", "-C", root, "diff", "--numstat", "HEAD").splitlines():
        p = l.split("\t")
        if len(p) == 3:
            num[p[2]] = (p[0], p[1])
    files = []
    for l in st[:MAX_FILES]:
        code, path = l[:2].strip() or "M", l[3:]
        a, d = num.get(path, ("", ""))
        files.append({"code": "A" if code == "??" else code, "path": path,
                      "add": a if a != "-" else "", "del": d if d != "-" else ""})
    return {"name": os.path.basename(root), "path": root, "files": files, "more": max(0, len(st) - MAX_FILES),
            "branch": sh("git", "-C", root, "branch", "--show-current").strip()}


def profile(top):
    rows = []
    for l in sh(os.path.join(os.path.dirname(HERE), "bin", "bk"), "roles", cwd=top or None).splitlines():
        p = l.split()
        if len(p) >= 2 and "/" in p[1]:
            rows.append({"role": p[0], "model": p[1].split("/")[-1], "mode": p[2] if len(p) > 2 else ""})
    return rows


def usage(name):
    try:
        u = json.loads(sh(sys.executable, os.path.join(HERE, "usage.py"), "--json", timeout=20))
    except ValueError:
        return None
    mine = [v for k, v in u.get("by_project", {}).items() if name and (k == name or k.startswith(name + "#"))]
    return {"tokens": u.get("tokens", 0), "cost": u.get("cost_usd", 0),
            "here_tokens": sum(v["tokens"] for v in mine), "here_cost": sum(v["cost"] for v in mine)}


def context(cwd):
    sys.path.insert(0, HERE)
    import usage as U
    return U.context_of_cwd(cwd)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    cwd = os.path.abspath(os.path.expanduser(args[0] if args else "."))
    home = os.path.expanduser("~")
    top = project_top(cwd) if os.path.isdir(cwd) else ""
    out = {"project": os.path.basename(top) if top else "", "path": (top or cwd).replace(home, "~", 1),
           "branch": "", "dirty": 0, "profile": profile(top), "changes": [],
           "context": context(cwd)}
    if top:
        out["branch"] = sh("git", "-C", cwd, "branch", "--show-current").strip()
        out["dirty"] = len([l for l in sh("git", "-C", cwd, "status", "--porcelain").splitlines() if l.strip()])
        out["changes"] = [c for c in map(changes_of, worktrees(top)) if c]
    if "--usage" in sys.argv:
        out["usage"] = usage(out["project"])
    json.dump(out, sys.stdout, ensure_ascii=False)
    print()


if __name__ == "__main__":
    main()
