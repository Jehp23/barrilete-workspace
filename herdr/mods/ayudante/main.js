// La cabecera del popup de Piola, el ayudante del workspace (instalado como mods/bk-ayudante). El popup lo arma
// mods/bk en alt+y: esta franja arriba y la terminal de Codex abajo. Dice quién es, cómo está y cómo se esconde:
// Esc no cierra el popup (va a Codex y lo interrumpe), así que la salida tiene que estar a la vista.
// props: { terminal } (la terminal del ayudante). Temporal: hasta que el workspace quede pulido.

import { View, div, svg } from "gpui-kit";
import { h_flex, v_flex } from "gpui-base";
import { terminals, keys, run, props, theme } from "herdr";

export const NOMBRE = "Piola";   // el mismo en mods/pestanas, en lib/ayudante.md y en el saludo de bk _ayuda
export const LEMA = "el ayudante del workspace · Codex en el repo de bk";
const MOD = "bk-ayuda";          // el mod que lo muestra y lo esconde (alt+y)
const GLYPH = { alt: "⌥", cmd: "⌘", ctrl: "⌃", shift: "⇧" };
export const WORD = { working: "trabajando", blocked: "te espera", done: "terminó" };

// Un color del tema con transparencia; uno que ya la trae queda como está (como en kit.js)
const al = (c, a) => (/^#[0-9a-fA-F]{6}$/.test(c ?? "") ? c + a : c ?? "#00000000");

// Cómo está: el estado que informa Codex en su terminal ("working", "blocked", "done"…); "" si no dice nada
// o si la terminal ya no vive.
export function estado(terminal, ts = terminals()) {
  const x = ts.find((t) => t.address === terminal);
  return x?.state === "live" && typeof x.status === "string" ? x.status : "";
}

// La tecla que abre un mod, en símbolos ("alt-y" → "⌥Y"); "" si no tiene
export function keyOfMod(name, all = keys()) {
  const k = all.find((b) => b.section === "global" && b.action === `mod.open:${name}`)?.keys;
  return k ? k.split("-").map((p) => GLYPH[p] ?? p.toUpperCase()).join("") : "";
}

export default class Ayudante extends View {
  render() {
    const t = theme();
    const st = estado(props()?.terminal);
    const word = WORD[st] ?? "";
    const color = st === "blocked" ? t.blocked : st === "done" ? t.done : t.working;
    const key = keyOfMod(MOD);
    return h_flex().id("bk-ayudante").size_full().pl(12).pr(10).gap(10).items_center().bg(t.chrome).border_b(1).border_color(t.border)
      .child(div().size(28).flex_none().rounded(8).bg(al(t.accent, "26")).flex().items_center().justify_center()
        .child(svg("mods/bk-ayudante/piola.svg").size(19).text_color(t.accent)))
      .child(v_flex().flex_1().min_w(0).gap(1)
        .child(h_flex().gap(8).items_center()
          .child(div().flex_none().text_size(13.5).font_bold().text_color(t.foreground).child(NOMBRE))
          .when(Boolean(word), (el) => el.child(div().flex_none().px(6).h(17).flex().items_center().rounded(5).bg(al(color, "22"))
            .text_size(10.5).line_height(1).font_medium().text_color(color).child(word))))
        .child(div().truncate().font_family("Geist").text_size(11.5).text_color(t.dim).child(LEMA)))
      .child(div().flex_none().font_family("Geist").text_size(11).text_color(t.dim).child("esc interrumpe a Codex"))
      .child(h_flex().id("ay-hide").h(26).pl(5).pr(9).gap(6).flex_none().items_center().rounded(7).cursor_pointer()
        .border_1().border_color(t.border).bg(t.raised).hover((s) => s.bg(t.hover))
        .tooltip("Esconder a Piola: la conversación sigue abierta")
        .on_click(() => run("mod.open", { name: MOD }))
        .when(Boolean(key), (el) => el.child(div().h(18).px(4).flex_none().flex().items_center().justify_center().rounded(5).border_1()
          .border_color(t.border).bg(t.background).text_size(10.5).line_height(1).font_semibold().text_color(t.muted).child(key)))
        .child(div().text_size(11.5).text_color(t.foreground).child("esconder")));
  }
}
