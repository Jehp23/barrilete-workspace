// La cabecera de cada pane de bk-lavanda: el chip con el número fijo de la ventana (alt+N), el icono del
// programa, lo que hace, la carpeta y la rama, y la marca de estado (la misma de la barra izquierda y las
// pestañas). Con el puntero encima: dividir, agrandar y cerrar ese pane. Clic: le da el foco.
// Clon del `pane` de Herdr 0.1.15, con las esquinas de arriba redondeadas como la losa (radius 10 en el layout).

import { View, div, svg } from "gpui-kit";
import { h_flex } from "gpui-base";
import { panes, terminals, props, run, theme, layout } from "herdr";
import { ICONS, PROSE, tilde, said, picto, mark, keycap } from "./kit.js";

// El marco de panes del primer bloque de pestaña visible (también el hijo activo de un stack).
function paneFrame(node) {
  if (!node || node.hidden) return null;
  if (node.content?.tab && node.content.pane) return node.content.pane;
  let children = node.children ?? [];
  if (node.type === "stack") {
    const visible = children.filter((child) => !child.hidden);
    children = [visible.find((child) => child.id === node.active) ?? visible[0]];
  }
  for (const child of children) {
    const frame = paneFrame(child);
    if (frame) return frame;
  }
  return null;
}

export default class Cabecera extends View {
  init() { this.hovered = false; }

  button(t, id, icon, command, args, tip) {
    return div().id(id).size(20).flex_none().flex().items_center().justify_center().rounded(5).text_color(t.dim).cursor_pointer()
      .hover((s) => s.bg(t.hover).text_color(t.foreground))
      .tooltip(tip)
      .on_click((_e, cx) => { cx.stop_propagation(); run(command, args); })
      .child(svg(`mods/pane/${icon}.svg`).size(13));
  }

  render() {
    const t = theme();
    const pane = props()?.pane;
    const all = panes();
    const p = all.find((x) => x.pane === pane);
    if (!p) return div();
    const n = p.terminal ? terminals().find((x) => x.address === p.terminal)?.labels?.["bk.id"] : null;
    const prog = ((p.program?.agent || p.program?.shell) && p.program.name) || p.program?.name || "shell";
    // Sola en su pestaña, la pestaña ya dice qué hace: la cabecera dice quién y dónde. En un split, cada una lo suyo.
    const alone = all.filter((x) => x.tab === p.tab).length < 2;
    const topic = p.mod ? p.title : alone ? "" : said(p.title, p.program, p.terminal);
    const frame = paneFrame(layout());
    const bottom = frame?.header?.position === "bottom";
    const r = Math.max(0, (frame?.radius ?? 10) - 1);
    const st = p.status;
    return h_flex().id(`pane-head-${pane}`).size_full().pl(n ? 6 : 10).pr(8).gap(8).items_center().bg(t.background).text_size(12)
      .when(bottom, (el) => el.border_t(1).rounded_b(r))
      .when(!bottom, (el) => el.border_b(1).rounded_t(r))
      .border_color(t.border)
      .on_hover((hovered, cx) => { this.hovered = hovered; cx.notify(); })
      .on_click(() => run("pane.focus", { pane }))
      .when(Boolean(n), (el) => el.child(keycap(t, n, { on: p.focused, size: 18 })))
      .when(Boolean(picto(p.program, 14, t.dim)), (el) => el.child(picto(p.program, 14, p.focused ? t.muted : t.dim)))
      .child(div().flex_shrink(1).min_w(0).truncate().font_family(PROSE).text_size(12.5).font_medium().text_color(p.focused ? t.foreground : t.muted).child(topic || prog))
      .when(Boolean(topic) && !p.mod, (el) => el.child(div().flex_none().text_color(t.dim).child(prog)))
      .child(h_flex().flex_1().min_w(0).gap(8).items_center().justify_end().text_size(11).text_color(t.dim)
        .when(Boolean(p.cwd), (el) => el.child(div().flex_shrink(1).min_w(0).text_ellipsis_start().child(tilde(p.cwd))))
        .when(Boolean(p.branch), (el) => el.child(h_flex().flex_none().max_w(200).gap(4).items_center()
          .child(svg(ICONS + "git-branch.svg").size(11).flex_none())
          .child(div().truncate().child(p.branch ?? "")))))
      .when(p.zoomed, (el) => el.child(svg("mods/pane/zoom.svg").size(11).flex_none().text_color(t.accent)))
      .when(Boolean(st) && st !== "idle", (el) => el.child(mark(t, st)))
      .when(this.hovered, (el) => el.child(h_flex().flex_none().gap(1)
        .child(this.button(t, `ph-r-${pane}`, "split-right", "pane.split", { direction: "right", pane }, "Dividir a la derecha"))
        .child(this.button(t, `ph-d-${pane}`, "split-down", "pane.split", { direction: "down", pane }, "Dividir abajo"))
        .child(this.button(t, `ph-z-${pane}`, p.zoomed ? "unzoom" : "zoom", "pane.zoom", { pane }, p.zoomed ? "Volver al tamaño" : "Agrandar"))
        .child(this.button(t, `ph-x-${pane}`, "close", "pane.close", { pane }, "Cerrar el pane"))));
  }
}
