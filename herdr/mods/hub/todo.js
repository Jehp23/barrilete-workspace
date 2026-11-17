// alt+t: los pasos del issue que trabaja el chat que mirás. El issue sale como en ÉPICAS (la carpeta, la rama, el
// nombre del chat y su terminal) y los pasos son las casillas `- [ ]` de su cuerpo («Hecho cuando»), de `bk _todo`
// (lib/herdr_todo.py, con caché de dos minutos). Solo lee: tildar es del agente (gh). Enter abre el issue en GitHub.

import { div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { focused, panes, terminals } from "herdr";
import { Panel, rank, bk, openUrl, pill } from "./kit.js";

const CHARS = 78;   // letras por renglón en el popup de 640: una casilla larga ocupa más de una fila

export default class Todo extends Panel {
  setup() {
    this.title = "TODO";
    this.placeholder = "Buscar un paso…";
    const f = focused() ?? {};
    this.term = f.terminal ?? null;
    this.pane = f.pane ?? null;
    this.dir = f.cwd ?? null;
    this.todo = null;   // lo que dijo bk _todo
  }

  subtitle() {
    const td = this.todo;
    if (!td?.issue) return "";
    return `#${td.issue}${td.total ? ` · ${td.done}/${td.total} hechas` : ""}`;
  }

  // Lo mismo que le pasaba el panel derecho: carpeta, rama, el nombre del chat (bk.name, bk.autotitle y el título
  // del pane) y la terminal
  args() {
    const p = panes().find((x) => x.pane === this.pane) ?? {};
    const l = terminals().find((x) => x.address === this.term)?.labels ?? {};
    return [this.dir ?? "", p.branch ?? "", [l["bk.name"], l["bk.autotitle"], p.title].filter(Boolean).join(" "), this.term];
  }

  async load() {
    if (!this.term || !this.dir) { this.todo = { issue: null }; return; }
    this.todo = await bk(["_todo", ...this.args()], { json: true, dir: this.dir, timeout: 30000 });
  }

  rows() {
    const td = this.todo;
    if (!td?.issue) return [];
    const items = (td.items ?? []).map((i, n) => {
      const text = i.text.replace(/`/g, "");
      return { key: `i-${n}`, kind: "item", text, done: i.done, section: i.section ?? "", h: 34 + 18 * Math.min(2, Math.floor(text.length / CHARS)) };
    });
    const top = { key: "issue", kind: "issue", text: td.title || (td.offline ? "sin red" : "") };
    const found = rank(items, this.query, (x) => [x.text, x.section]);
    const out = [];
    if (!this.query.trim()) out.push(top);
    let section = null;
    for (const { item, hits } of found) {
      if (item.section !== section) { out.push({ head: item.section || "Pasos" }); section = item.section; }
      out.push({ ...item, hits });
    }
    if (!items.length && !this.query.trim()) {
      out.push({ key: "none", kind: "none", text: td.offline ? "No pude leer el issue (¿sin red?)" : "El issue no tiene casillas (- [ ])" });
    }
    return out;
  }

  empty() {
    if (!this.term) return "Parate en un chat y volvé a abrir esto (alt+t).";
    return "Este chat no trabaja un issue";
  }

  draw(t, r, on) {
    if (r.kind === "issue") return h_flex().flex_1().min_w(0).gap(10).items_center()
      .child(div().flex_1().min_w(0).truncate().text_color(on ? t.foreground : t.muted).child(r.text))
      .when(Boolean(this.todo?.state === "closed"), (el) => el.child(pill(t, "cerrado", t.done)))
      .child(div().flex_none().text_size(11.5).text_color(t.accent).child(`#${this.todo.issue}`));
    if (r.kind === "none") return div().flex_1().min_w(0).text_color(this.todo?.offline ? t.blocked : t.dim).child(r.text);
    const box = div().size(13).flex_none().rounded(3).border_1().border_color(r.done ? t.done : t.input).bg(r.done ? t.done : "#00000000")
      .flex().items_center().justify_center().text_size(9).font_bold().text_color(t.background ?? "#000").child(r.done ? "✓" : "");
    const color = r.done ? t.dim : on ? t.foreground : t.muted;
    return h_flex().flex_1().min_w(0).gap(10).items_center().child(box)
      .child(div().flex_1().min_w(0).text_size(12.5).text_color(color).when(r.done, (el) => el.line_through()).child(r.text));
  }

  hints() { return this.todo?.url ? [["enter", "GitHub"], ["escape", "cerrar"]] : [["escape", "cerrar"]]; }

  enter() {
    if (this.todo?.url) { openUrl(this.todo.url); this.close(); }
  }
}
