#!/usr/bin/env bash
# Proporciones del workspace: lib/layout.conf es la única fuente (bin/bk la carga, lib/gentle.py la lee).
# Con un tmux FALSO en el PATH que solo contesta y anota: nunca toca un tmux de verdad.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/tmp"
cat > "$TMP/bin/tmux" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$TMP/tmux.log"
case "\$1 \$*" in
  display-message*window_width*) echo "\${FAKE_W:-200}" ;;
  display-message*window_zoomed_flag*) echo 0 ;;
  list-panes*) printf '%%0 claude\n%%1 bk rail\n%%2 bk sidebar\n' ;;
esac
SH
chmod +x "$TMP/bin/tmux"

# Una copia del repo, para poder cambiar layout.conf sin tocar el real
COPY="$TMP/ws"; mkdir -p "$COPY"; cp -R "$ROOT/bin" "$ROOT/lib" "$COPY/"
conf() { printf 'SIDE_W=%s\nRAIL_PCT=%s\nRAIL_MIN=%s\nLAYOUT_CHAT=%s\nLAYOUT_RAIL=%s\n' "$@" > "$COPY/lib/layout.conf"; }
layout() {   # layout <ancho de ventana>: lo que `bk _layout` le pide a tmux
  : > "$TMP/tmux.log"
  FAKE_W="$1" PATH="$TMP/bin:$PATH" HOME="$TMP/home" TMPDIR="$TMP/tmp" TMUX= TMUX_PANE= bash "$COPY/bin/bk" _layout bk-t >/dev/null 2>&1
}
resize() { grep -E "resize-pane -t $1 " "$TMP/tmux.log" | grep -oE -- '-x [0-9]+' | head -1; }
zoom() { grep -cE "resize-pane -Z -t %0" "$TMP/tmux.log"; }

# Con el layout.conf del repo (el de verdad): la tira de 14 y el riel al 34 %
cp "$ROOT/lib/layout.conf" "$COPY/lib/layout.conf"
layout 200
check_eq "$(resize %1)" "-x 68" "riel: 34 % de 200 columnas"
check_eq "$(resize %2)" "-x 14" "tira: SIDE_W, 14 columnas (entran los ids de los subagentes)"
check_eq "$(zoom)" "0" "con lugar, el chat no pasa a pantalla completa"
layout 140
check_eq "$(resize %1)" "-x 44" "riel: se achica para dejarle 80 columnas al chat (140 - 80 - 2 - 14)"
layout 100
check_eq "$(resize %1)" "" "sin lugar para el riel (menos de LAYOUT_RAIL) no lo redimensiona"
check_eq "$(zoom)" "1" "y el chat pasa a pantalla completa"

conf 7 40 30 10 5
layout 200
check_eq "$(resize %1)" "-x 80" "cambiar layout.conf cambia el riel (40 % de 200)"
check_eq "$(resize %2)" "-x 7" "y la tira"
layout 50
check_eq "$(resize %1)" "-x 30" "y el mínimo del riel"
conf 7 40 30 30 25
layout 50
check_eq "$(resize %1)$(zoom)" "1" "y lo que el chat no cede y cuándo se esconde el riel (50 - 30 - 2 - 7 = 11 < 25: zoom)"

# El workspace nuevo también las usa (split-window del riel y de la tira)
check_eq "$(grep -cE 'split-window .*-l "\$\{RAIL_PCT\}%"' "$ROOT/bin/bk")" "1" "bk crea el riel con RAIL_PCT"
check_eq "$(grep -cE 'split-window .*-l "\$SIDE_W"' "$ROOT/bin/bk")" "1" "bk crea la tira con SIDE_W"
# Ningún número suelto de proporciones en bin/bk
SUELTO=$(grep -nE "34 */ *100|-l 34%|-hb -l [0-9]+ |-x [0-9]+\b|-lt 46|=46|SIDE_W=|LAYOUT_CHAT=|LAYOUT_RAIL=" "$ROOT/bin/bk" || true)
check_eq "$SUELTO" "" "sin anchos sueltos en bin/bk"

# bash y python leen lo mismo, con valores que NO son los de por defecto (sino da igual de dónde los saquen)
conf 7 40 30 10 5
PYV=$(python3 -B -c "import sys; sys.path.insert(0, '$COPY/lib'); import gentle as g; print(g.SIDE_W, g.RAIL_PCT, g.RAIL_MIN, g.LAYOUT['LAYOUT_CHAT'])")
BV=$(bash -c ". '$COPY/lib/layout.conf'; echo \$SIDE_W \$RAIL_PCT \$RAIL_MIN \$LAYOUT_CHAT")
check_eq "$PYV" "7 40 30 10" "gentle lee layout.conf (valores distintos a los de por defecto)"
check_eq "$BV" "7 40 30 10" "y bash lee el mismo archivo"

echo "1..$N"
[ "$FAILED" -eq 0 ]
