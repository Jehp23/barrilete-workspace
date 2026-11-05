#!/usr/bin/env python3
"""bk song ui — pantalla en vivo de la radio: el tema arriba, el espectro del sonido en el medio (16 barras de
graves a agudos, con la marca del pico reciente) y abajo solo las estaciones del género.

Le habla al mpv de `bk song` por su socket IPC. Es solo un control remoto: al salir, la música sigue.
El gráfico es real: mpv separa el audio en 16 franjas de frecuencia (VIZ en song.sh) y astats mide cada una;
acá se leen ~20 veces por segundo. Teclas: espacio pausa · g género · 1-9 radio · n/p · f guardar · +/- vol ·
s cortar · q salir · ? las muestra abajo.

uso: song_ui.py <socket de mpv> <ruta a song.sh>
"""
import json
import os
import re
import select
import shutil
import signal
import socket
import subprocess
import sys
import termios
import time
import tty

SOCK, SONG = sys.argv[1], sys.argv[2]
CACHE = os.environ.get("BK_SONG_CACHE") or os.path.expanduser("~/.cache/bk")
HISTORY_ROWS = 3          # últimos temas que se guardan (se ven con bk song hist)
FPS = 20
BANDS_N = 16              # franjas del espectro: lavfi.astats.3…18 (los canales 1-2 son el audio que suena)
SPEC_RANGE = 30.0         # dB de la escala común: la franja más fuerte de los últimos segundos llena la altura
BAND_RANGE = 15.0         # dB de la escala propia de cada franja (si no, los agudos casi no se mueven)
MIX = 0.6                 # cuánto pesa la escala común (la forma del sonido) contra la propia (el movimiento)
SCALE_SECONDS = 6         # ventana para las escalas automáticas (las radios de techno vienen muy comprimidas)
FALL = 1.8                # cuánto baja una barra por segundo (en alturas); sube al instante
PEAK_HOLD, PEAK_FALL = 0.5, 1.2   # la marca del pico se queda 0,5 s y después cae 1,2 alturas por segundo
CURVE = 1.5               # >1 baja lo sostenido y deja los golpes altos (si no, el tercio de abajo queda siempre lleno)
HEADER_ROWS, FOOTER_ROWS = 4, 3   # tema/datos/cita/vacía arriba; graves…agudos/vacía/estaciones abajo

# Paletas por fondo de terminal. BANDS: el color del perfil por altura, de abajo (apagado) a arriba (rosa).
PALETTES = {
    "dark": {
        "BANDS": [(122, 102, 112), (168, 148, 158), (242, 184, 216), (232, 150, 200)],
        "VIOLET": (232, 150, 200), "DIM": (150, 136, 146), "TEXT": (232, 222, 230), "PINK": (240, 149, 200),
    },
    "light": {
        "BANDS": [(150, 130, 140), (120, 100, 112), (214, 120, 170), (184, 70, 140)],
        "VIOLET": (184, 70, 140), "DIM": (111, 104, 128), "TEXT": (46, 42, 54), "PINK": (142, 79, 117),
    },
}
BANDS = VIOLET = DIM = TEXT = PINK = None


def use_palette(name):
    global BANDS, VIOLET, DIM, TEXT, PINK
    p = PALETTES[name]
    BANDS, VIOLET, DIM, TEXT, PINK = p["BANDS"], p["VIOLET"], p["DIM"], p["TEXT"], p["PINK"]


def terminal_background(fd, out):
    """Le pregunta a la terminal su color de fondo (OSC 11). "light", "dark" o None si no contesta.
    BK_SONG_THEME=light|dark lo fuerza (p. ej. si tmux no pasa la pregunta)."""
    forced = os.environ.get("BK_SONG_THEME", "")
    if forced in PALETTES:
        return forced
    out.write("\033]11;?\033\\")
    out.flush()
    reply, deadline = b"", time.monotonic() + 0.3
    while time.monotonic() < deadline and not (reply.endswith(b"\x07") or reply.endswith(b"\033\\")):
        if select.select([fd], [], [], 0.05)[0]:
            reply += os.read(fd, 64)
    m = re.search(rb"rgb:([0-9a-fA-F]+)/([0-9a-fA-F]+)/([0-9a-fA-F]+)", reply)
    if not m:
        return None
    r, g, b = (int(x, 16) / (16 ** len(x) - 1) for x in m.groups())
    return "light" if 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.5 else "dark"

def fg(rgb):
    return "\033[38;2;%d;%d;%dm" % rgb

RESET, BOLD, ITALIC = "\033[0m", "\033[1m", "\033[3m"


class Mpv:
    """Conexión persistente al socket de mpv; se reconecta sola si mpv se reinicia (cambio de estación)."""

    def __init__(self, path):
        self.path, self.sock, self.buf, self.rid = path, None, b"", 0

    def _connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(self.path)
        self.sock, self.buf = s, b""

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None

    def cmd(self, *args):
        """Devuelve `data` si mpv respondió success, None si no (o si no hay mpv)."""
        for _ in range(2):
            try:
                if self.sock is None:
                    self._connect()
                self.rid += 1
                rid = self.rid
                self.sock.sendall((json.dumps({"command": list(args), "request_id": rid}) + "\n").encode())
                deadline = time.monotonic() + 0.3
                while time.monotonic() < deadline:
                    while b"\n" in self.buf:
                        line, self.buf = self.buf.split(b"\n", 1)
                        try:
                            msg = json.loads(line)
                        except ValueError:
                            continue
                        if msg.get("request_id") == rid:   # el resto son eventos asíncronos de mpv
                            return msg.get("data") if msg.get("error") == "success" else None
                    chunk = self.sock.recv(65536)
                    if not chunk:
                        raise OSError("socket cerrado")
                    self.buf += chunk
                return None
            except OSError:
                self.close()
        return None

    def get(self, prop):
        return self.cmd("get_property", prop)


def song(*args):
    """Reusa bk song para lo que cambia de estación o pausa (así también se entera la barra)."""
    subprocess.run([SONG, *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def db_of(meta, ch):
    """dB RMS del canal `ch` según astats; None en silencio ("-inf") o sin datos."""
    try:
        db = float((meta or {}).get("lavfi.astats.%d.RMS_level" % ch))
    except (TypeError, ValueError):
        return None
    return db if db > -120 else None


class Spectrum:
    """Alturas de las 16 barras (0-1) con caída suave y marcas de pico. Cada barra mezcla una escala común
    (la franja más fuerte de los últimos segundos llena la altura: se ve la forma del sonido) con una propia
    (su máximo reciente: así también se mueven las franjas que varían poco)."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.hist = []                      # (t, [dB por franja])
        self.vals = [0.0] * BANDS_N
        self.peaks = [(0.0, 0.0)] * BANDS_N  # (altura, cuándo llegó)
        self.t = None

    def update(self, dbs, now):
        dt = 0.0 if self.t is None else min(0.5, now - self.t)
        self.t = now
        if any(d is not None for d in dbs):
            self.hist.append((now, dbs))
        while self.hist and now - self.hist[0][0] > SCALE_SECONDS:
            self.hist.pop(0)
        known = [d for _, ds in self.hist for d in ds if d is not None]
        top = max(known) if known else 0.0
        for i, d in enumerate(dbs):
            if d is None:
                target = 0.0
            else:
                btop = max((ds[i] for _, ds in self.hist if ds[i] is not None), default=d)
                common = (d - (top - SPEC_RANGE)) / SPEC_RANGE
                own = (d - (btop - BAND_RANGE)) / BAND_RANGE
                target = max(0.0, min(1.0, MIX * common + (1 - MIX) * own)) ** CURVE
            v = max(target, self.vals[i] - FALL * dt)
            self.vals[i] = v
            ph, pt = self.peaks[i]
            if v >= ph:
                self.peaks[i] = (v, now)
            elif now - pt > PEAK_HOLD:
                self.peaks[i] = (max(v, ph - PEAK_FALL * dt), pt)


def clip(text, width):
    return text if len(text) <= width else text[: max(0, width - 1)] + "…"


def render_graph(vals, peaks, width, rows):
    """Espectro: una barra por franja, de graves (izquierda) a agudos, que crece desde abajo con 1/8 de celda.
    El color va por altura en franjas fijas (como un ecualizador): abajo apagado, arriba rosa. Arriba de cada
    barra, la marca ▔ de su pico reciente."""
    blocks = " ▁▂▃▄▅▆▇█"
    n = len(vals)
    bw = max(1, (width - (n - 1)) // n)          # ancho de barra, con una columna de aire entre barras
    pad = " " * max(0, (width - (bw * n + n - 1)) // 2)
    out = []
    for r in range(rows):                       # r = 0 es la fila de arriba
        h = rows - 1 - r                        # altura de esta fila desde abajo
        color = fg(BANDS[min(len(BANDS) - 1, h * len(BANDS) // max(1, rows))])
        cells = []
        for v, (p, _) in zip(vals, peaks):
            fill = v * rows - h
            if fill >= 1:
                c = color + "█"
            elif fill > 0:
                c = color + blocks[int(fill * 8)]
            elif p > v and int(min(p, 0.999) * rows) == h:
                c = fg(PINK) + "▔"
            else:
                c = " "
            cells.append(c * bw if len(c) == 1 else c[:-1] + c[-1] * bw)
        out.append(pad + " ".join(cells))
    return out


def main():
    if not sys.stdin.isatty():
        sys.exit("bk song ui necesita una terminal")

    mpv = Mpv(SOCK)
    def load_stations():
        rows = [l.split("\t") for l in
                subprocess.run([SONG, "stations"], capture_output=True, text=True).stdout.splitlines()]
        return [(r[0], r[1], r[2] if len(r) > 2 else "") for r in rows if len(r) >= 2]

    stations = load_stations()
    genres = list(dict.fromkeys(g for _, _, g in stations))
    view = None           # género que muestran los números (sigue al que suena hasta que apretás g)
    spec = Spectrum()
    old_viz = False       # el mpv que suena arrancó con el filtro de antes (solo volumen, sin franjas)
    info = {"station": "", "key": "", "genre": "", "title": "", "paused": False, "vol": 0, "alive": False,
            "br": "", "icy": ""}
    history = []
    last_info, msg, msg_until = 0.0, "", 0.0

    fd = sys.stdin.fileno()
    old_tty = termios.tcgetattr(fd)
    out = sys.stdout

    def restore(*_):
        termios.tcsetattr(fd, termios.TCSADRAIN, old_tty)
        out.write("\033[?25h\033[?1049l")         # cursor visible, salir de la pantalla alternativa
        out.flush()

    def on_term(*_):
        restore()
        sys.exit(0)

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGHUP, on_term)
    tty.setcbreak(fd)
    # Sin respuesta (terminal vieja o tmux sin passthrough): claro, que es el tema de Ghostty en este setup
    use_palette(terminal_background(fd, out) or "light")
    out.write("\033[?1049h\033[?25l")
    try:
        while True:
            t0 = time.monotonic()
            cols, lines = shutil.get_terminal_size((80, 24))
            width = max(20, cols - 4)

            # ---- estado (1 vez por segundo) ----
            if t0 - last_info > 1.0:
                last_info = t0
                info["alive"] = mpv.get("pid") is not None
                if info["alive"]:
                    meta = mpv.get("metadata") or {}
                    title = meta.get("icy-title") or meta.get("title") or ""
                    if title and title != info["title"]:
                        song("bar-status")    # anota el tema nuevo en el historial
                    info["title"] = title
                    info["br"] = meta.get("icy-br") or ""
                    info["icy"] = meta.get("icy-name") or meta.get("icy-description") or ""
                    info["paused"] = bool(mpv.get("pause"))
                    info["vol"] = int(mpv.get("volume") or 0)
                try:
                    parts = open(os.path.join(CACHE, "song.station")).read().rstrip("\n").split("\t")
                except OSError:
                    parts = []
                key, name, genre = (parts + ["", "", ""])[:3]
                genre = next((g for k, _, g in stations if k == key), genre)
                info["key"], info["station"], info["genre"] = key, name, genre
                try:
                    lines_h = open(os.path.join(CACHE, "song.history")).read().splitlines()[-HISTORY_ROWS:]
                    history = [l.split("\t") for l in reversed(lines_h) if l.count("\t") >= 2]
                except OSError:
                    history = []

            # ---- espectro (cada frame; en pausa las barras bajan solas) ----
            dbs = [None] * BANDS_N
            if info["alive"] and not info["paused"]:
                meta = mpv.get("af-metadata/viz")
                old_viz = bool(meta) and "lavfi.astats.3.RMS_level" not in meta
                dbs = [db_of(meta, 3 + i) for i in range(BANDS_N)]
            spec.update(dbs, t0)

            # ---- dibujo ----
            shown = view or info["genre"] or (genres[0] if genres else "")
            in_view = [st for st in stations if st[2] == shown][:9]
            buf = ["\033[H"]
            if info["alive"]:
                title = info["title"] or info["station"] or "?"
                datos = " · ".join(x for x in ("⏸ en pausa" if info["paused"] else "", info["genre"],
                                                info["station"] if info["title"] else "",
                                                f'{info["br"]} kbps' if info["br"] else "", f'vol {info["vol"]}%') if x)
                cita = info["icy"] if info["icy"] and info["icy"] != info["station"] else (history[1][2] if len(history) > 1 else "")
                buf.append("\033[2K  " + fg(PINK) + BOLD + "♪ " + clip(title, width - 2) + RESET + "\n")
                buf.append("\033[2K  " + fg(DIM) + clip(datos, width) + RESET + "\n")
                buf.append("\033[2K  " + (fg(TEXT) + ITALIC + "“" + clip(cita, width - 4) + "”" + RESET if cita else "") + "\n\033[2K\n")
            else:
                buf.append("\033[2K  " + fg(DIM) + "■ no está sonando nada — [n] o [1-%d] para arrancar" % len(stations)
                           + RESET + "\n\033[2K\n\033[2K\n\033[2K\n")
            rows = max(3, lines - HEADER_ROWS - FOOTER_ROWS)
            graph = render_graph(spec.vals, spec.peaks, width, rows)
            if old_viz:   # mpv viejo: sin franjas no hay espectro; al cambiar de estación arranca con el filtro nuevo
                graph[rows // 2] = " " * max(0, (width - 52) // 2) + fg(DIM) + "el espectro aparece al cambiar de estación (n o 1-9)"
            for line in graph:
                buf.append("\033[2K  " + line + RESET + "\n")
            buf.append("\033[2K  " + fg(DIM) + "graves" + " " * max(1, width - 12) + "agudos" + RESET + "\n\033[2K\n")
            # Abajo, solo las estaciones del género (las teclas, con ?)
            # Cortadas al ancho: si la línea se partiera en dos, la pantalla se correría y se perdería el título
            used, items = len(shown) + 2, []
            for n, (k, _, _) in enumerate(in_view):
                txt = "%d %s" % (n + 1, k)
                if used + len(txt) + 2 > width:
                    break
                used += len(txt) + 2
                items.append((fg(PINK) + BOLD if k == info["key"] else fg(DIM)) + txt + RESET)
            line = fg(DIM) + shown + ": " + RESET + "  ".join(items)
            if msg and t0 < msg_until:   # el aviso o las teclas (?): al lado si entran, si no en lugar de las radios
                line = line + fg(DIM) + "   " + msg + RESET if used + 3 + len(msg) <= width else fg(DIM) + clip(msg, width) + RESET
            buf.append("\033[2K  " + line + "\033[J")
            out.write("".join(buf))
            out.flush()

            # ---- teclas ----
            timeout = max(0.0, 1.0 / FPS - (time.monotonic() - t0))
            if select.select([sys.stdin], [], [], timeout)[0]:
                ch = os.read(fd, 32).decode(errors="ignore")[:1]
                if ch in ("q", "Q", "\x1b"):
                    break
                elif ch == " ":
                    song("pause")
                elif ch in ("n", "N"):
                    msg, msg_until = "cambiando de estación…", time.monotonic() + 3
                    mpv.close(); song("next"); spec.reset()
                elif ch in ("p", "P"):
                    msg, msg_until = "cambiando de estación…", time.monotonic() + 3
                    mpv.close(); song("prev"); spec.reset()
                elif ch.isdigit() and 1 <= int(ch) <= len(in_view):
                    msg, msg_until = "cambiando de estación…", time.monotonic() + 3
                    mpv.close(); song(in_view[int(ch) - 1][0]); spec.reset()
                    view = None
                elif ch in ("g", "G", "\t") and genres:
                    i = genres.index(shown) if shown in genres else -1
                    view = genres[(i + (-1 if ch == "G" else 1)) % len(genres)]
                elif ch in ("f", "F"):
                    r = subprocess.run([SONG, "fav"], capture_output=True, text=True)
                    msg, msg_until = (r.stdout or r.stderr).strip().splitlines()[-1] if (r.stdout or r.stderr).strip() else "", time.monotonic() + 3
                    stations = load_stations(); genres = list(dict.fromkeys(g for _, _, g in stations))
                elif ch in ("+", "=", "-", "_"):
                    step = 5 if ch in ("+", "=") else -5
                    mpv.cmd("set_property", "volume", max(0, min(100, int(mpv.get("volume") or 0) + step)))
                elif ch == "?":
                    msg, msg_until = "espacio pausa · g género · 1-9 radio · n/p · f guardar · +/- vol · s cortar · q salir", time.monotonic() + 5
                elif ch in ("s", "S"):
                    mpv.close(); song("stop")
                    break
                last_info = 0.0               # refrescar estado ya después de cualquier tecla
    except KeyboardInterrupt:
        pass
    finally:
        restore()
        mpv.close()


if __name__ == "__main__":
    main()
