#!/usr/bin/env python3
"""Instala en Herdr lo que bk necesita para sus atajos: el mod `bk` y las teclas alt+… (herdr/ del repo).

  herdr_install.py <herdr/ del repo> <carpeta de Herdr (~/.config/herdr-app)>

El mod se copia a mods/bk-<comando>, una carpeta por tecla. Las teclas se suman a keys.json sin pisar nada: una tecla que ya hace otra cosa
queda como está y se avisa. Antes del primer cambio guarda keys.json.antes-de-bk (una sola vez). Herdr deja de
actualizar un keys.json editado: sus atajos nuevos habrá que sumarlos a mano. Imprime qué hizo; correrlo de
nuevo no cambia nada.
"""
import filecmp, json, os, shutil, sys


def main():
    src, home = sys.argv[1], sys.argv[2]
    if not os.path.isdir(home):
        print(f"no existe {home}: abrí Herdr una vez y repetí"); return 1
    want = json.load(open(os.path.join(src, "keys.json")))
    # Una carpeta por comando (mods/bk-<comando>), todas con el mismo mod: una tecla abre un mod por su nombre
    # y no puede pasarle argumentos. mods/bk era la versión con una copia siempre abierta: se va.
    names = sorted({a.split(":", 1)[1] for b in want.values() for a in b.values() if a.startswith("mod.open:bk-")})
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
