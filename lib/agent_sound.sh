#!/bin/bash
# Sonido cuando un agente cambia a un estado que te importa (lo llama el hook de estado).
#   agent_sound.sh <estado_anterior> <estado_nuevo> [question|permission]
# Uno por tipo de pedido (no por agente): terminó · te pregunta · pide permiso · error.
# Apagar: bk sound off (escribe "off" en ~/.config/bk/sound). BK_SOUND_DRY=1 imprime en vez de sonar.
prev="${1:-}" new="${2:-}" wait="${3:-}"
[ "$prev" = "$new" ] && exit 0   # sin cambio de estado, sin sonido (evita repetir avisos)
[ "$(cat "$HOME/.config/bk/sound" 2>/dev/null)" = off ] && exit 0

case "$new" in
  done)
    # Solo si venía trabajando: "done" desde idle es el aviso de inactividad, no un final
    case "$prev" in working|background|waiting) s=Glass ;; *) exit 0 ;; esac ;;
  waiting)
    [ "$wait" = question ] && s=Ping || s=Purr ;;
  error) s=Basso ;;
  *) exit 0 ;;
esac

f="/System/Library/Sounds/$s.aiff"
if [ -n "${BK_SOUND_DRY:-}" ]; then echo "$s"; exit 0; fi
[ -f "$f" ] && command -v afplay >/dev/null || exit 0

# Si suena la radio de bk song, la baja mientras suena el aviso y después la deja como estaba.
# El candado evita que dos avisos seguidos guarden el volumen ya bajado como el "original".
SONG_CACHE="${BK_SONG_CACHE:-$HOME/.cache/bk}"
SOCK="$SONG_CACHE/song.sock" LOCK="$SONG_CACHE/song.duck"
mpv_vol() { printf '%s\n' "$1" | nc -U -w 1 "$SOCK" 2>/dev/null | head -n 1; }
play_ducked() {
  local orig="" mine=""
  # un candado de más de 30 s es de un aviso que murió a la mitad
  if [ -d "$LOCK" ]; then
    local m; m=$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo 0)
    [ $(( $(date +%s) - m )) -gt 30 ] && rmdir "$LOCK" 2>/dev/null
  fi
  if [ -S "$SOCK" ] && mkdir "$LOCK" 2>/dev/null; then
    mine=1
    orig=$(mpv_vol '{"command":["get_property","volume"]}' | sed -n 's/.*"data":\([0-9.]*\).*/\1/p')
    orig=${orig%.*}
    if [[ "$orig" =~ ^[0-9]+$ ]] && [ "$orig" -gt 0 ]; then
      mpv_vol "{\"command\":[\"set_property\",\"volume\",$(( orig * 35 / 100 ))]}" >/dev/null
    else
      orig=""
    fi
  fi
  afplay -v 0.6 "$f" >/dev/null 2>&1
  if [ -n "$orig" ]; then
    sleep 0.3
    mpv_vol "{\"command\":[\"set_property\",\"volume\",$orig]}" >/dev/null
  fi
  if [ -n "$mine" ]; then rmdir "$LOCK" 2>/dev/null || true; fi
}
(play_ducked &)
exit 0
