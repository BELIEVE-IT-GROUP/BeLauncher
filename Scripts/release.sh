#!/bin/bash
# Bumps the version, commits and creates the vX.Y.Z tag that triggers the release workflow.
# It does not push: that stays a deliberate manual step.
#
#   bash Scripts/release.sh [patch|minor|major]     (default: patch)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUMP="${1:-patch}"
case "$BUMP" in patch|minor|major) ;; *) echo "usage: release.sh [patch|minor|major]"; exit 1 ;; esac

UNEXPECTED_DIRTY="$(git status --porcelain \
    | grep -vE '^\\?\\? (audit-ai-layer/|audit-native-actions/|docs/plan-action-map-v2\\.md$)' \
    || true)"
[ -z "$UNEXPECTED_DIRTY" ] || {
    echo "Working tree is dirty; commit first."
    printf '%s\n' "$UNEXPECTED_DIRTY"
    exit 1
}

CURRENT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Scripts/Info.plist)"
IFS=. read -r MAJOR MINOR PATCH <<< "$CURRENT"
case "$BUMP" in
    major) NEXT="$((MAJOR + 1)).0.0" ;;
    minor) NEXT="$MAJOR.$((MINOR + 1)).0" ;;
    patch) NEXT="$MAJOR.$MINOR.$((PATCH + 1))" ;;
esac

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEXT" Scripts/Info.plist
git add Scripts/Info.plist
git commit -m "release: v$NEXT"
git tag -a "v$NEXT" -m "BeLauncher v$NEXT"

echo
echo "Tagged v$NEXT ($CURRENT → $NEXT)."
echo "Push to start the signed + notarized release:"
echo "    git push --follow-tags"
