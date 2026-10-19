#!/usr/bin/env bash
# Cut a GridFall release: VERSION, CHANGELOG.md, a release commit and an annotated tag.
#
# usage: tools/release.sh <version> [--dry-run]
#   version   semantic version without the v (0.2.0, 1.0.0-rc.1)
#   --dry-run print the changelog section and the commands; change nothing
#
# The game version lives in the VERSION file (project.godot is not touched); the release workflow
# (.github/workflows/release.yml) checks that the pushed tag equals v$(cat VERSION). After this
# script: review the commit, then `git push origin HEAD --follow-tags` to publish.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-}"
DRY=0
[ "${2:-}" = "--dry-run" ] && DRY=1
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
	sed -n '4,6p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
fi
TAG="v$VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
	echo "release: tag $TAG already exists" >&2
	exit 1
fi
if [ "$DRY" -eq 1 ]; then
	python3 -I tools/changelog.py --version "$VERSION"
	echo "release (dry run): would write VERSION=$VERSION, update CHANGELOG.md, commit and tag $TAG"
	exit 0
fi
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	echo "release: the working tree has uncommitted changes; commit or stash them first" >&2
	exit 1
fi
echo "$VERSION" > VERSION
python3 -I tools/changelog.py --version "$VERSION" --write CHANGELOG.md
git add VERSION CHANGELOG.md
git commit -m "chore(release): $TAG"
git tag -a "$TAG" -m "GridFall $TAG"
echo "release: tagged $TAG. Push with: git push origin HEAD --follow-tags"
