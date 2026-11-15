// alt+h: seguir en un chat nuevo. Le pide el resumen al chat que mirás (bk handoff --term); cuando el agente lo
// guarda, bk abre el chat nuevo solo (context_hook.py → bk handoff --listo) y, si lo elegiste, cierra el viejo.
// Abajo, los resúmenes que ya están listos: Enter sigue desde ese.

import { div } from "gpui-kit";
import { h_flex, v_flex } from "gpui-base";
import { focused, agents, notify } from "herdr";
import { Panel, rank, bk, launch, lastLine, ago, pill } from "./kit.js";

export default class Handoff extends Panel {
  setup() {
    this.title = "Seguir en un chat nuevo";
    this.placeholder = "Enter: pedir el resumen de este chat";
    this.term = focused()?.terminal ?? null;
    this.agent = agents().find((a) => a.address === this.term) ?? null;
    this.ready = [];
  }

  subtitle() {
    return this.agent ? `${this.agent.space_name} · ${this.agent.tab_name}` : "la terminal que mirás no es un chat";
  }

  async load() {
    this.ready = (await bk(["_hub", "handoffs"], { json: true, timeout: 8000 })).items ?? [];
  }

  rows() {
    const mine = this.agent ? [
      { key: "seguir", kind: "ask", cerrar: false, title: "Pedir el resumen y seguir en un chat nuevo", note: "este chat queda abierto" },
      { key: "cerrar", kind: "ask", cerrar: true, title: "Pedir el resumen, seguir y cerrar este chat", note: "se cierra cuando el nuevo abre" },
    ] : [];
    const ready = this.ready.map((r) => ({ key: `r-${r.sid}`, kind: "ready", r, title: r.name || r.project || r.sid.slice(0, 8) }));
    const all = rank([...mine, ...ready], this.query, (x) => [x.title, x.note ?? x.r?.project ?? ""]);
    const out = [];
    const a = all.filter((x) => x.item.kind === "ask"), b = all.filter((x) => x.item.kind === "ready");
    if (a.length) out.push({ head: "Este chat" }, ...a.map((x) => ({ ...x.item, hits: x.hits })));
    if (b.length) out.push({ head: "Resúmenes listos" }, ...b.map((x) => ({ ...x.item, hits: x.hits })));
    return out;
  }

  empty() { return "Parate en un chat y volvé a abrir esto (alt+h)."; }

  draw(t, r, on) {
    const title = div().flex_1().min_w(0).truncate().text_color(on ? t.foreground : t.muted).child(r.title);
    if (r.kind === "ask") return h_flex().flex_1().min_w(0).gap(10).items_center().child(title)
      .child(div().flex_none().text_size(11.5).text_color(r.cerrar ? t.blocked : t.dim).child(r.note));
    return h_flex().flex_1().min_w(0).gap(10).items_center().child(title)
      .when(Boolean(r.r.project), (el) => el.child(pill(t, r.r.project, t.accent)))
      .child(div().flex_none().text_size(11.5).text_color(t.dim).child(ago(r.r.age_min)));
  }

  hints(row) {
    return [["enter", row?.kind === "ready" ? "seguir desde este resumen" : "pedir el resumen"], ["escape", "cerrar"]];
  }

  enter(r, cx) {
    if (r.kind === "ready") { this.close(); return launch("Seguir en un chat nuevo", ["chat", "--desde", r.r.sid]); }
    this.work(cx, "pidiendo…", async () => {
      const res = await bk(["handoff", "--term", this.term, ...(r.cerrar ? ["--cerrar"] : [])], { timeout: 20000 });
      if (res.code !== 0) throw new Error(lastLine(res.stderr) || lastLine(res.stdout) || "bk handoff falló");
      notify({ title: "Resumen pedido", body: lastLine(res.stdout).replace(/^→\s*/, ""), level: "success", timeout: 6000 });
      this.close();
    });
  }
}
