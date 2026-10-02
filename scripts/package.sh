#!/bin/bash
# Build, sign, notarize, and staple an installer package holding the app and the driver.
# INSTALLER_IDENTITY="Developer ID Installer: Name (TEAMID)" NOTARY_PROFILE=domine ./scripts/package.sh [--dry-run]
# Run ./scripts/release.sh first: it produces build/release/dist/. Output is build/release/Domine-<version>.pkg.
# --dry-run prints the commands without running them.
source "$(dirname "$0")/_common.sh"

DRY_RUN=0
case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    "") ;;
    *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

if [ -z "${INSTALLER_IDENTITY:-}" ]; then
    echo "INSTALLER_IDENTITY is not set. Set it to your certificate name, for example: Developer ID Installer: Your Name (TEAMID)" >&2
    exit 1
fi
if [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "NOTARY_PROFILE is not set. Create one with: xcrun notarytool store-credentials NAME --apple-id ... --team-id ..." >&2
    exit 1
fi

OUT="$ROOT/build/release"
DIST="$OUT/dist"
APP_DIST="$DIST/Domine.app"
DRIVER_DIST="$DIST/Domine.driver"
PKG_WORK="$OUT/pkg"
INSTALLER="$ROOT/Installer"

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%q ' "$@"
        echo
    else
        "$@"
    fi
}

if [ "$DRY_RUN" -eq 1 ] && [ ! -d "$APP_DIST" ]; then
    VERSION="VERSION"
elif [ "$DRY_RUN" -eq 1 ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_DIST/Contents/Info.plist")
else
    for item in "$APP_DIST" "$DRIVER_DIST"; do
        [ -d "$item" ] || { echo "$item not found. Run ./scripts/release.sh first." >&2; exit 1; }
    done
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_DIST/Contents/Info.plist")
fi
UNSIGNED="$PKG_WORK/Domine-unsigned.pkg"
PKG="$OUT/Domine-$VERSION.pkg"

run rm -rf "$PKG_WORK"
run mkdir -p "$PKG_WORK/app-root" "$PKG_WORK/driver-root" "$PKG_WORK/scripts"
run ditto "$APP_DIST" "$PKG_WORK/app-root/Domine.app"
run ditto "$DRIVER_DIST" "$PKG_WORK/driver-root/Domine.driver"
run cp "$INSTALLER/scripts/postinstall" "$PKG_WORK/scripts/postinstall"

run pkgbuild --root "$PKG_WORK/app-root" \
    --identifier com.ethankawley.Domine.app --version "$VERSION" \
    --install-location /Applications --ownership recommended \
    "$PKG_WORK/Domine-app.pkg"
run pkgbuild --root "$PKG_WORK/driver-root" \
    --identifier com.ethankawley.Domine.driver --version "$VERSION" \
    --install-location /Library/Audio/Plug-Ins/HAL --ownership recommended \
    --scripts "$PKG_WORK/scripts" \
    "$PKG_WORK/Domine-driver.pkg"
run productbuild --distribution "$INSTALLER/distribution.xml" \
    --package-path "$PKG_WORK" --version "$VERSION" \
    "$UNSIGNED"
run productsign --sign "$INSTALLER_IDENTITY" --timestamp "$UNSIGNED" "$PKG"

if [ "$DRY_RUN" -eq 1 ]; then
    run xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist
else
    # notarytool can exit 0 on a rejected submission, so check the status it reports.
    RESULT="$OUT/notary-pkg-result.plist"
    xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist > "$RESULT"
    STATUS=$(/usr/libexec/PlistBuddy -c "Print :status" "$RESULT" 2>/dev/null || echo unknown)
    if [ "$STATUS" != "Accepted" ]; then
        ID=$(/usr/libexec/PlistBuddy -c "Print :id" "$RESULT" 2>/dev/null || echo "")
        echo "Notarization status: $STATUS. See why with: xcrun notarytool log $ID --keychain-profile $NOTARY_PROFILE" >&2
        exit 1
    fi
fi
run xcrun stapler staple "$PKG"

run pkgutil --check-signature "$PKG"
run spctl -a -vvv -t install "$PKG"

[ "$DRY_RUN" -eq 1 ] || echo "Packaged $PKG"
