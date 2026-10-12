#!/bin/sh
# Public distribution is fail-closed; development packaging must be explicit.
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -eq 0 ]; then set -- distribute; fi
exec python3 "$TASK_ROOT/tool/package_macos.py" "$@"
