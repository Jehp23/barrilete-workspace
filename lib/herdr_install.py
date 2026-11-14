#!/usr/bin/env python3
"""Instala en Herdr lo de bk: el mod `bk` de los atajos, las teclas alt+…, los paneles (tareas del kit, lado derecho)
y el layout `bk-lavanda` que los muestra (herdr/ del repo).

  herdr_install.py <herdr/ del repo> <carpeta de Herdr (~/.config/herdr-app)>

El mod se copia a mods/bk-<comando>, una carpeta por tecla. Las teclas se suman a keys.json sin pisar nada: una tecla que ya hace otra cosa
queda como está y se avisa. Antes del primer cambio guarda keys.json.antes-de-bk (una sola vez). Herdr deja de
actualizar un keys.json editado: sus atajos nuevos habrá que sumarlos a mano. Imprime qué hizo; correrlo de
nuevo no cambia nada.
"""
import filecmp, hashlib, json, os, shutil, sys


NO_KEY = ("bk-aviso", "bk-seguir")   # mods sin tecla: los abre bk (un aviso de Herdr) o el clic en ese aviso


# Los paneles de bk: herdr/mods/<nombre> → mods/bk-<nombre>. El layout bk-lavanda dice dónde va cada uno.
PANELS = ["tareas", "lado", "agentes"]
LAYOUT = "bk-lavanda"


def panels(src, home):
    copied = 0
    for name in PANELS:
        a, b = os.path.join(src, "mods", name), os.path.join(home, "mods", "bk-" + name)
        os.makedirs(b, exist_ok=True)
        for fn in sorted(os.listdir(a)):
            if not (os.path.isfile(os.path.join(b, fn)) and filecmp.cmp(os.path.join(a, fn), os.path.join(b, fn), shallow=False)):
                shutil.copyfile(os.path.join(a, fn), os.path.join(b, fn)); copied += 1
    print(f"paneles bk: {'actualizados' if copied else 'al día'} ({', '.join('bk-' + n for n in PANELS)})")


def digest(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def layout(src, home):
    """El layout de bk, uno solo: herdr/layouts/bk-lavanda.json del repo → layouts/ de Herdr. Sigue al repo mientras
    no lo retoques: bk anota qué instaló (bk-lavanda.instalado, su sha256) y solo pisa una copia que sigue igual a
    esa. Una copia retocada (o una que bk no instaló) queda como está y se avisa. No cambia el layout que se
    muestra: eso es `herdr-app do layout.switch --name bk-lavanda`."""
    want, have = os.path.join(src, "layouts", LAYOUT + ".json"), os.path.join(home, "layouts", LAYOUT + ".json")
    mark = os.path.join(home, LAYOUT + ".instalado")
    new = digest(want)
    try:
        was = open(mark).read().strip()
    except OSError:
        was = ""
    if not os.path.exists(have):
        what = f"instalado (herdr-app do layout.switch --name {LAYOUT})"
    elif digest(have) == new:
        what = "al día"
    elif was and digest(have) == was:
        what = "actualizado"
    else:
        print(f"layout {LAYOUT}: lo retocaste, no lo piso (para tomar el del repo, borrá {have} y repetí)"); return
    if what != "al día":
        os.makedirs(os.path.dirname(have), exist_ok=True)
        tmp = have + ".tmp"
        shutil.copyfile(want, tmp); os.replace(tmp, have)
    if was != new:
        with open(mark, "w") as f:
            f.write(new + "\n")
    print(f"layout {LAYOUT}: {what}")


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
    layout(src, home)

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
