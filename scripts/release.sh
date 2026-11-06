#!/bin/zsh
# Builds a Release arm64 app and packages a DMG + zip in dist/ (§20.2 steps 3, 4, 7).
# Signing: ad-hoc unless Config/Identity.xcconfig configures a team. Notarization/Gatekeeper/Sparkle appcast
# signing are BLOCKED until a Developer ID exists (see docs/release.md).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
scripts/verify-manifest.sh
scripts/build.sh Release | tail -3
APP=build/dd/Build/Products/Release/MeetingUtility.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
# Audit: arm64 only, nested code signed, MLX metallib inside the service only, no model weights bundled.
lipo -archs "$APP/Contents/MacOS/MeetingUtility" | grep -qx arm64
codesign --verify --deep --strict "$APP"
[ -f "$APP/Contents/XPCServices/InferenceService.xpc/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]
! find "$APP" -name '*.safetensors' | grep -q .
! nm -U "$APP/Contents/MacOS/MeetingUtility" 2>/dev/null | grep -q '_mlx_'
mkdir -p dist
rm -rf dist/stage && mkdir -p dist/stage
ditto "$APP" dist/stage/MeetingUtility.app
ln -s /Applications dist/stage/Applications
cp "$APP/Contents/Resources/AppIcon.icns" dist/stage/.VolumeIcon.icns   # DMG shows the app logo
SetFile -a C dist/stage 2>/dev/null || true
cp docs/INSTALL-TESTERS.md dist/stage/"Read Me First.md"
DMG="dist/MeetingUtility-$VERSION-$BUILD-arm64.dmg"
rm -f "$DMG"
hdiutil create -volname "Meeting Utility" -srcfolder dist/stage -ov -format UDRW dist/rw.dmg >/dev/null
MNT=$(hdiutil attach -nobrowse -noverify dist/rw.dmg | awk -F'\t' '/Volumes/ {print $NF}')
SetFile -a C "$MNT" 2>/dev/null || true
hdiutil detach "$MNT" >/dev/null
hdiutil convert dist/rw.dmg -format UDZO -o "$DMG" >/dev/null && rm -f dist/rw.dmg
ditto -c -k --keepParent "$APP" "dist/MeetingUtility-$VERSION-$BUILD-arm64.zip"
rm -rf dist/stage
( cd dist && shasum -a 256 *.dmg *.zip > SHA256SUMS.txt )
du -sh "$APP" "$DMG" dist/*.zip
echo "Release artifacts in dist/"
