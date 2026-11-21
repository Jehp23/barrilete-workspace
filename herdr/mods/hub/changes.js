// alt+g: lo que quedó sin commitear en el proyecto que mirás y en los worktrees de los agentes, con su diff al lado.
// ↑/↓ eligen el archivo; ctrl+j / ctrl+k (o shift+↓ / shift+↑) mueven el diff, la rueda también; Enter abre el archivo
// en un pane visor al lado de la terminal en foco. Un clic elige la fila; otro clic sobre la elegida la abre.
// Los datos: bk _hub changes y bk _hub diff.
// Con props { diff: { root, path, code, add, del } } es el popup del diff de un archivo (lo abre la pestaña Cambios del
// panel derecho, mods/lado): el mismo dibujo del diff, con la rueda para moverlo; esc lo cierra.
// El visor es este mismo mod puesto como pane: pane.split { mod: "bk-changes", props: { file } }. Muestra el archivo
// con el editor de solo lectura de Herdr, como el visor del mod files.

import { div } from "gpui-kit";
import { v_flex, h_flex, Editor, EditorState } from "gpui-base";
import { theme, settings, props, run, focused, notify, readTextFile } from "herdr";
import { Panel, rank, bk, cwd, tilde, plural, lit } from "./kit.js";
import { VIEW } from "./view.js";

const FS = 12, LH = 19;           // cuerpo y alto de una línea del diff
const CW = FS * 0.6;               // ancho de un carácter monoespaciado (aproximado: solo mide el scroll de costado)
const COLS = 400;                  // caracteres que se pintan por línea, como mucho
const TABS = 64;                   // tabs que se alinean por línea; en una tabla de datos, el resto va como un espacio
const NBSP = "\u00a0";
const LANG = { ts: "js", tsx: "js", mts: "js", cts: "js", jsx: "js", mjs: "js", toml: "yaml", jsonc: "json", svelte: "html", vue: "html" };

const clamp = (n, lo, hi) => Math.max(lo, Math.min(n, hi));
// El texto dibuja un tab como nada: se rellena hasta la siguiente columna múltiplo de 4
function untab(s) {
  if (!s.includes("\t")) return s;
  const parts = s.split("\t"), n = Math.min(parts.length - 1, TABS);
  let out = "";
  for (let i = 0; i < n; i++) { out += parts[i]; out += " ".repeat(4 - (out.length % 4)); }
  return out + parts.slice(n).join(" ");
}

// La letra de estado de git status: conflicto y borrado antes que agregado; el resto, su primera letra
function letter(code) {
  const c = code ?? "";
  if (c.includes("U") || c === "AA" || c === "DD") return "U";
  if (c.includes("D")) return "D";
  if (c.includes("A")) return "A";
  return c.slice(0, 1) || "M";
}
const tone = (t, l) => ({ U: t.ansi1, D: t.ansi1, A: t.done, "?": t.dim })[l] ?? t.ansi3;

// +n verde y −n rojo: en columnas en la lista, juntos en la cabecera del diff
function counts(t, f, cols = true) {
  const cell = (w, color, text) => div().when(cols, (el) => el.w(w).text_right()).text_color(color).child(text);
  return h_flex().flex_none().text_size(11.5).when(!cols, (el) => el.gap(8))
    .when(cols || f.add > 0, (el) => el.child(cell(42, t.done, f.add > 0 ? `+${f.add}` : "")))
    .when(cols || f.del > 0, (el) => el.child(cell(38, t.ansi1, f.del > 0 ? `−${f.del}` : "")));
}

// Lo que devuelve bk _hub diff, listo para dibujar: cada línea con su número (el viejo en las que salen, el nuevo
// en el resto) y sin tabs; el ancho de la más larga y cuántas cifras lleva el número más grande.
function prep(d) {
  let old = 0, now = 0, wide = 0;
  const lines = (d.lines ?? []).map(({ t, s }) => {
    let n = null;
    if (t === "@") { const m = /^@@ -(\d+)(?:,\d+)? \+(\d+)/.exec(s ?? ""); if (m) { old = +m[1]; now = +m[2]; } }
    else if (t === "-") n = old++;
    else if (t === "+") n = now++;
    else if (t === " ") { old++; n = now++; }
    const text = untab(s ?? "");
    wide = Math.max(wide, text.length);
    return { t, n, s: text };
  });
  if (d.truncated) lines.push({ t: "h", n: null, s: `… el diff sigue: se muestran las primeras ${lines.length} líneas` });
  return { lines, wide, digits: String(Math.max(old, now, 1)).length };
}

// La línea desde la columna `col`, sin partir un carácter de dos mitades (un emoji) ni comerse los espacios
function cut(s, col) {
  let a = Math.min(col, s.length);
  if (a > 0 && a < s.length && s.charCodeAt(a) >= 0xdc00 && s.charCodeAt(a) <= 0xdfff) a++;
  return s.slice(a, a + COLS).replace(/ /g, NBSP) || NBSP;
}

// Un tramo de la ruta con las letras que coincidieron resaltadas, en pedazos que no se achican
function spans(t, text, hits, color) {
  const out = [];
  let cur = "", on = false;
  [...text].forEach((ch, i) => {
    const h = hits.includes(i);
    if (h !== on && cur) { out.push([cur, on]); cur = ""; }
    on = h;
    cur += ch;
  });
  if (cur) out.push([cur, on]);
  return out.map(([s, h]) => div().flex_none().text_color(h ? t.accent : color).when(h, (el) => el.font_semibold()).child(s.replace(/ /g, NBSP)));
}

export default class Changes extends Panel {
  init(p, cx) {
    this.file = p?.file ?? props()?.file ?? null;   // con un archivo en las props, esta copia es el visor
    if (this.file) return this.readFile(cx);
    const d = p?.diff ?? props()?.diff ?? null;      // con un diff, el popup del diff de ese archivo
    if (d) {
      this.pane = { key: "diff", root: { path: d.root }, f: { path: d.path, code: d.code ?? "M", add: d.add ?? 0, del: d.del ?? 0 } };
      this.cache = new Map(); this.shown = "diff";
      this.dY = 0; this.dX = 0; this.dH = 520; this.dW = 700;
      return this.readDiff(cx);
    }
    super.init(p, cx);
  }

  setup() {
    this.title = "Cambios";
    this.placeholder = "Buscar por ruta…";
    this.dir = cwd();
    this.data = { roots: [] };
    this.memo = null;        // las filas de la última búsqueda
    this.cache = new Map();  // clave de fila → diff listo, o { error }
    this.gen = 0;            // sube con cada recarga: un diff pedido antes ya no vale
    this.shown = null;       // la fila cuyo diff se mira
    this.dY = 0; this.dX = 0;        // scroll del diff, en px
    this.dH = 520; this.dW = 700;    // tamaño de su ventana, hasta que se mida
  }

  async load() {
    const data = await bk(["_hub", "changes", this.dir], { json: true, timeout: 25000 });
    this.data = data;
    this.gen++;
    this.cache = new Map();
    this.shown = null;
  }

  rows() {
    if (this.memo && this.memo.q === this.query && this.memo.data === this.data) return this.memo.rows;
    const rows = [];
    (this.data.roots ?? []).forEach((root, ri) => {
      const found = rank(root.files ?? [], this.query, (f) => f.path);
      if (!found.length) return;
      rows.push({ head: root.name, note: [root.branch, plural(found.length, "archivo", "archivos")].filter(Boolean).join(" · ") });
      for (const { item, hits } of found) rows.push({ key: `${ri}:${item.path}`, root, f: item, hits });
    });
    this.memo = { q: this.query, data: this.data, rows };
    return rows;
  }

  total() { return (this.data.roots ?? []).reduce((n, r) => n + (r.files?.length ?? 0), 0); }

  subtitle() {
    const n = this.total();
    return [n ? `${plural(n, "archivo", "archivos")} sin commitear` : null, tilde(this.dir)].filter(Boolean).join(" · ");
  }

  empty() { return this.query.trim() ? `Nada coincide con «${this.query}»` : "✓ Todo guardado en Git"; }

  hints(row) {
    const open = row && letter(row.f.code) !== "D" ? [["enter", "abrir"]] : [];
    const diff = row ? [["ctrl-j", "bajar el diff"], ["ctrl-k", "subir"]] : [];
    return [...open, ...diff, ["ctrl-r", "recargar"], ["escape", "cerrar"]];
  }

  draw(t, r, on) {
    const f = r.f, l = letter(f.code);
    const at = f.path.lastIndexOf("/") + 1, dir = f.path.slice(0, at), name = f.path.slice(at);
    const hits = r.hits ?? [], inDir = hits.filter((i) => i < at), inName = hits.filter((i) => i >= at).map((i) => i - at);
    // La carpeta cede el lugar antes que el nombre y se corta por el principio: el nombre del archivo siempre se lee
    const folder = (inDir.length
      ? h_flex().overflow_hidden().justify_end().children(spans(t, dir, inDir, t.dim))
      : div().overflow_hidden().whitespace_nowrap().text_ellipsis_start().text_right().text_color(t.dim).child(dir)).min_w(0).flex_shrink(100);
    return h_flex().flex_1().min_w(0).gap(8).items_center()
      .child(div().w(10).flex_none().text_size(12).font_semibold().text_color(tone(t, l)).child(l))
      .child(h_flex().flex_1().min_w(0)
        .when(Boolean(dir), (el) => el.child(folder))
        .child(div().min_w(0).child(lit(t, name, inName, on ? t.foreground : t.muted))))
      .child(counts(t, f));
  }

  // Cambió la fila elegida: su diff, guardado por archivo. Una respuesta que llega tarde queda guardada pero no se
  // muestra (lo que se ve sale siempre de la fila elegida), y la de antes de una recarga se descarta.
  moved(cx) {
    const row = this.current(), key = row?.key ?? null;
    if (key === this.shown) return;
    const first = this.shown === null;
    this.shown = key;
    this.dY = 0; this.dX = 0;
    if (!row || this.cache.has(key)) return;
    const gen = this.gen;
    cx.spawn(async (cx) => {
      if (!first) await cx.sleep(90);   // con ↓ apretada no se pide el diff de cada fila que pasa
      if (gen !== this.gen || this.shown !== key || this.cache.has(key)) return;
      let d;
      try { d = prep(await bk(["_hub", "diff", row.root.path, row.f.path], { json: true, timeout: 15000 })); }
      catch (e) { d = { error: String(e?.message ?? e) }; }
      if (gen !== this.gen) return;
      this.cache.set(key, d);
      if (this.shown === key) cx.notify();
    });
  }

  maxY(d) { return Math.max(0, d.lines.length * LH - this.dH); }
  maxX(d) { return Math.max(0, Math.ceil((d.wide + 6) * CW + this.gutter(d) - this.dW)); }
  gutter(d) { return d.digits * CW + 20 + CW * 2; }   // el número y el signo

  // Mueve el diff que se mira; false si no había nada que mover
  scrollDiff(dy, dx) {
    const d = this.cache.get(this.shown);
    if (!d?.lines) return false;
    const y = clamp(this.dY + dy, 0, this.maxY(d)), x = clamp(this.dX + dx, 0, this.maxX(d));
    if (y === this.dY && x === this.dX) return false;
    this.dY = y; this.dX = x;
    return true;
  }

  // ctrl+j / ctrl+k y shift+↓ / shift+↑ van antes que las teclas del panel: ↓ sola elige la fila de abajo
  onKey(e, cx) {
    const k = e.key, m = e.modifiers;
    const way = (m.control && k === "j") || (m.shift && k === "down") ? 1 : (m.control && k === "k") || (m.shift && k === "up") ? -1 : 0;
    if (!way || this.ask) return super.onKey(e, cx);
    this.scrollDiff(way * Math.max(3, Math.floor(this.dH / LH / 3)) * LH, 0);   // un tercio de lo que se ve
    cx.stop_propagation();
    cx.notify();
  }

  enter(r, cx, e) {
    if (e?.click_count != null && r.key !== this.shown) return this.moved(cx);   // un clic solo elige
    const path = `${r.root.path}/${r.f.path}`;
    if (letter(r.f.code) === "D") return notify({ title: "Cambios", body: `${r.f.path} está borrado: no hay archivo para abrir`, level: "info" });
    const pane = focused()?.pane, mod = `bk-${VIEW}`;
    this.close();
    if (pane) run("pane.split", { direction: "right", pane, mod, props: { file: path } });
    else run("tab.new", { name: r.f.path.split("/").pop(), mod, props: { file: path } });   // sin pane en foco: en una pestaña
  }

  side(t, row) {
    if (!row) return this.blank(t);
    const f = row.f, l = letter(f.code), d = this.cache.get(row.key);
    const lines = d?.lines ?? null;
    const H = this.dH, y = lines ? Math.min(this.dY, this.maxY(d)) : 0;
    const from = lines ? Math.floor(y / LH) : 0, to = lines ? Math.min(lines.length, Math.ceil((y + H) / LH)) : 0;
    const head = h_flex().flex_none().h(36).px(14).gap(10).items_center().border_b(1).border_color(t.border)
      .child(div().flex_none().text_size(12).font_semibold().text_color(tone(t, l)).child(l))
      .child(div().flex_1().min_w(0).overflow_hidden().whitespace_nowrap().text_ellipsis_start().text_size(12.5).text_color(t.muted).child(tilde(`${row.root.path}/${f.path}`)))
      .when(lines && this.maxY(d) > 0, (el) => el.child(div().flex_none().text_size(11).text_color(t.dim).child(`${from + 1}–${to} de ${lines.length}`)))
      .child(counts(t, f, false));
    const view = div().id("diff-view").relative().flex_1().min_h(0).overflow_hidden()
      .on_size_change((size, cx) => {
        const z = settings().zoom ?? 1, h = Math.floor(size.height / z), w = Math.floor(size.width / z);
        if (h !== this.dH || w !== this.dW) { this.dH = h; this.dW = w; cx.notify(); }
      })
      .on_scroll_wheel((e, cx) => {
        const z = settings().zoom ?? 1, dx = (e.delta?.x ?? 0) / z, dy = (e.delta?.y ?? 0) / z;
        const moved = Math.abs(dy) >= Math.abs(dx) ? this.scrollDiff(-dy, 0) : this.scrollDiff(0, -dx);   // un eje por gesto
        cx.stop_propagation();
        if (moved) cx.notify();
      });
    // El aire de arriba y de abajo va por fuera de la ventana: las líneas se cortan en un borde limpio
    const body = lines ? view.children(this.diffRows(t, d, y, from, to))
      : view.child(div().px(14).py(6).text_size(13).text_color(d?.error ? t.blocked : t.dim).child(d?.error ?? "Leyendo…"));
    return v_flex().size_full().min_h(0).child(head).child(v_flex().flex_1().min_h(0).py(6).child(body));
  }

  // Solo las líneas que entran en la ventana, cada una a su altura; y la marca de por dónde va el scroll
  diffRows(t, d, y, from, to) {
    const col = Math.round(Math.min(this.dX, this.maxX(d)) / CW), numW = d.digits * CW + 20, max = this.maxY(d);
    const font = settings().font_family ?? "JetBrains Mono";
    const out = [];
    for (let i = from; i < to; i++) {
      const l = d.lines[i];
      const [color, bg] = l.t === "+" ? [t.done, t.done + "22"] : l.t === "-" ? [t.ansi1, t.ansi1 + "22"]
        : l.t === "@" ? [t.accent, null] : l.t === "h" ? [t.dim, null] : [t.muted, null];
      out.push(h_flex().absolute().left(0).right(0).top(i * LH - y).h(LH).pr(12).items_center()
        .font_family(font).text_size(FS).text_color(color)
        .when(Boolean(bg), (el) => el.bg(bg))
        .child(div().w(numW).flex_none().pr(8).text_right().text_color(t.dim).child(l.n === null ? "" : String(l.n)))
        .child(div().w(CW * 2).flex_none().child(l.t === "+" || l.t === "-" ? l.t : ""))
        .child(div().flex_1().min_w(0).overflow_hidden().whitespace_nowrap().child(cut(l.s, col))));
    }
    if (max > 0) {
      const h = Math.max(28, Math.round(this.dH * this.dH / (max + this.dH)));
      out.push(div().absolute().right(3).top(Math.round((this.dH - h) * (y / max))).w(4).h(h).rounded(2).bg(t.dim + "66"));
    }
    return out;
  }

  // Sin fila elegida: nada que comparar
  blank(t) {
    const clean = !this.loading && !this.error && !this.total();
    return v_flex().size_full().items_center().justify_center().gap(8).px(24)
      .when(clean, (el) => el
        .child(div().text_size(30).text_color(t.done).child("✓"))
        .child(div().text_size(13).text_color(t.muted).child("No hay nada sin commitear"))
        .child(div().text_size(11.5).text_color(t.dim).child("Ni en el proyecto ni en los worktrees de los agentes.")));
  }

  // ---------- el visor: esta copia como pane, con props { file } ----------

  readFile(cx) {
    cx.spawn(async (cx) => {
      const say = (note) => { this.code?.release(); this.code = null; this.note = note; };
      try {
        let text = await readTextFile(this.file);
        if (text === null) say("Ese archivo ya no está.");
        else if (text.includes("\0")) say("Es un binario: no hay texto para mostrar.");
        else {
          if (text.length > 400000) text = text.slice(0, 400000) + "\n… (cortado: el archivo es muy largo)";
          if (this.code) this.code.set_value(text);
          else {
            const t = theme(), ext = /\.([^./]+)$/.exec(this.file)?.[1] ?? "txt";
            this.code = EditorState.new({ language: LANG[ext] ?? ext, readonly: true, value: text,
              font_family: settings().font_family, font_size: FS,
              syntax: { keyword: t.ansi5, string: t.ansi2, comment: t.dim, function: t.ansi4, type: t.ansi3, number: t.ansi1, constant: t.ansi6 } });
          }
          this.note = null;
        }
      } catch { say("No se puede mostrar: es muy grande o no se puede leer."); }
      cx.notify();
    });
  }

  viewer(t) {
    return v_flex().id("bk-file").size_full().min_h(0).bg(t.background).text_size(12.5)
      .child(h_flex().flex_none().h(32).pl(14).pr(8).gap(10).items_center().border_b(1).border_color(t.border)
        .child(div().flex_1().min_w(0).overflow_hidden().whitespace_nowrap().text_ellipsis_start().text_color(t.muted).child(tilde(this.file)))
        .child(div().id("file-reload").flex_none().px(8).h(20).flex().items_center().rounded(6).cursor_pointer()
          .text_size(11).text_color(t.dim).hover((s) => s.bg(t.hover)).on_click((_e, cx) => this.readFile(cx)).child("recargar")))
      .child(this.code ? Editor.new(this.code).flex_1().min_h(0)
        : div().px(14).py(12).text_size(13).text_color(t.dim).child(this.note ?? "Leyendo…"));
  }

  // ---------- el popup del diff: esta copia con props { diff } ----------

  readDiff(cx) {
    const row = this.pane;
    cx.spawn(async (cx) => {
      let d;
      try { d = prep(await bk(["_hub", "diff", row.root.path, row.f.path], { json: true, timeout: 15000 })); }
      catch (e) { d = { error: String(e?.message ?? e) }; }
      this.cache.set("diff", d);
      cx.notify();
    });
  }

  diffPane(t) {
    return v_flex().id("bk-diff").size_full().min_h(0).bg(t.background).text_size(12.5)
      .child(v_flex().flex_1().min_h(0).child(this.side(t, this.pane)))
      .child(h_flex().flex_none().h(26).px(14).gap(12).items_center().border_t(1).border_color(t.border).text_size(11).text_color(t.dim)
        .child(div().flex_1().child("la rueda mueve el diff · esc cierra"))
        .child(div().id("diff-reload").px(8).h(20).flex().items_center().rounded(6).cursor_pointer().hover((s) => s.bg(t.hover))
          .on_click((_e, cx) => { this.cache.delete("diff"); this.dY = 0; this.dX = 0; this.readDiff(cx); cx.notify(); }).child("recargar")));
  }

  render() { return this.file ? this.viewer(theme()) : this.pane ? this.diffPane(theme()) : super.render(); }

  // Herdr llama a close() cuando la copia se va: el visor suelta su editor; el panel cierra su overlay
  close() {
    if (this.pane) return;   // el popup del diff lo cierra Herdr (esc o clic afuera)
    if (!this.file) return super.close();
    this.code?.release();
    this.code = null;
  }
}
