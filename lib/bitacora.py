#!/usr/bin/env python3
"""Agrega (o actualiza) la sección "Bitácora de agentes" en barrilete-estado-2026-11-15.html.

Lee las retros de la rama agents/retros de barrilete-kit (cada agente deja una al terminar
implement-issue, review-pr u orchestrate) y arma una tarjeta por cambio (PR) con la etiqueta
de cada agente que trabajó en él y su reporte. Es idempotente: reemplaza lo que hay entre
<!-- bitacora:start --> y <!-- bitacora:end -->.

Uso:  bk bitacora [ruta-al-repo] [ruta-al-html]   (alt+k «Bitácora de agentes»: la regenera y abre el HTML)
      python3 -I lib/bitacora.py [ruta-al-repo] [ruta-al-html]   solo la regenera

Por defecto el repo es ~/barrilete-kit y el HTML ~/Downloads/barrilete-estado-2026-11-15.backup.html (BK_BITACORA_REPO y
BK_BITACORA_HTML los cambian; los argumentos mandan).
"""
import datetime
import html
import json
import os
import re
import subprocess
import sys

REPO = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else os.environ.get("BK_BITACORA_REPO") or "~/barrilete-kit")
HTML = os.path.expanduser(sys.argv[2] if len(sys.argv) > 2 else
                          os.environ.get("BK_BITACORA_HTML") or "~/Downloads/barrilete-estado-2026-11-15.backup.html")
RAMA = "origin/agents/retros"
INI, FIN = "<!-- bitacora:start -->", "<!-- bitacora:end -->"
NAV = '<a href="#bitacora">13 bitácora</a>'

ROLES = {
    "implementer": "implementador",
    "implementer-light": "implementador liviano",
    "reviewer": "revisor",
    "session": "sesión",
    "orchestrator": "orquestador",
}
ETIQUETAS = {
    "deviations": "Desvíos",
    "decisions not covered": "Decisiones no cubiertas",
    "what the review found": "Qué encontró la review",
    "proposal": "Propuesta",
}
SKILLS = {"implement-issue": "implementó", "review-pr": "revisó", "orchestrate": "orquestó"}


def git(*args):
    return subprocess.run(["git", "-C", REPO, *args], capture_output=True, text=True, check=True).stdout


def leer_retros():
    git("fetch", "-q", "origin", "agents/retros")
    retros = []
    for ruta in git("ls-tree", "-r", "--name-only", RAMA).split():
        if not ruta.startswith("retros/") or not ruta.endswith(".md"):
            continue
        texto = git("show", f"{RAMA}:{ruta}")
        m = re.match(r"---\n(.*?)\n---\n(.*)", texto, re.S)
        if not m:
            continue
        meta = {}
        for linea in m.group(1).splitlines():
            if ":" in linea:
                k, v = linea.split(":", 1)
                meta[k.strip()] = v.strip()
        partes = re.split(r"\*\*([^*\n]+?):\*\*", m.group(2))
        secciones = []
        for i in range(1, len(partes) - 1, 2):
            secciones.append((partes[i].strip(), partes[i + 1].strip()))
        if not secciones and m.group(2).strip():
            secciones.append(("Reporte", m.group(2).strip()))
        meta["_secciones"] = secciones
        meta["_archivo"] = ruta
        retros.append(meta)
    return retros


def leer_prs():
    try:
        out = subprocess.run(
            ["gh", "pr", "list", "--state", "all", "--limit", "1000", "--json", "number,title,state,url"],
            cwd=REPO, capture_output=True, text=True, check=True, timeout=60,
        ).stdout
        return {str(p["number"]): p for p in json.loads(out)}
    except Exception:
        return {}


def md(texto):
    t = html.escape(texto)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    return t.replace("\n", "<br>")


def agente(r):
    rol = r.get("role", "") or "sesión"
    return f"{ROLES.get(rol, rol)} · {r.get('model', '?') or '?'}"


def clase_rol(r):
    return re.sub(r"[^a-z-]", "", (r.get("role") or "session").lower())


def construir(retros, prs):
    grupos = {}
    for r in retros:
        pr = re.sub(r"\D", "", r.get("pr", "") or "")
        issue = re.sub(r"\D", "", r.get("issue", "") or "")
        clave = f"pr{pr}" if pr else (f"issue{issue}" if issue else r["_archivo"])
        grupos.setdefault(clave, []).append(r)

    orden = sorted(grupos.items(), key=lambda kv: max(x.get("date", "") for x in kv[1]), reverse=True)
    agentes = {}
    for r in retros:
        agentes[agente(r)] = agentes.get(agente(r), 0) + 1

    filtros = "".join(
        f'<button class="bf" data-a="{html.escape(a)}">{html.escape(a)} <b>{n}</b></button>'
        for a, n in sorted(agentes.items(), key=lambda x: -x[1])
    )

    tarjetas = []
    for clave, rs in orden:
        rs.sort(key=lambda x: (x.get("date", ""), x["_archivo"]))
        pr = re.sub(r"\D", "", rs[0].get("pr", "") or "")
        issue = re.sub(r"\D", "", rs[0].get("issue", "") or "")
        info = prs.get(pr, {})
        titulo = info.get("title") or (f"Issue #{issue}" if issue else rs[0]["_archivo"])
        estado = info.get("state", "")
        badge = {"MERGED": ("done", "mergeado"), "OPEN": ("work", "abierto"), "CLOSED": ("blk", "cerrado")}.get(estado)
        enlace_pr = (f'<a href="{html.escape(info["url"])}">PR #{pr}</a>' if info.get("url")
                     else (f"PR #{pr}" if pr else ""))
        cab = " · ".join(x for x in [enlace_pr, f"issue #{issue}" if issue else "", rs[-1].get("date", "")] if x)
        tags = "".join(
            f'<span class="ag {clase_rol(r)}">{html.escape(agente(r))}'
            f'<i>{SKILLS.get(r.get("skill", ""), html.escape(r.get("skill", "")))}</i></span>'
            for r in rs
        )
        reportes = []
        for r in rs:
            cuerpo = "".join(
                f'<p><b>{html.escape(ETIQUETAS.get(k.lower(), k))}:</b> {md(v)}</p>' for k, v in r["_secciones"]
            )
            rutas = r.get("paths", "")
            if rutas:
                cuerpo += f'<p class="rutas"><b>Archivos:</b> {md(rutas)}</p>'
            reportes.append(
                f'<details><summary><span class="ag {clase_rol(r)}">{html.escape(agente(r))}</span> '
                f'{SKILLS.get(r.get("skill", ""), html.escape(r.get("skill", "")))} · {html.escape(r.get("date", ""))}'
                f'</summary>{cuerpo}</details>'
            )
        busca = html.escape(" ".join([titulo, pr, issue] + [agente(r) for r in rs]).lower())
        datos_a = html.escape("|".join(sorted({agente(r) for r in rs})))
        st = (f'<span class="st {badge[0]}">{badge[1]}</span>' if badge else "")
        tarjetas.append(
            f'<article class="bit" data-a="{datos_a}" data-q="{busca}">'
            f'<div class="bit-h"><h4>{html.escape(titulo)}</h4>{st}</div>'
            f'<div class="bit-m">{cab}</div><div class="bit-t">{tags}</div>{"".join(reportes)}</article>'
        )

    hoy = datetime.date.today().strftime("%d/%m/%Y")
    n_pr = sum(1 for k in grupos if k.startswith("pr"))
    return f"""{INI}
<section id="bitacora">
  <div class="sec-head"><span class="num">&gt;_ 13</span><h2>Bitácora de agentes</h2></div>
  <p class="sub">Cada agente reporta su trabajo en una retro al terminar (rama <code>agents/retros</code>). Acá se agrupa por cambio: cada tarjeta es un PR, con la etiqueta de cada agente que lo tocó. Tocá un agente para ver qué dijo. Actualizado {hoy}.</p>
  <div class="kpis">
    <div class="kpi hot"><b>{len(retros)}</b><span>reportes de agentes</span></div>
    <div class="kpi"><b>{n_pr}</b><span>cambios (PRs)</span></div>
    <div class="kpi"><b>{len(agentes)}</b><span>agentes distintos (rol · modelo)</span></div>
  </div>
  <div class="bit-f"><input id="bit-q" type="search" placeholder="Buscar por PR, issue, título o agente…">
  <div class="bit-b"><button class="bf on" data-a="">todos <b>{len(retros)}</b></button>{filtros}</div></div>
  <div id="bit-l">{"".join(tarjetas)}</div>
  <p id="bit-v" class="sub" hidden>Nada coincide con el filtro.</p>
  <p style="color:var(--gray);font-size:13px">Para actualizar: <code>bk bitacora</code> (alt+k «Bitácora de agentes»)</p>
</section>
<style>
#bitacora .bit-f{{position:sticky;top:46px;z-index:4;background:var(--bg);padding:10px 0;margin-bottom:8px}}
#bit-q{{width:100%;font:500 14px var(--mono);padding:10px 14px;border:2px solid var(--ink);border-radius:10px;background:var(--white);color:var(--ink)}}
.bit-b{{display:flex;flex-wrap:wrap;gap:6px;margin-top:10px}}
.bf{{font:500 12px var(--mono);border:2px solid var(--ink);border-radius:999px;background:var(--white);color:var(--ink);padding:3px 10px;cursor:pointer}}
.bf.on{{background:var(--ink);color:#fff}}
.bf b{{color:var(--red)}} .bf.on b{{color:var(--amber)}}
.bit{{background:var(--white);border:2px solid var(--ink);border-bottom-width:5px;border-radius:14px;padding:16px 18px;margin:0 0 14px}}
.bit-h{{display:flex;justify-content:space-between;gap:12px;align-items:flex-start}}
.bit h4{{font:800 18px/1.25 var(--display);margin:0}}
.bit-m{{font-size:12px;color:var(--gray);margin:4px 0 10px}}
.bit-t{{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:8px}}
.ag{{display:inline-flex;align-items:center;gap:6px;font-size:12px;font-weight:700;padding:2px 10px;border-radius:999px;border:2px solid var(--ink);background:var(--surface);white-space:nowrap}}
.ag i{{font-style:normal;font-weight:400;opacity:.75}}
.ag.implementer{{background:#DCE5FF}} .ag.implementer-light{{background:#EEF2FF}}
.ag.reviewer{{background:#FFF0C7}} .ag.orchestrator{{background:#FFE3E7}} .ag.session{{background:var(--surface)}}
.bit details{{border-top:1px solid var(--surface);padding:8px 0 0;margin-top:8px}}
.bit summary{{cursor:pointer;font-size:13px;color:var(--gray)}}
.bit details p{{font-size:14px;margin:8px 0;max-width:none;overflow-wrap:anywhere}}
.bit .rutas{{font-size:12px;color:var(--gray)}}
</style>
<script>
(() => {{
  const q = document.getElementById("bit-q"), bs = [...document.querySelectorAll("#bitacora .bf")];
  const cards = [...document.querySelectorAll("#bit-l .bit")], vacio = document.getElementById("bit-v");
  let ag = "";
  const filtrar = () => {{
    const t = q.value.trim().toLowerCase(); let n = 0;
    for (const c of cards) {{
      const ok = (!ag || c.dataset.a.split("|").includes(ag)) && (!t || c.dataset.q.includes(t));
      c.hidden = !ok; if (ok) n++;
    }}
    vacio.hidden = n > 0;
  }};
  bs.forEach(b => b.addEventListener("click", () => {{
    ag = b.dataset.a; bs.forEach(x => x.classList.toggle("on", x === b)); filtrar();
  }}));
  q.addEventListener("input", filtrar);
}})();
</script>
{FIN}"""


def main():
    try:
        with open(HTML, encoding="utf-8") as f:
            doc = f.read()
    except FileNotFoundError:
        sys.exit(f"no encuentro el HTML de estado en {HTML} (pasá la ruta como segundo argumento o en BK_BITACORA_HTML)")
    bloque = construir(leer_retros(), leer_prs())
    if INI in doc and FIN in doc:
        doc = doc[: doc.index(INI)] + bloque + doc[doc.index(FIN) + len(FIN):]
    else:
        doc = doc.replace("</main>", bloque + "\n</main>", 1)
    if NAV not in doc:
        doc = doc.replace('<a href="#pendiente">12 pendiente</a>', '<a href="#pendiente">12 pendiente</a>' + NAV, 1)
    with open(HTML, "w", encoding="utf-8") as f:
        f.write(doc)
    print(f"ok: {HTML}")


if __name__ == "__main__":
    main()
