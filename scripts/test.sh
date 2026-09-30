#!/bin/bash
# Run all unit tests. Pass a filter to run a subset, e.g. ./scripts/test.sh DomineDSPTests
source "$(dirname "$0")/_common.sh"
require_tools
xcodegen generate --quiet
args=()
[ $# -gt 0 ] && args=(-only-testing:"$1")
xcodebuild -scheme Domine -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
    "${args[@]}" test 2>&1 | quiet | grep -E "error:|✘|Test run with|TEST (SUCCEEDED|FAILED)|failed"
test "${PIPESTATUS[0]}" -eq 0
