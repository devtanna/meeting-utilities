#!/bin/zsh
# Usage: scripts/build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIG="${1:-Debug}"
[ -f Config/Identity.xcconfig ] || cp Config/Identity.example.xcconfig Config/Identity.xcconfig
xcodegen generate --quiet
[ -f Package.resolved ] && mkdir -p MeetingUtility.xcodeproj/project.xcworkspace/xcshareddata/swiftpm && cp Package.resolved MeetingUtility.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild -project MeetingUtility.xcodeproj -scheme MeetingUtility -configuration "$CONFIG" -derivedDataPath build/dd \
  -destination 'platform=macOS,arch=arm64' -skipMacroValidation -skipPackagePluginValidation -quiet build
cp MeetingUtility.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved Package.resolved
echo "Built: build/dd/Build/Products/$CONFIG/MeetingUtility.app"
