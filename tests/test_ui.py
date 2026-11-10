"""Tests del estilo de las vistas: una sola paleta (gentle.P), una tabla de estados y las proporciones.

Corre con tests/test_ui.sh (lo levanta lib/checks.sh).
"""
import os, re, sys, tempfile, types, unittest

LIB = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib")
sys.path.insert(0, LIB)
os.environ["BK_STATE_DIR"] = tempfile.mkdtemp()   # nunca el estado real de los agentes
os.environ["BK_TASKS_DIR"] = tempfile.mkdtemp()   # ni tus tareas
os.environ["BK_CACHE_DIR"] = tempfile.mkdtemp()   # ni tu caché de títulos
os.environ["BK_CONFIG_DIR"] = tempfile.mkdtemp()  # ni tu configuración
import gentle as G          # noqa: E402
REAL_UI = G.UI_FILE
G.UI_FILE = os.path.join(tempfile.mkdtemp(), "ui.json")   # nunca tu ~/.config/bk/ui.json (save_ui lo escribe)

STRIP = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def falso_curses():
    """Un curses que solo anota los pares: (módulo, {par: (color, fondo)})."""
    pares = {}
    return types.SimpleNamespace(init_pair=lambda n, f, b: pares.__setitem__(n, (f, b)),
                                 color_pair=lambda n: n << 8), pares


class PaletaUnica(unittest.TestCase):
    """Todas las vistas toman los colores de gentle (día/noche); ninguna trae su tabla de números 256."""

    def _attrs(self, **kw):
        falso, pares = falso_curses()
        real = sys.modules.get("curses")
        sys.modules["curses"] = falso
        try:
            return G.curses_attrs(**kw), pares
        finally:
            if real is None:
                del sys.modules["curses"]
            else:
                sys.modules["curses"] = real

    def test_to256_extremos_y_grises(self):
        self.assertEqual(G.to256("FFFFFF"), 231)
        self.assertEqual(G.to256("#000000"), 16)
        self.assertEqual(G.to256("808080"), 244)    # gris puro: la rampa de grises, no el cubo
        self.assertEqual(G.to256("FF0000"), 196)    # color puro: el cubo

    def test_ramp_va_de_un_tono_al_otro(self):
        r = G.ramp(5)
        self.assertEqual((len(r), r[0], r[-1]), (5, G.P["tint"], G.P["rose"]))
        self.assertEqual(G.ramp(1), [G.P["tint"]])   # un solo paso no divide por cero

    def test_curses_attrs_inicia_un_par_por_color_de_la_paleta(self):
        a, pares = self._attrs(base=30, shades=3)
        self.assertEqual(set(a), set(G.CURSES_NAMES) | {"shade0", "shade1", "shade2"})
        for name in G.CURSES_NAMES:
            self.assertEqual(pares[a[name] >> 8], (G.to256(G.P[name]), -1), name)
        self.assertEqual(len(set(a.values())), len(a))       # ningún par pisa a otro
        self.assertEqual(pares[a["shade2"] >> 8][0], G.to256(G.P["rose"]))

    def test_curses_attrs_con_ids_suma_los_numeros_de_workspace_y_el_contexto(self):
        a, pares = self._attrs(ids=True, shades=2)
        ids = G.ID_DAY if G.P is G.DAY else G.ID_NIGHT
        ctx = G.CTX_DAY if G.P is G.DAY else G.CTX_NIGHT
        self.assertEqual([pares[a[f"id{i}"] >> 8][0] for i in range(len(ids))], ids)
        self.assertEqual({k: pares[a[k] >> 8][0] for k in ("warn", "high")}, ctx)
        self.assertEqual(len(set(a.values())), len(a))       # ni con ids y shades se pisan
        self.assertEqual(len(G.ID_DAY), len(G.ID_NIGHT))     # la tira y sesiones cuentan con el mismo largo
        self.assertNotIn("id0", self._attrs()[0])

    def test_ninguna_vista_define_colores_propios(self):
        mal = []
        for f in sorted(os.listdir(LIB)):
            if not f.endswith(".py") or f == "gentle.py":
                continue
            with open(os.path.join(LIB, f), encoding="utf-8") as fh:
                for n, l in enumerate(fh, 1):
                    if re.search(r"init_pair\(|\\033\[38;5;|\\x1b\[38;5;", l):
                        mal.append(f"{f}:{n}: {l.strip()}")
        self.assertEqual(mal, [], "colores fuera de gentle.py: usá G.curses_attrs() o G.ROSE…")

    def test_las_vistas_importan_con_la_paleta(self):
        # cada vista toma sus colores al importarse o en ui(): que al menos importe sin tocar nada
        for m in ("agents", "agents_view", "changes", "customize", "dash", "new", "palette", "sessions",
                  "sidebar", "stats", "subwatch"):
            __import__(m)


class NoTocaLaConfig(unittest.TestCase):
    def test_la_suite_no_toca_tu_ui_json(self):
        self.assertNotEqual(os.path.realpath(G.UI_FILE), os.path.realpath(REAL_UI))
        self.assertEqual(os.path.realpath(REAL_UI), os.path.realpath(os.path.expanduser("~/.config/bk/ui.json")))


if __name__ == "__main__":
    unittest.main()
