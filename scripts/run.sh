#!/bin/bash
# Build, quit any running copy, and launch the Debug app.
# ./scripts/run.sh --logs   also streams the app's log in this terminal (Ctrl-C to stop).
source "$(dirname "$0")/_common.sh"
"$ROOT/scripts/build.sh"
"$ROOT/scripts/stop.sh" >/dev/null
open "$APP"
echo "Launched Domine."
if [ "${1:-}" = "--logs" ]; then
    exec "$ROOT/scripts/logs.sh"
fi
