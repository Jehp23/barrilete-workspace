#!/usr/bin/env python3
"""bk models: los modelos que se pueden elegir, por proveedor (claude, codex, gemini).

  bk models [<provider>] [--json] [--fresh]
  bk models --providers [--json]     qué proveedores tienen sesión iniciada y con qué cuentas (el panel de alt+k
                                     ofrece solo esos)

  codex   de la CLI (`codex debug models`, los visibles), guardados un día en ~/.cache/bk/models-codex.json;
          sin la CLI o si falla, los de models.yml
  claude, gemini   sus CLIs no listan modelos: salen de models.yml del repo más ~/.config/bk/models.yml

Sesión: claude y codex por sus cuentas (lib/accounts.py: `claude auth status`, `codex login status`, también las
cuentas extra de bk account); gemini por GEMINI_API_KEY / GOOGLE_API_KEY, ~/.gemini/oauth_creds.json o la clave
que la CLI guarda en el llavero (gemini-cli-api-key, gemini-cli-oauth: solo se mira que exista, no se lee).
"""
import json, os, re, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.realpath(__file__))
WS = os.path.dirname(HERE)
PROVIDERS = ["claude", "codex", "gemini"]
LINE_RE = re.compile(r"^([a-z]+)/(\S+)(?:\s+(.*))?$")
DAY = 86400


def cache_file():
    return os.path.join(os.path.expanduser("~"), ".cache", "bk", "models-codex.json")


def from_file(path):
    out = []
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return out
    for l in lines:
        l = l.strip()
        if not l or l.startswith("#"):
            continue
        m = LINE_RE.match(l)
        if m and m.group(1) in PROVIDERS:
            out.append({"provider": m.group(1), "model": m.group(2), "desc": (m.group(3) or "").strip()})
    return out


def codex_models(fresh=False):
    """Los visibles de `codex debug models`, o None si no se pudo (sin CLI, error, salida rota)."""
    path = cache_file()
    if not fresh:
        try:
            if time.time() - os.path.getmtime(path) < DAY:
                return json.load(open(path, encoding="utf-8"))
        except (OSError, ValueError):
            pass
    if not shutil.which("codex"):
        return None
    try:
        r = subprocess.run(["codex", "debug", "models"], capture_output=True, text=True, timeout=20, stdin=subprocess.DEVNULL)
        ms = json.loads(r.stdout)["models"]
        got = [{"provider": "codex", "model": m["slug"], "desc": m.get("description") or m.get("display_name") or ""}
               for m in ms if m.get("visibility", "list") == "list" and m.get("slug")]
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
        return None
    if not got:
        return None
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + f".{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(got, f, ensure_ascii=False)
    os.replace(tmp, path)
    return got


def catalog(fresh=False):
    """[{provider, model, desc}]: los de los archivos y, para codex, los de la CLI primero. Sin repetidos."""
    files = from_file(os.path.join(WS, "models.yml")) + from_file(os.path.join(os.path.expanduser("~"), ".config", "bk", "models.yml"))
    cx = codex_models(fresh) or []
    out, seen = [], set()
    for m in cx + files:
        k = (m["provider"], m["model"])
        if k not in seen:
            seen.add(k)
            out.append(m)
    return sorted(out, key=lambda m: PROVIDERS.index(m["provider"]))   # estable: dentro de cada provider, el orden de la fuente


def gemini_session():
    """(sesión, cómo): la CLI de gemini tiene con qué autenticarse."""
    if os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY"):
        return True, "clave de API (variable de entorno)"
    if os.path.isfile(os.path.join(os.path.expanduser("~"), ".gemini", "oauth_creds.json")):
        return True, "cuenta de Google"
    if shutil.which("security"):
        for svc, how in (("gemini-cli-api-key", "clave de API (llavero)"), ("gemini-cli-oauth", "cuenta de Google (llavero)")):
            try:
                r = subprocess.run(["security", "find-generic-password", "-s", svc], capture_output=True, timeout=5,
                                   stdin=subprocess.DEVNULL)
                if r.returncode == 0:
                    return True, how
            except (OSError, subprocess.SubprocessError):
                pass
    return False, ""


def providers():
    """[{provider, installed, logged, accounts}]: accounts son los nombres de las cuentas con sesión."""
    accs = []
    try:
        r = subprocess.run([sys.executable, os.path.join(HERE, "accounts.py"), "list", "--json"], capture_output=True,
                           text=True, timeout=60, stdin=subprocess.DEVNULL)
        accs = json.loads(r.stdout or "[]")
    except (OSError, subprocess.SubprocessError, ValueError):
        pass
    out = []
    for p in PROVIDERS:
        installed = bool(shutil.which(p))
        if p == "gemini":
            ok, how = gemini_session() if installed else (False, "")
            names = [how] if ok else []
        else:
            names = [a.get("name") + (f" ({a['who']})" if a.get("who") and "@" in a.get("who", "") else "")
                     for a in accs if a.get("provider") == p and a.get("logged_in")]
        out.append({"provider": p, "installed": installed, "logged": installed and bool(names), "accounts": names})
    return out


def main(argv):
    if "--providers" in argv:
        ps = providers()
        if "--json" in argv:
            json.dump(ps, sys.stdout, ensure_ascii=False)
            print()
            return
        for p in ps:
            state = ", ".join(p["accounts"]) if p["logged"] else ("sin sesión" if p["installed"] else "la CLI no está instalada")
            print(f"{'●' if p['logged'] else '○'} {p['provider']:<7} {state}")
        return
    fresh = "--fresh" in argv
    args = [a for a in argv if not a.startswith("--")]
    ms = catalog(fresh)
    if args:
        if args[0] not in PROVIDERS:
            print(f"bk models: provider desconocido: {args[0]} ({' | '.join(PROVIDERS)})", file=sys.stderr)
            sys.exit(1)
        ms = [m for m in ms if m["provider"] == args[0]]
    if "--json" in argv:
        json.dump(ms, sys.stdout, ensure_ascii=False)
        print()
        return
    w = max([len(m["provider"]) + len(m["model"]) + 1 for m in ms] + [10])
    cur = None
    for m in ms:
        if m["provider"] != cur:
            if cur:
                print()
            cur = m["provider"]
        print(f"{m['provider'] + '/' + m['model']:<{w}}  {m['desc']}")


if __name__ == "__main__":
    main(sys.argv[1:])
