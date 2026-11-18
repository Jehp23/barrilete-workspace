---
name: git-workflow
description: Flujo de ramas, commits y PRs de este repo. Usar siempre que crees ramas, commits, pushes o pull requests.
---

# Git workflow — barrilete-workspace

Detalle en `docs/github-naming-convention.md`. Resumen obligatorio en `AGENTS.md`.

## Ramas

- Única rama permanente `main`, protegida: nadie commitea ni edita su checkout. Creá la rama en su worktree (`git worktree add -b <rama> ../barrilete-workspace-wt/<rama> main`). Lo propio de la sesión entra con `bk land --wait`, sin PR (`README.md`, *main protegido*); el trabajo de un issue, con un PR a `main`.
- Nombre: `claude/<n°issue>-<descripcion>` (agente) o `<tipo>/<n°issue>-<descripcion>` (persona). Solo minúsculas, números y guiones.
- Si no hay issue, preguntá si abrir uno (skill `create-issue`) antes de inventar el número.

## Commits

- `<tipo>(<scope>): <descripcion>` — imperativo, minúscula, sin punto, ≤ 72 caracteres. Tipos en inglés, descripción en español.
- Un commit = un cambio lógico. Si toca varios scopes, sin scope o dividir.
- Rompe compatibilidad: `feat(api)!: …` + footer `BREAKING CHANGE: …`.

## Pull requests

1. Nunca commit ni push directo a `main`. Lo propio de una sesión entra con `bk land --wait`; el trabajo de un issue, por PR (esta sección).
2. Título con el mismo formato que un commit.
3. Cuerpo con `.github/pull_request_template.md`: Qué cambia / Por qué / Lógica de negocio afectada / Cómo probarlo / `Closes #n`.
4. Labels: exactamente un `type:` (las ramas `claude/` no lo reciben automático: ponelo vos), 1–2 `area:`, ningún `priority:`. Solo labels de `.github/labels.yml`.
5. Si cambia una regla de un ADR, auditoría o plan: label `business-logic` y explicarlo en "Lógica de negocio afectada".

```bash
gh pr create --base main --title "fix(api): …" --body-file <archivo> --label "type:bug" --label "area:api"
```
