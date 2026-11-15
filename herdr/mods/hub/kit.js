// Piezas comunes de los paneles de bk en Herdr (herdr/mods/hub): un panel es una lista con búsqueda que se
// maneja entera con el teclado. Cada vista (palette.js, issues.js…) extiende Panel y dice qué filas hay, cómo se
// dibuja cada una y qué hace Enter. Lo que es del kit (lanzar, aprobar, saltar) lo hace `bk`: acá no se decide.

import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex, InputState, Input } from "gpui-base";
import { exec, hc, theme, props, closeOverlay, openOverlay, focused, home, notify, keys, settings, run, terminals, setShared, shared } from "herdr";

export const ROW_H = 34;
export const HEAD_H = 28;
const POP = "bk.pop";   // el popup de terminal abierto (lo comparte con mods/bk)

export const cwd = () => focused()?.cwd || home();
// El bk que corren los paneles: el del PATH, salvo que shared "bk.bin" diga otro (la ventana de prueba)
export const bin = () => shared("bk.bin") || "bk";
export const tilde = (p) => (p ?? "").replace(home(), "~");
export const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

export function ago(min) {
  if (min == null) return "";
  if (min < 1) return "ahora";
  if (min < 60) return `${Math.round(min)} min`;
  const h = Math.floor(min / 60);
  return h < 24 ? `${h} h` : `${Math.floor(h / 24)} d`;
}

// Tus letras en orden; el inicio de palabra y las seguidas valen más. null: no coincide.
export function fuzzy(q, text) {
  const t = text.toLowerCase();
  let score = 0, at = 0, streak = 0;
  const hits = [];
  for (const ch of q) {
    const i = t.indexOf(ch, at);
    if (i < 0) return null;
    const start = i === 0 || /[\s:.\-_/#]/.test(t[i - 1]);
    streak = i === at && hits.length ? streak + 1 : 0;
    score += 1 + (start ? 6 : 0) + streak * 3 - Math.min(i - at, 6) * 0.3;
    hits.push(i);
    at = i + 1;
  }
  return { score: score - text.length * 0.02, hits };
}

// Filtra y ordena `items` por la búsqueda sobre text(item); sin búsqueda, los deja como vienen.
export function rank(items, query, text) {
  const q = query.trim().toLowerCase().replace(/\s+/g, "");
  if (!q) return items.map((item) => ({ item, hits: [] }));
  return items
    .map((item) => {
      const [main, more] = [].concat(text(item));
      const a = fuzzy(q, main);
      const b = a ? null : more ? fuzzy(q, `${main} ${more}`) : null;
      return a ? { item, score: a.score, hits: a.hits } : b ? { item, score: b.score - 4, hits: [] } : null;
    })
    .filter(Boolean)
    .sort((x, y) => y.score - x.score);
}

// bk <args>: el mismo bk de la terminal. json: true devuelve el JSON de su salida o tira su error.
export async function bk(args, { dir, timeout = 20000, json = false } = {}) {
  const r = await exec(bin(), args, { cwd: dir || cwd(), timeout });
  if (!json) return r;
  if (r.code !== 0) throw new Error(lastLine(r.stderr) || lastLine(r.stdout) || `bk ${args[0]} salió con ${r.code}`);
  return JSON.parse(r.stdout);
}

export const lastLine = (s) => clean(s ?? "").split("\n").map((l) => l.trim()).filter(Boolean).pop() ?? "";
export const clean = (s) => s.replace(/\u001b\[[0-9;?]*[A-Za-z]/g, "").replace(/\r/g, "");

// Una acción larga del kit (lanzar un agente, abrir un chat): bk la corre suelta y avisa al terminar.
export async function launch(title, args, dir) {
  notify({ title, body: `bk ${args.join(" ")}`, level: "info", timeout: 4000 });
  const r = await exec(bin(), ["_do", "--cwd", dir || cwd(), "--title", title, "--", ...args], { timeout: 15000 });
  if (r.code !== 0) notify({ title: `No pude: ${title}`, body: lastLine(r.stderr) || lastLine(r.stdout), level: "error" });
}

// Otra vista de bk (issues, prs…) o un mod de Herdr, en lugar de esta.
export function goto(name, extra = {}) {
  closeOverlay(props().overlay);
  if (extra.props) openOverlay({ mod: name, props: extra.props, kind: "dialog", width: extra.width ?? 0.86, height: extra.height ?? 0.82 });
  else run("mod.open", { name });
}

// Un programa de pantalla completa (bk monitor, la radio) en una terminal sobre la ventana; se cierra al salir.
export async function termPopup(name, cmd, dir, size = [0.9, 0.85]) {
  const old = shared(POP);
  if (old) {
    setShared(POP, null);
    closeOverlay(old.id);
    if (!old.keep && terminals().some((t) => t.address === old.terminal && t.state === "live")) await hc(["kill", old.terminal]);
  }
  const sh = `{ ${cmd}; } || { printf '\\n  (falló: enter para cerrar) '; read -r _; }`;
  const r = await hc(["run", "--json", "--bg", "--no-parent", "--rm", "--cwd", dir || cwd(), "--label", "bk.kind=popup",
    "--", "env", "BK_BACKEND=herdr", `BK_FROM_TERM=${focused()?.terminal ?? ""}`, "sh", "-c", sh]);
  if (r.code !== 0) throw new Error(lastLine(r.stderr) || "hc no abrió la terminal");
  const terminal = JSON.parse(r.stdout).address;
  const id = openOverlay({ kind: "dialog", modal: true, width: size[0], height: size[1], layout: { type: "block", content: { terminal } } });
  setShared(POP, { name, id, terminal, keep: false });
}

// "alt-shift-1" → ["⌥", "⇧", "1"]
const GLYPH = { alt: "⌥", cmd: "⌘", ctrl: "⌃", shift: "⇧", enter: "↵", escape: "esc", tab: "⇥", up: "↑", down: "↓", left: "←", right: "→", backspace: "⌫", space: "␣" };
export function keyParts(k) {
  const parts = k.endsWith("--") ? [...k.slice(0, -2).split("-"), "-"] : k.split("-");
  return parts.map((p) => GLYPH[p] ?? (p.length === 1 ? p.toUpperCase() : p));
}
export function chips(t, k, strong = false) {
  return h_flex().flex_none().gap(3).children(keyParts(k).map((p) =>
    div().min_w(18).h(18).px(5).flex().items_center().justify_center().rounded(5).border_1().border_color(t.border)
      .bg(strong ? t.selected : t.raised).text_size(10.5).text_color(strong ? t.accent : t.muted).child(p)));
}
// La tecla global que abre un mod o corre un comando (keys.json), o null
export function keyOf(action) {
  return keys().find((b) => b.section === "global" && b.action === action)?.keys ?? null;
}

// Texto con las letras que coincidieron en el color de acento
export function lit(t, text, hits, color) {
  if (!hits?.length) return div().truncate().text_color(color).child(text);
  const parts = [];
  let cur = "", on = false;
  [...text].forEach((ch, i) => {
    const h = hits.includes(i);
    if (h !== on && cur) { parts.push([cur, on]); cur = ""; }
    on = h;
    cur += ch;
  });
  if (cur) parts.push([cur, on]);
  return h_flex().min_w(0).overflow_hidden().children(parts.map(([s, h]) =>
    div().flex_none().text_color(h ? t.accent : color).when(h, (d) => d.font_semibold()).child(s.replace(/ /g, " "))));
}

export function pill(t, text, color) {
  return div().flex_none().max_w(190).px(7).h(18).flex().items_center().rounded(9).bg(color + "22").text_size(10.5).text_color(color)
    .child(div().min_w(0).truncate().child(text));
}

export function dot(t, status) {
  if (status === "working") return svg("mods/workspace-chrome/spinner.svg").size(11).flex_none().text_color(t.working).spin(900);
  const c = { blocked: t.blocked, waiting: t.blocked, pending: t.blocked, done: t.done, idle: t.idle, fail: t.ansi1, ok: t.done }[status] ?? t.dim;
  return div().size(7).flex_none().rounded_full().bg(c);
}

/**
 * Un panel: título, buscador, lista y pie con las teclas. La vista define:
 *   title, placeholder      textos
 *   hints()                 [[tecla, qué hace], …] para el pie
 *   async load(cx)          trae los datos (opcional); mientras, "leyendo…"
 *   rows()                  [{ head: "Grupo" } | { key, … }] ya filtradas por this.query. Ojo: en una fila, `h` es
 *                           su alto en px (por defecto ROW_H) y `head`/`note` son de las cabeceras: no los uses para otra cosa
 *   draw(t, row, on)        el contenido de una fila
 *   enter(row, cx, e)       Enter o clic
 *   key(e, row, cx)         otras teclas; devuelve true si la tomó
 *   side(t, row)            (opcional) lo que va a la derecha: una vista previa
 *   empty()                 qué decir sin filas
 * Para pedir un texto (la idea de un plan, la instrucción de un fix): this.askFor({ label, placeholder, run }).
 */
export class Panel extends View {
  init(_props, cx) {
    this.query = "";
    this.at = 0;
    this.scroll = 0;
    this.ask = null;
    this.loading = false;
    this.error = null;
    this.busy = null;
    this.listH = 420;
    this.setup?.(cx);
    this.input = InputState.new({ placeholder: this.placeholder ?? "Escribí para buscar…" });
    this.input.on("change", (_e, cx) => {
      if (this.ask) this.ask.value = this.input.value();
      else if (this.input.value() !== this.query) { this.query = this.input.value(); this.at = 0; this.scroll = 0; this.moved?.(cx); }
      cx.notify();
    });
    this.input.on("submit", (e, cx) => this.submit(cx, e));
    this.input.focus();
    cx.timer.after(30, () => this.input.focus());
    cx.timer.after(350, () => this.input.focus());
    this.handle = cx.focus_handle();
    if (this.load) this.reload(cx);
  }

  reload(cx) {
    this.loading = true;
    cx.spawn(async (cx) => {
      try { await this.load(cx); this.error = null; } catch (e) { this.error = String(e?.message ?? e); }
      this.loading = false;
      this.moved?.(cx);
      cx.notify();
    });
  }

  // Herdr llama a close() de la View cuando el overlay se va: que cerrar dos veces no haga nada
  close() {
    if (this.closed) return;
    this.closed = true;
    closeOverlay(props().overlay);
  }

  picks() { return this.rows().filter((r) => !r.head); }
  current() { const p = this.picks(); return p[Math.min(this.at, p.length - 1)] ?? null; }

  askFor(ask) {
    this.ask = { value: "", ...ask };
    this.input.set_value(ask.value ?? "");
    this.input.focus();
  }

  submit(cx, e) {
    if (this.ask) {
      const a = this.ask, text = (a.value ?? "").trim();
      if (!text && !a.optional) return;
      this.ask = null;
      this.input.set_value("");
      return a.run(text, cx);
    }
    const row = this.current();
    if (row) this.enter(row, cx, e);
  }

  // Corre algo corto mostrando "…" y deja el error a la vista si falla
  work(cx, label, fn) {
    this.busy = label;
    cx.notify();
    cx.spawn(async (cx) => {
      try { await fn(cx); this.error = null; } catch (e) { this.error = String(e?.message ?? e); }
      this.busy = null;
      cx.notify();
    });
  }

  onKey(e, cx) {
    const k = e.key, m = e.modifiers;
    const picks = this.picks();
    const page = Math.max(1, Math.floor(this.listH / ROW_H) - 1);
    if (k === "escape") {
      if (this.ask) { this.ask = null; this.input.set_value(this.query); }
      else if (this.query) { this.input.set_value(""); this.query = ""; this.at = 0; }
      else return this.close();
    } else if (this.ask) return;
    else if ((k === "down" && !m.shift) || (m.control && k === "n")) this.at = Math.min(this.at + 1, picks.length - 1);
    else if ((k === "up" && !m.shift) || (m.control && k === "p")) this.at = Math.max(this.at - 1, 0);
    else if (k === "pagedown") this.at = Math.min(this.at + page, picks.length - 1);
    else if (k === "pageup") this.at = Math.max(this.at - page, 0);
    else if (k === "home" && m.control) this.at = 0;
    else if (k === "end" && m.control) this.at = Math.max(0, picks.length - 1);
    else if (m.control && k === "r" && this.load) this.reload(cx);
    else if (this.key?.(e, this.current(), cx)) { /* la vista la tomó */ }
    else return;
    this.moved?.(cx);
    cx.stop_propagation();
    cx.notify();
  }

  list(t) {
    const rows = this.rows();
    const picks = rows.filter((r) => !r.head);
    this.at = Math.max(0, Math.min(this.at, picks.length - 1));
    const sel = picks[this.at];
    // Una sola tira: cada fila a una altura fija. El scroll se mueve lo justo para que la elegida se vea.
    const tops = [];
    let y = 0;
    for (const r of rows) { tops.push(y); y += r.head ? HEAD_H : (r.h ?? ROW_H); }
    const total = y, H = this.listH;
    const fixed = total > H;
    const max = Math.max(0, total - H);
    const hOf = (r) => (r.head ? HEAD_H : (r.h ?? ROW_H));
    const si = rows.indexOf(sel);
    if (si >= 0) {
      const from = si > 0 && rows[si - 1].head ? tops[si - 1] : tops[si];
      if (from < this.scroll) this.scroll = from;
      if (tops[si] + hOf(sel) > this.scroll + H) this.scroll = tops[si] + hOf(sel) - H;
    }
    this.scroll = Math.max(0, Math.min(this.scroll, max));
    const out = [];
    rows.forEach((r, i) => {
      const a = tops[i], b = a + hOf(r);
      if (fixed && !(b > this.scroll && a < this.scroll + H)) return;
      const place = (el) => (fixed ? el.absolute().left(0).right(0).top(a - this.scroll).bottom(H - (b - this.scroll)) : el.flex_none().h(b - a));
      if (r.head) {
        out.push(place(h_flex()).px(14).pb(5).gap(8).items_end().text_size(10.5).font_semibold().text_color(t.dim)
          .child(String(r.head).toUpperCase()).when(Boolean(r.note), (el) => el.child(div().font_normal().text_color(t.dim).child(r.note))));
        return;
      }
      const on = r === sel;
      out.push(place(h_flex()).id(`row-${r.key ?? i}`).mx(6).px(10).gap(10).items_center().rounded(8).cursor_pointer().text_size(13)
        .when(on, (el) => el.bg(t.selected)).hover((s) => s.bg(on ? t.selected : t.hover))
        .on_click((e, cx) => { this.at = picks.indexOf(r); this.enter(r, cx, e); cx.notify(); })
        .child(div().w(2).h(16).flex_none().rounded(1).bg(on ? t.accent : "#00000000"))
        .child(this.draw(t, r, on)));
    });
    const body = out.length
      ? div().id("panel-rows").relative().when(fixed, (el) => el.h(H).overflow_hidden()).when(!fixed, (el) => el.flex().flex_col())
          .on_scroll_wheel((e, cx) => {
            this.scroll = Math.max(0, Math.min(this.scroll - e.delta.y, max));
            while (this.at < picks.length - 1 && tops[rows.indexOf(picks[this.at])] < this.scroll) this.at++;
            while (this.at > 0 && tops[rows.indexOf(picks[this.at])] + ROW_H > this.scroll + H) this.at--;
            this.moved?.(cx);
            cx.notify();
          })
          .children(out)
      : div().px(16).py(18).text_size(13).text_color(this.error ? t.blocked : t.dim)
          .child(this.error ? this.error : this.loading ? "Leyendo…" : this.query.trim() ? `Nada coincide con «${this.query}»` : (this.empty?.() ?? "No hay nada para mostrar"));
    return { body, sel, count: picks.length };
  }

  render() {
    const t = theme();
    const wide = Boolean(this.side);
    const { body, sel, count } = this.ask ? { body: this.askBody(t), sel: null, count: 0 } : this.list(t);
    const hints = this.ask ? [["enter", this.ask.verb ?? "confirmar"], ["escape", "volver"]] : (this.hints?.(sel) ?? [["enter", "abrir"]]);
    const bar = h_flex().h(40).flex_none().px(12).gap(10).items_center().rounded(10).border_1()
      .border_color(this.ask ? t.blocked : t.accent).bg(t.background)
      .child(this.ask
        ? div().flex_none().px(8).h(22).flex().items_center().rounded(6).bg(t.blocked + "26").text_size(11.5).text_color(t.blocked).child(this.ask.label)
        : svg("mods/workspace-chrome/search.svg").size(15).flex_none().text_color(t.dim))
      .child(Input.new(this.input).flex_1().h_full().text_size(13.5).text_color(t.foreground))
      .when(Boolean(this.busy), (el) => el.child(h_flex().flex_none().gap(6).items_center().text_size(11.5).text_color(t.working)
        .child(svg("mods/workspace-chrome/spinner.svg").size(11).spin(900)).child(this.busy ?? "")))
      .when(!this.ask && !this.busy && count > 0, (el) => el.child(div().flex_none().text_size(11).text_color(t.dim).child(String(count))));
    const head = h_flex().flex_none().h(22).gap(8).items_center()
      .child(div().flex_none().size(8).rounded_full().bg(t.accent))
      .child(div().flex_none().text_size(13).font_semibold().text_color(t.foreground).child(this.title ?? "bk"))
      .when(Boolean(this.subtitle?.()), (el) => el.child(div().flex_1().min_w(0).truncate().text_size(12).text_color(t.dim).child(this.subtitle?.() ?? "")))
      .when(!this.subtitle?.(), (el) => el.child(div().flex_1()))
      .when(Boolean(this.error) && count > 0, (el) => el.child(div().flex_none().max_w(360).truncate().text_size(11.5).text_color(t.blocked).child(this.error ?? "")));
    const foot = h_flex().flex_none().h(26).px(4).gap(14).items_center().text_size(11).text_color(t.dim)
      .children(hints.map(([k, what]) => h_flex().flex_none().gap(6).items_center().child(chips(t, k)).child(what)));
    const listBox = v_flex().id("panel-list").min_h(0).when(wide, (el) => el.w(this.listW ?? 420).flex_none().h_full())
      .when(wide, (el) => el.on_size_change((size, cx) => {
        const h = Math.max(ROW_H * 3, Math.floor(size.height / (settings().zoom ?? 1)));
        if (h !== this.listH) { this.listH = h; cx.notify(); }
      }))
      .child(body);
    const main = wide
      ? h_flex().flex_1().min_h(0).gap(12).items_stretch().child(listBox)
          .child(v_flex().flex_1().min_w(0).min_h(0).rounded(10).border_1().border_color(t.border).bg(t.background).overflow_hidden().child(this.side(t, sel)))
      : listBox;
    return v_flex().id("bk-panel").track_focus(this.handle).w_full().min_h(0).when(wide, (el) => el.size_full())
      .p(16).gap(10).bg(t.popover).on_key_down((e, cx) => this.onKey(e, cx))
      .child(head).child(bar).child(main).child(foot);
  }

  askBody(t) {
    return v_flex().px(14).py(14).gap(6)
      .child(div().text_size(13).text_color(t.foreground).child(this.ask.title ?? this.ask.label))
      .when(Boolean(this.ask.help), (el) => el.child(div().text_size(12).text_color(t.dim).child(this.ask.help)));
  }
}

// La terminal viva del agente de bk con esa ventana (i42, pr57), o null. `project` desempata entre proyectos.
export function agentTerm(win, project) {
  if (!win) return null;
  return terminals().find((x) => x.state === "live" && x.labels?.["bk.kind"] === "agent" && x.labels?.["bk.win"] === win
    && (!project || !x.labels?.["bk.project"] || x.labels["bk.project"] === project)) ?? null;
}

// Mostrar la pestaña de una terminal: su espacio, su pestaña y el teclado en ella
export function reveal(term) {
  const space = term.labels?.["herdr.space"], tab = term.labels?.["herdr.tab"];
  if (space) run("space.select", { id: space });
  if (tab) run("tab.select", { id: tab });
  run("pane.focus", { terminal: term.address });
}

// Abrir en el navegador, solo direcciones de GitHub
export function openUrl(url) {
  return /^https:\/\/github\.com\//.test(url ?? "") ? exec("open", [url]) : Promise.resolve(null);
}
