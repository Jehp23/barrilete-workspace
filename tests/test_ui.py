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


class EstadosUnicos(unittest.TestCase):
    """La tira, el riel, el monitor y los overlays dicen lo mismo de cada estado: gentle.STATES."""

    def test_cada_estado_tiene_su_glifo_salvo_los_que_son_lo_mismo(self):
        # sin esto, "trabajando" y "te espera" volverían a distinguirse solo por el color
        por_glifo = {}
        for k, (g, _, _) in G.STATES.items():
            por_glifo.setdefault(g, []).append(k)
        iguales = {"!": ["waiting", "permission"], "●": ["working", "trust"], "·": ["ended", "none"]}
        for g, ks in por_glifo.items():
            self.assertEqual(ks, iguales.get(g, ks[:1]), g)
        # y los pares que no pueden confundirse tienen glifo o color distinto
        for a, b in (("working", "waiting"), ("working", "question"), ("question", "permission"),
                     ("done", "idle"), ("working", "stale"), ("working", "trust")):
            self.assertNotEqual(G.STATES[a][::2], G.STATES[b][::2], (a, b))

    def test_state_ui_con_estado_desconocido_o_vacio(self):
        self.assertEqual(G.state_ui("rarisimo"), ("·", "rarisimo", "muted"))
        self.assertEqual(G.state_ui(None), ("·", "sin estado", "muted"))

    def test_los_colores_de_los_estados_existen_en_la_paleta(self):
        for k in G.STATES:
            g, txt, c = G.state_ansi(k)
            self.assertIn(G.STATES[k][2], G.STATE_COLOR, k)
            self.assertIn(G.STATES[k][2], G.CURSES_NAMES, k)      # la tira lo pide a curses_attrs por ese nombre
            self.assertEqual(c, getattr(G, G.STATE_COLOR[G.STATES[k][2]]), k)

    def test_la_tira_usa_la_tabla(self):
        import sidebar
        attrs = {n: i + 1 for i, n in enumerate(G.CURSES_NAMES)}
        for st in ("working", "background", "stale", "question", "permission", "waiting", "none", "idle", "done"):
            g, a = sidebar.dot_for(st, 0, attrs)
            self.assertEqual(a, attrs[G.STATES[st][2]], st)
            if st not in ("working", "background"):
                self.assertEqual(g, G.STATES[st][0], st)
        self.assertNotEqual(sidebar.dot_for("working", 0, attrs)[0], sidebar.dot_for("working", 1, attrs)[0])  # gira

    def test_el_riel_usa_la_tabla(self):
        import rail
        for st in ("working", "background", "waiting", "done", "idle", "error", "trust", "question", "permission"):
            self.assertEqual(rail.state_row(st), G.state_ansi(st), st)

    def test_agents_view_dash_y_sessions_usan_la_tabla(self):
        import agents_view as AV, dash as DA, sessions as SE
        for st in ("working", "waiting", "done", "idle", "trust", "question", "permission"):
            g, txt, col = G.state_ansi(st)
            self.assertEqual(AV.state_style(st), (f"{g} {txt}", col), st)
            self.assertEqual(DA.state_style(st), (f"{g} {txt}", col), st)
        for k, txt in SE.STATE_TXT.items():
            self.assertEqual(txt, G.STATES[k][1], k)

    def test_monitor_y_lista_de_agentes_usan_la_tabla(self):
        import monitor as MO, agents as AG
        base = {"asks": False, "why": "", "state": "idle", "kind": "agent", "mins": 0}
        casos = [({"state": "working"}, "working"), ({"state": "background"}, "background"),
                 ({"state": "done"}, "done"), ({"state": "idle"}, "idle"), ({"state": ""}, "none"),
                 ({"asks": True, "why": "pide permiso"}, "permission"), ({"asks": True, "why": "elegí"}, "question")]
        for extra, key in casos:
            g, c, _ = MO.state_of({**base, **extra})
            self.assertEqual((g, c), G.state_ansi(key)[::2], key)
        g, c, t = MO.state_of({**base, "state": "working", "mins": 60})
        self.assertEqual((g, c), G.state_ansi("stale")[::2])
        self.assertEqual(MO.state_of({**base, "kind": "chat"})[0], "◇")   # un chat se ve distinto de un agente
        # bk ls: glifo y color del estado, el chat con su rombo
        ag = {**base, "short": "x", "win": "i1", "title": "t", "num": "1", "ref": "", "project": "p", "queued": 0,
              "question": "", "note": ""}
        for st in ("working", "done", "idle"):
            ln = AG.line({**ag, "state": st}, color=False)
            self.assertTrue(ln.startswith(G.STATES[st][0] + " "), (st, ln))
        self.assertIn(G.state_ansi("working")[2], AG.line({**ag, "state": "working"}))
        self.assertTrue(AG.line({**ag, "state": "working", "kind": "chat"}, color=False).startswith("◇ "))


class SongUiPaleta(unittest.TestCase):
    def _song_ui(self):
        argv, sys.argv = sys.argv, ["song_ui", "sock", "song"]   # song_ui lee argv al importarse (es un script)
        try:
            import song_ui as SU
        finally:
            sys.argv = argv
        return SU

    def test_las_paletas_salen_de_gentle(self):
        SU = self._song_ui()
        for nombre, pal in (("dark", G.NIGHT), ("light", G.DAY)):
            p = SU.PALETTES[nombre]
            self.assertEqual(p["PINK"], G.rgb(pal["rose"]), nombre)
            self.assertEqual(p["DIM"], G.rgb(pal["muted"]), nombre)
            self.assertEqual(p["TEXT"], G.rgb(pal["text"]), nombre)
            self.assertEqual((p["BANDS"][0], p["BANDS"][-1]), (G.rgb(pal["muted"]), G.rgb(pal["rose"])), nombre)
            self.assertEqual(len(p["BANDS"]), 4)

    def test_rgb_y_ramp_con_otra_paleta(self):
        self.assertEqual(G.rgb("#F095C8"), (240, 149, 200))
        self.assertEqual(G.ramp(2, "tint", "rose", G.DAY), [G.DAY["tint"], G.DAY["rose"]])


class NoTocaLaConfig(unittest.TestCase):
    def test_la_suite_no_toca_tu_ui_json(self):
        self.assertNotEqual(os.path.realpath(G.UI_FILE), os.path.realpath(REAL_UI))
        self.assertEqual(os.path.realpath(REAL_UI), os.path.realpath(os.path.expanduser("~/.config/bk/ui.json")))


if __name__ == "__main__":
    unittest.main()
