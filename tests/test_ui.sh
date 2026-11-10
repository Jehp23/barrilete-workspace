#!/usr/bin/env bash
# Corre tests/test_ui.py (paleta, estados y proporciones de las vistas). lib/checks.sh levanta los test_*.sh.
cd "$(dirname "$0")/.." || exit 1
export PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/bk-checks-pycache"
exec python3 -m unittest -q tests/test_ui.py
