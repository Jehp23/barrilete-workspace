---
skill: implement-issue
issue: 23
pr: 28
area: none
paths: docs/decisions/ADR-001-lista-de-espacios-entre-maquinas.md, docs/decisions/README.md, docs/README.md, docs/llms.txt, docs/reference/glossary.md
date: 2026-11-21
skill_sha: 6178344b6aed453e550d10ea5943573013ff79f4
model: opus
role: session
---
**Desvíos:** no corrí `prepare.sh`: el issue vive en el repo upstream (lautioliver) y el clon tiene `origin` = fork (Jehp23), así que habría buscado el issue y la rama en el repo equivocado; creé el worktree a mano desde `upstream/main`. No me pude asignar el issue ni poner labels (sin permiso de triage). Sin commit en rojo: solo docs (`sin tests:` en el PR).
**Decisiones no cubiertas:** `verify.py` compara contra `origin/main`, que en un fork es un main viejo: corrió los 21 checks sobre 224 archivos y marcó fallas de main. Tuve que correr los mismos checks en un checkout limpio de `upstream/main` para probar que eran previas. El CI no corrió en el PR (viene de un fork). El ADR agregó dos detalles que la épica no decía: desempate por host y la conversión alias→host al leer; el alias de `hc machine` ≠ hostname salió al escribir el ADR.
**Lo que encontró la revisión:** nada (`/code-review` low, diff solo de docs). `check-docs.py` sí encontró una ruta al glosario que todavía no existe en main (espacios.js, de #8).
**Propuesta:** que `prepare.sh` y `verify.py` detecten un remoto `upstream` (o tomen la base de una variable) para trabajar desde un fork.
