// Perfiles de modelos (bk profile): un provider/modelo por rol, para todos los proyectos. Tres niveles:
//   perfiles   enter usa el perfil · → o tab lo edita · ctrl+n uno nuevo (copia del elegido) · ctrl+x dos veces lo borra
//   roles      los cinco roles del perfil con su provider/modelo · enter elige otro
//   modelos    los conocidos (claude y los que ya usan tus perfiles) y «Otro…» para escribir provider/modelo
// Lo decide y lo guarda `bk profile` (lib/profiles.py); acá solo se elige. Desde alt+k: «Perfiles de modelos».

import { div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { notify } from "herdr";
import { Panel, rank, bk, lit, pill, termPopup, bin, lastLine, cwd } from "./kit.js";

const SURE_MS = 4000;
const OTHER = "\u0000otro";

export default class Profiles extends Panel {
  setup() {
    this.title = "Perfiles de modelos";
    this.placeholder = "Perfil…";
    this.data = { profiles: [], roles: [], suggest: [] };
    this.editing = null;   // el perfil que se edita (nivel roles)
    this.role = null;      // el rol al que se le elige modelo (nivel modelos)
    this.confirm = null;
  }

  async load() {
    this.data = await bk(["profile", "--json"], { json: true, timeout: 8000 });
  }

  prof() { return this.data.profiles.find((p) => p.name === this.editing) ?? null; }

  subtitle() {
    if (this.role) return `${this.editing} › ${this.role}`;
    if (this.editing) return this.editing + (this.editing === this.data.active ? " · activo" : "");
    return this.data.active ? `activo: ${this.data.active}` : "sin perfil: cada rol sale de roles.yml";
  }

  rows() {
    const q = this.query;
    if (this.role) {
      const cur = this.prof()?.roles?.[this.role];
      const items = [...this.data.suggest.map((s) => ({ key: s, spec: s, cur: s === cur })), { key: OTHER, spec: "Otro… (provider/modelo)", other: true }];
      return rank(items, q, (r) => r.spec).map(({ item, hits }) => ({ ...item, hits }));
    }
    if (this.editing) {
      const roles = this.prof()?.roles ?? {};
      const items = this.data.roles.map((r) => ({ key: r, role: r, spec: roles[r] ?? null }));
      return rank(items, q, (r) => [r.role, r.spec ?? ""]).map(({ item, hits }) => ({ ...item, hits }));
    }
    const items = this.data.profiles.map((p) => ({ key: p.name, p }));
    return rank(items, q, (r) => [r.p.name, r.p.summary]).map(({ item, hits }) => ({ ...item, hits }));
  }

  empty() {
    if (this.editing) return "Nada coincide.";
    return this.query.trim() ? "Ningún perfil coincide: ctrl+n crea uno con ese nombre." : "No hay perfiles.";
  }

  draw(t, r, on) {
    const fg = on ? t.foreground : t.muted;
    if (this.role) {
      return h_flex().flex_1().min_w(0).gap(10).items_center()
        .child(div().flex_1().min_w(0).child(lit(t, r.spec, r.hits, r.other ? t.dim : fg)))
        .when(Boolean(r.cur), (el) => el.child(pill(t, "ahora", t.accent)));
    }
    if (this.editing) {
      return h_flex().flex_1().min_w(0).gap(10).items_center()
        .child(div().w(150).flex_none().child(lit(t, r.role, r.hits, fg)))
        .child(div().flex_1().min_w(0).truncate().text_color(r.spec ? t.foreground : t.dim).child(r.spec ?? "de roles.yml"));
    }
    const sure = this.confirm === r.key, act = r.p.name === this.data.active;
    return h_flex().flex_1().min_w(0).gap(10).items_center()
      .child(div().w(110).flex_none().child(lit(t, r.p.name, r.hits, act ? t.accent : fg)))
      .child(div().flex_1().min_w(0).truncate().text_size(12).text_color(t.dim).child(r.p.summary))
      .when(sure, (el) => el.child(div().flex_none().text_size(11).text_color(t.blocked).child("ctrl+x de nuevo para borrar")))
      .when(!sure && act, (el) => el.child(pill(t, "activo", t.accent)));
  }

  hints(row) {
    if (this.role) return [["enter", "usar este"], ["left", "volver"], ["escape", "cerrar"]];
    if (this.editing) return [["enter", "cambiar el modelo"], ["left", "volver"], ["ctrl-u", "usar este perfil"], ["escape", "cerrar"]];
    const h = [["enter", "usar"], ["right", "editar"], ["ctrl-n", "nuevo"]];
    if (row?.p && row.p.name !== this.data.active) h.push(["ctrl-x", this.confirm === row.key ? "de nuevo para borrar" : "borrar"]);
    return [...h, ["ctrl-o", "archivo"], ["escape", "cerrar"]];
  }

  moved() {
    if (this.confirm && this.confirm !== this.current()?.key) this.confirm = null;
  }

  go(cx, editing, role) {
    this.editing = editing;
    this.role = role;
    this.query = "";
    this.input.set_value("");
    this.at = 0;
    this.scroll = 0;
    cx.notify();
  }

  back(cx) {
    if (this.role) this.go(cx, this.editing, null);
    else if (this.editing) this.go(cx, null, null);
    else return false;
    return true;
  }

  // bk profile <args>: corre, avisa si falla y relee
  change(cx, label, args, ok) {
    return this.work(cx, label, async (cx) => {
      const r = await bk(["profile", ...args], { timeout: 10000 });
      if (r.code !== 0) throw new Error(lastLine(r.stderr) || `bk profile salió con ${r.code}`);
      await this.load();
      ok?.(r, cx);
    });
  }

  use(cx, name) {
    this.change(cx, "cambiando…", [name], (r) => {
      notify({ title: `Perfil ${name}`, body: lastLine(r.stdout).replace(/^perfil [^:]*: /, ""), level: "success", timeout: 5000 });
      this.close();
    });
  }

  setSpec(cx, spec) {
    const { editing, role } = this;
    this.change(cx, "guardando…", ["set", editing, role, spec], (_r, cx) => {
      notify({ title: `${editing}: ${role}`, body: spec, level: "success", timeout: 4000 });
      this.go(cx, editing, null);
    });
  }

  enter(r, cx) {
    if (this.role) {
      if (!r.other) return this.setSpec(cx, r.spec);
      return this.askFor({ label: this.role, title: `Modelo para ${this.role} en ${this.editing}`,
        help: "<provider>/<modelo>: claude/opus, claude/claude-opus-5-5, codex/gpt-5… Providers: " + (this.data.providers ?? []).join(", "),
        verb: "guardar", run: (text) => this.setSpec(cx, text) });
    }
    if (this.editing) return this.go(cx, this.editing, r.role);
    this.use(cx, r.p.name);
  }

  key(e, row, cx) {
    const k = e.key, ctrl = e.modifiers.control;
    // ← y → mueven el cursor mientras hay algo escrito; con el buscador vacío, cambian de nivel
    if (k === "left" && !ctrl && !this.query) return this.back(cx);
    if (((k === "right" && !this.query) || k === "tab") && !this.editing && row?.p) { this.go(cx, row.p.name, null); return true; }
    if (ctrl && k === "u" && this.editing && !this.role) { this.use(cx, this.editing); return true; }
    if (ctrl && k === "o") {
      this.close();
      termPopup("profiles", `'${bin()}' profile edit`, cwd()).catch((err) => notify({ title: "bk profile", body: String(err?.message ?? err), level: "error" }));
      return true;
    }
    if (this.editing) return false;
    if (ctrl && k === "n") {
      const from = row?.p?.name ?? this.data.active ?? "normal";
      const typed = this.query.trim().toLowerCase().replace(/\s+/g, "-");
      this.askFor({ label: "nuevo", title: `Perfil nuevo, copia de ${from}`, help: "Minúsculas, números y guiones. Después elegí el modelo de cada rol.",
        value: typed, verb: "crear", run: (name) => this.change(cx, "creando…", ["new", name, from], (_r, cx) => this.go(cx, name, null)) });
      return true;
    }
    if (ctrl && k === "x" && row?.p) {
      if (row.p.name === this.data.active) { notify({ title: "No borro el activo", body: "Elegí otro perfil antes.", level: "warning" }); return true; }
      if (this.confirm !== row.key) {
        this.confirm = row.key;
        const n = (this.asked = (this.asked ?? 0) + 1);
        cx.timer.after(SURE_MS, (cx) => { if (this.asked === n && this.confirm) { this.confirm = null; cx.notify(); } });
        return true;
      }
      this.confirm = null;
      this.change(cx, "borrando…", ["rm", row.p.name]);
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
