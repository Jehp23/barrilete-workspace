// alt+h: seguir en un chat nuevo. Le pide el resumen al chat que mirás (bk handoff --term); cuando el agente lo
// guarda, bk abre el chat nuevo solo (context_hook.py → bk handoff --listo) y, si lo elegiste, cierra el viejo.
// Abajo, los resúmenes que ya están listos: Enter sigue desde ese. Al final, el umbral de contexto (bk context): con
// cuánto contexto el chat deja su resumen y sigue en uno nuevo solo (200k por defecto).

import { div } from "gpui-kit";
import { h_flex, v_flex } from "gpui-base";
import { focused, agents, notify, props } from "herdr";
import { Panel, rank, bk, launch, lastLine, ago, pill } from "./kit.js";

export default class Handoff extends Panel {
  setup() {
    this.title = "Seguir en un chat nuevo";
    this.placeholder = "Enter: pedir el resumen de este chat";
    this.term = focused()?.terminal ?? null;
    this.agent = agents().find((a) => a.address === this.term) ?? null;
    this.ready = [];
    this.ctx = null;   // bk context --json: {limit, warn, default, custom}
  }

  subtitle() {
    return this.agent ? `${this.agent.space_name} · ${this.agent.tab_name}` : "la terminal que mirás no es un chat";
  }

  async load() {
    const [h, c] = await Promise.all([bk(["_hub", "handoffs"], { json: true, timeout: 8000 }),
      bk(["context", "--json"], { json: true, timeout: 8000 }).catch(() => null)]);
    this.ready = h.items ?? [];
    this.ctx = c?.limit ? c : null;
    // Desde la paleta (alt+k → «Umbral de contexto»): el cursor en el umbral en uso
    if ((props() ?? {}).section === "limit") {
      const i = this.rows().filter((r) => !r.head).findIndex((r) => r.kind === "limit" && r.on);
      if (i >= 0) this.at = i;
    }
  }

  // Las opciones del umbral: las fijas y la elegida (si es otra, de bk context <n>)
  limits() {
    if (!this.ctx) return [];
    const k = (n) => `${Math.round(n / 1000)}k`;
    const opts = [150000, 200000, 300000, 400000, 500000];
    if (!opts.includes(this.ctx.limit)) opts.push(this.ctx.limit);
    return opts.sort((a, b) => a - b).map((n) => ({
      key: `l-${n}`, kind: "limit", n, on: n === this.ctx.limit,
      title: `Umbral: ${k(n)}${n === this.ctx.default ? " (por defecto)" : ""}`,
      note: n === this.ctx.limit ? "en uso" : `aviso desde ${k(Math.floor(n * 3 / 4))}`,
    }));
  }

  rows() {
    const mine = this.agent ? [
      { key: "seguir", kind: "ask", cerrar: false, title: "Pedir el resumen y seguir en un chat nuevo", note: "este chat queda abierto" },
      { key: "cerrar", kind: "ask", cerrar: true, title: "Pedir el resumen, seguir y cerrar este chat", note: "se cierra cuando el nuevo abre" },
    ] : [];
    const ready = this.ready.map((r) => ({ key: `r-${r.sid}`, kind: "ready", r, title: r.name || r.project || r.sid.slice(0, 8) }));
    const all = rank([...mine, ...ready, ...this.limits()], this.query, (x) => [x.title, x.note ?? x.r?.project ?? ""]);
    const out = [];
    const a = all.filter((x) => x.item.kind === "ask"), b = all.filter((x) => x.item.kind === "ready");
    if (a.length) out.push({ head: "Este chat" }, ...a.map((x) => ({ ...x.item, hits: x.hits })));
    if (b.length) out.push({ head: "Resúmenes listos" }, ...b.map((x) => ({ ...x.item, hits: x.hits })));
    const c = all.filter((x) => x.item.kind === "limit");
    if (c.length) out.push({ head: "Con cuánto contexto seguir en un chat nuevo" }, ...c.map((x) => ({ ...x.item, hits: x.hits })));
    return out;
  }

  empty() { return "Parate en un chat y volvé a abrir esto (alt+h)."; }

  draw(t, r, on) {
    const title = div().flex_1().min_w(0).truncate().text_color(on ? t.foreground : t.muted).child(r.title);
    if (r.kind === "ask") return h_flex().flex_1().min_w(0).gap(10).items_center().child(title)
      .child(div().flex_none().text_size(11.5).text_color(r.cerrar ? t.blocked : t.dim).child(r.note));
    if (r.kind === "limit") return h_flex().flex_1().min_w(0).gap(10).items_center().child(title)
      .child(div().flex_none().text_size(11.5).text_color(r.on ? t.accent : t.dim).child(r.note));
    return h_flex().flex_1().min_w(0).gap(10).items_center().child(title)
      .when(Boolean(r.r.project), (el) => el.child(pill(t, r.r.project, t.accent)))
      .child(div().flex_none().text_size(11.5).text_color(t.dim).child(ago(r.r.age_min)));
  }

  hints(row) {
    const what = row?.kind === "ready" ? "seguir desde este resumen" : row?.kind === "limit" ? "usar este umbral" : "pedir el resumen";
    return [["enter", what], ["escape", "cerrar"]];
  }

  enter(r, cx) {
    if (r.kind === "ready") { this.close(); return launch("Seguir en un chat nuevo", ["chat", "--desde", r.r.sid]); }
    if (r.kind === "limit") return this.work(cx, "guardando…", async () => {
      const res = await bk(["context", String(r.n)], { timeout: 8000 });
      if (res.code !== 0) throw new Error(lastLine(res.stderr) || lastLine(res.stdout) || "bk context falló");
      this.ctx = { ...this.ctx, limit: r.n, custom: true };
      notify({ title: "Umbral de contexto", body: lastLine(res.stdout), level: "success", timeout: 5000 });
    });
    this.work(cx, "pidiendo…", async () => {
      const res = await bk(["handoff", "--term", this.term, ...(r.cerrar ? ["--cerrar"] : [])], { timeout: 20000 });
      if (res.code !== 0) throw new Error(lastLine(res.stderr) || lastLine(res.stdout) || "bk handoff falló");
      notify({ title: "Resumen pedido", body: lastLine(res.stdout).replace(/^→\s*/, ""), level: "success", timeout: 6000 });
      this.close();
    });
  }
}
