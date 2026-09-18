#!/bin/sh
#
# Complete an in-app macOS update.
#
# PortableUpdateInstaller launches this detached script before exiting. Downloading,
# mounting, and validation happen in the main process. This script waits for exit,
# replaces the installed bundle, and restarts the application.
#
# Usage: install-dmg-update.sh <staging-directory> <installed-bundle> <new-bundle> <pid>
#
# Roll back failures and log the reason to ~/Library/Logs/Moonlight-update-error.log.

set -u

WORKSPACE="$1"
INSTALLED_APP="$2"
STAGED_APP="$3"
MAIN_PID="$4"

BACKUP_DIR="$WORKSPACE/backup"
LOG_FILE="$HOME/Library/Logs/Moonlight-update-error.log"

log_failure() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

cleanup() {
    [ -n "$WORKSPACE" ] && [ -d "$WORKSPACE" ] && rm -rf "$WORKSPACE"
}

# Wait for the main process to exit; kill -0 probes existence without sending a signal.
# Give up after 30 seconds rather than terminating a possibly active stream.
waited=0
while kill -0 "$MAIN_PID" 2>/dev/null; do
    if [ "$waited" -ge 300 ]; then
        log_failure "Timed out waiting for Moonlight (pid $MAIN_PID) to exit; update not applied."
        cleanup
        exit 1
    fi
    sleep 0.1
    waited=$((waited + 1))
done

if [ ! -d "$STAGED_APP" ]; then
    log_failure "Staged app bundle is missing: $STAGED_APP"
    cleanup
    exit 1
fi

mkdir -p "$BACKUP_DIR" || {
    log_failure "Unable to create backup directory: $BACKUP_DIR"
    cleanup
    exit 1
}

# Move the old bundle into backup so replacement failures can restore it unchanged.
if [ -d "$INSTALLED_APP" ]; then
    if ! mv "$INSTALLED_APP" "$BACKUP_DIR/" 2>/dev/null; then
        log_failure "Unable to move the installed app aside: $INSTALLED_APP"
        cleanup
        exit 1
    fi
fi

# A cross-volume staging directory makes mv a non-atomic copy/delete operation.
# Retain the backup until replacement has completed.
if ! mv "$STAGED_APP" "$INSTALLED_APP" 2>/dev/null; then
    log_failure "Unable to move the new app into place: $INSTALLED_APP"

    # A failed cross-volume move may leave a partial destination. Remove it first
    # so restoring the backup does not nest Moonlight.app inside a broken bundle.
    rm -rf "$INSTALLED_APP"

    BACKUP_APP="$BACKUP_DIR/$(basename "$INSTALLED_APP")"
    if [ -d "$BACKUP_APP" ] && mv "$BACKUP_APP" "$INSTALLED_APP" 2>/dev/null; then
        open -a "$INSTALLED_APP" 2>/dev/null
    else
        # Rollback also failed. Preserve the backup: it is the only complete installation.
        log_failure "Rollback failed. The previous version is still in $BACKUP_DIR — move it back manually."
        exit 1
    fi

    cleanup
    exit 1
fi

open -a "$INSTALLED_APP" 2>/dev/null || log_failure "Update installed but relaunch failed: $INSTALLED_APP"

cleanup
exit 0
