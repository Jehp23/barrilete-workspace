// Cuentas (clic en la cuenta de la barra de abajo): las de cada IA, con su mail y si tienen la sesión iniciada.
// Un clic (o Enter) en una cuenta la deja activa para esa IA: lo que lances de ahora en más corre con ella, y el chat
// de Claude que mirás se relanza con ella retomando la misma conversación (si no está trabajando). Cada cuenta
// guarda su propio login (bk account: una carpeta por cuenta), así que cambiar no pide iniciar sesión de nuevo.
//   Enter       usar esta cuenta (una sin sesión: hacer su login)
//   ctrl+l      volver a hacer el login de la elegida
//   «Agregar una cuenta…»  el nombre y después el login, en una terminal sobre la ventana
// Lo decide y lo guarda `bk account` (lib/accounts.py); acá solo se elige.

import { div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { focused, agents, notify } from "herdr";
import { Panel, rank, bk, lit, pill, termPopup, bin, lastLine, clean, cwd } from "./kit.js";

const IA = { claude: "Claude", codex: "Codex" };
const sq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

export default class Cuentas extends Panel {
  setup() {
    this.title = "Cuentas";
    this.placeholder = "Cuenta o mail…";
    this.items = [];
    this.term = focused()?.terminal ?? null;
    this.chat = agents().some((a) => a.address === this.term);
  }

  subtitle() {
    return this.chat ? "un clic la deja activa y relanza este chat con ella" : "un clic la deja activa para lo que lances";
  }

  async load() {
    this.items = await bk(["account", "--json"], { json: true, timeout: 30000 });
    const i = this.picks().findIndex((r) => r.a?.active && r.a.provider === "claude");
    if (i >= 0) this.at = i;
  }

  rows() {
    const out = [];
    for (const prov of Object.keys(IA)) {
      const mine = this.items.filter((a) => a.provider === prov)
        .map((a) => ({ key: `${prov}:${a.name}`, a, label: a.name === "default" ? "la de siempre" : a.name }));
      const add = { key: `new:${prov}`, add: prov, label: `Agregar una cuenta de ${IA[prov]}…` };
      const got = rank([...mine, add], this.query, (r) => [r.label, r.a?.email || r.a?.who || ""]);
      if (!got.length) continue;
      const act = mine.find((r) => r.a.active);
      out.push({ head: IA[prov], note: act ? `activa: ${act.label}` : "" }, ...got.map(({ item, hits }) => ({ ...item, hits })));
    }
    return out;
  }

  empty() { return this.loading ? "Mirando las cuentas…" : "Nada coincide."; }

  draw(t, r, on) {
    const fg = on ? t.foreground : t.muted;
    const row = h_flex().flex_1().min_w(0).gap(10).items_center();
    if (r.add) return row.child(div().flex_1().text_color(t.dim).child(r.label));
    const a = r.a;
    return row
      .child(div().w(130).flex_none().child(lit(t, r.label, r.hits, a.active ? t.accent : fg)))
      .child(div().flex_1().min_w(0).truncate().text_size(12).text_color(t.dim).child(a.email || (a.logged_in ? a.who : "") || ""))
      .when(a.active, (el) => el.child(pill(t, "activa", t.accent)))
      .when(!a.logged_in, (el) => el.child(pill(t, "sin sesión", t.blocked)));
  }

  hints(row) {
    const tail = [["ctrl-r", "releer"], ["escape", "cerrar"]];
    if (row?.add) return [["enter", "agregar"], ...tail];
    if (row?.a && !row.a.logged_in) return [["enter", "iniciar sesión"], ...tail];
    return [["enter", "usar esta"], ["ctrl-l", "iniciar sesión de nuevo"], ...tail];
  }

  // El login es interactivo (abre el navegador): en una terminal sobre la ventana
  login(a) {
    const args = a.name === "default" ? `default ${a.provider}` : sq(a.name);
    this.close();
    termPopup("cuentas", `'${bin()}' account login ${args}`, cwd(), [0.7, 0.6])
      .catch((err) => notify({ title: "bk", body: String(err?.message ?? err), level: "error" }));
  }

  add(prov) {
    this.askFor({ label: IA[prov], title: `Cuenta nueva de ${IA[prov]}`,
      help: "Un nombre corto para reconocerla: trabajo, personal… (minúsculas, números y guiones). Después, su login.",
      verb: "seguir", run: (name) => {
        name = name.toLowerCase().replace(/\s+/g, "-");
        this.close();
        termPopup("cuentas", `'${bin()}' account new ${prov} ${sq(name)}`, cwd(), [0.7, 0.6])
          .catch((err) => notify({ title: "bk", body: String(err?.message ?? err), level: "error" }));
      } });
  }

  use(cx, a) {
    const args = ["account", "use", a.name, ...(a.name === "default" ? [a.provider] : [])];
    if (a.provider === "claude" && this.chat) args.push("--relaunch", "--terminal", this.term);
    this.work(cx, "cambiando…", async () => {
      const r = await bk(args, { timeout: 30000 });
      if (r.code !== 0) throw new Error(lastLine(r.stderr) || `bk account salió con ${r.code}`);
      const said = clean(r.stdout ?? "").split("\n").map((l) => l.trim()).filter(Boolean);
      notify({ title: `${IA[a.provider]}: ${a.name === "default" ? "la de siempre" : a.name}`,
        body: said.slice(1).join(" · ") || said[0] || "", level: "success", timeout: 6000 });
      this.close();
    });
  }

  enter(r, cx) {
    if (r.add) return this.add(r.add);
    if (!r.a.logged_in) return this.login(r.a);
    if (r.a.active && !(r.a.provider === "claude" && this.chat)) return this.close();
    this.use(cx, r.a);
  }

  key(e, row, cx) {
    if (e.modifiers.control && e.key === "l" && row?.a) { this.login(row.a); return true; }
    return false;
  }
}
