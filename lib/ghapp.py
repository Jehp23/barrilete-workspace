#!/usr/bin/env python3
"""Identidad de bot para los agentes: tokens de instalación de la GitHub App.

Config: ~/.config/bk/gh-app.json  {"app_id": 123456, "key": "~/.config/bk/gh-app.pem"}
Cache:  ~/.cache/bk/ghapp/  (token por instalación, se renueva con menos de 10 min de vida)

  ghapp.py token [owner/repo]   token para el repo (por defecto, el remoto origin del directorio actual)
  ghapp.py credential get       helper de credenciales de git (git push como el bot)
  ghapp.py whoami               "<slug>[bot] <id>" para firmar los commits
  ghapp.py check                dice si está configurada y a qué repos llega

Sin config o sin acceso al repo sale con 1 y no imprime token: bk lanza al agente como vos.
El JWT se firma con openssl (RS256), sin dependencias de Python.
"""
import base64
import calendar
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

CONF = os.path.expanduser("~/.config/bk/gh-app.json")
CACHE = os.path.expanduser("~/.cache/bk/ghapp")
API = "https://api.github.com"


def conf():
    try:
        with open(CONF) as f:
            c = json.load(f)
        c["key"] = os.path.expanduser(c.get("key", "~/.config/bk/gh-app.pem"))
        if c.get("app_id") and os.path.isfile(c["key"]):
            return c
    except (OSError, ValueError):
        pass
    return None


def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def jwt(c):
    now = int(time.time())
    head = b64(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    body = b64(json.dumps({"iat": now - 60, "exp": now + 540, "iss": str(c["app_id"])}).encode())
    msg = f"{head}.{body}".encode()
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", c["key"]], input=msg,
                         capture_output=True, check=True).stdout
    return f"{head}.{body}.{b64(sig)}"


def api(method, path, auth):
    req = urllib.request.Request(API + path, method=method, headers={
        "Authorization": f"Bearer {auth}", "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "bk-ghapp"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def repo_here():
    try:
        url = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True,
                             text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$", url)
    return m.group(1) if m else None


def cached(name):
    try:
        with open(os.path.join(CACHE, name)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def store(name, data):
    os.makedirs(CACHE, mode=0o700, exist_ok=True)
    p = os.path.join(CACHE, name)
    fd = os.open(p + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f)
    os.replace(p + ".tmp", p)


def installation(c, repo):
    """id de instalación para el repo (cacheado: no cambia)."""
    ids = cached("installations.json") or {}
    if repo in ids:
        return ids[repo]
    try:
        inst = api("GET", f"/repos/{repo}/installation", jwt(c))["id"]
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise
    ids[repo] = inst
    store("installations.json", ids)
    return inst


def token(repo):
    c = conf()
    if not c or not repo:
        return None
    inst = installation(c, repo)
    if not inst:
        return None
    t = cached(f"token-{inst}.json")
    if t and t["exp"] - time.time() > 600:
        return t["token"]
    r = api("POST", f"/app/installations/{inst}/access_tokens", jwt(c))
    exp = calendar.timegm(time.strptime(r["expires_at"], "%Y-%m-%dT%H:%M:%SZ"))
    store(f"token-{inst}.json", {"token": r["token"], "exp": exp})
    return r["token"]


def whoami():
    c = conf()
    if not c:
        return None
    w = cached("whoami.json")
    if w and w.get("app_id") == c["app_id"]:
        return w
    slug = api("GET", "/app", jwt(c))["slug"]
    req = urllib.request.Request(f"{API}/users/{slug}%5Bbot%5D", headers={"User-Agent": "bk-ghapp"})
    with urllib.request.urlopen(req, timeout=15) as r:
        uid = json.load(r)["id"]
    w = {"app_id": c["app_id"], "login": f"{slug}[bot]", "id": uid,
         "email": f"{uid}+{slug}[bot]@users.noreply.github.com"}
    store("whoami.json", w)
    return w


def main():
    a = sys.argv[1:]
    try:
        if a[:1] == ["token"]:
            t = token(a[1] if len(a) > 1 else repo_here())
            if not t:
                sys.exit(1)
            print(t)
        elif a[:2] == ["credential", "get"]:
            req = dict(l.split("=", 1) for l in sys.stdin.read().splitlines() if "=" in l)
            if req.get("host") != "github.com":
                sys.exit(0)
            path = re.sub(r"\.git$", "", req.get("path", "")) or repo_here()
            t = token(path)
            if t:
                print(f"username=x-access-token\npassword={t}")
        elif a[:1] == ["credential"]:
            pass  # store/erase: nada que guardar
        elif a[:1] == ["whoami"]:
            w = whoami()
            if not w:
                sys.exit(1)
            print(w["login"], w["id"], w["email"])
        elif a[:1] == ["check"]:
            c = conf()
            if not c:
                print(f"sin configurar: falta {CONF} con app_id o la clave .pem"); sys.exit(1)
            w = whoami()
            insts = api("GET", "/app/installations", jwt(c))
            print(f"app {c['app_id']} · {w['login']} · {len(insts)} instalación(es)")
            for i in insts:
                t = api("POST", f"/app/installations/{i['id']}/access_tokens", jwt(c))["token"]
                repos = api("GET", "/installation/repositories", t)["repositories"]
                print(f"  {i['account']['login']}: {', '.join(r['name'] for r in repos)}")
        else:
            print(__doc__.strip()); sys.exit(2)
    except (urllib.error.URLError, subprocess.CalledProcessError, KeyError, ValueError) as e:
        print(f"ghapp: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
