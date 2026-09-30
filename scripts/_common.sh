# Shared settings for the dev scripts. Sourced, not run.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/Debug/Domine.app"
cd "$ROOT"

require_tools() {
    command -v xcodebuild >/dev/null || { echo "xcodebuild not found. Install Xcode 16 or later." >&2; exit 1; }
    command -v xcodegen >/dev/null || { echo "xcodegen not found. Run: brew install xcodegen" >&2; exit 1; }
}

# Drops the simulator and plug-in noise that Xcode prints on every run.
quiet() {
    grep -vE "DVTPlugIn|DVTCoreDevice|CoreSimulator|appintentsmetadataprocessor|linkd.autoShortcut|CUICatalog" || true
}
