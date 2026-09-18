#!/bin/bash
set -euo pipefail

# install-qt-action installs below the workspace and exports QT_ROOT_DIR.
# Do not hard-code C:\Qt; local runs can use lrelease from PATH.
if [[ -n "${QT_ROOT_DIR:-}" && -x "$QT_ROOT_DIR/bin/lrelease" ]]; then
    LRELEASE="$QT_ROOT_DIR/bin/lrelease"
elif [[ -n "${QT_ROOT_DIR:-}" && -x "$QT_ROOT_DIR/bin/lrelease.exe" ]]; then
    LRELEASE="$QT_ROOT_DIR/bin/lrelease.exe"
else
    LRELEASE="$(command -v lrelease)"
fi
echo "Using $LRELEASE"

# Compile all translation catalogs.
for f in app/languages/*.ts; do
    echo "Processing $f..."
    "$LRELEASE" "$f"
done

echo "Translation compilation completed!"
