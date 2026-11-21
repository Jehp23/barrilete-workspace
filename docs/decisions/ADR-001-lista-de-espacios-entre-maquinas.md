# ADR-001 — La lista de espacios compartida entre máquinas

## Estado

Propuesto

Origen: épica [#22](https://github.com/lautioliver/barrilete-workspace/issues/22) (decisiones 2 y 3, tomadas el 2026-11-21), issue [#23](https://github.com/lautioliver/barrilete-workspace/issues/23).

## Contexto

- Herdr ya conecta varias máquinas (`hc machine`): los espacios de otra máquina llegan con `.machine` y `hc exec --on <máquina>` corre un comando allá.
- La lista de espacios de la barra (el orden, las carpetas, el color y la imagen de cada cosa; PR #8, rama `espacios-carpetas`) vive en `shared("bk.espacios")` de Herdr (`herdr/mods/agentes/espacios.js`). Ese `shared` es de cada máquina: con dos máquinas hay dos listas, y lo que acomodás en una no aparece en la otra.
- En #8 la clave de un espacio es su nombre, o `nombre@máquina` si corre en otra (`keyOf`). Esa máquina es el **nombre que le dio Herdr en esta máquina** (`hc machine ls`: `name`, por ejemplo `mac-luciano`), un alias local: la otra máquina no se llama así a sí misma (su `host` es `macbook-pro-de-luciano`) y para ella el espacio es local, sin `@`. La misma fila tiene una clave distinta en cada máquina.
- No hay servidor propio ni base de datos: el estado de bk vive en archivos y en el `shared` de Herdr.

Hay que decidir dónde vive la lista cuando la ven varias máquinas, cómo se resuelven dos cambios a la vez y con qué clave se reconoce un espacio en todas.

## Decisión

1. **Cada máquina guarda su copia completa de la lista y, al cambiarla, la empuja a las otras.** La copia sigue en `shared("bk.espacios")` de cada máquina. Después de cada cambio, la máquina que cambió manda el documento entero a cada máquina conectada con `hc exec --on <máquina> bk _espacios put` (el documento por stdin). Una máquina desconectada no frena: el envío tiene tope de tiempo y reintentos acotados (los mismos de #8), y esa máquina se pone al día cuando vuelve (regla 3).
2. **Gana la copia más nueva, por la marca de tiempo del documento entero.** El documento lleva `ts` (milisegundos desde 1970, del último cambio) y `host` (el hostname de la máquina que lo cambió). `bk _espacios put` aplica lo que recibe solo si es más nuevo que lo que tiene; si el `ts` empata, gana el `host` mayor en orden alfabético, así todas eligen la misma. No se mezclan dos copias campo por campo: si dos máquinas cambian casi a la vez, se pierde el cambio de la más vieja.
3. **Al abrir la barra o reconectar una máquina, cada una trae las copias de las otras y se queda con la más nueva.** Con `hc exec --on <máquina> bk _espacios get`, con el mismo tope de tiempo. Si la propia es la más nueva, la empuja (regla 1).
4. **La clave de un espacio entre máquinas es `<nombre>@<hostname de la máquina donde corre>`, también para los locales.** El hostname es el que la máquina dice de sí misma (`hostname`) y el que Herdr muestra como `host` de una máquina remota, así que es el mismo en todas; el nombre que Herdr le da a una máquina (`name`) no se usa en la clave porque es un alias de cada lado. El mismo proyecto abierto en dos máquinas son dos filas. Los repetidos de un nombre en la misma máquina siguen como en #8 (`nombre#2@hostname`).
5. **Una fila vieja sin máquina se toma como local.** Al leer una lista guardada antes de esta regla, la fila `nombre` pasa a `nombre@<hostname propio>` (y `nombre@<alias>` pasa a `nombre@<host de ese alias>` si la máquina está conectada). No hay migración aparte: es la lectura (`clean`) la que convierte.

## Alternativas descartadas

- **Una máquina principal que guarda la lista y las otras le preguntan.** Si esa máquina se apaga o se desconecta, las otras se quedan sin lista o sin poder cambiarla, y hay que elegir y mover la principal a mano. Con copias en cada una, todas siguen andando solas.
- **La lista en un archivo de git (en un repo o en una rama de datos).** Cada arrastre de un espacio sería un commit y un push, con su demora y sus choques; y depende de la red a GitHub para algo que pasa entre dos máquinas conectadas por Herdr.
- **Mezclar dos copias campo por campo (CRDT, o una marca por fila).** Evitaría perder un cambio cuando dos máquinas editan a la vez, pero la lista la cambia una persona por vez y el costo (marcas por fila, borrados que hay que recordar, carpetas que se mueven) no se justifica hoy. Si el pisado se vuelve un problema real, se reemplaza este ADR.
- **La clave con el nombre de Herdr de la máquina.** Es un alias distinto en cada máquina (Contexto): la misma fila tendría dos claves.

## Consecuencias

- Se gana: la misma lista en todas las máquinas, sin servidor ni máquina principal; cada una sigue andando si las otras se caen.
- Cuesta: dos cambios casi simultáneos en máquinas distintas, uno se pierde (el más viejo). Un reloj atrasado en una máquina puede hacer perder sus cambios frente a una copia vieja de otra: se acepta (los relojes se sincronizan solos por red).
- Las copias tienen que entenderse entre sí: hace falta la misma versión de bk en cada máquina (`bk machines sync`, #24).
- Código: la clave con hostname y la lectura de las filas viejas, en #26 (sobre `espacios-carpetas`, #8: cambia `keyOf`, que hoy usa el alias); `bk _espacios get|put`, `ts`/`host` y el empuje al cambiar y al reconectar, en #27.
