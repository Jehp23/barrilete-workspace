// El menú del clic derecho de bk (instalado como mods/bk-menu): las mismas opciones que el `menu` de Herdr, en
// castellano, con lugar para el texto y las teclas como en el resto de los paneles. El de Herdr abre a 220 px y
// cortaba los atajos (cmd-shift-c) y "Send right-clicks to pane" (2026-11-15).
// Lo usan el layout bk-lavanda ("terminal_menu": "bk-menu", el clic derecho en una terminal), la lista de agentes
// (espacios y agentes) y las pestañas: props { tab: "pane" | "tab" | "space", target }. ↑/↓ mueven, Enter corre,
// Esc cierra. Una opción es [texto, comando, args]; "worktree" abre el diálogo de worktrees de Herdr.

import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { run, props, closeOverlay, openOverlay, theme, keys, terminals, spaces, panes, exec } from "herdr";

export const WIDTH = 300;
const ROW = 32, SEP = 9, PAD = 6;
const ICONS = "mods/workspace-chrome/";
const GLYPH = { alt: "⌥", cmd: "⌘", ctrl: "⌃", shift: "⇧", enter: "↵", escape: "esc", tab: "⇥" };

// Dónde está un espacio ahora: la carpeta viva de su primera terminal, o donde se creó
function place(s) {
  const tabs = new Set((s.tabs ?? []).map((c) => c.id));
  return panes().find((p) => tabs.has(p.tab) && p.cwd)?.cwd || s.folder;
}

// El checkout de un espacio: "main" (el del repo), "linked" (un worktree) o null
async function checkout(folder, on) {
  const top = await exec("git", ["rev-parse", "--show-toplevel"], { cwd: folder, on });
  const common = await exec("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { cwd: folder, on });
  if (top.code !== 0 || common.code !== 0) return null;
  return common.stdout.trim() === `${top.stdout.trim()}/.git` ? "main" : "linked";
}

export function items(p, git) {
  p = p ?? {};
  const tg = p.target ?? {};
  if (p.tab === "pane") {
    const all = terminals();
    const term = all.find((t) => t.address === tg.terminal);
    const parent = term?.parent && all.find((t) => t.address === term.parent);
    const toProgram = term?.labels?.["herdr.right-click"] === "program";
    // Una terminal fuera de una pestaña (un bloque del layout, una ventana) no tiene pane que dividir ni cerrar
    const inTab = panes().some((pane) => pane.pane === tg.pane);
    return [
      ...(inTab ? [
        ["Dividir a la derecha", "pane.split", { direction: "right", pane: tg.pane }, "panel-right"],
        ["Dividir abajo", "pane.split", { direction: "down", pane: tg.pane }, "panel-right"],
        ["Agrandar", "pane.zoom", { pane: tg.pane }, "square"],
      ] : []),
      ...(term ? [toProgram
        ? ["Clic derecho: menú de Herdr", "terminal.right_click", { terminal: term.address, to: "menu" }, "terminal"]
        : ["Clic derecho: al programa", "terminal.right_click", { terminal: term.address, to: "program" }, "terminal"]] : []),
      ...(parent ? [[`Devolver a ${parent.name || parent.address}`, "terminal.park", { terminal: term.address }, "archive"]] : []),
      ...(inTab ? [["Cerrar", "pane.close", { pane: tg.pane }, "x"]] : []),
    ];
  }
  if (p.tab === "tab") {
    return [
      ["Renombrar", "tab.rename", { id: tg.id }, "square-pen"],
      ["Pestaña nueva", "tab.new", { space: tg.space }, "plus"],
      ["Cerrar", "tab.close", { id: tg.id }, "x"],
    ];
  }
  if (p.tab === "space") {
    return [
      ["Renombrar", "space.rename", { id: tg.id }, "square-pen"],
      ...(git ? [["Worktree nuevo", "worktree", { space: tg.id, action: "new" }, "git-branch"],
        ["Abrir un worktree", "worktree", { space: tg.id, action: "open" }, "git-branch"]] : []),
      ...(git === "linked" ? [["Borrar este worktree", "worktree", { space: tg.id, action: "remove" }, "git-branch"]] : []),
      ["Cerrar", "space.close", { id: tg.id }, "x"],
    ];
  }
  return [["Espacio nuevo", "space.new", {}, "plus"], ["Teclas", "app.help", {}, "terminal"]];
}

// Una raya antes de cerrar (lo que no tiene vuelta) y antes de "Clic derecho" (otra clase de cosa)
const sepBefore = (list, i) => i > 0 && (list[i][1].endsWith(".close") || list[i][1] === "terminal.right_click");

// El alto justo para esas opciones
export function height(list) {
  return PAD * 2 + list.length * ROW + list.filter((_, i) => sepBefore(list, i)).length * SEP;
}

// La tecla global de un comando (pane.split:right cuenta para pane.split con { direction: "right" })
export function shortcut(name, args) {
  const value = args && Object.values(args)[0];
  return keys().find((b) => b.section === "global" && (b.action === name || b.action === `${name}:${value}`))?.keys ?? "";
}
export function keyParts(k) {
  if (!k) return [];
  const parts = k.endsWith("--") ? [...k.slice(0, -2).split("-"), "-"] : k.split("-");
  return parts.map((p) => GLYPH[p] ?? (p.length === 1 ? p.toUpperCase() : p));
}

// Abrir este menú desde otro mod, del alto justo
export function openMenu(tab, target, mod = "bk-menu") {
  return openOverlay({ mod, kind: "popup", width: WIDTH, height: height(items({ tab, target }, null)), props: { tab, target } });
}

export default class Menu extends View {
  init(_props, cx) {
    this.at = 0;
    this.git = null;
    this.handle = cx.focus_handle();
    this.handle.focus();
    const p = props();
    const space = p?.tab === "space" && spaces().find((s) => s.id === p.target?.id);
    const folder = space && place(space);
    if (folder) cx.spawn(async (cx) => { this.git = await checkout(folder, space.machine).catch(() => null); cx.notify(); });
  }

  choose(i) {
    const it = items(props(), this.git)[i];
    if (!it) return;
    closeOverlay(props()?.overlay);
    if (it[1] === "worktree") openOverlay({ mod: "worktree", kind: "dialog", ...(it[2].action === "open" ? { width: 560, height: 480 } : { width: 440, height: 260 }), props: it[2] });
    else run(it[1], it[2]);
  }

  render() {
    const t = theme();
    const list = items(props(), this.git);
    const danger = (it) => it[1].endsWith(".close") || it[2]?.action === "remove";
    return v_flex().id("bk-menu").track_focus(this.handle).size_full().min_h(0).p(PAD).bg(t.popover).text_size(12.5)
      .on_key_down((e, cx) => {
        if (e.key === "down") this.at = (this.at + 1) % list.length;
        else if (e.key === "up") this.at = (this.at + list.length - 1) % list.length;
        else if (e.key === "enter") return this.choose(this.at);
        else if (e.key === "escape") return closeOverlay(props().overlay);
        else return;
        cx.notify();
      })
      .children(list.map((it, i) => {
        const on = i === this.at;
        const color = danger(it) ? t.ansi1 ?? t.blocked : t.foreground;
        const caps = keyParts(shortcut(it[1], it[2]));
        return v_flex().flex_none()
          .when(sepBefore(list, i), (el) => el.child(div().mx(8).my(4).h(1).bg(t.border)))
          .child(h_flex().id(`bm-${i}`).h(ROW).px(9).gap(10).rounded(7).items_center().cursor_pointer()
            .when(on, (el) => el.bg(t.selected))
            .hover((s) => s.bg(on ? t.selected : t.hover))
            .on_hover((h, cx) => { if (h && this.at !== i) { this.at = i; cx.notify(); } })
            .on_click(() => this.choose(i))
            .child(svg(ICONS + it[3] + ".svg").size(14).flex_none().text_color(danger(it) ? color : on ? t.accent : t.muted))
            .child(div().flex_1().min_w(0).truncate().text_color(color).child(it[0]))
            .child(h_flex().flex_none().gap(3).children(caps.map((c) =>
              div().min_w(18).h(18).px(4).flex().items_center().justify_center().rounded(5).border_1().border_color(t.border)
                .bg(t.raised).text_size(10.5).text_color(t.muted).child(c)))));
      }));
  }
}
