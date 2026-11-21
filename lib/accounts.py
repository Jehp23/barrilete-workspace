#!/usr/bin/env python3
"""bk account: cuentas de Claude Code o Codex por sesión, sin perder las conversaciones.

Cada cuenta es una carpeta de config propia (CLAUDE_CONFIG_DIR o CODEX_HOME) en
${BK_ACCOUNTS_DIR:-${XDG_STATE_HOME:-~/.local/state}/bk/accounts}/<nombre>. Lo compartido (las
conversaciones, settings, skills, hooks…) es un symlink a la carpeta principal; lo propio de cada cuenta
son las credenciales (Claude Code las guarda en el llavero con un sufijo por carpeta) y .claude.json.
La cuenta "default" es la de siempre (~/.claude, ~/.codex) y no tiene carpeta.

  accounts.py list [--json]              las cuentas, con su proveedor y si tienen sesión iniciada
  accounts.py new <claude|codex> [nombre]  crear la carpeta (el login lo hace bk). Sin nombre: claude-2, claude-3…
  accounts.py provider <nombre>          claude | codex (default: vacío)
  accounts.py env <nombre>               VAR=valor para lanzar con esa cuenta (repara los symlinks)
  accounts.py email [nombre]             el mail de esa cuenta (sin nombre: la de siempre de Claude)
  accounts.py active <claude|codex>      la cuenta activa de esa IA (default si no se eligió otra)
  accounts.py set-active <nombre> [claude|codex]   elegirla (default necesita decir de qué IA)

La activa es la que usa lo que se lanza sin una cuenta propia (ni --account, ni la de la terminal, ni la de la
sesión de tmux): la elige un clic en el panel Cuentas de Herdr o bk account use fuera de tmux. Vive en
<carpeta de cuentas>/activas.json.
"""
import json
import os
import re
import subprocess
import sys

HOME = os.path.expanduser("~")
STATE = os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state")
ROOT = os.environ.get("BK_ACCOUNTS_DIR") or os.path.join(STATE, "bk", "accounts")
MAIN = {"claude": os.environ.get("BK_CLAUDE_MAIN") or os.path.join(HOME, ".claude"),
        "codex": os.environ.get("BK_CODEX_MAIN") or os.path.join(HOME, ".codex")}
VAR = {"claude": "CLAUDE_CONFIG_DIR", "codex": "CODEX_HOME"}
# Lo que comparten todas las cuentas de un proveedor. Las carpetas marcadas con / se crean en la
# principal si faltan (projects/: sin ella, una cuenta nueva escribiría sus conversaciones aparte).
SHARED = {
    "claude": ["projects/", "settings.json", "CLAUDE.md", "barrilete-lessons.md", "skills", "plugins",
               "hooks", "agents", "commands", "output-styles", "history.jsonl", "file-history", "todos",
               "plans", "shell-snapshots", "session-env", "keybindings.json"],
    "codex": ["sessions/", "config.toml", "AGENTS.md", "hooks.json", "rules", "prompts", "history.jsonl"],
}
# De ~/.claude.json, lo que no es de la cuenta: proyectos confiados, MCP del usuario, tema.
SEED_KEYS = ("projects", "mcpServers", "theme")
ACTIVE = os.path.join(ROOT, "activas.json")
NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")


def die(msg):
    print(f"bk account: {msg}", file=sys.stderr)
    sys.exit(1)


def path(name):
    return os.path.join(ROOT, name)


def provider(name):
    try:
        with open(os.path.join(path(name), "proveedor")) as f:
            return f.read().strip()
    except OSError:
        return ""


def email(name, prov=None):
    """El mail de la cuenta con ese nombre (default o vacío: la de siempre de prov, Claude si no se dice), leído de
    sus archivos sin preguntarle al CLI: Claude, de .claude.json (oauthAccount.emailAddress); Codex, del id_token de
    auth.json (solo el campo email). None si no tiene sesión iniciada o no existe. Barato: la barra lo pide cada 10 s."""
    if name in (None, "", "default"):
        prov = prov or "claude"
        d = None
    else:
        prov = provider(name)
        d = path(name)
    if prov == "codex":
        return codex_email(os.path.join(d or MAIN["codex"], "auth.json"))
    if prov != "claude":
        return None
    f = os.path.join(d, ".claude.json") if d else (os.environ.get("BK_CLAUDE_JSON") or os.path.join(HOME, ".claude.json"))
    try:
        with open(f, encoding="utf-8") as fh:
            acct = json.load(fh).get("oauthAccount") or {}
    except (OSError, ValueError, AttributeError):
        return None
    e = acct.get("emailAddress") if isinstance(acct, dict) else None
    return e.strip() if isinstance(e, str) and "@" in e else None


def codex_email(f):
    import base64
    try:
        with open(f, encoding="utf-8") as fh:
            tok = ((json.load(fh).get("tokens") or {}).get("id_token") or "").split(".")
        body = tok[1] + "=" * (-len(tok[1]) % 4)
        e = json.loads(base64.urlsafe_b64decode(body)).get("email")
    except (OSError, ValueError, AttributeError, IndexError, TypeError):
        return None
    return e.strip() if isinstance(e, str) and "@" in e else None


def free_name(prov):
    """El primer nombre libre para una cuenta nueva sin nombre: claude-2, claude-3… (la de siempre es la 1)."""
    n = 2
    while os.path.exists(path(f"{prov}-{n}")):
        n += 1
    return f"{prov}-{n}"


def names():
    try:
        return sorted(n for n in os.listdir(ROOT) if provider(n))
    except OSError:
        return []


def actives():
    try:
        with open(ACTIVE) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return {}
    return d if isinstance(d, dict) else {}


def active(prov):
    """La cuenta activa de esa IA: la elegida si todavía existe y es de esa IA; si no, default."""
    name = actives().get(prov)
    return name if isinstance(name, str) and name and provider(name) == prov else "default"


def set_active(name, prov=""):
    if name == "default":
        if prov not in VAR:
            die("set-active default <claude|codex>: ¿la de siempre de qué IA?")
    else:
        p = provider(name)
        if not p:
            die(f"no existe la cuenta {name} (bk account)")
        if prov and prov != p:
            die(f"la cuenta {name} es de {p}, no de {prov}")
        prov = p
    d = actives()
    if name == "default":
        d.pop(prov, None)
    else:
        d[prov] = name
    os.makedirs(ROOT, mode=0o700, exist_ok=True)
    tmp = ACTIVE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=2)
    os.replace(tmp, ACTIVE)


def link_shared(name):
    """Crea los symlinks que falten (si la principal ganó algo nuevo, la cuenta lo ve). Nunca pisa
    un archivo real de la cuenta: si existe y no es symlink, lo deja."""
    prov, d = provider(name), path(name)
    for item in SHARED[prov]:
        is_dir = item.endswith("/")
        item = item.rstrip("/")
        src, dst = os.path.join(MAIN[prov], item), os.path.join(d, item)
        if is_dir:
            os.makedirs(src, exist_ok=True)
        if not os.path.lexists(src) or os.path.lexists(dst):
            continue
        os.symlink(src, dst)


def seed_claude_json(d):
    main = os.environ.get("BK_CLAUDE_JSON") or os.path.join(HOME, ".claude.json")
    try:
        with open(main) as f:
            data = json.load(f)
    except (OSError, ValueError):
        data = {}
    seed = {k: data[k] for k in SEED_KEYS if k in data}
    fd = os.open(os.path.join(d, ".claude.json"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(seed, f, indent=2)


def new(prov, name=""):
    if prov not in VAR:
        die(f"proveedor desconocido: {prov} (claude | codex)")
    name = name or free_name(prov)
    if name == "default" or not NAME.match(name):
        die(f"nombre inválido: {name!r} (minúsculas, números y guiones; 'default' es la de siempre)")
    d = path(name)
    if os.path.exists(d):
        die(f"ya existe la cuenta {name} ({provider(name) or '?'}): {d}")
    os.makedirs(d, mode=0o700)
    with open(os.path.join(d, "proveedor"), "w") as f:
        f.write(prov + "\n")
    if prov == "claude":
        seed_claude_json(d)
    link_shared(name)
    print(d)


def env(name):
    if name in ("", "default"):
        return
    prov = provider(name)
    if not prov:
        die(f"no existe la cuenta {name} (bk account)")
    link_shared(name)
    print(f"{VAR[prov]}={path(name)}")


def status(prov, d):
    """(sesión iniciada, quién). Lo pregunta al CLI con la carpeta de la cuenta."""
    e = dict(os.environ)
    e.pop("CLAUDE_CONFIG_DIR", None)
    e.pop("CODEX_HOME", None)
    if d:
        e[VAR[prov]] = d
    try:
        if prov == "claude":
            r = subprocess.run(["claude", "auth", "status"], env=e, capture_output=True, text=True, timeout=15)
            j = json.loads(r.stdout or "{}")
            return bool(j.get("loggedIn")), j.get("email") or j.get("authMethod") or ""
        r = subprocess.run(["codex", "login", "status"], env=e, capture_output=True, text=True, timeout=15)
        out = (r.stdout + r.stderr).strip().splitlines()
        return r.returncode == 0, (out[0] if out else "")
    except FileNotFoundError:
        return False, f"{prov} no está instalado"
    except (subprocess.TimeoutExpired, ValueError):
        return False, "?"


def listing(as_json):
    rows = [{"name": "default", "provider": p, "dir": MAIN[p]} for p in ("claude", "codex")]
    rows += [{"name": n, "provider": provider(n), "dir": path(n)} for n in names()]
    # En paralelo: cada status le pregunta al CLI y el panel Cuentas espera la lista entera
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=8) as ex:
        got = list(ex.map(lambda r: status(r["provider"], None if r["name"] == "default" else r["dir"]), rows))
    act = {p: active(p) for p in VAR}
    for r, (logged, who) in zip(rows, got):
        r["logged_in"], r["who"], r["active"] = logged, who, act[r["provider"]] == r["name"]
        r["email"] = email(r["name"], r["provider"])
    if as_json:
        print(json.dumps(rows, ensure_ascii=False))
        return
    for r in rows:
        mark = "●" if r["logged_in"] else "○"
        print(f"{mark} {r['name']:<14} {r['provider']:<7} {r['who'] or 'sin sesión'}{'  ← activa' if r['active'] else ''}")


def main(argv):
    cmd = argv[0] if argv else "list"
    if cmd == "list":
        listing("--json" in argv)
    elif cmd == "new" and len(argv) in (2, 3):
        new(argv[1], argv[2] if len(argv) == 3 else "")
    elif cmd == "provider" and len(argv) == 2:
        print(provider(argv[1]))
    elif cmd == "email" and len(argv) <= 2:
        e = email(argv[1] if len(argv) == 2 else "")
        if not e:
            sys.exit(1)
        print(e)
    elif cmd == "active" and len(argv) == 2 and argv[1] in VAR:
        print(active(argv[1]))
    elif cmd == "set-active" and len(argv) in (2, 3):
        set_active(argv[1], argv[2] if len(argv) == 3 else "")
    elif cmd == "env" and len(argv) == 2:
        env(argv[1])
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
