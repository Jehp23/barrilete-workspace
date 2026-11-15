// alt+e: las tareas del kit (ADR-005): lo que hay que aprobar, lo que te espera y lo que está en marcha. Tab suma
// el historial. Los datos son los de `bk _tasks` (lib/herdr_tasks.py); las etiquetas bk.* de las terminales dicen
// cuál sigue abierta (agentTerm de kit). Enter lanza el reviewer propuesto (bk approve) o va a la pestaña del agente; ctrl+o abre el
// issue o el PR en el navegador. Lanzar sigue siendo de bk: el panel no decide nada.

import { div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { exec, notify } from "herdr";
import { Panel, rank, bk, launch, lit, pill, dot, ago, lastLine, agentTerm, reveal } from "./kit.js";

// Estado de la tarea → sección, en el orden en que se muestran, y el punto que le toca (dot de kit)
const SECTIONS = [
  { status: "pending", label: "Por aprobar", dot: "pending" },
  { status: "waiting", label: "Te esperan", dot: "waiting" },
  { status: "in_progress", label: "Trabajando", dot: "working" },
  { status: "completed", label: "Completadas", dot: "done" },
  { status: "failed", label: "Fallidas", dot: "fail" },
  { status: "incomplete", label: "Incompletas", dot: "blocked" },
  { status: "cancelled", label: "Canceladas", dot: null },
];
const ACTIVE = ["pending", "waiting", "in_progress"];
const ROLE = { implementer: "accent", reviewer: "ansi4", planner: "ansi6", orchestrator: "ansi3" };
const GITHUB = /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/(pull|issues)\/\d+$/;

const canApprove = (task) => task.status === "pending" && task.role === "reviewer";
const refNumber = (task) => (/^#\d+$/.test(task.ref ?? "") ? task.ref.slice(1) : "");
// El PR de la tarea: el que anotó bk, o el de su nombre (ADR-005: pr<n>-<rol>). "" si no tiene.
export const prOf = (task) => String(task.pr ?? /^pr(\d+)-/.exec(task.id ?? "")?.[1] ?? "");

// "PR #271" si la tarea es sobre ese PR; si no, su issue ("#226"). El título que trae bk es el de ese número.
export function nameOf(task) {
  const n = refNumber(task), pr = prOf(task);
  if (n) return pr === n ? `PR #${n}` : `#${n}`;
  return pr ? `PR #${pr}` : task.id;
}

// Lo que va a la derecha del título: qué falta, o cómo terminó
export function noteOf(task, live) {
  if (canApprove(task)) return "enter lo lanza";
  if (ACTIVE.includes(task.status)) return live || task.status === "pending" ? "" : "sin terminal";
  const r = task.result;
  if (typeof r === "string") return r;
  if (r?.pr && String(r.pr) !== refNumber(task)) return `→ PR #${r.pr}`;
  if (r?.kind === "blockers") return "con bloqueantes";
  return r?.reason ?? "";
}

export function age(iso, now) {
  const at = Date.parse(iso ?? "");
  return at ? ago((now - at) / 60000) : "";
}

// owner/repo de la URL de origin, o ""
export function slugOf(url) {
  return /github\.com[:/]([\w.-]+\/[\w.-]+?)(?:\.git)?\s*$/.exec(url ?? "")?.[1] ?? "";
}

export default class Tasks extends Panel {
  setup() {
    this.title = "Te esperan";
    this.placeholder = "Buscar una tarea…";
    this.tasks = [];
    this.all = false;
    this.slugs = {};
  }

  async load() {
    const known = new Set(SECTIONS.map((s) => s.status));
    const list = await bk(["_tasks", ...(this.all ? ["--all"] : [])], { json: true, timeout: 30000 });
    this.tasks = list.filter((x) => known.has(x.status) && (this.all || ACTIVE.includes(x.status)));
  }

  subtitle() { return this.all ? "todas, con el historial" : "activas"; }

  // La terminal viva del agente de esa tarea (la ventana que bk anotó, en su proyecto), o null. Una tarea
  // cerrada no tiene: otra tarea pudo tomar después la misma ventana.
  terminalOf(task) {
    return ACTIVE.includes(task.status) ? agentTerm(task.window, task.project) : null;
  }

  rows() {
    const when = (x) => Date.parse(x.updated ?? "") || 0;
    const items = [...this.tasks].sort((a, b) => when(b) - when(a)).map((task) => ({
      key: task.dir || `${task.project}/${task.id}`, task, term: this.terminalOf(task), section: SECTIONS.find((s) => s.status === task.status),
    }));
    if (this.query.trim()) {
      return rank(items, this.query, (r) => [r.task.title || r.task.id, `${nameOf(r.task)} ${r.task.pr ?? ""} ${r.task.role ?? ""} ${r.task.project ?? ""} ${r.task.id} ${r.section.label}`])
        .map(({ item, hits }) => ({ ...item, hits }));
    }
    const rows = [];
    for (const s of SECTIONS) {
      const members = items.filter((r) => r.section === s);
      if (members.length) rows.push({ head: s.label, note: String(members.length) }, ...members);
    }
    return rows;
  }

  draw(t, r, on) {
    const k = r.task, live = Boolean(r.term);
    const mark = k.status === "in_progress" && !live ? null : r.section.dot;
    const note = noteOf(k, live);
    const fg = on ? t.foreground : t.muted;
    return h_flex().flex_1().min_w(0).gap(10).items_center()
      .child(h_flex().w(12).flex_none().items_center().justify_center().child(dot(t, mark)))
      .child(div().w(62).flex_none().truncate().font_medium().text_color(fg).child(nameOf(k)))
      .child(h_flex().w(92).flex_none().items_center().child(pill(t, k.role || "tarea", t[ROLE[k.role]] ?? t.muted)))
      .child(div().flex_1().min_w(0).child(lit(t, k.title || k.id, r.hits, k.title ? fg : t.dim)))
      .when(Boolean(note), (el) => el.child(div().flex_none().max_w(170).truncate().text_size(11).text_color(canApprove(k) ? t.blocked : t.dim).child(note)))
      .child(div().flex_none().max_w(130).truncate().text_size(11.5).text_color(t.dim).child(k.project ?? ""))
      .child(div().w(46).flex_none().text_right().text_size(11).text_color(t.dim).child(age(k.updated, Date.now())));
  }

  hints(row) {
    const tab = ["tab", this.all ? "solo las activas" : "ver todas"];
    if (!row) return [tab, ["ctrl-r", "recargar"], ["escape", "cerrar"]];
    const go = canApprove(row.task) ? "lanzar el reviewer" : row.term ? "ir a su pestaña" : "por qué no tiene pestaña";
    return [["enter", go], ["ctrl-o", "abrir en GitHub"], tab, ["ctrl-r", "recargar"], ["escape", "cerrar"]];
  }

  empty() {
    if (this.query.trim()) return null;
    return this.all ? "Todavía no hay tareas. alt+i lanza un agente sobre un issue." : "Nada te espera. alt+i lanza un agente sobre un issue.";
  }

  enter(r) {
    const k = r.task;
    if (canApprove(k)) {
      this.close();
      launch(`Reviewer PR #${prOf(k) || refNumber(k)}`, ["approve", k.id], k.repo)
        .catch((e) => notify({ title: `No pude lanzar ${k.id}`, body: String(e?.message ?? e), level: "error" }));
      return;
    }
    if (!r.term) {
      const why = k.status === "pending" ? `es una propuesta: bk approve ${k.id} la lanza`
        : ACTIVE.includes(k.status) ? "su agente ya no tiene una terminal abierta"
        : `está ${r.section.label.toLowerCase().replace(/s$/, "")}: su agente ya cerró`;
      notify({ title: `${nameOf(k)} · ${k.role ?? k.id}`, body: why, level: "info" });
      return;
    }
    this.close();
    reveal(r.term);
  }

  key(e, row, cx) {
    const k = e.key, m = e.modifiers;
    if (k === "tab" && !m.control && !m.shift) {
      this.all = !this.all;
      this.at = 0;
      this.reload(cx);
      return true;
    }
    if (m.control && k === "o" && row) { this.browse(row.task, cx); return true; }
    return false;
  }

  // El PR si la tarea tiene uno, si no su issue. La URL se arma del origin del repo; solo se abre una de GitHub.
  browse(task, cx) {
    const pr = prOf(task);
    const n = pr || refNumber(task);
    if (!n || !task.repo) return notify({ title: nameOf(task), body: "no tiene un issue ni un PR para abrir", level: "info" });
    this.work(cx, "abriendo…", async () => {
      if (!this.slugs[task.repo]) {
        const r = await exec("git", ["-C", task.repo, "remote", "get-url", "origin"], { timeout: 5000 });
        this.slugs[task.repo] = r.code === 0 ? slugOf(r.stdout.trim()) : "";
      }
      const url = `https://github.com/${this.slugs[task.repo]}/${pr ? "pull" : "issues"}/${n}`;
      if (!GITHUB.test(url)) throw new Error(`no sé cuál es el repo de GitHub de ${task.project}`);
      const r = await exec("open", [url], { timeout: 10000 });
      if (r.code !== 0) throw new Error(lastLine(r.stderr) || "no pude abrir el navegador");
    });
  }
}
