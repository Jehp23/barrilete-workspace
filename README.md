# barrilete-workspace

Workspace personal de agentes sobre [Barrilete Kit](https://github.com/lautioliver/barrilete-kit), manejado desde la terminal.
Los agentes corren en la sesión tmux `agents`; Sketchybar muestra su estado (rol, modelo, issue) y los checkpoints.

```
bk plan "<idea>"   bk run <issue>   bk review <pr>   bk orchestrate
bk ls              bk go <ventana>  bk stop <ventana>
bk roles           bk mode [work|chill]
```

- `bk run` reusa el kit: `routing.py` elige el rol y `prepare.sh --worktree` asigna el issue y crea el worktree.
- `roles.yml` dice qué provider/modelo corre cada rol; un proyecto lo pisa con `.barrilete/roles.yml`.
- `--dry-run` en cualquier comando de agentes muestra qué haría sin lanzar nada.
- Provider `codex`: preparado pero sin probar, y sin las barandas de `guardrails.py` (son hooks de Claude Code).

Instalación: `ln -sf ~/barrilete-workspace/bin/bk ~/.local/bin/bk` y `brew install tmux`.
