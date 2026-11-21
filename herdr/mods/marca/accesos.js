// Los accesos directos de la cabecera de la barra izquierda: lo que sea que abras seguido (una página, una carpeta,
// un archivo, una app). Clic lo abre con `open`, como un doble clic en el Finder. Se agregan soltando archivos sobre
// la cabecera o con el + (pegás una URL o una ruta); el clic derecho abre la lista para sacar alguno.
// Se guardan en ~/.config/herdr-app/bk-accesos.json ([{ target, name, kind }]), que leen la cabecera y el popup.

import { div, svg } from "gpui-kit";
import { h_flex, v_flex, InputState, Input } from "gpui-base";
import { exec, notify, appHome, home, readTextFile, writeTextFile, shared, setShared, pickFolder, props, closeOverlay, theme } from "herdr";
import { al, tilde } from "./kit.js";

export const KEY = "bk.accesos";
const file = () => `${appHome()}/bk-accesos.json`;
const SCHEME = /^[a-z][a-z0-9+.-]*:\/\//i;
const BARE = /^(mailto|tel|sms|facetime|facetime-audio|x-apple\.systempreferences):/i;

// Lo que escribiste o pegaste → lo que se le pasa a `open`, o null si no parece ni URL ni ruta.
// «github.com/x» lleva https://, «localhost:3000» http://, «~/…» se expande y file:// se vuelve ruta.
export function normalize(raw, h = home()) {
  let s = String(raw ?? "").trim().replace(/^(["'])(.*)\1$/, "$2");
  if (!s || /[\u0000-\u001f]/.test(s)) return null;
  if (/^file:\/\//i.test(s)) { try { s = decodeURIComponent(s.slice(7)); } catch { return null; } }
  if (SCHEME.test(s) || BARE.test(s)) return s;
  if (s === "~" || s.startsWith("~/")) s = h + s.slice(1);
  if (s.startsWith("/")) return s.length > 1 ? s.replace(/\/+$/, "") : s;
  if (/\s/.test(s)) return null;
  if (/^(localhost|127\.0\.0\.1)(:\d+)?(\/.*)?$/i.test(s)) return "http://" + s;
  if (/^[\w-]+(\.[\w-]+)*\.[a-z]{2,}(:\d+)?([/?#].*)?$/i.test(s)) return "https://" + s;
  return null;
}

export const isUrl = (target) => SCHEME.test(target) || BARE.test(target);

// El nombre que se ve: el sitio sin www, la dirección de un mailto, o el último tramo de la ruta (sin .app).
export function nameOf(target) {
  if (/^https?:\/\//i.test(target)) {
    const m = target.match(/^https?:\/\/([^/?#:]+)/i);
    return (m?.[1] ?? target).replace(/^www\./i, "");
  }
  if (BARE.test(target)) return target.replace(BARE, "").replace(/^\/\//, "") || target;
  if (isUrl(target)) return target.replace(/:\/\/.*$/, "");
  const last = target.split("/").filter(Boolean).pop() ?? "/";
  return last.replace(/\.app$/i, "");
}

// web y link (otro esquema: obsidian://, slack://) llevan la inicial; carpeta, archivo y app, su icono
export function iconOf(kind) {
  return { folder: "mods/workspace-chrome/folder.svg", file: "mods/workspace-chrome/file-text.svg", app: "mods/bk-marca/app.svg" }[kind] ?? null;
}

export function parse(raw) {
  try {
    const l = JSON.parse(raw ?? "[]");
    return Array.isArray(l) ? l.filter((x) => typeof x?.target === "string" && x.target) : [];
  } catch { return []; }
}

export async function readList() {
  return parse(await readTextFile(file()));
}

// Lee, cambia y escribe; si otra copia escribió en el medio (writeTextFile rechaza), vuelve a leer.
export async function change(fn) {
  for (let i = 0; ; i++) {
    const raw = await readTextFile(file());
    const next = fn(parse(raw));
    try {
      await writeTextFile(file(), JSON.stringify(next, null, 2) + "\n", raw);
      setShared(KEY, next);
      return next;
    } catch (e) { if (i >= 2) throw e; }
  }
}

async function kindOf(target) {
  if (/^https?:\/\//i.test(target)) return "web";
  if (isUrl(target)) return "link";
  if (/\.app$/i.test(target)) return "app";
  const r = await exec("test", ["-d", target]).catch(() => ({ code: 1 }));
  return r.code === 0 ? "folder" : "file";
}

// Suma los que no estaban, al final. Devuelve cuántos sumó.
export async function add(targets) {
  const items = [];
  for (const target of targets) items.push({ target, name: nameOf(target), kind: await kindOf(target) });
  let added = 0;
  await change((list) => {
    const seen = new Set(list.map((x) => x.target));
    const fresh = items.filter((x) => !seen.has(x.target) && seen.add(x.target));
    added = fresh.length;
    return [...list, ...fresh];
  });
  return added;
}

export const remove = (target) => change((list) => list.filter((x) => x.target !== target));

export async function openTarget(target) {
  const r = await exec("open", [target]).catch((e) => ({ code: 1, stderr: String(e?.message ?? e) }));
  if (r.code !== 0) notify({ title: "No se pudo abrir", body: `${tilde(target)}${r.stderr ? "\n" + r.stderr.trim() : ""}`, level: "error" });
}

// La cara de un acceso: la inicial de un sitio, el icono de lo demás
export function face(t, a, size = 15) {
  const icon = iconOf(a.kind);
  if (icon) return svg(icon).size(size);
  return div().size(size + 3).flex().items_center().justify_center().rounded(5).border_1().border_color(al(t.accent, "66"))
    .bg(al(t.accent, "1c")).text_size(size - 4).line_height(1).font_bold().text_color(t.accent)
    .child((a.name || a.target).replace(/^www\./i, "").charAt(0).toUpperCase() || "·");
}

export const ROW = 30;
export const popupHeight = (n) => 104 + Math.min(Math.max(n, 1), 8) * ROW;

// El popup: pegar una URL o una ruta (⏎ la agrega), elegir una carpeta, soltar archivos, y la lista con su ×.
export class Gestor {
  constructor(cx) {
    this.list = shared(KEY) ?? null;
    this.error = null;
    this.input = InputState.new({ placeholder: "Pegá una URL o una ruta" });
    this.input.on("change", (_e, cx) => { if (this.error) { this.error = null; cx.notify(); } });
    this.input.on("submit", (_e, cx) => this.submit(cx));
    this.input.focus();
    cx.timer.after(30, () => this.input.focus());
    cx.spawn(async (cx) => { this.list = await readList(); cx.notify(); });
  }

  submit(cx) {
    const target = normalize(this.input.value());
    if (!target) { this.error = "No parece una URL ni una ruta"; cx.notify(); return; }
    this.input.set_value("");
    this.addAll(cx, [target]);
  }

  addAll(cx, targets) {
    cx.spawn(async (cx) => {
      try { await add(targets); this.list = shared(KEY) ?? await readList(); }
      catch (e) { this.error = `No se pudo guardar: ${e?.message ?? e}`; }
      cx.notify();
    });
  }

  render(cx) {
    const t = theme();
    const list = shared(KEY) ?? this.list ?? [];
    const stop = (_e, cx) => cx.stop_propagation();
    const row = (a) => h_flex().id(`acc-row-${a.target}`).h(ROW).flex_none().px(6).gap(8).items_center().rounded(6).cursor_pointer()
      .hover((s) => s.bg(t.hover)).on_click(() => { openTarget(a.target); closeOverlay(props().overlay); })
      .child(div().size(20).flex_none().flex().items_center().justify_center().text_color(t.muted).child(face(t, a, 14)))
      .child(div().flex_none().max_w(110).truncate().text_size(12).text_color(t.foreground).child(a.name || a.target))
      .child(div().flex_1().min_w(0).truncate().text_size(11).text_color(t.dim).child(tilde(a.target)))
      .child(div().id(`acc-x-${a.target}`).size(20).flex_none().flex().items_center().justify_center().rounded(5).text_color(t.dim)
        .hover((s) => s.bg(al(t.blocked, "26")).text_color(t.blocked)).tooltip("Quitar")
        .on_mouse_down("left", stop)
        .on_click((_e, cx) => { cx.stop_propagation(); cx.spawn(async (cx) => { await remove(a.target).catch(() => {}); this.list = shared(KEY); cx.notify(); }); })
        .child(svg("mods/workspace-chrome/x.svg").size(12)));
    return v_flex().id("accesos").size_full().p(10).gap(8).bg(t.popover)
      .on_drop((e, cx) => this.addAll(cx, (e.paths ?? []).map((p) => normalize(p)).filter(Boolean)))
      .child(h_flex().h(30).flex_none().px(8).gap(8).items_center().rounded(7).border_1().border_color(this.error ? t.blocked : t.input).bg(t.background)
        .child(Input.new(this.input).flex_1().h_full().text_size(12.5).text_color(t.foreground))
        .child(div().id("acc-folder").flex_none().px(6).h(22).flex().items_center().rounded(5).cursor_pointer().text_size(11).text_color(t.muted)
          .hover((s) => s.bg(t.hover).text_color(t.foreground)).tooltip("Elegir una carpeta")
          .on_click((_e, cx) => cx.spawn(async (cx) => { const p = await pickFolder({ prompt: "Agregar" }); if (p) this.addAll(cx, [p]); }))
          .child("Carpeta…")))
      .child(div().flex_none().text_size(11).text_color(this.error ? t.blocked : t.dim)
        .child(this.error ?? "⏎ agrega · soltá archivos o apps acá o sobre la cabecera"))
      .child(div().h(1).flex_none().bg(t.border))
      .child(v_flex().id("acc-list").flex_1().min_h(0).overflow_y_scroll()
        .when(list.length === 0, (el) => el.child(div().pt(6).px(6).text_size(11.5).text_color(t.dim).child("Todavía no hay accesos directos.")))
        .children(list.map(row)));
  }
}
