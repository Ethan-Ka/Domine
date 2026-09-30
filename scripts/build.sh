#!/bin/bash
# Regenerate the Xcode project and build the Debug app.
source "$(dirname "$0")/_common.sh"
require_tools
xcodegen generate --quiet
xcodebuild -scheme Domine -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" build 2>&1 | quiet | grep -E "error:|warning: |BUILD (SUCCEEDED|FAILED)"
test "${PIPESTATUS[0]}" -eq 0
echo "Built $APP"
