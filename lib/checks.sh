#!/usr/bin/env bash
# Los checks que corre bk land antes de que una rama entre a main. Sumá acá los tests que haya.
set -u
cd "$(dirname "$0")/.."
rc=0
for f in bin/bk lib/*.sh githooks/*; do [ -f "$f" ] && { bash -n "$f" || rc=1; }; done
export PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/bk-checks-pycache"
for f in lib/*.py; do python3 -m py_compile "$f" || rc=1; done
for t in tests/test_*.sh; do [ -f "$t" ] && { bash "$t" >/dev/null 2>&1 || { echo "falló $t"; rc=1; }; }; done
[ $rc -eq 0 ] && echo "checks ok"
exit $rc
