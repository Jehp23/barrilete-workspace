// alt+,: el aspecto de la ventana, con el cambio a la vista: tema, paneles, tamaño y fuente de la terminal.
// Enter aplica y el panel queda abierto, para probar varios. El tema y el tamaño son comandos de Herdr; la fuente
// es `font` de settings.json (la de la persona), que solo manda si el layout a la vista no fija la suya: cuando la
// fija, se guarda igual (vale en los otros layouts) y el panel lo dice en vez de fingir que cambió.

import { div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { run, themes, fonts, settings, layout, layouts, shared, appHome, readTextFile, writeTextFile } from "herdr";
import { Panel, rank, lit, pill } from "./kit.js";

const GROUPS = ["Tema", "Paneles", "Tamaño", "Fuente de la terminal", "Herdr"];
const FONTS = ["SF Mono", "JetBrains Mono", "Geist Mono", "Menlo"];
const DEFAULT_FONT = "JetBrains Mono";   // la que usa Herdr si settings.json no nombra ninguna
const SWATCH = ["accent", "working", "blocked", "done", "background"];
const MANY = 10;   // un layout que fija tantos colores tapa casi todo el tema

function find(node, id) {
  if (node?.id === id) return node;
  for (const child of node?.children ?? []) {
    const found = find(child, id);
    if (found) return found;
  }
  return null;
}

// settings.json con una clave cambiada y todo lo demás igual. Tira si el archivo no es un objeto JSON.
export function withSetting(raw, key, value) {
  const s = raw ? JSON.parse(raw) : {};
  if (!s || typeof s !== "object" || Array.isArray(s)) throw new Error("settings.json no es un objeto");
  return JSON.stringify({ ...s, [key]: value }, null, 2) + "\n";
}
export const withFont = (raw, font) => withSetting(raw, "font", font);

export default class Look extends Panel {
  setup() {
    this.title = "Aspecto";
    this.placeholder = "Tema, fuente, tamaño, paneles…";
    this.person = {};    // settings.json como está escrito (lo que eligió la persona)
    this.said = null;    // qué pasó con lo último que se aplicó
    const have = new Set(fonts());
    this.fonts = FONTS.filter((f) => have.has(f));
    // Abre parado en el tema actual: un Enter de más no cambia nada
    this.at = Math.max(0, this.rows().filter((r) => !r.head).findIndex((r) => r.kind === "theme" && r.on));
  }

  async load() {
    const raw = await readTextFile(`${appHome()}/settings.json`);
    try { this.person = raw ? JSON.parse(raw) : {}; } catch (_e) { this.person = {}; }
  }

  now() {
    const s = settings(), root = layout() ?? {};
    return {
      name: String(shared("layout") ?? ""), dark: Boolean(s.dark), theme: s.dark ? s.theme_dark : s.theme_light,
      font: s.font_family ?? DEFAULT_FONT, fixed: typeof root.font === "string" ? root.font : null,
      own: Object.keys(root.colors ?? {}).length, zoom: Math.round((s.zoom ?? 1) * 100), root,
    };
  }

  subtitle() {
    if (this.said) return this.said;
    const n = this.now();
    return [n.name, n.theme, n.font, `${n.zoom} %`].filter(Boolean).join(" · ");
  }

  moved() { this.said = null; }

  rows() {
    const n = this.now();
    const all = layouts();
    const mine = this.person?.font ?? DEFAULT_FONT;
    const list = [];
    // Un tema que se llama como un layout es de ese layout (themes/win98.json): solo se ofrece ahí
    for (const x of themes().filter((x) => x.name === n.name || !all.includes(x.name))) {
      list.push({
        key: `theme:${x.name}`, group: "Tema", kind: "theme", title: x.name.replace(/-/g, " "), x, on: x.name === n.theme,
        tag: Boolean(x.light) === n.dark ? (x.light ? "claro" : "oscuro") : "", words: `theme colores ${x.light ? "claro light" : "oscuro dark"}`,
        verb: "probar este tema", go: (cx) => this.pick(x, n, cx),
      });
    }
    const toggle = (id, what, words) => {
      const node = find(n.root, id);
      if (node) list.push({ key: `toggle:${id}`, group: "Paneles", title: `${node.hidden ? "Mostrar" : "Ocultar"} ${what}`, hint: node.hidden ? "ahora no se ve" : "a la vista", words, go: () => run("layout.toggle", { id }) });
    };
    toggle("sidebar", "la barra izquierda", "sidebar espacios agentes");
    toggle("lado", "el panel derecho", "github cambios estado lado");
    list.push({ key: "layout", group: "Paneles", title: "Siguiente layout", hint: `ahora ${n.name}${all.length ? ` · hay ${all.length}` : ""}`, words: "layout switch ventana", go: () => run("layout.switch") });
    list.push({ key: "zoom:in", group: "Tamaño", title: "Agrandar", words: "zoom más grande", go: () => run("app.zoom_in") });
    list.push({ key: "zoom:out", group: "Tamaño", title: "Achicar", words: "zoom más chico", go: () => run("app.zoom_out") });
    list.push({ key: "zoom:reset", group: "Tamaño", title: "Restablecer", hint: "100 %", words: "zoom normal reset", go: () => run("app.zoom_reset") });
    for (const f of this.fonts) {
      list.push({
        key: `font:${f}`, group: "Fuente de la terminal", kind: "font", title: f, on: f === n.font, mine: f === mine && f !== n.font,
        words: "font letra tipografía", verb: "usar esta fuente", go: (cx) => this.font(f, cx),
      });
    }
    list.push({ key: "settings", group: "Herdr", title: "Ajustes de Herdr", hint: "layouts, sonidos, máquinas…", words: "settings preferencias", verb: "abrir", go: () => { this.close(); run("app.settings"); } });

    if (this.query.trim()) return rank(list, this.query, (r) => [r.title, `${r.group} ${r.words ?? ""}`]).map(({ item, hits }) => ({ ...item, hits }));
    const notes = {
      "Tema": n.own >= MANY ? `${n.name} pinta sus colores encima: casi no se nota` : n.own ? `${n.name} fija ${n.own} colores` : "",
      "Tamaño": `${n.zoom} %`,
      "Fuente de la terminal": n.fixed ? `la fija el layout ${n.name}: acá no cambia` : this.fonts.includes(n.font) ? "" : `ahora ${n.font}`,
    };
    const rows = [];
    for (const g of GROUPS) {
      const members = list.filter((r) => r.group === g);
      if (members.length) rows.push({ head: g, note: notes[g] ?? "" }, ...members);
    }
    return rows;
  }

  draw(t, r, on) {
    const fg = on ? t.foreground : t.muted;
    const right = (text) => div().flex_none().text_size(11.5).text_color(t.dim).child(text);
    if (r.kind === "theme") {
      return h_flex().flex_1().min_w(0).gap(12).items_center()
        .child(h_flex().flex_none().gap(4).items_center().children(SWATCH.map((c) =>
          div().size(11).flex_none().rounded_full().border_1().border_color(t.border).bg(r.x.colors[c] ?? t.dim))))
        .child(div().flex_1().min_w(0).child(lit(t, r.title, r.hits, r.on ? t.foreground : fg)))
        .when(Boolean(r.tag), (el) => el.child(right(r.tag)))
        .when(r.on, (el) => el.child(pill(t, "actual", t.accent)));
    }
    if (r.kind === "font") {
      return h_flex().flex_1().min_w(0).gap(12).items_center()
        .child(div().w(150).flex_none().truncate().font_family(r.title).text_size(13.5).text_color(r.on ? t.foreground : fg).child(r.title))
        .child(div().flex_1().min_w(0).truncate().font_family(r.title).text_size(12.5).text_color(t.dim).child("bk run 42 → {ok} 0O 1lI"))
        .when(r.mine, (el) => el.child(pill(t, "la tuya", t.muted)))
        .when(r.on, (el) => el.child(pill(t, "en uso", t.accent)));
    }
    return h_flex().flex_1().min_w(0).gap(12).items_center()
      .child(div().flex_1().min_w(0).child(lit(t, r.title, r.hits, fg)))
      .when(Boolean(r.hint), (el) => el.child(right(r.hint ?? "")));
  }

  hints(row) { return [["enter", row?.verb ?? "hacer"], ["up", ""], ["down", "elegir"], ["escape", "cerrar"]]; }

  enter(row, cx) { row.go(cx); }

  // app.theme cambia la mitad (clara u oscura) del tema; lo que se ve depende de la apariencia y del layout. Un
  // tema de la otra claridad (bk-dia con la apariencia oscura) pasa además la apariencia a la suya: si no, no se
  // vería. settings.json guarda esa apariencia (`appearance`); volver a un tema oscuro la vuelve a oscura.
  pick(x, n, cx) {
    const flip = Boolean(x.light) === n.dark;
    this.work(cx, flip ? "cambiando la apariencia…" : "aplicando…", async () => {
      if (flip) await this.save("appearance", x.light ? "light" : "dark");
      run("app.theme", { name: x.name });
      this.said = n.own >= MANY ? `tema ${x.name}, pero ${n.name} pinta sus colores encima`
        : flip ? `tema: ${x.name} (apariencia ${x.light ? "clara" : "oscura"})` : `tema: ${x.name}`;
    });
  }

  // Leer settings.json, cambiar solo esa clave y escribir si nadie lo tocó mientras tanto (si lo tocaron, se lee
  // de nuevo)
  async save(key, value) {
    const path = `${appHome()}/settings.json`;
    for (let attempt = 0; ; attempt++) {
      const raw = await readTextFile(path);
      let next;
      try { next = withSetting(raw, key, value); } catch (e) { throw new Error(`no toqué settings.json: ${e?.message ?? e}`); }
      try {
        if (next !== raw) await writeTextFile(path, next, raw);
        this.person = JSON.parse(next);
        return;
      } catch (e) {
        if (attempt >= 2) throw e;
      }
    }
  }

  font(name, cx) {
    this.work(cx, "guardando…", async () => {
      await this.save("font", name);
      const n = this.now();
      this.said = n.fixed && n.fixed !== name ? `${n.name} fija ${n.fixed}: ${name} se ve en los otros layouts` : `fuente de la terminal: ${name}`;
    });
  }
}
