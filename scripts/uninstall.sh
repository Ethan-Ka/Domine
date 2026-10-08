#!/bin/bash
# Remove Domine completely: the app, the audio driver, pkg receipts, settings and permissions.
# scripts/uninstall.sh [--dry-run] [--wait-pid PID] [--keep-settings] [--yes]
# --dry-run        print each command instead of running it
# --wait-pid PID   wait up to 15 s for that process to exit first (used when the app calls this script)
# --keep-settings  leave preferences, caches, logs and permissions alone
# --yes            do not ask for confirmation
# Env DOMINE_APP_PATH: extra .app path to remove (the copy that launched the app).
# Asks for an admin password once. Restarting coreaudiod drops all audio for a few seconds.
set -uo pipefail

USAGE="Usage: $0 [--dry-run] [--wait-pid PID] [--keep-settings] [--yes]"
DRY_RUN=0; WAIT_PID=""; KEEP=0; YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --keep-settings) KEEP=1 ;;
        --yes) YES=1 ;;
        --wait-pid)
            [ $# -ge 2 ] || { echo "$USAGE" >&2; exit 2; }
            WAIT_PID="$2"; shift ;;
        *) echo "$USAGE" >&2; exit 2 ;;
    esac
    shift
done

BUNDLE="com.ethankawley.Domine"
APPS=("/Applications/Domine.app")
case "${DOMINE_APP_PATH:-}" in
    /?*.app)
        if [ "$DOMINE_APP_PATH" != "/Applications/Domine.app" ]; then APPS+=("$DOMINE_APP_PATH"); fi ;;
esac
DRIVER="/Library/Audio/Plug-Ins/HAL/Domine.driver"
RECEIPTS=("$BUNDLE.app" "$BUNDLE.driver")

USER_PATHS=(
    "$HOME/Library/Preferences/$BUNDLE.plist"
    "$HOME/Library/Application Support/Domine"
    "$HOME/Library/Caches/$BUNDLE"
    "$HOME/Library/HTTPStorages/$BUNDLE"
    "$HOME/Library/Saved Application State/$BUNDLE.savedState"
    "$HOME/Library/Logs/Domine"
)

run() {
    if [ "$DRY_RUN" -eq 1 ]; then printf '%q ' "$@"; echo; else "$@"; fi
}

# Confirmation
if [ "$YES" -eq 0 ] && [ -t 0 ]; then
    echo "This will remove:"
    for p in "${APPS[@]}" "$DRIVER"; do echo "  $p"; done
    echo "  the installer receipts for Domine"
    if [ "$KEEP" -eq 0 ]; then
        for p in "${USER_PATHS[@]}"; do echo "  $p"; done
        echo "  Domine's saved settings and privacy permissions"
    fi
    printf 'Remove Domine? [y/N] '
    read -r ans
    case "$ans" in y|Y|yes|YES) ;; *) echo "Cancelled. Nothing was removed."; exit 1 ;; esac
fi

# Quit the app
if [ -n "$WAIT_PID" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "wait up to 15 s for pid $WAIT_PID to exit"
    else
        for _ in $(seq 1 30); do kill -0 "$WAIT_PID" 2>/dev/null || break; sleep 0.5; done
    fi
else
    run osascript -e 'tell application id "com.ethankawley.Domine" to quit'
    if [ "$DRY_RUN" -eq 0 ]; then
        for _ in $(seq 1 20); do pgrep -x Domine >/dev/null || break; sleep 0.5; done
    fi
    run pkill -x Domine
fi

# Admin step
ADMIN=""
add() { ADMIN="${ADMIN:+$ADMIN; }$(printf '%q ' "$@")"; }
for a in "${APPS[@]}"; do
    if [ "$DRY_RUN" -eq 1 ] || [ -e "$a" ]; then add rm -rf "$a"; fi
done
if [ "$DRY_RUN" -eq 1 ] || [ -e "$DRIVER" ]; then add rm -rf "$DRIVER"; fi
for id in "${RECEIPTS[@]}"; do
    if [ "$DRY_RUN" -eq 1 ] || pkgutil --pkg-info "$id" >/dev/null 2>&1; then add pkgutil --forget "$id"; fi
done
ADMIN="$ADMIN; launchctl kickstart -k system/com.apple.audio.coreaudiod || killall coreaudiod"

# Escape for an AppleScript string literal
ESC=${ADMIN//\\/\\\\}
ESC=${ESC//\"/\\\"}
SCRIPT="do shell script \"$ESC\" with administrator privileges with prompt \"Domine needs your password to remove its app and audio driver.\""

echo "Restarting coreaudiod. Audio drops for a few seconds."
if [ "$DRY_RUN" -eq 1 ]; then
    run osascript -e "$SCRIPT"
elif ! osascript -e "$SCRIPT" >/dev/null 2>&1; then
    echo "Cancelled. Nothing was removed."
    exit 1
fi

# User-level cleanup
if [ "$KEEP" -eq 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        run defaults delete "$BUNDLE"
    else
        defaults delete "$BUNDLE" >/dev/null 2>&1 || true
    fi
    for p in "${USER_PATHS[@]}"; do
        if [ "$DRY_RUN" -eq 1 ] || [ -e "$p" ]; then run rm -rf "$p"; fi
    done
    if [ "$DRY_RUN" -eq 1 ]; then
        run tccutil reset All "$BUNDLE"
    else
        tccutil reset All "$BUNDLE" >/dev/null 2>&1 || true
    fi
fi

[ "$DRY_RUN" -eq 1 ] || echo "Removed Domine."
exit 0
