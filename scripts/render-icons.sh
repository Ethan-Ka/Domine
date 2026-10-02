#!/bin/bash
# Render Design/AppIcon.svg into every macOS app icon size in the asset catalog.
# Uses rsvg-convert when installed, otherwise scripts/render-svg.swift (AppKit).
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=Design/AppIcon.svg
OUT=Sources/Domine/Assets.xcassets/AppIcon.appiconset
mkdir -p "$OUT"

if ! command -v rsvg-convert >/dev/null; then
    RENDER="${TMPDIR:-/tmp}/domine-render-svg"
    swiftc -O scripts/render-svg.swift -o "$RENDER"
fi

render() { # svg png pixels
    if command -v rsvg-convert >/dev/null; then
        rsvg-convert -w "$3" -h "$3" "$1" -o "$2"
    else
        "$RENDER" "$1" "$2" "$3"
    fi
}

for pt in 16 32 128 256 512; do
    render "$SRC" "$OUT/icon_${pt}x${pt}.png" "$pt"
    render "$SRC" "$OUT/icon_${pt}x${pt}@2x.png" "$((pt * 2))"
done
echo "Rendered $OUT"
