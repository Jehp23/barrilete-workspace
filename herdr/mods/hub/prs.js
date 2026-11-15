// alt+r: los pull requests abiertos del proyecto que mirás. Enter lanza al reviewer del kit (bk review <n>); si el
// kit ya lo propuso (tarea pr<n>-reviewer por aprobar) lo aprueba, y si ya corre va a su pestaña. Tab pide una
// instrucción y lanza al implementer sobre la rama del PR (bk fix <n> "…"). ctrl+g vuelve a correr los checks que
// fallaron. Mergear sigue siendo tuyo: ctrl+o lo abre en GitHub. Los datos: bk _hub prs.

import { div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { notify } from "herdr";
import { Panel, rank, bk, launch, cwd, lit, pill, agentTerm, reveal, openUrl } from "./kit.js";

const CI = { ok: ["CI ok", "done"], fail: ["CI falló", "ansi1"], pending: ["CI corriendo", "working"] };
const REVIEW = { approved: ["aprobado", "done"], changes: ["cambios pedidos", "blocked"], required: ["falta review", "dim"] };

export default class Prs extends Panel {
  setup() {
    this.title = "Revisar o corregir un PR";
    this.placeholder = "Número, rama o palabras del título…";
    this.dir = cwd();
    this.data = { items: [] };
  }

  subtitle() {
    const d = this.data;
    return [d.repo || d.project, d.stale ? "sin conexión: lista vieja" : null].filter(Boolean).join(" · ");
  }

  async load() {
    this.data = await bk(["_hub", "prs", this.dir], { json: true, timeout: 25000 });
  }

  rows() {
    const items = this.data.items ?? [];
    const found = rank(items, this.query, (p) => ["#" + p.n + " " + p.title, p.branch + " " + p.author]);
    if (this.query.trim()) return found.map(({ item, hits }) => ({ key: "p" + item.n, p: item, hits }));
    const wait = items.filter((p) => p.task?.status === "pending"), rest = items.filter((p) => p.task?.status !== "pending");
    const out = [];
    if (wait.length) out.push({ head: "Reviewer por aprobar" }, ...wait.map((p) => ({ key: "p" + p.n, p })));
    if (rest.length) out.push({ head: "Abiertos", note: String(rest.length) }, ...rest.map((p) => ({ key: "p" + p.n, p })));
    return out;
  }

  empty() { return this.data.repo ? "No hay pull requests abiertos." : "Esta carpeta no es un proyecto con GitHub."; }

  draw(t, r, on) {
    const p = r.p;
    const ci = CI[p.ci], rv = REVIEW[p.review];
    const pending = p.task?.status === "pending";
    return h_flex().flex_1().min_w(0).gap(10).items_center()
      .child(div().flex_1().min_w(0).child(lit(t, "#" + p.n + " " + p.title, r.hits, on ? t.foreground : t.muted)))
      .when(Boolean(p.draft), (el) => el.child(pill(t, "borrador", t.dim)))
      .when(Boolean(ci), (el) => el.child(pill(t, ci[0], t[ci[1]] ?? t.dim)))
      .when(Boolean(rv), (el) => el.child(pill(t, rv[0], t[rv[1]] ?? t.dim)))
      .when(Boolean(p.task), (el) => el.child(pill(t, pending ? "reviewer propuesto" : "con agente", pending ? t.blocked : t.working)));
  }

  what(p) {
    if (p?.task?.status === "pending") return "aprobar el reviewer";
    if (p?.task) return "ir a su agente";
    return "lanzar el reviewer";
  }

  hints(row) {
    return [["enter", this.what(row?.p)], ["tab", "corregir (fix)"], ["ctrl-g", "re-correr checks"], ["ctrl-o", "ver en GitHub"], ["escape", "cerrar"]];
  }

  key(e, row) {
    if (!row) return false;
    const p = row.p;
    if (e.key === "tab") {
      this.askFor({ label: "fix #" + p.n, title: "¿Qué tiene que corregir el implementer en #" + p.n + "?", help: "Trabaja sobre la rama " + p.branch + ", en su worktree.", verb: "lanzar el implementer",
        run: (text) => { this.close(); launch("Fix PR #" + p.n, ["fix", String(p.n), text], this.dir); } });
      return true;
    }
    if (e.modifiers.control && e.key === "o") { openUrl(p.url); return true; }
    if (e.modifiers.control && e.key === "g") { this.close(); launch("Checks de #" + p.n, ["rerun", "--go", String(p.n)], this.dir); return true; }
    return false;
  }

  enter(r) {
    const p = r.p;
    if (p.task?.status === "pending") { this.close(); return launch("Reviewer PR #" + p.n, ["approve", p.task.id], this.dir); }
    if (p.task) {
      const term = agentTerm(p.task.window, this.data.project);
      if (term) { this.close(); return reveal(term); }
      return notify({ title: "PR #" + p.n, body: "tiene la tarea " + p.task.id + " y su agente no tiene una terminal abierta", level: "info" });
    }
    this.close();
    launch("Reviewer PR #" + p.n, ["review", String(p.n)], this.dir);
  }
}
