#!/bin/bash
# Regenerate the project and open it in Xcode, for debugging with breakpoints.
source "$(dirname "$0")/_common.sh"
require_tools
xcodegen generate --quiet
open "$ROOT/Domine.xcodeproj"
