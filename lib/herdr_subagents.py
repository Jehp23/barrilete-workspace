#!/usr/bin/env python3
"""Subagentes internos de Claude por terminal de Herdr; mismas reglas que bk-shell.

Solo metadatos: los hooks relacionan sesión y terminal; agents.subagents excluye
los terminados y los transcripts sin actividad por más de diez minutos.
También dice cuántos comandos en segundo plano (tests, CI, Monitor…) dejó corriendo el último turno de cada
terminal: Herdr ve el chat quieto y lo daría por listo; el hook (hooks/agent_state.sh) los cuenta al terminar el turno.
"""
import json
import agents as A
import sidebar as S


def snapshot():
    out, background = {}, {}
    for terminal, state in A.states().items():
        # El estado manda: un hook viejo pudo dejar la cuenta en 0 (0 = sin cuenta, el mod no muestra el número).
        if state.get("state") == "background":
            n = state.get("background")
            background[terminal] = n if isinstance(n, int) and not isinstance(n, bool) and n > 0 else 0
        children = []
        for description, path in A.subagents(state.get("_sid")):
            try:
                with open(path[:-len(".jsonl")] + ".meta.json") as f:
                    meta = json.load(f)
            except (OSError, ValueError):
                continue
            # Cuenta también los ya terminados: no renumera los hermanos vivos.
            numbered = S.sub_name("session", path)
            children.append({"id": S.full_id(path), "number": numbered.split(" ", 1)[0].split(".")[-1],
                             "description": description, "type": meta.get("agentType") or "subagente",
                             "background": meta.get("requestShape") == "background", "path": path})
        if children:
            out[terminal] = children
    return {"by_terminal": out, "background": background}


if __name__ == "__main__":
    print(json.dumps(snapshot(), ensure_ascii=False))
