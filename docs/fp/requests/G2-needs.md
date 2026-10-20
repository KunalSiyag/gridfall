# G2 needs

Requests from G2 (render performance) to the slices that own the files involved, and notes for the
integrator. Values are in world units (1 u = 20 m) unless metres are given.

## To the integrator

1. **Re-import after merging G2.** G2 switches every texture import under `models/**` (except
   `models/characters/**`) to VRAM compression with mipmaps, and normal maps to RGTC. The first
   `tools/gate.sh` run after the merge re-imports them (about 1,645 textures; a warm cache takes a
   few minutes, a cold one about 85 s more). Old uncompressed `.ctex` files stay in `.godot/imported`
   (about 400 MB per worktree); they are cache and can be deleted.
2. **After every later merge** run `python3 -I tools/optimize_imports.py --check`. On failure:
   `--apply`, a heavy `godot --headless --path . --import` under the lock, commit, then
   `tools/gate.sh full` (ARCHITECTURE §7).
3. **Re-bake the building proxies when building models change** (H's re-export, new zone models):
   `godot --headless --path . -s res://scripts/fp/render/proxy_bake.gd` rewrites
   `scripts/fp/render/proxies.json` and the merged mid-LOD meshes in `models/real/midlod/`
   (62 meshes, about 4 MB; about 5 s in all). A model missing from the bake still gets a far
   impostor and an occluder, from its surface bounds, but as a plain grey box; a mesh without a
   fresh mid-LOD bake is merged at runtime, which stalls 10 to 140 ms on its first instance while
   its arrays are read back from the GPU. `fp_renderperf_test` fails while any bake is stale.

4. **Resolved after the reboot:** Vulkan uses the RTX 3050 again (fp_bench, 2026-10-20).
   **The RTX 3050 is unavailable on this machine until a reboot.** The NVIDIA kernel module
   (580.173) and its user-space libraries (580.178) no longer match, so Vulkan lists only the AMD
   Renoir iGPU and llvmpipe, and every windowed run (gate render, fp_bench) now renders on the
   iGPU: frame times are about 4x the S0 gate's. Draw calls, render CPU and VRAM still compare;
   D11's millisecond targets can only be judged on the RTX 3050 after a reboot.
5. **Deviations from the G2 contract, on purpose.** (a) Holder ranges have no hysteresis margin
   (the contract said 2 u): the impostor shader and the mid-LOD twins switch at exactly the
   engine's distance, and a margin would leave a band where both or neither draw. (b) Buildings
   have three levels (real, merged twin from `VIS_BUILDING_NEAR`, chunk impostor from
   `VIS_BUILDING`), so building meshes end at `VIS_BUILDING_NEAR`; `VIS_BUILDING` is 15 u.
   (c) Impostors are stepped mass proxies from an offline bake, not plain body boxes, and cover
   every zone level (R1 houses too) plus coal, pump, sewage and stadium; occluders stay on the
   contract's solid kinds. (d) No `[rendering]` change: runtime `use_occlusion_culling` works on
   4.7.2 (a probe culled 7% of objects with it), so orbit pays nothing.

## To G1 (streetscape)

1. **Construction sites are now the largest draw-call cost on foot (please act).** Measured on a
   local trial merge of `fp/G1` + `fp/G2` (day 6, 1600x900, Medium, the bench's
   `street_cross_nohud` pose): 2,243 draws in all, 1,191 with every `Site` hidden, so the sites
   cost about 1,050 draws in that one view. The city holds 7,976 site parts: 5,416 of them end at
   `CRANE_FAR` (30 u) because `construction_kit.gd` gives that range to every part whose bound is
   longer than 0.25 u (scaffold runs, hoarding segments, slabs, nets), only 2,443 end at
   `WS.VIS_SITE_PART` (8 u, G2's value), and lowering that to 4 u saved only 26 draws. Suggested,
   in order of payoff: (a) keep `CRANE_FAR` for the crane mast and jib only and give everything
   else `VIS_SITE_PART * vis_mult`; (b) merge each site's static parts into one mesh per material
   (the scaffold alone is hundreds of `MeshInstance3D`s); (c) a site's far look can be its hoarding
   plus the crane. G2 never touches nodes under `Site` (contract), so this one is yours.
2. **Your texture imports.** `textures/real/**` (ground: VRAM compressed with mipmaps, normal maps
   RGTC) and `env/**` (mipmaps) are not compliant yet: 196 MB of ground textures become 44 MB.
   Apply with `python3 -I tools/optimize_imports.py --apply textures/real env` and re-import.
3. **G2 ranges what it finds in tile holders on `tile_built`** and never touches a part whose
   `visibility_range_begin` or `_end` is already set, nor anything under a `Site` child, nor your
   MultiMeshes and decals outside holders. Props are recognised by your `prop` meta (or a
   `res://models/real/props/` / `res://models/props/` scene path); they end at
   `WS.VIS_PROP * vis_mult` and cast no shadow.
4. **Building LODs.** Every building mesh with 3+ surfaces (and every road piece's mesh) gets a
   merged one-surface twin as a child (`G2Mid`, metas `g2_mid` and `fp_owner`), drawn from
   `WS.VIS_BUILDING_NEAR * vis_mult` (80 m on Medium) to `WS.VIS_BUILDING * vis_mult` (300 m);
   past that, chunk impostors. Each switch is at one exact distance from the mesh's bounding-box
   centre, with no hysteresis margin. The twins copy your on-foot look: lit windows use your
   `window_fp.gdshader` room cells and hash (same rooms lit), glass follows `_glass_mat`. If you
   change either, tell G2 (`midlod.gdshader`, `impostor.gdshader`). If you replace a model's mesh
   nodes after `tile_built`, emit `tile_built` again or the new parts stay unranged. Twins do not
   get wet in rain.
5. `quality.camera_far()`, `vis_mult()` and `max_street_lights()` exist as static functions in
   `scripts/fp/render/quality.gd`, as your fallbacks expect. G2 sets the first-person camera's
   `far` on every preset change.

## To H (assets)

1. **Lighter far meshes.** Building GLBs average 17 to 30 surfaces, so a building costs that many
   draw calls up close. Atlased materials (at most 3 per building) would cut near-field draws the
   most. G2 handles the far field itself (merged chunk impostors).
2. After re-exporting `models/real/**`, run `--apply` on your files (your step 6.1) and re-bake the
   proxies (integrator note 3).

## To E (traffic)

1. Set `visibility_range_end` on your agents (`WS.VIS_CAR`, `WS.VIS_PERSON`, times
   `quality.vis_mult(preset)`); G2 does not walk agent nodes.
2. `anim_stats()` is read by `fp_bench` in every row; report `anim_us` and `char_draws` once E2
   lands, and the bench enforces the T9 budget (1,500 µs, 150 character draws) with
   `FPBENCH_ENFORCE=1`.

## To A (player)

1. The bench records `camera` from `player.camera_mode` and, when present, the hero's animation
   cost from `player.avatar.anim_us` (µs per frame) and the rig's `rig.update_us`. Please expose
   `anim_us` on the avatar when A2 wires the AnimationTree.
2. G2 writes `player.camera.far` on every preset change (45 / 60 / 75); keep A's code from
   resetting it outside `setup`.
