#!/bin/bash
# Build the Debug virtual output driver and install it into Core Audio's plug-in folder.
# ./scripts/install-driver.sh [--dry-run]
# Asks for an admin password once (system dialog). Restarting coreaudiod drops all audio for a few seconds.
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

# Root cannot read ~/Documents, so stage the driver in /private/tmp as the user first.
STAGE="/private/tmp/domine-driver-stage"
run rm -rf "$STAGE"
run mkdir -p "$STAGE"
run ditto "$DRIVER" "$STAGE/Domine.driver"

echo "Restarting coreaudiod. Audio drops for a few seconds."
CMD="mkdir -p $HAL && rm -rf $DEST && ditto $STAGE/Domine.driver $DEST && chown -R root:wheel $DEST && killall coreaudiod"
run osascript -e "do shell script \"$CMD\" with administrator privileges with prompt \"Domine needs to install its audio driver.\""
run rm -rf "$STAGE"

[ "$DRY_RUN" -eq 1 ] && exit 0
sleep 6
if system_profiler SPAudioDataType 2>/dev/null | grep -q "Domine"; then
    echo "Installed $DEST. The Domine virtual output (com.ethankawley.Domine.VirtualOutput) is present."
else
    echo "Installed, but the Domine device did not appear. Check: log show --last 5m --predicate 'process CONTAINS \"coreaudiod\"'" >&2
    exit 1
fi
