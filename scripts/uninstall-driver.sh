#!/bin/bash
# Remove the virtual output driver and restart coreaudiod.
# ./scripts/uninstall-driver.sh [--dry-run]
# Needs an admin password (sudo). Restarting coreaudiod drops all audio for a few seconds.
# --dry-run prints the commands without running them.
source "$(dirname "$0")/_common.sh"

DRY_RUN=0
case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    "") ;;
    *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

DEST="/Library/Audio/Plug-Ins/HAL/Domine.driver"

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%q ' "$@"
        echo
    else
        "$@"
    fi
}

if [ "$DRY_RUN" -eq 0 ] && [ ! -e "$DEST" ]; then
    echo "The driver is not installed ($DEST not found)."
    exit 0
fi

run sudo rm -rf "$DEST"
echo "Restarting coreaudiod. All audio stops for a few seconds."
run sudo killall coreaudiod

[ "$DRY_RUN" -eq 1 ] || echo "Removed $DEST."
