"""Adaptador de Claude Code (ADR-007 del kit, lautioliver/barrilete-workspace#11).

Lleva los desvíos y los hallazgos que encuentra `bk learn` al store del proyecto donde pasaron, como evento v1. Escribe
con el `scripts/agents/learning.py` de ese proyecto: el kit decide el store (`.barrilete/learning.json`), el nombre del
proyecto y valida. Un proyecto sin ese script no recibe nada y su desvío queda solo en el vault.

Solo metadatos: el tipo del desvío va en `class` (como slug: `guardrail-block`), el modelo de la sesión, `harness:
claude-code`, el rol, el `area` del label del issue y `evidence_ref` (la ruta del transcript, o solo su nombre si el store
es `branch`, o la URL del PR). Nunca el
texto del transcript, de la persona o de la review.

No manda la historia de antes de su primera corrida, no repite un evento (aunque se corra `bk learn --rebuild`) y un
error de un proyecto nunca frena a `bk learn`.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time

STATE = os.path.expanduser(os.environ.get("BK_LEARN_STORE_STATE", "~/.cache/barrilete/learn-store.json"))
KIT_SCRIPT = os.path.join("scripts", "agents", "learning.py")
# Lo que contexto() del kit lee del entorno: el de quien corre learn no es el de la sesión del desvío
ENV_DROP = ("BK_TASK_DIR", "BK_MODEL", "BK_PROVIDER", "BARRILETE_MODEL", "BARRILETE_PROVIDER", "BK_HARNESS", "CLAUDECODE")
TS = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z")
SENT_MAX = 20000


def slug(x):
    return re.sub(r"[^a-z0-9]+", "-", str(x or "").lower()).strip("-")


def _git(cwd, *args):
    try:
        r = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def main_checkout(cwd):
    """El checkout principal del repo de cwd (también desde un worktree). Si el worktree ya se borró, el de al lado
    (`<repo>-wt/<n>` → `<repo>`)."""
    if not cwd:
        return None
    if os.path.isdir(cwd):
        common = _git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir")
        if common:
            return os.path.realpath(os.path.dirname(common)) if os.path.basename(common) == ".git" else None
    parent = os.path.dirname(cwd.rstrip("/"))
    if parent.endswith("-wt") and os.path.isdir(parent[:-3]):
        return os.path.realpath(parent[:-3])
    return None


def kit_of(cwd):
    main = main_checkout(cwd)
    return main if main and os.path.isfile(os.path.join(main, KIT_SCRIPT)) else None


def local_store(main):
    """True si el proyecto guarda sus datos solo en la máquina (`local`, o sin `.barrilete/learning.json`). Ante la duda
    (archivo ilegible u otro valor), False: lo que se escribe puede salir de la máquina."""
    try:
        with open(os.path.join(main, ".barrilete", "learning.json")) as f:
            return json.load(f).get("store", "local") == "local"
    except FileNotFoundError:
        return True
    except (OSError, ValueError, AttributeError):
        return False


def issue_of(branch, cwd=""):
    """El issue de la rama (`claude/324-…`, `feat/12-…`) o del worktree (`<repo>-wt/324`)."""
    m = re.match(r"(?:[a-z]+/)*(\d+)(?:-|$)", branch or "")
    if not m and cwd and os.path.dirname(cwd.rstrip("/")).endswith("-wt"):
        m = re.match(r"(\d+)(?:-|$)", os.path.basename(cwd.rstrip("/")))
    return int(m.group(1)) if m else None


def origin_slug(main):
    m = re.search(r"github\.com[:/]([^/]+/[^/\s]+?)(?:\.git)?$", _git(main, "remote", "get-url", "origin"))
    return m.group(1) if m else None


def _gh_env():
    return {k: v for k, v in os.environ.items() if k not in ("GH_CONFIG_DIR", "GH_TOKEN")}


class Store:
    def __init__(self):
        try:
            with open(STATE) as f:
                st = json.load(f)
        except (OSError, ValueError):
            st = {}
        st = st if isinstance(st, dict) else {}
        # Un estado roto no frena a learn: lo que no tiene el tipo esperado empieza de cero
        for k in ("areas", "pr_openers", "sent"):
            if not isinstance(st.get(k), dict):
                st[k] = {}
        if not isinstance(st.get("since"), str) or not TS.fullmatch(st["since"]):
            # Desde la primera corrida: la historia que ya estaba en los transcripts no se manda
            st["since"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self.st, self.since = st, st["since"]
        # clave → ts del evento, para que el recorte guarde los más nuevos
        self.sent = {str(k): str(v or "") for k, v in st["sent"].items()}
        self.areas = st["areas"]
        self.openers = st["pr_openers"]
        self.gh_failed = set()      # issues que gh no pudo leer en esta corrida: no se reintentan hasta la próxima
        self.ok = self.failed = 0
        self.projects = set()

    def save(self):
        self.st["sent"] = dict(sorted(self.sent.items(), key=lambda kv: (kv[1], kv[0]))[-SENT_MAX:])
        try:
            os.makedirs(os.path.dirname(STATE), exist_ok=True)
            with open(STATE + ".tmp", "w") as f:
                json.dump(self.st, f)
            os.replace(STATE + ".tmp", STATE)
        except OSError:
            pass

    # --- quién abrió cada PR (para el modelo de los hallazgos) ---
    def note_pr_opener(self, cwd, branch, model):
        main = main_checkout(cwd)
        if main and branch and model and model != "-":
            self.openers[f"{main}:{branch}"] = model

    def opener_model(self, main, branch):
        return self.openers.get(f"{os.path.realpath(main)}:{branch}", "")

    def area(self, main, n):
        if not n:
            return ""
        repo = origin_slug(main)
        if not repo:
            return ""
        key = f"{repo}#{n}"
        if key in self.gh_failed:
            return ""
        if key not in self.areas:
            try:
                r = subprocess.run(["gh", "issue", "view", str(n), "--repo", repo, "--json", "labels"],
                                   capture_output=True, text=True, timeout=30, env=_gh_env())
                labels = [l.get("name", "") for l in json.loads(r.stdout).get("labels", [])] if r.returncode == 0 else None
            except (OSError, ValueError, AttributeError, subprocess.SubprocessError):
                labels = None
            if labels is None:          # gh no pudo: se vuelve a probar en otra corrida
                self.gh_failed.add(key)
                return ""
            self.areas[key] = next((slug(l[5:]) for l in labels if l.startswith("area:")), "")
        return self.areas[key]

    # --- un evento de learn → el store de su proyecto ---
    def send(self, e):
        """e: un evento de learn con sus campos internos (_cwd, _branch, _path o _main, _pr, _url, _head)."""
        ts = e.get("ts") or ""
        if not TS.fullmatch(ts) or ts < self.since:
            return
        finding = e.get("type") == "review_finding"
        main = e.get("_main") if finding else kit_of(e.get("_cwd"))
        if not main or not os.path.isfile(os.path.join(main, KIT_SCRIPT)):
            return
        key = hashlib.sha1(json.dumps([main, e.get("type"), ts, e.get("session"), e.get("detail")]).encode()).hexdigest()[:20]
        if key in self.sent:
            return
        fields = {"ts": ts, "class": slug(e.get("sig") if finding else e.get("type"))}
        role = slug(e.get("role"))
        if role:
            fields["role"] = role
        if finding:
            fields["pr"] = e.get("_pr")
            fields["evidence_ref"] = e.get("_url")
            area = self.area(main, issue_of(e.get("_head")))
        else:
            path = e.get("_path") or ""
            home = os.path.expanduser("~")
            if not local_store(main):   # store branch: la ruta lleva el usuario local y la rama tiene la visibilidad del repo
                fields["evidence_ref"] = os.path.basename(path)
            elif path.startswith(home + os.sep):
                fields["evidence_ref"] = "~/" + os.path.relpath(path, home)
            else:
                fields["evidence_ref"] = path
            area = self.area(main, issue_of(e.get("_branch"), e.get("_cwd")))
        if area:
            fields["area"] = area
        model = e.get("model") or ""
        if self._emit(main, "finding" if finding else "deviation", fields, model):
            self.sent[key] = ts
            self.ok += 1
            self.projects.add(main)
        else:
            self.failed += 1

    def _emit(self, main, kind, fields, model):
        env = {k: v for k, v in os.environ.items() if k not in ENV_DROP}
        env["BK_HARNESS"] = "claude-code"
        if model and model not in ("-", "<synthetic>"):
            env["BK_MODEL"] = model      # el kit lo valida: si no es un id de modelo queda unknown
        args = [sys.executable, os.path.join(main, KIT_SCRIPT), "emit", kind]
        args += [f"{k}={v}" for k, v in fields.items() if v not in (None, "")]
        try:
            r = subprocess.run(args, cwd=main, env=env, capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.SubprocessError):
            return False
        return r.returncode == 0
