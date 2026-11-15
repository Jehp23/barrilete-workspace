// alt+s: las sesiones de Claude (lo que hacía bk s): saltar a una abierta o retomar una reciente. Cada abierta lleva
// el número fijo de su ventana (el de alt+N), su estado, su pestaña y su proyecto, para saber cuál es cuál.
// Enter sobre una abierta muestra su pestaña (nativo, al instante); sobre una reciente, bk la retoma en un chat
// nuevo de su proyecto (bk _hub session-go); sobre una abierta fuera de Herdr (tmux u otra terminal) solo avisa.
// ctrl+x dos veces sobre una abierta la cierra: bk stop si es un agente del kit; si no, su pestaña (o solo su pane,
// si la pestaña tiene más). Los datos: bk _hub sessions.

import { div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { terminals, spaces, panes, run, notify } from "herdr";
import { Panel, rank, bk, launch, chips, lit, pill, dot, ago, tilde, reveal, lastLine } from "./kit.js";

const SURE_MS = 4000;   // cuánto espera el segundo ctrl+x
const ID_W = 22;
// Estado que anota el hook de bk → [punto (dot de kit), palabra, color del tema]
const STATE = {
  working: ["working", "trabajando", "working"],
  background: ["working", "en 2º plano", "working"],
  waiting: ["waiting", "te espera", "blocked"],
  permission: ["waiting", "pide permiso", "blocked"],
  question: ["waiting", "te pregunta", "blocked"],
  trust: ["waiting", "confiá la carpeta", "blocked"],
  stale: ["waiting", "¿trabado?", "blocked"],
  error: ["fail", "error", "ansi1"],
  done: ["done", "", "done"],
  idle: ["idle", "", "dim"],
  ended: [null, "terminó", "dim"],
};
const stateOf = (state) => STATE[state] ?? [null, state || "", "dim"];

export default class Sessions extends Panel {
  setup() {
    this.title = "Sesiones";
    this.placeholder = "Título, proyecto o número…";
    this.data = { open: [], recent: [] };
    this.confirm = null;        // sid de la que espera el segundo ctrl+x
    this.closing = new Set();   // las que cerré acá: se van de la lista cuando su terminal muere
    this.ids = false;
  }

  async load() {
    this.data = await bk(["_hub", "sessions"], { json: true, timeout: 20000 });
  }

  subtitle() {
    const wait = (this.data.open ?? []).filter((s) => stateOf(s.state)[0] === "waiting").length;
    return wait ? (wait === 1 ? "1 te espera" : `${wait} te esperan`) : "";
  }

  rows() {
    const live = new Map(terminals().filter((x) => x.state === "live").map((x) => [x.address, x]));
    const tabs = new Map(spaces().flatMap((sp) => sp.tabs.map((tb) => [tb.id, tb])));
    const open = (this.data.open ?? []).map((s) => {
      const term = s.terminal ? live.get(s.terminal) ?? null : null;
      const tab = tabs.get(term?.labels?.["herdr.tab"]);
      // away: bk dice que no vive en Herdr (tmux u otra terminal). Con terminal pero sin verla viva acá, se le pregunta a bk.
      const away = !s.terminal;
      const place = tab ? (tab.named ? tab.name : "pestaña " + tab.name) : term ? "sin pestaña" : !away ? "sin terminal" : s.where ? s.where + " · tmux" : "fuera de Herdr";
      return { key: "o-" + s.sid, open: true, s, sid: s.sid, title: s.title, term, away, place, id: String(term?.labels?.["bk.id"] ?? "") };
    }).filter((r) => r.term || !this.closing.has(r.sid));
    const recent = (this.data.recent ?? []).map((s) => ({ key: "r-" + s.sid, open: false, s, sid: s.sid, title: s.title }));
    const q = this.query.trim();
    const pick = (list, text) => (q ? rank(list, q, text).map(({ item, hits }) => ({ ...item, hits })) : list);
    const a = pick(open, (r) => [r.title, `${r.s.project} ${r.place} ${r.id} ${stateOf(r.s.state)[1]}`]);
    const b = pick(recent, (r) => [r.title, `${r.s.project} ${tilde(r.s.cwd)}`]);
    this.ids = a.some((r) => r.id);
    const out = [];
    if (a.length) out.push({ head: "Abiertas", note: String(a.length) }, ...a);
    if (b.length) out.push({ head: "Recientes", note: String(b.length) }, ...b);
    return out;
  }

  empty() { return "No hay sesiones de Claude."; }

  draw(t, r, on) {
    const s = r.s;
    const small = (text, color) => div().flex_none().text_size(11.5).text_color(color ?? t.dim).child(text);
    const age = div().flex_none().w(44).flex().justify_end().text_size(11).text_color(t.dim).child(ago(s.age_min));
    const title = div().flex_1().min_w(0).child(lit(t, r.title, r.hits, on ? t.foreground : t.muted));
    // el número y el punto van en columnas fijas: los títulos de las dos listas quedan alineados
    const row = h_flex().flex_1().min_w(0).gap(9).items_center()
      .when(this.ids, (el) => el.child(div().w(ID_W).flex_none().flex().justify_center().when(Boolean(r.id), (c) => c.child(chips(t, r.id, on)))));
    if (!r.open) {
      return row.child(div().w(12).flex_none()).child(title)
        .when(Boolean(s.handoff), (el) => el.child(pill(t, "resumen", t.done)))
        .when(Boolean(s.account) && s.account !== "default", (el) => el.child(pill(t, s.account ?? "", t.ansi3 ?? t.dim)))
        .child(div().flex_none().max_w(170).truncate().text_size(11.5).text_color(t.dim).child(tilde(s.cwd)))
        .when(Boolean(s.project), (el) => el.child(pill(t, s.project, t.accent)))
        .child(age);
    }
    const [point, word, color] = stateOf(s.state);
    const sure = this.confirm === r.sid;
    return row.child(div().w(12).flex_none().flex().justify_center().child(dot(t, point))).child(title)
      .when(sure, (el) => el.child(small("ctrl+x de nuevo para cerrar", t.blocked)))
      .when(!sure && Boolean(word), (el) => el.child(small(word, t[color] ?? t.dim)))
      .when(Boolean(s.handoff), (el) => el.child(pill(t, "resumen", t.done)))
      .child(div().flex_none().max_w(150).truncate().text_size(11.5).text_color(t.dim).child(r.place))
      .when(Boolean(s.project), (el) => el.child(pill(t, s.project, t.accent)))
      .child(age);
  }

  hints(row) {
    const tail = [["ctrl-r", "recargar"], ["escape", "salir"]];
    if (!row) return tail;
    if (!row.open) return [["enter", "retomar en un chat nuevo"], ...tail];
    if (row.away) return tail;   // fuera de Herdr: no hay a dónde saltar
    if (!row.term) return [["enter", "buscarla con bk"], ...tail];
    return [["enter", "ir a su pestaña"], ["ctrl-x", this.confirm === row.sid ? "de nuevo para cerrar" : "cerrar"], ...tail];
  }

  moved() {
    if (this.confirm && this.confirm !== this.current()?.sid) this.confirm = null;
  }

  enter(r) {
    // Abierta en tmux u otra terminal: no hay pestaña que mostrar, y retomarla acá la duplicaría. El panel queda.
    if (r.open && r.away) {
      const body = `«${r.title}» corre en tmux u otra terminal: desde acá no se puede saltar a ella.`;
      return notify({ title: "Esa sesión está abierta fuera de Herdr", body, level: "warning", timeout: 6000 });
    }
    this.close();
    if (r.open && r.term) {
      if (r.term.labels?.["herdr.tab"]) return reveal(r.term);
      return run("terminal.peek", { terminal: r.term.address });   // sin pestaña (un subagente): se la espía
    }
    launch("Retomar " + r.title, ["_hub", "session-go", r.sid]);
  }

  key(e, row, cx) {
    if (!e.modifiers.control || e.key !== "x") return false;
    if (row?.open) this.shut(row, cx);
    return true;
  }

  // El primer ctrl+x pregunta (en la fila y en el pie); el segundo, sobre la misma fila, cierra.
  shut(row, cx) {
    const x = row.term, name = `«${row.title}»`;
    if (!x) return notify({ title: `No cierro ${name}`, body: "No vive en Herdr: cerrala en la terminal donde corre.", level: "warning", timeout: 5000 });
    if (this.confirm !== row.sid) {
      this.confirm = row.sid;
      const n = (this.asked = (this.asked ?? 0) + 1);
      cx.timer.after(SURE_MS, (cx) => {
        if (this.asked !== n || !this.confirm) return;
        this.confirm = null;
        cx.notify();
      });
      return;
    }
    this.confirm = null;
    const L = x.labels ?? {};
    if (L["bk.kind"] === "agent" && L["bk.win"]) {
      return this.work(cx, "cerrando…", async () => {
        let ok = false, body = "";
        try {
          const r = await bk(["stop", L["bk.win"]], { timeout: 30000 });
          ok = r.code === 0;
          body = ok ? lastLine(r.stdout) : lastLine(r.stderr) || `bk stop salió con ${r.code}`;
        } catch (err) {
          body = String(err?.message ?? err);
        }
        notify({ title: ok ? `Cerré ${name}` : `No pude cerrar ${name}`, body, level: ok ? "success" : "error" });
        if (ok) this.closing.add(row.sid);
        try { await this.load(); } catch (_) { /* queda la lista que había */ }
      });
    }
    // Un chat u otra cosa: su pestaña si es lo único que tiene; si no, solo su pane. Sin pane, su terminal.
    const pane = panes().find((p) => p.terminal === x.address);
    if (pane && panes().filter((p) => p.tab === pane.tab).length === 1) run("tab.close", { id: pane.tab, confirmed: true });
    else if (pane) run("pane.close", { pane: pane.pane });
    else run("terminal.kill", { terminal: x.address });
    this.closing.add(row.sid);
    notify({ title: `Cerré ${name}`, body: [row.id ? "ventana " + row.id : "", row.s.project, row.place].filter(Boolean).join(" · "), level: "info", timeout: 3000 });
    cx.timer.after(900, (cx) => this.reload(cx));   // ya sin su terminal, bk la pasa a recientes
  }
}
