#!/usr/bin/env python3
"""bk snapshot / bk restore: foto de tus workspaces y agentes, para volver a dejarlos como estaban.

  bk snapshot              saca una foto ahora (workspaces bk-…, su chat y la sesión de Claude; ventanas de agents)
  bk snapshot --auto       lo mismo, pero solo si pasaron 5 min o cambió algo (lo corre Sketchybar cada ~2 min)
  bk restore --list        las fotos guardadas, de la más nueva a la más vieja
  bk restore [N|archivo]   vuelve a la foto N de la lista (1 = la última): recrea lo que falte y retoma cada
                           chat y agente con `claude --resume`. Lo que ya está corriendo no lo toca.
  bk restore … --dry-run   muestra qué haría, sin hacer nada

Las fotos van a ~/.cache/bk/snapshots/ (se guardan las últimas 200). Los agentes se retoman con la identidad
del bot, como cuando los lanza bk, y cada chat y agente con su cuenta (bk account). Pensado para después de que
se cae tmux o se reinicia la máquina.
"""
import glob
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import agents as AG  # noqa: E402

DIR = os.path.join(os.environ.get("BK_CACHE_DIR", os.path.expanduser("~/.cache/bk")), "snapshots")
BK = os.path.join(os.path.dirname(HERE), "bin", "bk")
SESSION = os.environ.get("BK_SESSION", "agents")
KEEP, AUTO_EVERY = 200, 300
RESUME = re.compile(r"claude\b.*--resume\s+([0-9a-f-]{36})")
ACCOUNTS = os.path.join(HERE, "accounts.py")


def tmux(*args):
    return AG.sh("tmux", *args)


def sid_of(pane, sts, start=""):
    """La sesión de Claude que corre en un pane: por el estado del hook, o por el --resume con que se lanzó."""
    sid = (sts.get(pane) or {}).get("_sid") or ""
    if not sid:
        m = RESUME.search(start or "")
        sid = m.group(1) if m else ""
    return sid


def take():
    sts = AG.states()
    shot = {"ts": time.time(), "workspaces": [], "agents": []}
    rows = []
    for l in tmux("list-sessions", "-F", "#{session_created}\t#{session_name}").splitlines():
        c, _, n = l.partition("\t")
        rows.append((int(c or 0), n))
    for created, name in sorted(rows):   # en el orden en que se crearon (el de la tira)
        if not name.startswith("bk"):
            continue
        chat, cwd, start = "", "", ""
        for l in tmux("list-panes", "-t", f"={name}:main", "-F",
                      "#{pane_id}\t#{pane_start_command}\t#{pane_current_path}").splitlines():
            pid, st, path = (l.split("\t") + ["", ""])[:3]
            if "bk rail" in st or "bk sidebar" in st:
                continue
            chat, start, cwd = pid, st, path
            break
        env = tmux("show-environment", "-t", f"={name}", "BK_PROJECT").strip()
        shot["workspaces"].append({
            "name": name, "created": created,
            "project": env.split("=", 1)[1] if env.startswith("BK_PROJECT=") else "",
            "cwd": (sts.get(chat) or {}).get("cwd") or cwd,
            "sid": sid_of(chat, sts, start),
            "label": tmux("show-options", "-qv", "-t", f"={name}:", "@bk_name").strip(),
            "id": tmux("show-options", "-qv", "-t", f"={name}:", "@bk_id").strip(),
            # bk account use: la cuenta de la sesión por proveedor (sin clave: la default)
            "account": {p: v for p in ("claude", "codex")
                        if (v := tmux("show-options", "-qv", "-t", f"={name}:", f"@bk_account_{p}").strip())},
        })
    for l in tmux("list-panes", "-s", "-t", f"={SESSION}", "-F",
                  "#{window_name}\t#{pane_id}\t#{pane_start_command}\t#{pane_current_path}\t#{@bk_ws}\t#{@bk_account}").splitlines():
        win, pane, start, path, ws, acct = (l.split("\t") + ["", "", "", "", ""])[:6]
        if ws:   # el chat de un workspace de visita: se guarda con su workspace
            continue
        st = sts.get(pane) or {}
        shot["agents"].append({"win": win, "cwd": st.get("cwd") or path, "sid": sid_of(pane, sts, start),
                               "role": st.get("role", ""), "model": st.get("model", ""), "ref": st.get("ref", ""),
                               "account": acct})
    return shot


def files():
    return sorted(glob.glob(os.path.join(DIR, "*.json")), reverse=True)


def save(auto=False):
    shot = take()
    if not shot["workspaces"] and not shot["agents"]:
        return None   # tmux vacío (recién caído): no pisar la última foto buena
    os.makedirs(DIR, exist_ok=True)
    prev = files()
    if auto and prev:
        try:
            last = json.load(open(prev[0]))
            same = {k: last.get(k) for k in ("workspaces", "agents")} == {k: shot[k] for k in ("workspaces", "agents")}
            age = time.time() - last.get("ts", 0)
            if (same and age < AUTO_EVERY) or age < 60:   # igual que hace poco, o una foto hace menos de 1 min
                return None
        except (OSError, ValueError):
            pass
    path = os.path.join(DIR, time.strftime("%Y%m%d-%H%M%S") + ".json")
    with open(path, "w") as f:
        json.dump(shot, f, ensure_ascii=False, indent=1)
    for old in files()[KEEP:]:
        os.remove(old)
    return path


def describe(shot):
    ws = ", ".join(w["name"][3:] for w in shot["workspaces"]) or "-"
    ag = ", ".join(a["win"] for a in shot["agents"]) or "-"
    return f"workspaces: {ws} · agentes: {ag}"


def server_start():
    try:
        return int(tmux("display-message", "-p", "#{start_time}").strip() or 0)
    except ValueError:
        return 0


def pick(arg):
    fs = files()
    if not arg:
        # Sin número: la última foto de ANTES de que arrancara este server de tmux (la de después de una caída
        # ya muestra todo vacío). Si el server es el mismo de siempre, la última.
        start = server_start()
        for i, f in enumerate(fs, 1):
            try:
                if not start or json.load(open(f)).get("ts", 0) < start:
                    arg = str(i)
                    break
            except (OSError, ValueError):
                continue
        arg = arg or "1"
    if arg.isdigit():
        n = int(arg)
        if not 1 <= n <= len(fs):
            sys.exit(f"bk restore: no hay foto {n} (bk restore --list)")
        return fs[n - 1]
    if os.path.exists(arg):
        return arg
    sys.exit(f"bk restore: no encuentro {arg}")


def ensure_server():
    """restore puede correr con tmux caído: levantar el server con la sesión de agentes y apuntar TMUX a él."""
    if SESSION not in tmux("list-sessions", "-F", "#{session_name}").split():
        subprocess.run(["tmux", "new-session", "-d", "-s", SESSION, "-n", "restore"], check=False)
    sock = tmux("display-message", "-p", "#{socket_path}").strip()
    env = dict(os.environ)
    if sock:
        env["TMUX"] = f"{sock},0,0"   # bk solo mira que esté definida para no hacer attach
    return env


def chat_pane(ws):
    for l in tmux("list-panes", "-t", f"={ws}:main", "-F", "#{pane_id}\t#{pane_start_command}").splitlines():
        pid, st = (l.split("\t") + [""])[:2]
        if "bk rail" not in st and "bk sidebar" not in st:
            return pid
    return ""


def running_claude(pane):
    """¿Hay un claude vivo en ese pane? (el comando visible a veces es zsh, que lo lanzó)"""
    pid = tmux("display-message", "-p", "-t", pane, "#{pane_pid}").strip()
    if not pid:
        return False
    out = AG.sh("ps", "-o", "command=", "-g", pid)
    return any(re.search(r"(^|[\s/])claude(\s|$)", l.strip()) for l in out.splitlines())


def pane_running(sid):
    """El pane donde ya corre esa sesión de Claude (por el estado del hook o por el --resume del proceso), o ""."""
    if not sid:
        return ""
    for p, st in AG.states().items():
        if st.get("_sid") == sid and tmux("display-message", "-p", "-t", p, "#{pane_id}").strip() == p and running_claude(p):
            return p
    for l in tmux("list-panes", "-a", "-F", "#{pane_id}\t#{pane_pid}").splitlines():
        p, pid = (l.split("\t") + [""])[:2]
        if sid in AG.sh("ps", "-o", "command=", "-g", pid):
            return p
    return ""


def bot_env(cwd):
    """Las variables del bot para un agente (las mismas que le da bk al lanzarlo)."""
    out = AG.sh(BK, "_botenv", cwd, timeout=30)
    args = []
    for l in out.splitlines():
        if "=" in l:
            args += ["-e", l]
    return args


def account_env(name):
    """-e para tmux que lanzan con esa cuenta (como bk). Si la cuenta ya no existe: la default, con aviso."""
    if not name or name == "default":
        return []
    prov = AG.sh("python3", ACCOUNTS, "provider", name).strip()
    kv = AG.sh("python3", ACCOUNTS, "env", name).strip() if prov else ""
    if not kv:
        print(f"  ! la cuenta {name} ya no existe: va con la default")
        return []
    return ["-e", kv, "-e", f"BK_ACCOUNT_{prov.upper()}={name}"]


def restore(path, dry):
    shot = json.load(open(path))
    print(f"foto {os.path.basename(path)[:-5]} · {describe(shot)}")
    env = ensure_server() if not dry else os.environ
    have = set(tmux("list-sessions", "-F", "#{session_name}").split())
    # primero los que tenían número fijo, así uno sin número (foto vieja) no les gana el suyo
    for w in sorted(shot["workspaces"], key=lambda w: not w.get("id")):
        name, sid = w["name"], w["sid"]
        cwd = w["cwd"] if os.path.isdir(w.get("cwd") or "") else w.get("project") or os.path.expanduser("~")
        if name not in have:
            print(f"  + workspace {name} ({cwd})" + (f" · retoma {sid[:8]}" if sid else ""))
            if dry:
                continue
            subprocess.run([BK, "ws", w.get("project") or cwd], env={**env, "BK_WS_SESSION": name, "BK_WS_ID": w.get("id") or "", "BK_CLIENT": "nocliente", "BK_RESTORING": "1"},
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=cwd)
        pane = chat_pane(name) if not dry else ""
        if w.get("label") and not dry:
            tmux("set-option", "-t", f"={name}:", "@bk_name", w["label"])
        accts = w.get("account") or {}
        if accts and name not in have:
            print(f"  · {name}: cuenta " + ", ".join(f"{p} {v}" for p, v in accts.items()))
            if not dry:   # la sesión vuelve a quedar con su cuenta (opción y entorno, como bk account use)
                for v in accts.values():
                    subprocess.run([BK, "account", "use", v], env={**env, "BK_FROM": name},
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if not sid:
            continue
        if not dry and pane and running_claude(pane) and name in have:
            print(f"  = {name}: su chat sigue corriendo")
            continue
        elsewhere = pane_running(sid) if not dry else ""
        if elsewhere and elsewhere != pane:
            # la sesión ya corre en otro lado (la retomaste a mano): traerla a su lugar, no abrir otra copia
            print(f"  ⇄ {name}: su chat ya corría en otra ventana; lo traigo a su lugar")
            tmux("swap-pane", "-d", "-s", elsewhere, "-t", pane)
            tmux("kill-pane", "-t", pane)   # el chat nuevo que había abierto bk ws quedó donde estaba el otro
            continue
        if name in have:
            print(f"  ↻ {name}: retoma el chat {sid[:8]}")
        if not dry and pane:
            tmux("respawn-pane", "-k", "-t", pane, "-c", cwd, *account_env(accts.get("claude")),
                 f"claude --resume {sid}; exec $SHELL")
    if not dry:   # traer chats a su lugar puede vaciar (y cerrar) la sesión de agentes: asegurarla de nuevo
        ensure_server()
    wins = set(tmux("list-windows", "-t", f"={SESSION}", "-F", "#{window_name}").split())
    for a in shot["agents"]:
        if not dry:   # volver a mirar justo antes: una ventana recién creada tarda en mostrar su claude
            wins = set(tmux("list-windows", "-t", f"={SESSION}", "-F", "#{window_name}").split())
        if a["win"] not in wins and a["sid"] and not dry and pane_running(a["sid"]):
            print(f"  = agente {a['win']}: ya corre en otra ventana")
            continue
        if a["win"] in wins or not a["sid"]:
            if a["win"] in wins:
                print(f"  = agente {a['win']}: sigue corriendo")
            continue
        print(f"  + agente {a['win']} ({a['cwd']}) · retoma {a['sid'][:8]}" + (" como el bot" if a.get("role") else "")
              + (f" · cuenta {a['account']}" if a.get("account") else ""))
        if dry:
            continue
        e = ["-e", f"BARRILETE_ROLE={a['role']}", "-e", f"BARRILETE_MODEL={a['model']}"] if a.get("role") else []
        if a.get("ref"):
            e += ["-e", f"BARRILETE_ISSUE={a['ref']}"]
        if a.get("role"):
            e += bot_env(a["cwd"])
        e += account_env(a.get("account"))
        subprocess.run(["tmux", "new-window", "-d", "-t", f"={SESSION}:", "-n", a["win"], "-c", a["cwd"], *e,
                        f"claude --resume {a['sid']}"], check=False)
        tmux("set-option", "-w", "-t", f"={SESSION}:{a['win']}", "remain-on-exit", "on")
        if a.get("account"):
            tmux("set-option", "-w", "-t", f"={SESSION}:{a['win']}", "@bk_account", a["account"])
    if not dry:
        # El renovador del token del bot vive en el server de tmux: si tmux se cayó, murió con él.
        # bk _botenv lo vuelve a lanzar (una vez por repo) aunque el agente ya estuviera corriendo.
        for cwd in {a["cwd"] for a in shot["agents"] if a.get("role") and os.path.isdir(a["cwd"])}:
            bot_env(cwd)
        tmux("kill-window", "-t", f"={SESSION}:restore")   # la ventana que levantó el server, si hizo falta
        AG.sh("sketchybar", "--trigger", "agent_update")


def main():
    a = sys.argv[1:]
    cmd = a[0] if a else "save"
    if cmd == "save":
        p = save(auto="--auto" in a)
        if "--auto" not in a:
            print(f"foto guardada: {p}" if p else "nada que guardar (tmux vacío)")
        return
    if cmd == "list":
        for i, f in enumerate(files()[:30], 1):
            try:
                shot = json.load(open(f))
            except (OSError, ValueError):
                continue
            print(f"{i:>3}  {time.strftime('%d/%m %H:%M', time.localtime(shot['ts']))}  {describe(shot)}")
        return
    if cmd == "restore":
        rest = [x for x in a[1:] if not x.startswith("--")]
        restore(pick(rest[0] if rest else ""), "--dry-run" in a)
        return
    sys.stderr.write(__doc__)
    sys.exit(2)


if __name__ == "__main__":
    main()
