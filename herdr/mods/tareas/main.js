// Tareas de Barrilete Kit en Herdr: las tareas activas de los agentes (ADR-005: <issue>-<rol>, pr<n>-<rol>)
// con su rol, su issue o PR y su estado. Los datos son los del kit, no los de la ventana: `bk tasks --json`
// (lib/tasks.py) dice qué tareas hay y las etiquetas bk.* de las terminales dicen cuál sigue abierta; `bk _tasks`
// (lib/herdr_tasks.py) es eso mismo con el título de cada issue o PR.
// Clic en una tarea: va a la pestaña de su agente. Un reviewer propuesto (por aprobar) tiene su botón, que
// corre `bk approve <tarea>`: lanzar sigue siendo de bk, el panel no decide nada.

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
    this.launcher = Boolean(props()?.launcher);
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
      const r = await exec("bk", ["_tasks", ...(this.board ? ["--all"] : [])], { timeout: 10000 });
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
    const what = [task.title || task.project, age(task.updated, now), live || task.status === "pending" ? null : "sin terminal"].filter(Boolean).join(" · ");
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

  // El acceso de la barra: abre el centro de tareas y dice, sin entrar, qué te espera. Con los tres grupos a la
  // vez no entran las palabras largas: se acortan.
  renderLauncher(t) {
    const n = (status) => this.tasks.filter((x) => x.status === status).length;
    const groups = [
      { id: "pending", n: n("pending"), long: "por aprobar", short: "aprobar", color: t.blocked },
      { id: "waiting", n: n("waiting"), long: "te esperan", short: "esperan", color: t.blocked },
      { id: "in_progress", n: n("in_progress"), long: "trabajando", short: "activas", color: t.working },
    ].filter((g) => g.n > 0);
    const word = (g) => (groups.length > 2 ? g.short : g.long);
    const quiet = this.error ? "no pude leer las tareas" : !this.loaded ? "leyendo…" : groups.length ? null : "nada te espera";
    return h_flex().size_full().px(12).py(8).bg(t.chrome)
      .child(v_flex().id("open-task-center").flex_1().min_w(0).h_full().px(10).gap(3).justify_center().rounded(8).bg(t.surface)
        .cursor_pointer().hover((s) => s.bg(t.hover)).on_click((_e, cx) => cx.spawn(async () => this.openBoard()))
        .child(div().text_size(12).text_color(t.muted).child("▦ Tareas de Barrilete ↗"))
        .child(h_flex().gap(6).text_size(10.5).min_w(0)
          .when(Boolean(quiet), (el) => el.child(div().id("launcher-quiet").truncate().text_color(this.error ? t.blocked : t.dim).child(quiet ?? "")))
          .children(groups.map((g) => div().id(`launcher-${g.id}`).flex_none().text_color(g.color ?? t.dim).child(`${g.n} ${word(g)}`)))));
  }

  // El reviewer que el kit propuso para un PR: `bk approve` lo lanza, en el repo de la tarea. Un clic por vez.
  canApprove(task) {
    return task.status === "pending" && task.role === "reviewer";
  }

  async approve(task, cx) {
    this.approving ??= new Set();
    if (this.approving.has(task.dir)) return;
    this.approving.add(task.dir);
    cx.notify();
    try {
      const r = await exec("bk", ["approve", task.id], { cwd: task.repo || home(), timeout: 120000 });
      if (r.code !== 0) throw new Error((r.stderr.trim() || r.stdout.trim()).split("\n").pop() || `bk approve salió con ${r.code}`);
      notify({ title: `${task.id}`, body: "reviewer lanzado", level: "success" });
      await this.load();
    } catch (e) {
      notify({ title: `No pude lanzar ${task.id}`, body: String(e?.message ?? e), level: "error" });
    } finally {
      this.approving.delete(task.dir);
      cx.notify();
    }
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
    const ref = task.pr ? `PR #${task.pr}` : task.ref || task.id;
    const detail = [task.project, task.role, task.id, task.worktree, task.result?.reason].filter(Boolean).join(" · ");
    const launching = this.approving?.has(task.dir);
    return h_flex().id(`board-${task.dir || task.project + "-" + task.id}`).flex_none().px(16).py(14).gap(12)
      .border_b(1).border_color(t.border).cursor_pointer().hover((s) => s.bg(t.hover))
      .on_click(() => this.open(task, term)).tooltip(detail)
      .child(div().w(3).h(30).rounded(2).flex_none().bg(color))
      .child(v_flex().flex_1().min_w(0).gap(7)
        .child(div().truncate().font_medium().text_size(13).text_color(t.foreground).tooltip(task.title || ref).child(task.title || ref))
        .child(h_flex().gap(8).text_size(10.5).text_color(t.dim)
          .child(div().flex_none().text_color(t.accent).child(ref))
          .child(div().flex_1().min_w(0).truncate().child([task.project, task.role].filter(Boolean).join(" · ")))
          .child(div().flex_none().text_color(term ? t.done : t.dim).child(term ? "● En línea" : "Sin sesión"))
          .child(div().flex_none().child(age(task.updated, now)))))
      .child(v_flex().flex_none().items_end().gap(7)
        .child(div().px(8).py(4).rounded(6).bg(color + "18").text_size(10.5).text_color(color).child(section?.label || task.status))
        .when(this.canApprove(task), (el) => el.child(div().id(`approve-${task.dir}`).px(8).py(4).rounded(6).text_size(11)
          .bg(t.selected).text_color(t.accent).cursor_pointer().hover((s) => s.bg(t.hover))
          .on_click((_e, cx) => { cx.stop_propagation(); cx.spawn(async (cx) => this.approve(task, cx)); })
          .child(launching ? "Lanzando…" : "Lanzar reviewer"))));
  }

  nav(t, id, name, count, selected, action, color = t.dim) {
    return h_flex().id(id).h(31).px(9).gap(8).flex_none().rounded(7).cursor_pointer()
      .bg(selected ? t.selected : t.chrome).hover((s) => s.bg(t.hover)).on_click(action)
      .child(div().flex_1().min_w(0).truncate().text_size(11).text_color(selected ? t.foreground : t.muted).tooltip(name).child(name))
      .child(div().flex_none().text_size(10).text_color(selected ? t.accent : color).child(String(count)));
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
    const summary = [{status:"active",label:"activas",n:count("active"),color:t.accent},{status:"waiting",label:"requieren atención",n:count("pending")+count("waiting"),color:t.blocked},{status:"completed",label:"completadas",n:count("completed"),color:t.done}];
    const filters = [{status:"active",label:"Activas",color:"accent"},{status:"all",label:"Todas",color:"dim"},...SECTIONS];
    const filterName = filters.find((s) => s.status === this.filter)?.label || "Activas";
    const heading = (name) => div().px(9).pt(14).pb(7).text_size(10).font_medium().text_color(t.dim).child(name);
    return v_flex().id("task-center").size_full().min_h(0).p(20).gap(16).bg(t.background).text_size(12)
      .child(h_flex().gap(12).flex_none()
        .child(div().size(36).flex_none().rounded(10).bg(t.selected).text_color(t.accent).flex().items_center().justify_center().text_size(19).child("▦"))
        .child(v_flex().flex_1().min_w(0).gap(3)
          .child(div().text_size(21).font_semibold().text_color(t.foreground).child("Tareas"))
          .child(div().text_size(11).text_color(t.dim).child("Barrilete · Centro de trabajo")))
        .child(this.chip(t,"refresh-tasks","↻ Actualizar",false,(_e,cx)=>cx.spawn(async(cx)=>{await this.load();cx.notify();}))))
      .child(h_flex().gap(20).px(2).pb(14).flex_none().border_b(1).border_color(t.border)
        .children(summary.map((s)=>h_flex().gap(6)
          .child(div().font_semibold().text_color(s.color).child(String(s.n)))
          .child(div().text_size(11).text_color(t.muted).child(s.label)))))
      .child(h_flex().flex_1().min_h(0).gap(18).items_stretch()
        .child(v_flex().id("project-filters").w(162).p(6).flex_none().min_h(0).gap(3).rounded(10).bg(t.chrome).overflow_y_scrollbar()
          .child(heading("PROYECTOS"))
          .child(this.nav(t,"project-all","Todos",this.tasks.length,!this.project,(_e,cx)=>chooseProject("",cx)))
          .children(projects.map((name)=>this.nav(t,`project-${name}`,name,this.tasks.filter((x)=>x.project===name).length,this.project===name,(_e,cx)=>chooseProject(name,cx))))
          .child(heading("ESTADO"))
          .children(filters.map((s)=>this.nav(t,`filter-${s.status}`,s.label,s.status==="all" ? projectTasks.length : count(s.status),this.filter===s.status,(_e,cx)=>{this.filter=s.status;cx.notify();},t[s.color]))))
        .child(v_flex().flex_1().min_w(0).min_h(0).gap(10)
          .child(h_flex().gap(8).flex_none().py(4)
            .child(div().flex_1().min_w(0).truncate().font_medium().text_size(13).text_color(t.foreground).child(this.project || "Todos los proyectos"))
            .child(div().flex_none().text_size(10.5).text_color(t.dim).child(`${filterName} · ${list.length}`)))
          .when(Boolean(this.error),(el)=>el.child(div().text_color(t.blocked).child(`No pude actualizar: ${this.error}`)))
          .child(v_flex().id("board-task-list").flex_1().min_h(0).rounded(10).border(1).border_color(t.border).bg(t.surface).overflow_y_scrollbar()
            .when(!list.length,(el)=>el.child(v_flex().p(24).gap(8)
              .child(div().text_color(t.foreground).child(!this.loaded ? "Cargando tareas…" : "No hay tareas con estos filtros"))
              .child(div().text_size(11).text_color(t.dim).child("Probá con otro proyecto o con Todas."))))
            .children(list.map((task)=>this.boardRow(t,task,all,now))))));
  }

  render() {
    const t = theme();
    if (this.board) return this.renderBoard(t);
    if (this.launcher) return this.renderLauncher(t);
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
