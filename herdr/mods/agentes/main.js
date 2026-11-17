// La barra izquierda de bk-lavanda: los espacios y, debajo, los agentes con sus sub-agentes (quién lanzó a
// quién). Cada agente lleva el chip con su número fijo de ventana (alt+N), su título, dónde está y la marca
// de estado, la misma que usan las pestañas, la cabecera de cada pane y la barra de abajo.
// Dos vistas (el botón de la derecha de "AGENTES"): por prioridad (te esperan, listos, trabajando, quietos)
// o por espacio. Angosta (riel), solo los chips con su marca.
// Nació como clon del `agents` de Herdr 0.1.15: el orden, los pins y el árbol de sub-agentes son los suyos.

import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { agents, terminals, focused, panes, spaces, run, theme, shared, setShared, setAgentOrder, openOverlay, closeOverlay, props, window, layout, exec, home } from "herdr";
import { ICONS, PROSE, RANK, al, find, narrow, ago, ids, said, picto, mark, keycap, iconButton, rule } from "./kit.js";

const SUBS_EVERY = 4000;
const EPIC_EVERY = 60000;   // bk _epica guarda lo de GitHub unos minutos: esto solo vuelve a leer su caché
const bin = () => shared("bk.bin") || "bk";

// Al riel (en macOS, con lugar para los botones de la ventana) o de vuelta al ancho que tenía.
function toggleSidebar() {
  const width = find(layout(), "sidebar")?.size?.px;
  if (!narrow()) setShared("sidebar.width", width);
  setShared("sidebar.collapsed", !narrow());
  run("layout.resize", { id: "sidebar", px: narrow() ? (shared("sidebar.width") ?? 288) : window()?.platform === "macos" ? 76 : 44 });
}

// Un sub-agente sin pane no está en agents(): su palabra cruda, con error como "te espera". Nunca "listo":
// le rinde a su padre, y la novedad es el listo del padre.
const kidStatus = (k, listed) => {
  const s = listed.get(k.address) ?? k.status;
  return s === "error" ? "blocked" : s === "done" ? "idle" : s;
};
const SORTS = [
  { id: "priority", label: "Por prioridad", icon: "clock" },
  { id: "grouped", label: "Por espacio", icon: "layers" },
];
const sortOf = () => SORTS.find((s) => s.id === shared("agents.sort")) ?? SORTS[0];
const SECTION = { 4: "Te esperan", 3: "Listos", 2: "Trabajando", 1: "Quietos" };
const SECTION_STATUS = { 4: "blocked", 3: "done", 2: "working" };
// El color de cada espacio: el que eligió Herdr (shared "space.colors", un nombre del tema) o uno fijo por su id.
const TINTS = ["ansi4", "ansi5", "ansi6", "ansi13", "ansi3", "ansi2"];
const hash = (s) => { let h = 0; for (const ch of String(s)) h = (h * 31 + ch.charCodeAt(0)) >>> 0; return h; };
// El menú del clic derecho de bk (mods/bk-menu): ancho para el texto y las teclas, del alto justo
// (alto: 6 px arriba y abajo, 32 por opción y 9 por raya; el de un espacio cuenta los tres de worktree)
// El alto de bk-menu para el más largo de cada tipo (tests/test_herdr_mods.sh lo compara con height() de bk-menu)
const MENU_H = { space: 12 + 5 * 32 + 9, pane: 12 + 6 * 32 + 2 * 9 };
const menu = (tab, target) => openOverlay({ mod: "bk-menu", kind: "popup", width: 300, height: MENU_H[tab], props: { tab, target } });
// De qué chat sale la épica: la carpeta y la rama del pane enfocado, y el nombre del chat (#123 en bk.name o
// bk.autotitle) por si la rama no dice el issue. bk _epica (lib/herdr_epica.py) saca de ahí el issue y su épica.
function epicQuery() {
  const f = focused();
  if (!f?.terminal) return null;
  const p = panes().find((x) => x.pane === f.pane) ?? {};
  const l = terminals().find((x) => x.address === f.terminal)?.labels ?? {};
  return [p.cwd ?? f.cwd ?? "", p.branch ?? "", [l["bk.name"], l["bk.autotitle"], p.title].filter(Boolean).join(" ")];
}
const BAR = 10;
const bar = (done, total) => { const n = total ? Math.round((BAR * done) / total) : 0; return "▓".repeat(n) + "░".repeat(BAR - n); };

// La marca de un sub-agente. tests/test_herdr_subagents.sh evalúa tree() y subRow() de este archivo sin sus
// imports (solo les pasa View, div, svg, h_flex, v_flex, agents, run y home): por eso subRow no usa del kit
// nada más que esto, y sin kit dibuja un hueco.
const subMark = (t, st) => (typeof mark === "function" ? mark(t, st, 12) : div());

export default class Agents extends View {
  init(_props, cx) {
    if (props()?.sortMenu) return;
    this.folded = new Set();
    this.openPrev = new Set();   // las líneas «antes» desplegadas (plegadas por defecto)
    this.claudeSubs = {};
    this.subsRaw = "";
    this.subError = null;
    const refresh = async (cx) => {
      if (this.subBusy) return;
      this.subBusy = true;
      let changed = false;
      try {
        const r = await exec(bin(), ["_subagents"], { timeout: 8000 });
        if (r.code !== 0) throw new Error(r.stderr.trim() || "bk _subagents no respondió");
        if (r.stdout !== this.subsRaw) {
          this.claudeSubs = JSON.parse(r.stdout).by_terminal ?? {};
          this.subsRaw = r.stdout;
          changed = true;
        }
        if (this.subError) changed = true;
        this.subError = null;
      } catch (e) {
        const msg = String(e?.message ?? e);
        changed = msg !== this.subError;
        this.subError = msg;
      } finally { this.subBusy = false; }
      // Solo se redibuja si cambió algo: cada dibujo de un mod repinta la ventana entera.
      if (changed) cx.notify();
    };
    cx.spawn(refresh);
    cx.timer.every(SUBS_EVERY, (cx) => cx.spawn(refresh));
    // La épica del chat enfocado. Si ese chat no tiene, queda la última vista (en gris): guardada entre reinicios.
    this.epic = null;
    this.lastEpic = JSON.parse(localStorage.getItem("epic") ?? "null");
    this.epicKey = null;
    this.epicAt = 0;
    cx.timer.every(EPIC_EVERY, (cx) => { this.epicAt = 0; cx.notify(); });
    // El último estado de cada agente y cuándo cambió (ms), guardado entre reinicios.
    this.changed = JSON.parse(localStorage.getItem("changed") ?? "{}");
    this.pendingPins = JSON.parse(localStorage.getItem("pins") ?? "[]");
    if (!this.pendingPins.length) localStorage.removeItem("pins");
    this.migratingPins = new Set();
    cx.timer.every(30000, (cx) => cx.notify());   // los "hace 12m"
  }

  // Anota los agentes que cambiaron de estado. Listo y quieto cuentan como uno: mirar a uno que terminó lo
  // pasa de listo a quieto, y mirar no es que el agente haya hecho algo.
  track(list, now) {
    let dirty = false;
    for (const a of list) {
      const s = a.status === "done" ? "idle" : a.status;
      if (this.changed[a.address]?.s === s) continue;
      this.changed[a.address] = { s, at: now };
      dirty = true;
    }
    if (!dirty) return;
    const listed = new Set(list.map((a) => a.address));
    for (const [k, c] of Object.entries(this.changed)) if (!listed.has(k) && now - c.at > 30 * 86400000) delete this.changed[k];
    localStorage.setItem("changed", JSON.stringify(this.changed));
  }

  // Los pins de la versión vieja (guardados acá) pasan a la etiqueta de su terminal cuando vuelve.
  migratePins(all) {
    if (!this.pendingPins.length) return;
    const listed = new Map(all.filter((t) => t.state === "live").map((t) => [t.address, t]));
    const pending = this.pendingPins.filter((address) => {
      const terminal = listed.get(address);
      if (!terminal) return true;
      if (terminal.labels?.["herdr.pinned"]) return false;
      if (!this.migratingPins.has(address)) {
        this.migratingPins.add(address);
        run("terminal.pin", { terminal: address, pinned: true });
      }
      return true;
    });
    if (pending.length === this.pendingPins.length) return;
    this.pendingPins = pending;
    if (pending.length) localStorage.setItem("pins", JSON.stringify(pending));
    else localStorage.removeItem("pins");
  }

  since(a) {
    return this.changed[a.address]?.at ?? 0;
  }

  // Los chats que siguieron en otro por un handoff (etiqueta bk.from del nuevo, lib/herdr.sh): el mismo trabajo
  // en una sola fila. Devuelve { prev: nuevo → viejo, hidden: los viejos que van debajo de su nuevo }. Un viejo
  // fijado conserva su fila; si dos chats dicen venir del mismo, lo toma el primero de la lista; una cadena
  // que vuelve sobre sí misma (no debería pasar) se corta.
  lineage(list, labelsOf) {
    const live = new Map(list.map((a) => [a.address, a]));
    const prev = new Map();
    const taken = new Set();
    for (const a of list) {
      const from = labelsOf.get(a.address)?.["bk.from"];
      const old = from ? live.get(from) : null;   // uno que dice venir de sí mismo es una vuelta: se corta abajo
      if (!old || old.pinned || taken.has(from)) continue;
      let p = from, loop = false;
      while (p && !loop) { loop = p === a.address; p = prev.get(p); }
      if (loop) continue;
      prev.set(a.address, from);
      taken.add(from);
    }
    return { prev, hidden: taken };
  }

  // Pide la épica si cambió el chat enfocado o pasó EPIC_EVERY; uno a la vez. Llamado al dibujar.
  epicRefresh(cx) {
    const q = epicQuery();
    const key = JSON.stringify(q);
    if (this.epicBusy || (key === this.epicKey && Date.now() - this.epicAt < EPIC_EVERY)) return;
    this.epicBusy = true;
    this.epicKey = key;
    this.epicAt = Date.now();
    cx.spawn(async (cx) => {
      try {
        if (!q) { this.epic = null; return; }
        const r = await exec(bin(), ["_epica", ...q], { timeout: 20000 });
        // La del chat anterior queda hasta la respuesta (sin parpadeo); si bk falla, no se sabe: va la última, en gris
        const e = r.code === 0 ? JSON.parse(r.stdout).epic ?? null : null;
        if (e && JSON.stringify(e) !== JSON.stringify(this.lastEpic)) {
          this.lastEpic = e;
          localStorage.setItem("epic", JSON.stringify(e));
        }
        this.epic = e;
      } catch { this.epic = null; } finally {
        this.epicBusy = false;
        // Si el foco cambió mientras preguntaba, la próxima vuelta pide el nuevo.
        cx.notify();
      }
    });
  }

  // ÉPICA #N título ▓▓▓▓░░ 5/7, de la épica del chat enfocado; si no tiene, la última vista, en gris. Clic: en GitHub.
  epicBlock(t) {
    const e = this.epic ?? this.lastEpic;
    if (!e) return null;
    const stale = !this.epic;
    const ink = stale ? t.dim : t.foreground;
    return h_flex().id("epic").h(26).flex_none().pl(8).pr(8).gap(7).rounded(6).items_center().text_size(11.5).cursor_pointer()
      .hover((x) => x.bg(t.hover))
      .tooltip(`${e.repo}#${e.number} ${e.title}${stale ? " · la última vista: este chat no tiene épica" : ""}`)
      .on_click(() => exec("open", [`https://github.com/${e.repo}/issues/${e.number}`]))
      .child(div().flex_none().text_size(10.5).font_semibold().text_color(stale ? t.dim : t.accent).child("ÉPICA"))
      .child(div().flex_1().min_w(0).truncate().text_color(ink).child(`#${e.number} ${e.title}`))
      .child(div().flex_none().text_size(9).text_color(stale ? t.dim : e.total && e.done >= e.total ? t.done : t.accent).child(bar(e.done, e.total)))
      .child(div().flex_none().text_color(t.dim).child(`${e.done}/${e.total}`));
  }

  sortMenu(t) {
    const on = sortOf().id;
    return v_flex().w_full().p(5).bg(t.popover).text_size(12.5)
      .child(div().px(8).pt(4).pb(6).text_size(10.5).font_semibold().text_color(t.accent).child("ORDENAR AGENTES"))
      .children(SORTS.map((s) => h_flex().id(`sort-${s.id}`).h(30).px(8).gap(9).rounded(6).items_center().text_color(t.foreground)
        .hover((el) => el.bg(t.hover))
        .on_click(() => { setShared("agents.sort", s.id); closeOverlay(props().overlay); })
        .child(svg(`${ICONS}${s.icon}.svg`).size(14).flex_none().text_color(t.muted))
        .child(div().flex_1().child(s.label))
        .when(s.id === on, (el) => el.child(svg(`${ICONS}check.svg`).size(14).flex_none().text_color(t.accent)))));
  }

  // Los sub-agentes vivos de `addr`, en profundidad, cada uno con las líneas del árbol delante.
  tree(all, addr, lead = []) {
    const kids = all.filter((k) => k.parent === addr && k.state === "live");
    return kids.flatMap((k, i) => {
      const last = i === kids.length - 1;
      return [
        { t: k, lines: [...lead, last ? "└" : "├"] },
        ...this.tree(all, k.address, [...lead, last ? "" : "│"]),
      ];
    });
  }

  subRow(t, s, shown) {
    const k = s.t;
    const st = kidStatus(k, this.listed);
    const on = k.address === shown;
    return h_flex().id(`sub-${k.address}`).pl(19).pr(8).h(24).flex_none().rounded(6).items_center().text_size(11.5).cursor_pointer()
      .when(on, (el) => el.bg(t.selected))
      .hover((x) => x.bg(t.hover))
      .on_click(() => {
        if (k.transcript) {
          const parent = agents().find((a) => a.address === k.parent);
          if (parent) run("space.select", { id: parent.space });
          run("tab.new", { ...(parent ? { space: parent.space } : {}), name: k.name.split(" · ")[0], folder: home(), argv: ["bk", "sub", k.transcript] });
        } else if (this.listed.has(k.address)) run("pane.focus", { terminal: k.address });
        else run("terminal.peek", { terminal: k.address });
      })
      .tooltip(k.transcript ? `${k.name}${k.background ? " · segundo plano" : ""} · clic para seguirlo en vivo` : k.name || k.address)
      .children(s.lines.map((l, i) => div().self_start().mt(-3).w(i === s.lines.length - 1 ? 14 : 10).h(15).mr(i === s.lines.length - 1 ? 7 : 4).flex_none()
        .when(Boolean(l), (el) => el.border_l(1).border_color(t.input))
        .when(l === "└" || l === "├", (el) => el.border_b(1).rounded_bl(5))))
      .child(div().flex_1().min_w(0).truncate().text_color(on ? t.foreground : t.muted).child(k.name || k.template || k.program?.name || k.address))
      .when(Boolean(k.background), (el) => el.child(div().flex_none().ml(6).text_size(10.5).text_color(t.dim).child("2º")))
      .child(div().ml(6).child(subMark(t, st)));
  }

  // Los espacios: color y letra, nombre, la rama si no es la de siempre, y la marca si algo ahí te necesita.
  spaceRow(t, s, collapsed) {
    const name = (shared("space.colors") ?? {})[s.id];
    const color = (name?.startsWith?.("#") ? name : t[name]) ?? t[TINTS[hash(s.id) % TINTS.length]] ?? t.accent;
    const loud = s.status && s.status !== "idle";
    const tile = div().size(collapsed ? 22 : 18).flex_none().rounded(collapsed ? 6 : 5).bg(al(color, s.active ? "40" : "26")).flex().items_center().justify_center()
      .text_size(collapsed ? 11.5 : 10.5).line_height(1).font_bold().text_color(color).child([...s.name][0]?.toUpperCase() ?? "?");
    const act = (el) => el.cursor_pointer()
      .on_click(() => run("space.select", { id: s.id }))
      .on_mouse_down("right", (_e, cx) => { cx.stop_propagation(); menu("space", { id: s.id }); });
    if (collapsed) {
      return act(h_flex().id(`sp-${s.id}`).relative().h(30).flex_none().justify_center().items_center().tooltip(s.name)
        .child(div().p(3).rounded(8).when(s.active, (el) => el.bg(t.selected)).child(tile))
        .when(loud, (el) => el.child(div().absolute().top(0).right(15).rounded_full().bg(t.chrome).child(mark(t, s.status, 12)))));
    }
    const usual = !s.branch || s.branch === "main" || s.branch === "master" || s.branch.toLowerCase() === s.name.toLowerCase();
    return act(h_flex().id(`sp-${s.id}`).h(28).px(8).gap(9).flex_none().rounded(8).items_center()
      .when(s.active, (el) => el.bg(t.selected))
      .when(!s.active, (el) => el.hover((x) => x.bg(t.hover)))
      .child(tile)
      .child(div().flex_shrink(0).max_w(usual ? 190 : 130).truncate().text_color(s.active ? t.foreground : t.muted).when(s.active, (el) => el.font_medium()).child(s.name))
      .when(Boolean(s.machine), (el) => el.child(div().flex_none().text_size(10.5).text_color(t.dim).child(`@${s.machine}`)))
      .child(div().flex_1().min_w(0).truncate().text_right().text_size(11).text_color(t.dim).child(usual ? "" : s.branch))
      .when(loud, (el) => el.child(mark(t, s.status, 12))));
  }

  render(cx) {
    const t = theme();
    if (props()?.sortMenu) return this.sortMenu(t);
    const collapsed = narrow();
    const sort = sortOf();
    let list = agents();
    this.listed = new Map(list.map((a) => [a.address, a.status]));
    const native = terminals();
    const numbers = ids(native);
    const internal = Object.entries(this.claudeSubs).flatMap(([parent, children]) =>
      children.map((child) => ({
        address: `claude:${parent}:${child.id}`, parent, state: "live", status: "working",
        name: `${child.number}. ${child.type === "general-purpose" ? "general" : child.type} · ${child.description}`,
        transcript: child.path, background: child.background,
      })));
    const all = [...native, ...internal];
    this.migratePins(all);
    const shown = focused()?.agent;
    const now = Date.now();
    this.track(list, now);
    // Un sub-agente con pane también está en agents(): donde un árbol lo muestra no lleva fila propia, salvo fijado.
    const nested = new Set(collapsed ? [] : list.flatMap((a) => this.tree(all, a.address).map((s) => s.t.address)));
    list = list.filter((a) => a.pinned || !nested.has(a.address));
    const labelsOf = new Map(native.map((x) => [x.address, x.labels ?? {}]));
    const byAddress = new Map(list.map((a) => [a.address, a]));
    // Un chat que siguió en otro (handoff) va debajo del nuevo, en la línea «antes»; en el riel no hay dónde
    const { prev, hidden } = collapsed ? { prev: new Map(), hidden: new Set() } : this.lineage(list, labelsOf);
    const tabCounts = new Map();
    for (const a of list) tabCounts.set(a.tab, (tabCounts.get(a.tab) ?? 0) + 1);
    const byPriority = sort.id === "priority";
    const urgency = new Map(list.map((a) => [a.address, Math.max(RANK[a.status] ?? 0, ...this.tree(all, a.address).map((s) => RANK[kidStatus(s.t, this.listed)] ?? 0))]));
    // Lo que te necesita en un chat viejo sube con su nuevo: la fila se ordena por lo más urgente de la cadena
    const chained = (addr, seen = new Set()) => {
      const old = prev.get(addr);
      if (!old || seen.has(old)) return urgency.get(addr) ?? 0;
      seen.add(old);
      return Math.max(urgency.get(addr) ?? 0, chained(old, seen));
    };
    for (const a of list) if (prev.has(a.address)) urgency.set(a.address, chained(a.address));
    list = list.filter((a) => !hidden.has(a.address));
    const rankOf = (a) => urgency.get(a.address);
    if (byPriority) list = [...list].sort((x, y) => rankOf(y) - rankOf(x) || this.since(y) - this.since(x) || y.seq - x.seq);
    const pinned = list.filter((a) => a.pinned);
    const rest = list.filter((a) => !a.pinned);
    list = [...pinned, ...rest];
    setAgentOrder(list.map((a) => a.address));

    const sp = spaces();
    const tabs = new Map(sp.flatMap((s) => s.tabs).map((tab) => [tab.id, tab]));
    // El título de la fila: lo que el agente dice que hace. Una pestaña que alguien nombró a mano gana; los
    // nombres automáticos (chat-3, 2, el del programa) no dicen nada y van a la segunda línea.
    const titleOf = (a) => {
      const tab = tabs.get(a.tab);
      const own = said(a.title, a.program, a.address);
      const auto = !tab?.named || /^(chat-\d+|\d+)$/.test(tab.name) || tab.name === a.program?.name || tabCounts.get(a.tab) > 1;
      return (auto ? own : "") || (tab?.named ? tab.name : "") || own || a.program?.name || a.address;
    };
    const metaOf = (a, title, full) => {
      // En qué quedó el chat (lib/names.py, etiqueta bk.status) dice más que chat-3 o el nombre del programa
      const status = labelsOf.get(a.address)?.["bk.status"];
      if (status) return [full ? a.space_name : null, status].filter(Boolean).join(" · ");
      const tab = tabs.get(a.tab);
      const machine = a.address.includes("/") ? a.address.split("/")[0] : null;
      const tabName = tab?.named && tab.name !== title ? tab.name : null;
      return [machine, full ? a.space_name : null, tabName ?? (a.program?.name !== title ? a.program?.name : null)].filter(Boolean).join(" · ");
    };

    // El chevron que pliega los sub-agentes; plegado, cuántos son, con el color del más urgente.
    const fold = (a, subs) => {
      const sts = subs.map((s) => kidStatus(s.t, this.listed));
      const top = sts.reduce((m, s) => ((RANK[s] ?? 0) > (RANK[m] ?? 0) ? s : m), null);
      const open = !this.folded.has(a.address);
      return div().id(`fold-${a.address}`).h(16).px(2).gap(2).flex().flex_none().items_center().rounded(4).text_size(10.5)
        .text_color(open ? t.dim : (t[top] ?? t.dim)).cursor_pointer()
        .hover((s) => s.bg(t.hover).text_color(t.foreground))
        .on_click((_e, cx) => {
          cx.stop_propagation();
          open ? this.folded.add(a.address) : this.folded.delete(a.address);
          cx.notify();
        })
        .child(svg(`${ICONS}chevron-${open ? "down" : "right"}.svg`).size(11).flex_none())
        .when(!open, (el) => el.child(String(subs.length)));
    };

    const row = (a, subs = []) => {
      const n = numbers.get(a.address);
      if (collapsed) {
        // El riel: el chip con su número y, en la esquina, la marca si no está quieto.
        return h_flex().id(`ag-${a.address}`).relative().h(30).flex_none().justify_center().items_center().cursor_pointer()
          .tooltip(titleOf(a))
          .on_click(() => run("pane.focus", { pane: a.pane }))
          .child(div().p(3).rounded(8).when(a.focused, (el) => el.bg(t.selected)).child(keycap(t, n, { on: a.focused })))
          .when(a.status !== "idle", (el) => el.child(div().absolute().top(0).right(15).rounded_full().bg(t.chrome).child(mark(t, a.status, 12))));
      }
      const when = this.since(a);
      const isPinned = a.pinned;
      const full = byPriority || isPinned;   // sin un rótulo de espacio arriba, la fila dice el suyo
      const title = titleOf(a);
      const meta = metaOf(a, title, full);
      const quiet = a.status === "idle" && !a.focused;
      const pic = picto(a.program, 12, t.dim);
      const pin = div().id(`pin-${a.address}`).flex_none().p(1).rounded(4).text_color(t.dim).cursor_pointer()
        .hover((s) => s.bg(t.hover).text_color(t.foreground))
        .tooltip(isPinned ? "Soltar" : "Fijar arriba")
        .on_click((_e, cx) => {
          cx.stop_propagation();
          run("terminal.pin", { terminal: a.address, pinned: !isPinned });
          this.hovered = null;   // la fila se va de abajo del puntero y no llega el aviso de salida
          cx.notify();
        })
        .child(svg(`${ICONS}${isPinned ? "pin-off" : "pin"}.svg`).size(12));
      const timeColor = a.status === "blocked" ? t.blocked : a.status === "working" ? t.working : t.dim;
      const waits = a.status === "blocked";
      // La que te espera es una tarjeta con borde ámbar: se encuentra sin leer.
      return h_flex().id(`ag-${a.address}`).px(7).h(44).flex_none().rounded(8).items_center().gap(10).cursor_pointer()
        .border_1().border_color(waits ? al(t.blocked, "59") : "#00000000")
        .when(a.focused, (el) => el.bg(t.selected))
        .when(!a.focused && waits, (el) => el.bg(al(t.blocked, "14")))
        .hover((s) => s.bg(a.focused ? t.selected : waits ? al(t.blocked, "22") : t.hover))
        .on_hover((on, cx) => {
          if (on) this.hovered = a.address;
          else if (this.hovered === a.address) this.hovered = null;
          cx.notify();
        })
        .on_click(() => run("pane.focus", { pane: a.pane }))
        // Doble clic: renombrar, igual que «Renombrar» del clic derecho (el nombre a mano manda sobre el automático)
        .on_mouse_down("left", (e) => { if (e.click_count === 2 && a.tab) run("tab.rename", { id: a.tab }); })
        .on_mouse_down("right", (_e, cx) => { cx.stop_propagation(); menu("pane", { pane: a.pane, terminal: a.address }); })
        .child(keycap(t, n, { on: a.focused }))
        .child(v_flex().flex_1().min_w(0).gap(3)
          .child(h_flex().gap(6).items_center()
            .child(div().flex_1().min_w(0).truncate().font_family(PROSE).text_size(13).line_height(1.25).font_medium().text_color(quiet ? t.muted : t.foreground).child(title))
            .when(subs.length > 0, (el) => el.child(fold(a, subs)))
            .child(mark(t, a.status)))
          .child(h_flex().gap(5).items_center().text_size(11).line_height(1.25).text_color(t.dim)
            .when(Boolean(pic), (el) => el.child(pic))
            .child(div().flex_1().min_w(0).truncate().child(meta))
            .when(this.hovered === a.address, (el) => el.child(pin))
            .when(this.hovered !== a.address && isPinned, (el) => el.child(svg(`${ICONS}pin.svg`).size(11).flex_none()))
            .when(this.hovered !== a.address && Boolean(when), (el) => el.child(div().flex_none().min_w(28).whitespace_nowrap().text_right().text_color(timeColor).child(ago(now - when))))));
    };

    // La línea «antes»: el chat del que este siguió (handoff), plegado. Desplegado muestra su fila entera, con
    // sus sub-agentes y su propio «antes». Plegado igual avisa si algo ahí te espera o sigue trabajando.
    const prevLine = (old, depth) => {
      const open = this.openPrev.has(old.address);
      const top = SECTION_STATUS[urgency.get(old.address)];
      const loud = top === "blocked" || top === "working";
      const head = h_flex().id(`prev-${old.address}`).pl(19).pr(8).h(24).flex_none().gap(5).rounded(6).items_center().text_size(11.5).cursor_pointer()
        .hover((x) => x.bg(t.hover))
        .tooltip(open ? "Plegar el chat anterior" : "El chat del que este siguió (handoff): clic para verlo")
        .on_click((_e, cx) => {
          open ? this.openPrev.delete(old.address) : this.openPrev.add(old.address);
          cx.notify();
        })
        .child(svg(`${ICONS}chevron-${open ? "down" : "right"}.svg`).size(11).flex_none().text_color(t.dim))
        .child(div().flex_1().min_w(0).truncate().text_color(t.dim).child(`antes: ${titleOf(old)}`))
        .when(loud, (el) => el.child(mark(t, top, 12)))
        .child(div().id(`prev-x-${old.address}`).flex_none().p(1).rounded(4).text_color(t.dim).cursor_pointer()
          .hover((s) => s.bg(t.hover).text_color(t.foreground))
          .tooltip("Cerrar el chat anterior")
          .on_click((_e, cx) => { cx.stop_propagation(); run("tab.close", { id: old.tab }); })
          .child(svg(`${ICONS}x.svg`).size(11)));
      if (!open) return [head];
      return [head, v_flex().pl(14).gap(1).children(withKids(old, depth + 1))];
    };

    const withKids = (a, depth = 0) => {
      const subs = collapsed ? [] : this.tree(all, a.address);
      const r = row(a, subs);
      const old = depth < 8 ? byAddress.get(prev.get(a.address)) : null;
      const before = old ? prevLine(old, depth) : [];
      if (this.folded.has(a.address)) return [r, ...before];
      return [r, ...subs.map((s) => this.subRow(t, s, shown)), ...before];
    };

    // Los grupos, en el orden de la lista: secciones por prioridad o espacios. Los agentes de un espacio
    // vienen juntos en agents(), así que los vecinos arman el grupo.
    const groups = pinned.length ? [{ id: "pinned", label: "Fijados", status: null, members: pinned }] : [];
    for (const a of rest) {
      const r = rankOf(a) || RANK.idle;
      const id = byPriority ? `sec-${r}` : `sp-${a.space}`;
      if (groups.at(-1)?.id === id) groups.at(-1).members.push(a);
      else groups.push({ id, label: byPriority ? SECTION[r] : a.space_name || "", status: byPriority ? SECTION_STATUS[r] : null, members: [a] });
    }

    // El rótulo de un grupo; lo pliega. Plegado dice cuántos son y el estado más urgente.
    const header = (g, first) => {
      const open = !this.folded.has(g.id);
      const top = g.members.reduce((m, a) => ((RANK[a.status] ?? 0) > (RANK[m] ?? 0) ? a.status : m), null);
      return h_flex().id(`g-${g.id}`).px(8).h(first ? 22 : 30).pt(first ? 0 : 8).flex_none().gap(6).items_center().text_size(11).cursor_pointer()
        .hover((s) => s.text_color(t.foreground))
        .on_click((_e, cx) => {
          open ? this.folded.add(g.id) : this.folded.delete(g.id);
          cx.notify();
        })
        .child(div().flex_shrink(1).min_w(0).truncate().font_medium().text_color(t[g.status] ?? t.muted).child(g.label))
        .child(div().flex_none().text_color(t.dim).child(String(g.members.length)))
        .child(div().flex_1())
        .when(!open, (el) => el
          .when(!byPriority && top && top !== "idle", (x) => x.child(mark(t, top, 12)))
          .child(svg(`${ICONS}chevron-right.svg`).size(11).flex_none().text_color(t.dim)));
    };
    const rows = collapsed
      ? list.flatMap(withKids)
      : groups.flatMap((g, i) => [header(g, i === 0), ...(this.folded.has(g.id) ? [] : g.members.flatMap(withKids))]);

    if (collapsed) {
      return v_flex().size_full().min_h(0).bg(t.chrome).pt(4)
        .child(v_flex().flex_none().max_h(200).overflow_hidden().children(sp.map((s) => this.spaceRow(t, s, true))))
        .child(div().flex_none().mx(22).my(6).h(1).bg(t.border))
        .child(v_flex().id("ag-list").flex_1().min_h(0).overflow_y_scrollbar().children(rows))
        .child(h_flex().h(30).flex_none().items_center().justify_center()
          .child(iconButton(t, "collapse", "sidebar", toggleSidebar, { tip: "Abrir la barra", size: 15 })));
    }
    this.epicRefresh(cx);
    const epic = this.epicBlock(t);
    return v_flex().size_full().min_h(0).bg(t.chrome).pl(8).pr(4).pt(8).text_size(12.5)
      .child(rule(t, "ESPACIOS", [iconButton(t, "space-new", "plus", () => run("space.new"), { tip: "Espacio nuevo" })]))
      // Hasta ocho espacios, la lista mide lo que ocupa; con más, se desplaza dentro de ese alto.
      .child((sp.length > 8 ? v_flex().id("sp-list").h(8 * 29).overflow_y_scrollbar() : v_flex().id("sp-list")).flex_none().gap(1).pr(4).children(sp.map((s) => this.spaceRow(t, s, false))))
      .child(div().h(6).flex_none())
      .when(Boolean(epic), (el) => el.child(epic).child(div().h(2).flex_none()))
      .child(rule(t, "AGENTES", [
        iconButton(t, "ag-sort", sort.icon, () => openOverlay({ mod: "bk-agentes", kind: "popup", width: 200, height: 110, props: { sortMenu: true } }), { tip: `Orden: ${sort.label.toLowerCase()}` }),
      ]))
      .when(list.length === 0, (el) => el.child(div().px(8).pt(2).text_size(11.5).text_color(t.dim).child("Todavía no hay agentes. Aparecen acá cuando avisan su estado.")))
      .when(Boolean(this.subError), (el) => el.child(div().px(8).pb(4).text_size(11).text_color(t.blocked).tooltip(this.subError || "").child("No pude leer los sub-agentes de Claude")))
      .child(v_flex().id("ag-list").flex_1().min_h(0).pr(4).pb(8).gap(1).overflow_y_scrollbar().children(rows));
  }
}
