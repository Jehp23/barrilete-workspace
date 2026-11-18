#!/usr/bin/env python3
"""bk bitacora: la «Bitácora de agentes» de cada repo, con el scripts/agents/bitacora.py de su kit (barrilete-kit#339).

Por cada repo corre `<repo>/scripts/agents/bitacora.py -C <repo>`, que lee sus retros y deja la página en
<repo>/.barrilete/bitacora.html (el diseño de barrilete o el del proyecto). Este envoltorio no arma nada: el formato
de las retros y el diseño son del kit.

Uso:  bk bitacora [repo...]                 (alt+k «Bitácora de agentes»: las regenera y las abre)
      python3 -I lib/bitacora.py [repo...]  solo las regenera

Sin argumentos, los repos de ~/.config/bk/retros.json ({"repos": ["~/barrilete-kit", ...]}; sin él, ~/barrilete-kit).
Imprime "ok: <página>" por cada página. Un repo con un kit sin bitácora o cuyo script falla se dice en una línea
por stderr y se sigue. Termina con 1 si ningún repo dio una página.
"""
import json
import os
import subprocess
import sys

RETRO_REPOS_CONF = os.path.expanduser("~/.config/bk/retros.json")


def repos(args):
    if args:
        return args
    try:
        with open(RETRO_REPOS_CONF, encoding="utf-8") as f:
            lista = json.load(f).get("repos", [])
    except (OSError, ValueError, AttributeError):
        lista = ["~/barrilete-kit"]
    return [r for r in lista if isinstance(r, str) and r]


def una(repo):
    """La página de un repo, o None (y una línea por stderr) si no la pudo armar."""
    repo = os.path.abspath(os.path.expanduser(repo))
    script = os.path.join(repo, "scripts", "agents", "bitacora.py")
    if not os.path.isfile(script):
        print(f"bk bitacora: {repo} no trae scripts/agents/bitacora.py (su kit es anterior a la bitácora: "
              "actualizalo)", file=sys.stderr)
        return None
    try:
        r = subprocess.run([sys.executable, "-I", script, "-C", repo], capture_output=True, text=True,
                           timeout=300)
    except (OSError, subprocess.SubprocessError) as err:
        print(f"bk bitacora: {repo}: {err}", file=sys.stderr)
        return None
    paginas = [linea[4:] for linea in r.stdout.splitlines() if linea.startswith("ok: ")]
    if r.returncode != 0 or not paginas:
        lineas = r.stderr.strip().splitlines() or r.stdout.strip().splitlines() or [f"salió con {r.returncode}"]
        print(f"bk bitacora: {repo}: {lineas[-1]}", file=sys.stderr)
        return None
    return paginas[-1]


def main(args):
    hechas = [p for p in (una(r) for r in repos(args)) if p]
    for p in hechas:
        print(f"ok: {p}")
    return 0 if hechas else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
