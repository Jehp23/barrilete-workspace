#!/usr/bin/env python3
"""Un test no puede correr su función `bk` (la que apunta todo a carpetas temporales) a través de env, command, exec,
nohup, nice, timeout, xargs, sudo ni `sh -c`: esos solo corren programas, así que ejecutan el bk real del PATH, con
tu estado real. Pasó el 2026-11-10: `env -u BK_NO_WARM … bk review 9` en un test creó una tarea en las tareas de
verdad y abrió una ventana en el tmux real.

  check_test_fns.py <test.sh>…     imprime archivo:línea de cada caso y sale con 1 si hay alguno

Mira cada archivo por separado: las funciones que define (`nombre() {`) y las líneas donde uno de esos lanzadores,
después de sus opciones y asignaciones (-u X, A=1, 5s…), tiene como comando el nombre de una de esas funciones.
`env … "$ROOT/bin/bk"`, `command -v bk` y `bash -c "$(declare -f bk); bk …"` están bien y no se marcan.
No ve lo que pasa por una variable (`$CMD bk`) ni un nombre más adentro de la cadena de `sh -c`.
"""
import re, sys

DEF = re.compile(r"(?:^|[\s;{(&|])(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\)\s*[{(]")
LAUNCH = re.compile(r"(?<![\w/.$-])(?:(env|command|exec|nohup|nice|timeout|xargs|sudo)\s+|((?:ba|z|da)?sh)\s+-c\s+[\"'])")
VALUE = r"(?:\"[^\"]*\"|'[^']*'|\$\([^)]*\)|[^\s\"';|&)])*"
SKIP = re.compile(r"\s*(?:-u\s+\w+|[A-Za-z_]\w*=" + VALUE + r"|-[\w-]+(?:=" + VALUE + r")?|\d+(?:\.\d+)?[smhd]?)(?=\s)")
WORD = re.compile(r"\s*([A-Za-z_][\w-]*)(?![\w/.=-])")


def logical_lines(text):
    """(número de la primera línea, texto) con las continuaciones `\\` unidas."""
    out, buf, start = [], "", 0
    for i, line in enumerate(text.split("\n"), 1):
        if not buf:
            start = i
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        out.append((start, buf + line)); buf = ""
    if buf:
        out.append((start, buf))
    return out


def findings(text):
    fns = set(DEF.findall(text))
    out = []
    for n, line in logical_lines(text):
        if line.lstrip().startswith("#"):
            continue
        for m in LAUNCH.finditer(line):
            how = m.group(1) or m.group(2) + " -c"
            pos, opts = m.end(), []
            while True:
                s = SKIP.match(line, pos)
                if not s:
                    break
                opts.append(s.group(0).strip()); pos = s.end()
            w = WORD.match(line, pos)
            if not w or w.group(1) not in fns:
                continue
            if how == "command" and any(o in ("-v", "-V") for o in opts):
                continue   # pregunta qué es, no lo corre
            out.append((n, how, w.group(1)))
    return out


def main():
    bad = 0
    for path in sys.argv[1:]:
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError as e:
            print(f"{path}: no lo pude leer ({e})"); bad += 1; continue
        for n, how, fn in findings(text):
            print(f"{path}:{n}: `{how}` no corre funciones: `{fn}` es una función de este test y ahí se ejecuta el {fn} real del PATH")
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
