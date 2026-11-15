// alt+i: los issues abiertos del proyecto que mirás. Enter lanza el agente del kit sobre el elegido (bk run <n>:
// routing.py elige el rol, prepare.sh crea el worktree con su candado). Si ese issue ya tiene un agente, Enter va
// a su pestaña. Tab cambia el rol (automático → implementer → implementer-light). Los datos: bk _hub issues.

import { div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { notify } from "herdr";
import { Panel, rank, bk, launch, cwd, lit, pill, dot, agentTerm, reveal, openUrl } from "./kit.js";

const ROLES = [null, "implementer", "implementer-light"];
const STATUS = { pending: "por aprobar", waiting: "te espera", in_progress: "trabajando" };

function since(iso) {
  const at = Date.parse(iso ?? "");
  if (!at) return "";
  const m = Math.floor((Date.now() - at) / 60000);
  if (m < 60) return Math.max(m, 1) + " min";
  const h = Math.floor(m / 60);
  return h < 24 ? h + " h" : Math.floor(h / 24) + " d";
}

export default class Issues extends Panel {
  setup() {
    this.title = "Implementar un issue";
    this.placeholder = "Número o palabras del título…";
    this.dir = cwd();
    this.data = { items: [] };
    this.role = 0;
  }

  subtitle() {
    const d = this.data;
    const role = ROLES[this.role] ? "rol " + ROLES[this.role] : "rol automático";
    return [d.repo || d.project, role, d.stale ? "sin conexión: lista vieja" : null].filter(Boolean).join(" · ");
  }

  async load() {
    this.data = await bk(["_hub", "issues", this.dir], { json: true, timeout: 25000 });
  }

  rows() {
    const items = this.data.items ?? [];
    const found = rank(items, this.query, (i) => ["#" + i.n + " " + i.title, (i.labels ?? []).join(" ")]);
    if (this.query.trim()) return found.map(({ item, hits }) => ({ key: "i" + item.n, i: item, hits }));
    const busy = items.filter((i) => i.task), free = items.filter((i) => !i.task);
    const out = [];
    if (busy.length) out.push({ head: "Con agente" }, ...busy.map((i) => ({ key: "i" + i.n, i })));
    if (free.length) out.push({ head: busy.length ? "Sin empezar" : "Issues abiertos", note: String(free.length) }, ...free.map((i) => ({ key: "i" + i.n, i })));
    return out;
  }

  empty() { return this.data.repo ? "No hay issues abiertos." : "Esta carpeta no es un proyecto con GitHub."; }

  draw(t, r, on) {
    const i = r.i;
    const working = i.task?.status === "in_progress";
    return h_flex().flex_1().min_w(0).gap(10).items_center()
      .child(div().flex_1().min_w(0).child(lit(t, "#" + i.n + " " + i.title, r.hits, on ? t.foreground : t.muted)))
      .children((i.labels ?? []).slice(0, 2).map((l) => pill(t, l, t.ansi4 ?? t.accent)))
      .when(Boolean(i.pr), (el) => el.child(pill(t, "PR #" + i.pr, t.done)))
      .when(Boolean(i.task), (el) => el.child(h_flex().flex_none().gap(6).items_center().child(dot(t, working ? "working" : "blocked"))
        .child(div().text_size(11.5).text_color(working ? t.working : t.blocked).child(STATUS[i.task?.status] ?? i.task?.status ?? ""))))
      .child(div().flex_none().w(44).text_size(11).text_color(t.dim).child(since(i.updated)));
  }

  hints(row) {
    const go = row?.i?.task ? "ir a su agente" : "lanzar el agente";
    return [["enter", go], ["tab", "rol"], ["ctrl-o", "ver en GitHub"], ["ctrl-r", "recargar"], ["escape", "cerrar"]];
  }

  key(e, row) {
    if (e.key === "tab") { this.role = (this.role + 1) % ROLES.length; return true; }
    if (e.modifiers.control && e.key === "o" && row) { openUrl(row.i.url); return true; }
    return false;
  }

  enter(r) {
    const i = r.i;
    if (i.task) {
      const term = agentTerm(i.task.window, this.data.project);
      if (term) { this.close(); return reveal(term); }
      return notify({ title: "#" + i.n, body: "ya tiene la tarea " + i.task.id + " (" + (STATUS[i.task.status] ?? i.task.status) + ") y su agente no tiene una terminal abierta", level: "info" });
    }
    this.close();
    const role = ROLES[this.role];
    launch("Agente para #" + i.n, ["run", String(i.n), ...(role ? ["--role", role] : [])], this.dir);
  }
}
