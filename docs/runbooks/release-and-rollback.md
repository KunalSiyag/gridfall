# Release and rollback

## Cut a release

1. Make sure `main` is green.
2. `tools/release.sh X.Y.Z --dry-run` previews the notes; `tools/release.sh X.Y.Z` writes `VERSION`, updates `CHANGELOG.md` from Conventional Commits with `tools/changelog.py`, commits and tags `vX.Y.Z`.
3. Push: `git push origin HEAD --follow-tags`. The `release` workflow checks the tag matches `VERSION`, runs the quick gate, exports Linux and Windows builds with `tools/export.sh all`, and publishes a GitHub Release with zips, `SHA256SUMS.txt` and the changelog section as notes. The run summary records version, commit, gate result, release URL and artifact sizes.

## Staged rollout

Gameplay changes ship behind flags in `data/feature_flags.json` with `"default": false`. Testers opt in with `GRIDFALL_FLAGS=<flag>=on` or a `user://feature_flags.json` file (`{"<flag>": true}`) before the default flips. Flip the default in a patch release once it is stable, then delete the flag (`python3 tools/checks/feature_flags.py` reports flags nothing reads any more).

## Roll back

- **Bad feature, good build:** set its flag to `off` in `data/feature_flags.json` and cut a patch release. Players can also run with `GRIDFALL_FLAGS=<flag>=off`.
- **Bad build:** mark the GitHub Release as pre-release (hides it from "latest"), then re-publish the previous tag's artifacts: `gh release edit vX.Y.Z --prerelease` and point players to the previous release. Revert the offending commits on `main` with `git revert` and cut a new patch release. Never delete or move a published tag.

## Verify

The Releases page shows the expected latest version and its download runs `godot`-free on a clean machine.
