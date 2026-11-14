#!/usr/bin/env python3
"""Subagentes internos de Claude por terminal de Herdr; mismas reglas que bk-shell.

Solo metadatos: los hooks relacionan sesión y terminal; agents.subagents excluye
los terminados y los transcripts sin actividad por más de diez minutos.
"""
import json
import agents as A
import sidebar as S


def snapshot():
    out = {}
    for terminal, state in A.states().items():
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
    return {"by_terminal": out}


if __name__ == "__main__":
    print(json.dumps(snapshot(), ensure_ascii=False))
