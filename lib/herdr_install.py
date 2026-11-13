#!/usr/bin/env python3
"""Instala en Herdr lo de bk: el mod `bk` de los atajos, las teclas alt+…, los paneles (tareas del kit, lado derecho)
y el layout `bk` que los muestra (herdr/ del repo).

  herdr_install.py <herdr/ del repo> <carpeta de Herdr (~/.config/herdr-app)>

El mod se copia a mods/bk-<comando>, una carpeta por tecla. Las teclas se suman a keys.json sin pisar nada: una tecla que ya hace otra cosa
queda como está y se avisa. Antes del primer cambio guarda keys.json.antes-de-bk (una sola vez). Herdr deja de
actualizar un keys.json editado: sus atajos nuevos habrá que sumarlos a mano. Imprime qué hizo; correrlo de
nuevo no cambia nada.
"""
import filecmp, json, os, shutil, sys


NO_KEY = ("bk-aviso", "bk-seguir")   # mods sin tecla: los abre bk (un aviso de Herdr) o el clic en ese aviso


# Los paneles de bk (herdr/mods/<nombre> → mods/bk-<nombre>) y dónde va cada uno en el layout `bk`:
# (id del bloque, id del nodo que lo contiene, el bloque)
PANELS = [
    ("tareas", "sidebar-lists", {"type": "block", "size": {"weight": 1}, "min": 90}),
    ("lado", "work-body", {"type": "block", "size": {"px": 300}, "min": 220, "max": 520}),
]


def panels(src, home):
    copied = 0
    for name, _parent, _block in PANELS:
        a, b = os.path.join(src, "mods", name), os.path.join(home, "mods", "bk-" + name)
        os.makedirs(b, exist_ok=True)
        for fn in sorted(os.listdir(a)):
            if not (os.path.isfile(os.path.join(b, fn)) and filecmp.cmp(os.path.join(a, fn), os.path.join(b, fn), shallow=False)):
                shutil.copyfile(os.path.join(a, fn), os.path.join(b, fn)); copied += 1
    print(f"paneles bk: {'actualizados' if copied else 'al día'} ({', '.join('bk-' + p[0] for p in PANELS)})")


def find(node, id_):
    if isinstance(node, dict):
        if node.get("id") == id_:
            return node
        for child in node.get("children") or []:
            got = find(child, id_)
            if got:
                return got
    return None


def layout(home):
    """El layout `bk`: el `main` de Herdr más los paneles de bk. Si no existe, se arma desde main.json; si existe,
    solo se le suman los bloques que falten (lo que le hayas retocado queda). No cambia el layout que se muestra:
    eso es `herdr-app do layout.switch --name bk`."""
    path = os.path.join(home, "layouts", "bk.json")
    new = not os.path.exists(path)
    try:
        doc = json.load(open(os.path.join(home, "layouts", "main.json") if new else path))
    except FileNotFoundError:
        print("layout bk: no hay layouts/main.json (abrí Herdr una vez y repetí)"); return
    except ValueError as e:
        print(f"layout bk: {'main' if new else 'bk'}.json no es JSON válido, no lo toco ({e})"); return
    added, lost = [], []
    for name, parent, block in PANELS:
        if find(doc, name):
            continue
        into = find(doc, parent)
        if not into or not isinstance(into.get("children"), list):
            lost.append(f"{name} (no encuentro {parent})"); continue
        into["children"].append({"id": name, **block, "content": {"mod": "bk-" + name}})
        added.append(name)
    if new or added:
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(doc, f, indent=2, ensure_ascii=False); f.write("\n")
        os.replace(tmp, path)
    what = "creado desde main" if new else (f"sumé {', '.join(added)}" if added else "al día")
    print(f"layout bk: {what}" + (f"; sin lugar para {', '.join(lost)}" if lost else "")
          + (" (para verlo: herdr-app do layout.switch --name bk)" if new else ""))


def main():
    src, home = sys.argv[1], sys.argv[2]
    if not os.path.isdir(home):
        print(f"no existe {home}: abrí Herdr una vez y repetí"); return 1
    want = json.load(open(os.path.join(src, "keys.json")))
    # Una carpeta por comando (mods/bk-<comando>), todas con el mismo mod: una tecla abre un mod por su nombre
    # y no puede pasarle argumentos. mods/bk era la versión con una copia siempre abierta: se va.
    names = sorted({a.split(":", 1)[1] for b in want.values() for a in b.values() if a.startswith("mod.open:bk-")} | set(NO_KEY))
    mod, copied = os.path.join(src, "mods", "bk"), 0
    for name in names:
        dst = os.path.join(home, "mods", name)
        os.makedirs(dst, exist_ok=True)
        for fn in ("main.js", "mod.json"):
            a, b = os.path.join(mod, fn), os.path.join(dst, fn)
            if not (os.path.isfile(b) and filecmp.cmp(a, b, shallow=False)):
                shutil.copyfile(a, b); copied += 1
    shutil.rmtree(os.path.join(home, "mods", "bk"), ignore_errors=True)
    print(f"mods bk-*: {'actualizados' if copied else 'al día'} ({len(names)} en {os.path.join(home, 'mods')})")

    panels(src, home)
    layout(home)
    # El look versionado se instala aparte: no pisa el layout bk personalizado.
    look = os.path.join(home, "layouts", "bk-lavanda.json")
    os.makedirs(os.path.dirname(look), exist_ok=True)
    if not os.path.exists(look):
        shutil.copyfile(os.path.join(src, "layouts", "bk-lavanda.json"), look)
        print("layout bk-lavanda: instalado (herdr-app do layout.switch --name bk-lavanda)")

    path = os.path.join(home, "keys.json")
    try:
        keys = json.load(open(path))
    except FileNotFoundError:
        print("teclas: no hay keys.json (abrí Herdr una vez y repetí)"); return 1
    except ValueError as e:
        print(f"teclas: keys.json no es JSON válido, no lo toco ({e})"); return 1
    added, taken = [], []
    for section, binds in want.items():
        have = keys.setdefault(section, {})
        for key, action in binds.items():
            ours = isinstance(have.get(key), str) and (have[key].startswith("bk.") or have[key].startswith("mod.open:bk-"))
            if key not in have or (ours and have[key] != action):   # las de una versión anterior de bk se actualizan
                have[key] = action; added.append(key)
            elif have[key] != action:
                taken.append(f"{key} (ya es {json.dumps(have[key], ensure_ascii=False)})")
    stale = [(b, k) for b in keys.values() for k, a in b.items() if a == "bk.last"]   # alt+0 de la versión anterior
    for b, k in stale:
        del b[k]
    if added or stale:
        backup = path + ".antes-de-bk"
        if not os.path.exists(backup):
            shutil.copyfile(path, backup)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(keys, f, indent=2, ensure_ascii=False); f.write("\n")
        os.replace(tmp, path)
    print(f"teclas: {len(added)} nuevas o actualizadas" + (f", {len(taken)} ocupadas: " + ", ".join(taken) if taken else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
