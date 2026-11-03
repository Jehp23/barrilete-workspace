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
[ -f "$f" ] && command -v afplay >/dev/null && (afplay -v 0.6 "$f" >/dev/null 2>&1 &)
exit 0
