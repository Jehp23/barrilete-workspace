// alt+a: los agentes vivos de Herdr, los que te esperan arriba, y a la derecha lo último que se ve en la terminal
// del elegido. Enter va a su pestaña, Tab le escribe (bk say si es de bk, hc send si no), ctrl+x dos veces lo
// cierra (bk stop si es un agente del kit) y ctrl+o lo espía sin moverte. Los sub-agentes van bajo su padre.

import { div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { agents, terminals, panes, run, hc, notify, settings } from "herdr";
import { Panel, rank, bk, chips, lit, dot, ago, tilde, clean, lastLine, plural } from "./kit.js";

const RANK = { blocked: 4, done: 3, working: 2, idle: 1 };
const GROUPS = [
  { head: "Te esperan", has: (n) => n >= 3 },
  { head: "Trabajando", has: (n) => n === 2 },
  { head: "Quietos", has: (n) => n <= 1 },
];
const WORD = { blocked: "te espera", done: "terminó", working: "trabajando", idle: "quieto" };
const ACTIVE = ["in_progress", "waiting", "pending"];
const TOP_H = 48, SUB_H = 28;
const LINE = 17;       // alto de una línea de la vista previa
const SURE_MS = 4000;  // cuánto espera el segundo ctrl+x
const HOLD_MS = 300;   // Panel vuelve la selección al principio al salir del modo texto: se sostiene este rato
const ID_W = 22;

// Un sub-agente sin pane no está en agents(): vale lo que dice su terminal. Nunca queda "done": le avisa a su padre.
export function subStatus(k, listed) {
  const s = listed.get(k.address)?.status ?? k.status ?? null;
  return s === "error" ? "blocked" : s === "done" ? "idle" : s;
}

// La tarea del kit de esa terminal (por su ventana y su proyecto): de ahí sale el título del issue o del PR
export function taskOf(tasks, labels) {
  const mine = tasks.filter((k) => k.window && k.window === labels["bk.win"] && (!labels["bk.project"] || k.project === labels["bk.project"]));
  return mine.find((k) => ACTIVE.includes(k.status)) ?? mine.at(-1) ?? null;
}

// Cómo se llama: un agente del kit por su rol y su issue, un chat por su nombre, el resto por su título.
// win: la ventana de bk (para bk say; bk stop solo si kind es agent).
export function describe(a, x, tasks) {
  const L = x?.labels ?? {};
  const title = (a?.title || x?.title || "").trim();
  const prog = a?.program?.name || x?.program?.name || "";
  const win = L["bk.win"] ?? "";
  if (L["bk.kind"] === "agent") {
    const ref = /^\d+$/.test(L["bk.ref"] ?? "") ? `#${L["bk.ref"]}` : (L["bk.ref"] ?? "");
    return { kind: "agent", win, name: [L["bk.role"] || "agente", ref || win].filter(Boolean).join(" "), detail: taskOf(tasks, L)?.title || title || win };
  }
  if (L["bk.kind"] === "chat") {
    const name = L["bk.name"] || title || win || prog;
    return { kind: "chat", win, name, detail: L["bk.name"] && title && title !== name ? title : [prog, win].filter(Boolean).join(" · ") };
  }
  const tab = a?.tab_name && !/^\d+$/.test(a.tab_name) && a.tab_name !== prog ? a.tab_name : "";
  const name = x?.name || x?.template || title || prog || x?.address || a?.address || "";
  return { kind: "other", win: "", name, detail: [prog !== name ? prog : "", tab].filter(Boolean).join(" · ") };
}

// La pantalla como líneas, sin los renglones vacíos del final (lo último escrito queda abajo)
export function screenLines(text) {
  const lines = clean(text).replace(/\t/g, "    ").split("\n").map((l) => l.replace(/\s+$/, ""));
  while (lines.length && !lines[lines.length - 1]) lines.pop();
  return lines;
}

// hc avisa sus errores como JSON en stderr
function hcError(r) {
  try { return JSON.parse(r.stderr).error?.message ?? lastLine(r.stderr); } catch (_e) { return lastLine(r.stderr) || `hc salió con ${r.code}`; }
}
const firstLine = (s) => clean(s ?? "").split("\n").map((l) => l.trim()).find(Boolean) ?? "";

const slot = (t, status) => h_flex().w(12).flex_none().items_center().justify_center().child(dot(t, status));

export default class Agents extends Panel {
  setup(cx) {
    this.title = "Agentes";
    this.placeholder = "Buscar un agente…";
    this.listW = 440;
    this.tasks = [];
    this.noTitles = null;
    this.screen = null;    // { address, lines | error }: lo leído de la terminal que se mira
    this.seeing = null;
    this.reading = null;
    this.confirm = null;   // dirección del que espera el segundo ctrl+x
    this.target = null;    // a quién se le está escribiendo
    this.hold = null;
    this.ids = false;
    cx.timer.every(2000, (cx) => this.watch((this.target ?? this.current())?.address ?? null, cx, true));
    cx.timer.every(30000, (cx) => cx.notify());   // los "hace cuánto"
    this.moved(cx);
  }

  // Los títulos de los issues y PRs de los agentes del kit. Sin agentes del kit no hace falta preguntar.
  async load() {
    if (!terminals().some((x) => x.state === "live" && x.labels?.["bk.kind"] === "agent")) return;
    try {
      this.tasks = await bk(["_tasks"], { json: true, timeout: 20000 });
      this.noTitles = null;
    } catch (e) {
      this.noTitles = String(e?.message ?? e);
    }
  }

  subtitle() {
    if (this.noTitles) return `sin los títulos de los issues: ${this.noTitles}`;
    const all = agents();
    const wait = all.filter((a) => a.status === "blocked" || a.status === "done").length;
    return all.length ? `${plural(all.length, "vivo", "vivos")}${wait ? ` · ${wait === 1 ? "1 te espera" : `${wait} te esperan`}` : ""}` : "";
  }

  rows() {
    const list = agents();
    const live = terminals().filter((x) => x.state === "live");
    const term = new Map(live.map((x) => [x.address, x]));
    const listed = new Map(list.map((a) => [a.address, a]));
    const now = Date.now();
    const tree = (addr, depth, seen) => live.filter((k) => k.parent === addr && !seen.has(k.address)).flatMap((k) => {
      seen.add(k.address);
      return [{ k, depth }, ...tree(k.address, depth + 1, seen)];
    });
    const subs = new Map(list.map((a) => [a.address, tree(a.address, 1, new Set([a.address]))]));
    // Un sub-agente con pane también está en agents(): va bajo su padre, no suelto
    const nested = new Set([...subs.values()].flatMap((s) => s.map((x) => x.k.address)));
    const item = (a, x, extra) => {
      const address = a?.address ?? x.address;
      const at = x?.status_ms ?? null;
      return {
        key: address, address, a, ...describe(a, x, this.tasks), id: String(x?.labels?.["bk.id"] ?? ""),
        where: a?.space_name ?? "", cwd: x?.cwd ?? "", since: at ?? 0, age: at ? ago((now - at) / 60000) : "", ...extra,
      };
    };
    const tops = list.filter((a) => !nested.has(a.address)).map((a) => {
      const kids = subs.get(a.address).map(({ k, depth }) => item(listed.get(k.address) ?? null, k, { sub: true, depth, status: subStatus(k, listed), h: SUB_H }));
      const urgency = Math.max(RANK[a.status] ?? 0, ...kids.map((k) => RANK[k.status] ?? 0));
      return { ...item(a, term.get(a.address) ?? null, { status: a.status, h: TOP_H }), kids, urgency };
    }).sort((p, q) => q.urgency - p.urgency || (RANK[q.status] ?? 0) - (RANK[p.status] ?? 0) || q.since - p.since || q.a.seq - p.a.seq);
    const flat = tops.flatMap((p) => [p, ...p.kids]);
    this.ids = flat.some((r) => r.id);

    let rows = [];
    if (this.query.trim()) {
      rows = rank(flat, this.query, (r) => [r.name, `${r.detail} ${r.where} ${r.win} ${r.address} ${WORD[r.status] ?? ""} ${r.id}`])
        .map(({ item, hits }) => ({ ...item, hits }));
    } else {
      for (const g of GROUPS) {
        const members = tops.filter((p) => g.has(p.urgency));
        if (members.length) rows.push({ head: g.head, note: String(members.length) }, ...members.flatMap((p) => [p, ...p.kids]));
      }
    }
    this.keep(rows.filter((r) => !r.head));
    return rows;
  }

  // La lista se reordena sola (uno termina, otro te espera): la selección sigue al agente, no al renglón.
  keep(picks) {
    const held = this.hold && Date.now() < this.hold.until ? this.hold.address : null;
    const user = this.at !== this.lastAt || this.query !== this.lastQuery;
    const want = held ?? (user ? null : this.chosen);
    if (want) {
      const i = picks.findIndex((r) => r.address === want);
      if (i >= 0) this.at = i;
    }
    this.at = Math.max(0, Math.min(this.at, picks.length - 1));
    this.lastAt = this.at;
    this.lastQuery = this.query;
    this.chosen = picks[this.at]?.address ?? null;
  }

  moved(cx) {
    // Se salió del modo "decile" con Esc: la selección vuelve al que se le estaba escribiendo
    if (this.target && !this.ask) {
      this.hold = { address: this.target.address, until: Date.now() + HOLD_MS };
      this.target = null;
    }
    const row = this.current();
    if (this.confirm && this.confirm !== row?.address) this.confirm = null;
    this.watch(row?.address ?? null, cx);
  }

  // Lee la pantalla de esa terminal (una lectura por vez); again: aunque sea la misma que ya se mira
  watch(address, cx, again = false) {
    if (address === this.seeing && !again) return;
    this.seeing = address;
    if (!address || this.reading === address) return;
    this.reading = address;
    cx.spawn(async (cx) => {
      let screen;
      try {
        const r = await hc(["read", address, "--lines", "60"]);
        screen = r.code === 0 ? { address, lines: screenLines(r.stdout) } : { address, error: hcError(r) };
      } catch (e) {
        screen = { address, error: String(e?.message ?? e) };
      }
      if (this.reading === address) this.reading = null;
      if (this.seeing !== address) return;
      const same = this.screen?.address === address && this.screen.error === screen.error && (this.screen.lines ?? []).join("\n") === (screen.lines ?? []).join("\n");
      this.screen = screen;
      if (!same) cx.notify();
    });
  }

  draw(t, r, on) {
    const sure = this.confirm === r.address;
    const quiet = r.status === "idle" || !r.status;
    const name = div().flex_1().min_w(0).child(lit(t, r.name, r.hits, on || !quiet ? t.foreground : t.muted));
    const id = div().w(ID_W).flex_none().flex().justify_center().when(Boolean(r.id), (el) => el.child(chips(t, r.id, on)));
    if (r.sub) {
      return h_flex().flex_1().min_w(0).gap(8).items_center().text_size(12.5)
        .when(this.ids, (el) => el.child(id))
        .child(div().flex_none().pl(4 + (r.depth - 1) * 14).text_color(t.dim).child("└"))
        .child(slot(t, r.status))
        .child(name)
        .child(div().flex_none().text_size(11).text_color(sure ? t.blocked : t.dim).child(sure ? "ctrl+x de nuevo para cerrar" : r.age));
    }
    return h_flex().flex_1().min_w(0).gap(9).items_center()
      .when(this.ids, (el) => el.child(id))
      .child(slot(t, r.status))
      .child(v_flex().flex_1().min_w(0).gap(3)
        .child(h_flex().gap(8).items_center()
          .child(name)
          .child(div().flex_none().text_size(11).text_color(t.dim).child(r.age)))
        .child(h_flex().gap(8).items_center().text_size(11.5)
          .child(div().flex_1().min_w(0).truncate().text_color(sure ? t.blocked : t.dim).child(sure ? "ctrl+x de nuevo para cerrar" : r.detail))
          .child(div().flex_none().max_w(150).truncate().text_color(t.dim).child(r.where))));
  }

  side(t, row) {
    const r = row ?? this.target;
    const note = (text, color) => v_flex().flex_1().min_h(0).w_full().items_center().justify_center().px(20).text_size(12.5).text_color(color ?? t.dim).child(text);
    if (!r) return note(this.loading ? "Leyendo…" : agents().length ? "Nada coincide" : "No hay agentes vivos");
    const s = this.screen?.address === r.address ? this.screen : null;
    const fit = Math.max(4, Math.floor((this.listH - 2 - 38 - 20) / LINE));
    const lines = (s?.lines ?? []).slice(-fit);
    const head = h_flex().flex_none().h(38).px(14).gap(8).items_center().border_b(1).border_color(t.border).text_size(12)
      .child(slot(t, r.status))
      .child(div().flex_none().max_w(300).truncate().font_semibold().text_color(t.foreground).child(r.name))
      .when(Boolean(WORD[r.status]), (el) => el.child(div().flex_none().text_color(t[r.status] ?? t.dim).child(WORD[r.status] ?? "")))
      .child(div().flex_1())
      .child(div().min_w(0).truncate().text_color(t.dim).child(tilde(r.cwd)))
      .child(div().flex_none().px(6).h(18).flex().items_center().rounded(5).bg(t.raised).text_size(10.5).text_color(t.muted).child(r.address));
    const body = !s ? note(`Leyendo ${r.address}…`)
      : s.error ? note(`No pude leer ${r.address}: ${s.error}`, t.blocked)
      : !lines.length ? note("Pantalla vacía")
      : v_flex().flex_1().min_h(0).px(14).py(10).overflow_hidden().justify_end()
          .font_family(settings().font_family ?? "JetBrains Mono").text_size(12).text_color(t.foreground)
          .children(lines.map((l) => div().flex_none().h(LINE).line_height(`${LINE}px`).whitespace_nowrap().child(l.replace(/ /g, " ") || " ")));
    return v_flex().flex_1().min_h(0).w_full().child(head).child(body);
  }

  hints(row) {
    if (!row) return [["ctrl-r", "recargar"], ["escape", "cerrar"]];
    return [["enter", row.a ? "ir a su pestaña" : "espiar"], ["tab", "escribirle"], ["ctrl-o", "espiar"],
      ["ctrl-x", this.confirm === row.address ? "de nuevo para cerrar" : "cerrar"], ["escape", "salir"]];
  }

  empty() { return this.query.trim() ? null : "No hay agentes vivos. alt+i lanza uno sobre un issue."; }

  // A su pestaña. Un sub-agente sin pane no tiene pestaña: se lo espía sobre la de su padre.
  enter(row) {
    this.close();
    if (!row.a) return run("terminal.peek", { terminal: row.address });
    run("space.select", { id: row.a.space });
    run("tab.select", { id: row.a.tab });
    run("pane.focus", { terminal: row.address });
  }

  key(e, row, cx) {
    const k = e.key, m = e.modifiers;
    if (k === "tab" && !m.control && !m.shift) { if (row) this.write(row); return true; }
    if (!m.control || !row) return false;
    if (k === "x") { this.shut(row, cx); return true; }
    if (k === "o") { this.close(); run("terminal.peek", { terminal: row.address }); return true; }
    return false;
  }

  write(row) {
    this.target = row;
    this.confirm = null;
    this.askFor({
      label: "decile", verb: "mandar", title: `A ${row.name}`,
      help: row.win
        ? "Va con bk say: si está trabajando queda en cola hasta que termine el turno; si tiene un menú abierto solo pasa un número."
        : "Se pega en su terminal y aprieta Enter (hc send).",
      run: (text, cx) => this.say(row, text, cx),
    });
  }

  say(row, text, cx) {
    this.target = null;
    this.hold = { address: row.address, until: Date.now() + HOLD_MS };
    this.work(cx, "mandando…", async (cx) => {
      let ok = false, body = "";
      try {
        if (row.win) {
          const r = await bk(["say", row.win, text], { timeout: 45000 });
          ok = r.code === 0;
          body = ok ? lastLine(r.stdout) : firstLine(r.stderr) || lastLine(r.stdout) || `bk say salió con ${r.code}`;
        } else {
          const r = await hc(["send", "--", row.address, text]);
          ok = r.code === 0;
          body = ok ? text : hcError(r);
        }
      } catch (e) {
        body = String(e?.message ?? e);
      }
      notify({ title: ok ? `Le escribiste a ${row.name}` : `No le llegó a ${row.name}`, body, level: ok ? "success" : "error" });
      this.watch(row.address, cx, true);
    });
  }

  // El primer ctrl+x pregunta (en la fila y en el pie); el segundo, sobre la misma fila, cierra.
  shut(row, cx) {
    if (this.confirm !== row.address) {
      this.confirm = row.address;
      const n = (this.asked = (this.asked ?? 0) + 1);
      cx.timer.after(SURE_MS, (cx) => {
        if (this.asked !== n || !this.confirm) return;
        this.confirm = null;
        cx.notify();
      });
      return;
    }
    this.confirm = null;
    if (row.kind === "agent" && row.win) {
      return this.work(cx, "cerrando…", async () => {
        let ok = false, body = "";
        try {
          const r = await bk(["stop", row.win], { timeout: 30000 });
          ok = r.code === 0;
          body = ok ? lastLine(r.stdout) : firstLine(r.stderr) || `bk stop salió con ${r.code}`;
        } catch (e) {
          body = String(e?.message ?? e);
        }
        notify({ title: ok ? `Cerré ${row.name}` : `No pude cerrar ${row.name}`, body, level: ok ? "success" : "error" });
      });
    }
    if (!row.a) run("terminal.kill", { terminal: row.address });
    else if (panes().filter((p) => p.tab === row.a.tab).length <= 1) run("tab.close", { id: row.a.tab, confirmed: true });
    else run("pane.close", { pane: row.a.pane });
    notify({ title: `Cerré ${row.name}`, body: row.where || row.address, level: "info", timeout: 3000 });
  }
}
