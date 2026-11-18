# Contextos — barrilete-workspace

> Los contextos delimitados del sistema: cada uno con su responsabilidad y sus palabras propias. Dónde vive el código de cada uno se declara en la sección `contexts` de [`agents-map.json`](../agents-map.json).

Pendiente: lo decide la persona. Todavía no hay contextos declarados (`contexts` está vacío en el mapa), así que no hay dependencias que chequear. Declararlos fija qué parte del código puede usar a cuál, y una dependencia nueva pasa a necesitar un ADR (ADR-003 del kit).

Una división posible, según cómo está agrupado el código hoy ([módulos](modules.md)), para que la persona decida:

- **agentes**: lanzar, estado y tareas (`bin/bk`, `hooks/agent_state.sh`, `lib/agents.py`, `lib/tasks.py`).
- **herdr**: el backend y los paneles de Herdr (`lib/herdr.sh`, `lib/herdr_*.py`, `herdr/`); usaría a agentes.
- **land**: entrar a `main` (`lib/land.py`, `githooks/`, `lib/checks.sh`).
- **retroalimentación**: desvíos, lecciones y métricas (`lib/learn.py`, `lib/deviations.py`, `lib/effect.py`, `lib/metrics.py`).

## Cómo se relacionan

Sin contextos declarados no hay relaciones que contar acá. Hoy todas las vistas leen el mismo estado (los archivos que escribe `hooks/agent_state.sh`, a través de `lib/agents.py`) y los mods de Herdr hablan con el resto solo por `bk _hub` y `bk _do`.
