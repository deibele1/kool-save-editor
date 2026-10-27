#!/bin/zsh
# Builds the Release app and installs it, replacing an earlier copy.
# Usage: Tools/install-app.sh [destination folder, default /Applications]
set -euo pipefail
cd "$(dirname "$0")/.."

destination="${1:-/Applications}"
app="Kool Save Editor.app"
if pgrep -qf "$destination/$app/Contents/MacOS"; then
    echo "Quit Kool Save Editor first (it is running from $destination)." >&2
    exit 1
fi
derived="$(mktemp -d)"
trap 'rm -rf "$derived"' EXIT

xcodebuild -project KSEMac.xcodeproj -scheme KSEMac -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived" build -quiet

rm -rf "$destination/$app"
ditto "$derived/Build/Products/Release/$app" "$destination/$app"
echo "Installed $destination/$app"
