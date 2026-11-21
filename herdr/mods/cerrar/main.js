// Cerrar un chat que siguió de otros por handoffs (instalado como mods/bk-cerrar): la cadena entera de «antes»
// (etiqueta bk.from del nuevo, lib/herdr.sh; la misma que arma lineage() en la barra de agentes) en una lista, con
// título, cuándo y estado, y todos marcados. Enter cierra los marcados, «Cerrar todos (N)» cierra todos, espacio (o un
// clic) desmarca el que querés guardar. Lo abren el «Cerrar…» del clic derecho (herdr/mods/menu) y ctrl+x de
// Sesiones (herdr/mods/hub/sessions.js), solo si el chat tiene un «antes» vivo; sin «antes» cierran como siempre.
// props: { terminal } (el chat que se cierra).

import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { agents, terminals, panes, spaces, run, exec, props, closeOverlay, theme, notify, shared } from "herdr";
import { ICONS, PROSE, WORD, ago, ids, said, mark, keycap } from "./kit.js";

// El tamaño con el que lo abren el menú y Sesiones (el mismo que mod.json; un test los compara)
export const SIZE = { kind: "dialog", width: 540, height: 400 };
const bin = () => shared("bk.bin") || "bk";
const pinned = (x) => Boolean(x?.pinned || x?.labels?.["herdr.pinned"]);

// La cadena de un chat: [él, el chat del que siguió, el de antes de ese…], solo terminales vivas. Como lineage():
// un viejo fijado conserva su fila (corta la cadena) y una vuelta se corta.
export function chain(address, all = terminals()) {
  const live = new Map(all.filter((x) => x.state === "live").map((x) => [x.address, x]));
  if (!live.has(address)) return [];
  const out = [address];
  for (let cur = live.get(address); cur;) {
    const from = cur.labels?.["bk.from"];
    const old = from && !out.includes(from) ? live.get(from) : null;
    if (!old || pinned(old)) break;
    out.push(from);
    cur = old;
  }
  return out;
}

// Cerrar una terminal como ctrl+x de Sesiones: un agente del kit con bk stop; si no, su pestaña si es lo único que
// tiene, si no solo su pane, y sin pane su terminal. Este popup ya es la confirmación.
export function shut(address) {
  const x = terminals().find((t) => t.address === address);
  const L = x?.labels ?? {};
  if (L["bk.kind"] === "agent" && L["bk.win"]) return exec(bin(), ["stop", L["bk.win"]], { timeout: 30000 });
  const all = panes();
  const pane = all.find((p) => p.terminal === address);
  if (pane && all.filter((p) => p.tab === pane.tab).length === 1) run("tab.close", { id: pane.tab, confirmed: true });
  else if (pane) run("pane.close", { pane: pane.pane });
  else run("terminal.kill", { terminal: address });
}

export default class Cerrar extends View {
  init(_props, cx) {
    this.handle = cx.focus_handle();
    this.handle.focus();
    this.at = 0;
    this.list = chain(props()?.terminal);
    this.off = new Set();     // los que desmarcaste (los demás se cierran)
    this.info = new Map();    // terminal → { title, age_min } de bk _hub sessions
    cx.spawn(async (cx) => {
      try {
        const r = await exec(bin(), ["_hub", "sessions"], { timeout: 20000 });
        if (r.code === 0) for (const s of JSON.parse(r.stdout).open ?? []) if (s.terminal) this.info.set(s.terminal, s);
      } catch (_) { /* sin bk: sin cuándo, y el título de Herdr */ }
      cx.notify();
    });
  }

  marked() { return this.list.filter((a) => !this.off.has(a)); }

  toggle(a) { this.off.has(a) ? this.off.delete(a) : this.off.add(a); }

  // El título que muestra la barra: el nombre del chat (bk.name o el de su pestaña), el de bk, el del agente
  titleOf(a) {
    const x = terminals().find((t) => t.address === a);
    const L = x?.labels ?? {};
    const tab = spaces().flatMap((s) => s.tabs ?? []).find((tb) => tb.id === L["herdr.tab"]);
    const ag = agents().find((g) => g.address === a);
    return L["bk.name"] || (tab?.named ? tab.name : "") || L["bk.autotitle"] || this.info.get(a)?.title
      || said(ag?.title, ag?.program, a) || x?.name || a;
  }

  done(which) {
    if (!which.length) return;
    for (const a of which) shut(a);
    closeOverlay(props().overlay);
    const kept = this.list.length - which.length;
    notify({ title: which.length === 1 ? `Cerré «${this.titleOf(which[0])}»` : `Cerré ${which.length} chats`,
      body: kept ? `quedan abiertos ${kept} de la cadena` : "", level: "info", timeout: 3000 });
  }

  render() {
    const t = theme();
    const list = this.list;
    const n = ids();
    const shown = this.marked();
    this.at = Math.max(0, Math.min(this.at, list.length - 1));
    const button = (id, label, on, primary, click) => div().id(id).h(28).px(12).flex().items_center().rounded(7)
      .text_size(12.5).when(on, (el) => el.cursor_pointer().on_click(click))
      .bg(primary && on ? t.ansi1 ?? t.blocked : t.raised).border_1().border_color(primary && on ? t.ansi1 ?? t.blocked : t.border)
      .text_color(!on ? t.dim : primary ? t.accent_foreground ?? t.background : t.foreground)
      .hover((s) => (on ? s.bg(primary ? t.ansi1 ?? t.blocked : t.hover) : s))
      .child(label);
    const row = (a, i) => {
      const on = i === this.at, keep = this.off.has(a);
      const status = agents().find((g) => g.address === a)?.status;
      const min = this.info.get(a)?.age_min;
      const meta = [i === 0 ? "este chat" : "antes", status ? WORD[status] ?? status : "", min == null ? "" : ago(min * 60000)].filter(Boolean).join(" · ");
      return h_flex().id(`cc-${a}`).h(44).px(10).gap(10).flex_none().rounded(7).items_center().cursor_pointer()
        .when(on, (el) => el.bg(t.selected))
        .hover((s) => s.bg(on ? t.selected : t.hover))
        .on_hover((h, cx) => { if (h && this.at !== i) { this.at = i; cx.notify(); } })
        .on_click((_e, cx) => { this.at = i; this.toggle(a); cx.notify(); })
        .child(div().size(16).flex_none().flex().items_center().justify_center().rounded(4).border_1()
          .border_color(keep ? t.border : t.ansi1 ?? t.blocked).when(!keep, (el) => el.bg(t.ansi1 ?? t.blocked))
          .when(!keep, (el) => el.child(svg(ICONS + "check.svg").size(12).text_color(t.accent_foreground ?? t.background))))
        .child(keycap(t, n.get(a), { size: 20 }))
        .child(v_flex().flex_1().min_w(0).gap(2)
          .child(div().truncate().font_family(PROSE).text_size(13).text_color(keep ? t.muted : t.foreground).child(this.titleOf(a)))
          .child(div().truncate().text_size(11).text_color(t.dim).child(keep ? `${meta} · queda abierto` : meta)))
        .when(Boolean(status), (el) => el.child(mark(t, status)));
    };
    return v_flex().id("bk-cerrar").track_focus(this.handle).size_full().min_h(0).p(14).gap(10).bg(t.popover)
      .on_key_down((e, cx) => {
        const a = list[this.at];
        if (e.key === "down") this.at = (this.at + 1) % list.length;
        else if (e.key === "up") this.at = (this.at + list.length - 1) % list.length;
        else if (e.key === "space" && a) this.toggle(a);
        else if (e.key === "enter") return this.done(e.modifiers?.control ? list : this.marked());
        else if (e.key === "escape") return closeOverlay(props().overlay);
        else return;
        cx.notify();
      })
      .child(v_flex().gap(3).flex_none()
        .child(div().font_family(PROSE).text_size(15).font_medium().text_color(t.foreground)
          .child(list.length > 1 ? `Cerrar este chat y ${list.length === 2 ? "el de antes" : `sus ${list.length - 1} de antes`}` : "Cerrar este chat"))
        .child(div().text_size(11.5).text_color(t.dim)
          .child("Siguieron uno de otro por handoffs. Se cierran los marcados: desmarcá (espacio o clic) los que querés guardar.")))
      .child(v_flex().id("cc-list").flex_1().min_h(0).gap(2).overflow_y_scroll().children(list.map(row)))
      .child(h_flex().flex_none().gap(8).items_center().justify_end()
        .child(div().flex_1().text_size(11).text_color(t.dim).child("↑↓ mover · espacio marcar · esc cancelar"))
        .child(button("cc-all", `Cerrar todos (${list.length})`, list.length > 0, false, () => this.done(list)))
        .child(button("cc-go", `Cerrar ${shown.length === list.length ? "" : "marcados "}(${shown.length}) ↵`, shown.length > 0, true, () => this.done(this.marked()))));
  }
}
