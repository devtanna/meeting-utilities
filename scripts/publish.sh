#!/bin/zsh
# Bumps the version, tests, builds, commits, tags, pushes and creates the GitHub release.
#
#   scripts/publish.sh [patch|minor|major|X.Y.Z]     (default: patch)
#   DRY_RUN=1 scripts/publish.sh minor               bump + test + build only; nothing is committed or pushed
#   NOTES=path/to/notes.md scripts/publish.sh        your highlights, shown above the generated changelog
#
# The version lives in Config/Base.xcconfig (tracked). MU_BUILD increases by one on every release.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=devtanna/meeting-utilities
BASE=Config/Base.xcconfig
BUMP=${1:-patch}

die() { print -u2 "publish: $*"; exit 1; }

# --- Preflight -------------------------------------------------------------------------------------------
[[ $(git branch --show-current) == main ]] || die "switch to main first"
[[ -z $(git status --porcelain) ]] || die "working tree has uncommitted changes"
git fetch -q origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || die "main is not in sync with origin/main (pull or push first)"
gh auth status -h github.com >/dev/null 2>&1 || die "gh is not logged in (run: gh auth login)"
if grep -qE '^MU_(VERSION|BUILD)[[:space:]]*=' Config/Identity.xcconfig 2>/dev/null; then
    die "remove MU_VERSION/MU_BUILD from Config/Identity.xcconfig; the version now lives in $BASE"
fi

CUR=$(awk -F' = ' '/^MU_VERSION =/ {print $2}' $BASE)
CUR_BUILD=$(awk -F' = ' '/^MU_BUILD =/ {print $2}' $BASE)
[[ $CUR == <->.<->.<-> && $CUR_BUILD == <-> ]] || die "can't read MU_VERSION/MU_BUILD from $BASE"
parts=(${(s:.:)CUR})
case $BUMP in
    patch) NEW="$parts[1].$parts[2].$((parts[3] + 1))" ;;
    minor) NEW="$parts[1].$((parts[2] + 1)).0" ;;
    major) NEW="$((parts[1] + 1)).0.0" ;;
    <->.<->.<->) NEW=$BUMP ;;
    *) die "usage: scripts/publish.sh [patch|minor|major|X.Y.Z]" ;;
esac
NEW_BUILD=$((CUR_BUILD + 1))
TAG="v$NEW"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"
gh release view "$TAG" -R $REPO >/dev/null 2>&1 && die "release $TAG already exists on GitHub"
[[ -z ${NOTES:-} || -f $NOTES ]] || die "NOTES file not found: $NOTES"

print "Releasing $CUR ($CUR_BUILD) → $NEW ($NEW_BUILD)${DRY_RUN:+  [dry run]}"

# --- Bump, test, build (undo the bump if anything fails before the commit) -------------------------------
committed=0
restore() { (( committed )) || git checkout -q -- $BASE; }
trap restore EXIT
sed -i '' -e "s/^MU_VERSION = .*/MU_VERSION = $NEW/" -e "s/^MU_BUILD = .*/MU_BUILD = $NEW_BUILD/" $BASE

scripts/test.sh
rm -rf dist
scripts/release.sh

DMG=dist/MeetingUtility-$NEW-$NEW_BUILD-arm64.dmg
ZIP=dist/MeetingUtility-$NEW-$NEW_BUILD-arm64.zip
[[ -f $DMG && -f $ZIP && -f dist/SHA256SUMS.txt ]] || die "expected $DMG, $ZIP and dist/SHA256SUMS.txt"

if [[ -n ${DRY_RUN:-} ]]; then
    print "Dry run done: artifacts are in dist/ and $BASE is restored. Nothing was committed or pushed."
    exit 0
fi

# --- Commit, tag, push, release ---------------------------------------------------------------------------
git add $BASE
git commit -q -m "Release $TAG"
committed=1
git tag -a "$TAG" -m "meetingutils $NEW"
git push -q origin main "$TAG"

notes=$(mktemp)
{
    [[ -n ${NOTES:-} ]] && { cat "$NOTES"; print; }
    cat <<EOF
## Install

Download \`$(basename $DMG)\` below and drag the app to Applications. This build is **not notarized**, so on first launch open **System Settings › Privacy & Security** and click **Open Anyway** ([guide](https://github.com/$REPO/blob/main/docs/INSTALL-TESTERS.md)). Updating from an earlier version: quit the app, replace it in Applications, and open it again. Your notes and models are kept.

Requires an Apple Silicon Mac on macOS 15 or newer. Check the download with \`shasum -a 256 -c SHA256SUMS.txt\`.

EOF
} > "$notes"

gh release create "$TAG" "$DMG" "$ZIP" dist/SHA256SUMS.txt -R $REPO \
    --title "meetingutils $NEW" --notes-file "$notes" --generate-notes --latest
rm -f "$notes"
print "Published https://github.com/$REPO/releases/tag/$TAG"
