// alt+u: cuánto se usó hoy y en el mes. Arriba los números grandes (hoy, el mes, la racha, el total), en el medio
// los últimos 30 días en barras y abajo lo de hoy por modelo y por proyecto. El costo es el equivalente en API: con
// suscripción es una referencia, no una factura. Los datos: bk _hub stats (ctrl+r los vuelve a contar).
// Ojo con los tokens: los de hoy van sin las lecturas de caché (aparte); los de los días y el total las incluyen.

import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { theme, props, closeOverlay } from "herdr";
import { bk, chips, plural } from "./kit.js";

const MES = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"];
const MESES = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"];
const ROW = 28, ROWS = 6;   // alto de una fila de las listas y cuántas se ven sin scroll

// 340000 → 340k · 1234567 → 1.2M · 12734710739 → 12.7B
function human(n) {
  n = Math.round(Number(n) || 0);
  for (const [lim, unit] of [[1e9, "B"], [1e6, "M"], [1e3, "k"]]) {
    if (n < lim * 0.9995) continue;
    const v = n / lim;
    return (v >= 99.95 ? String(Math.round(v)) : v.toFixed(1).replace(/\.0$/, "")) + unit;
  }
  return String(n);
}

// 126.7 → $126.70 · 5321.28 → $5,321 (los grandes, sin centavos)
function money(x, cents = true) {
  x = Math.round((Number(x) || 0) * 100) / 100;
  const whole = !cents || x >= 1000;
  const [int, dec] = (whole ? String(Math.round(x)) : x.toFixed(2)).split(".");
  return "$" + int.replace(/\B(?=(\d{3})+$)/g, ",") + (dec ? "." + dec : "");
}

// "2026-11-15" → "15 nov"
function day(date) {
  const [, m, d] = String(date ?? "").split("-").map(Number);
  return m && d ? `${d} ${MES[m - 1] ?? ""}` : String(date ?? "");
}

const sum = (list, field) => list.reduce((n, x) => n + (Number(x[field]) || 0), 0);

export default class Stats extends View {
  init(_p, cx) {
    this.data = null;
    this.error = null;
    this.loading = false;
    this.hover = null;   // el día bajo el puntero
    this.handle = cx.focus_handle();
    this.handle.focus();
    cx.timer.after(300, () => this.handle.focus());
    this.load(cx, false);
  }

  // fresh: sin lo guardado (bk lo guarda 60 s)
  load(cx, fresh) {
    if (this.loading) return;
    this.loading = true;
    cx.spawn(async (cx) => {
      try {
        this.data = await bk(["_hub", "stats", ...(fresh ? ["--fresh"] : [])], { json: true, timeout: 30000 });
        this.error = null;
      } catch (e) { this.error = String(e?.message ?? e); }
      this.loading = false;
      cx.notify();
    });
  }

  card(t, label, big, unit, lines) {
    return v_flex().flex_1().min_w(0).px(16).py(14).gap(4).rounded(10).border_1().border_color(t.border).bg(t.background)
      .child(div().text_size(10.5).font_semibold().text_color(t.dim).child(label.toUpperCase()))
      .child(h_flex().gap(7).items_end()
        .child(div().flex_none().text_size(28).font_semibold().text_color(t.foreground).child(big))
        .when(Boolean(unit), (el) => el.child(div().min_w(0).truncate().pb(5).text_size(12).text_color(t.muted).child(unit ?? ""))))
      .children(lines.filter(Boolean).map((l, i) => div().truncate().text_size(i ? 11 : 12).text_color(i ? t.dim : t.muted).child(l)));
  }

  cards(t, d) {
    const out = [];
    const today = d.today, days = Array.isArray(d.days) ? d.days : [], total = d.total;
    if (today) out.push(this.card(t, "Hoy", money(today.cost), null,
      [`${human(today.tokens)} tokens`, today.cache_read ? `más ${human(today.cache_read)} leídos de caché` : null]));
    if (days.length) {
      // El mes en curso si los 30 días lo cubren entero; si no (un 31), lo que hay: los últimos 30 días
      const ym = String(days[days.length - 1].date).slice(0, 7), whole = String(days[0].date) <= `${ym}-01`;
      const span = whole ? days.filter((x) => String(x.date).startsWith(ym)) : days;
      const used = span.filter((x) => x.cost > 0 || x.tokens > 0).length, cost = sum(span, "cost");
      out.push(this.card(t, whole ? MESES[Number(ym.slice(5)) - 1] ?? "Este mes" : "Últimos 30 días", money(cost), null,
        [`${plural(used, "día", "días")} con uso`, used ? `${money(cost / used)} por día de uso` : null]));
    }
    if (d.streak != null) {
      // bk cuenta la racha desde hoy, o desde ayer si hoy todavía no hubo uso
      const active = (x) => x && (x.cost > 0 || x.tokens > 0), used = days.filter(active).length;
      const upTo = !d.streak ? "ni ayer ni hoy hubo uso" : !days.length ? "con uso" : active(days[days.length - 1]) ? "con uso, contando hoy" : "con uso, hasta ayer";
      out.push(this.card(t, "Racha", String(d.streak), d.streak === 1 ? "día seguido" : "días seguidos",
        [upTo, days.length ? `${used} de los últimos ${days.length} días` : null]));
    }
    if (total) out.push(this.card(t, "Total", money(total.cost, false), null,
      [`${human(total.tokens)} tokens con caché`, total.sessions != null ? plural(total.sessions, "sesión", "sesiones") : null]));
    return out.length ? h_flex().flex_none().gap(10).items_stretch().children(out) : null;
  }

  // Una barra por día, tan alta como su costo; hoy en el color de acento
  chart(t, d) {
    const days = Array.isArray(d.days) ? d.days : [];
    if (!days.length) return null;
    const max = Math.max(...days.map((x) => Number(x.cost) || 0)), top = days.find((x) => x.cost === max);
    const on = this.hover != null ? days[this.hover] : null;
    return v_flex().flex_1().min_h(150).px(16).pt(14).pb(12).gap(10).rounded(10).border_1().border_color(t.border).bg(t.background)
      .child(h_flex().flex_none().items_center().gap(8)
        .child(div().flex_1().text_size(10.5).font_semibold().text_color(t.dim).child(`ÚLTIMOS ${days.length} DÍAS`))
        .child(div().flex_none().text_size(11.5).text_color(on ? t.foreground : t.dim)
          .child(on ? `${day(on.date)} · ${money(on.cost)}` : "costo por día")))
      .child(h_flex().flex_1().min_h(0).gap(4).items_stretch().children(days.map((x, i) => {
        const last = i === days.length - 1, pct = max > 0 ? Math.round((x.cost / max) * 1000) / 10 : 0;
        return v_flex().id(`day-${i}`).flex_1().min_w(0).justify_end()
          .on_hover((hovered, cx) => {
            const next = hovered ? i : this.hover === i ? null : this.hover;
            if (next !== this.hover) { this.hover = next; cx.notify(); }
          })
          .child(div().w_full().h(`${pct}%`).min_h(2).rounded_t(3)
            .bg(x.cost > 0 ? (last || this.hover === i ? t.accent : t.accent + "66") : t.border));
      })))
      .child(h_flex().flex_none().text_size(11).text_color(t.dim)
        .child(div().flex_1().child(day(days[0].date)))
        .child(div().flex_none().child(max > 0 ? `máximo ${money(max)} · ${day(top?.date)}` : "sin uso en estos días"))
        .child(div().flex_1().text_right().text_color(t.accent).child(`hoy · ${day(days[days.length - 1].date)}`)));
  }

  // Una lista de hoy (por modelo, por proyecto): nombre, barra según su costo, tokens y costo
  list(t, id, title, rows, name) {
    if (!Array.isArray(rows)) return null;
    const max = Math.max(0, ...rows.map((r) => Number(r.cost) || 0)), maxTok = Math.max(0, ...rows.map((r) => Number(r.tokens) || 0));
    const share = (r) => (max > 0 ? r.cost / max : maxTok > 0 ? r.tokens / maxTok : 0);
    return v_flex().flex_1().min_w(0).px(16).pt(14).pb(10).gap(8).rounded(10).border_1().border_color(t.border).bg(t.background)
      .child(h_flex().flex_none().gap(8).text_size(10.5).text_color(t.dim)
        .child(div().flex_1().font_semibold().child(title.toUpperCase()))
        .when(rows.length > ROWS, (el) => el.child(div().flex_none().child(`${rows.length - ROWS} más abajo`))))
      .child(v_flex().id(id).h(Math.max(1, Math.min(rows.length, ROWS)) * ROW).overflow_y_scrollbar().text_size(12.5)
        .when(!rows.length, (el) => el.child(div().h(ROW).flex().items_center().text_color(t.dim).child("Hoy todavía no hubo uso.")))
        .children(rows.map((r) => h_flex().flex_none().h(ROW).gap(12).items_center()
          .child(div().w(150).flex_none().truncate().text_color(t.foreground).child(String(name(r) ?? "?")))
          .child(div().flex_1().min_w(40).h(6).rounded(3).bg(t.raised)
            .child(div().h_full().w(`${Math.max(1, Math.round(share(r) * 100))}%`).rounded(3).bg(t.accent)))
          .child(div().w(48).flex_none().text_right().text_color(t.muted).child(human(r.tokens)))
          .child(div().w(72).flex_none().text_right().text_color(t.foreground).child(money(r.cost))))));
  }

  body(t) {
    const d = this.data;
    if (!d) return div().flex_1().px(4).py(8).text_size(13).text_color(this.error ? t.blocked : t.dim).child(this.error ?? "Leyendo…");
    const lists = [this.list(t, "by-model", "Hoy por modelo", d.today?.by_model, (r) => r.name || r.model),
      this.list(t, "by-project", "Hoy por proyecto", d.today?.by_project, (r) => r.project)].filter(Boolean);
    return v_flex().flex_1().min_h(0).gap(10)
      .children([this.cards(t, d), this.chart(t, d)].filter(Boolean))
      .when(lists.length > 0, (el) => el.child(h_flex().flex_none().gap(10).items_start().children(lists)));
  }

  render() {
    const t = theme();
    const hint = (k, what) => h_flex().flex_none().gap(6).items_center().child(chips(t, k)).child(what);
    return v_flex().id("bk-stats").track_focus(this.handle).size_full().min_h(0).p(16).gap(10).bg(t.popover)
      .on_key_down((e, cx) => {
        if (e.key === "escape" || e.key === "q") return closeOverlay(props()?.overlay);
        if (e.key === "r" && e.modifiers.control) { this.load(cx, true); cx.stop_propagation(); cx.notify(); }
      })
      .child(h_flex().flex_none().h(22).gap(8).items_center()
        .child(div().flex_none().size(8).rounded_full().bg(this.error ? t.blocked : t.accent))
        .child(div().flex_none().text_size(13).font_semibold().text_color(t.foreground).child("Uso y costo"))
        .child(div().flex_1().min_w(0).truncate().text_size(12).text_color(t.dim).child(this.loading && this.data ? "contando de nuevo…" : "costo equivalente en API"))
        .when(Boolean(this.error && this.data), (el) => el.child(div().flex_none().max_w(420).truncate().text_size(11.5).text_color(t.blocked).child(this.error ?? ""))))
      .child(this.body(t))
      .child(h_flex().flex_none().h(26).px(4).gap(14).items_center().text_size(11).text_color(t.dim)
        .child(hint("escape", "cerrar")).child(hint("ctrl-r", "contar de nuevo"))
        .child(div().flex_1().min_w(0).truncate().text_right()
          .child("El costo es lo que saldría por la API: con suscripción es una referencia, no una factura.")));
  }
}
