#!/usr/bin/env python3
"""Hook de Claude Code (UserPromptSubmit y PostToolUse): le avisa al agente que ya carga mucho contexto.

Cada llamada vuelve a leer todo el contexto, así que una sesión larga sale cara. La tira, el riel y bk monitor
se lo muestran a la persona; esto se lo dice al agente, con un mensaje en `additionalContext`:
  - ámbar (desde 200k): cuando termine lo que está haciendo, que recomiende /clear o un chat nuevo.
  - rojo (desde 400k): que cierre en un punto estable y deje el resumen para seguir en un chat nuevo, con la
    plantilla de handoff.py, en ~/.local/state/bk/handoffs/<session_id>.md (bk chat --desde lo toma).

Sin repetir: avisa una vez al cruzar 200k, una al cruzar 400k y después cada +100k. Lo último avisado queda por
sesión en ~/.cache/bk/context_hook/<session_id> (BK_CONTEXT_HOOK_STATE lo cambia, para los tests). Si el
contexto baja (/compact), vuelve a avisar al cruzar de nuevo.

Además, en PostToolUse: si el agente acaba de guardar (Write) el resumen de su sesión, corre `bk handoff --listo
<session_id>` suelto, sin esperarlo: bk abre el chat nuevo o avisa (lib/handoff.py). BK_HANDOFF_BK cambia el bk
que corre (los tests).

Por debajo de 200k, dentro de un subagente (trae agent_id) o ante cualquier error: no imprime nada y sale 0.
Nunca bloquea. El contexto sale de usage.context_of (el último turno del transcript), sin otro parser.
"""
import json
import os
import sys

STEP = 100_000   # después del rojo, cada cuánto vuelve a avisar


def bucket(tokens, U):
    """0 abajo de 200k · 1 ámbar · 2 rojo (400k) · 3 desde 500k · 4 desde 600k …"""
    if not tokens or tokens < U.CTX_WARN:
        return 0
    if tokens < U.CTX_HIGH:
        return 1
    return 2 + (tokens - U.CTX_HIGH) // STEP


def next_chat():
    """Cómo seguir en un chat nuevo: con Herdr, alt+h (pide el resumen y abre el chat nuevo solo); con tmux, alt+n.
    El backend como lo decide bin/bk: BK_BACKEND; si no, ~/.config/bk/backend."""
    b = os.environ.get("BK_BACKEND", "")
    if not b:
        try:
            with open(os.path.expanduser("~/.config/bk/backend")) as f:
                b = f.read().strip()
        except OSError:
            b = ""
    return "en un chat nuevo con su resumen (alt+h)" if b == "herdr" else "en un chat nuevo (alt+n)"


def message(tokens, U, sid="", cwd=None):
    n = U.human_ctx(tokens)
    if U.ctx_level(tokens) == "high":
        head = (f"Llevás {n} de contexto: cerrá lo que estás haciendo en un punto estable y no arranques trabajo "
                "nuevo en esta sesión. Si sos un agente de bk (tenés BK_TASK_DIR), terminá la ronda con tu `bk done` "
                "normal y no hagas nada más. Si no:")
        try:
            import handoff
            return f"{head} {handoff.request(sid, cwd=cwd)}"
        except Exception:   # sin la plantilla, el aviso de antes
            return (f"{head} dejá un resumen corto de dónde quedaste (qué está hecho, qué falta, archivos y "
                    "comandos) y recomendale a la persona seguir en una sesión nueva.")
    return (f"Llevás {n} de contexto y cada llamada lo vuelve a leer: cuando termines lo que estás haciendo, "
            f"recomendale a la persona seguir con /clear o {next_chat()}.")


def handoff_written(ev, sid):
    """El agente guardó el resumen de esta sesión: que bk siga (abrir el chat nuevo o avisar), sin esperarlo."""
    if ev.get("hook_event_name") != "PostToolUse" or ev.get("tool_name") != "Write":
        return
    path = (ev.get("tool_input") or {}).get("file_path") or ""
    import handoff
    import subprocess
    if not path or os.path.realpath(os.path.expanduser(path)) != os.path.realpath(handoff.md_path(sid)):
        return
    bk = os.environ.get("BK_HANDOFF_BK") or os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "bin", "bk")
    subprocess.Popen([bk, "handoff", "--listo", sid], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)


def main():
    sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
    import usage as U

    ev = json.load(sys.stdin)
    if ev.get("agent_id"):   # subagente: su contexto no es el del transcript principal, y son cortos
        return
    event, sid, path = ev.get("hook_event_name"), ev.get("session_id"), ev.get("transcript_path")
    if event not in ("UserPromptSubmit", "PostToolUse") or not sid or not path:
        return
    try:
        handoff_written(ev, sid)
    except Exception:   # el aviso de contexto sale igual
        pass
    tokens = U.context_of(path=path)
    now = bucket(tokens, U)

    state_dir = os.environ.get("BK_CONTEXT_HOOK_STATE") or os.path.expanduser("~/.cache/bk/context_hook")
    state = os.path.join(state_dir, os.path.basename(sid))
    try:
        last = int(open(state).read().strip() or 0)
    except (OSError, ValueError):
        last = 0
    if now != last:   # sube: avisar; baja (/compact): recordarlo para volver a avisar al cruzar otra vez
        os.makedirs(state_dir, exist_ok=True)
        with open(state + ".tmp", "w") as f:
            f.write(str(now))
        os.replace(state + ".tmp", state)
    if now <= last:
        return
    sys.stdout.write(json.dumps({"hookSpecificOutput": {"hookEventName": event,
                                                        "additionalContext": message(tokens, U, sid, ev.get("cwd"))}},
                                ensure_ascii=False) + "\n")


if __name__ == "__main__":
    try:
        main()
    except BaseException:   # nunca romper la sesión: ni salida a medias ni código distinto de 0
        pass
    sys.exit(0)
