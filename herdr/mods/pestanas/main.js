// Las pestañas de bk-lavanda: una píldora por pestaña del espacio a la vista, con el chip del número fijo de
// su agente (alt+N), lo que hace y la marca de estado (la misma de la barra izquierda y la cabecera).
// A la derecha: + (el menú de Herdr), Archivos y Cambios si están habilitados, y mostrar u ocultar el lado derecho.
// Clon del `tabs` de Herdr 0.1.15: arrastrar para ordenar, doble clic para renombrar, clic derecho para el menú,
// la rueda para pasar de pestaña y el panel recordado por espacio son los suyos.

import { View, div, svg } from "gpui-kit";
import { h_flex, ScrollHandle } from "gpui-base";
import { spaces, panes, terminals, run, openOverlay, theme, window, shared, layout, settings } from "herdr";
import { PROSE, find, ids, said, picto, mark, keycap, iconButton } from "./kit.js";

export default class Pestanas extends View {
  init() {
    this.pressed = null;
    this.scroll = ScrollHandle.new();
    this.panels = JSON.parse(localStorage.getItem("panels") ?? "{}");
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

  render() {
    const t = theme();
    const space = spaces().find((p) => p.active);
    const shown = space?.tabs ?? [];
    const active = shown.findIndex((tab) => tab.active);
    const selected = shown[active]?.id;
    if (selected !== this.selected || active !== this.selectedIndex) {
      this.selected = selected;
      this.selectedIndex = active;
      if (active >= 0) this.scroll.scroll_to_item(active);
    }
    const stop = (_e, cx) => cx.stop_propagation();
    // Una lectura de cada lista por dibujo: cada una copia todo a JS.
    const all = panes();
    const numbers = ids(terminals());
    const lead = new Map();
    for (const p of all) {
      const cur = lead.get(p.tab);
      if (!cur || (!cur.program?.agent && p.program?.agent)) lead.set(p.tab, p);
    }
    const item = (c, i) => {
      const p = lead.get(c.id);
      const program = p?.program;
      const n = p?.terminal ? numbers.get(p.terminal) : null;
      // Los nombres automáticos (chat-3, 2, el del programa) no dicen nada: ahí va lo que el agente dice que hace.
      const auto = !c.named || /^(chat-\d+|\d+|tb\w+)$/.test(c.name) || c.name === program?.name;
      const name = (auto ? said(p?.title, program, p?.terminal) : "") || (/^tb\w+$/.test(c.name) || /^\d+$/.test(c.name) ? program?.name ?? "Terminal" : c.name);
      const pic = n ? null : picto(program, 14, c.active ? t.muted : t.dim);
      const loud = c.status && c.status !== "idle";
      return h_flex().id(`tab-${c.id}`).h(28).pl(n ? 5 : 9).pr(c.active ? 5 : 9).gap(7).rounded(8).items_center().flex_none().text_size(12).cursor_pointer()
        // Un cambio de nombre o de marca en esta pestaña o una anterior puede empujar a la activa afuera.
        .when(i <= active, (el) => el.on_size_change((_size, cx) => { this.scroll.scroll_to_item(active); cx.notify(); }))
        .border_1().border_color(c.active ? t.border : "#00000000").bg(c.active ? t.background : "#00000000").text_color(c.active ? t.foreground : t.muted)
        .when(!c.active, (el) => el.hover((s) => s.bg(t.hover).text_color(t.foreground)))
        .tooltip(c.named && name !== c.name ? `${c.name} · ${name}` : name)
        .on_mouse_down("left", (e, cx) => { cx.stop_propagation(); this.pressed = i; if (e.click_count === 2) run("tab.rename", { id: c.id }); })
        .on_mouse_up("left", () => {
          const from = this.pressed; this.pressed = null;
          if (from !== null && from !== i) run("tab.move", { id: shown[from].id, index: space.tabs.findIndex((x) => x.id === c.id) + 1 });
          else run("tab.select", { id: c.id });
        })
        .on_mouse_down("right", (_e, cx) => { cx.stop_propagation(); openOverlay({ mod: "menu", kind: "popup", width: 200, props: { tab: "tab", target: { id: c.id, space: space.id } } }); })
        .when(Boolean(n), (el) => el.child(keycap(t, n, { on: c.active, size: 18 })))
        .when(Boolean(pic), (el) => el.child(pic))
        .child(div().max_w(c.active ? 240 : 180).truncate().font_family(PROSE).text_size(12.5).when(c.active, (el) => el.font_medium()).child(name))
        .when(c.zoomed, (el) => el.child(svg("mods/pane/zoom.svg").size(11).flex_none().text_color(t.accent)))
        .when(Boolean(loud), (el) => el.child(mark(t, c.status, 12)))
        .when(c.active, (el) => el.child(div().id(`close-${c.id}`).size(18).flex_none().flex().items_center().justify_center().rounded(5).text_color(t.dim)
          .hover((s) => s.bg(t.hover).text_color(t.foreground))
          .on_mouse_down("left", stop).on_click((_e, cx) => { cx.stop_propagation(); run("tab.close", { id: c.id }); })
          .child(svg("mods/pane/close.svg").size(11))));
    };
    const root = layout(), sidebar = find(root, "sidebar"), w = window();
    // Con la barra izquierda oculta o angosta, las pestañas le dejan lugar a los botones de la ventana.
    const lightsPadding = w?.platform === "macos" && w.titlebar === "none" && !w.fullscreen && root?.traffic_lights
      ? Math.max(8, (root.traffic_lights[0] + 66) / (settings().zoom ?? 1) - (sidebar?.hidden ? 0 : sidebar?.size?.px ?? 0))
      : 8;
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
    return h_flex().size_full().min_w(0).pr(8).pl(lightsPadding).gap(2).items_center().bg(t.chrome)
      .on_mouse_up("left", () => { this.pressed = null; })
      .on_scroll_wheel((e) => { if (Math.abs(e.delta.y) >= 1) run(e.delta.y > 0 ? "tab.prev" : "tab.next"); })
      .child(h_flex().id("tab-scroll").flex_1().min_w(0).h_full().items_center().gap(2).overflow_x_scrollbar().track_scroll(this.scroll)
        .on_size_change((_size, cx) => { if (active >= 0) { this.scroll.scroll_to_item(active); cx.notify(); } })
        .children(shown.map(item))
        // El + va después de la última pestaña (los índices de scroll_to_item no cambian: es el último hijo).
        .child(div().flex_none().pl(4).child(iconButton(t, "tab-new", "plus", () => openOverlay({ mod: "new-menu", kind: "popup", width: 250, height: 512 }), { tip: "Pestaña nueva", stop: true }))))
      .when(enabled.includes("files"), (el) => el.child(panelButton("files", "Archivos", "mods/files/file.svg")))
      .when(enabled.includes("changes"), (el) => el.child(panelButton("changes", "Cambios", "mods/changes/changes.svg")))
      .when(Boolean(lado), (el) => el.child(iconButton(t, "lado-toggle", "mods/bk-pestanas/panel.svg", () => run("layout.toggle", { id: "lado" }), { tip: lado?.hidden ? "Mostrar el lado derecho" : "Ocultar el lado derecho", on: !lado?.hidden, stop: true, size: 15 })))
      .when(Boolean(w?.buttons), (el) => el.child(winButton("minimize", w.platform === "windows" ? svg("mods/tabs/win-min.svg").size(16) : "−", () => run("window.minimize")))
        .child(winButton("maximize", w.platform === "windows" ? svg(`mods/tabs/${w.maximized ? "win-restore" : "win-max"}.svg`).size(16) : "□", () => run("window.maximize")))
        .child(winButton("close-window", w.platform === "windows" ? svg("mods/tabs/win-close.svg").size(16) : svg("mods/pane/close.svg").size(13), () => run("window.close"))));
  }
}
