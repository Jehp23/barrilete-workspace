#!/bin/bash
GPU=$(ioreg -l 2>/dev/null | grep -o '"Device Utilization %"=[0-9]*' | head -1 | cut -d= -f2)
[ -z "$GPU" ] && GPU="--"
sketchybar --set "$NAME" label="${GPU}%"
