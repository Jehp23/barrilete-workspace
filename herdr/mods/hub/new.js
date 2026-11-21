// alt+n: crear sin salir de donde estás. Un chat más del proyecto que mirás (común, en una rama aparte o con
// nombre), el resumen del chat que mirás para seguir en uno nuevo (abre alt+h), una terminal, un chat suelto,
// seguir desde un resumen listo (se ven los 3 más nuevos; buscando, todos)
// u otro proyecto (bk muestra su espacio, o lo crea con su chat). Si escribís una ruta (/… o ~/…), la primera fila
// abre esa carpeta. Lo hace todo bk (bk chat, bk open). Los datos: bk _hub projects y handoffs; los títulos de los
// resúmenes salen de bk _hub sessions.

import { div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { exec, run, home, focused, agents } from "herdr";
import { Panel, rank, bk, launch, goto, cwd, tilde, lit, pill, ago } from "./kit.js";

const READY = 3;   // cuántos resúmenes se ven sin buscar (los más nuevos; buscando aparecen todos)
const last = (path) => path.replace(/\/+$/, "").split("/").pop() || "/";
// El nombre que bk le da al proyecto de esa raíz (project_of de bin/bk)
const nameOf = (top) => last(top).replace(/[.:]/g, "_");

// La raíz del proyecto de una carpeta, como project_top de bin/bk: el repo, o el repo principal si es un worktree
// de <repo>-wt/. Fuera de un repo, la carpeta misma.
async function projectTop(dir) {
  let top = dir.replace(/(.)\/+$/, "$1");
  try {
    const r = await exec("git", ["-C", dir, "rev-parse", "--show-toplevel"], { timeout: 4000 });
    if (r.code === 0 && r.stdout.trim()) top = r.stdout.trim();
  } catch (_) { /* sin git o sin carpeta: queda la carpeta */ }
  const parts = top.split("/"), parent = parts[parts.length - 2] ?? "";
  if (!parent.endsWith("-wt")) return top;
  const main = [...parts.slice(0, -2), parent.slice(0, -3)].join("/");
  try { return (await exec("test", ["-d", main], { timeout: 2000 })).code === 0 ? main : top; } catch (_) { return top; }
}

// "~/x" y "/x" son rutas; "~otro" no (la carpeta de otro usuario no se resuelve acá)
function pathOf(text) {
  const q = text.trim();
  if (q === "~" || q.startsWith("~/")) return home() + q.slice(1);
  return q.startsWith("/") ? q : null;
}

export default class New extends Panel {
  setup() {
    this.title = "Nuevo";
    this.placeholder = "Qué crear, un proyecto o una ruta (~/…)";
    this.dir = cwd();
    this.top = null;      // la raíz del proyecto de this.dir (cuando se sabe)
    this.projects = [];
    this.handoffs = [];
    this.titles = {};     // sid → título de la sesión
    const term = focused()?.terminal;   // ¿la terminal que mirás es un chat? (alt+h pide su resumen)
    this.inChat = Boolean(term) && agents().some((a) => a.address === term);
  }

  subtitle() { return "desde " + tilde(this.dir); }

  async load() {
    const get = (topic) => bk(["_hub", topic], { json: true, timeout: 10000 });
    const [top, projects, handoffs, sessions] = await Promise.all([
      projectTop(this.dir), get("projects"), get("handoffs").catch(() => null), get("sessions").catch(() => null),
    ]);
    this.top = top;
    this.projects = projects.items ?? [];
    this.handoffs = handoffs?.items ?? [];
    this.titles = {};
    for (const s of [...(sessions?.open ?? []), ...(sessions?.recent ?? [])]) this.titles[s.sid] = s.title;
  }

  // El proyecto de la carpeta en foco: {name, path}, o null mientras no se sabe
  here() {
    if (!this.top) return null;
    return this.projects.find((p) => p.path === this.top) ?? { name: nameOf(this.top), path: this.top };
  }

  // Pide un nombre y, con él, cierra el panel y sigue
  named(label, title, help, then) {
    this.askFor({ label, title, help, verb: "abrir el chat", run: (text) => { this.close(); then(text); } });
  }

  actions() {
    const dir = this.dir;
    return [
      { key: "chat", group: 0, title: "Chat nuevo", hint: "bk chat", words: "claude otro pestaña", verb: "abrir el chat",
        go: () => { this.close(); launch("Chat nuevo", ["chat"], dir); } },
      // Parado en un chat: su resumen y seguir en uno nuevo. Es alt+h (bk handoff --term), acá porque se busca en alt+n
      ...(this.inChat ? [{ key: "resumen", group: 0, title: "Resumen de este chat y seguir en uno nuevo…", hint: "alt+h",
        words: "handoff seguir contexto largo continuar", verb: "elegir cómo seguir", go: () => goto("bk-handoff") }] : []),
      { key: "rama", group: 0, title: "Chat en una rama aparte…", hint: "bk chat --rama", words: "branch worktree cambio", verb: "ponerle nombre a la rama",
        go: () => this.named("rama", "¿Cómo se llama el cambio?", "Queda en la rama chat/<nombre>, con su worktree y su espacio, desde la rama principal al día.",
          (text) => launch("Chat en la rama " + text, ["chat", "--rama", text], dir)) },
      { key: "nombre", group: 0, title: "Chat con nombre…", hint: "bk chat --nombre", words: "llamar titulo pestaña", verb: "ponerle nombre al chat",
        go: () => this.named("nombre", "¿Cómo se llama el chat?", "Es el nombre de su pestaña; también sirve para bk go y bk say.",
          (text) => launch("Chat " + text, ["chat", "--nombre", text], dir)) },
      { key: "term", group: 0, title: "Terminal en una pestaña", hint: "", words: "shell consola tab", verb: "abrir la terminal",
        go: () => { this.close(); run("tab.new"); } },
      { key: "suelto", group: 1, title: "Chat suelto", hint: "bk chat --suelto", words: "sin proyecto claude libre", verb: "abrir el chat",
        go: () => { this.close(); launch("Chat suelto", ["chat", "--suelto"], dir); } },
    ];
  }

  rows() {
    const q = this.query.trim();
    const here = this.here();
    const acts = this.actions().map((a) => ({ ...a, kind: "act", text: [a.title, `${a.hint} ${a.words}`] }));
    // (ho y no h: Panel lee r.h como el alto de la fila)
    const ready = this.handoffs.map((ho) => {
      const known = this.titles[ho.sid];
      const title = known || ho.name || ho.session || ho.sid.slice(0, 8);
      // sin el título de la sesión, dos resúmenes del mismo chat se ven iguales: los distingue el id (bk chat --desde <id>)
      const from = [ho.name, ho.session, known ? "" : ho.sid.slice(0, 8)].filter((x) => x && x !== title).join(" · ");
      return { key: "h-" + ho.sid, kind: "handoff", ho, title, from, text: [title, `${ho.project} ${from} resumen seguir`] };
    });
    const others = this.projects.filter((p) => p.path !== here?.path)
      .map((p) => ({ key: "p-" + p.path, kind: "project", p, title: p.name, text: [p.name, `${tilde(p.path)} abrir proyecto`] }));
    const path = pathOf(q);
    const first = path ? [{ key: "path", kind: "path", path, title: "Abrir " + tilde(path), hint: "bk open" }] : [];
    if (q) {
      return [...first, ...rank([...acts, ...ready, ...others], q, (r) => r.text).map(({ item, hits }) => ({ ...item, hits }))];
    }
    const out = [{ head: here ? "En " + here.name : "En este proyecto" }, ...acts.filter((a) => a.group === 0),
      { head: "Sin proyecto" }, ...acts.filter((a) => a.group === 1)];
    if (ready.length) {   // bk los da del más nuevo al más viejo
      const note = ready.length > READY ? `${READY} de ${ready.length}` : String(ready.length);
      out.push({ head: "Seguir desde un resumen", note }, ...ready.slice(0, READY));
    }
    if (others.length) out.push({ head: "Otro proyecto", note: String(others.length) }, ...others);
    return out;
  }

  draw(t, r, on) {
    const ink = on ? t.foreground : t.muted;
    const row = h_flex().flex_1().min_w(0).gap(10).items_center();
    if (r.kind === "project") {
      return row.child(div().flex_none().max_w(300).min_w(0).child(lit(t, r.title, r.hits, ink)))
        .child(div().flex_1().min_w(0).truncate().text_size(11.5).text_color(t.dim).child(tilde(r.p.path)))
        .when(Boolean(r.p.open), (el) => el.child(pill(t, "abierto", t.done)));
    }
    if (r.kind === "handoff") {
      return row.child(div().flex_1().min_w(0).child(lit(t, r.title, r.hits, ink)))
        .when(Boolean(r.from), (el) => el.child(div().flex_none().max_w(160).truncate().text_size(11.5).text_color(t.dim).child(r.from)))
        .when(Boolean(r.ho.project), (el) => el.child(pill(t, r.ho.project, t.accent)))
        .child(div().flex_none().w(44).flex().justify_end().text_size(11).text_color(t.dim).child(ago(r.ho.age_min)));
    }
    return row.child(div().flex_1().min_w(0).child(lit(t, r.title, r.hits, ink)))
      .when(Boolean(r.hint), (el) => el.child(div().flex_none().text_size(11.5).text_color(t.dim).child(r.hint)));
  }

  hints(row) {
    const what = !row ? "elegir"
      : row.kind === "project" ? (row.p.open ? "ir a su espacio" : "abrir su espacio con un chat")
      : row.kind === "handoff" ? "seguir en un chat nuevo"
      : row.kind === "path" ? "abrir esa carpeta"
      : row.verb;
    return [["enter", what], ["escape", "cerrar"]];
  }

  enter(r, cx) {
    if (r.kind === "act") { r.go(); return cx.notify(); }
    this.close();
    if (r.kind === "path") return launch("Abrir " + tilde(r.path), ["open", r.path], this.dir);
    if (r.kind === "project") return launch("Abrir " + r.p.name, ["open", r.p.path], this.dir);
    launch("Seguir desde " + r.title, ["chat", "--desde", r.ho.sid], this.dir);
  }
}
