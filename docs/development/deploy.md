# Deploy — barrilete-workspace

> Entornos, dónde corre cada pieza y cómo se publica.

No hay servidores ni entornos: `bk` corre en la máquina de la persona (macOS).

## Dónde corre cada pieza

- **`bk`**: `~/.local/bin/bk` es un enlace a `~/barrilete-workspace/bin/bk`, el checkout de `main`. Lo que entra a `main` con `bk land --wait` es lo que corre desde ese momento; un worktree no cambia el `bk` en uso.
- **Hooks de Claude Code**: registrados en `~/.claude/settings.json` y apuntando al checkout de `main` (`hooks/agent_state.sh`, `lib/context_hook.py`). `lib/tmux_guard.py` corre desde una copia en `~/.claude/hooks/tmux_guard.py`: un cambio en el repo no llega hasta copiarlo.
- **Herdr**: `bk backend herdr` (con `lib/herdr_install.py`) copia lo de `herdr/` a `~/.config/herdr-app`. Hay que correrlo de nuevo para que un cambio de mods, teclas, temas o layout llegue a la app (ver *Herdr en vez de tmux* en el [README](../../README.md)).
- **tmux y Ghostty**: `~/.config/tmux/tmux.conf` es un enlace a `dotfiles/tmux.conf`; `bk theme` apunta la config de Ghostty a `dotfiles/ghostty/bk-day` o a un tema de Ghostty.
- **Hook de git**: `git config core.hooksPath githooks` en el checkout, para que `githooks/reference-transaction` proteja `main`.

## Cómo se publica

Entrar a `main` es `bk land --wait` desde el worktree de la rama (espera su turno, rebasa, corre `lib/checks.sh` y hace el fast-forward). `bk land` no pushea; el remoto es `respaldo` (GitHub `lautioliver/barrilete-workspace`). Pendiente: lo decide la persona (cuándo y cómo se pushea `main` a `respaldo`).

CI en GitHub (`.github/workflows/docs.yml`, del kit): valida los docs y corre los tests de `scripts/agents/` en cada PR y en cada push a `main`. No corre `lib/checks.sh`.
