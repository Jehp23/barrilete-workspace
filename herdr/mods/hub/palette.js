// alt+k: todo lo que se puede hacer, por nombre y con su tecla. Lo del kit primero (lanzar, revisar, aprobar),
// después chats, vistas y la ventana. Las entradas de `bk palette` que no tienen panel propio llegan de
// `bk _hub palette` (lib/palette.py es la lista única) y se corren según su tipo: run lanza, show muestra la
// salida, view abre la pantalla en una terminal sobre la ventana.

import { div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { run, openOverlay, focused, notify } from "herdr";
import { Panel, rank, bk, bin, launch, goto, termPopup, chips, keyOf, lit, cwd, lastLine } from "./kit.js";

const view = (name) => (p) => goto(`bk-${name}`);
const herdr = (name, args) => (p) => { p.close(); run(name, args); };
const out = (title, args) => (p) => goto("bk-out", { props: { title, args, dir: cwd() } });

// [id, grupo, título, comando que se ve a la derecha, tecla (acción de keys.json) | null, palabras, acción]
const NATIVE = [
  ["issues", "Agentes", "Implementar un issue…", "bk run", "mod.open:bk-issues", "lanzar implementer agente", view("issues")],
  ["prs", "Agentes", "Revisar o corregir un PR…", "bk review · bk fix", "mod.open:bk-prs", "reviewer pull request", view("prs")],
  ["plan", "Agentes", "Planear una feature", "bk plan", null, "planner idea", (p) => p.askFor({ label: "plan", title: "¿Qué querés planear?", help: "El planner corre /plan-feature en la raíz del proyecto.", verb: "lanzar el planner", run: (text) => { p.close(); launch("Planner", ["plan", text]); } })],
  ["orchestrate", "Agentes", "Orquestar (hasta 3 issues)", "bk orchestrate", null, "orchestrator repartir", (p) => { p.close(); launch("Orquestador", ["orchestrate"]); }],
  ["tasks", "Agentes", "Tareas y aprobaciones", "bk tasks · bk approve", "mod.open:bk-tasks", "te esperan checkpoints aprobar reviewer", view("tasks")],
  ["todo", "Agentes", "TODO del panel derecho: los pasos del issue de este chat", "bk _todo", "mod.open:bk-todo", "pasos casillas hecho cuando checklist tareas issue", view("todo")],
  ["agents", "Agentes", "Agentes: ver, escribirles, cerrar", "bk ls · say · stop", "mod.open:bk-agents", "peek watch lista", view("agents")],
  ["profiles", "Agentes", "Perfiles de modelos y tareas…", "bk profile · bk ask", null, "perfil modelos proveedor codex claude gemini editar nuevo tarea imagenes investigar", view("profiles")],
  ["next", "Agentes", "Ir al que te espera", "bk go", "mod.open:bk-next", "saltar bloqueado terminó", view("next")],
  ["chat", "Chats", "Chat nuevo en este proyecto", "bk chat", "mod.open:bk-chat", "claude otro", view("chat")],
  ["new", "Chats", "Nuevo… (rama, suelto, otro proyecto)", "bk new", "mod.open:bk-new", "workspace abrir proyecto worktree", view("new")],
  ["sessions", "Chats", "Sesiones: saltar o retomar", "bk s", "mod.open:bk-sessions", "resume recientes orca", view("sessions")],
  ["handoff", "Chats", "Pedir el resumen y seguir en un chat nuevo", "bk handoff", "mod.open:bk-handoff", "contexto clear", view("handoff")],
  ["context", "Chats", "Umbral de contexto: con cuánto seguir en un chat nuevo…", "bk context", "mod.open:bk-handoff", "contexto ventana tokens umbral límite 200k handoff resumen",
    // alt+h ya parado en el umbral en uso; la forma del popup es la de "handoff" en views.json
    (p) => goto("bk-handoff", { props: { section: "limit" }, overlay: { kind: "popup", at: "top", offset: 64, width: 640, height: 0.7 } })],
  ["back", "Chats", "Volver al chat de este espacio", "", "mod.open:bk-back", "orquestador", view("back")],
  ["last", "Chats", "Volver a donde estabas", "", "mod.open:bk-last", "anterior atrás", view("last")],
  ["changes", "Ver", "Cambios sin commitear", "bk changes", "mod.open:bk-changes", "diff git", view("changes")],
  ["branches", "Ver", "Ramas de todos los proyectos", "", "mod.open:bk-branches", "ramas branch worktree limpiar borrar", view("branches")],
  ["stats", "Ver", "Uso y costo", "bk stats · tokens", "mod.open:bk-stats", "estadísticas tokens modelos", view("stats")],
  ["term", "Ver", "Terminal rápida", "bk term", "mod.open:bk-term", "shell", view("term")],
  ["keys", "Ver", "Teclas", "", "mod.open:bk-keys", "atajos ayuda shortcuts", view("keys")],
  ["music", "Ver", "Radio", "bk song", "mod.open:bk-song", "música song", view("song")],
  ["look", "Ventana", "Aspecto: tema, fuente y paneles", "", "mod.open:bk-look", "customize colores theme", view("look")],
  ["split-r", "Ventana", "Dividir a la derecha", "", "pane.split:right", "pane split", herdr("pane.split", { direction: "right" })],
  ["split-d", "Ventana", "Dividir abajo", "", "pane.split:down", "pane split", herdr("pane.split", { direction: "down" })],
  ["zoom", "Ventana", "Agrandar este pane", "", "pane.zoom", "zoom maximizar", herdr("pane.zoom")],
  ["sidebar", "Ventana", "Mostrar u ocultar la barra", "", "layout.toggle:sidebar", "sidebar izquierda", herdr("layout.toggle", { id: "sidebar" })],
  ["lado", "Ventana", "Mostrar u ocultar el panel derecho", "", "layout.toggle:lado", "github estado", herdr("layout.toggle", { id: "lado" })],
  ["tab-close", "Ventana", "Cerrar esta pestaña", "", "tab.close", "cerrar", herdr("tab.close")],
  ["tab-rename", "Ventana", "Renombrar esta pestaña", "", "tab.rename", "nombre", herdr("tab.rename")],
  ["picker", "Ventana", "Ir a un espacio o pestaña…", "", "mod.open:picker", "saltar buscar", herdr("mod.open", { name: "picker" })],
  ["herdr", "Ventana", "Comandos de Herdr", "", "app.palette", "paleta app", herdr("app.palette")],
  ["settings", "Ventana", "Ajustes de Herdr", "", "app.settings", "preferencias", herdr("app.settings")],
];

// Comandos de lib/palette.py que ya tienen entrada nativa arriba (no se repiten)
const COVERED = /^(run|review|fix|plan|orchestrate|stop|watch|changes|term|s|stats|customize|peek|ls|handoff|context|chat|song|profile|ask|models)\b/;
const GROUPS = ["Recientes", "Perfil", "Agentes", "Chats", "Ver", "GitHub", "Sesión", "Barra", "Facultad", "Música", "Ventana"];

export default class Palette extends Panel {
  setup() {
    this.title = "Comandos";
    this.placeholder = "¿Qué querés hacer?";
    this.extra = [];
    this.recent = JSON.parse(localStorage.getItem("recent") ?? "[]");
  }

  async load() {
    const d = await bk(["_hub", "palette"], { json: true, timeout: 8000 });
    this.profiles = d.profile ?? { active: null, profiles: [] };
    this.extra = (d.items ?? []).filter((e) => !COVERED.test(e.cmd)).map((e) => ({
      id: `bk:${e.cmd}`, group: GROUPS.includes(e.group) ? e.group : "Sesión", title: e.label, hint: `bk ${e.cmd}`, key: null, words: e.cmd,
      go: (p) => this.generic(p, e),
    }));
  }

  generic(p, e) {
    const args = e.cmd.split(" ");
    const go = (extra) => {
      const all = [...args, ...extra];
      if (e.kind === "show") return goto("bk-out", { props: { title: e.label, args: all, dir: cwd() } });
      p.close();
      if (e.kind === "view") return termPopup(args[0], `'${bin()}' ${all.join(" ")}`, cwd()).catch((err) => notify({ title: "bk", body: String(err?.message ?? err), level: "error" }));
      launch(e.label, all);
    };
    if (e.arg) return p.askFor({ label: args[0], title: e.label, help: `Falta: ${e.arg}`, run: (text) => go(text.split(/\s+/)) });
    go([]);
  }

  entries() {
    const native = NATIVE.map(([id, group, title, hint, action, words, go]) => ({ id, group, title, hint, key: action ? keyOf(action) : null, words, go }));
    return [...native, ...this.profileEntries(), ...this.extra];
  }

  // Un renglón por perfil de modelos (bk profile): escribir «barato» y enter lo cambia. El activo, marcado.
  profileEntries() {
    const { active, profiles = [] } = this.profiles ?? {};
    // A la derecha solo los modelos, sin repetir: el detalle por rol está en el panel de edición
    return profiles.map(({ name, summary, models }) => ({
      id: `profile:${name}`, group: "Perfil", title: name === active ? `Perfil ${name} · activo` : `Usar el perfil ${name}`,
      hint: models ?? summary, key: null, words: `perfil modelos ${name} ${summary}`,
      go: (p) => {
        p.close();
        if (name === active) return goto("bk-profiles");
        bk(["profile", name]).then((r) => notify(r.code === 0
          ? { title: `Perfil ${name}`, body: lastLine(r.stdout).replace(/^perfil [^:]*: /, ""), level: "success", timeout: 5000 }
          : { title: `No pude usar el perfil ${name}`, body: lastLine(r.stderr), level: "error" }));
      },
    }));
  }

  rows() {
    const all = this.entries();
    if (!this.query.trim()) {
      const recent = this.recent.map((id) => all.find((e) => e.id === id)).filter(Boolean).slice(0, 4);
      const rows = [];
      if (recent.length) rows.push({ head: "Recientes" }, ...recent.map((e) => ({ key: `r-${e.id}`, e })));
      for (const g of GROUPS.slice(1)) {
        const members = all.filter((e) => e.group === g);
        if (members.length) rows.push({ head: g }, ...members.map((e) => ({ key: e.id, e })));
      }
      return rows;
    }
    return rank(all, this.query, (e) => [e.title, `${e.group} ${e.hint} ${e.words}`]).map(({ item, hits }) => ({ key: item.id, e: item, hits }));
  }

  draw(t, r, on) {
    return h_flex().flex_1().min_w(0).gap(10).items_center()
      .child(div().flex_1().min_w(0).child(lit(t, r.e.title, r.hits, on ? t.foreground : t.muted)))
      .when(Boolean(r.e.hint), (el) => el.child(div().flex_none().max_w(240).truncate().text_size(11.5).text_color(t.dim).child(r.e.hint)))
      .when(Boolean(r.e.key), (el) => el.child(chips(t, r.e.key ?? "", on)));
  }

  hints() { return [["enter", "hacer"], ["up", ""], ["down", "elegir"], ["escape", "cerrar"]]; }

  enter(r) {
    const e = r.e;
    this.recent = [e.id, ...this.recent.filter((x) => x !== e.id)].slice(0, 12);
    localStorage.setItem("recent", JSON.stringify(this.recent));
    e.go(this);
  }
}
