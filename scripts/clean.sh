#!/bin/bash
# Delete build output and the generated Xcode project. The next build regenerates both.
#   --xcode  also delete Xcode's own DerivedData/Domine-* folders, which hold
#            older Domine.app copies that System Settings can confuse with
#            this one (same name and bundle ID, different signature).
source "$(dirname "$0")/_common.sh"

xcode=false
for arg in "$@"; do
    case "$arg" in
        --xcode) xcode=true ;;
        *) echo "Unknown option: $arg (use --xcode)" >&2; exit 2 ;;
    esac
done

rm -rf "$ROOT/build" "$ROOT/Domine.xcodeproj"
echo "Removed build/ and Domine.xcodeproj."

if $xcode; then
    shopt -s nullglob
    copies=("$HOME/Library/Developer/Xcode/DerivedData"/Domine-*)
    if [ ${#copies[@]} -eq 0 ]; then
        echo "No Xcode DerivedData/Domine-* folders."
    fi
    for dir in "${copies[@]}"; do
        echo "Removing $dir"
        rm -rf "$dir"
    done
fi
