#!/usr/bin/env python3
"""¿Se pueden lanzar agentes de bk en este proyecto? Si no, por qué, en palabras.

  kit_check.py <raíz del repo>    imprime el motivo y sale con 1; sin nada que decir, sale con 0

`bk run` (y todo lo que lanza agentes) necesita barrilete-kit 2 o más nuevo: sus scripts en scripts/agents/
(guardrails.py, prepare.sh). Lo usan bin/bk (project_root, cuando falta guardrails.py) y lib/herdr_epica.py
(`nolaunch`: la épica no ofrece «Lanzar» en un repo que no puede, y dice por qué). Un kit 0.x tiene sus scripts en
scripts/agentes/ y bk no sabe lanzar con él (2026-11-19: «Lanzar» de una épica de abra fallaba con «no es un
proyecto Barrilete»).
"""
import json, os, sys

NEED = 2   # la versión mayor del kit desde la que bk sabe lanzar


def problem(root):
    """El motivo por el que no se puede lanzar en `root`, o None si se puede."""
    root = os.path.abspath(os.path.expanduser(root or "."))
    name = os.path.basename(root.rstrip("/")) or root
    if os.path.isfile(os.path.join(root, "scripts", "agents", "guardrails.py")):
        return None
    try:
        kit = json.load(open(os.path.join(root, ".agent-kit.json"), encoding="utf-8"))
    except OSError:
        kit = None          # no hay .agent-kit.json
    except ValueError:
        kit = {}            # hay uno, roto: es un proyecto con kit, sin versión que leer
    version = str(kit.get("version") or "") if isinstance(kit, dict) else ""
    if kit is None and not os.path.isdir(os.path.join(root, "scripts", "agentes")):
        return f"{name} no es un proyecto Barrilete: no tiene barrilete-kit (.agent-kit.json)"
    try:
        major = int(version.split(".")[0])
    except ValueError:
        major = None
    if (major is not None and major < NEED) or os.path.isdir(os.path.join(root, "scripts", "agentes")):
        old = f"el kit {version}" if version else "un kit viejo (scripts/agentes/)"
        return f"{name} tiene {old}: para lanzar agentes hace falta barrilete-kit {NEED} o más nuevo. Actualizá el kit de {name}"
    return f"a {name} le falta scripts/agents/guardrails.py de barrilete-kit{' ' + version if version else ''}: actualizá o reinstalá el kit"


if __name__ == "__main__":
    why = problem(sys.argv[1] if len(sys.argv) > 1 else ".")
    if why:
        print(why)
    sys.exit(1 if why else 0)
