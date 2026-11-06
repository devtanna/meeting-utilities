#!/bin/zsh
# Checks the toolchain, generates the Xcode project and resolves packages.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild -version
command -v xcodegen >/dev/null || { echo "Install xcodegen: brew install xcodegen"; exit 1; }
xcodegen --version
xcrun --find metal >/dev/null 2>&1 && xcrun metal --version >/dev/null 2>&1 || { echo "Installing Metal toolchain"; xcodebuild -downloadComponent MetalToolchain; }
[ -f Config/Identity.xcconfig ] || cp Config/Identity.example.xcconfig Config/Identity.xcconfig
xcodegen generate --quiet
if [ -f Package.resolved ]; then
  mkdir -p MeetingUtility.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
  cp Package.resolved MeetingUtility.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
fi
xcodebuild -resolvePackageDependencies -project MeetingUtility.xcodeproj -scheme MeetingUtility -derivedDataPath build/dd
echo "Bootstrap complete."
