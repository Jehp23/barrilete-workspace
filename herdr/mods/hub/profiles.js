// Perfiles de modelos y tareas (alt+k → «Perfiles de modelos y tareas»). Niveles:
//   inicio    PERFILES (bk profile): enter usa · → o tab edita · ctrl+n nuevo (copia del elegido) · ctrl+x dos veces borra
//             TAREAS (bk ask): enter elige el modelo · ctrl+e la descripción · ctrl+x dos veces borra · «Nueva tarea…»
//   roles     los cinco roles del perfil con su provider/modelo · enter elige otro
//   modelos   el catálogo (bk models) agrupado por proveedor, y «Otro…» para escribir provider/modelo. Para un rol solo
//             claude y codex (los que bk sabe lanzar como agente); para una tarea, también gemini
// Lo deciden y lo guardan `bk profile`, `bk ask` y `bk models` (lib/profiles.py, ask.py, models.py); acá solo se elige.

import { div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { notify } from "herdr";
import { Panel, rank, bk, lit, pill, termPopup, bin, lastLine, cwd } from "./kit.js";

const SURE_MS = 4000;
const OTHER = "\u0000otro";
const NEW_TASK = "\u0000nueva";

export default class Profiles extends Panel {
  setup() {
    this.title = "Perfiles de modelos y tareas";
    this.placeholder = "Perfil, tarea o modelo…";
    this.data = { profiles: [], roles: [], providers: [] };
    this.tasks = { tasks: [], providers: [] };
    this.models = [];
    this.provs = null;     // [{provider, logged, accounts}] de bk models --providers; null: no se pudo saber
    this.editing = null;   // el perfil que se edita (nivel roles)
    this.role = null;      // el rol al que se le elige modelo
    this.task = null;      // la tarea a la que se le elige modelo: { name, desc, spec }
    this.confirm = null;
  }

  async load() {
    const [p, t, m, s] = await Promise.all([
      bk(["profile", "--json"], { json: true, timeout: 8000 }),
      bk(["ask", "--json"], { json: true, timeout: 8000 }),
      bk(["models", "--json"], { json: true, timeout: 30000 }).catch(() => []),
      bk(["models", "--providers", "--json"], { json: true, timeout: 60000 }).catch(() => null),
    ]);
    this.data = p;
    this.tasks = t;
    this.models = m;
    this.provs = s;
  }

  // Los proveedores que se ofrecen: los permitidos (roles: claude y codex; tareas: también gemini) con sesión iniciada.
  // Si no se pudo saber quién tiene sesión, todos los permitidos
  offered() {
    const allowed = this.task ? this.tasks.providers : this.data.providers;
    if (!this.provs) return allowed.map((p) => ({ provider: p, accounts: [] }));
    return this.provs.filter((s) => s.logged && allowed.includes(s.provider));
  }

  logged(spec) {
    const p = (spec ?? "").split("/")[0];
    return !this.provs || this.provs.some((s) => s.provider === p && s.logged);
  }

  prof() { return this.data.profiles.find((p) => p.name === this.editing) ?? null; }
  picking() { return Boolean(this.role || this.task); }

  subtitle() {
    if (this.task) return `tarea ${this.task.name} › modelo`;
    if (this.role) return `${this.editing} › ${this.role}`;
    if (this.editing) return this.editing + (this.editing === this.data.active ? " · activo" : "");
    return this.data.active ? `perfil activo: ${this.data.active}` : "sin perfil: cada rol sale de roles.yml";
  }

  rows() {
    const q = this.query;
    const found = (items, text) => rank(items, q, text).map(({ item, hits }) => ({ ...item, hits }));
    if (this.picking()) {
      const cur = this.task ? this.task.spec : this.prof()?.roles?.[this.role];
      const out = [];
      for (const { provider: prov, accounts } of this.offered()) {
        const items = this.models.filter((m) => m.provider === prov)
          .map((m) => ({ key: `${prov}/${m.model}`, spec: `${prov}/${m.model}`, desc: m.desc, cur: `${prov}/${m.model}` === cur }));
        const got = found(items, (r) => [r.spec, r.desc]);
        if (got.length) out.push({ head: prov, note: accounts.join(" · ") }, ...got);
      }
      if (!out.length) out.push({ head: "sin cuentas", note: "ningún proveedor permitido tiene sesión: bk account para iniciarla" });
      out.push({ head: "otro" }, { key: OTHER, spec: "Otro… (escribir provider/modelo)", other: true, hits: [] });
      return out;
    }
    if (this.editing) {
      const roles = this.prof()?.roles ?? {};
      return found(this.data.roles.map((r) => ({ key: r, role: r, spec: roles[r] ?? null })), (r) => [r.role, r.spec ?? ""]);
    }
    const profs = found(this.data.profiles.map((p) => ({ key: `p:${p.name}`, p })), (r) => [r.p.name, r.p.summary]);
    const tasks = found(this.tasks.tasks.map((t) => ({ key: `t:${t.name}`, t })), (r) => [r.t.name, `${r.t.spec} ${r.t.desc}`]);
    const out = [];
    if (profs.length) out.push({ head: "Perfiles", note: "los modelos de los roles" }, ...profs);
    out.push({ head: "Tareas", note: "bk ask: el orquestador se las pasa a ese modelo" }, ...tasks,
      { key: NEW_TASK, newTask: true, hits: [] });
    return out;
  }

  empty() { return "Nada coincide."; }

  draw(t, r, on) {
    const fg = on ? t.foreground : t.muted;
    const sure = this.confirm === r.key;
    const row = () => h_flex().flex_1().min_w(0).gap(10).items_center();
    if (this.picking()) {
      return row()
        .child(div().w(250).flex_none().child(lit(t, r.spec, r.hits, r.other ? t.dim : fg)))
        .child(div().flex_1().min_w(0).truncate().text_size(12).text_color(t.dim).child(r.desc ?? ""))
        .when(Boolean(r.cur), (el) => el.child(pill(t, "ahora", t.accent)));
    }
    if (this.editing) {
      return row()
        .child(div().w(150).flex_none().child(lit(t, r.role, r.hits, fg)))
        .child(div().flex_1().min_w(0).truncate().text_color(r.spec ? t.foreground : t.dim).child(r.spec ?? "de roles.yml"));
    }
    if (r.newTask) return row().child(div().flex_1().text_color(t.dim).child("Nueva tarea…"));
    if (r.t) {
      return row()
        .child(div().w(110).flex_none().child(lit(t, r.t.name, r.hits, fg)))
        .child(div().w(210).flex_none().truncate().text_size(12).text_color(r.t.installed ? t.foreground : t.blocked).child(r.t.spec))
        .child(div().flex_1().min_w(0).truncate().text_size(12).text_color(t.dim).child(sure ? "" : r.t.desc))
        .when(sure, (el) => el.child(div().flex_none().text_size(11).text_color(t.blocked).child("ctrl+x de nuevo para borrar")))
        .when(!sure && !r.t.installed, (el) => el.child(pill(t, "falta la CLI", t.blocked)))
        .when(!sure && r.t.installed && !this.logged(r.t.spec), (el) => el.child(pill(t, "sin sesión", t.blocked)));
    }
    const act = r.p.name === this.data.active;
    return row()
      .child(div().w(110).flex_none().child(lit(t, r.p.name, r.hits, act ? t.accent : fg)))
      .child(div().flex_1().min_w(0).truncate().text_size(12).text_color(t.dim).child(r.p.summary))
      .when(sure, (el) => el.child(div().flex_none().text_size(11).text_color(t.blocked).child("ctrl+x de nuevo para borrar")))
      .when(!sure && act, (el) => el.child(pill(t, "activo", t.accent)));
  }

  hints(row) {
    const tail = [["ctrl-o", "archivo"], ["escape", "cerrar"]];
    if (this.picking()) return [["enter", "usar este"], ["left", "volver"], ["escape", "cerrar"]];
    if (this.editing) return [["enter", "cambiar el modelo"], ["left", "volver"], ["ctrl-u", "usar este perfil"], ["escape", "cerrar"]];
    if (row?.newTask) return [["enter", "crear una tarea"], ...tail];
    if (row?.t) return [["enter", "cambiar el modelo"], ["ctrl-e", "descripción"], ["ctrl-x", this.confirm === row.key ? "de nuevo para borrar" : "borrar"], ...tail];
    const h = [["enter", "usar"], ["right", "editar"], ["ctrl-n", "nuevo"]];
    if (row?.p && row.p.name !== this.data.active) h.push(["ctrl-x", this.confirm === row.key ? "de nuevo para borrar" : "borrar"]);
    return [...h, ...tail];
  }

  moved() {
    if (this.confirm && this.confirm !== this.current()?.key) this.confirm = null;
  }

  go(cx, { editing = null, role = null, task = null } = {}) {
    Object.assign(this, { editing, role, task, query: "", at: 0, scroll: 0 });
    this.input.set_value("");
    cx.notify();
  }

  back(cx) {
    if (this.role) this.go(cx, { editing: this.editing });
    else if (this.task || this.editing) this.go(cx);
    else return false;
    return true;
  }

  // bk <profile|ask> <args>: corre, avisa si falla y relee
  change(cx, label, args, ok) {
    return this.work(cx, label, async (cx) => {
      const r = await bk(args, { timeout: 10000 });
      if (r.code !== 0) throw new Error(lastLine(r.stderr) || `bk ${args[0]} salió con ${r.code}`);
      await this.load();
      ok?.(r, cx);
    });
  }

  use(cx, name) {
    this.change(cx, "cambiando…", ["profile", name], (r) => {
      notify({ title: `Perfil ${name}`, body: lastLine(r.stdout).replace(/^perfil [^:]*: /, ""), level: "success", timeout: 5000 });
      this.close();
    });
  }

  setSpec(cx, spec) {
    if (this.task) {
      const { name, desc } = this.task;
      return this.change(cx, "guardando…", ["ask", "set", name, spec, ...(desc ? [desc] : [])], (_r, cx) => {
        notify({ title: `Tarea ${name}`, body: spec, level: "success", timeout: 4000 });
        this.go(cx);
      });
    }
    const { editing, role } = this;
    this.change(cx, "guardando…", ["profile", "set", editing, role, spec], (_r, cx) => {
      notify({ title: `${editing}: ${role}`, body: spec, level: "success", timeout: 4000 });
      this.go(cx, { editing });
    });
  }

  // Nueva tarea: el nombre, para qué sirve (lo lee el orquestador) y después el modelo
  newTask(cx) {
    this.askFor({ label: "tarea", title: "Nueva tarea", help: "Un nombre corto: imagenes, investigar, traducir… (minúsculas, números y guiones).",
      verb: "seguir", run: (name, cx) => {
        name = name.toLowerCase().replace(/\s+/g, "-");
        this.askFor({ label: name, title: `¿Para qué sirve ${name}?`, help: "El orquestador lo lee para saber cuándo usarla. Ej.: buscar información en la web y responder con las fuentes.",
          verb: "elegir el modelo", run: (desc, cx) => this.go(cx, { task: { name, desc, spec: null } }) });
      } });
  }

  enter(r, cx) {
    if (this.picking()) {
      if (!r.other) return this.setSpec(cx, r.spec);
      const allowed = this.offered().map((s) => s.provider).join(", ") || "ninguno con sesión";
      return this.askFor({ label: this.task?.name ?? this.role, title: "Otro modelo",
        help: `<provider>/<modelo>, por ejemplo codex/gpt-6.1-sol o gemini/gemini-2.5-flash. Providers: ${allowed}`,
        verb: "guardar", run: (text, cx) => this.setSpec(cx, text) });
    }
    if (this.editing) return this.go(cx, { editing: this.editing, role: r.role });
    if (r.newTask) return this.newTask(cx);
    if (r.t) return this.go(cx, { task: { name: r.t.name, desc: "", spec: r.t.spec } });
    this.use(cx, r.p.name);
  }

  // El primer ctrl+x pregunta (en la fila y en el pie); el segundo, sobre la misma fila, borra
  sure(row, cx) {
    if (this.confirm === row.key) { this.confirm = null; return true; }
    this.confirm = row.key;
    const n = (this.asked = (this.asked ?? 0) + 1);
    cx.timer.after(SURE_MS, (cx) => { if (this.asked === n && this.confirm) { this.confirm = null; cx.notify(); } });
    return false;
  }

  key(e, row, cx) {
    const k = e.key, ctrl = e.modifiers.control;
    // ← y → mueven el cursor mientras hay algo escrito; con el buscador vacío, cambian de nivel
    if (k === "left" && !ctrl && !this.query) return this.back(cx);
    if (((k === "right" && !this.query) || k === "tab") && !this.editing && !this.picking() && row?.p) { this.go(cx, { editing: row.p.name }); return true; }
    if (ctrl && k === "u" && this.editing && !this.role) { this.use(cx, this.editing); return true; }
    if (ctrl && k === "o") {
      const cmd = row?.t || row?.newTask ? "ask" : "profile";
      this.close();
      termPopup("profiles", `'${bin()}' ${cmd} edit`, cwd());
      return true;
    }
    if (this.editing || this.picking()) return false;
    if (ctrl && k === "n") {
      if (row?.t || row?.newTask) { this.newTask(cx); return true; }
      const from = row?.p?.name ?? this.data.active ?? "normal";
      const typed = this.query.trim().toLowerCase().replace(/\s+/g, "-");
      this.askFor({ label: "nuevo", title: `Perfil nuevo, copia de ${from}`, help: "Minúsculas, números y guiones. Después elegí el modelo de cada rol.",
        value: typed, verb: "crear", run: (name, cx) => this.change(cx, "creando…", ["profile", "new", name, from], (_r, cx) => this.go(cx, { editing: name })) });
      return true;
    }
    if (ctrl && k === "e" && row?.t) {
      const t = row.t;
      this.askFor({ label: t.name, title: `¿Para qué sirve ${t.name}?`, help: "El orquestador lo lee para saber cuándo usarla.", value: t.desc,
        verb: "guardar", run: (desc, cx) => this.change(cx, "guardando…", ["ask", "set", t.name, t.spec, desc]) });
      return true;
    }
    if (ctrl && k === "x" && row?.t) {
      if (this.sure(row, cx)) this.change(cx, "borrando…", ["ask", "rm", row.t.name]);
      return true;
    }
    if (ctrl && k === "x" && row?.p) {
      if (row.p.name === this.data.active) { notify({ title: "No borro el activo", body: "Elegí otro perfil antes.", level: "warning" }); return true; }
      if (this.sure(row, cx)) this.change(cx, "borrando…", ["profile", "rm", row.p.name]);
      return true;
    }
    return false;
  }

  // esc en roles o modelos vuelve un nivel en vez de cerrar
  onKey(e, cx) {
    if (e.key === "escape" && !this.ask && !this.query && this.back(cx)) return cx.stop_propagation();
    return super.onKey(e, cx);
  }
}
