#!/usr/bin/env python3
"""Las tareas del kit para los paneles de bk en Herdr (herdr/mods/tareas): lo mismo que `bk tasks --json`, con el
título del issue o del PR de cada una.

  herdr_tasks.py [--all]        (bk _tasks [--all])

`title` sale de la caché de títulos de bk (~/.cache/bk/titles.json, la de bk ls). Los que faltan se le piden a
GitHub, hasta FETCH por corrida para no trabar el panel: las activas van primero y el historial se completa en las
corridas siguientes. Sin título (sin red, repo que ya no existe): "". No cambia ninguna tarea.
"""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import agents as AG
import tasks as TK

FETCH = 8


def number(t):
    """El issue de la tarea (ref "#267"); si no tiene, su PR."""
    ref = str(t.get("ref") or "").lstrip("#")
    return ref if ref.isdigit() else str(t.get("pr") or "")


def main():
    ts = TK.tasks(all_="--all" in sys.argv)
    titles, slugs, left = AG.load_titles(), {}, FETCH
    for t in ts:
        repo, num = t.get("repo") or "", number(t)
        t["title"] = ""
        if not num or not repo:
            continue
        if repo not in slugs:
            slugs[repo] = AG.repo_of(repo)
        key = f"{slugs[repo]}#{num}"
        if not slugs[repo]:
            continue
        if key in titles:
            t["title"] = titles[key]
        elif left > 0:
            left -= 1
            t["title"] = AG.title_for(repo, num, titles, fetch=True)
    json.dump(ts, sys.stdout, ensure_ascii=False)
    print()


if __name__ == "__main__":
    main()
