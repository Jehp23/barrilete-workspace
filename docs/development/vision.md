# Visión — barrilete-workspace

> Qué es, qué hay y qué viene. Narrativa, no especificación.

## Qué es

Un workspace personal para trabajar con muchos agentes de Claude Code (y Codex) a la vez sobre los proyectos de [Barrilete Kit](https://github.com/lautioliver/barrilete-kit), sin perderles el rastro. Todo pasa por un comando, `bk`: lanzar un agente sobre un issue (`bk run`), revisar o corregir un PR (`bk review`, `bk fix`), planear y orquestar, ver quién trabaja y quién te espera, hablarle a un agente sin entrar a su ventana y seguir un chat largo en uno nuevo con un resumen.

El kit pone las reglas y las skills de los agentes (`implement-issue`, `review-pr`, `orchestrate`…); `bk` pone el lugar donde corren y la vista de todos juntos.

## Qué hay

- Dos lugares donde viven los chats y los agentes: el workspace de tmux (chat, riel y tira, una sesión por proyecto) y la app Herdr (un espacio por proyecto, una pestaña por agente, paneles y teclas `alt+…`). Se elige con `bk backend`.
- Un estado común para todas las vistas: el hook `hooks/agent_state.sh` anota qué hace cada sesión y de ahí leen `bk ls`, la tira, el riel, `bk monitor`, `bk s` y los paneles de Herdr, con los mismos glifos (`lib/gentle.py`).
- Tareas con estado y eventos para cada agente (ADR-005 del kit) y un cierre declarado (`bk done`).
- Lo que te espera en un solo lugar: `bk checkpoints`, `bk monitor` y, en Herdr, `alt+e`.
- Trabajo en paralelo sobre el propio repo: `main` protegido, una rama y un worktree por sesión y `bk land --wait` para entrar.
- Herramientas alrededor: cuentas de Claude por sesión (`bk account`), perfiles de modelos (`bk profile`), trabajos puntuales a otros modelos (`bk ask`), uso y costo (`bk tokens`, `bk stats`), retroalimentación de desvíos (`bk learn`) y radio (`bk song`).

## Qué viene

Pendiente: lo decide la persona. Lo que el repo muestra hoy: el trabajo reciente va casi todo a Herdr (`feat(herdr)`/`fix(herdr)` en el historial: épicas, panel TODO, la franja de arriba) y el workspace de tmux se mantiene. Ver [roadmap](roadmap.md).
