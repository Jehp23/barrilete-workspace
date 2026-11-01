# barrilete-workspace

Workspace personal de agentes sobre [Barrilete Kit](https://github.com/lautioliver/barrilete-kit), manejado desde la terminal.
Los agentes corren en la sesión tmux `agents`; Sketchybar muestra su estado (rol, modelo, issue) y los checkpoints.

```
bk plan "<idea>"   bk run <issue>   bk review <pr>   bk orchestrate
bk ls              bk go <ventana>  bk stop <ventana>
bk roles           bk mode [work|chill]   bk song [estación]   bk theme [day|night|auto]
```

- `bk run` reusa el kit: `routing.py` elige el rol y `prepare.sh --worktree` asigna el issue y crea el worktree.
- `roles.yml` dice qué provider/modelo corre cada rol; un proyecto lo pisa con `.barrilete/roles.yml`.
- `--dry-run` en cualquier comando de agentes muestra qué haría sin lanzar nada.
- Provider `codex`: preparado pero sin probar, y sin las barandas de `guardrails.py` (son hooks de Claude Code).

- `bk song` reproduce radios de techno/house en segundo plano con mpv (`bk song help`); un género que no está en la lista se busca en radio-browser.info.
  `bk song ui` abre una pantalla en vivo con el gráfico del sonido (niveles reales de cada canal) y control con teclas; al salir, la música sigue.

Instalación: `ln -sf ~/barrilete-workspace/bin/bk ~/.local/bin/bk` y `brew install tmux mpv`.

## Retroalimentación (`bk learn`)
`lib/learn.py` lee los transcripts y registra desvíos en el vault de Obsidian (`~/Documents/Obsidian Vault/agents`):
barandas, verificaciones fallidas, contratos de subagentes (patrones automáticos) y tus correcciones, rechazos
e interrupciones (para leer en el resumen del día). Un patrón repetido ≥3 veces en 14 días propone una lección;
las que marcás `accepted` con su regla pasan a `agents/INDEX.md`, que Claude Code importa desde `~/.claude/CLAUDE.md`.
`bk lessons` lista las que esperan revisión; la barra las muestra como checkpoint (󰌵).

## Dotfiles
- `dotfiles/tmux.conf` → `~/.config/tmux/tmux.conf`
- `dotfiles/ghostty/bk-day`: tema violeta pastel (modo day). `bk theme` apunta la línea `theme` de la config de Ghostty
  a ese archivo (day), a `Shades Of Purple` (night) o a los dos según macOS (auto), y recarga Ghostty con SIGUSR2.
- `dotfiles/sketchybar/` → `~/.config/sketchybar` (centro de control: agentes, checkpoints, tokens, GitHub, modos work/chill)

Ambos son enlaces simbólicos: se editan acá y quedan versionados.
