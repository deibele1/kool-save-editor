#!/bin/zsh
# Builds the Release app and installs it, replacing an earlier copy.
# Signs with the Developer ID certificate, as Tools/release.sh does (without notarizing): macOS
# ties privacy permissions such as reading the Mac App Store saves to the signature, and
# discards them when a differently signed copy (Apple Development) starts.
# Usage: Tools/install-app.sh [destination folder, default /Applications]
set -euo pipefail
cd "$(dirname "$0")/.."

destination="${1:-/Applications}"
app="Kool Save Editor.app"
team="QFY7385FUG"
if pgrep -qf "$destination/$app/Contents/MacOS"; then
    echo "Quit Kool Save Editor first (it is running from $destination)." >&2
    exit 1
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

xcodebuild -project KSEMac.xcodeproj -scheme KSEMac -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$work/KSEMac.xcarchive" archive -quiet
cat > "$work/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$team</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$work/KSEMac.xcarchive" -exportOptionsPlist "$work/export.plist" \
    -exportPath "$work/export" -allowProvisioningUpdates -quiet

rm -rf "$destination/$app"
ditto "$work/export/$app" "$destination/$app"
echo "Installed $destination/$app"
