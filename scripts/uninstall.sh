#!/bin/bash
# Remove Domine and its virtual output driver, as installed by the Domine package.
# ./scripts/uninstall.sh [--dry-run]
# Asks for an admin password once (system dialog). Restarting coreaudiod drops all audio for a few seconds.
# --dry-run prints the commands without running them.
set -euo pipefail

DRY_RUN=0
case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    "") ;;
    *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%q ' "$@"
        echo
    else
        "$@"
    fi
}

run pkill -x Domine || true
CMD="rm -rf /Applications/Domine.app /Library/Audio/Plug-Ins/HAL/Domine.driver"
for id in com.ethankawley.Domine.app com.ethankawley.Domine.driver; do
    if [ "$DRY_RUN" -eq 1 ] || pkgutil --pkg-info "$id" >/dev/null 2>&1; then
        CMD="$CMD; pkgutil --forget $id"
    fi
done
CMD="$CMD; killall coreaudiod"

echo "Restarting coreaudiod. Audio drops for a few seconds."
run osascript -e "do shell script \"$CMD\" with administrator privileges with prompt \"Domine needs to remove its app and audio driver.\""

[ "$DRY_RUN" -eq 1 ] || echo "Removed Domine."
