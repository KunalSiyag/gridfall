# Asset import problems

## Symptoms

- Pink or missing meshes, `Failed loading resource` errors, or `ext_resource` UID warnings.
- The editor re-imports on every launch, or first launch takes far longer than usual.

## Confirm

1. `godot --headless --path . --import` and read the errors at the end.
2. Check the file is tracked: `git ls-files models/real/<path>`. A missing `.import` sidecar means the asset was never imported in a commit.

## Fix

1. Close Godot.
2. Clear the import cache (safe; it is regenerated): `rm -rf .godot/imported .godot/uid_cache.bin`.
3. Re-import: `godot --headless --path . --import` (several minutes for ~460 MB of assets).
4. If import settings were lost, re-apply them: `python3 tools/optimize_imports.py` then import again.
5. If a GLB itself is broken, rebuild it from source with the Blender scripts in `tools/blender/` (see README, "Running").

## Verify

`tools/gate.sh quick --only fp_assets` passes and the asset shows in game.
