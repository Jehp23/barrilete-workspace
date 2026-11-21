#!/usr/bin/env python3
"""bk profile: perfiles de modelos (un provider/modelo por rol) que se cambian de una vez, para todos los proyectos.

  bk profile                          los perfiles, con el activo marcado
  bk profile <nombre>                 usar ese perfil desde ahora (los agentes que ya corren siguen como estaban)
  bk profile off                      sin perfil: cada rol vuelve a roles.yml
  bk profile set <perfil> <rol> <provider>/<modelo>    cambiar un rol de un perfil (lo crea si no existe)
  bk profile new <nombre> [<de>]      un perfil nuevo, copia de <de> (por defecto, el activo o normal)
  bk profile rm <nombre>              borrar un perfil (no el activo)
  bk profile edit                     abrir el archivo de perfiles en $EDITOR
  bk profile --json                   todo lo anterior en JSON (los paneles de Herdr)

Los de fábrica están en profiles.yml del repo. Al primer cambio se copian a ~/.config/bk/profiles.yml, que
desde ahí manda; el activo se guarda en ~/.config/bk/profile. bin/bk lee el perfil activo con awk
(profile_spec) para no arrancar Python en cada rol: si cambiás el formato, cambiá los dos.
"""
import json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
WS = os.path.dirname(HERE)
DEFAULTS = os.path.join(WS, "profiles.yml")
ROLES = ["planner", "orchestrator", "implementer", "implementer-light", "reviewer"]
PROVIDERS = ["claude", "codex"]
SUGGEST = ["claude/opus", "claude/sonnet", "claude/haiku"]
SHORT = {"planner": "plan", "orchestrator": "orq", "implementer": "impl", "implementer-light": "light", "reviewer": "review"}
RESERVED = {"off", "set", "new", "rm", "edit", "list", "help"}
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")
SPEC_RE = re.compile(r"^([a-z]+)/([A-Za-z0-9][A-Za-z0-9._:\[\]-]*)$")
HEAD_RE = re.compile(r"^([^\s#][^:]*):\s*(#.*)?$")
ROLE_RE = re.compile(r"^(\s+)([^\s:#]+):\s*([^\s#]+)")


def conf_dir():
    return os.path.join(os.path.expanduser("~"), ".config", "bk")


def user_file():
    return os.path.join(conf_dir(), "profiles.yml")


def active_file():
    return os.path.join(conf_dir(), "profile")


def source():
    """El archivo que manda: tu copia si existe, si no el de fábrica."""
    return user_file() if os.path.isfile(user_file()) else DEFAULTS


def parse(path):
    """{perfil: {rol: spec}} en el orden del archivo. Las mismas reglas que el awk de bin/bk (profile_spec)."""
    out, cur = {}, None
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return out
    for l in lines:
        m = HEAD_RE.match(l)
        if m:
            cur = m.group(1).strip()
            out.setdefault(cur, {})
            continue
        if l[:1] not in ("", " ", "\t", "#"):
            cur = None   # una línea sin sangría que no es un perfil corta el bloque
            continue
        m = ROLE_RE.match(l)
        if cur is not None and m:
            out[cur].setdefault(m.group(2), m.group(3))
    return out


def active():
    try:
        return open(active_file(), encoding="utf-8").read().strip() or None
    except OSError:
        return None


def die(msg):
    print(f"bk profile: {msg}", file=sys.stderr)
    sys.exit(1)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".profiles.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def editable():
    """Tu copia, creada desde la de fábrica la primera vez."""
    if not os.path.isfile(user_file()):
        os.makedirs(conf_dir(), exist_ok=True)
        shutil.copyfile(DEFAULTS, user_file())
    return user_file()


def check_name(name):
    if not NAME_RE.match(name or "") or name in RESERVED:
        die(f"«{name}» no sirve de nombre (minúsculas, números y guiones; no {', '.join(sorted(RESERVED))})")


def check_spec(spec):
    m = SPEC_RE.match(spec or "")
    if not m:
        die(f"«{spec}» no es <provider>/<modelo> (por ejemplo claude/sonnet o codex/gpt-5)")
    if m.group(1) not in PROVIDERS:
        die(f"provider desconocido: {m.group(1)} ({' | '.join(PROVIDERS)})")
    if m.group(1) == "codex" and not shutil.which("codex"):
        print("ojo: Codex CLI no está instalado; los agentes de ese rol no van a poder arrancar", file=sys.stderr)


def set_role(profile, role, spec):
    """Cambia (o agrega) <rol>: <spec> en el bloque del perfil, sin tocar comentarios ni el resto."""
    path = editable()
    lines = open(path, encoding="utf-8").read().splitlines()
    start = next((i for i, l in enumerate(lines) if (m := HEAD_RE.match(l)) and m.group(1).strip() == profile), None)
    if start is None:
        while lines and not lines[-1].strip():
            lines.pop()
        lines += ["", f"{profile}:", f"  {role}: {spec}"]
    else:
        end = start + 1
        while end < len(lines) and (lines[end][:1] in ("", " ", "\t", "#")) and not HEAD_RE.match(lines[end]):
            end += 1
        last = start   # la última línea con algo del bloque, para agregar el rol debajo
        for i in range(start + 1, end):
            m = ROLE_RE.match(lines[i])
            if m and m.group(2) == role:
                lines[i] = lines[i][:m.start(3)] + spec + lines[i][m.end(3):]
                break
            if lines[i].strip():
                last = i
        else:
            lines.insert(last + 1, f"  {role}: {spec}")
    write(path, "\n".join(lines) + "\n")


def remove(profile):
    path = editable()
    lines = open(path, encoding="utf-8").read().splitlines()
    start = next((i for i, l in enumerate(lines) if (m := HEAD_RE.match(l)) and m.group(1).strip() == profile), None)
    if start is None:
        die(f"no hay un perfil «{profile}»")
    end = start + 1
    while end < len(lines) and (lines[end][:1] in ("", " ", "\t", "#")) and not HEAD_RE.match(lines[end]):
        end += 1
    while end > start + 1 and not lines[end - 1].strip():
        end -= 1   # las líneas en blanco del final quedan como separación
    del lines[start:end]
    while start < len(lines) and start > 0 and not lines[start].strip() and not lines[start - 1].strip():
        del lines[start]
    write(path, "\n".join(lines) + "\n")


def summary(roles):
    """«plan opus · impl sonnet · review codex/gpt-5»: el provider solo si no es claude."""
    def short(spec):
        p, _, m = spec.partition("/")
        return m if p == "claude" else spec
    return " · ".join(f"{SHORT.get(r, r)} {short(roles[r])}" for r in ROLES if r in roles)


def models(roles):
    """«opus · sonnet · haiku»: los modelos que usa, sin repetir, en el orden de los roles (para la paleta)."""
    out = []
    for r in ROLES:
        if r in roles:
            p, _, m = roles[r].partition("/")
            v = m if p == "claude" else roles[r]
            if v not in out:
                out.append(v)
    return " · ".join(out)


def data():
    profs = parse(source())
    act = active()
    seen = set(SUGGEST)
    for roles in profs.values():
        seen.update(roles.values())
    suggest = SUGGEST + sorted(s for s in seen if s not in SUGGEST)
    return {"active": act if act in profs else None, "missing": act if act and act not in profs else None,
            "file": source(), "custom": source() == user_file(), "roles": ROLES, "providers": PROVIDERS,
            "suggest": suggest,
            "profiles": [{"name": n, "roles": r, "summary": summary(r), "models": models(r)} for n, r in profs.items()]}


def show():
    d = data()
    if d["missing"]:
        print(f"ojo: el perfil activo «{d['missing']}» ya no está en {d['file']}: cada rol sale de roles.yml\n")
    w = max([len(p["name"]) for p in d["profiles"]] + [4])
    for p in d["profiles"]:
        mark = "●" if p["name"] == d["active"] else " "
        print(f"{mark} {p['name']:<{w}}  {p['summary']}")
    if not d["active"]:
        print(f"\nsin perfil activo: cada rol sale de roles.yml (bk profile <nombre> para elegir uno)")
    print(f"\narchivo: {d['file'].replace(os.path.expanduser('~'), '~', 1)}")


def main(argv):
    if not argv:
        return show()
    a = argv[0]
    if a == "--json":
        json.dump(data(), sys.stdout, ensure_ascii=False)
        print()
    elif a in ("-h", "--help", "help"):
        print(__doc__.strip().split("\n\n")[1])
    elif a == "off":
        try:
            os.remove(active_file())
        except FileNotFoundError:
            pass
        print("sin perfil: cada rol sale de roles.yml")
    elif a == "set":
        if len(argv) != 4:
            die("bk profile set <perfil> <rol> <provider>/<modelo>")
        _, prof, role, spec = argv
        check_name(prof)
        if role not in ROLES:
            die(f"rol desconocido: {role} ({', '.join(ROLES)})")
        check_spec(spec)
        set_role(prof, role, spec)
        print(f"{prof}: {role} → {spec}" + ("" if prof == active() else f"  (el activo es {active() or 'ninguno'})"))
    elif a == "new":
        if len(argv) not in (2, 3):
            die("bk profile new <nombre> [<copia de>]")
        name = argv[1]
        check_name(name)
        profs = parse(source())
        if name in profs:
            die(f"ya hay un perfil «{name}»")
        base = argv[2] if len(argv) == 3 else (active() if active() in profs else "normal")
        if base not in profs:
            die(f"no hay un perfil «{base}» para copiar")
        roles = profs[base] or {"implementer": "claude/sonnet"}
        for r, s in roles.items():
            set_role(name, r, s)
        print(f"{name}: copia de {base} ({summary(roles)})")
    elif a == "rm":
        if len(argv) != 2:
            die("bk profile rm <nombre>")
        if argv[1] == active():
            die(f"«{argv[1]}» es el activo: elegí otro antes de borrarlo")
        remove(argv[1])
        print(f"borré el perfil {argv[1]}")
    elif a == "edit":
        path = editable()
        ed = os.environ.get("VISUAL") or os.environ.get("EDITOR") or "vi"
        # $EDITOR puede traer argumentos («code -w»): lo arma el shell; la ruta va aparte, como $1
        sys.exit(subprocess.call(["/bin/sh", "-c", f'{ed} "$1"', "sh", path]))
    elif len(argv) == 1:
        profs = parse(source())
        if a not in profs:
            die(f"no hay un perfil «{a}» ({', '.join(profs) or 'ninguno'})")
        os.makedirs(conf_dir(), exist_ok=True)
        write(active_file(), a + "\n")
        print(f"perfil {a}: {summary(profs[a])}")
    else:
        die("bk profile [<nombre> | off | set | new | rm | edit | --json]")


if __name__ == "__main__":
    main(sys.argv[1:])
