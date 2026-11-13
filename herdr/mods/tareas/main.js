// Tareas de Barrilete Kit en Herdr: las tareas activas de los agentes (ADR-005: <issue>-<rol>, pr<n>-<rol>)
// con su rol, su issue o PR y su estado. Los datos son los del kit, no los de la ventana: `bk tasks --json`
// (lib/tasks.py) dice qué tareas hay y las etiquetas bk.* de las terminales dicen cuál sigue abierta.
// Clic en una tarea: va a la pestaña de su agente. Solo lee; lanzar y aprobar siguen siendo de bk.

import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { exec, terminals, run, theme, home, watchFolder, notify } from "herdr";

// Estado de la tarea → sección, en el orden en que se muestran, y el color del tema que le toca
const SECTIONS = [
  { status: "pending", label: "Por aprobar", color: "blocked" },
  { status: "waiting", label: "Te esperan", color: "done" },
  { status: "in_progress", label: "Trabajando", color: "working" },
];

const label = (t, k) => t.labels?.[k] ?? "";

function age(iso, now) {
  const at = Date.parse(iso ?? "");
  if (!at) return "";
  const m = Math.floor((now - at) / 60000);
  if (m < 1) return "ahora";
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  return h < 24 ? `${h} h` : `${Math.floor(h / 24)} d`;
}

export default class Tareas extends View {
  init(_props, cx) {
    this.tasks = [];
    this.error = null;
    this.loaded = false;
    const reload = async (cx) => {
      await this.load();
      cx.notify();
    };
    cx.spawn(reload);
    cx.timer.every(30000, (cx) => cx.spawn(reload));
    // Las tareas cambian cuando un agente o un hook escribe su task.json: no hace falta esperar al reloj
    cx.spawn(async (cx) => {
      for (;;) {
        try {
          await watchFolder(`${home()}/.local/state/bk/tasks`);
        } catch (_e) {
          return;   // sin carpeta todavía: queda el reloj
        }
        await reload(cx);
      }
    });
  }

  async load() {
    try {
      const r = await exec("bk", ["tasks", "--json"], { timeout: 10000 });
      if (r.code !== 0) throw new Error(r.stderr.trim() || `bk tasks salió con ${r.code}`);
      const known = new Set(SECTIONS.map((s) => s.status));
      this.tasks = JSON.parse(r.stdout).filter((t) => known.has(t.status));
      this.error = null;
    } catch (e) {
      this.error = String(e?.message ?? e);
    }
    this.loaded = true;
  }

  // La terminal viva del agente de esa tarea (la ventana que bk anotó, en su proyecto), o null
  terminalOf(task, all) {
    if (!task.window) return null;
    return all.find((t) => t.state === "live" && label(t, "bk.kind") === "agent" && label(t, "bk.win") === task.window
      && (!label(t, "bk.project") || label(t, "bk.project") === task.project)) ?? null;
  }

  open(task, term) {
    if (!term) {
      const how = task.status === "pending" ? `bk approve ${task.id} la lanza` : "su agente ya no tiene una terminal abierta";
      notify({ title: `${task.id}`, body: how, level: "info" });
      return;
    }
    const tab = label(term, "herdr.tab");
    if (tab) run("tab.select", { id: tab });
    run("pane.focus", { terminal: term.address });
  }

  row(t, task, term, section, now) {
    const color = t[section.color] ?? t.dim;
    const live = Boolean(term);
    const what = [task.project, age(task.updated, now), live || task.status === "pending" ? null : "sin terminal"].filter(Boolean).join(" · ");
    return h_flex()
      .id(`task-${task.project}-${task.id}`)
      .px(8)
      .h(44)
      .flex_none()
      .rounded(8)
      .gap(10)
      .items_center()
      .cursor_pointer()
      .hover((s) => s.bg(t.hover))
      .on_click(() => this.open(task, term))
      .child(div().w(3).h(26).flex_none().rounded(2).bg(live || task.status === "pending" ? color : t.dim + "55"))
      .child(v_flex().flex_1().min_w(0).gap(2)
        .child(h_flex().gap(6).items_center()
          .child(div().flex_none().font_medium().text_color(live ? t.foreground : t.muted).child(task.pr ? `PR #${task.pr}` : task.ref || task.id))
          .child(div().flex_1().min_w(0).truncate().text_color(t.muted).child(task.role ?? "")))
        .child(div().truncate().text_size(11).text_color(t.dim).child(what)));
  }

  render() {
    const t = theme();
    const all = terminals();
    const now = Date.now();
    const rows = [];
    for (const s of SECTIONS) {
      const members = this.tasks.filter((x) => x.status === s.status);
      if (!members.length) continue;
      rows.push(h_flex().id(`sec-${s.status}`).px(8).pt(8).h(30).flex_none().gap(6).items_center().text_size(11).font_medium()
        .child(div().text_color(t[s.color] ?? t.dim).child(s.label))
        .child(div().text_color(t.dim).child(String(members.length))));
      for (const task of members) rows.push(this.row(t, task, this.terminalOf(task, all), s, now));
    }
    const empty = this.error ? `No pude leer las tareas: ${this.error}`
      : !this.loaded ? "Leyendo las tareas…"
      : rows.length === 0 ? "Sin tareas activas. bk run <issue> lanza un agente." : null;

    return v_flex()
      .size_full()
      .min_h(0)
      .bg(t.chrome)
      .border_t(1)
      .border_color(t.border)
      .text_size(13)
      .child(h_flex().px(16).h(41).pt(14).pb(5).flex_none().items_center()
        .child(div().text_size(11.5).font_medium().text_color(t.dim).child("Tareas del kit")))
      .when(Boolean(empty), (el) => el.child(div().px(16).text_size(12).text_color(this.error ? t.blocked : t.dim).child(empty ?? "")))
      .child(v_flex().id("task-list").flex_1().min_h(0).px(8).overflow_y_scrollbar().mode("always").children(rows));
  }
}
