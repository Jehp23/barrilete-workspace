// La salida de un comando de bk que solo muestra texto (tokens, roles, cuentas, lecciones…), en un panel.
// props: { title, args, dir }. ctrl+r lo corre de nuevo.

import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { exec, theme, props, closeOverlay, settings } from "herdr";
import { clean, chips, tilde, bin } from "./kit.js";

export default class Out extends View {
  init(_p, cx) {
    this.text = null;
    this.code = 0;
    this.handle = cx.focus_handle();
    this.handle.focus();
    cx.timer.after(300, () => this.handle.focus());
    this.runIt(cx);
  }

  runIt(cx) {
    const p = props() ?? {};
    this.text = null;
    cx.spawn(async (cx) => {
      try {
        const r = await exec(bin(), p.args ?? ["help"], { cwd: p.dir, timeout: 60000 });
        this.code = r.code;
        this.text = clean(`${r.stdout}${r.stderr ? `\n${r.stderr}` : ""}`).replace(/\s+$/, "") || "(sin salida)";
      } catch (e) {
        this.code = 1;
        this.text = String(e?.message ?? e);
      }
      cx.notify();
    });
  }

  render() {
    const t = theme();
    const p = props() ?? {};
    const lines = (this.text ?? "").split("\n");
    return v_flex().id("bk-out").track_focus(this.handle).size_full().min_h(0).p(16).gap(10).bg(t.popover)
      .on_key_down((e, cx) => {
        if (e.key === "escape" || e.key === "q" || e.key === "enter") return closeOverlay(p.overlay);
        if (e.key === "r" && e.modifiers.control) { this.runIt(cx); cx.notify(); }
      })
      .child(h_flex().flex_none().h(22).gap(8).items_center()
        .child(div().flex_none().size(8).rounded_full().bg(this.code ? t.blocked : t.accent))
        .child(div().flex_none().text_size(13).font_semibold().text_color(t.foreground).child(p.title ?? "bk"))
        .child(div().flex_1().min_w(0).truncate().text_size(12).text_color(t.dim).child(`bk ${(p.args ?? []).join(" ")} · ${tilde(p.dir)}`)))
      .child(v_flex().id("out-text").flex_1().min_h(0).p(14).rounded(10).border_1().border_color(t.border).bg(t.background)
        .overflow_y_scrollbar().font_family(settings().font_family ?? "JetBrains Mono").text_size(12.5).text_color(t.foreground)
        .children(this.text === null ? [div().text_color(t.dim).child("Corriendo…")]
          : lines.map((l) => div().flex_none().whitespace_nowrap().child(l.replace(/ /g, " ") || " "))))
      .child(h_flex().flex_none().h(26).px(4).gap(14).items_center().text_size(11).text_color(t.dim)
        .child(h_flex().gap(6).items_center().child(chips(t, "escape")).child("cerrar"))
        .child(h_flex().gap(6).items_center().child(chips(t, "ctrl-r")).child("correr de nuevo")));
  }
}
