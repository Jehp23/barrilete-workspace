// alt+m: la radio de bk song. Arriba, qué suena. Enter sobre un control (pausar, siguiente, cortar), un género o
// una estación corre bk song … y el panel queda abierto con el estado nuevo, para cambiar varias veces seguidas.
// Tab (o la última fila) abre bk song ui, la pantalla con el espectro, en una terminal sobre la ventana. Lo que
// escribís y no es de la lista se puede buscar en radio-browser.info (bk song <tag>) o, si es un link, reproducir.
// Los datos: bk _hub song (qué suena y los géneros) y bk song stations (clave, nombre y género de cada radio).

import { div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { notify } from "herdr";
import { Panel, rank, bk, bin, termPopup, lit, pill, lastLine, plural } from "./kit.js";

const POLL_MS = 10000;    // cada cuánto se vuelve a mirar qué suena (el tema cambia solo)
const PLAY_MS = 90000;    // bk song <radio> vuelve cuando hay sonido o se rinde: ~8 s una radio, ~30 s un link
// Subcomandos de bk song (lib/song.sh): escritos en el buscador no son un género para buscar
const RESERVED = new Set(["stop", "pause", "bar-status", "next", "prev", "stations", "genres", "ui", "now", "status",
  "hist", "history", "vol", "volume", "list", "ls", "fav", "add", "rm", "help"]);
const quote = (s) => `'${s.replace(/'/g, `'\\''`)}'`;

export default class Song extends Panel {
  setup(cx) {
    this.title = "Radio";
    this.placeholder = "Género, estación o un link…";
    this.now = { playing: false, paused: false, station: null, title: null, genre: null, genres: [] };
    this.stations = [];   // [{key, name, genre}], en el orden de bk song stations
    this.looking = false;
    this.ready = false;   // ya se leyó una vez qué suena
    cx.timer.every(POLL_MS, (cx) => this.look(cx));
  }

  subtitle() {
    const n = this.now;
    if (!n.playing && !n.paused) return this.loading ? "" : "no suena nada";
    return [n.paused ? "en pausa" : "suena", n.station ?? "una radio", n.title].filter(Boolean).join(" · ");
  }

  async load() { await this.refresh(); }

  // fetch, y la selección queda en la misma fila aunque cambien las de arriba (al arrancar aparecen los controles)
  async refresh(key = this.current()?.key, at = this.at, query = this.query) {
    const first = !this.ready;
    await this.fetch();
    this.ready = true;
    if (first || this.at !== at || this.query !== query) return;   // recién abre, o te moviste mientras leía
    const i = this.picks().findIndex((r) => r.key === key);
    this.at = Math.max(i, 0);
  }

  // Qué suena y qué radios hay. Solo lee: no arranca ni corta nada.
  async fetch() {
    const [now, list] = await Promise.all([
      bk(["_hub", "song"], { json: true, timeout: 8000 }),
      bk(["song", "stations"], { timeout: 8000 }).catch(() => null),
    ]);
    this.now = now;
    if (list?.code === 0) {
      this.stations = list.stdout.split("\n").map((l) => l.split("\t")).filter((p) => p[0])
        .map(([key, name, genre]) => ({ key, name: name || key, genre: genre || "" }));
    }
  }

  // El tema cambia solo: se vuelve a mirar cada tanto, sin "leyendo…"
  look(cx) {
    if (this.looking || this.loading || this.busy) return;
    this.looking = true;
    cx.spawn(async (cx) => {
      try { await this.refresh(); } catch (_) { /* queda lo último que se supo */ }
      this.looking = false;
      cx.notify();
    });
  }

  items() {
    const n = this.now, on = n.playing || n.paused;
    const genres = n.genres?.length ? n.genres : [...new Set(this.stations.map((s) => s.genre).filter(Boolean))];
    const ctl = !on ? [] : [
      { key: "pause", title: n.paused ? "Seguir" : "Pausar", hint: "bk song pause", words: "pausa play reanudar", args: ["pause"],
        busy: n.paused ? "siguiendo…" : "pausando…", verb: n.paused ? "seguir" : "pausar" },
      { key: "next", title: "Siguiente", hint: "bk song next", words: "otra radio estación", args: ["next"], busy: "sintonizando…", verb: "pasar a la siguiente radio del género", slow: true },
      { key: "prev", title: "Anterior", hint: "bk song prev", words: "otra radio estación volver", args: ["prev"], busy: "sintonizando…", verb: "volver a la radio anterior del género", slow: true },
      { key: "stop", title: "Cortar", hint: "bk song stop", words: "parar apagar silencio", args: ["stop"], busy: "cortando…", verb: "cortar la música" },
    ].map((c) => ({ ...c, kind: "ctl", alias: c.args[0], text: [c.title, `${c.hint} ${c.words}`] }));
    const gen = genres.map((g) => {
      const mine = this.stations.filter((s) => s.genre === g);
      // la primera radio del género, por su clave: lo mismo que hace bk song <género>, aunque otra radio se llame así
      return { key: "g-" + g, kind: "genre", alias: g, title: g, detail: mine[0] ? [mine[0].name, mine.length > 1 ? plural(mine.length, "radio", "radios") : ""].filter(Boolean).join(" · ") : "",
        sounds: on && n.genre === g, args: [mine[0]?.key ?? g], busy: "sintonizando…", verb: "poner " + g, slow: true, text: [g, "género " + (mine[0]?.name ?? "")] };
    });
    const order = (s) => { const i = genres.indexOf(s.genre); return i < 0 ? genres.length : i; };
    const sta = [...this.stations].sort((a, b) => order(a) - order(b)).map((s) => ({
      key: "s-" + s.key, kind: "station", alias: s.key, title: s.name, detail: s.genre,
      sounds: on && n.station === s.name && (!n.genre || !s.genre || n.genre === s.genre),
      args: [s.key], busy: "sintonizando…", verb: "poner esta radio", slow: true, text: [s.name, `${s.key} ${s.genre} estación radio`] }));
    const ui = { key: "ui", kind: "ui", alias: "ui", title: "Pantalla de la radio", hint: "bk song ui", verb: "abrir la pantalla", text: ["Pantalla de la radio", "bk song ui espectro visualizador teclas"] };
    return { ctl, gen, sta, ui };
  }

  // Lo escrito, si sirve como «bk song <eso>»: un link se reproduce; otra palabra se busca como género
  typed(q, gen, sta) {
    if (!q || q.startsWith("-")) return null;
    if (/^https?:\/\/\S+$/.test(q)) return { key: "url", kind: "typed", title: "Reproducir " + q, hint: "bk song <link>", args: [q], busy: "abriendo el link…", verb: "reproducir el link", slow: true };
    const low = q.toLowerCase();
    if (/^https?:/.test(low) || RESERVED.has(low) || [...gen, ...sta].some((r) => r.alias === q)) return null;
    return { key: "tag", kind: "typed", title: `Buscar una radio de «${q}»`, hint: "radio-browser.info", args: [q], busy: "buscando…", verb: "buscar y poner la más votada", slow: true };
  }

  rows() {
    const q = this.query.trim();
    const { ctl, gen, sta, ui } = this.items();
    if (q) {
      const all = [...ctl, ...gen, ...sta, ui];
      let found = rank(all, q, (r) => r.text).map(({ item, hits }) => ({ ...item, hits }));
      // lo mismo que escribirías en la terminal (pause, ui, rock, mega) va primero, coincida lo que coincida
      const same = all.find((r) => r.alias === q);
      if (same) found = [found.find((r) => r.key === same.key) ?? same, ...found.filter((r) => r.key !== same.key)];
      const extra = this.typed(q, gen, sta);
      return extra?.key === "url" ? [extra, ...found] : extra ? [...found, extra] : found;
    }
    const out = [];
    if (ctl.length) out.push({ head: "Ahora" }, ...ctl);
    if (gen.length) out.push({ head: "Géneros" }, ...gen);
    if (sta.length) out.push({ head: "Estaciones", note: String(sta.length) }, ...sta);
    out.push({ head: "Ver" }, ui);
    return out;
  }

  draw(t, r, on) {
    const ink = on || r.sounds ? t.foreground : t.muted;
    return h_flex().flex_1().min_w(0).gap(10).items_center()
      .child(div().min_w(0).when(r.kind !== "genre", (el) => el.flex_1()).when(r.kind === "genre", (el) => el.flex_none().w(96)).child(lit(t, r.title, r.hits, ink)))
      .when(r.kind === "genre", (el) => el.child(div().flex_1().min_w(0).truncate().text_size(11.5).text_color(t.dim).child(r.detail)))
      .when(Boolean(r.sounds), (el) => el.child(pill(t, this.now.paused ? "en pausa" : "suena", this.now.paused ? t.blocked : t.done)))
      .when(r.kind === "station", (el) => el.child(div().flex_none().w(72).flex().justify_end().text_size(11.5).text_color(t.dim).child(r.detail)))
      .when(r.kind !== "station" && r.kind !== "genre" && Boolean(r.hint), (el) => el.child(div().flex_none().text_size(11.5).text_color(t.dim).child(r.hint)));
  }

  hints(row) {
    return [["enter", row?.verb ?? "elegir"], ["tab", "pantalla"], ["ctrl-r", "recargar"], ["escape", "cerrar"]];
  }

  key(e) {
    if (e.key === "tab" && !e.modifiers.control && !e.modifiers.shift) { this.screen(); return true; }
    return false;
  }

  // bk song ui queda en primer plano hasta que salís: va en una terminal sobre la ventana, y este panel se cierra
  screen() {
    this.close();
    termPopup("song", quote(bin()) + " song ui").catch((err) => notify({ title: "Radio", body: String(err?.message ?? err), level: "error" }));
  }

  enter(r, cx) {
    if (r.kind === "ui") return this.screen();
    if (this.busy) return;   // de a un cambio por vez: dos bk song juntos se pisan el reproductor
    const at = this.at, query = this.query;
    this.work(cx, r.busy, async () => {
      try {
        const res = await bk(["song", ...r.args], { timeout: r.slow ? PLAY_MS : 15000 });
        if (res.code !== 0) throw new Error(lastLine(res.stderr).replace(/^bk song:\s*/, "") || lastLine(res.stdout) || `bk song salió con ${res.code}`);
      } catch (err) {
        notify({ title: "Radio", body: String(err?.message ?? err), level: "error" });
      }
      try { await this.refresh(r.key, at, query); } catch (_) { /* queda lo último que se supo */ }
    });
  }
}
