#!/usr/bin/env python3
"""bk ask: pasarle un trabajo puntual al modelo de una tarea (imágenes e investigar → Codex…).

  bk ask                                   las tareas, con su modelo y para qué sirven
  bk ask <tarea> "<pedido>" [--timeout S]  correrlo sin pantalla; imprime la respuesta y, si dejó archivos, dónde
  bk ask set <tarea> <provider>/<modelo> [descripción…]   crear o cambiar una tarea
  bk ask rm <tarea>                        borrar una tarea
  bk ask edit                              abrir el archivo de tareas en $EDITOR
  bk ask --json                            las tareas en JSON (el panel de alt+k, el orquestador)

Cada pedido corre en su carpeta, ~/.cache/bk/ask/<fecha>-<tarea>/, con la respuesta (respuesta.md), el registro
(log.txt) y lo que haya generado (imágenes…). El orquestador copia de ahí lo que necesite al worktree.

  claude   claude -p --model M                      solo texto (sin permisos para escribir)
  codex    codex --search exec -m M -s workspace-write -C <carpeta> --ephemeral   escribe solo en su carpeta
                                                    (imágenes) y busca en la web (investigar)
  gemini   gemini -m M -p                           con la búsqueda web de Gemini; sin aprobación, lo que pide
                                                    permiso (shell, escribir) no corre

Las de fábrica están en tareas.yml del repo; al editar se copian a ~/.config/bk/tareas.yml.
"""
import json, os, re, shutil, signal, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.realpath(__file__))
WS = os.path.dirname(HERE)
DEFAULTS = os.path.join(WS, "tareas.yml")
PROVIDERS = ["claude", "codex", "gemini"]
RESERVED = {"set", "rm", "edit", "list", "help", "models"}
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")
SPEC_RE = re.compile(r"^([a-z]+)/([A-Za-z0-9][A-Za-z0-9._:\[\]-]*)$")
LINE_RE = re.compile(r"^([a-z0-9][a-z0-9-]*):\s*(\S+)(?:\s+(.*))?$")
TIMEOUT = 600
QUOTA_RE = re.compile(r"\b429\b|RESOURCE_EXHAUSTED|quota|rate.?limit|usage limit", re.I)
OWN = {"respuesta.md", "log.txt", "pedido.txt"}


def conf_dir():
    return os.path.join(os.path.expanduser("~"), ".config", "bk")


def user_file():
    return os.path.join(conf_dir(), "tareas.yml")


def source():
    return user_file() if os.path.isfile(user_file()) else DEFAULTS


def die(msg, code=1):
    print(f"bk ask: {msg}", file=sys.stderr)
    sys.exit(code)


def parse(path=None):
    """{tarea: {spec, desc}} en el orden del archivo."""
    out = {}
    try:
        lines = open(path or source(), encoding="utf-8").read().splitlines()
    except OSError:
        return out
    for l in lines:
        if l.lstrip().startswith("#"):
            continue
        m = LINE_RE.match(l.rstrip())
        if m and m.group(1) not in out:
            out[m.group(1)] = {"spec": m.group(2), "desc": (m.group(3) or "").strip()}
    return out


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tareas.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def editable():
    if not os.path.isfile(user_file()):
        os.makedirs(conf_dir(), exist_ok=True)
        shutil.copyfile(DEFAULTS, user_file())
    return user_file()


def check_spec(spec):
    m = SPEC_RE.match(spec or "")
    if not m:
        die(f"«{spec}» no es <provider>/<modelo> (por ejemplo codex/gpt-6.1-sol o gemini/gemini-2.5-flash)")
    if m.group(1) not in PROVIDERS:
        die(f"provider desconocido: {m.group(1)} ({' | '.join(PROVIDERS)})")
    if not shutil.which(m.group(1)):
        print(f"ojo: la CLI de {m.group(1)} no está instalada; la tarea no va a poder correr", file=sys.stderr)


def set_task(name, spec, desc):
    desc = " ".join(desc.split())   # un renglón
    path = editable()
    lines = open(path, encoding="utf-8").read().splitlines()
    new = f"{name}: {spec}" + (f"   {desc}" if desc else "")
    for i, l in enumerate(lines):
        m = LINE_RE.match(l.rstrip())
        if m and not l.lstrip().startswith("#") and m.group(1) == name:
            if not desc and m.group(3):   # sin descripción nueva, queda la que tenía
                new = f"{name}: {spec}   {m.group(3).strip()}"
            lines[i] = new
            break
    else:
        while lines and not lines[-1].strip():
            lines.pop()
        lines.append(new)
    write(path, "\n".join(lines) + "\n")


def remove(name):
    path = editable()
    lines = open(path, encoding="utf-8").read().splitlines()
    keep = [l for l in lines if not ((m := LINE_RE.match(l.rstrip())) and not l.lstrip().startswith("#") and m.group(1) == name)]
    if len(keep) == len(lines):
        die(f"no hay una tarea «{name}»")
    write(path, "\n".join(keep) + "\n")


def data():
    ts = parse()
    return {"file": source(), "custom": source() == user_file(), "providers": PROVIDERS,
            "tasks": [{"name": n, "spec": t["spec"], "desc": t["desc"],
                       "installed": bool(shutil.which(t["spec"].split("/")[0]))} for n, t in ts.items()]}


def show():
    d = data()
    if not d["tasks"]:
        print("no hay tareas (bk ask set <tarea> <provider>/<modelo> <para qué sirve>)")
    w = max([len(t["name"]) for t in d["tasks"]] + [4])
    ws = max([len(t["spec"]) for t in d["tasks"]] + [4])
    for t in d["tasks"]:
        miss = "" if t["installed"] else "   (falta la CLI)"
        print(f"{t['name']:<{w}}  {t['spec']:<{ws}}  {t['desc']}{miss}")
    print(f"\nbk ask <tarea> \"<pedido>\" · archivo: {d['file'].replace(os.path.expanduser('~'), '~', 1)}")


def command(provider, model, prompt, folder):
    if provider == "claude":
        return ["claude", "-p", "--model", model, prompt]
    if provider == "codex":
        return ["codex", "--search", "exec", "-m", model, "--skip-git-repo-check", "--ephemeral", "-s", "workspace-write",
                "-C", folder, "-o", os.path.join(folder, "respuesta.md"), prompt]
    if provider == "gemini":
        return ["gemini", "-m", model, "--skip-trust", "-o", "text", "-p", prompt]
    die(f"provider desconocido: {provider}")


def run(name, request, timeout):
    ts = parse()
    if name not in ts:
        die(f"no hay una tarea «{name}» ({', '.join(ts) or 'ninguna'}): bk ask para verlas")
    spec = ts[name]["spec"]
    m = SPEC_RE.match(spec)
    if not m or m.group(1) not in PROVIDERS:
        die(f"la tarea {name} tiene «{spec}», que no es <provider>/<modelo> válido")
    provider, model = m.group(1), m.group(2)
    if not shutil.which(provider):
        die(f"la tarea {name} usa {provider}, y su CLI no está instalada")
    base = os.path.join(os.path.expanduser("~"), ".cache", "bk", "ask")
    os.makedirs(base, exist_ok=True)
    folder = tempfile.mkdtemp(dir=base, prefix=time.strftime("%Y%m%d-%H%M%S-") + name + "-")
    prompt = (f"{request}\n\n(Trabajás en la carpeta {folder}. Si generás archivos, guardalos ahí y nombralos "
              f"en la respuesta. No toques nada fuera de esa carpeta.)")
    open(os.path.join(folder, "pedido.txt"), "w", encoding="utf-8").write(request + "\n")
    log_path = os.path.join(folder, "log.txt")
    out_path = os.path.join(folder, "respuesta.md")
    with open(log_path, "w", encoding="utf-8") as log, open(os.devnull) as null:
        out = None if provider == "codex" else open(out_path, "w", encoding="utf-8")
        try:
            p = subprocess.Popen(command(provider, model, prompt, folder), cwd=folder, stdin=null,
                                 stdout=(out or log), stderr=log, start_new_session=True)
        except OSError as e:
            die(f"no pude correr {provider}: {e}")
        try:
            rc = p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(p.pid, signal.SIGTERM)
                p.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                os.killpg(p.pid, signal.SIGKILL)
            rc = None
        finally:
            if out:
                out.close()
    logtxt = open(log_path, encoding="utf-8", errors="replace").read()
    answer = open(out_path, encoding="utf-8", errors="replace").read().strip() if os.path.isfile(out_path) else ""
    files = sorted(os.path.join(folder, f) for f in os.listdir(folder) if f not in OWN)
    quota = bool(QUOTA_RE.search(logtxt))
    if rc != 0 or not (answer or files):
        why = (f"pasaron {timeout} s sin terminar" if rc is None else f"{provider} salió con {rc}" if rc else "no devolvió nada")
        if quota:
            why += f"; {provider} dice que no hay cuota o que se pasó del límite (429): revisá tu plan o probá otro modelo con bk ask set"
        print(answer, end="\n" if answer else "")
        die(f"{name} ({spec}): {why}. Registro: {log_path}", 2)
    print(answer)
    if files:
        print("\narchivos:")
        for f in files:
            print(f"  {f}")
    print(f"\n(carpeta: {folder})")


def main(argv):
    if not argv:
        return show()
    a = argv[0]
    if a == "--json":
        json.dump(data(), sys.stdout, ensure_ascii=False)
        print()
    elif a in ("-h", "--help", "help"):
        print(__doc__.strip().split("\n\n")[1])
    elif a == "set":
        if len(argv) < 3:
            die("bk ask set <tarea> <provider>/<modelo> [descripción…]")
        name, spec, desc = argv[1], argv[2], " ".join(argv[3:])
        if not NAME_RE.match(name) or name in RESERVED:
            die(f"«{name}» no sirve de nombre (minúsculas, números y guiones; no {', '.join(sorted(RESERVED))})")
        check_spec(spec)
        set_task(name, spec, desc)
        t = parse()[name]
        print(f"{name}: {t['spec']}" + (f"   {t['desc']}" if t["desc"] else ""))
    elif a == "edit":
        ed = os.environ.get("VISUAL") or os.environ.get("EDITOR") or "vi"
        sys.exit(subprocess.call(["/bin/sh", "-c", f'{ed} "$1"', "sh", editable()]))
    elif a == "rm":
        if len(argv) != 2:
            die("bk ask rm <tarea>")
        remove(argv[1])
        print(f"borré la tarea {argv[1]}")
    else:
        rest = argv[1:]
        timeout = TIMEOUT
        if "--timeout" in rest:
            i = rest.index("--timeout")
            try:
                timeout = int(rest[i + 1])
            except (IndexError, ValueError):
                die("--timeout <segundos>")
            del rest[i:i + 2]
        request = " ".join(rest).strip()
        if not request:
            die(f'bk ask {a} "<pedido>"')
        run(a, request, timeout)


if __name__ == "__main__":
    main(sys.argv[1:])
