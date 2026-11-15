import { execFile } from "node:child_process";
const chain = () => new Proxy(function () {}, { get: (t, k) => (k === "then" ? undefined : chain()), apply: () => chain() });
export const div = chain, svg = chain, v_flex = chain, h_flex = chain;
export class View {}
export const Input = { new: chain };
export const InputState = { new: () => { let v = ""; const h = {}; return { value: () => v, set_value: (x) => { const old = v; v = x; if (old !== x) h.change?.({}, CX); }, on: (e, f) => (h[e] = f), focus() {}, _h: h }; } };
export const notify = (n) => console.log("NOTIFY", JSON.stringify(n));
export const exec = (cmd, args, o) => new Promise((res) => execFile(cmd, args, { cwd: o.cwd, env: { ...process.env } }, (e, stdout, stderr) => res({ code: e ? e.code ?? 1 : 0, stdout, stderr })));
export const props = () => ({}), closeOverlay = () => {}, openOverlay = () => {}, focused = () => null, home = () => process.env.HOME, keys = () => [], settings = () => ({}), run = () => {}, terminals = () => [], setShared = () => {}, shared = () => null, hc = async () => ({ code: 0 }), theme = () => ({});
// Un contexto por evento: usarlo después de que el evento terminó es un error (como en Herdr)
export function mkCX() {
  const c = { alive: true };
  const ok = () => { if (!c.alive) throw new Error("cx viejo: el evento ya terminó"); };
  Object.assign(c, { notify() { ok(); }, stop_propagation() { ok(); }, focus_handle: () => ({}), timer: { after() {} },
    spawn: (f) => { ok(); const inner = mkCX(); CX.p = f(inner); return CX.p; } });
  return c;
}
export const CX = mkCX();
