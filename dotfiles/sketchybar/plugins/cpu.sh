#!/bin/bash
CPU=$(top -l 1 -n 0 | grep "CPU usage" | awk '{print $3}' | cut -d% -f1)
# Sin decimales: "11.52%" ocupaba ~25 px que la derecha del notch no tiene
sketchybar --set "$NAME" label="$(printf '%.0f' "${CPU:-0}")%"
