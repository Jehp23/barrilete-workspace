// El lado derecho de bk en Herdr: lo que mostraba el riel de tmux (lib/rail.py), en tres tarjetas de marco
// redondeado con el título sobre la línea, como las de la TUI de bk.
//   SESIÓN   proyecto, rama, cuenta, contexto de la sesión de Claude, uso de hoy y perfil de roles
//   GITHUB   el repo y sus PRs abiertos, cada uno con su estado en color
//   CAMBIOS  lo que quedó sin commitear en el proyecto y en sus worktrees, con +/−
// Los datos salen de `bk _side <carpeta>` (lib/herdr_side.py) para la carpeta de la terminal que mirás, cada
// 4 s (el uso, cada minuto); los PRs, de `gh pr list`, una vez por minuto y por carpeta. Solo lee, y solo se
// redibuja cuando algo cambió.

import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { exec, focused, terminals, theme, home, shared } from "herdr";
import { ICONS, PROSE, al, card, pill } from "./kit.js";

const EVERY = 4000;        // git es barato: el panel sigue lo que pasa
const SLOW = 60000;        // el uso lee los transcripts y gh sale a la red: una vez por minuto
const CTX_FULL = 500000;   // el largo de la barra de contexto (ámbar desde 200k, rojo desde 400k: lib/usage.py)
const MAX_FILES = 14;      // archivos a la vista por worktree; el resto se cuenta
const SHORT = { implementer: "impl", "implementer-light": "light", reviewer: "review", planner: "plan", orchestrator: "orq" };
const BAD = ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"];
const bin = () => shared("bk.bin") || "bk";

function human(n) {
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  if (n >= 1e3) return `${Math.round(n / 1e3)}k`;
  return String(Math.round(n ?? 0));
}

// "git@github.com:dueña/repo.git" o "https://github.com/dueña/repo" → "dueña/repo"
const slug = (url) => (url ?? "").trim().match(/github\.com[:/]([^/\s]+\/[^/\s]+?)(?:\.git)?$/)?.[1] ?? null;

export default class Lado extends View {
  init(_props, cx) {
    this.data = null;
    this.raw = "";
    this.usage = null;
    this.usageAt = 0;
    this.error = null;
    this.gh = new Map();   // carpeta → { at, repo, prs, error }
    this.busy = false;
    const tick = async (cx) => {
      if (this.busy) return;   // una corrida lenta no se pisa con la siguiente
      this.busy = true;
      let changed = false;
      try {
        changed = await this.load();
        if (await this.loadGithub()) changed = true;
      } finally {
        this.busy = false;
      }
      if (changed) cx.notify();
    };
    cx.spawn(tick);
    cx.timer.every(EVERY, (cx) => cx.spawn(tick));
  }

  // true si lo que se muestra cambió
  async load() {
    const cwd = focused()?.cwd || home();
    const now = Date.now();
    const withUsage = now - this.usageAt >= SLOW || this.cwd !== cwd;
    const before = this.raw + (this.error ?? "");
    try {
      const r = await exec(bin(), ["_side", cwd, ...(withUsage ? ["--usage"] : [])], { timeout: 25000 });
      if (r.code !== 0) throw new Error(r.stderr.trim() || `bk _side salió con ${r.code}`);
      const d = JSON.parse(r.stdout);
      if (withUsage) {
        this.usage = d.usage ?? null;
        this.usageAt = now;
      }
      delete d.usage;
      this.data = d;
      this.raw = JSON.stringify([d, this.usage]);
      this.cwd = cwd;
      this.error = null;
    } catch (e) {
      this.error = String(e?.message ?? e);
    }
    return before !== this.raw + (this.error ?? "");
  }

  // Los PRs de la carpeta que mirás: una llamada a gh por minuto y por carpeta. true si cambió algo.
  async loadGithub() {
    const cwd = this.cwd;
    if (!cwd || !this.data?.project) return false;
    const had = this.gh.get(cwd);
    if (had && Date.now() - had.at < SLOW) return false;
    const next = { at: Date.now(), repo: had?.repo ?? null, prs: had?.prs ?? null, error: null };
    this.gh.set(cwd, next);
    try {
      // El repo se pregunta una sola vez por carpeta: primero al remoto de git (no sale a la red) y, si no
      // se llama origin o no es de GitHub, a gh.
      if (!next.repo) {
        const origin = await exec("git", ["-C", cwd, "remote", "get-url", "origin"], { timeout: 5000 });
        next.repo = slug(origin.stdout);
      }
      if (!next.repo) {
        const view = await exec("gh", ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"], { cwd, timeout: 12000 });
        next.repo = view.code === 0 ? view.stdout.trim() || null : null;
      }
      if (!next.repo) throw new Error("esta carpeta no tiene un repo de GitHub (o falta gh auth login)");
      const prs = await exec("gh", ["pr", "list", "--limit", "5", "--json", "number,title,url,isDraft,reviewDecision,statusCheckRollup"], { cwd, timeout: 12000 });
      if (prs.code !== 0) throw new Error("gh no respondió · revisá gh auth status");
      next.prs = JSON.parse(prs.stdout);
    } catch (e) { next.error = String(e?.message ?? e); }
    return JSON.stringify([had?.repo, had?.prs, had?.error]) !== JSON.stringify([next.repo, next.prs, next.error]);
  }

  // Una fila "clave   valor [algo a la derecha]", con las claves en una columna.
  kv(t, key, value, extra = null) {
    return h_flex().gap(8).items_center().min_h(18)
      .child(div().w(66).flex_none().whitespace_nowrap().text_color(t.dim).child(key))
      .child(typeof value === "string" ? div().flex_1().min_w(0).truncate().text_color(t.foreground).child(value) : value)
      .when(Boolean(extra), (el) => el.child(extra));
  }

  sesion(t, d) {
    if (!d.project) {
      return card(t, "SESIÓN", "sin proyecto", [
        this.kv(t, "Carpeta", div().id("lado-sin-proyecto").flex_1().min_w(0).text_ellipsis_start().text_color(t.muted).tooltip(d.path).child(d.path)),
        ...this.uso(t, d),
      ]);
    }
    const term = focused()?.terminal;
    const labels = term ? terminals().find((x) => x.address === term)?.labels : null;
    const account = labels?.["bk.account"];
    const dirty = d.dirty ? pill(t, `±${d.dirty}`, t.blocked) : null;
    const rows = [
      this.kv(t, "Proyecto", div().flex_1().min_w(0).truncate().font_medium().text_color(t.foreground).child(d.project)),
      this.kv(t, "Rama", h_flex().flex_1().min_w(0).gap(5).items_center()
        .child(svg(ICONS + "git-branch.svg").size(12).flex_none().text_color(t.accent))
        .child(div().min_w(0).truncate().text_color(t.foreground).child(d.branch || "—")), dirty),
      this.kv(t, "Cuenta", div().flex_1().min_w(0).truncate().text_color(account ? t.working : t.muted).child(account || "la de siempre")),
    ];
    // El contexto de la sesión de Claude de esta carpeta: una barra que se llena, ámbar desde 200k, rojo desde 400k.
    const c = d.context;
    if (c) {
      const color = c.level === "high" ? t.ansi1 : c.level === "warn" ? t.blocked : t.done;
      const hint = c.level === "high" ? "sesión muy larga: conviene cortarla (/clear o chat nuevo)" : c.level === "warn" ? "sesión larga" : "contexto de la sesión de Claude de esta carpeta";
      rows.push(h_flex().id("lado-contexto").gap(8).items_center().min_h(18).tooltip(`${c.tokens.toLocaleString("es-AR")} tokens · ${hint}`)
        .child(div().w(66).flex_none().text_color(t.dim).child("Contexto"))
        .child(div().flex_1().h(5).rounded_full().bg(t.raised).child(div().h(5).rounded_full().bg(color).w(`${Math.max(4, Math.min(100, Math.round((c.tokens / CTX_FULL) * 100)))}%`)))
        .child(div().flex_none().w(38).text_right().text_color(c.level ? color : t.foreground).child(`${Math.round(c.tokens / 1000)}k`)));
    }
    rows.push(...this.uso(t, d));
    if (d.profile?.length) {
      rows.push(h_flex().gap(8).items_start().min_h(18)
        .child(div().w(66).flex_none().text_color(t.dim).child("Perfil"))
        .child(h_flex().flex_1().min_w(0).flex_wrap().gap_x(10).gap_y(3).children(d.profile.map((p) => h_flex().flex_none().gap(4)
          .child(div().text_color(t.dim).child(SHORT[p.role] ?? p.role))
          .child(div().text_color(t.muted).child(p.model))))));
    }
    const n = labels?.["bk.id"];
    return card(t, "SESIÓN", n ? `ventana ${n}` : "", rows);
  }

  uso(t, d) {
    const u = this.usage;
    if (!u) return [];
    const here = d.project ? `${human(u.here_tokens)} · $${u.here_cost.toFixed(2)}` : `${human(u.tokens)} · $${u.cost.toFixed(2)}`;
    const total = d.project && Math.abs(u.cost - u.here_cost) >= 0.01 ? div().flex_none().text_size(11).text_color(t.dim).child(`de $${u.cost.toFixed(2)}`) : null;
    return [this.kv(t, d.project ? "Hoy acá" : "Hoy", here, total)];
  }

  github(t) {
    const g = this.gh.get(this.cwd);
    const open = (url) => { if (/^https:\/\/github\.com\//.test(url)) exec("open", [url]); };
    if (!g || (!g.prs && !g.error)) return card(t, "GITHUB", "", [div().text_color(t.dim).child("Consultando…")]);
    const rows = [];
    if (g.repo) {
      rows.push(h_flex().id("github-repo").gap(6).items_center().cursor_pointer().text_color(t.muted).hover((s) => s.text_color(t.accent)).tooltip("Abrir en GitHub")
        .on_click(() => open(`https://github.com/${g.repo}`))
        .child(div().flex_1().min_w(0).truncate().child(g.repo))
        .child(div().flex_none().text_color(t.dim).child("↗")));
    }
    if (g.error && !g.prs) rows.push(div().text_color(t.blocked).child(g.error));
    for (const pr of g.prs ?? []) {
      const checks = pr.statusCheckRollup ?? [];
      const failed = checks.some((c) => BAD.includes(c.conclusion || c.state));
      const pending = checks.some((c) => (c.status && c.status !== "COMPLETED") || ["PENDING", "EXPECTED"].includes(c.state));
      const [state, color] = pr.isDraft ? ["borrador", t.dim]
        : failed ? ["CI falló", t.ansi1]
        : pr.reviewDecision === "CHANGES_REQUESTED" ? ["cambios pedidos", t.blocked]
        : pending ? ["CI en curso", t.working]
        : pr.reviewDecision === "APPROVED" ? ["aprobado", t.done]
        : ["en revisión", t.accent];
      rows.push(v_flex().id(`github-pr-${pr.number}`).mx(-6).px(6).py(4).gap(3).rounded(6).cursor_pointer().hover((s) => s.bg(t.hover)).tooltip(pr.title)
        .on_click(() => open(pr.url))
        .child(h_flex().gap(8).items_center()
          .child(div().flex_none().font_medium().text_color(t.accent).child(`#${pr.number}`))
          .child(div().flex_1())
          .child(pill(t, state, color)))
        .child(div().truncate().font_family(PROSE).text_size(12.5).text_color(t.foreground).child(pr.title)));
    }
    if (g.prs && !g.prs.length) rows.push(div().text_color(t.dim).child("Sin pull requests abiertos"));
    const n = g.prs?.length ?? 0;
    return card(t, "GITHUB", n ? `${n} PR${n > 1 ? "s" : ""} abierto${n > 1 ? "s" : ""}` : g.prs ? "al día" : "", rows);
  }

  cambios(t, d) {
    const n = d.changes.reduce((s, c) => s + c.files.length + c.more, 0);
    const rows = [];
    for (const c of d.changes) {
      rows.push(h_flex().gap(6).items_center().pt(rows.length ? 4 : 0)
        .child(div().flex_none().max_w(150).truncate().font_medium().text_color(t.foreground).child(c.name))
        .child(div().flex_1().min_w(0).truncate().text_size(11).text_color(t.dim).child(c.branch && c.branch !== c.name ? c.branch : ""))
        .child(div().flex_none().text_size(11).text_color(t.dim).child(String(c.files.length + c.more))));
      for (const f of c.files.slice(0, MAX_FILES)) {
        const color = f.code.includes("U") || f.code === "AA" || f.code === "DD" || f.code === "D" ? t.ansi1 : f.code === "A" ? t.done : t.blocked;
        rows.push(h_flex().gap(7).items_center().text_size(11.5).h(17)
          .child(div().w(9).flex_none().font_medium().text_color(color).child(f.code.slice(0, 1)))
          .child(div().flex_1().min_w(0).text_ellipsis_start().text_color(t.muted).child(f.path))
          .child(div().flex_none().min_w(30).text_right().text_color(t.done).child(f.add && f.add !== "0" ? `+${f.add}` : ""))
          .child(div().flex_none().min_w(30).text_right().text_color(t.ansi1).child(f.del && f.del !== "0" ? `−${f.del}` : "")));
      }
      const rest = c.more + Math.max(0, c.files.length - MAX_FILES);
      if (rest) rows.push(div().text_size(11).text_color(t.dim).child(`… y ${rest} más`));
    }
    if (!rows.length) rows.push(h_flex().gap(6).items_center().text_color(t.dim).child(svg(ICONS + "check.svg").size(12).flex_none().text_color(t.done)).child("Todo guardado en Git"));
    return card(t, "CAMBIOS", n ? `${n} archivo${n > 1 ? "s" : ""}` : "", rows);
  }

  render() {
    const t = theme();
    const d = this.data;
    const cards = [];
    if (this.error) cards.push(card(t, "BK", "", [div().text_color(t.blocked).child(`No pude leer el estado: ${this.error}`)], { color: al(t.blocked, "66") }));
    if (d) cards.push(this.sesion(t, d));
    if (d?.project) cards.push(this.github(t));
    if (d) cards.push(this.cambios(t, d));
    if (!d && !this.error) cards.push(card(t, "SESIÓN", "", [div().text_color(t.dim).child("Leyendo…")]));
    return v_flex().id("lado").size_full().min_h(0).pb(8).gap(8).text_size(12).overflow_y_scrollbar().children(cards);
  }
}
