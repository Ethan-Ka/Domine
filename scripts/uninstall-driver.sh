#!/bin/bash
# Remove the virtual output driver and restart coreaudiod.
# ./scripts/uninstall-driver.sh [--dry-run]
# Asks for an admin password once (system dialog). Restarting coreaudiod drops all audio for a few seconds.
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

echo "Restarting coreaudiod. Audio drops for a few seconds."
run osascript -e "do shell script \"rm -rf $DEST && killall coreaudiod\" with administrator privileges with prompt \"Domine needs to remove its audio driver.\""

[ "$DRY_RUN" -eq 1 ] && exit 0
sleep 3
if [ -e "$DEST" ]; then echo "$DEST is still present." >&2; exit 1; fi
echo "Removed $DEST."
