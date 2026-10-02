#!/bin/bash
# Remove Domine and its virtual output driver, as installed by the Domine package.
# ./scripts/uninstall.sh [--dry-run]
# Needs an admin password (sudo). Restarting coreaudiod drops all audio for a few seconds.
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
run sudo rm -rf /Applications/Domine.app
run sudo rm -rf /Library/Audio/Plug-Ins/HAL/Domine.driver

for id in com.ethankawley.Domine.app com.ethankawley.Domine.driver; do
    if [ "$DRY_RUN" -eq 1 ] || pkgutil --pkg-info "$id" >/dev/null 2>&1; then
        run sudo pkgutil --forget "$id"
    fi
done

echo "Restarting coreaudiod. All audio stops for a few seconds."
if [ "$DRY_RUN" -eq 1 ]; then
    run sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
else
    sudo launchctl kickstart -k system/com.apple.audio.coreaudiod || sudo killall coreaudiod || true
fi

[ "$DRY_RUN" -eq 1 ] || echo "Removed Domine."
