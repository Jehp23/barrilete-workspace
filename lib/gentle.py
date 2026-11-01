"""Estilo compartido de las vistas de bk, a lo gentle-shell (tarjetas "neon" con acento rosa).

Tarjeta:
    ╭─ ✿ Agents · 1 active ─────────────── 12m ╮
    │ ● i211  implementer   sonnet 5.5   2º plano │
    ╰─────────────────────────────────────────────╯
"""
import re, unicodedata

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


def rgb(h):
    h = h.lstrip("#")
    return f"\033[38;2;{int(h[0:2], 16)};{int(h[2:4], 16)};{int(h[4:6], 16)}m"


RST, BOLD, DIM, ITAL = "\033[0m", "\033[1m", "\033[2m", "\033[3m"
ROSE = rgb("F095C8")      # acento principal (títulos, marco)
PETAL = rgb("D7A0B8")     # acento suave
IRIS = rgb("A99CF5")      # trabajo en curso
AMBER = rgb("E6B450")     # espera / segundo plano
GREEN = rgb("8CCB8A")     # listo
RED = rgb("F07178")       # te espera / error
TEXT = rgb("E8DCE3")
MUTED = rgb("7E6E78")
FRAME = rgb("7A5F6E")     # marco de tarjetas inactivas


def cw(ch):
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in "WF" else 1


def vlen(s):
    return sum(cw(c) for c in ANSI.sub("", s))


def cut(line, width):
    """Corta a `width` columnas visibles conservando los colores (con "…" si sobra texto)."""
    if vlen(line) <= width:
        return line + RST
    out, w, i = [], 0, 0
    while i < len(line):
        m = ANSI.match(line, i)
        if m:
            out.append(m.group(0)); i = m.end(); continue
        c = cw(line[i])
        if w + c > width - 1:
            break
        out.append(line[i]); w += c; i += 1
    return "".join(out) + ("…" if width > 0 else "") + RST


def fit(s, width):
    s = cut(s, width) if vlen(s) > width else s
    return s + " " * max(0, width - vlen(s))


def lr(left, right, width):
    """Texto a la izquierda y a la derecha en `width` columnas."""
    gap = width - vlen(left) - vlen(right)
    if gap < 1:
        return fit(left, width)
    return left + " " * gap + right


def card(title, rows, width, color=FRAME, accent=ROSE, glyph="✿", right=""):
    """Tarjeta neon: marco redondeado, título con glifo, filas recortadas al ancho."""
    inner = width - 4
    head = f"{accent}{glyph} {BOLD}{title}{RST}"
    tr = f" {MUTED}{right}{RST} " if right else ""
    fill = width - 4 - vlen(head) - vlen(tr) - 1
    top = f"{color}╭─ {RST}{head}{color} {'─' * max(0, fill)}{RST}{tr}{color}╮{RST}"
    out = [top]
    for r in rows:
        out.append(f"{color}│{RST} {fit(r, inner)} {color}│{RST}")
    out.append(f"{color}╰{'─' * (width - 2)}╯{RST}")
    return out


def hint(keys, width):
    """Fila de atajos: `j/k select   enter abrir …` con la tecla resaltada."""
    parts = [f"{PETAL}{k}{RST} {MUTED}{v}{RST}" for k, v in keys]
    return fit("   ".join(parts), width)
