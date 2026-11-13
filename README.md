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
  **El chat nuevo se abre solo**: cuando el agente guarda el resumen, el hook (`lib/context_hook.py`, en el Write de
  ese archivo) corre `bk handoff --listo <sesión>`. Si lo pediste vos con `bk handoff`, bk abre el chat nuevo en el
  momento (`bk chat --desde`); si lo pidió el aviso rojo, no abre nada solo: con Herdr sale un aviso «Resumen listo»
  que lo abre al hacerle clic (`bk handoff --seguir`, el resumen listo más nuevo; dura diez minutos), y con tmux queda
  la marca `↪` como siempre. Una sola vez por pedido, aunque el agente guarde el archivo de nuevo; con tmux, fuera de
  tmux no abre nada. El `.json` anota quién lo pidió (`via`).

## Herdr en vez de tmux (`bk backend herdr`)
`bk backend herdr` hace que los chats y los agentes vivan en la app [Herdr](https://herdr.dev) y no en tmux
(`bk backend tmux` vuelve; queda en `~/.config/bk/backend`, y `BK_BACKEND` manda para un comando). No hay riel,
tira ni footer: la lista de espacios y la de agentes de Herdr muestran lo mismo.

- **Un espacio por proyecto**: `bk` en la carpeta del proyecto abre (o muestra) el espacio `<proyecto>` con su
  chat en la pestaña `chat`. `bk chat` suma otra pestaña (`chat-2`…), `bk chat --rama X` abre el espacio
  `<proyecto>-<x>` en su worktree y `bk chat --suelto` va al espacio `chats`.
- **Una pestaña por agente**: `bk run`, `fix`, `review`, `plan` y `orchestrate` lanzan al agente en una pestaña
  del espacio de su proyecto (`i42`, `pr57`…) sin sacarte de la que estás mirando. Herdr muestra su estado.
- `bk ls`, `go`, `peek`, `say`, `stop`, `handoff`, `name`, `open` y `term` andan igual; `bk watch <agente>` muestra
  su pestaña. Lo que es del workspace de tmux (`rail`, `sidebar`, `dash`, `new`, `snapshot`, `restore`) avisa y no
  corre: herdr-core ya mantiene vivas las terminales. `bk account use` sigue siendo de tmux; `--account X` anda.
- **Los mismos atajos que en tmux**: `bk backend herdr` instala en Herdr los mods `bk-*` (`herdr/mods/bk`) y suma a su
  `keys.json` las teclas de `dotfiles/tmux.conf` (`herdr/keys.json`), sin pisar las que ya hacen otra cosa y con
  respaldo en `keys.json.antes-de-bk`. `alt+k` paleta, `alt+g` cambios, `alt+s` sesiones, `alt+u` stats, `alt+n`
  nuevo y `alt+a` agentes (`bk ls` y `bk peek`) abren en un popup que se cierra al salir (la misma tecla también lo
  cierra); `alt+x` muestra y esconde la terminal rápida del espacio; `alt+1…9` va al espacio N (su posición en la
  lista), `alt+shift+1…9` a la pestaña del agente N del espacio y `alt+q` vuelve al chat; `alt+,` abre los ajustes
  de Herdr. Una tecla no puede correr un programa ni pasar argumentos: abre un mod con el nombre del comando
  (`mod.open:bk-palette`), que hace lo suyo y se cierra; todos son el mismo archivo. Nada queda abierto (una ventana
  del mod siempre a la escucha tapaba los clics de toda la app). Herdr deja de actualizar un `keys.json` editado.
  Dos mods más, sin tecla: `bk-aviso` (muestra un aviso que pide bk; solo un mod puede avisar) y `bk-seguir` (el clic
  del aviso «Resumen listo»). Falta: `alt+0` (espacio anterior) no tiene equivalente, y en `bk s` saltar a una sesión o retomarla usa tmux.
- **El layout `bk`**: `bk backend herdr` también instala dos paneles dibujados por Herdr (no terminales) y un layout
  que los muestra, copia del `main` de Herdr: en la barra, las tareas activas del kit (`herdr/mods/tareas`, de
  `bk tasks --json`: por aprobar, te esperan, trabajando; clic va a la pestaña del agente) y, a la derecha, lo que
  mostraba el riel (`herdr/mods/lado`, de `bk _side`: proyecto, rama, perfil de roles, uso de hoy, agentes del
  espacio y lo que quedó sin commitear en el proyecto y sus worktrees). Instalar no cambia el layout que ves:
  `herdr-app do layout.switch --name bk` lo muestra y `--name main` vuelve. Si retocás `layouts/bk.json`, queda:
  instalar de nuevo solo repone los bloques que falten. Tests: `tests/test_side.sh` y `tests/test_herdr.sh`.
- Cómo está hecho (`lib/herdr.sh`): `herdr-app` crea espacios y pestañas y `hc` (herdr-core) lee, escribe y cierra
  las terminales. Lo que en tmux era el nombre de la ventana y sus `@opciones` son etiquetas de la terminal
  (`bk.kind`, `bk.win`, `bk.project`, `bk.role`, `bk.ref`), y el "pane" es su dirección (`t7`), que el hook de
  estado toma de `HC_TERMINAL_ID`. Tests: `tests/test_herdr.sh`, con un Herdr falso (`tests/herdr_fake.py`).

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

### Estética Lavanda

`bk backend herdr` instala también `bk-lavanda`. Activarlo:
`herdr-app do layout.switch --name bk-lavanda`.
Fondos ciruela, acentos violeta pastel, tipografía JetBrains Mono y tarjetas redondeadas:
proyectos, agentes en vivo y tareas a la izquierda; terminal en el centro;
contexto, GitHub y cambios a la derecha. Ámbar indica atención, menta éxito y coral errores.
El perfil muestra cada rol en su propia fila. El panel nativo de agentes muestra todos los espacios, títulos, estados en vivo y actividad animada.

GitHub muestra hasta cuatro PRs abiertos con enlaces al navegador, borrador,
revisión y CI. Requiere `gh` autenticado (`gh auth status`) y un remoto GitHub;
se actualiza cada minuto y al cambiar de carpeta, sin bloquear el estado local.
Si no puede consultar GitHub, muestra el error sin ocultar los cambios de Git.
El layout vive en `herdr/layouts/bk-lavanda.json`; se instala una sola vez para
conservar ajustes locales. Para volver: `herdr-app do layout.switch --name bk`.

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
