#!/usr/bin/env python3
"""Retroalimentación del harness: desvíos de los agentes → patrones → lecciones → INDEX.md.

Lee los transcripts de Claude Code (~/.claude/projects/**/*.jsonl) de forma incremental y registra
eventos de desvío en el vault de Obsidian. Nunca escribe reglas: propone lecciones (status: proposed)
y solo las que la persona marca `accepted` y completa pasan a agents/INDEX.md, que leen los agentes.

Eventos:
  guardrail_block   una baranda (guardrails.py/barandas.py) frenó un comando
  hook_block        otro hook PreToolUse frenó una herramienta
  user_denied       la persona rechazó un permiso
  interrupt         la persona interrumpió al agente
  verify_fail       red.sh / verify.py terminó con error
  contract_*        un subagente devolvió escalate / blockers / question / dropped
  plan_correction   después de `planner.py --draft`, la respuesta no fue un "sí"
  user_correction   la persona corrigió al agente ("no, ...", "te dije ...")

Uso: learn.py [--quiet] [--rebuild]
"""
import glob
import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta

PROJECTS = os.path.expanduser("~/.claude/projects")
VAULT = os.path.expanduser(os.environ.get("BARRILETE_VAULT", "~/Documents/Obsidian Vault"))
AG = os.path.join(VAULT, "agents")
STATE = os.path.expanduser("~/.cache/barrilete/learn-state.json")
AGENT_STATE_DIR = os.path.expanduser("~/.cache/sketchybar/agents")

FIRST_SCAN_DAYS = 30          # primera pasada: historia reciente
PATTERN_DAYS, PATTERN_MIN = 14, 3
INDEX_MAX_RULES = 40          # el índice entra en el contexto de cada sesión: corto

RE_MODEL = re.compile(r'"model":"(claude-[^"]+)"')
RE_TOOLUSE = re.compile(r'"type":"tool_use","id":"(toolu_[^"]+)","name":"([^"]+)"')
RE_CONTRACT = re.compile(r"^\s*result:\s*(escalate|blockers|question|dropped)\b", re.M)
RE_FIELD = lambda k: re.compile(rf"^\s*{k}:\s*(\S+)", re.M)
RE_APPROVE = re.compile(r"^\s*(s[ií]|yes|dale|ok(ay)?|aprob|listo|adelante|go|perfecto|de una|confirm)", re.I)
# Solo frases que corrigen al agente. "no me deja / no me aparece" es un reporte, no una corrección.
RE_CORRECT = re.compile(
    r"^\s*(no\s*[,.!]|no\s+(es|era|eso|hagas|toques|uses|quiero|quise|cambies|borres|sigas)\b|nope\b|"
    r"eso no\b|te dije\b|est[aá] mal\b|wrong\b|that'?s (wrong|not)\b|don'?t\b|"
    r"no era (eso|as[ií])\b)", re.I)
# Señales sin firma común: se leen en el resumen del día, no generan lecciones automáticas
FREEFORM = {"interrupt", "user_correction", "plan_correction", "user_denied"}


# ---------- utilidades ----------
def project_name(cwd):
    if not cwd:
        return "?"
    base, parent = os.path.basename(cwd), os.path.basename(os.path.dirname(cwd))
    return f"{parent[:-3]}#{base}" if parent.endswith("-wt") else base


def norm(s, n=90):
    s = re.sub(r"/[\w./-]+", "<ruta>", s)
    s = re.sub(r"\b\d+\b", "N", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s[:n]


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(b.get("text", "") if isinstance(b, dict) else str(b) for b in content)
    return ""


def slug(s):
    s = re.sub(r"[^\w\s-]", "", s.lower())
    return re.sub(r"[\s_]+", "-", s).strip("-")[:60] or "leccion"


def role_for(session_id, cache={}):
    if session_id not in cache:
        try:
            with open(os.path.join(AGENT_STATE_DIR, f"{session_id}.json")) as f:
                cache[session_id] = json.load(f).get("role") or "-"
        except (OSError, ValueError):
            cache[session_id] = "-"
    return cache[session_id]


# ---------- escaneo ----------
def load_state(rebuild):
    if not rebuild:
        try:
            with open(STATE) as f:
                return json.load(f), False
        except (OSError, ValueError):
            pass
    return {"offsets": {}, "model": {}, "tools": {}, "plan": {}}, True


def scan(state, since_ts):
    offsets, models, tools, plan = state["offsets"], state["model"], state["tools"], state["plan"]
    events = []
    for path in glob.glob(os.path.join(PROJECTS, "**", "*.jsonl"), recursive=True):
        try:
            st = os.stat(path)
        except OSError:
            continue
        if st.st_mtime < since_ts:
            continue
        off = offsets.get(path, 0)
        if st.st_size < off:
            off = 0
        if st.st_size == off:
            continue
        with open(path, "rb") as f:
            f.seek(off)
            data = f.read()
        end = data.rfind(b"\n") + 1
        for raw in data[:end].splitlines():
            line = raw.decode("utf-8", "ignore")
            is_user = '"type":"user"' in line
            is_asst = '"type":"assistant"' in line
            if not (is_user or is_asst):
                continue
            if is_asst:
                m = RE_MODEL.search(line)
                if m and m.group(1) != "<synthetic>":
                    models[path] = m.group(1)
                for tid, name in RE_TOOLUSE.findall(line):
                    tools[tid] = name
                interesting = any(k in line for k in ("red.sh", "verify.py", "planner.py", "result:"))
                if not interesting:
                    continue
            elif not ('"is_error":true' in line or "interrupted by user" in line
                      or '"tool_result"' not in line):
                continue
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("type") not in ("user", "assistant") or e.get("isMeta"):
                continue
            ctx = {
                "ts": e.get("timestamp", ""), "project": project_name(e.get("cwd")),
                "session": (e.get("sessionId") or "")[:8], "model": models.get(path, "-"),
                "role": role_for(e.get("sessionId") or ""),
            }
            content = (e.get("message") or {}).get("content")
            blocks = content if isinstance(content, list) else [{"type": "text", "text": content or ""}]
            for b in blocks:
                if not isinstance(b, dict):
                    continue
                if e["type"] == "assistant":
                    events += assistant_events(b, ctx, tools, plan, path)
                else:
                    events += user_events(b, ctx, tools, plan, path)
        offsets[path] = off + end
    # acotar el mapa de herramientas (solo hace falta para resultados cercanos)
    if len(tools) > 4000:
        for k in list(tools)[:-2000]:
            del tools[k]
    return events


def ev(ctx, typ, sig, detail):
    return {**ctx, "type": typ, "sig": sig, "detail": re.sub(r"\s+", " ", detail).strip()[:280]}


def assistant_events(b, ctx, tools, plan, path):
    out = []
    if b.get("type") == "tool_use":
        cmd = str((b.get("input") or {}).get("command", ""))
        name = b.get("name", "")
        tools[b.get("id", "")] = f"{name}::{cmd[:300]}" if cmd else name
        if "planner.py" in cmd:
            plan[path] = "--draft" in cmd
    elif b.get("type") == "text":
        t = b.get("text", "")
        m = RE_CONTRACT.search(t)
        if m:
            role = (RE_FIELD("role").search(t) or [None, ctx["role"]])[1]
            model = (RE_FIELD("model").search(t) or [None, ctx["model"]])[1]
            issue = (RE_FIELD("issue").search(t) or [None, "?"])[1]
            summ = (RE_FIELD("summary").search(t) or [None, ""])[1]
            c = {**ctx, "role": role, "model": model}
            out.append(ev(c, f"contract_{m.group(1)}", f"{m.group(1)} · {role}",
                          f"issue {issue}: {t[t.find('summary:'):][:240] if 'summary:' in t else summ}"))
    return out


def user_events(b, ctx, tools, plan, path):
    out = []
    if b.get("type") == "tool_result":
        if not b.get("is_error"):
            return out
        t = text_of(b.get("content"))
        tool = tools.get(b.get("tool_use_id", ""), "?")
        if "hook error" in t and "PreToolUse" in t:
            reason = t[t.find("]:") + 2:] if "]:" in t else t
            first = reason.strip().split("\n")[0]
            if "):" in first:
                first = first.split("):", 1)[1]
            first = first.strip().rstrip(".")
            typ = "guardrail_block" if re.search(r"baranda|guardrail", t, re.I) else "hook_block"
            out.append(ev(ctx, typ, norm(first), first))
        elif "doesn't want to proceed" in t:
            out.append(ev(ctx, "user_denied", f"rechazado · {tool.split('::')[0]}",
                          tool.split("::", 1)[1] if "::" in tool else tool))
        elif re.search(r"red\.sh|verify\.py", tool):
            which = "red.sh" if "red.sh" in tool else "verify.py"
            out.append(ev(ctx, "verify_fail", f"{which} falló", t[:240]))
        return out
    if b.get("type") != "text":
        return out
    t = (b.get("text") or "").strip()
    if not t:
        return out
    if t.startswith("[Request interrupted by user"):
        out.append(ev(ctx, "interrupt", "interrupción", t))
        return out
    # Mensajes de sistema / comandos no son texto de la persona
    if t.startswith(("<", "Caveat:", "[Image")) or "system-reminder" in t[:200]:
        return out
    if plan.get(path):
        if RE_APPROVE.match(t):
            plan[path] = False
        else:
            out.append(ev(ctx, "plan_correction", "plan corregido", t))
        return out
    if RE_CORRECT.match(t):
        out.append(ev(ctx, "user_correction", "corrección", t))
    return out


# ---------- vault ----------
def month_file(day):
    return os.path.join(AG, "data", f"events-{day[:7]}.jsonl")


def local_day(ts):
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone().strftime("%Y-%m-%d")
    except ValueError:
        return datetime.now().strftime("%Y-%m-%d")


def load_events(days):
    since = (datetime.now() - timedelta(days=days)).strftime("%Y-%m-%d")
    out = []
    for f in sorted(glob.glob(os.path.join(AG, "data", "events-*.jsonl"))):
        for raw in open(f, encoding="utf-8"):
            try:
                e = json.loads(raw)
            except ValueError:
                continue
            if e.get("day", "") >= since:
                out.append(e)
    return out


LABELS = {
    "guardrail_block": "baranda", "hook_block": "hook", "user_denied": "permiso rechazado",
    "interrupt": "interrupción", "verify_fail": "verificación fallida",
    "contract_escalate": "escaló", "contract_blockers": "review con bloqueantes",
    "contract_question": "pregunta", "contract_dropped": "abandonó",
    "plan_correction": "plan corregido", "user_correction": "corrección",
}


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def short_model(m):
    return re.sub(r"-\d{8}$", "", (m or "-").replace("claude-", ""))


def write_day(day, evs):
    def table(es):
        return ("| hora (UTC) | tipo | proyecto | rol | modelo | detalle |\n|---|---|---|---|---|---|\n"
                + "\n".join(
                    f"| {e['ts'][11:16]} | {LABELS.get(e['type'], e['type'])} | {e['project']} | "
                    f"{e['role']} | {short_model(e['model'])} | {e['detail'][:140].replace('|', '/')} |"
                    for e in sorted(es, key=lambda e: e["ts"])))
    c = Counter(LABELS.get(e["type"], e["type"]) for e in evs)
    resumen = " · ".join(f"{k} {v}" for k, v in c.most_common())
    auto = [e for e in evs if e["type"] not in FREEFORM]
    leer = [e for e in evs if e["type"] in FREEFORM and e["type"] != "interrupt"]
    n_int = sum(1 for e in evs if e["type"] == "interrupt")
    body = f"# Desvíos {day}\n\n{resumen}\n"
    if leer:
        body += ("\n## Para leer: tus correcciones y rechazos\n"
                 "No generan lecciones solas. Si ves un patrón, creá una lección en `lessons/`.\n\n"
                 + table(leer) + "\n")
    if auto:
        body += "\n## Con firma (alimentan [[patterns]])\n\n" + table(auto) + "\n"
    if n_int:
        body += f"\nInterrupciones: {n_int}.\n"
    write(os.path.join(AG, "deviations", f"{day}.md"),
          f"---\ntipo: desvios\nfecha: {day}\ntotal: {len(evs)}\n---\n" + body)


def existing_lessons():
    out = {}
    for f in glob.glob(os.path.join(AG, "lessons", "*.md")):
        txt = open(f, encoding="utf-8").read()
        m = re.search(r'^signature:\s*"?(.*?)"?\s*$', txt, re.M)
        if m:
            out[m.group(1)] = f
    return out


def suggested_rule(typ, sig):
    if typ == "guardrail_block":
        return (f"No intentes {sig}: es una acción humana. No busques otro camino; "
                "pedile a la persona que la corra ella.")
    return ""


def write_patterns_and_lessons(evs):
    groups = defaultdict(list)
    for e in evs:
        groups[(e["type"], e["sig"], e["project"])].append(e)
    rows, nuevas = [], []
    lessons = existing_lessons()
    for (typ, sig, proj), g in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        g = sorted(g, key=lambda e: e["ts"])
        rows.append(f"| {len(g)} | {LABELS.get(typ, typ)} | {sig.replace('|', '/')} | {proj} | "
                    f"{', '.join(sorted({short_model(e['model']) for e in g}))} |")
        key = f"{typ}::{sig}::{proj}"
        if len(g) < PATTERN_MIN or key in lessons or typ in FREEFORM:
            continue
        name = slug(f"{LABELS.get(typ, typ)} {sig}")
        path = os.path.join(AG, "lessons", f"{name}.md")
        ejemplos = "\n".join(f"- {e['day']} · {e['project']} · {short_model(e['model'])}: {e['detail'][:200]}"
                             for e in g[-3:])
        write(path, f"""---
status: proposed   # proposed → accepted (entra a INDEX.md) | retired
type: {typ}
signature: "{key}"
scope: {proj}      # global, o el proyecto donde aplica
count: {len(g)}
first_seen: {g[0]['day']}
last_seen: {g[-1]['day']}
---
# {LABELS.get(typ, typ).capitalize()}: {sig}

Patrón detectado por `bk learn`: {len(g)} veces en {PATTERN_DAYS} días.

## Ejemplos
{ejemplos}

## Regla para los agentes
<!-- Una línea. Es lo único que pasa a INDEX.md cuando status: accepted. Vacía = no entra. -->
{suggested_rule(typ, sig)}

## Notas
<!-- Si la regla es de un solo proyecto, considerá llevarla a su AGENTS.md o a /improve-skills: el repo manda en lo del proyecto. -->
""")
        nuevas.append(name)
    write(os.path.join(AG, "patterns.md"),
          f"# Patrones (últimos {PATTERN_DAYS} días)\n\nGenerado por `bk learn`. Con ≥{PATTERN_MIN} repeticiones se propone una lección.\n\n"
          "| veces | tipo | firma | proyecto | modelos |\n|---|---|---|---|---|\n" + "\n".join(rows) + "\n")
    return nuevas


def write_models(evs30):
    by = defaultdict(Counter)
    sessions = defaultdict(set)
    for e in evs30:
        k = (short_model(e["model"]), e["role"])
        by[k][LABELS.get(e["type"], e["type"])] += 1
        sessions[k].add(e["session"])
    rows = "\n".join(
        f"| {m} | {r} | {sum(c.values())} | {len(sessions[(m, r)])} | "
        f"{' · '.join(f'{k} {v}' for k, v in c.most_common(4))} |"
        for (m, r), c in sorted(by.items(), key=lambda kv: -sum(kv[1].values())))
    write(os.path.join(AG, "models.md"),
          "# Desvíos por modelo y rol (30 días)\n\nGenerado por `bk learn`. Sirve para decidir qué modelo corre cada rol (roles.yml).\n\n"
          "| modelo | rol | desvíos | sesiones con desvíos | principales |\n|---|---|---|---|---|\n" + rows + "\n")


def write_index():
    rules = []
    for f in sorted(glob.glob(os.path.join(AG, "lessons", "*.md"))):
        txt = open(f, encoding="utf-8").read()
        if not re.search(r"^status:\s*accepted\b", txt, re.M):
            continue
        scope = (re.search(r"^scope:\s*(\S+)", txt, re.M) or [None, "global"])[1]
        sec = re.search(r"## Regla para los agentes\n(.*?)(\n## |\Z)", txt, re.S)
        rule = re.sub(r"<!--.*?-->", "", sec.group(1), flags=re.S).strip() if sec else ""
        if rule:
            rules.append(f"- {'' if scope == 'global' else f'[solo en {scope}] '}{rule.splitlines()[0]}")
    rules = rules[:INDEX_MAX_RULES]
    write(os.path.join(AG, "INDEX.md"),
          "<!-- Generado por `bk learn` desde agents/lessons/ (status: accepted). No editar acá: editá la lección. -->\n"
          "# Lecciones aprendidas de agentes\n\n"
          "Reglas que salieron de desvíos reales y la persona aprobó. Aplican además de AGENTS.md; "
          "si chocan con el AGENTS.md de un proyecto, manda el proyecto.\n\n"
          + ("\n".join(rules) if rules else "_Todavía no hay lecciones aceptadas._") + "\n")
    return len(rules)


def main():
    quiet = "--quiet" in sys.argv
    if not os.path.isdir(VAULT):
        sys.exit(f"learn.py: no existe el vault {VAULT}")
    state, fresh = load_state("--rebuild" in sys.argv)
    since = 0 if not fresh else (datetime.now() - timedelta(days=FIRST_SCAN_DAYS)).timestamp()
    if fresh:  # reconstrucción: evitar eventos duplicados
        for f in glob.glob(os.path.join(AG, "data", "events-*.jsonl")):
            os.remove(f)
    new = scan(state, since)

    touched = set()
    for e in new:
        e["day"] = local_day(e["ts"])
        touched.add(e["day"])
        os.makedirs(os.path.join(AG, "data"), exist_ok=True)
        with open(month_file(e["day"]), "a", encoding="utf-8") as f:
            f.write(json.dumps(e, ensure_ascii=False) + "\n")

    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE + ".tmp", "w") as f:
        json.dump(state, f)
    os.replace(STATE + ".tmp", STATE)

    evs30 = load_events(30)
    for day in touched:
        write_day(day, [e for e in evs30 if e["day"] == day])
    since14 = (datetime.now() - timedelta(days=PATTERN_DAYS)).strftime("%Y-%m-%d")
    nuevas = write_patterns_and_lessons([e for e in evs30 if e["day"] >= since14])
    write_models(evs30)
    n_rules = write_index()
    proposed = sum(1 for f in glob.glob(os.path.join(AG, "lessons", "*.md"))
                   if re.search(r"^status:\s*proposed\b", open(f, encoding="utf-8").read(), re.M))

    if not quiet:
        print(f"{len(new)} desvíos nuevos · {len(evs30)} en 30 días · {proposed} lecciones por revisar · "
              f"{n_rules} reglas en INDEX.md")
        for n in nuevas:
            print(f"  nueva lección propuesta: agents/lessons/{n}.md")


if __name__ == "__main__":
    main()
