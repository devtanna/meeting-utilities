#!/bin/zsh
# Runs all automated checks: package unit tests (Swift Testing) and the manifest gate.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
(cd Packages/MeetingKit && swift test)
scripts/verify-manifest.sh
echo "All tests passed."
