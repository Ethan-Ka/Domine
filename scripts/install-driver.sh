#!/bin/bash
# Build the Debug virtual output driver and install it into Core Audio's plug-in folder.
# ./scripts/install-driver.sh [--dry-run]
# Needs an admin password (sudo). Restarting coreaudiod drops all audio for a few seconds.
# --dry-run prints the commands without running them.
source "$(dirname "$0")/_common.sh"

DRY_RUN=0
case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    "") ;;
    *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

DRIVER="$DERIVED/Build/Products/Debug/Domine.driver"
HAL="/Library/Audio/Plug-Ins/HAL"
DEST="$HAL/Domine.driver"

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%q ' "$@"
        echo
    else
        "$@"
    fi
}

run "$ROOT/scripts/build.sh"
if [ "$DRY_RUN" -eq 0 ] && [ ! -d "$DRIVER" ]; then
    echo "Build did not produce $DRIVER" >&2
    exit 1
fi
run codesign --verify --strict "$DRIVER"

run sudo mkdir -p "$HAL"
run sudo rm -rf "$DEST"
run sudo ditto "$DRIVER" "$DEST"
run sudo chown -R root:wheel "$DEST"

echo "Restarting coreaudiod. All audio stops for a few seconds."
run sudo killall coreaudiod

[ "$DRY_RUN" -eq 1 ] || echo "Installed $DEST. Audio MIDI Setup should now list \"Domine\"."
