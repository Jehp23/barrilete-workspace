// Tareas de Barrilete Kit en Herdr: las tareas activas de los agentes (ADR-005: <issue>-<rol>, pr<n>-<rol>)
// con su rol, su issue o PR y su estado. Los datos son los del kit, no los de la ventana: `bk tasks --json`
// (lib/tasks.py) dice qué tareas hay y las etiquetas bk.* de las terminales dicen cuál sigue abierta.
// Clic en una tarea: va a la pestaña de su agente. Solo lee; lanzar y aprobar siguen siendo de bk.

import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { exec, terminals, run, theme, home, watchFolder, notify, props, spaces } from "herdr";

// Estado de la tarea → sección, en el orden en que se muestran, y el color del tema que le toca
const SECTIONS = [
  { status: "pending", label: "Por aprobar", color: "blocked" },
  { status: "waiting", label: "Te esperan", color: "blocked" },
  { status: "in_progress", label: "Trabajando", color: "working" },
  { status: "completed", label: "Completadas", color: "done" },
  { status: "failed", label: "Fallidas", color: "ansi1" },
  { status: "incomplete", label: "Incompletas", color: "blocked" },
  { status: "cancelled", label: "Canceladas", color: "dim" },
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
    this.project = localStorage.getItem("project") || "";
    this.filter = "active";
    this.board = Boolean(props()?.board);
    if (props()?.launcher) return;
    this.error = null;
    this.loaded = false;
    const reload = async (cx) => {
      if (this.busy) return;
      this.busy = true;
      try { await this.load(); } finally { this.busy = false; }
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
      const r = await exec("bk", ["tasks", "--json", ...(this.board ? ["--all"] : [])], { timeout: 10000 });
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
    if (!task.window || !["pending", "waiting", "in_progress"].includes(task.status)) return null;
    return all.find((t) => t.state === "live" && label(t, "bk.kind") === "agent" && label(t, "bk.win") === task.window
      && (!label(t, "bk.project") || label(t, "bk.project") === task.project)) ?? null;
  }

  open(task, term) {
    if (!term) {
      const how = task.status === "pending" ? `bk approve ${task.id} la lanza`
        : ["waiting", "in_progress"].includes(task.status) ? "su agente ya no tiene una terminal abierta"
        : `Tarea ${SECTIONS.find((s) => s.status === task.status)?.label.toLowerCase() || task.status}`;
      notify({ title: `${task.id}`, body: how, level: "info" });
      return;
    }
    const space = label(term, "herdr.space");
    if (space) run("space.select", { id: space });
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
      .h(52)
      .flex_none()
      .rounded(10)
      .bg(t.surface)
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

  async openBoard() {
    if (this.opening) return;
    this.opening = true;
    try {
      const command = async (name, args) => {
        const r = await exec("herdr-app", ["do", name, JSON.stringify(args)], { timeout: 10000 });
        if (r.code !== 0) throw new Error(r.stderr.trim() || "No pude abrir el centro de tareas");
        return JSON.parse(r.stdout);
      };
      const existing = spaces().find((s) => s.name === "Barrilete · Tareas" && !s.machine);
      if (existing) {
        let board = existing.tabs?.find((tab) => tab.name === "Todas las tareas");
        if (!board) {
          const made = await command("tab.new", { name: "Todas las tareas", space: existing.id, mod: "bk-tareas", props: { board: true } });
          board = { id: made.tab };
        }
        run("space.select", { id: existing.id });
        run("tab.select", { id: board.id });
        return;
      }
      const created = await command("space.new", { name: "Barrilete · Tareas", tab: "Inicio", folder: home(), machine: "" });
      const board = await command("tab.new", { name: "Todas las tareas", space: created.space, mod: "bk-tareas", props: { board: true } });
      // Solo cierra la terminal vacía que acabamos de crear; el tablero ya tiene su propia pestaña.
      await command("tab.close", { id: created.tab, confirmed: true });
      run("space.select", { id: created.space });
      run("tab.select", { id: board.tab });
    } catch (e) {
      notify({ title: "Barrilete", body: String(e?.message ?? e), level: "error" });
    } finally { this.opening = false; }
  }

  chip(t, id, text, selected, action) {
    return div().id(id).px(10).py(7).rounded(8).flex_none().text_size(12).cursor_pointer()
      .bg(selected ? t.selected : t.surface).text_color(selected ? t.accent : t.muted)
      .hover((s) => s.bg(t.hover)).on_click(action).child(text);
  }

  boardRow(t, task, all, now) {
    const section = SECTIONS.find((s) => s.status === task.status);
    const color = t[section?.color] ?? t.dim;
    const term = this.terminalOf(task, all);
    const result = task.result;
    const detail = [task.role, task.worktree, typeof result === "string" ? result : result?.reason].filter(Boolean).join(" · ");
    return v_flex().id(`board-${task.dir || task.project + "-" + task.id}`).flex_none().p(14).gap(7).rounded(12)
      .bg(t.surface).border(1).border_color(t.border).cursor_pointer().hover((s) => s.bg(t.hover))
      .on_click(() => this.open(task, term))
      .child(h_flex().gap(12).items_center()
        .child(div().size(7).rounded(4).flex_none().bg(color))
        .child(div().font_semibold().text_color(t.foreground).child(task.pr ? `PR #${task.pr}` : task.ref || task.id))
        .child(div().flex_1().min_w(0).truncate().text_color(t.muted).child(task.project))
        .child(div().text_size(11).text_color(color).child(section?.label || task.status)))
      .child(div().truncate().text_size(12).text_color(t.muted).tooltip(detail).child(detail || task.id))
      .child(h_flex().gap(12).text_size(11).text_color(t.dim)
        .child(div().flex_1().min_w(0).truncate().child(task.id))
        .child(div().flex_none().text_color(term ? t.done : t.dim).child(term ? "● Agente disponible" : "Sin agente conectado"))
        .child(div().flex_none().child(age(task.updated, now))));
  }

  renderBoard(t) {
    const active = (x) => ["pending", "waiting", "in_progress"].includes(x.status);
    const projects = [...new Set(this.tasks.map((x) => x.project))].sort();
    const projectTasks = this.tasks.filter((x) => !this.project || x.project === this.project);
    const list = projectTasks.filter((x) => this.filter === "all" || (this.filter === "active" ? active(x) : x.status === this.filter))
      .sort((a, b) => (Date.parse(b.updated) || 0) - (Date.parse(a.updated) || 0));
    const chooseProject = (name, cx) => { this.project = name; localStorage.setItem("project", name); cx.notify(); };
    const all = terminals();
    const now = Date.now();
    const count = (status) => projectTasks.filter((x) => status === "active" ? active(x) : x.status === status).length;
    const summary = [{label:"Activas",n:count("active"),color:t.accent},{label:"Necesitan atención",n:count("pending")+count("waiting"),color:t.blocked},{label:"Completadas",n:count("completed"),color:t.done}];
    const filters = [{status:"active",label:"Activas"},{status:"all",label:"Todas"},...SECTIONS];
    return v_flex().id("task-center").size_full().min_h(0).p(22).gap(18).bg(t.background).text_size(13)
      .child(h_flex().items_center().gap(12).flex_none()
        .child(v_flex().flex_1().min_w(0).gap(5)
          .child(div().text_size(23).font_semibold().text_color(t.foreground).child("Tareas de Barrilete"))
          .child(div().text_size(12).text_color(t.muted).child("Todos tus proyectos. Un lugar para seguir el trabajo.")))
        .child(this.chip(t,"refresh-tasks","Actualizar",false,(_e,cx)=>cx.spawn(async(cx)=>{await this.load();cx.notify();}))))
      .child(h_flex().gap(12).flex_none().children(summary.map((s)=>v_flex().flex_1().min_w(0).p(14).gap(7).rounded(12).bg(t.surface)
        .child(div().text_size(24).font_semibold().text_color(s.color).child(String(s.n)))
        .child(div().text_size(11).text_color(t.muted).child(s.label)))))
      .child(h_flex().flex_1().min_h(0).gap(18).items_stretch()
        .child(v_flex().id("project-filters").w(176).flex_none().min_h(0).gap(7).overflow_y_scrollbar()
          .child(div().px(10).py(6).text_size(11).text_color(t.accent).child("PROYECTOS"))
          .child(this.chip(t,"project-all",`Todos · ${this.tasks.length}`,!this.project,(_e,cx)=>chooseProject("",cx)))
          .children(projects.map((name)=>this.chip(t,`project-${name}`,`${name} · ${this.tasks.filter((x)=>x.project===name).length}`,this.project===name,(_e,cx)=>chooseProject(name,cx)).truncate().tooltip(name))))
        .child(v_flex().flex_1().min_w(0).min_h(0).gap(12)
          .child(h_flex().gap(6).flex_wrap().flex_none().children(filters.map((s)=>this.chip(t,`filter-${s.status}`,s.label,this.filter===s.status,(_e,cx)=>{this.filter=s.status;cx.notify();}))))
          .child(div().text_size(11).text_color(t.dim).child(`${this.project || "Todos los proyectos"} · ${list.length} tareas`))
          .when(Boolean(this.error),(el)=>el.child(div().text_color(t.blocked).child(`No pude actualizar: ${this.error}`)))
          .child(v_flex().id("board-task-list").flex_1().min_h(0).gap(10).overflow_y_scrollbar()
            .when(!list.length,(el)=>el.child(v_flex().p(24).gap(8).rounded(12).bg(t.surface)
              .child(div().text_color(t.foreground).child(!this.loaded ? "Cargando tareas…" : "No hay tareas con estos filtros"))
              .child(div().text_size(12).text_color(t.dim).child("Elegí otro proyecto o seleccioná Todas para ver el historial."))))
            .children(list.map((task)=>this.boardRow(t,task,all,now))))));
  }

  render() {
    const t = theme();
    if (this.board) return this.renderBoard(t);
    if (props()?.launcher) return h_flex().size_full().px(12).py(8).bg(t.chrome)
      .child(this.chip(t, "open-task-center", "▦ Tareas de Barrilete ↗", false, (_e, cx) => cx.spawn(async () => this.openBoard())).flex_1());
    const all = terminals();
    const now = Date.now();
    const rows = [];
    for (const s of SECTIONS.slice(0, 3)) {
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
        .child(div().text_size(11.5).font_medium().text_color(t.accent).child("TAREAS · BARRILETE")))
      .when(Boolean(empty), (el) => el.child(div().px(16).text_size(12).text_color(this.error ? t.blocked : t.dim).child(empty ?? "")))
      .child(v_flex().id("task-list").flex_1().min_h(0).px(8).overflow_y_scrollbar().mode("always").children(rows));
  }
}
