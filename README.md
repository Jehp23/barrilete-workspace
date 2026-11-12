# barrilete-workspace

Workspace personal de agentes sobre [Barrilete Kit](https://github.com/lautioliver/barrilete-kit), manejado desde la terminal.
Los agentes corren en la sesión tmux `agents`; Sketchybar muestra su estado (rol, modelo, issue) y lo que te espera (`bk checkpoints`).

```
bk                 (workspace)      bk s             (sesiones)
bk plan "<idea>"   bk run <issue>   bk review <pr>   bk fix <pr> "…"   bk orchestrate
bk ls              bk go <ventana>  bk stop <ventana>  bk clean [--yes]
bk peek [ventana]  bk say <ventana> "…"   bk watch [ventana|--all]
bk monitor         bk checkpoints   bk tasks         bk done <resultado>   bk approve <tarea>
bk account         bk account use <cuenta> [--relaunch]   bk run … --account <cuenta>
bk roles           bk mode [work|chill]   bk song [estación]   bk theme [day|night|auto]
```

## Workspace (`bk`)
Uno por proyecto: `bk` en la carpeta de un proyecto abre (o retoma) la sesión tmux `bk-<proyecto>`;
`bk open <proyecto|ruta>` lo abre en una ventana nueva de Ghostty, en el escritorio donde estás.
Así cada escritorio de macOS tiene su proyecto. El riel, el footer y `alt+a` muestran solo los agentes,
cambios y tokens de ese proyecto (el repo y sus worktrees `<repo>-wt/*`); los agentes
siguen todos en la sesión `agents`. `bk open` sin argumento lista los workspaces abiertos.

```
┌──────────────────────────┬──────────────────┐
│                          │ agentes en vivo  │
│  chat · orquestador      │ (bk watch --all) │
│  (claude)                ├──────────────────┤
│                          │ radio            │
├──────────────────────────┴──────────────────┤
│ agentes · tokens (bk dash: dos tablas)      │
└─────────────────────────────────────────────┘
```

- **Chat**: un `claude` donde hablás con los agentes (mensajes entre sesiones) y les respondés con `bk say`.
- **Agentes en vivo**: un panel que se reparte entre los agentes que trabajan (encabezado con rol/modelo/estado
  y lo último que dijeron); los terminados van abajo en una línea. Solo lectura.
- **Tablas**: agentes ordenados por urgencia y uso del día por modelo (`lib/dash.py`).
- Las proporciones se reacomodan solas al conectarse o redimensionar (hooks de tmux → `bk _layout`).
- **Número fijo**: cada workspace toma al crearse el número libre más bajo (`@bk_id`) y lo conserva aunque se
  cierren otros; la tira, el header, `bk ls` y `alt+1…9` usan ese número, cada uno con su color.
  En la tira, los workspaces del mismo proyecto (`BK_PROJECT`) quedan juntos y una línea a la izquierda los une
  (`╭ │ ╰`); cada proyecto va donde está su número más bajo y el tooltip dice cuál es.
- **Quién lanzó a quién**: debajo de cada ventana de la tira (`└`) van sus subagentes vivos como `5.3 reviewer`
  (el 3.º que lanzó el workspace 5, contando los que ya terminaron, así el número no cambia; la descripción y el id
  `agent-…`, en el tooltip) y los agentes bk que lanzó, por su ventana
  (`f268`). Abajo de la línea, cada agente bk va por el nombre de su ventana y con `←3` (lo lanzó el workspace 3),
  `←f268` (otro agente) o `←?` (esa ventana ya se cerró). `bk` lo anota al lanzar (`@bk_parent` de la ventana:
  la sesión, no su número, que se reusa). Los agentes lanzados antes de esto no lo tienen. La tira mide 14
  columnas (`SIDE_W` en `lib/layout.conf`, con las demás proporciones del workspace: el riel al 34 %, mínimo 46).
- **Un solo estilo**: los colores de todas las vistas salen de la paleta de `lib/gentle.py` (día y noche, la que
  cambia `bk theme`) y el glifo, el texto y el color de cada estado, de `gentle.STATES`: `⠋` trabajando · `!` te
  espera o pide permiso · `?` te pregunta · `⚠` ¿trabado? · `✓` listo · `○` libre. La tira, el riel, el monitor,
  `bk ls` y los overlays dicen lo mismo.
- **Contexto de cada sesión**: cada llamada vuelve a leer todo el contexto, así que una sesión larga sale cara.
  La tira marca `▪` (ámbar desde 200k, rojo desde 400k; el número en el tooltip), el riel lo muestra por agente y
  para este chat, `bk monitor` en la columna CTX, y `bk land` sugiere `/clear` o un chat nuevo si el chat que lo
  corrió pasa los 200k. Sale del último turno del transcript (`usage.context_of`), sin llamar a ningún modelo.
  Al agente se lo dice un hook de Claude Code (`lib/context_hook.py`, en `UserPromptSubmit` y `PostToolUse`): un mensaje
  en su contexto al cruzar 200k (recomendar `/clear` o un chat nuevo), al cruzar 400k (cerrar en un punto estable y dejar
  el resumen para seguir, abajo; un agente de bk termina con su `bk done`) y después cada +100k. No repite (estado en `~/.cache/bk/context_hook/`),
  no corre en subagentes y ante cualquier error no dice nada. Se instala en `~/.claude/settings.json`, en `hooks`:
  `{"type": "command", "command": "python3 ~/barrilete-workspace/lib/context_hook.py", "timeout": 5}` en
  `UserPromptSubmit` y en `PostToolUse` (con `"matcher": "*"`).
- **Seguir en un chat nuevo (handoff)**: el resumen tiene siempre el mismo formato (`lib/handoff.py`): de dónde viene
  (sesión, workspace y número, rama, cuenta: lo completa bk, no el agente), hecho, falta (empezando por el primer paso),
  te espera a vos, no tocar y archivos y comandos; como mucho 40 líneas. Queda en
  `~/.local/state/bk/handoffs/<session_id>.md`. Lo pide el aviso rojo, o vos: `bk handoff [N]` se lo pide al chat del
  workspace N (desde el mismo chat, `! bk handoff` imprime el pedido). `bk chat --desde N` (o «↪ Seguir desde ws N» en
  `alt+n`) abre un workspace más en la misma carpeta y con la misma cuenta, con el resumen como primer mensaje (va como
  argumento de `claude`, sin `send-keys`), lo borra y te pregunta si cierra el viejo. `bk handoff --listos`: los que hay. Los tres están también en la paleta (`alt+k`). Mientras espera, la tira
  marca ese workspace con `↪` (en lugar del `▪` de contexto) y `bk s` marca su fila con `↪`, también en recientes.

## Sesiones (`bk s` · `C-a s`)
Selector estilo Orca (`lib/sessions.py`): arriba las sesiones abiertas (Enter salta a su pane; un agente que
terminó se revive con `claude --resume` en el mismo pane), abajo las recientes de todas las carpetas
(Enter las retoma en una ventana nueva de `agents`, en su carpeta). `/` busca, `x` cierra un agente o un workspace.
Una sesión abierta fuera de tmux aparece como `afuera` y no se duplica.
Cada chat de un workspace muestra su número fijo con su color (`ws 3`, el mismo de la tira y `alt+N`), así sabés cuál
es. `x` sobre un workspace lo cierra entero (chat, riel y tira) después de confirmar con `y`; la conversación queda en
recientes. El workspace donde estás no se cierra desde ahí. Por comando: `tmux kill-session -t '=bk-<nombre>'` (con comillas
en zsh, que expande el `=`).

## Hablar con los agentes sin entrar
- `bk peek [ventana]`: la pantalla de un agente (sin ventana: las últimas líneas de todos).
- `bk say <ventana> "…"`: escribe en su ventana como si fuera tu teclado, así que vale como tu respuesta
  (aprobar un plan, publicar una review). Pensado para que lo corras vos (`! bk say …` desde el chat):
  un agente no aprueba en tu nombre.
- `bk watch [ventana]`: espejo en vivo de un agente; sin ventana toma el próximo libre.
- `bk fix <pr> "instrucción"`: implementer sobre la rama de un PR abierto, reusando su worktree.

- `bk run` reusa el kit: `routing.py` elige el rol y `prepare.sh --worktree` asigna el issue y crea el worktree.
- `roles.yml` dice qué provider/modelo corre cada rol; un proyecto lo pisa con `.barrilete/roles.yml`.
- `--dry-run` en cualquier comando de agentes, y en `bk ws` y `bk chat` (también `--rama`, `--suelto` y `--desde`), muestra qué haría sin lanzar ni abrir nada.
- Provider `codex`: preparado pero sin probar. Las barandas y los eventos de las tareas le llegan por el `.codex/hooks.json`
  del proyecto (los trae el kit), pero no está verificado que Codex los dispare igual que Claude Code.

- `bk song` reproduce radios de techno/house en segundo plano con mpv (`bk song help`); un género que no está en la lista se busca en radio-browser.info.
  `bk song ui` abre una pantalla en vivo con el gráfico del sonido (niveles reales de cada canal) y control con teclas; al salir, la música sigue.

Instalación: `ln -sf ~/barrilete-workspace/bin/bk ~/.local/bin/bk` y `brew install tmux mpv`.

## Tareas (ADR-005 del kit)
Cada agente de `bk run`, `bk review` o `bk fix` trabaja sobre una tarea (`<issue>-<rol>`, `pr<n>-<rol>`) con estado y
eventos, en `~/.local/state/bk/tasks/<proyecto>/<id>/` (`task.json` y `events.jsonl`); el agente recibe la carpeta en
`BK_TASK_DIR` y los hooks del kit anotan inicio, espera, commits y PRs.
- Un segundo `bk run` sobre el mismo issue no lanza otro agente (con cualquiera de los dos implementers).
- `bk run` suelta el candado del worktree (`agent-lock` del kit) que tomó `prepare.sh` antes de lanzar al agente: el
  agente lo toma como su primer paso y `bk done` lo suelta. Si el candado es de otro agente vivo, `bk run` no lanza.
- El agente cierra con `bk done pr <n>` (o `blockers`, `dropped "…"`, `escalate "…"`); si termina sin cerrarla queda
  `incomplete`, y `bk stop` la deja `cancelled`.
- Su PR propone `pr<n>-reviewer`, que arranca solo con `bk approve`. Con `--orchestrated` (lo usa `/orchestrate`) no hay
  propuesta: el orquestador lanza al reviewer.
- `bk say` a un agente que trabaja se encola hasta que termine el turno (`--now` para ya).
- `bk tasks` las lista con su carpeta; `bk tasks prune --yes` borra las terminadas (nada se borra solo).

## main protegido (`bk land`)
Varias sesiones trabajan a la vez sobre este repo. Nadie edita el checkout de `main` ni commitea en `main`: cada sesión
trabaja en su rama y su worktree (`git worktree add -b <rama> ../barrilete-workspace-wt/<rama> main`) y entra con `bk land`.
- **Claims**: al editar un archivo en un worktree, el hook de Claude Code (`.claude/settings.json`) lo registra a nombre de
  la rama. Si otra rama que empezó antes también lo modifica, le avisa al agente que no corra los checks todavía.
- **Orden**: una rama espera a las ramas activas que empezaron antes que ella y comparten algún archivo. Es un solo
  orden por hora de inicio, así que no hay deadlock. Las ramas sin actividad en 3 h o sin worktree no bloquean.
- **`bk land --wait`**, desde el worktree con todo commiteado:
  1. espera su turno;
  2. con el mutex de `main` tomado, rebasa sobre `main`;
  3. corre `lib/checks.sh`, una sola vez;
  4. hace el fast-forward.
  Si choca, el choque queda en su worktree: `main` nunca queda a medias.
- **Qué devuelve `bk land`**: 0 entró · 3 en cola · 4 choque en el rebase · 5 checks en rojo · 6 no pudo hacer el fast-forward.
- **`bk claims`** muestra quién modifica qué y quién espera a quién; `bk release` suelta los claims de una rama.
- **El hook de git** (`githooks/reference-transaction`, con `git config core.hooksPath githooks`) rechaza cualquier
  cambio de `main` que no venga de `bk land`, aunque uses `--no-verify`, y no deja reescribirla. La salida de
  emergencia es `BK_MAIN_OK=1`.

## Cuentas (`bk account`, port de bk-shell#17)
Cada sesión de bk puede usar otra cuenta de Claude Code o de Codex, y pueden correr dos a la vez; las conversaciones son
las mismas (`/resume` y `alt+s` ven todas).
- `bk account new claude trabajo` crea la cuenta en `~/.local/state/bk/accounts/trabajo` y abre su login. Lo compartido
  (`projects/`, settings, `CLAUDE.md`, skills, hooks) es un symlink a `~/.claude`; las credenciales son propias.
- `bk account use trabajo` la pone en esta sesión: los agentes y chats que lances desde acá corren con ella
  (`--relaunch`: también el chat principal, retomando su conversación). `bk account use default` vuelve a la de siempre.
- `bk run … --account X` solo para un lanzamiento. El riel muestra en Status el mail de la cuenta de la sesión,
  también el de la default. Es la que eligió la sesión: con `bk account use` sin `--relaunch`, el chat que ya estaba
  abierto sigue con la anterior hasta relanzarlo.
- `bk account login <cuenta>` rehace el login de una cuenta; `bk account login default` el de la de siempre (`~/.claude`),
  aunque esta sesión use otra. Si dos cuentas muestran el mismo email en `bk account`, en la práctica son una sola.
- `bk restore` retoma cada chat y agente con su cuenta (si la cuenta ya no existe, con la default y avisa).

## Lo que te espera (`bk monitor` · `bk checkpoints`)
- `bk monitor`: pantalla para el otro monitor. Arriba *Te esperan* (preguntas, permisos y checkpoints, con el comando
  para contestar); después agentes y chats en tablas, las tareas, los desvíos en vivo agrupados (los graves suenan) y el
  costo de hoy. La memoria libre va en el encabezado.
- `bk checkpoints` (`--json`): planes por aprobar, reviewers propuestos, PRs para revisar o mergear y lecciones, cada uno
  con su comando. Es la misma lista que *Te esperan* y el popup de la barra; ya no está en el riel.

## Retroalimentación (`bk learn`)
`lib/learn.py` lee los transcripts y registra desvíos en el vault de Obsidian (`~/Documents/Obsidian Vault/agents`):
barandas, verificaciones fallidas, contratos de subagentes (patrones automáticos) y tus correcciones, rechazos
e interrupciones (para leer en el resumen del día). Un patrón repetido ≥3 veces en 14 días propone una lección;
las que marcás `accepted` con su regla pasan a `agents/INDEX.md`, que Claude Code importa desde `~/.claude/CLAUDE.md`.
`bk lessons` lista las que esperan revisión; la barra las muestra como checkpoint (󰌵).
`bk learn effect` mide si cada regla aceptada baja los hallazgos de review que dice evitar: hallazgos de su clase por
ronda (y qué parte del total son) en los PRs abiertos antes y después de aceptarla. Escribe `agents/efecto.md`; las
que dan *no baja* son para reescribir o retirar. Usa `accepted:` y `mide:` del frontmatter de la lección.

## Dotfiles
- `dotfiles/tmux.conf` → `~/.config/tmux/tmux.conf`
- `dotfiles/ghostty/bk-day`: tema violeta pastel (modo day). `bk theme` apunta la línea `theme` de la config de Ghostty
  a ese archivo (day), a `Shades Of Purple` (night) o a los dos según macOS (auto), y recarga Ghostty con SIGUSR2.
- `dotfiles/sketchybar/` → `~/.config/sketchybar` (centro de control: agentes, lo que te espera, tokens, GitHub, modos work/chill)

Ambos son enlaces simbólicos: se editan acá y quedan versionados.
