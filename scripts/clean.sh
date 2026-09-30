#!/bin/bash
# Delete build output and the generated Xcode project. The next build regenerates both.
source "$(dirname "$0")/_common.sh"
rm -rf "$ROOT/build" "$ROOT/Domine.xcodeproj"
echo "Removed build/ and Domine.xcodeproj."
