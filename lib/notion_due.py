#!/usr/bin/env python3
"""Entregas pendientes desde la página pública de Notion (modo uni de la barra).

Lee la base "Entregas" con la API pública de notion.site (no hace falta token: la página está
publicada). Config en ~/.config/bk/uni.json:
  {"notion": {"site": "https://<algo>.notion.site", "space": "<id>", "collection": "<id>", "view": "<id>",
              "props": {"date": "gwfJ", "status": "Rwoy", "time": "Y\\\\Qv", "type": "uO}D"}}}
Salida: una línea por entrega sin terminar (Estado distinto de "Listo"), ordenadas por fecha:
  <AAAA-MM-DD>\t<HH:MM o vacío>\t<tipo>\t<estado>\t<nombre>
--overdue incluye las vencidas; sin eso, solo de hoy en adelante. Caché de 5 minutos.
"""
import json, os, sys, time, urllib.request
from datetime import date

CONF = os.path.expanduser("~/.config/bk/uni.json")
CACHE = os.path.expanduser("~/.cache/bk/notion_entregas.json")


def fetch(n):
    body = {
        "collection": {"id": n["collection"], "spaceId": n["space"]},
        "collectionView": {"id": n["view"], "spaceId": n["space"]},
        "loader": {"type": "reducer", "reducers": {"collection_group_results": {"type": "results", "limit": 500}},
                   "searchQuery": "", "userTimeZone": "America/Argentina/Buenos_Aires"},
    }
    req = urllib.request.Request(n["site"].rstrip("/") + "/api/v3/queryCollection", data=json.dumps(body).encode(),
                                 headers={"content-type": "application/json", "user-agent": "bk-uni/1"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def rows(data, props):
    def val(x):
        v = x.get("value", {}); return v.get("value", v)

    def txt(p, k):
        return "".join(s[0] for s in p.get(k, []) if isinstance(s, list) and s)

    def dt(p, k):
        for s in p.get(k, []):
            for f in (s[1] if len(s) > 1 else []):
                if f and f[0] == "d":
                    return f[1].get("start_date", "")
        return ""
    bl = data["recordMap"]["block"]
    ids = data["result"]["reducerResults"]["collection_group_results"]["blockIds"]
    for i in ids:
        p = val(bl.get(i, {})).get("properties", {})
        yield dt(p, props["date"]), txt(p, props["time"]), txt(p, props["type"]), txt(p, props["status"]), \
            txt(p, "title").strip()


def main():
    try:
        n = json.load(open(CONF))["notion"]
    except (OSError, ValueError, KeyError):
        sys.exit(2)
    data = None
    try:
        if time.time() - os.path.getmtime(CACHE) < 300:
            data = json.load(open(CACHE))
    except (OSError, ValueError):
        pass
    if data is None:
        try:
            data = fetch(n)
            os.makedirs(os.path.dirname(CACHE), exist_ok=True)
            json.dump(data, open(CACHE, "w"))
        except Exception:
            try:
                data = json.load(open(CACHE))   # sin red: lo último que se leyó
            except (OSError, ValueError):
                sys.exit(1)
    today = date.today().isoformat()
    pend = [r for r in rows(data, n["props"]) if r[0] and r[3].lower() != "listo"
            and ("--overdue" in sys.argv or r[0] >= today)]
    for d, t, ty, st, name in sorted(pend):
        print(f"{d}\t{t}\t{ty}\t{st}\t{name}")


if __name__ == "__main__":
    main()
