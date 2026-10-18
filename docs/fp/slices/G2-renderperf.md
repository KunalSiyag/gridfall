# Slice G2: Render performance

Branch `fp/G2-renderperf`, branched from `fp/integration` after S0. Read ARCHITECTURE D11, S0 §§15.1, 17.6 and 18. In `understand.md`, read "3D CITY RENDERER", the perf_hotspots sections and CRITIC (a)#3. The current baseline is in `.../scratchpad/logs/fp_bench.log`.

## Goal (what the player sees)

First person runs smoothly on the target laptop: an RTX 3050 Laptop GPU with 4 GB, at 1600×900. The D11 targets are p50 ≤ 16.7 ms, p99 ≤ 33 ms, under 2,000 draw calls and VRAM ≤ 1.5 GB. Quality presets in the pause menu (Low, Medium, High) visibly trade detail for speed. Nothing pops into view at close range.

The measurements say the bottleneck is **draw calls and render CPU** (5.3k draws, 15–17 ms render CPU, 8–12 ms GPU), plus **uncompressed textures** (2.09 GB of VRAM). It is not post-processing. Fix it in that order.

## Owned files (exclusive)

- `scripts/fp/render/**` (entry point `render_opt_feature.gd`, id `render_opt`; `hlod.gd`, `occluders.gd`, `quality.gd`, …)
- `project.godot` `[rendering]` section only
- `tools/optimize_imports.py` (new). Every slice may **run** it on its own files (`--apply <paths>`); only G2 edits it.
- The parameters inside `*.import` files under `models/**` (`compress/mode`, `mipmaps/generate`, `compress/normal_map`, …). Do not change the texture or model *contents*. Import parameters elsewhere belong to the slice that owns the assets: G1 for `textures/real/**` and `env/**`, D for `assets/posters/**`, I for `sounds/fp/**`. Reimport rewrites each file's `[remap]` section, so two slices editing the same `.import` file always conflict; this split prevents it.
- `tools/tests/fp_bench.gd`, inherited from S0
- `tools/tests/fp_renderperf_test.gd`

## Seams consumed

| From | API |
|---|---|
| `CityView` (S0 seams) | `tile_built(i, holder)`, which fires per holder including the full build in `setup` (`in_setup` is true then); `tile_cleared(i)`; `world_rebuilt`; `fp_mode_changed(on)`; `building_aabb(i)` (whole-lot bound, **not** an occluder shape); `tile_holder(i)` (meta `building_path`, `building_xform`); `fp_mode` |
| G1 | `prop` meta on prop roots; `flush_rebuild_queue()`; ranges G1 sets itself (kit cranes, its MultiMeshes and decals) |
| `AP` (H) | `COLBOX_PREFIX` (`ColBox_<n>` empties: preferred body boxes), `<model>_lod` files if H provides them |
| `FpContext` | `view`, `player`, `env`, `sun`, `settings.quality`, `world_root`, `mode` |
| `GameBus` | listens to `quality_changed(preset)`, `settings_changed`, `world_ready` |
| S0 `WS` | `VIS_BUILDING`, `VIS_PROP`, `VIS_PERSON`, `VIS_CAR`, `VIS_SITE_PART`, `CAMERA_FAR`. G2 owns the **values** of `VIS_*` (S0 §4.3). |
| F | `CitySim.slice_stats()` (bench report, when present) |
| G1 | the light profile owns the Environment and Sun values; G2 only sets viewport, `RenderingServer` and project quality knobs |

## Seams G2 may request

- From G1 (already in G1's contract): `prop` meta on prop roots, shared materials of identical props, `_flicker_lights`.

## Seams G2 provides

`scripts/fp/render/quality.gd`, static, readable by every slice without a feature lookup:

```gdscript
static func vis_mult(preset: String) -> float          # 0.7 / 1.0 / 1.3
static func max_street_lights(preset: String) -> int   # 6 / 12 / 16
static func camera_far(preset: String) -> float        # 45 / WS.CAMERA_FAR (60) / 75
```
- From H: lighter LOD meshes or impostor cards for buildings (`<model>_lod.glb`), and atlased materials, at most 3 per building.
- From E: agents set their own `visibility_range_end` (`VIS_CAR`, `VIS_PERSON`).

## Deliverables

### 1. Post-pass on `tile_built` (`hlod.gd`, `occluders.gd`)

On every `tile_built(i, holder)`, when `view.fp_mode` is true (skipped while `view.in_setup`), and for all tiles on `world_rebuilt`:

**Visibility ranges.** `mult = quality.vis_mult(preset)`.

| Target | `visibility_range_end` | Notes |
|---|---|---|
| Holder geometry | `WS.VIS_BUILDING * mult` for building models | `visibility_range_end_margin` 2 u; fade mode Disabled, the cheapest |
| Props (lamps, benches, bins, billboards, shelters) | `VIS_PROP * mult` | |
| Road tiles | `VIS_BUILDING * mult` | |
| Site parts | none from G2 | the construction kit sets its own ranges (`construction_kit.gd:11, 128, 152, 171`) and G1 keeps cranes at 30 |

**Which nodes G2 touches.** A node is a prop when it (or an ancestor up to the holder) has `prop` meta (G1), or, as a fallback for legacy roots, its `scene_file_path` begins with `res://models/real/props/` or `res://models/props/`. G2 **never** touches nodes under a `Site` child, nodes whose `visibility_range_end` is already non-zero (another slice set it), or G1's MultiMeshes and decals (outside holders; G1 ranges them itself). Every node G2 writes gets `set_meta("g2_vis", true)`, which is what the undo and the preset switch walk.

**Shadows.**
- Set `cast_shadow = OFF` on props and on any mesh smaller than 0.05 u.
- Buildings keep their shadows. Their shadow meshes already exist (`create_shadow_meshes=true`).

**Solid kinds.** Occluders and impostors are built **only** for: `ZONE_R` at level ≥ 2; `ZONE_C` and `ZONE_I` at level ≥ 1; and the closed services (city hall, hospital, school, police, fire, university, train station). `building_aabb` merges every mesh including the 0.94 lot slab, trees and spires (`city_view.gd:1155-1172`), and `park.glb`, `wind_farm.glb`, `stadium.glb`, `airport.glb`, `landfill.glb` and `coal_plant.glb` pass a 0.3 u height cutoff, so a box from it would hide everything behind trees, turbines and stacks, plus front yards and side gaps.

**Body box** (per unique `building_path`, cached): the union of mesh AABBs above `LOT_TOP + 0.002`, excluding nodes from `props/` and nodes or surfaces named `Tree*` / `Leaf*` / `*_foliage`; inset 15% in xz and use 0.8 of its height. When the model has H's `ColBox_<n>` empties, use their union instead.

**HLOD and impostors.**
1. Per 8×8-tile chunk, build one merged `ArrayMesh` of box impostors from the body boxes of the solid buildings in the chunk.
2. Use one material with a per-instance tint per model path: the material's `albedo_color` (or a tint table precomputed offline). Never read back VRAM-compressed textures to average them; that is slow and unreliable headless.
3. Impostors start where the holders end, with no overlap: impostor `visibility_range_begin = VIS_BUILDING * mult` with `visibility_range_begin_margin = 2`; holders `visibility_range_end = VIS_BUILDING * mult` with `end_margin = 2`. (A fixed begin of 20 against holders ending at 30–39 drew both from 20 to 30 u, with the box hiding the real building.) Tune `VIS_BUILDING` (G2 owns it, for example 20) rather than overlapping.
4. Rebuild a chunk lazily on `tile_built` / `tile_cleared`, debounced to at most 1 chunk rebuild per frame. Build the **initial** impostors synchronously in `on_world_rebuilt()`.

**Occluders.**
1. One `ArrayOccluder3D` per 8×8 chunk, holding the boxes of its solid buildings (body boxes shrunk as above), inside one `OccluderInstance3D` per chunk, rebuilt with the impostor debounce. Adding or removing an OccluderInstance3D per tile would re-commit the occlusion scene on every change.
2. Put them under a `World/Occluders` node, never under CityView.
3. Occlusion culling is enabled per viewport at runtime in FP (`get_viewport().use_occlusion_culling = true`, restored on teardown), so orbit pays nothing. If a probe shows Godot 4.7.2 needs the project setting, set `rendering/occlusion_culling/use_occlusion_culling=true` in `[rendering]` instead and note the orbit cost in the hand-off (orbit has no occluders).

**Undo.** On `view.fp_mode_changed(false)` and in `teardown()`, restore the defaults on every `g2_vis` node: no ranges, shadows as authored, impostors and occluders hidden.

### 2. `[rendering]` and quality presets (`quality.gd`)

The project defaults, which also serve orbit, change only where orbit is not hurt. Keep `msaa_3d=2` for orbit; the presets override it at runtime in FP.

Each preset is applied at runtime on `quality_changed` and on setup:

| Knob | Low | Medium (default) | High |
|---|---|---|---|
| `Viewport.scaling_3d_mode` / scale | FSR2 / 0.59 | FSR2 / 0.77 | FSR2 / 0.9 (or Native if p99 allows) |
| `Viewport.msaa_3d` | off | off (FSR2 brings TAA) | off |
| `RenderingServer.directional_shadow_atlas_set_size` | 2048, 16-bit | 4096, 16-bit | 4096, 16-bit |
| `directional_soft_shadow_filter_set_quality` | hard | soft low | soft medium |
| `environment_set_ssao_quality` | very low, half size | medium, half size | high |
| `environment_set_ssil_quality` | (off, set by G1) | low, half size | medium |
| Visibility multiplier on `VIS_*` | 0.7 | 1.0 | 1.3 |
| `Camera3D.far` (FP camera) | 45 | `WS.CAMERA_FAR` (60) | 75 |
| `mesh_lod_threshold` (`Viewport.mesh_lod_threshold`) | 2.0 | 1.0 | 0.75 |
| Max street lights (G1 reads `quality.max_street_lights`) | 6 | 12 | 16 |

**Restoring orbit.** In `setup`, snapshot **every** knob G2 touches from its current runtime value or `ProjectSettings` (the `[rendering]` section sets `msaa_3d=2`, `directional_shadow/size=8192`, `soft_shadow_filter_quality=3`, `ssao/quality=3`, `ssil/quality=2`; the viewport scaling mode and scale, `mesh_lod_threshold`, the SSAO and SSIL half-size flags, and occlusion culling), record each setter call, and restore all of them on teardown. Headless has no getter for the atlas size, so the recorded setter values are what the test reads.

**Preset switch.** During the post-pass, cache each holder's `GeometryInstance3D` list and its class (building, prop, road). A switch re-applies from that cache over frames, at most 3 ms per frame, never by re-walking the scene (a full re-walk of about 2,660 active tiles at 0.3 ms each is about 0.8 s).

### 3. Texture VRAM (`tools/optimize_imports.py`)

The script is idempotent and run by hand. It edits `.import` files only.

**Model textures** (`models/real/**/*_{diff,arm,nor_gl}.jpg.import` and the other image imports):
- `compress/mode=2` (VRAM Compressed; BPTC or S3TC on desktop), `mipmaps/generate=true`.
- `nor_gl` files get `compress/normal_map=1`.
- Leaf PNGs keep their alpha and get `mipmaps/generate=true`.

**`textures/real/*.import` and `env/*.hdr.import`** (settings defined here, applied by G1 to its own files): `mipmaps/generate=true`. Ground textures get `compress/mode=2`. HDRs stay as they are, apart from mipmaps.

**Modes:**
- `--check` lists every non-compliant file and exits 1 if there are any.
- `--apply` rewrites them.
- `--report` prints the before/after estimated VRAM.

Then run one heavy `godot --headless --path . --import` under the lock and commit the regenerated `.import` files. The `.godot/` cache is gitignored.

**Scope and paths.** `--apply` and `--check` take optional path arguments, so another slice can apply the settings to its own files; with no arguments they cover `models/**` (G2's) and **report** (never rewrite) other owners' files. The settings for `textures/real/**` and `env/**` (mipmaps on; ground textures VRAM-compressed) are listed in the script so G1 can apply them to its files.

**Merge order.** `optimize_imports.py` lands with G2. G2 merges **before H**; H rebases and runs `--apply` on its re-exported `models/real/**` files (H's step 6.1). Whatever the order, after every merge the integrator runs `python3 -I tools/optimize_imports.py --check` when the script exists; on failure, `--apply`, a heavy `--import` under the lock, commit, then `tools/gate.sh full` (ARCHITECTURE §7).

**Optional stretch: texture dedupe.** 1,595 extracted textures exist, but only 145 are unique by md5. Remap duplicates through the `.glb.import` `_subresources` or an import script to a shared `res://materials/lib/`. Do it only if it is reversible and passes `validate_real.py` (coordinate with H).

### 4. Bench (`tools/tests/fp_bench.gd`)

- Keep S0's labels (including `street_day_end` and the `p50_ms` field) and add `street_eye_nohud_low`, `_medium` and `_high`.
- Report the F stats (`slice_stats`) during `street_tick` and `street_day_end`.
- Add `FPBENCH_ENFORCE=1`. When it is set, the bench fails with `FPBENCH: FAIL <reason>` if `street_eye_nohud` (Medium) has p50 > 16.7 ms, p99 > 33 ms, draws > 2,000 or VRAM > 1,536 MB. The 2,000 draws include E's agents (budget 500) and G1's furniture.
- Without that env var it stays report-only, which is how the gate runs it.

### 5. Feature (`render_opt_feature.gd`)

- Applies the preset on `setup` and on `quality_changed`.
- Owns the post-pass.
- `self_test`:
  - occlusion culling is on for the FP viewport;
  - at least 1 occluder box per 10 solid building tiles;
  - every building holder within 10 u has `visibility_range_end > 0`;
  - the current preset is applied.

## Acceptance tests

`tools/tests/fp_renderperf_test.gd`, token `FP_RENDERPERF_TEST: PASS`. It runs headless with `fp_kit.make_ctx(root, {"view": true, "grow": true, "player": true})`, `view.set_fp_mode(true)`, `view.flush_rebuild_queue()` when it exists, and `make_feature(ctx, "render_opt")`. **Every float comparison uses `is_equal_approx` or a 1e-5 tolerance** (a probe: `scaling_3d_scale = 0.59` reads back 0.58999997377396, and `visibility_range_end = 4.0 * 0.7` fails `==`).

**Visibility ranges.**
- Every building `MeshInstance3D` under a holder has `visibility_range_end ≈ WS.VIS_BUILDING * mult` and carries `g2_vis`.
- Every prop has `≈ VIS_PROP * mult`, and its shadow casting is off.
- No node under a `Site` child, and no node whose range was set before the post-pass, was changed by G2.

**Occluders.**
- Occluder boxes exist only for solid kinds: none on `PARK`, wind-farm or stadium tiles (place them with `sim.apply_action` builds if the grown city has none), and at least one per solid building.
- Every occluder box lies inside its building's body box, and so inside `building_aabb`.
- One `OccluderInstance3D` per chunk with solid buildings, not per tile.
- After `sim.apply_action` bulldoze plus ticks until the tile clears, then `view.flush_rebuild_queue()` (the FP rebuild queue is asynchronous and `fp_kit.ticks` never runs `CityView._process`), the chunk no longer holds that tile's box.

**Impostors.**
- There is one merged impostor mesh per 8×8 chunk that contains solid buildings, already present right after `make_feature` (initial build is synchronous).
- Its `visibility_range_begin ≈` the holders' `visibility_range_end` (`VIS_BUILDING * mult`), with no overlap band.

**Presets.**
- Emitting `quality_changed("low")` sets the viewport `scaling_3d_mode == SCALING_3D_MODE_FSR2` with scale ≈ 0.59 and `msaa_3d == MSAA_DISABLED`. The atlas size is read back through a recorded setter, since headless has no getter.
- `"high"` gives a scale ≈ 0.9, and `quality.camera_far("low") > ` the Low fog end G1 would use.
- A preset switch walks only the cached lists (no `find_children` call on holders; count with a test hook).
- Teardown restores **every** snapshotted knob (native scaling, MSAA 2×, the 8192 atlas, soft-shadow quality 3, SSAO quality 3, SSIL quality 2, half-size flags, `mesh_lod_threshold`, occlusion culling).

**Undo.** `view.set_fp_mode(false)` emits `fp_mode_changed(false)`; after it, no `g2_vis` node keeps a range, and impostors and occluders are hidden.

**Import compliance.** The test runs `OS.execute("python3", ["-I", ProjectSettings.globalize_path("res://tools/optimize_imports.py"), "--check"])`, which must exit 0 for `models/**`. Use `python3 -I` and pass absolute paths as arguments.

**Gate, render mode.** `tools/gate.sh render` shows `street_eye_nohud` improving against the S0 baseline. Attach the before and after FPBENCH tables. Hand-off target: Medium preset with p50 ≤ 16.7 ms, p99 ≤ 33 ms, draws < 2,000 and VRAM ≤ 1.5 GB (report). If the target is missed, list the remaining top costs.

## Performance budget

- The post-pass costs at most **0.3 ms per tile**, and an impostor chunk rebuild at most 4 ms. Rebuilds are debounced to one chunk per frame.
- At most about 1,500 occluder boxes (the number of buildings in a fully built core), in one `ArrayOccluder3D` per chunk.
- The preset switch re-applies from cached lists over frames, at most 3 ms per frame (no single 100 ms+ stall).

## Risks

- **Import churn.** The import change triggers a full re-import (about 85 s, 2.2 GB). Every worktree must re-import after merging. Note this in the hand-off.
- **FSR2 ghosting.** FSR2 can ghost thin geometry and fast agents. If it is objectionable on Medium, fall back to TAA plus `scaling_3d` bilinear.
- **Occluders.** Wrong boxes cull visible geometry. Keep them to solid kinds and body boxes, and verify with the photo tour.
- **Visibility ranges and shadows.** A range applies to shadow casting too. Distant towers lose their shadows beyond 30 u, which is accepted behind fog.
- **Headless renderer.** It cannot measure performance. Every perf claim must come from `gate.sh render` on the real GPU, one at a time under the lock.

## Do NOT touch

- `city_view.gd` (request meta from G1) and the Environment and Sun values (G1).
- Model and texture contents (H).
- `project.godot` sections other than `[rendering]`.
- `main.gd`, the S0 files and other slices' files.
