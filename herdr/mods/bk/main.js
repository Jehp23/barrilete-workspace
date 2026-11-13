// bk en Herdr: los atajos alt+… del workspace de tmux (dotfiles/tmux.conf), con las mismas teclas.
// keys.json no puede correr un programa ni pasarle argumentos a un mod: cada tecla abre un mod con el nombre
// del comando ("alt-k": "mod.open:bk-palette"), que hace lo suyo y se cierra. Todos son este mismo archivo
// (lib/herdr_install.py lo copia a mods/bk-<comando>); el comando sale del nombre con que Herdr lo abrió.
// Nada queda abierto: una ventana del mod siempre a la escucha tapaba los clics de toda la app (2026-11-13).
// Un popup es una terminal sobre la ventana que se cierra sola cuando el comando termina (display-popup -E).

import { View, div } from "gpui-kit";
import { hc, run, props, openOverlay, closeOverlay, focused, terminals, spaces, home, notify, shared, setShared } from "herdr";

// comando → lo que corre en el popup y su tamaño (los de tmux.conf)
const POPUPS = {
  palette: { cmd: "bk palette", w: 0.7, h: 0.7 },
  changes: { cmd: "bk changes", w: 0.92, h: 0.88 },
  sessions: { cmd: "bk s", w: 0.9, h: 0.75 },
  stats: { cmd: "bk stats", w: 0.92, h: 0.85 },
  new: { cmd: "bk new", w: 0.7, h: 0.6 },
  agents: { cmd: "bk ls; echo; bk peek; printf '\\n  (enter para cerrar) '; read -r _", w: 0.92, h: 0.88 },
};
const POP = "bk.pop";   // el popup abierto, compartido entre las copias: { name, id, terminal, keep }

const label = (t, k) => t.labels?.[k] ?? "";
const live = (t) => t.state === "live";
const alive = (addr) => terminals().some((t) => t.address === addr && live(t));

export default class Bk extends View {
  init(_p, cx) {
    const mine = props()?.overlay ?? "";
    const c = mine.startsWith("mod-bk-") ? mine.slice("mod-bk-".length) : "";
    cx.spawn(async (_cx) => {
      try {
        if (c) await this.handle(c);
      } catch (e) {
        notify({ title: "bk", body: String(e?.message ?? e), level: "error" });
      }
      if (mine) closeOverlay(mine);
    });
  }

  async handle(c) {
    const f = focused();
    if (POPUPS[c]) return this.popup(c, POPUPS[c], f);
    if (c === "term") return this.term(f);
    if (c === "back") return this.show(f, (t) => label(t, "bk.kind") === "chat", 1, "este espacio no tiene un chat de bk");
    const m = /^agent([1-9])$/.exec(c);
    if (m) return this.show(f, (t) => label(t, "bk.kind") === "agent", Number(m[1]), `no hay agente ${m[1]} en este espacio`);
    notify({ title: "bk", body: `comando desconocido: ${c}`, level: "warning" });
  }

  // Cierra el popup anterior, viva o no su terminal (uno cuyo comando ya terminó puede quedar abierto y es
  // modal). Devuelve su nombre si estaba vivo: la misma tecla lo cierra y no abre otro.
  async closePop() {
    const p = shared(POP);
    if (!p) return null;
    setShared(POP, null);
    const was = alive(p.terminal);
    closeOverlay(p.id);
    if (was && !p.keep) await hc(["kill", p.terminal]);
    return was ? p.name : null;
  }

  open(name, addr, spec, keep) {
    const id = openOverlay({ kind: "dialog", modal: true, width: spec.w, height: spec.h, layout: { type: "block", content: { terminal: addr } } });
    setShared(POP, { name, id, terminal: addr, keep });
  }

  // Un comando de bk en un popup, en la carpeta de la terminal que mirabas
  async popup(name, spec, f) {
    if ((await this.closePop()) === name) return;
    // Si el comando falla, el popup espera un enter: se lee el error en vez de cerrarse al instante
    const cmd = `{ ${spec.cmd}; } || { printf '\\n  (falló: enter para cerrar) '; read -r _; }`;
    const r = await hc(["run", "--json", "--bg", "--no-parent", "--rm", "--cwd", f?.cwd || home(), "--label", "bk.kind=popup",
      "--", "env", "BK_BACKEND=herdr", `BK_FROM_TERM=${f?.terminal ?? ""}`, "sh", "-c", cmd]);
    if (r.code !== 0) throw new Error(r.stderr.trim() || "hc no abrió el popup");
    this.open(name, JSON.parse(r.stdout).address, spec, false);
  }

  // alt+x: la terminal rápida del espacio. Esconderla no la cierra: vuelve con lo que dejaste.
  async term(f) {
    if ((await this.closePop()) === "term") return;
    const space = f?.space ?? "";
    let addr = terminals().find((t) => live(t) && label(t, "bk.kind") === "term" && label(t, "bk.space") === space)?.address;
    if (!addr) {
      const r = await hc(["run", "--json", "--bg", "--no-parent", "--cwd", f?.cwd || home(), "--label", "bk.kind=term", "--label", `bk.space=${space}`]);
      if (r.code !== 0) throw new Error(r.stderr.trim() || "hc no abrió la terminal");
      addr = JSON.parse(r.stdout).address;
    }
    this.open("term", addr, { w: 0.85, h: 0.75 }, true);
  }

  // La pestaña n (desde 1) del espacio a la vista cuya terminal cumple `pick`, en el orden de las pestañas
  show(f, pick, n, missing) {
    const tabs = spaces().find((s) => s.id === f?.space)?.tabs ?? [];
    const at = (t) => tabs.findIndex((tab) => tab.id === label(t, "herdr.tab"));
    const list = terminals().filter((t) => live(t) && pick(t) && at(t) >= 0).sort((a, b) => at(a) - at(b));
    const t = list[n - 1];
    if (!t) return notify({ title: "bk", body: missing, level: "info" });
    run("tab.select", { id: label(t, "herdr.tab") });
  }

  render() {
    return div();
  }
}
