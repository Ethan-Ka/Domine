#!/bin/bash
# Build the Sparkle appcast for a release made by release.sh (SPEC 8c).
# ./scripts/appcast.sh [--dry-run] [FILE...]
# FILE is a notarized .zip or .pkg. With none, uses build/release/Domine.zip and
# any build/release/*.pkg. Output goes to build/release/appcast/: the versioned
# update files and appcast.xml, ready to upload. Publishes nothing.
#
# Signing uses the private EdDSA key that generate_keys stored in the login keychain.
# Environment:
#   SPARKLE_BIN          folder with generate_appcast and sign_update (default: the
#                        Sparkle package checkout under build/)
#   FEED_URL             published appcast to start from, so older entries are kept
#                        (default: SPARKLE_FEED_URL in project.yml)
#   DOWNLOAD_URL_PREFIX  where the files will be downloaded from (default: the
#                        GitHub release for this version, tag vVERSION)
source "$(dirname "$0")/_common.sh"

DRY_RUN=0
INPUTS=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -*) echo "Usage: $0 [--dry-run] [FILE...]" >&2; exit 2 ;;
        *) INPUTS+=("$arg") ;;
    esac
done

REPO_URL="https://github.com/Ethan-Ka/Domine"
RELEASE="$ROOT/build/release"
OUT="$RELEASE/appcast"
APP="$RELEASE/dist/Domine.app"

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%q ' "$@"
        echo
    else
        "$@"
    fi
}

# Sparkle's tools ship in the package's binary artifact, which Xcode downloads
# on the first build (scripts/build.sh, test.sh, or release.sh).
find_sparkle_bin() {
    if [ -n "${SPARKLE_BIN:-}" ]; then
        echo "$SPARKLE_BIN"
        return
    fi
    local tool
    tool=$(find "$ROOT/build" -path "*/SourcePackages/artifacts/*/bin/generate_appcast" -type f 2>/dev/null | head -n 1)
    [ -n "$tool" ] && dirname "$tool"
}

BIN=$(find_sparkle_bin || true)
if [ -z "$BIN" ] || [ ! -x "$BIN/generate_appcast" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        BIN='$SPARKLE_BIN'
    else
        echo "Sparkle's generate_appcast not found. Build once (./scripts/build.sh) or set SPARKLE_BIN." >&2
        exit 1
    fi
fi

if [ ${#INPUTS[@]} -eq 0 ]; then
    [ -f "$RELEASE/Domine.zip" ] && INPUTS+=("$RELEASE/Domine.zip")
    for pkg in "$RELEASE"/*.pkg; do
        [ -f "$pkg" ] && INPUTS+=("$pkg")
    done
    if [ ${#INPUTS[@]} -eq 0 ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            INPUTS=("$RELEASE/Domine.zip")
        else
            echo "Nothing to publish in $RELEASE. Run ./scripts/release.sh first, or pass the files." >&2
            exit 1
        fi
    fi
fi

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null
}

if [ -d "$APP" ]; then
    VERSION=$(plist_value CFBundleShortVersionString)
    BUILD=$(plist_value CFBundleVersion)
elif [ "$DRY_RUN" -eq 1 ]; then
    VERSION=VERSION
    BUILD=BUILD
else
    echo "$APP not found. Run ./scripts/release.sh first." >&2
    exit 1
fi

if [ -z "${FEED_URL:-}" ]; then
    FEED_URL=$(sed -n 's/^ *SPARKLE_FEED_URL: *//p' "$ROOT/project.yml" | head -n 1)
fi
PREFIX="${DOWNLOAD_URL_PREFIX:-$REPO_URL/releases/download/v$VERSION/}"

run mkdir -p "$OUT"

# Start from the published feed so generate_appcast keeps the older entries.
if [ ! -f "$OUT/appcast.xml" ] && [ -n "$FEED_URL" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        run curl -fsSL "$FEED_URL" -o "$OUT/appcast.xml"
    elif curl -fsSL "$FEED_URL" -o "$OUT/appcast.xml.download"; then
        mv "$OUT/appcast.xml.download" "$OUT/appcast.xml"
        echo "Starting from the published appcast at $FEED_URL"
    else
        rm -f "$OUT/appcast.xml.download"
        echo "No published appcast at $FEED_URL. Starting a new one."
    fi
fi

PKGS=()
for input in "${INPUTS[@]}"; do
    if [ "$DRY_RUN" -eq 0 ] && [ ! -f "$input" ]; then
        echo "$input not found." >&2
        exit 1
    fi
    case "$input" in
        *.zip) run cp "$input" "$OUT/Domine-$VERSION.zip" ;;
        *.pkg)
            name="Domine-$VERSION.pkg"
            run cp "$input" "$OUT/$name"
            PKGS+=("$name")
            ;;
        *) echo "Unsupported file: $input (expected .zip or .pkg)" >&2; exit 1 ;;
    esac
done

# generate_appcast reads archives only. It skips .pkg files, which get a
# signature below for an item added by hand.
run "$BIN/generate_appcast" --download-url-prefix "$PREFIX" --link "$REPO_URL" "$OUT"

for name in ${PKGS[@]+"${PKGS[@]}"}; do
    echo
    echo "$name: generate_appcast does not handle packages. To ship it as the update,"
    echo "replace the enclosure of the build $BUILD item in appcast.xml with:"
    if [ "$DRY_RUN" -eq 1 ]; then
        run "$BIN/sign_update" "$OUT/$name"
    else
        echo "<enclosure url=\"$PREFIX$name\" sparkle:installationType=\"package\" type=\"application/octet-stream\" $("$BIN/sign_update" "$OUT/$name")/>"
    fi
done

[ "$DRY_RUN" -eq 1 ] || echo "Appcast in $OUT. Upload the update files to the v$VERSION release and appcast.xml to the site."
