# Setup — barrilete-workspace

> Cómo levantar el proyecto en local: variables de entorno, servicios, troubleshooting.

## Instalar

```bash
git clone https://github.com/lautioliver/barrilete-workspace.git ~/barrilete-workspace
ln -sf ~/barrilete-workspace/bin/bk ~/.local/bin/bk
brew install tmux mpv
git -C ~/barrilete-workspace config core.hooksPath githooks   # protege main (solo entra con bk land)
```

Además hacen falta `python3` (solo biblioteca estándar), `git`, `gh` autenticado (`gh auth status`) para issues y PRs, `claude` (Claude Code) y, para algunos tests de Herdr, `node`. Para el backend de Herdr: la app [Herdr](https://herdr.dev) (`herdr-app` y `hc`) y `bk backend herdr`. Los hooks de Claude Code (`hooks/agent_state.sh`, `lib/context_hook.py`) se registran a mano en `~/.claude/settings.json`: el [README](../../README.md) dice en qué eventos.

Los comandos de agentes (`bk run`, `review`, `fix`…) se corren dentro de un proyecto Barrilete (uno que tenga `scripts/agents/guardrails.py`).

## Trabajar en el repo

```bash
git worktree add -b <rama> ../barrilete-workspace-wt/<rama> main
cd ../barrilete-workspace-wt/<rama>
bash lib/checks.sh          # todo: sintaxis de bash, py_compile, check_test_fns y tests/test_*.sh
bash tests/test_herdr.sh    # un test solo
bk land --wait              # con todo commiteado: entra a main
```

`lib/checks.sh` corre los tests con `BK_BACKEND=tmux` y sin `HC_TERMINAL_ID`: los que prueban Herdr usan un `herdr-app` y un `hc` falsos (`tests/herdr_fake.py`, `tests/herdr_stub`).

## Variables de entorno

| Variable | Qué hace |
|---|---|
| `BK_BACKEND` | `tmux` o `herdr` para un comando (si no, `~/.config/bk/backend`; sin nada, tmux) |
| `BK_SESSION` | la sesión tmux de los agentes (por defecto `agents`) |
| `BK_MAIN_OK=1` | salida de emergencia del hook que protege `main` |
| `BK_NAMES_OFF=1` | apaga los nombres vivos de los chats en Herdr |
| `BK_NO_SWEEP=1` | apaga el borrado solo de las ramas que ya entraron |
| `BK_BITACORA_HTML` | el HTML de estado que actualiza `bk bitacora` |

## Problemas conocidos

- `bk land --help` no muestra ayuda: corre el land. El uso está en `bin/bk`.
- Con `TMUX` definida, `TMUX_TMPDIR` no aísla: un `tmux kill-server` de prueba tira el tmux real. Usá `-L`/`-S`.
- `lib/herdr_install.py <herdr/ del repo> <carpeta de Herdr>` pisa los mods de esa carpeta: para probar, pasale una carpeta temporal, no `~/.config/herdr-app`.
