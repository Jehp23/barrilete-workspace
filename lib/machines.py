#!/usr/bin/env python3
"""bk machines sync: la misma versión de bk en cada máquina conectada a Herdr (hc machine ls).

  machines.py sync [--dry-run]

Para cada máquina conectada: le manda con un git bundle los commits de bk que no tiene (por hc exec -i, así que anda
sin pushear y sin red a GitHub), deja su worktree propio <repo>-wt/bk-sync desacoplado en el commit de esta máquina,
apunta su ~/.local/bin/bk ahí y corre bk backend herdr allá. <repo> es el repo del bk que esa máquina ya tiene
instalado. El checkout de la persona allá no se toca nunca; si alguien editó a mano bk-sync, esa máquina frena.
Con --dry-run dice qué haría (solo mira).

Sale con 1 si no puede empezar (bk con cambios sin commitear acá, sin hc), con 3 si alguna máquina no quedó al día y
con 0 si quedaron todas. BK_HC: el hc a usar; BK_SYNC_REPO: el repo de bk de esta máquina (las pruebas).
"""
import json, os, shutil, subprocess, sys, tempfile

HC = os.environ.get("BK_HC") or shutil.which("hc") or os.path.expanduser("~/.local/bin/hc")
REPO = os.environ.get("BK_SYNC_REPO") or os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
WT_NAME = "bk-sync"
PROBE_TIMEOUT, APPLY_TIMEOUT = 30, 300

# Lo que corre en la otra máquina (python3 -c REMOTE probe|apply <sha> [bundle]): imprime una línea de JSON.
# probe solo mira; apply trae el bundle de stdin (si lo hay), mueve bk-sync, apunta bk y corre backend herdr.
REMOTE = r'''
import json, os, subprocess, sys, tempfile
def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True)
def out(**kw):
    print(json.dumps(kw)); sys.exit(0)
op, sha = sys.argv[1], sys.argv[2]
link = os.path.expanduser("~/.local/bin/bk")
if not os.path.exists(link):
    out(error="no tiene bk en ~/.local/bin/bk: instalalo una vez a mano")
checkout = os.path.dirname(os.path.dirname(os.path.realpath(link)))
r = git("-C", checkout, "rev-parse", "--path-format=absolute", "--git-common-dir")
if r.returncode:
    out(error=f"su bk ({checkout}) no está en un repo de git")
repo = os.path.dirname(r.stdout.strip())
wt = f"{repo}-wt/WT_NAME"
exists = os.path.exists(os.path.join(wt, ".git"))
def state():
    head = git("-C", wt, "rev-parse", "HEAD").stdout.strip() if exists else ""
    dirty = bool(exists and git("-C", wt, "status", "--porcelain", "--untracked-files=no").stdout.strip())
    linked = os.path.realpath(link) == os.path.realpath(os.path.join(wt, "bin", "bk"))
    has = git("-C", repo, "cat-file", "-e", sha + "^{commit}").returncode == 0
    return dict(wt=wt, head=head, dirty=dirty, linked=linked, has=has, exists=exists)
if op == "probe":
    refs = git("-C", repo, "for-each-ref", "--format=%(objectname)", "refs/heads", "refs/remotes", "refs/tags").stdout.split()
    out(refs=sorted(set(refs)), **state())
st = state()
if st["dirty"]:
    out(error=f"{wt} tiene cambios sin commitear: no lo toco (commitealos o descartalos allá)", dirty=True)
if len(sys.argv) > 3:
    with tempfile.NamedTemporaryFile(suffix=".bundle", delete=False) as f:
        f.write(sys.stdin.buffer.read())
    r = git("-C", repo, "fetch", "-q", f.name)
    os.unlink(f.name)
    if r.returncode:
        out(error="no pude traer el bundle: " + (r.stderr.strip() or r.stdout.strip()))
if exists:
    r = git("-C", wt, "checkout", "-q", "--detach", sha)
else:
    git("-C", repo, "worktree", "prune")
    os.makedirs(os.path.dirname(wt), exist_ok=True)
    r = git("-C", repo, "worktree", "add", "-q", "--detach", wt, sha)
if r.returncode:
    out(error=f"no pude dejar {wt} en {sha[:7]}: " + r.stderr.strip())
tmp = link + ".bk-sync"
if os.path.lexists(tmp):
    os.unlink(tmp)
os.symlink(os.path.join(wt, "bin", "bk"), tmp)
os.replace(tmp, link)
r = subprocess.run([os.path.join(wt, "bin", "bk"), "backend", "herdr"], capture_output=True, text=True)
if r.returncode:
    out(error="bk backend herdr falló: " + ((r.stderr or r.stdout).strip().splitlines() or ["?"])[-1])
out(ok=True, wt=wt)
'''.replace("WT_NAME", WT_NAME)


def git(*args, **kw):
    return subprocess.run(["git", "-C", REPO, *args], capture_output=True, **kw)


def die(msg):
    print(f"bk machines: {msg}", file=sys.stderr)
    sys.exit(1)


def remote(machine, op, sha, timeout, bundle=None):
    """Corre REMOTE en la máquina; devuelve su JSON, o {"error": …} si no respondió o no se entiende."""
    cmd = [HC, "exec", "--on", machine, "--timeout", str(timeout)]
    if bundle is not None:
        cmd.append("-i")
    cmd += ["--", "python3", "-c", REMOTE, op, sha] + (["bundle"] if bundle is not None else [])
    try:
        r = subprocess.run(cmd, input=bundle if bundle is not None else b"", capture_output=True, timeout=timeout + 15)
    except (OSError, subprocess.TimeoutExpired) as e:
        return {"error": f"no responde ({e.__class__.__name__})"}
    lines = r.stdout.decode(errors="replace").strip().splitlines()
    try:
        return json.loads(lines[-1])
    except (IndexError, ValueError):
        why = (r.stderr.decode(errors="replace").strip().splitlines() or lines or [f"salió con {r.returncode}"])[-1]
        return {"error": f"no responde bien: {why}"}


def known(refs):
    """De los commits que tiene la otra máquina, los que también están acá (el --not del bundle)."""
    if not refs:
        return []
    r = git("cat-file", "--batch-check", input="\n".join(refs).encode())
    return [l.split()[0] for l in r.stdout.decode().splitlines() if l.split()[1:2] == ["commit"]]


def bundle_for(negs):
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "bk.bundle")
        r = git("bundle", "create", path, "HEAD", *[f"^{n}" for n in negs])
        if r.returncode:
            return None, r.stderr.decode(errors="replace").strip()
        with open(path, "rb") as f:
            return f.read(), None


def sync(dry):
    if not os.path.exists(HC) and not shutil.which(HC):
        die(f"no encuentro hc ({HC}): bk machines sync necesita Herdr")
    r = git("rev-parse", "HEAD")
    if r.returncode:
        die(f"{REPO} no es un repo de git")
    sha = r.stdout.decode().strip()
    if git("status", "--porcelain", "--untracked-files=no").stdout.strip():
        die(f"bk tiene cambios sin commitear en {REPO}: commitealos primero, si no la otra máquina no queda igual")
    try:
        ms = json.loads(subprocess.run([HC, "machine", "ls", "--json"], capture_output=True, timeout=30).stdout or b"{}")
    except (OSError, ValueError, subprocess.TimeoutExpired) as e:
        die(f"hc machine ls no anduvo ({e.__class__.__name__})")
    machines = ms.get("machines") or []
    if not machines:
        print("No hay otras máquinas en Herdr (hc machine ls).")
        return 0
    failed = False
    for m in machines:
        name = m.get("name") or m.get("id") or "?"
        if m.get("state") != "connected":
            print(f"{name}: desconectada, la salto")
            continue
        p = remote(name, "probe", sha, PROBE_TIMEOUT)
        if "error" in p:
            print(f"{name}: {p['error']}"); failed = True; continue
        if p.get("dirty"):
            print(f"{name}: {p['wt']} tiene cambios sin commitear: no lo toco (commitealos o descartalos allá)")
            failed = True; continue
        if p.get("head") == sha and p.get("linked"):
            print(f"{name}: ya está al día en {sha[:7]}")
            continue
        negs = [] if p.get("has") else known(p.get("refs") or [])
        if dry:
            send = "" if p.get("has") else "mandaría {} commit(s), ".format(
                git("rev-list", "--count", "HEAD", *[f"^{n}" for n in negs]).stdout.decode().strip() or "?")
            verb = "movería" if p.get("exists") else "crearía"
            print(f"{name}: {send}{verb} {p['wt']} en {sha[:7]}, apuntaría ~/.local/bin/bk ahí y correría bk backend herdr")
            continue
        data = None
        if not p.get("has"):
            data, err = bundle_for(negs)
            if err:
                print(f"{name}: no pude armar el bundle: {err}"); failed = True; continue
        a = remote(name, "apply", sha, APPLY_TIMEOUT, bundle=data)
        if "error" in a:
            print(f"{name}: {a['error']}"); failed = True; continue
        print(f"{name}: listo en {sha[:7]} ({a.get('wt')})")
    return 3 if failed else 0


def main(argv):
    if not argv or argv[0] != "sync" or any(a != "--dry-run" for a in argv[1:]):
        die("uso: bk machines sync [--dry-run]")
    return sync("--dry-run" in argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
