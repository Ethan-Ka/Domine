#!/bin/bash
# Quit Domine. Asks politely first so the engine tears down the tap and aggregate,
# then force-quits after 5 seconds. Core Audio removes a dead process's private
# tap and aggregate on its own, so system audio comes back either way.
source "$(dirname "$0")/_common.sh"
if ! pgrep -xq Domine; then echo "Domine is not running."; exit 0; fi
osascript -e 'tell application id "com.ethankawley.Domine" to quit' 2>/dev/null || true
for _ in 1 2 3 4 5; do pgrep -xq Domine || { echo "Domine quit."; exit 0; }; sleep 1; done
pkill -9 -x Domine && echo "Domine force-quit."
