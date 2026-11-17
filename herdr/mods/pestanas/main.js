// La franja de arriba de bk-lavanda: el contexto del chat enfocado, no sus pestañas (esas ya son las filas de
// AGENTES y se eligen con alt+N). Dos renglones como mucho:
//   1. proyecto › #épica título › #issue título · rol. La épica y el issue solo si el chat tiene uno de verdad
//      (bk _epica / bk _todo lo encuentran en su worktree, su conversación, su rama o un #N); el rol, si bk lo lanzó
//      con uno (etiqueta bk.role). Sin issue: lo que el agente dice que hace.
//   2. el avance: las casillas del issue (- [ ]) hechas y la próxima. Solo si el issue tiene casillas.
// A la derecha: los agentes que te esperan (de cualquier espacio, menos el enfocado), Archivos y Cambios si están
// habilitados, y mostrar u ocultar el lado derecho. El panel Archivos/Cambios se recuerda por espacio.

import { View, div, svg } from "gpui-kit";
import { h_flex, v_flex } from "gpui-base";
import { exec, spaces, panes, terminals, agents, focused, run, theme, window, shared, layout, settings, home } from "herdr";
import { PROSE, al, find, ids, said, mark, keycap, iconButton } from "./kit.js";

const EVERY = 20000;   // bk _todo y bk _epica guardan lo de GitHub unos minutos: esto solo vuelve a leer su caché
const WAIT_MAX = 4;    // chips de «te espera»; los demás, en un +N
const bin = () => shared("bk.bin") || "bk";
const gh = (url) => { if (/^https:\/\/github\.com\//.test(url ?? "")) exec("open", [url]); };

// Lo que bk necesita para saber el issue del chat enfocado (como el lado derecho y ÉPICAS): carpeta, rama, su
// nombre (bk.name, bk.autotitle y el título del pane) y su terminal. null sin una terminal enfocada.
export function chatArgs(f = focused(), all = panes(), ts = terminals()) {
  if (!f?.terminal) return null;
  const p = all.find((x) => x.pane === f.pane) ?? {};
  const l = ts.find((x) => x.address === f.terminal)?.labels ?? {};
  return [f.cwd ?? home(), p.branch ?? "", [l["bk.name"], l["bk.autotitle"], p.title].filter(Boolean).join(" "), f.terminal];
}
const keyOf = (q) => (q ? JSON.stringify(q) : "-");

// Lo que se dibuja, de lo que dijeron bk _todo y bk _epica. issue y epic son null sin asociación real (la épica,
// además, si es el issue mismo); steps es null si el issue no tiene casillas: ahí no va el renglón de avance.
export function context(todo, epica) {
  const issue = todo?.issue ? { number: todo.issue, title: todo.title ?? "", url: todo.url ?? "" } : null;
  const e = epica?.epic;
  const epic = issue && e && e.number !== issue.number
    ? { number: e.number, title: e.title ?? "", url: `https://github.com/${e.repo}/issues/${e.number}` } : null;
  const items = issue && Array.isArray(todo.items) ? todo.items : [];
  const steps = items.length ? { done: items.filter((x) => x.done).length, total: items.length, items, next: items.find((x) => !x.done) ?? null } : null;
  return { issue, epic, steps };
}

// Los que te esperan, para los chips: estado blocked, sin el chat que estás mirando, por número de ventana.
export function waiting(list, here, numbers) {
  return list.filter((a) => a.status === "blocked" && a.address !== here)
    .map((a) => ({ address: a.address, pane: a.pane, n: numbers.get(a.address) ?? null, name: said(a.title, a.program, a.address) || a.tab_name || a.space_name }))
    .sort((a, b) => (Number(a.n) || 1e9) - (Number(b.n) || 1e9));
}

export default class Pestanas extends View {
  init(_props, cx) {
    this.panels = JSON.parse(localStorage.getItem("panels") ?? "{}");
    this.key = "";
    this.at = 0;
    this.todo = null;
    this.epica = null;
    this.busy = false;
    cx.timer.every(EVERY, (cx) => cx.spawn(async (cx) => { if (await this.load(true)) cx.notify(); }));
  }

  // Pide el issue, sus casillas y su épica del chat enfocado. Otro chat: borra lo del anterior antes de leer, así
  // nunca se ve el issue de otro. true si hay que volver a dibujar (cambió lo que se muestra, o el foco se movió
  // mientras leía: el dibujo pide el nuevo).
  async load(tick = false) {
    const q = chatArgs();
    const key = keyOf(q);
    if (this.busy || (key === this.key && (!tick || Date.now() - this.at < EVERY))) return false;
    const before = JSON.stringify([this.todo, this.epica]);
    if (key !== this.key) { this.todo = null; this.epica = null; }
    this.key = key;
    this.at = Date.now();
    if (q) {
      this.busy = true;
      try {
        const [todo, epica] = await Promise.all([exec(bin(), ["_todo", ...q], { timeout: 30000 }), exec(bin(), ["_epica", ...q], { timeout: 30000 })]);
        if (todo.code === 0) this.todo = JSON.parse(todo.stdout);
        if (epica.code === 0) this.epica = JSON.parse(epica.stdout);
      } catch { /* queda lo último */ } finally {
        this.busy = false;
      }
    }
    return before !== JSON.stringify([this.todo, this.epica]) || keyOf(chatArgs()) !== this.key;
  }

  // El panel lateral (Archivos/Cambios) se recuerda por espacio: al cambiar de espacio se muestra el suyo
  // (cerrado si nunca tuvo), y abrirlo o cerrarlo lo anota.
  syncPanel(space, panel, body, enabled) {
    if (!space || !panel) return;
    const now = panel.hidden ? null : body?.active ?? null;
    if (space.id !== this.space) {
      const first = this.space === undefined;
      this.space = space.id; this.pending = null;
      if (!(first && !(space.id in this.panels))) {
        const stored = this.panels[space.id] ?? null, want = enabled.includes(stored) ? stored : null;
        if (want !== now) {
          this.pending = { want, until: Date.now() + 1000 };
          if (want) { run("layout.select", { stack: "panel-body", child: want }); run("layout.show", { id: "panel" }); }
          else run("layout.hide", { id: "panel" });
          return;
        }
      }
    }
    // Hasta que la restauración llegue (o gane otra cosa), el estado viejo no es una elección.
    if (this.pending) {
      if (this.pending.want !== now && Date.now() < this.pending.until) return;
      this.pending = null;
    }
    if (this.panels[space.id] === now) return;
    this.panels[space.id] = now;
    localStorage.setItem("panels", JSON.stringify(this.panels));
  }

  render(cx) {
    const t = theme();
    const f = focused();
    const ts = terminals();
    // Otro chat enfocado: pedir lo suyo ya, sin esperar el próximo tick
    if (keyOf(chatArgs(f, panes(), ts)) !== this.key && !this.busy) cx?.spawn(async (cx) => { if (await this.load()) cx.notify(); });
    const stop = (_e, cx) => cx.stop_propagation();
    const space = spaces().find((p) => p.active);
    const numbers = ids(ts);
    const here = f?.terminal ?? null;
    const role = ts.find((x) => x.address === here)?.labels?.["bk.role"] || null;
    const list = agents();
    const me = list.find((a) => a.address === here);
    const { issue, epic, steps } = context(this.todo, this.epica);

    // Renglón 1: dónde estás. Cada tramo se corta solo.
    const sep = () => div().flex_none().text_color(t.dim).child("›");
    const ref = (id, x, color, maxW) => h_flex().id(id).min_w(0).gap(5).items_center().cursor_pointer()
      .on_mouse_down("left", stop).on_click(() => gh(x.url)).tooltip(`#${x.number} ${x.title} · abrir en GitHub`)
      .child(div().flex_none().font_semibold().text_color(t.accent).child(`#${x.number}`))
      .when(Boolean(x.title), (el) => el.child(div().min_w(0).max_w(maxW).truncate().font_family(PROSE).text_color(color).child(x.title)));
    const doing = issue ? "" : said(me?.title, me?.program, here);
    const line1 = h_flex().min_w(0).gap(7).items_center().text_size(12.5)
      .child(div().flex_none().font_medium().text_color(t.foreground).child(space?.name ?? "~"))
      .when(Boolean(epic), (el) => el.child(sep()).child(ref("ctx-epic", epic, t.muted, 220)))
      .when(Boolean(issue), (el) => el.child(sep()).child(ref("ctx-issue", issue, t.foreground, 420)))
      .when(Boolean(doing), (el) => el.child(sep()).child(div().min_w(0).truncate().font_family(PROSE).text_color(t.muted).child(doing)))
      .when(Boolean(role), (el) => el.child(div().flex_none().px(6).h(17).flex().items_center().rounded(5).bg(al(t.accent, "1c"))
        .text_size(10.5).line_height(1).font_medium().text_color(t.accent).child(role ?? "")));

    // Renglón 2: el avance del issue, una rayita por casilla, y la próxima.
    const line2 = steps ? h_flex().id("ctx-steps").min_w(0).gap(7).items_center().text_size(10.5).text_color(t.dim)
      .tooltip(steps.next ? `Sigue (${steps.next.section || "issue"}): ${steps.next.text}` : "Todas las casillas hechas")
      .child(h_flex().flex_none().gap(2).children(steps.items.slice(0, 24).map((x) => div().w(steps.total > 12 ? 6 : 10).h(4).rounded(2).bg(x.done ? t.done : t.border))))
      .child(div().flex_none().font_medium().text_color(steps.done === steps.total ? t.done : t.muted).child(`${steps.done}/${steps.total}`))
      .when(Boolean(steps.next), (el) => el.child(div().min_w(0).truncate().font_family(PROSE).child((steps.next?.text ?? "").replace(/`/g, ""))))
      : null;

    // Los que te esperan: el chip de su número; clic lleva a su pane.
    const wait = waiting(list, here, numbers);
    const chip = (a) => h_flex().id(`wait-${a.address}`).flex_none().h(24).pl(4).pr(5).gap(5).items_center().rounded(6).cursor_pointer()
      .border_1().border_color(al(t.blocked, "59")).bg(al(t.blocked, "14")).hover((s) => s.bg(al(t.blocked, "26")))
      .tooltip(`${a.name || "Agente"} · te espera`).on_mouse_down("left", stop).on_click(() => run("pane.focus", { pane: a.pane }))
      .child(keycap(t, a.n, { size: 18 })).child(mark(t, "blocked", 12));
    const more = wait.length - WAIT_MAX;

    const root = layout(), sidebar = find(root, "sidebar"), w = window();
    // Con la barra izquierda oculta o angosta, la franja le deja lugar a los botones de la ventana.
    const lightsPadding = w?.platform === "macos" && w.titlebar === "none" && !w.fullscreen && root?.traffic_lights
      ? Math.max(12, (root.traffic_lights[0] + 66) / (settings().zoom ?? 1) - (sidebar?.hidden ? 0 : sidebar?.size?.px ?? 0))
      : 12;
    const panel = find(root, "panel"), body = find(root, "panel-body"), lado = find(root, "lado");
    const enabled = shared("workspace.panels") ?? ["files", "changes"];
    this.syncPanel(space, panel, body, enabled);
    const panelButton = (id, label, icon) => {
      const on = panel && !panel.hidden && body?.active === id;
      return h_flex().id(`panel-${id}`).h(24).px(8).gap(6).flex_none().items_center().rounded(6).cursor_pointer()
        .text_size(11.5).bg(on ? t.selected : "#00000000").text_color(on ? t.foreground : t.muted)
        .hover((s) => s.bg(t.hover).text_color(t.foreground)).on_mouse_down("left", stop)
        .on_click(() => {
          if (on) run("layout.hide", { id: "panel" });
          else { run("layout.select", { stack: "panel-body", child: id }); run("layout.show", { id: "panel" }); }
        }).child(svg(icon).size(13)).child(label);
    };
    const winButton = (id, label, action) => div().id(id).size(24).flex_none().flex().items_center().justify_center().rounded(6).text_color(t.dim)
      .hover((s) => s.bg(t.hover).text_color(t.foreground)).on_mouse_down("left", stop).on_click(action).child(label);
    return h_flex().size_full().min_w(0).pr(8).pl(lightsPadding).gap(6).items_center().bg(t.chrome)
      .child(v_flex().id("ctx").flex_1().min_w(0).gap(4).justify_center().child(line1).when(Boolean(line2), (el) => el.child(line2)))
      .when(wait.length > 0, (el) => el.child(h_flex().id("ctx-wait").flex_none().gap(4).items_center()
        .children(wait.slice(0, WAIT_MAX).map(chip))
        .when(more > 0, (x) => x.child(div().flex_none().text_size(11).text_color(t.blocked).tooltip(wait.slice(WAIT_MAX).map((a) => a.name || a.n).join(" · ")).child(`+${more}`)))))
      .when(enabled.includes("files"), (el) => el.child(panelButton("files", "Archivos", "mods/files/file.svg")))
      .when(enabled.includes("changes"), (el) => el.child(panelButton("changes", "Cambios", "mods/changes/changes.svg")))
      .when(Boolean(lado), (el) => el.child(iconButton(t, "lado-toggle", "mods/bk-pestanas/panel.svg", () => run("layout.toggle", { id: "lado" }), { tip: lado?.hidden ? "Mostrar el lado derecho" : "Ocultar el lado derecho", on: !lado?.hidden, stop: true, size: 15 })))
      .when(Boolean(w?.buttons), (el) => el.child(winButton("minimize", w.platform === "windows" ? svg("mods/tabs/win-min.svg").size(16) : "−", () => run("window.minimize")))
        .child(winButton("maximize", w.platform === "windows" ? svg(`mods/tabs/${w.maximized ? "win-restore" : "win-max"}.svg`).size(16) : "□", () => run("window.maximize")))
        .child(winButton("close-window", w.platform === "windows" ? svg("mods/tabs/win-close.svg").size(16) : svg("mods/pane/close.svg").size(13), () => run("window.close"))));
  }
}
