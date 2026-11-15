// La cabecera de la barra izquierda de bk-lavanda (el barrilete de la marca, que cambia según haya quien te
// espere, quien trabaje o nadie; buscar; plegar la barra) y, con props.footer, su pie de una línea (ajustes,
// aspecto, agregar una máquina). Nació como clon de workspace-chrome de Herdr 0.1.15.

import { View, div, image, svg } from "gpui-kit";
import { h_flex } from "gpui-base";
import { theme, run, props, window, shared, setShared, updates, layout, agents } from "herdr";
import { find, narrow, iconButton } from "./kit.js";

// Al riel (en macOS, con lugar para los botones de la ventana) o de vuelta al ancho que tenía.
function toggleSidebar() {
  const width = find(layout(), "sidebar")?.size?.px;
  if (!narrow()) setShared("sidebar.width", width);
  setShared("sidebar.collapsed", !narrow());
  run("layout.resize", { id: "sidebar", px: narrow() ? (shared("sidebar.width") ?? 288) : window()?.platform === "macos" ? 76 : 44 });
}

export default class Marca extends View {
  footer(t, collapsed) {
    const ready = Boolean(updates()?.app?.ready);
    const dot = div().size(6).flex_none().rounded_full().bg(t.accent);
    if (collapsed) {
      return h_flex().size_full().bg(t.chrome).items_center().justify_center()
        .child(div().relative().child(iconButton(t, "settings", "mods/bk-marca/settings.svg", () => run("app.settings"), { tip: "Ajustes" }))
          .when(ready, (el) => el.child(dot.absolute().top(2).right(2))));
    }
    return h_flex().size_full().bg(t.chrome).pl(8).pr(8).pb(4).gap(2).items_center().text_size(12)
      .child(h_flex().id("settings").h(26).px(8).gap(8).flex_none().items_center().rounded(6).cursor_pointer().text_color(t.muted)
        .hover((s) => s.bg(t.hover).text_color(t.foreground))
        .on_click(() => run("app.settings"))
        .child(svg("mods/bk-marca/settings.svg").size(14).flex_none())
        .child("Ajustes")
        .when(ready, (el) => el.child(dot).tooltip("Hay una actualización lista")))
      .child(div().flex_1())
      .child(iconButton(t, "theme", "mods/bk-marca/theme.svg", () => run("mod.open", { name: "bk-look" }), { tip: "Aspecto: tema, fuente, tamaño" }))
      .child(iconButton(t, "machine", "mods/bk-marca/plus.svg", () => run("mod.open", { name: "machine-add" }), { tip: "Agregar una máquina" }));
  }

  render() {
    const t = theme();
    const collapsed = narrow();
    if (props()?.footer) return this.footer(t, collapsed);
    const w = window();
    const lights = w?.platform === "macos" && !w?.fullscreen;
    // En el riel de macOS los botones de la ventana ocupan la fila; la barra se abre desde abajo de la lista.
    if (collapsed) {
      return h_flex().size_full().bg(t.chrome).items_center().justify_center()
        .when(!lights, (el) => el.child(iconButton(t, "sidebar-toggle", "mods/bk-marca/sidebar.svg", toggleSidebar, { tip: "Abrir la barra", stop: true, size: 15 })));
    }
    const list = agents();
    const waiting = list.filter((a) => a.status === "blocked").length;
    const working = list.filter((a) => a.status === "working").length;
    // El barrilete de la marca dice cómo está todo: ojos ámbar sobre fondo ámbar si alguien te espera,
    // despierto si hay agentes trabajando, con los ojos cerrados si todo está quieto. Sin animación: no gasta.
    const mood = waiting ? "wait" : working ? "fly" : "rest";
    const tip = waiting ? `Barrilete Kit · ${waiting === 1 ? "1 agente te espera" : waiting + " agentes te esperan"}` : working ? `Barrilete Kit · ${working} trabajando` : "Barrilete Kit · todo quieto";
    // Arrastrada a un ancho intermedio, la fila deja primero el nombre y después la lupa.
    const width = find(layout(), "sidebar")?.size?.px ?? 288;
    return h_flex().size_full().bg(t.chrome).pl(lights ? 80 : 14).pr(8).gap(2).items_center()
      .child(h_flex().flex_1().min_w(0).gap(8).items_center().tooltip(tip)
        .child(div().size(24).flex_none().rounded(7).bg(mood === "wait" ? t.blocked : t.accent).flex().items_center().justify_center()
          .child(image(`mods/bk-marca/bk-${mood}.svg`).size(20)))
        .when(width >= 208, (el) => el.child(div().text_size(13).font_bold().text_color(t.foreground).child("BK"))))
      .when(width >= 184, (el) => el.child(iconButton(t, "search", "mods/bk-marca/search.svg", () => run("mod.open", { name: "picker" }), { tip: "Buscar", stop: true, size: 15 })))
      .child(iconButton(t, "sidebar-toggle", "mods/bk-marca/sidebar.svg", toggleSidebar, { tip: "Plegar la barra", stop: true, size: 15 }));
  }
}
