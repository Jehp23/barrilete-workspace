// bk en Herdr: las acciones sin panel (ir a la ventana N, al agente N, al próximo que te espera, volver, chat
// nuevo, terminal rápida, el ayudante) y los avisos que pide bk. Los paneles (comandos, issues, agentes…) son mods/hub.
// keys.json no puede correr un programa ni pasarle argumentos a un mod: cada tecla abre un mod con el nombre
// del comando ("alt-j": "mod.open:bk-next"), que hace lo suyo y se cierra. Todos son este mismo archivo
// (lib/herdr_install.py lo copia a mods/bk-<comando>); el comando sale del nombre con que Herdr lo abrió.
// Nada queda abierto: una ventana del mod siempre a la escucha tapaba los clics de toda la app (2026-11-13).
// Un popup es una terminal sobre la ventana que se cierra sola cuando el comando termina (display-popup -E).

import { View, div } from "gpui-kit";
import { hc, exec, run, props, openOverlay, closeOverlay, focused, terminals, spaces, agents, home, notify, shared, setShared, readTextFile } from "herdr";

// El único comando que corre en un popup: el clic del aviso «Resumen listo» (sin tecla). Lo demás que era un
// popup de terminal (comandos, cambios, sesiones, uso, nuevo, agentes) ahora es un panel de mods/hub.
const SEGUIR = { cmd: "bk handoff --seguir", w: 0.6, h: 0.3 };
const AVISO_MS = 600000;   // el aviso «Resumen listo» espera el clic diez minutos
const AVISOS = ".cache/bk/herdr-avisos";   // la cola de hd_notice (lib/herdr.sh), bajo el home: un aviso por archivo
// Lo que queda a la vista un aviso sin clic, por nivel: un error se tiene que poder leer
const AVISO_NIVEL = { info: 5000, success: 5000, warning: 15000, error: 15000 };
const POP = "bk.pop";   // el popup abierto, compartido entre las copias: { name, id, terminal, keep }
const PEDIDO = "bk.pop.pedido";   // el popup que pide un panel del hub (termPopup en mods/hub/kit.js)
const AYUDA = "ayuda";  // bk.kind de la terminal del ayudante (alt+y); la franja de arriba la busca con la misma
const AYUDA_CABECERA = 48;   // alto de la cabecera del popup del ayudante (mods/ayudante)
// Lo que corre esa terminal ($0 es bk): si puede arrancar, bk _ayuda toma su lugar; si no, queda el motivo a la vista
const AYUDA_SH = `"$0" --dry-run _ayuda >/dev/null && exec "$0" _ayuda; printf '\\n  (enter para cerrar) '; read -r _`;

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
      this.closeSelf();
    });
  }

  closeSelf() {
    const mine = props()?.overlay;
    if (mine && !this.closed) closeOverlay(mine);
    this.closed = true;
  }

  async handle(c) {
    const f = focused();
    if (c === "seguir") return this.popup(c, SEGUIR, f);
    if (c === "pop") return this.pedido();
    if (c === "term") return this.term(f);
    if (c === "ayuda") return this.ayuda();
    if (c === "aviso") return this.aviso();
    if (c === "back") return this.show(f, (t) => label(t, "bk.kind") === "chat", 1, "este espacio no tiene un chat de bk");
    if (c === "chat") return this.chat(f);
    if (c === "next") return this.next(f);
    if (c === "last") return this.last(f);
    if (c === "epica") return this.epica(f);
    if (c === "todo") return this.todo();
    if (c === "cambios") return this.tab("cambios");
    const g = /^go([1-9])$/.exec(c);
    if (g) return this.go(g[1]);
    const m = /^agent([1-9])$/.exec(c);
    if (m) return this.show(f, (t) => label(t, "bk.kind") === "agent", Number(m[1]), `no hay agente ${m[1]} en este espacio`);
    notify({ title: "bk", body: `comando desconocido: ${c}`, level: "warning" });
  }

  // alt+t: el panel derecho en la pestaña TODO (los pasos del issue del chat, mods/lado). Si ya estaba en TODO,
  // vuelve a Estado. Siempre lo muestra: oculto (alt+.), la tecla no haría nada a la vista.
  todo() { this.tab("todo"); }

  // alt+g: lo mismo con la pestaña Cambios (lo sin commitear; el clic en un archivo abre su diff en un popup)
  tab(name) {
    setShared("bk.lado.tab", shared("bk.lado.tab") === name ? "estado" : name);
    run("layout.show", { id: "lado" });
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

  open(name, addr, spec, keep, layout = { type: "block", content: { terminal: addr } }) {
    const id = openOverlay({ kind: "dialog", modal: true, width: spec.w, height: spec.h, layout });
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

  // bk-pop: el programa de pantalla completa que pidió un panel del hub (bk monitor desde alt+k, la radio, el editor
  // de perfiles). El panel se cierra antes y no puede esperar a hc: deja el pedido en shared y abre este mod.
  pedido() {
    const p = shared(PEDIDO);
    if (!p?.cmd) return;
    setShared(PEDIDO, null);
    return this.popup(String(p.name || "pop"), { cmd: String(p.cmd), w: p.w ?? 0.9, h: p.h ?? 0.85 }, { cwd: p.dir, terminal: p.from });
  }

  // Los avisos que pide bk (hd_notice en lib/herdr.sh): solo un mod puede avisar, así que bk deja cada uno en un
  // archivo de la cola y abre este mod, que los muestra en orden (el nombre empieza con la hora) y los borra.
  // El que trae un mod lo abre con el clic (bk-seguir) y espera diez minutos; el resto (lo que deja bk _do al
  // terminar) va con su nivel y se va solo. Primero avisa y después borra: si Herdr cierra esta copia en el
  // medio (otro aviso que llega justo: mod.open sobre un mod abierto lo cierra), lo que falta queda en la cola
  // para la próxima. Uno de hace más de diez minutos se borra sin mostrarse: quedó de cuando Herdr no estaba.
  async aviso() {
    const dir = `${home()}/${AVISOS}`;
    const ls = await exec("ls", [dir], { timeout: 5000 });
    const files = ls.code === 0 ? ls.stdout.split("\n").filter((f) => f.endsWith(".json")) : [];
    // <hora>-<pid>[-<k>].json: por hora, y los de un mismo bk en el mismo segundo en el orden en que los pidió
    // (como texto, "…-2.json" queda antes que "….json")
    const turn = (f) => {
      const p = f.slice(0, -".json".length).split("-").map((x) => Number(x) || 0);
      return [p[0] ?? 0, p[1] ?? 0, p[2] ?? 1];
    };
    files.sort((a, b) => {
      const x = turn(a), y = turn(b);
      return x[0] - y[0] || x[1] - y[1] || x[2] - y[2] || (a < b ? -1 : a > b ? 1 : 0);
    });
    for (const f of files) {
      let n = null;
      try {
        n = JSON.parse(await readTextFile(`${dir}/${f}`));   // null si otra copia ya se lo llevó
      } catch (_e) {
        n = null;   // no es un aviso: se borra abajo, sin mostrar nada
      }
      const fresh = typeof n?.ts !== "number" || Date.now() / 1000 - n.ts <= AVISO_MS / 1000;
      if (n?.title && fresh) {
        const level = Object.hasOwn(AVISO_NIVEL, n.level) ? n.level : "info";
        const mod = typeof n.mod === "string" ? n.mod : "";
        notify({ title: String(n.title), body: String(n.body ?? ""), level,
          ...(mod ? { timeout: AVISO_MS, action: { name: "mod.open", args: { name: mod } } } : { timeout: AVISO_NIVEL[level] }) });
      }
      await exec("rm", ["-f", `${dir}/${f}`], { timeout: 5000 });
    }
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

  // alt+y, o el botón «Piola» de la franja de arriba (mods/pestanas): Piola, el ayudante del workspace, una sesión de
  // Codex en el repo de bk (bk _ayuda) en un popup. Uno solo para toda la ventana, sin pestaña ni fila en la lista
  // de agentes. Esconderlo no lo cierra: vuelve con su conversación; si saliste de Codex, la próxima vez empieza
  // uno nuevo. Si no puede arrancar (no está Codex: lo dice bk --dry-run _ayuda), el popup espera un enter para
  // que se lea por qué; salir de Codex, en cambio, lo cierra sin preguntar.
  // Temporal: hasta que el workspace quede pulido.
  async ayuda() {
    if ((await this.closePop()) === "ayuda") return;
    let addr = terminals().find((t) => live(t) && label(t, "bk.kind") === AYUDA)?.address;
    if (!addr) {
      const r = await hc(["run", "--json", "--bg", "--no-parent", "--rm", "--cwd", home(), "--label", `bk.kind=${AYUDA}`,
        "--", "env", "BK_BACKEND=herdr", "sh", "-c", AYUDA_SH, shared("bk.bin") || "bk"]);
      if (r.code !== 0) throw new Error(r.stderr.trim() || "hc no abrió el ayudante");
      addr = JSON.parse(r.stdout).address;
    }
    // Arriba, la cabecera de Piola (mods/ayudante: quién es, cómo está y el botón de esconder); abajo, su terminal
    this.open("ayuda", addr, { w: 0.6, h: 0.85 }, true, { type: "column", children: [
      { id: "ayudante-cabecera", type: "block", size: { px: AYUDA_CABECERA }, content: { mod: "bk-ayudante", props: { terminal: addr } } },
      { id: "ayudante-terminal", type: "block", content: { terminal: addr } }] });
  }

  // Mostrar la pestaña de una terminal (su espacio, su pestaña y el foco en ella)
  reveal(t) {
    const space = label(t, "herdr.space"), tab = label(t, "herdr.tab");
    if (space) run("space.select", { id: space });
    if (tab) run("tab.select", { id: tab });
    run("pane.focus", { terminal: t.address });
  }

  // alt+N: la ventana con ese número fijo (etiqueta bk.id, lib/herdr.sh), esté en el espacio que esté
  go(n) {
    const t = terminals().find((x) => live(x) && label(x, "bk.id") === n);
    if (!t) return notify({ title: "bk", body: `no hay ventana ${n}`, level: "info", timeout: 2500 });
    this.reveal(t);
  }

  // alt+c: otro chat en el proyecto de la terminal que mirás (bk chat), sin menú. bk avisa cuando abrió.
  async chat(f) {
    const dir = f?.cwd || home();
    notify({ title: "Chat nuevo", body: dir.replace(home(), "~"), level: "info", timeout: 3000 });
    const r = await exec(shared("bk.bin") || "bk", ["_do", "--cwd", dir, "--title", "Chat nuevo", "--", "chat"], { cwd: dir, timeout: 15000 });
    if (r.code !== 0) throw new Error((r.stderr || r.stdout).trim().split("\n").pop() || "bk chat falló");
  }

  // alt+j: el próximo agente que te necesita (primero los que preguntan, después los que terminaron); cada
  // pulsación pasa al siguiente. Sin ninguno, lo dice.
  next(f) {
    const urgent = (a) => (a.status === "blocked" ? 0 : a.status === "done" ? 1 : 2);
    const list = agents().filter((a) => urgent(a) < 2).sort((a, b) => urgent(a) - urgent(b) || b.seq - a.seq);
    if (!list.length) return notify({ title: "bk", body: "nadie te espera", level: "info", timeout: 2500 });
    const at = list.findIndex((a) => a.address === f?.terminal);
    const a = list[(at + 1) % list.length];
    run("space.select", { id: a.space });
    run("tab.select", { id: a.tab });
    run("pane.focus", { terminal: a.address });
  }

  // alt+0: la pestaña donde estabas antes de esta. El rastro lo anota la barra de bk (mods/barra) en
  // shared "bk.trail": [{ space, tab }, …], lo más nuevo primero.
  last(f) {
    const trail = shared("bk.trail") ?? [];
    const alive = (p) => spaces().some((s) => s.id === p.space && s.tabs.some((tab) => tab.id === p.tab));
    const prev = trail.find((p) => (p.space !== f?.space || p.tab !== f?.tab) && alive(p));
    if (!prev) return notify({ title: "bk", body: "no hay un lugar anterior", level: "info", timeout: 2500 });
    run("space.select", { id: prev.space });
    run("tab.select", { id: prev.tab });
  }

  // alt+p: el detalle de la épica del chat enfocado (si no tiene, la primera de la sección ÉPICAS), el mismo popup
  // que abre el clic en su tarjeta. Los datos y el alto los deja la barra de agentes en shared "bk.epics".
  epica(f) {
    const s = shared("bk.epics") ?? {};
    const keys = Object.keys(s.epics ?? {});
    const key = s.byTerminal?.[f?.terminal] ?? (keys.length === 1 ? keys[0] : null);
    if (!keys.length) return notify({ title: "bk", body: "ningún chat tiene una épica", level: "info", timeout: 2500 });
    // Este mod (un popup invisible) se cierra antes de abrir el de la épica: si se cierra después, Herdr le
    // devuelve el teclado a la terminal de abajo y el popup no recibe ↑↓ ⏎ g l esc (2026-11-17).
    this.closeSelf();
    // Este chat no tiene épica y hay varias: elegir cuál (el selector está en bk-agentes)
    if (!key) return openOverlay({ mod: "bk-agentes", kind: "dialog", width: 420, height: s.pickHeight ?? 34 + keys.length * 30 + 10, props: { epicPick: true } });
    openOverlay({ mod: "bk-agentes", kind: "dialog", width: 780, height: s.epics?.[key]?.height ?? 400, props: { epic: key } });
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
