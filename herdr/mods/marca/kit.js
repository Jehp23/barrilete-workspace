// Piezas de dibujo de bk-lavanda: la marca de estado, el chip con el número de ventana, el rótulo sobre una
// línea y la tarjeta con título en el marco. Una sola versión de cada una para que la barra izquierda, las
// pestañas, la cabecera de cada pane y el lado derecho se vean de una pieza.
// Va igual en agentes, pestanas, cabecera, lado y marca (un mod de Herdr no puede importar de otra carpeta):
// si lo cambiás, copialo a las demás.

import { div, svg, image } from "gpui-kit";
import { h_flex, v_flex } from "gpui-base";
import { layout, terminals, home } from "herdr";

export const ICONS = "mods/workspace-chrome/";
// La interfaz va en la fuente de la terminal (ui_font del layout). Solo la prosa que se corta (lo que hace un
// agente, el título de un PR) va en Geist, que viene con Herdr y entra un tercio más de texto en el mismo ancho.
export const PROSE = "Geist";
// background: el turno terminó pero dejó comandos corriendo (tests, CI); lo marca bk, no Herdr (mods/agentes).
export const RANK = { blocked: 4, done: 3, working: 2, background: 1.5, idle: 1 };
export const WORD = { blocked: "te espera", done: "listo", working: "trabajando", background: "en 2º plano", idle: "quieto" };

// Un color del tema con transparencia ("22"); uno que ya la trae queda como está.
export const al = (c, a) => (/^#[0-9a-fA-F]{6}$/.test(c ?? "") ? c + a : c ?? "#00000000");

export function find(node, id) {
  if (node?.id === id) return node;
  for (const child of node?.children ?? []) {
    const found = find(child, id);
    if (found) return found;
  }
  return null;
}

// La barra izquierda angosta (riel): va por su ancho, no por una marca; arrastrar el borde también la angosta.
export const narrow = () => (find(layout(), "sidebar")?.size?.px ?? Infinity) < 160;

export const tilde = (p) => {
  if (!p) return "";
  const h = home();
  return p === h ? "~" : p.startsWith(h + "/") ? "~" + p.slice(h.length) : p;
};

export function ago(ms) {
  const m = Math.floor(ms / 60000);
  if (m < 1) return "ahora";
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  return h < 24 ? `${h}h` : `${Math.floor(h / 24)}d`;
}

// El número fijo de cada ventana (etiqueta bk.id de su terminal): dirección → "3". Una lectura por dibujo.
export function ids(all = terminals()) {
  const out = new Map();
  for (const x of all) {
    const n = x.labels?.["bk.id"];
    if (n) out.set(x.address, String(n));
  }
  return out;
}

// El título que el agente le puso a su terminal, sin el glifo de estado de adelante ni el " | proyecto" de
// atrás (Codex). "" si no dice nada: una ruta, el nombre del programa, usuario@máquina, su propia dirección (t7).
export function said(title, program, address) {
  const raw = (title ?? "").replace(/^[^\p{L}\p{N}~/]+/u, "").trim();
  if (!raw || raw === address || /^[~/]|^[A-Za-z]:\\/.test(raw) || raw.includes("@")) return "";
  const text = raw.replace(/\s+\|\s+[^|]+$/, "").trim();
  const low = text.toLowerCase();
  return low === (program?.name ?? "").toLowerCase() || low === program?.key ? "" : text;
}

// El icono del programa (la tabla de Herdr): un glifo de un color o una imagen.
export function picto(p, size, color) {
  if (!p?.icon) return null;
  return p.tint ? svg(p.icon).size(size).flex_none().text_color(color) : image(p.icon).w(size).h(size).flex_none();
}

// La marca de estado, la misma en toda la ventana, en una caja de `box` px. Cada estado tiene forma y color
// propios: trabajando, un punto que late (un cuadro cada 450 ms: no redibuja la ventana 30 veces por segundo como un
// spinner); en 2º plano, un medio círculo que gira; te espera, un disco ámbar con !; listo, un tilde verde; quieto, un anillo apagado.
export function mark(t, status, box = 14) {
  const wrap = (el) => div().size(box).flex_none().flex().items_center().justify_center().child(el);
  if (status === "working") return div().size(box).flex_none().flex().items_center().justify_center()
    .text_size(box - 2).line_height(1).text_color(t.working).frames(["●", "●", "•"], 450);
  // En 2º plano: un medio círculo que gira despacio (como el riel de bk-shell), no el punto que late.
  if (status === "background") return div().size(box).flex_none().flex().items_center().justify_center()
    .text_size(box - 2).line_height(1).text_color(t.working).frames(["◐", "◓", "◑", "◒"], 900);
  if (status === "blocked") return div().size(box).flex_none().rounded_full().bg(t.blocked).flex().items_center().justify_center()
    .text_size(box - 4).line_height(1).font_bold().text_color(t.accent_foreground).child("!");
  if (status === "done") return wrap(svg(ICONS + "check.svg").size(box - 1).text_color(t.done));
  return wrap(div().size(Math.round(box * 0.57)).rounded_full().border(1.5).border_color(t.idle ?? t.dim));
}

// El chip con el número de la ventana, como una tecla. `on`: la que tiene el foco. Sin número, un punto.
export function keycap(t, n, { on = false, size = 22 } = {}) {
  const small = size < 20;
  return div().min_w(size).h(size).px(small ? 4 : 0).flex_none().flex().items_center().justify_center()
    .rounded(small ? 5 : 6).border_1().border_color(on ? al(t.accent, "88") : t.border).bg(on ? al(t.accent, "26") : t.raised)
    .text_size(small ? 10.5 : 11.5).line_height(1).font_semibold().text_color(on ? t.accent : n ? t.muted : t.dim)
    .child(n ? String(n) : "·");
}

// Un botón de icono de 24 px. `stop`: en una barra que arrastra la ventana, el clic no la mueve.
export function iconButton(t, id, icon, action, { tip, on = false, size = 14, stop = false } = {}) {
  const el = div().id(id).size(24).flex_none().flex().items_center().justify_center().rounded(6).cursor_pointer()
    .text_color(on ? t.accent : t.dim).when(on, (x) => x.bg(al(t.accent, "1c")))
    .hover((s) => s.bg(t.hover).text_color(t.foreground))
    .on_click((e, cx) => { cx.stop_propagation(); action(e, cx); })
    .child(svg(icon.includes("/") ? icon : ICONS + icon + ".svg").size(size));
  return (stop ? el.on_mouse_down("left", (_e, cx) => cx.stop_propagation()) : el).when(Boolean(tip), (x) => x.tooltip(tip ?? ""));
}

// El rótulo de una sección de la barra: mayúsculas chicas en acento sobre una línea, y a la derecha lo suyo.
export function rule(t, label, right = []) {
  return h_flex().h(30).flex_none().pl(8).pr(4).gap(8).items_center()
    .child(div().flex_none().text_size(10.5).font_semibold().text_color(t.accent).child(label))
    .child(div().flex_1().h(1).bg(t.border))
    .children(right);
}

// La tarjeta: marco redondeado con el título sobre la línea de arriba, como las de la TUI de bk.
// El marco de arriba queda 8 px por debajo del borde de la tarjeta (la mitad de alto del título).
export function card(t, title, right, body, { color } = {}) {
  const line = color ?? t.input;
  const R = 10;
  return v_flex().flex_none()
    .child(h_flex().h(8 + R).items_start()
      .child(div().mt(8).w(12).h(R).flex_none().border_t(1).border_l(1).rounded_tl(R).border_color(line))
      .child(div().flex_none().px(6).h(16).flex().items_center().text_size(10.5).line_height(1).font_semibold().text_color(t.accent).child(title))
      .child(div().mt(8).h(1).flex_1().min_w(8).bg(line))
      .when(Boolean(right), (el) => el.child(div().flex_none().max_w(150).truncate().px(6).h(16).flex().items_center().text_size(10.5).line_height(1).text_color(t.dim).child(right ?? "")))
      .child(div().mt(8).w(12).h(R).flex_none().border_t(1).border_r(1).rounded_tr(R).border_color(line)))
    .child(v_flex().px(12).pt(2).pb(10).gap(6).border_l(1).border_r(1).border_b(1).rounded_bl(R).rounded_br(R).border_color(line).children(body));
}

// Una etiqueta de color: texto sobre un tinte del mismo color.
export function pill(t, text, color) {
  return div().flex_none().px(6).h(17).flex().items_center().rounded(5).bg(al(color, "22")).text_size(10.5).line_height(1).font_medium().text_color(color).child(text);
}
