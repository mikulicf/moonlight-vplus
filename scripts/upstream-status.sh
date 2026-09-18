#!/usr/bin/env bash
# Compatibility entry point; Python also supports native Windows invocation.
set -euo pipefail
if command -v python3 >/dev/null 2>&1; then
    exec python3 "$(dirname "$0")/upstream-status.py" "$@"
else
    exec python "$(dirname "$0")/upstream-status.py" "$@"
fi
