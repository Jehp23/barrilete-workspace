#!/usr/bin/env bash
# Los checks que corre bk land antes de que una rama entre a main. Sumá acá los tests que haya.
set -u
cd "$(dirname "$0")/.."
rc=0
for f in bin/bk lib/*.sh githooks/*; do [ -f "$f" ] && { bash -n "$f" || rc=1; }; done
# Los tests corren con el backend de tmux aunque tu bk use Herdr (~/.config/bk/backend): los que prueban
# Herdr lo piden ellos, con un herdr-app y un hc falsos
export BK_BACKEND=tmux; unset HC_TERMINAL_ID
export PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/bk-checks-pycache"
for f in lib/*.py; do python3 -m py_compile "$f" || rc=1; done
# Un test que corre su función bk con env, command, exec, xargs o sh -c ejecuta el bk real (pasó el 2026-11-10)
python3 lib/check_test_fns.py tests/*.sh || rc=1
for t in tests/test_*.sh; do [ -f "$t" ] && { bash "$t" >/dev/null 2>&1 || { echo "falló $t"; rc=1; }; }; done
[ $rc -eq 0 ] && echo "checks ok"
exit $rc
