// El lado derecho de bk en Herdr: lo que mostraba el riel de tmux (lib/rail.py), dibujado por Herdr.
// Estado (proyecto, rama, perfil de roles, uso de hoy), GitHub y lo que quedó sin
// commitear en el proyecto y en sus worktrees. Los datos salen de `bk _side <carpeta>` (lib/herdr_side.py),
// para la carpeta de la terminal que mirás. Los agentes viven en el panel nativo de la barra izquierda.
// Solo lee.

import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { exec, focused, theme, home } from "herdr";

const EVERY = 4000;        // git es barato: el panel sigue lo que pasa
const USAGE_EVERY = 60000; // el uso lee los transcripts: más espaciado
const SHORT = { implementer: "impl", "implementer-light": "light", reviewer: "review", planner: "plan", orchestrator: "orq" };


function human(n) {
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)}k`;
  return String(Math.round(n ?? 0));
}

export default class Lado extends View {
  init(_props, cx) {
    this.data = null;
    this.usage = null;
    this.usageAt = 0;
    this.error = null;
    this.github = null;
    this.githubError = null;
    this.githubAt = 0;
    this.busy = false;
    const tick = async (cx) => {
      if (this.busy) return;   // una corrida lenta no se pisa con la siguiente
      this.busy = true;
      try {
        await this.load();
      } finally {
        this.busy = false;
      }
      cx.notify();
    };
    cx.spawn(tick);
    cx.timer.every(EVERY, (cx) => cx.spawn(tick));
    const githubTick = async (cx) => {
      const cwd = focused()?.cwd || home();
      if (this.githubBusy || this.githubCwd === cwd && Date.now() - this.githubAt < 60000) return;
      this.githubBusy = true;
      if (this.githubCwd !== cwd) { this.github = null; this.githubError = null; }
      this.githubCwd = cwd;
      this.githubAt = Date.now();
      await this.loadGithub(cwd);
      this.githubBusy = false;
      cx.notify();
    };
    cx.spawn(githubTick);
    cx.timer.every(EVERY, (cx) => cx.spawn(githubTick));
  }

  async load() {
    const cwd = focused()?.cwd || home();
    const now = Date.now();
    const withUsage = now - this.usageAt >= USAGE_EVERY || this.cwd !== cwd;
    try {
      const r = await exec("bk", ["_side", cwd, ...(withUsage ? ["--usage"] : [])], { timeout: 25000 });
      if (r.code !== 0) throw new Error(r.stderr.trim() || `bk _side salió con ${r.code}`);
      const d = JSON.parse(r.stdout);
      if (withUsage) {
        this.usage = d.usage ?? null;
        this.usageAt = now;
      }
      this.data = d;
      this.cwd = cwd;
      this.error = null;
    } catch (e) {
      this.error = String(e?.message ?? e);
    }
  }

  async loadGithub(cwd) {
    try {
      const repo = await exec("gh", ["repo", "view", "--json", "nameWithOwner,url"], { cwd, timeout: 10000 });
      if (repo.code !== 0) throw new Error("GitHub indisponible · revisá gh auth status");
      const prs = await exec("gh", ["pr", "list", "--limit", "4", "--json", "number,title,url,isDraft,reviewDecision,statusCheckRollup"], { cwd, timeout: 10000 });
      if (prs.code !== 0) throw new Error("No se pudieron consultar los PRs");
      this.github = { ...JSON.parse(repo.stdout), prs: JSON.parse(prs.stdout) };
      this.githubError = null;
    } catch (e) { this.githubError = String(e?.message ?? e); }
  }

  card(t, title, right, body) {
    return v_flex()
      .flex_none()
      .rounded(12)
      .border(1)
      .border_color(t.border)
      .bg(t.surface)
      .child(h_flex().px(12).pt(10).pb(6).gap(8).items_center()
        .child(div().flex_1().min_w(0).truncate().text_size(11.5).font_semibold().text_color(t.accent).child(title))
        .when(Boolean(right), (el) => el.child(div().flex_none().text_size(11).text_color(t.dim).child(right ?? ""))))
      .child(v_flex().px(12).pb(11).gap(5).children(body));
  }

  // wrap: el valor sigue en otra línea en vez de cortarse (el perfil de roles no entra en una)
  kv(t, key, value, extra = null, wrap = false) {
    const text = div().flex_1().min_w(0).text_color(t.foreground).child(value);
    return h_flex().gap(8).when(!wrap, (el) => el.items_center()).when(wrap, (el) => el.items_start())
      .child(div().w(70).flex_none().whitespace_nowrap().text_color(t.dim).child(key))
      .child(wrap ? text : text.truncate())
      .when(Boolean(extra), (el) => el.child(extra));
  }

  estado(t, d) {
    const dirty = d.dirty ? div().flex_none().text_color(t.ansi3 ?? t.working).child(`±${d.dirty}`) : null;
    // Fuera de un proyecto (el centro de tareas, una terminal en ~) no hay rama ni perfil que mostrar
    const rows = d.project ? [
      this.kv(t, "Proyecto", d.project),
      this.kv(t, "Rama", d.branch || "—", dirty),
      this.kv(t, "Perfil", d.profile.map((p) => `${SHORT[p.role] ?? p.role} ${p.model}`).join(" · ") || "—", null, true),
    ] : [div().id("lado-sin-proyecto").text_color(t.dim).child(`${d.path} · fuera de un proyecto`)];
    // El contexto de la sesión de Claude de esta carpeta: ámbar desde 200k, rojo desde 400k (los umbrales de lib/usage.py)
    const c = d.context;
    if (c) {
      const color = c.level === "high" ? (t.ansi1 ?? t.blocked) : c.level === "warn" ? (t.ansi3 ?? t.working) : t.foreground;
      const hint = c.level === "high" ? "sesión muy larga: conviene cortarla" : c.level === "warn" ? "sesión larga" : "";
      rows.push(h_flex().id("lado-contexto").gap(8).items_center().tooltip(`${c.tokens.toLocaleString("en-US")} tokens de contexto`)
        .child(div().w(70).flex_none().whitespace_nowrap().text_color(t.dim).child("Contexto"))
        .child(div().flex_1().min_w(0).truncate().text_color(color).child(`${Math.round(c.tokens / 1000)}k`))
        .when(Boolean(hint), (el) => el.child(div().flex_none().text_size(11).text_color(color).child(hint))));
    }
    const u = this.usage;
    if (u) {
      const here = d.project ? `${human(u.here_tokens)} · $${u.here_cost.toFixed(2)}` : `${human(u.tokens)} tok`;
      rows.push(this.kv(t, d.project ? "Hoy acá" : "Hoy", here, div().flex_none().text_color(t.dim).child(`total $${u.cost.toFixed(2)}`)));
    }
    return this.card(t, "Tu espacio", "EN FOCO", rows);
  }

  cambios(t, d) {
    const n = d.changes.reduce((s, c) => s + c.files.length + c.more, 0);
    const rows = [];
    for (const c of d.changes) {
      rows.push(h_flex().gap(6).items_center().pt(rows.length ? 5 : 0)
        .child(div().flex_none().max_w(150).truncate().font_medium().text_color(t.foreground).child(c.name))
        .child(div().flex_1().min_w(0).truncate().text_color(t.dim).child(c.branch)));
      for (const f of c.files) {
        const color = f.code.includes("U") || f.code === "AA" || f.code === "DD" ? t.ansi1 : f.code === "A" ? t.done : f.code === "D" ? t.ansi1 : t.ansi3;
        rows.push(h_flex().gap(7).items_center().text_size(12)
          .child(div().w(10).flex_none().text_color(color).child(f.code.slice(0, 1)))
          .child(div().flex_1().min_w(0).text_ellipsis_start().text_color(t.muted).child(f.path))
          .when(Boolean(f.add), (el) => el.child(div().flex_none().text_color(t.ansi2 ?? t.done).child(`+${f.add}`)))
          .when(Boolean(f.del) && f.del !== "0", (el) => el.child(div().flex_none().text_color(t.ansi1 ?? t.blocked).child(`-${f.del}`))));
      }
      if (c.more) rows.push(div().text_size(12).text_color(t.dim).child(`… y ${c.more} más`));
    }
    if (!rows.length) rows.push(div().text_color(t.dim).child("✓ Todo guardado en Git"));
    return this.card(t, "Cambios", n ? `${n} archivo${n > 1 ? "s" : ""}` : "", rows);
  }

  githubCard(t) {
    const cwd = focused()?.cwd || home();
    const g = this.githubCwd === cwd ? this.github : null;
    if (!g) return this.card(t, "GitHub", "", [div().text_size(12).text_color(this.githubError ? t.blocked : t.dim).child(this.githubError || "Conectando con el repositorio…")]);
    const open = (url) => { if (/^https:\/\/github\.com\//.test(url)) exec("open", [url]); };
    const rows = [div().id("github-repo").cursor_pointer().text_color(t.accent).truncate().tooltip(g.nameWithOwner).on_click(() => open(g.url)).child(`${g.nameWithOwner} ↗`)];
    for (const pr of g.prs) {
      const checks = pr.statusCheckRollup ?? [];
      const failed = checks.some((c) => ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].includes(c.conclusion || c.state));
      const pending = checks.some((c) => (c.status && c.status !== "COMPLETED") || ["PENDING", "EXPECTED"].includes(c.state));
      const state = pr.isDraft ? "Borrador" : failed ? "CI falló" : pr.reviewDecision === "CHANGES_REQUESTED" ? "Cambios pedidos" : pending ? "CI en curso" : pr.reviewDecision === "APPROVED" ? "Aprobado" : "En revisión";
      const color = failed ? t.ansi1 : pr.reviewDecision === "CHANGES_REQUESTED" ? t.blocked : pr.reviewDecision === "APPROVED" && !pending && !pr.isDraft ? t.done : t.accent;
      rows.push(v_flex().id(`github-pr-${pr.number}`).p(8).gap(4).rounded(8).bg(t.background).cursor_pointer().hover((s) => s.bg(t.hover)).tooltip(pr.title).on_click(() => open(pr.url))
        .child(h_flex().justify_between().gap(8).child(div().font_medium().text_color(t.accent).child(`#${pr.number}`)).child(div().text_size(11).text_color(color).child(state)))
        .child(div().truncate().text_color(t.foreground).child(pr.title)));
    }
    if (!g.prs.length) rows.push(div().text_color(t.done).child("✓ Sin pull requests abiertos"));
    return this.card(t, "GitHub", g.prs.length ? "PRs recientes" : "AL DÍA", rows);
  }

  render() {
    const t = theme();
    const d = this.data;
    const cards = [];
    if (this.error) cards.push(this.card(t, "bk", "", [div().text_color(t.blocked).child(`No pude leer el estado: ${this.error}`)]));
    if (d) cards.push(this.estado(t, d));
    if (d?.project) cards.push(this.githubCard(t));
    if (d) cards.push(this.cambios(t, d));
    if (!d && !this.error) cards.push(div().px(4).text_color(t.dim).child("Leyendo…"));
    return v_flex().id("lado").size_full().min_h(0).gap(12).text_size(12.5).overflow_y_scrollbar().children(cards);
  }
}
