---
name: gridfall-fp-feature
description: Add or change a first/third-person feature module under scripts/fp/ (FpFeature lifecycle, registry, game bus, save state, tests). Use when building new street-level gameplay, HUD widgets or camera modes.
---

# Adding a first-person feature

1. Create `scripts/fp/<feature>/<feature>_feature.gd` with `extends FpFeature`. Implement `feature_id()`, `setup(ctx)`, and as needed `on_world_rebuilt()`, `to_dict()/from_dict()`, `teardown()`, `pick()`, `self_test()`, `photo_shots()` (see `scripts/fp/fp_feature.gd`).
2. Register it once in `scripts/fp/fp_features.gd` (`id`, `slice`, `path`). Update the feature count in `tools/tests/fp_core_test.gd`.
3. Talk to other features through `ctx.bus` (`scripts/fp/game_bus.gd`) signals. Do not reach into another feature's nodes; `tools/checks/boundaries.py` fails the build if you preload another feature's folder.
4. Read the city through `ctx.sim`, `ctx.view`, `ctx.residents`; never mutate sim state except through `CitySim` actions.
5. If it changes gameplay, add a flag to `data/feature_flags.json` and check it with `FeatureFlags.enabled("<flag>")` (each feature's registry id is already a flag; FpMode skips disabled ones).
6. Input: add actions to `project.godot` `[input]` (keyboard and joypad), and document keys in the pause-menu legend (`scripts/fp/ui/pause_menu.gd`) and README.
7. Test: add `tools/tests/fp_<feature>_test.gd` (copy the structure of `tools/tests/fp_overview_test.gd`), then run `tools/gate.sh quick --only fp_<feature>` and the full gate.
8. Document the module in `docs/fp/ARCHITECTURE.md`.
