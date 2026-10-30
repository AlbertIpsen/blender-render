#!/usr/bin/env bash
# Publish a new BlenderRender version: everyone's app then offers "Update & Restart".
#
#   ./release.sh "What changed"            bumps 1.2.3 -> 1.2.4
#   ./release.sh minor "What changed"      bumps 1.2.3 -> 1.3.0  (also: major, or an exact 2.0.0)
#
# Commits everything that changed, tags it, builds the app and uploads it as a GitHub release.
set -euo pipefail
cd "$(dirname "$0")"

BUMP=patch
[[ $# -ge 2 ]] && { BUMP="$1"; shift; }
[[ $# -eq 1 && -n "$1" ]] || { sed -n '2,7p' "$0"; exit 2; }
NOTES="$1"

[[ "$(git branch --show-current)" == "main" ]] || { echo "release from main"; exit 1; }
git fetch -q origin main 2>/dev/null || :
[[ "$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)" == "0" ]] || { echo "main is behind GitHub: pull first"; exit 1; }

IFS=. read -r MAJOR MINOR PATCH < VERSION
case "$BUMP" in
    patch) V="$MAJOR.$MINOR.$((PATCH + 1))" ;;
    minor) V="$MAJOR.$((MINOR + 1)).0" ;;
    major) V="$((MAJOR + 1)).0.0" ;;
    [0-9]*.[0-9]*.[0-9]*) V="$BUMP" ;;
    *) echo "unknown version '$BUMP'"; exit 2 ;;
esac

# The app only recopies its PC scripts when RenderPC.protocolVersion differs from rq.py's.
LAST="$(git describe --tags --abbrev=0 2>/dev/null || :)"
if [[ -n "$LAST" ]] && ! git diff --quiet "$LAST" -- pc remote_gpu.py progress.py \
    && git diff --quiet "$LAST" -- BlenderRenderApp/Sources/RenderPC.swift; then
    echo "note: PC scripts changed but protocolVersion didn't, so existing PCs won't get them."
fi

echo "$V" > VERSION
BlenderRenderApp/build_app.sh --no-install
ditto -c -k --norsrc --keepParent BlenderRenderApp/build/BlenderRender.app BlenderRenderApp/build/BlenderRender.zip

git add -A
git commit -q -m "Release v$V" -m "$NOTES" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git tag "v$V"
git push -q origin main "v$V"
gh release create "v$V" BlenderRenderApp/build/BlenderRender.zip --title "v$V" --notes "$NOTES"
echo "released v$V"
