#!/bin/zsh
# Builds a signed, notarized release of Kool Save Editor and packages it as a disk image.
#
# Needs a "Developer ID Application" certificate in the keychain and notarization credentials,
# stored once with:
#   xcrun notarytool store-credentials KSEMac --apple-id <Apple ID> --team-id QFY7385FUG
#
# Usage: Tools/release.sh   (writes build/Kool-Save-Editor-<version>.dmg)
set -euo pipefail
cd "$(dirname "$0")/.."

team="QFY7385FUG"
profile="${NOTARY_PROFILE:-KSEMac}"
app="Kool Save Editor.app"
identity=$(security find-identity -v -p codesigning | awk -F'"' "/Developer ID Application: .*\\($team\\)/ { print \$2; exit }")
if [[ -z "$identity" ]]; then
    echo "No Developer ID Application certificate for team $team in the keychain." >&2
    exit 1
fi
version=$(xcodebuild -project KSEMac.xcodeproj -target KSEMac -showBuildSettings 2>/dev/null | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
work="build/work"
rm -rf "$work"
mkdir -p "$work"

echo "Archiving version $version…"
xcodebuild -project KSEMac.xcodeproj -scheme KSEMac -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$work/KSEMac.xcarchive" archive -quiet

echo "Exporting with $identity…"
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

echo "Notarizing the app…"
ditto -c -k --keepParent "$work/export/$app" "$work/app.zip"
xcrun notarytool submit "$work/app.zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$work/export/$app"

echo "Building the disk image…"
stage="$work/dmg"
mkdir -p "$stage"
ditto "$work/export/$app" "$stage/$app"
ln -s /Applications "$stage/Applications"
cp LICENSE NOTICE "$stage/"
dmg="build/Kool-Save-Editor-$version.dmg"
rm -f "$dmg"
hdiutil create -volname "Kool Save Editor $version" -srcfolder "$stage" -format UDZO -quiet "$dmg"
codesign --sign "$identity" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"

echo "Checking it the way Gatekeeper will…"
spctl --assess --type execute -v "$work/export/$app"
spctl --assess --type open --context context:primary-signature -v "$dmg"
shasum -a 256 "$dmg"
echo "Release ready: $dmg"
