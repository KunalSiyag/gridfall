---
name: gridfall-assets
description: Add, re-import or optimise GridFall 3D assets (models/real, Blender pipeline, Godot import settings, licenses). Use when adding models, textures or HDRIs or when imports break.
---

# Assets

1. Source models come from the Blender scripts in `tools/blender/` or CC0 sources (Poly Haven, Kenney). Record the license in `models/LICENSES/` or `models/real/LICENSES/`.
2. Put the file under `models/real/<group>/`. Keep each file under 5 MB where possible; `tools/checks/large_files.py` and the pre-commit hook reject files over 12 MB.
3. Apply the shared import settings: `python3 tools/optimize_imports.py`, then `godot --headless --path . --import`.
4. Reference new paths through `scripts/fp/asset_paths.gd` (first person) or the model tables in `scripts/world/city_view.gd` (orbit view), keeping a fallback for missing files.
5. Validate: `tools/gate.sh quick --only fp_assets`, and look at it in game or with `tools/gate.sh render`.
6. If imports break, follow `docs/runbooks/asset-import.md`.
