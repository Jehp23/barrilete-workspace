#!/usr/bin/env python3
"""Nombres vivos de los chats de bk en Herdr: en qué está cada uno, no de qué se habló al principio.

El título que Claude le pone a una sesión (ai-title) sale del primer mensaje y no cambia más: un chat que empezó en
«PR #1090 escáner de staff» y ahora despliega el release #1095 sigue diciendo lo primero. Al terminar cada turno,
el hook (hooks/agent_state.sh) lanza esto en segundo plano; espera a que el chat se quede quieto y le pide a un
modelo barato, con lo último de la conversación (el recap de Claude, tus últimos pedidos y su última respuesta):

  título  corto, del tema de ahora: la pestaña de Herdr se llama así (etiqueta bk.autotitle)
  estado  en qué quedó o qué falta: la segunda línea de la barra de agentes (etiqueta bk.status)

Un nombre que pusiste vos (bk name, renombrar la pestaña a mano o /rename en Claude) manda: se deja el título y
solo se actualiza el estado.

  names.py update <sesión> <transcript.jsonl> <terminal>   (el hook; sale enseguida si no es un chat de bk)
  names.py update … --now                                  sin esperar a que se quede quieto
  names.py show <transcript.jsonl>                         lo que se le mandaría al modelo, sin llamarlo

Variables: BK_NAMES_MODEL (haiku), BK_NAMES_QUIET (segundos de quietud antes de nombrar, 20), BK_NAMES_OFF=1
lo apaga, BK_HC / BK_HERDR_APP (los comandos de Herdr, para las pruebas), BK_NAMES_CLAUDE (el claude a correr).
"""
import json
import os
import re
import subprocess
import sys
import time

HC = os.environ.get("BK_HC", "hc")
APP = os.environ.get("BK_HERDR_APP", "herdr-app")
CLAUDE = os.environ.get("BK_NAMES_CLAUDE", "claude")
MODEL = os.environ.get("BK_NAMES_MODEL", "haiku")
TITLE_MAX, STATUS_MAX = 40, 70
AUTO_TAB = re.compile(r"^(chat-\d+|\d+|tb\w+|\d+\. general)?$")   # los nombres que Herdr o bk ponen solos: se pueden pisar


def cache_dir():
    d = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "bk", "names")
    os.makedirs(d, exist_ok=True)
    return d


def text_of(content):
    """El texto de un mensaje (string o lista de bloques), sin resultados de herramientas ni imágenes."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    return ""


def read_transcript(path, tail_bytes=400_000):
    """{title, custom, recap, asks: [últimos pedidos], last: última respuesta} del final del transcript."""
    out = {"title": "", "custom": "", "recap": "", "asks": [], "last": ""}
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - tail_bytes))
            raw = f.read().decode("utf-8", "replace")
    except OSError:
        return out
    lines = raw.splitlines()
    if size > tail_bytes:
        lines = lines[1:]   # el primero puede estar cortado
    for line in lines:
        try:
            o = json.loads(line)
        except ValueError:
            continue
        t = o.get("type")
        if t == "ai-title":
            out["title"] = o.get("aiTitle") or out["title"]
        elif t == "custom-title":
            out["custom"] = o.get("customTitle") or out["custom"]
        elif t == "system" and o.get("subtype") == "away_summary":
            out["recap"] = o.get("content") or out["recap"]
        elif t == "user" and not o.get("isMeta") and not o.get("isSidechain"):
            s = text_of((o.get("message") or {}).get("content")).strip()
            # Lo que no escribió la persona: avisos del sistema, salidas de comandos, recordatorios
            if s and not s.startswith("<"):
                out["asks"] = (out["asks"] + [s[:600]])[-4:]
        elif t == "assistant" and not o.get("isSidechain"):
            s = text_of((o.get("message") or {}).get("content")).strip()
            if s:
                out["last"] = s[-1500:]
    return out


def prompt_for(tr, prev_title):
    asks = "\n".join(f"- {a}" for a in tr["asks"]) or "(ninguno)"
    return f"""Ponele nombre a una sesión de trabajo con un agente de código, para reconocerla en una lista de pestañas.

Título actual: {prev_title or tr['title'] or '(ninguno)'}
Resumen más reciente (puede estar viejo): {tr['recap'] or '(ninguno)'}
Últimos pedidos de la persona:
{asks}
Última respuesta del agente:
{tr['last'] or '(ninguna)'}

Respondé SOLO un JSON: {{"titulo": "...", "estado": "..."}}
- titulo: de qué trata la sesión AHORA, máximo {TITLE_MAX} caracteres, en castellano, sin punto final. Con el
  número de issue o PR si hay uno (#1095). Si el título actual todavía describe bien el tema, devolvelo igual.
- estado: en qué quedó o qué falta, máximo {STATUS_MAX} caracteres, sin punto final. Empezá con ✓ si terminó,
  con ? si espera una respuesta o decisión de la persona.
"""


def ask_model(prompt):
    env = {k: v for k, v in os.environ.items() if k not in ("HC_TERMINAL_ID", "TMUX_PANE", "TMUX")}
    try:
        r = subprocess.run([CLAUDE, "-p", "--model", MODEL, "--no-session-persistence",
                            "--settings", '{"disableAllHooks": true}', prompt],
                           capture_output=True, text=True, timeout=90, env=env, cwd=cache_dir())
    except (OSError, subprocess.TimeoutExpired):
        return None
    m = re.search(r"\{.*\}", r.stdout or "", re.S)
    if not m:
        return None
    try:
        d = json.loads(m.group(0))
    except ValueError:
        return None
    title = clean(d.get("titulo"), TITLE_MAX)
    status = clean(d.get("estado"), STATUS_MAX)
    return (title, status) if title or status else None


def clean(s, limit):
    s = re.sub(r"\s+", " ", str(s or "")).strip().rstrip(".").strip()
    return s if len(s) <= limit else s[: limit - 1].rstrip() + "…"


def hc_json(*args):
    try:
        r = subprocess.run([HC, *args], capture_output=True, text=True, timeout=10)
        return json.loads(r.stdout) if r.returncode == 0 else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def tab_of(tab_id):
    try:
        r = subprocess.run([APP, "ls"], capture_output=True, text=True, timeout=10)
        for sp in json.loads(r.stdout).get("spaces") or []:
            for tab in sp.get("tabs") or []:
                if tab.get("id") == tab_id:
                    return tab
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return None


def apply(term, labels, tr, title, status):
    """Pone las etiquetas y, si nadie le puso nombre a mano, renombra la pestaña. Devuelve lo que hizo."""
    done = []
    sets = []
    if status and status != labels.get("bk.status"):
        sets.append(f"bk.status={status}")
    hand = labels.get("bk.name") or tr["custom"]
    tab_id = labels.get("herdr.tab")
    if title and not hand:
        tab = tab_of(tab_id) if tab_id else None
        name = (tab or {}).get("name") or ""
        # La pestaña es de este chat solo si no la renombró nadie: un nombre automático o el que pusimos antes
        ours = tab is not None and (AUTO_TAB.match(name) or name == labels.get("bk.autotitle"))
        if tab is not None and not ours and name:
            # La renombraste a mano (menú, doble clic): ese es su nombre, también para bk say/go y alt+a
            sets.append(f"bk.name={name}")
        elif title != labels.get("bk.autotitle"):
            sets.append(f"bk.autotitle={title}")
        if ours and name != title:
            subprocess.run([APP, "do", "tab.rename", json.dumps({"id": tab_id, "name": title}, ensure_ascii=False)],
                           capture_output=True, timeout=10)
            done.append(f"pestaña «{title}»")
    if sets:
        subprocess.run([HC, "label", term, *sets], capture_output=True, timeout=10)
        done += sets
    return done


def update(sid, path, term, now=False):
    if os.environ.get("BK_NAMES_OFF") == "1":
        return "apagado"
    info = hc_json("get", term, "--json")
    labels = (info or {}).get("labels") or {}
    if labels.get("bk.kind") != "chat":
        return "no es un chat de bk"
    stamp = os.path.join(cache_dir(), re.sub(r"[^\w-]", "", sid) + ".json")
    try:
        before = os.path.getsize(path)
    except OSError:
        return "sin transcript"
    if not now:
        # Que se quede quieto: si en este rato empezó otro turno, el Stop de ese turno nombra después.
        time.sleep(float(os.environ.get("BK_NAMES_QUIET", "20")))
        try:
            if os.path.getsize(path) != before:
                return "siguió trabajando"
        except OSError:
            return "sin transcript"
    try:
        with open(stamp) as f:
            if json.load(f).get("size") == before:
                return "sin cambios"
    except (OSError, ValueError):
        pass
    tr = read_transcript(path)
    got = ask_model(prompt_for(tr, labels.get("bk.autotitle")))
    if not got:
        return "el modelo no respondió"
    did = apply(term, labels, tr, *got)
    with open(stamp, "w") as f:
        json.dump({"size": before, "ts": int(time.time()), "title": got[0], "status": got[1]}, f)
    return ", ".join(did) or "igual que antes"


def main(argv):
    if len(argv) >= 4 and argv[0] == "update":
        print(update(argv[1], argv[2], argv[3], now="--now" in argv))
    elif len(argv) == 2 and argv[0] == "show":
        print(prompt_for(read_transcript(argv[1]), ""))
    else:
        print("names.py update <sesión> <transcript.jsonl> <terminal> [--now] · names.py show <transcript.jsonl>", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
