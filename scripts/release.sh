#!/bin/bash
# Archive a Release build, sign it with Developer ID, notarize, staple, and verify.
# DEVELOPMENT_TEAM=ABCDE12345 NOTARY_PROFILE=domine ./scripts/release.sh [--dry-run]
# --dry-run prints the commands without running them. Output goes to build/release/.
source "$(dirname "$0")/_common.sh"

DRY_RUN=0
case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    "") ;;
    *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
    echo "DEVELOPMENT_TEAM is not set. Set it to your 10-character Apple team ID." >&2
    exit 1
fi
if ! [[ "$DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "DEVELOPMENT_TEAM must be 10 uppercase letters or digits, got '$DEVELOPMENT_TEAM'." >&2
    exit 1
fi
if [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "NOTARY_PROFILE is not set. Create one with: xcrun notarytool store-credentials NAME --apple-id ... --team-id $DEVELOPMENT_TEAM" >&2
    exit 1
fi

OUT="$ROOT/build/release"
ARCHIVE="$OUT/Domine.xcarchive"
EXPORT="$OUT/export"
APP_OUT="$EXPORT/Domine.app"
ZIP="$OUT/Domine.zip"
OPTIONS="$OUT/ExportOptions.plist"

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%q ' "$@"
        echo
    else
        "$@"
    fi
}

export_options() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>teamID</key>
    <string>$DEVELOPMENT_TEAM</string>
</dict>
</plist>
EOF
}

[ "$DRY_RUN" -eq 1 ] || require_tools

run rm -rf "$OUT"
run mkdir -p "$OUT"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "cat > $(printf '%q' "$OPTIONS") <<EOF"
    export_options
    echo "EOF"
else
    export_options > "$OPTIONS"
fi

run xcodegen generate --quiet
run xcodebuild archive -quiet \
    -scheme Domine -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$OUT/DerivedData" \
    -archivePath "$ARCHIVE" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS=--timestamp
run xcodebuild -exportArchive -quiet \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT" \
    -exportOptionsPlist "$OPTIONS"

run ditto -c -k --keepParent "$APP_OUT" "$ZIP"
if [ "$DRY_RUN" -eq 1 ]; then
    run xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist
else
    # notarytool can exit 0 on a rejected submission, so check the status it reports.
    RESULT="$OUT/notary-result.plist"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist > "$RESULT"
    STATUS=$(/usr/libexec/PlistBuddy -c "Print :status" "$RESULT" 2>/dev/null || echo unknown)
    if [ "$STATUS" != "Accepted" ]; then
        ID=$(/usr/libexec/PlistBuddy -c "Print :id" "$RESULT" 2>/dev/null || echo "")
        echo "Notarization status: $STATUS. See why with: xcrun notarytool log $ID --keychain-profile $NOTARY_PROFILE" >&2
        exit 1
    fi
fi
run xcrun stapler staple "$APP_OUT"

# Re-zip so the distributed archive carries the stapled ticket.
run rm -f "$ZIP"
run ditto -c -k --keepParent "$APP_OUT" "$ZIP"

run codesign --verify --deep --strict --verbose=2 "$APP_OUT"
run spctl -a -vvv -t install "$APP_OUT"

[ "$DRY_RUN" -eq 1 ] || echo "Released $ZIP"
