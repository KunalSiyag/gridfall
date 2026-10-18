# Slice G1: Streetscape and look

Branch `fp/G1-streetscape`, branched from `fp/integration` after S0. Read ARCHITECTURE D1, D8 and D11, S0 §§4, 5, 14 and 15.1. In `understand.md`, read "3D CITY RENDERER" and "LOOK & ASSETS".

## Goal (what the player sees)

At eye level GridFall looks like a real city street:

- **Human-scale buildings.** People, cars, doors and storeys all match.
- **Buildings face the street.** Shopfronts and doors look onto the sidewalk instead of showing their backs at random.
- **A street-level ground.** Crisp, non-repeating grass and paving; continuous sidewalks and verges with no ledges; water lies below the banks instead of floating as a glass slab.
- **Street furniture on the sidewalks.** Lamps, benches, bins, bollards, bus shelters, street-name signs at junctions, and crosswalk ramps.
- **A first-person light profile.** Sharp near shadows, contact AO in metres, and depth fog that hides the far plane.
- **Night.** Real light pools under nearby lamps.
- **Weather.** Clear, overcast and rain, with wet roads.
- **Construction.** Sites at the right scale.
- **No rebuild hitches.** Tile rebuilds are spread across frames, nearest first.

## Owned files (exclusive)

- `scripts/world/city_view.gd`. Keep every S0 seam:
  - the `tile_built`, `tile_cleared` and `world_rebuilt` signals and their emission semantics;
  - `building_aabb`, `tile_holder`, `set_camera` and `fp_mode` / `set_fp_mode` with the §15.1 hiding list;
  - the `display` labels.

  Keep the public and pseudo-public API others use:
  - `setup`, `set_overlay`, `set_night`, `night`;
  - `bus_stops`, `life`, `avatars`, `kit`;
  - `show_mayor_decision`, `show_mayor_thinking`, `show_citizen_voices`, `avatar_position`;
  - `screen_to_tile`, `tile_world`;
  - `_scene`, `_inst`, `_mat`, `_pbr`, `_add_smoke`, `_road_neighbors`, `_random_road`, `_power_icons`, `_water_icons`.
- `scripts/world/construction_kit.gd`
- `scripts/world/sky_director.gd`. Keep the S0 `MIN_CYCLE_DAY_SECONDS` hold rule, `fixed_hour`, `clock_text()`, `night` and `setup` signature.
- `scenes/main-environment.tres`. This is the **orbit** profile; keep its values.
- `shaders/**` (new shaders welcome; leave the dead `building_power` and `road_conduit` alone)
- `scripts/fp/street/**` (entry point `streetscape_feature.gd`, id `streetscape`; `light_profile.gd`, `weather.gd`, `street_lights.gd`, …)
- `textures/real/**` and `env/**`: the contents **and** the `.import` parameters (G2 owns only `models/**` imports). Today every `textures/real/*.import` and `env/*.hdr.import` has `mipmaps/generate=false` and `compress/mode=0`; G1 sets mipmaps on (and VRAM compression for ground textures) with `tools/optimize_imports.py --apply <paths>` once G2's script exists, or by hand with the same values before that, and commits the re-imported `.import` files.
- `tools/tests/fp_streetscape_test.gd`

## Seams consumed

| From | API |
|---|---|
| S0 `WS` | `REAL_SCALE`, `MACHINE_SCALE`, `GROUND_Y`, `LOT_TOP`, `PAD_TOP`, `WATER_Y`, `RIVERBED_Y`, `SIDEWALK_*`, `ROAD_HALF`, `ZEBRA_*`, `SHADOW_MAX_DIST`, `SSAO_RADIUS`, `SSIL_RADIUS`, `FOG_DEPTH_BEGIN` / `END`, `CAMERA_FAR`, `VIS_SITE_PART`, `M`. G1 **owns the values** of `GROUND_Y`, `WATER_Y`, `LOT_TOP` and `PAD_TOP` (S0 §4.3) and changes them in the same commit that changes the geometry. |
| S0 `CityDirectory` | `frontage(i)`, `frontage_yaw(i)` (the single rule for which way a lot faces; build your own instance with `CityDirectory.new().setup(sim)` so it also works in orbit), `street_name`, `intersection_name` |
| S0 `RoadTopology` | `mask`, `piece`, `arms`, `sidewalk_point`, `is_bridge` |
| `FpContext` (feature) | `env`, `sun`, `sky`, `view`, `player` (position for rebuild priority and lights), `settings.quality` |
| `GameBus` | listens to `quality_changed(preset)`, `pause_changed`, `world_ready` |
| G2 `scripts/fp/render/quality.gd` (static, optional) | `vis_mult(preset)`, `max_street_lights(preset)`, `camera_far(preset)`. Until G2 lands, use 1.0, 12 and `WS.CAMERA_FAR`. |
| E traffic feature (optional) | `light_pole(i, corner)` on cross tiles, for the street-name blades |
| `AP` (H) | `load_scene()`, `STREET_SIGN`, `BUS_SHELTER`, `BILLBOARD_POSTER`, `TRAFFIC_LIGHT` (E places the lights on all four corners of cross tiles), `CROSSWALK_RAMP`, `BOLLARD`, `BIKE_RACK`, `PARKING_METER`, `LEASE_SIGN`; fall back when missing |

## Seams G1 provides (contract with other slices)

- **Building orientation.** Zone and service models get `rotation_degrees.y = directory.frontage_yaw(i)` when it is finite, and the old `(h % 4) * 90` otherwise. Do this in both `_build_tile` (line 962) and `_model_for` (1150). Give `_model_for` an optional tile index argument.
- **`var priority_point: Vector3`.** The streetscape feature sets it every frame to the player position. The rebuild queue uses it.
- **`poster_slot` meta** (D, A): `{"kind": "billboard"|"bus_shelter"|"hoarding"|"lease", "size": Vector2, "xform": Transform3D}`, on billboards, bus shelters, the construction kit's frontage fence segment (kind `"hoarding"`; the kit already fences the lot at ±0.47 with a gate gap, `construction_kit.gd:641-654`) and FP lease boards. The billboard poster rect is `(0.34, 0.15)` at local `(0, 0.275, 0.006)`.
- **`colliders` meta** (A): every furniture placement — **batched into a MultiMesh or not** — is also appended to its road holder's `holder.set_meta("colliders", [{"shape": "cyl"|"box", "pos": Vector3 (holder-local), "r": float | "size": Vector3, "yaw": float}])`, written **before** `tile_built` fires for that holder. A reads only this meta when it exists, so batched furniture (which has no nodes to scan) still blocks.
- **Site `colliders` meta** (A; added by S0 in fix round 2, `S0-foundation.md` §15.1): `ConstructionKit.build_site` bakes every part marked with `solid(node)` / `solid_box(node, aabb)` into `site.set_meta("colliders", [{"shape": "box", "pos": Vector3 (centre of the base, holder-local), "size": Vector3, "yaw": float}])` on the `Site` node before `tile_built`; `CityView.site_boxes(i)` reads it and `fp_seams_test` checks that every drawn part a walker can bump into lies in one of them. The boxes are measured from the meshes, so G1's `MACHINE_SCALE` and `REAL_SCALE` changes carry over by themselves; **G1 marks every new blocking part it adds to the kit** (and leaves progress-revealed groups unmarked, or names them in the test's `PROGRESS_GROUPS`). Use the same `pos` convention (centre of the base) for the furniture `colliders` above, so A has one reader. Open placement issues: `docs/fp/requests/S0-needs.md`.
- **`prop` meta** (G2): `set_meta("prop", true)` on every prop root G1 places, including the legacy `_add_zone_prop` and `_maybe_bus_stop` roots (which carry no marker today, `city_view.gd:1210-1250`). G1 applies `VIS_PROP * vis_mult` and shadows-off to its own MultiMeshes and decals, which sit outside holders where G2's post-pass cannot see them.
- **`bus_stops[i]`** stores the shelter side as a `Vector2i` (the `dv` of `_maybe_bus_stop`) instead of `true`; `has()` semantics are unchanged (E reads it).
- **Rebuild queue API:** `flush_rebuild_queue() -> void` builds everything pending synchronously and emits `tile_built` for each; `rebuild_pending() -> int`. `setup()` clears the queue. Tests of other slices (G2, I) call the flush after ticking; S0's `grow_offline` calls it (S0 §6.2).
- **`set_fp_mode(on)` rebuilds on a real change.** S0's version only toggles visibility, so FP-only geometry (lots, pads, furniture, tree chunks, FX) would stay in orbit form until each tile changed. When the value changes, G1's version runs `_build_trees()`, `_refresh_trees()` and `rebuild_all(false)` synchronously (bypassing the queue), then emits `world_rebuilt` and S0's `fp_mode_changed`. At boot the field is already set before the first `setup` (S0 §6.1), so the boot path builds once.
- **Light profile API** (`scripts/fp/street/light_profile.gd`, static): `apply(env: Environment, sun: DirectionalLight3D, mode: String, preset: String)`, with mode `"fp"` or `"orbit"`. `apply(..., "orbit", ...)` must restore the orbit values **exactly**, because `exit_fp()` relies on it (rules in the light-profile section).
- **SkyDirector weather hooks:** `var weather_energy_mult := 1.0`, `var weather_exposure_mult := 1.0`, `var fog_begin_override := -1.0`, read inside `_apply` (`sky_director.gd:89-98` rewrites sun energy, colour, ambient, fog colour and exposure every frame, so multipliers applied from outside would be overwritten on the next frame).

## Deliverables: everything in `city_view.gd` (and friends) that changes for street level

### Scale (applies to orbit too; there is one world)

| Where | Today | Change |
|---|---|---|
| `city_view.gd:44` `REAL_SCALE := 0.9` | buildings at 0.9, so lots are 0.846 with 0.077 gaps | `REAL_SCALE := WS.REAL_SCALE` (1.0). This also affects `_model_scale` (1128–1130), the zone scale at 954–962, the services at 1012–1013 and `_model_bounds` (site footprints grow 11%). |
| `construction_kit.gd:9` `MS = 1/16` | machines too big | `WS.MACHINE_SCALE` |
| `construction_kit.gd:11` `FAR = 70` | 1.4 km cull on 8 cm rebar | `WS.VIS_SITE_PART` (8) for small parts; keep the large crane parts at 30 |
| `city_view.gd:1775`, ambient Kenney cars ×0.17 | off in FP (S0) | leave for orbit |

People and vehicle scale belong to E (`resident_avatars.gd:158`, `city_life.gd`).

### Orientation and lots

- **Yaw.** Use the frontage yaw described above, for zones and services.
- **Level-0 lots** (937–939: emissive pad; 966–974: glowing post). In FP, replace them with a dirt or grass lot, plus a "For lease" sign. Use `AP.LEASE_SIGN`, or else a procedural board, at the frontage edge with `poster_slot` kind `"lease"`. Orbit keeps today's pads.
- **C and I pads** (930–947, y 0.006). The pad hides the model's own lot details. In FP, drop the pad for real models, since the lot slab is in the GLB. Otherwise lower it to `LOT_TOP + 0.0002`, with metric texture tiling (`uv1_scale = 1 / (3.0 * M)`).
- **Gaps between the lot edge (0.47) and the tile edge (0.5).** Fill them with a verge strip: grass at `GROUND_Y` on lot sides, and a sidewalk apron at the frontage to meet the road sidewalk.

### Ground, water, curbs and markings

**Ground** (`_build_ground` 272–302).
- Raise the base plane from `-0.012` to the new `WS.GROUND_Y`. Recommended: `0.0`. That puts the ground 0.009 u (18 cm) below the sidewalk top, within A's `STEP_HEIGHT` of 0.0125 u (25 cm).
- Build it as merged chunk meshes that **exclude water tiles**, instead of the single 252×252 plane.
- Use metric anti-tiling grass: a new `shaders/ground_detail.gdshader` with a detail layer (1 repeat per 3 m, `uv1_scale = 1 / (3.0 * M)`), a macro variation layer (1 per 40 m), and stochastic or hex tiling or a hash-rotated UV.

**Water** (284–302 and `shaders/water.gdshader`).
- Surface at the new `WS.WATER_Y` (recommended `-0.03`, 60 cm below the datum) and the riverbed at `RIVERBED_Y` (recommended `-0.08`).
- Bank skirts: vertical or sloped quads along every water–land edge, using `dirt` and `rock` PBR.
- Shader tiling per metre (`tiling = 1 / (8 * M)`), depth fade and shore foam, and keep it opaque if reflections cost too much.
- Bridges (`road_bridge.glb`, deck at 0.003) now visibly span the water.

**Road wear and variety.**
- Decal nodes (`Decal`) per road tile, seeded by `hash(i)`: cracks, patches, oil, manholes. Allow 0–3 per tile. `Decal` has no `visibility_range_end` (it is not a GeometryInstance3D; probe-confirmed), so use `distance_fade_enabled = true`, `distance_fade_begin = 2.5`, `distance_fade_length = 0.5`.
- Crosswalk ramps (`AP.CROSSWALK_RAMP`) at the zebra ends on tee and cross tiles.
- Do not move the GLB markings. E's lane graph reads `WS`.

**Wet roads.** `_tune_materials` (204–216) instantiates each scene once and calls the static `_tune_material` (219–245) per shared material; for the `MATTE_PREFIXES` it flattens roughness to 0.92 on `Roof*`, `Gravel*`, `Asphalt*` and `Sidewalk*` (not `Curb*`). Keep the dry look, but add a wetness parameter driven by `weather.gd`: lower roughness, darker albedo, and a puddle mask from a noise texture through `detail_mask` or a `next_pass` shader. A **global** shader uniform needs `RenderingServer.global_shader_parameter_add("wetness", …)` at runtime (in the streetscape feature's `setup`, removed in `teardown`), because G1 owns no `project.godot` section.

### Street furniture (replaces lot-corner props in FP)

**`_add_zone_prop`** (1210–1226) puts props at the lot corners `(±0.4, ±0.4)` with random yaw, where they can intersect buildings.
- In FP, place furniture on **road-tile sidewalks** instead, seeded per road tile:
  - lit straights keep their GLB lamps (baked at ±0.34, inside `WS.CURB_FURNITURE`);
  - other straights get 0–2 items from {bench, bin, bollard pair, tree pit with `tree_small`, bike rack, parking meter};
  - lamps, bins, bollards, signs and tree pits sit in `WS.CURB_FURNITURE` ([0.305, 0.345] from the centreline); benches, bike racks and meters in `WS.FRONT_FURNITURE` ([0.415, 0.49]); nothing in `WS.PED_BAND` ([0.355, 0.405]), which E's pedestrians walk. Items are oriented to the road and spaced at least 0.12 apart.
  - every item gets `prop` meta and a `colliders` entry on its holder, batched or not.
- Commercial lots keep **billboards**, at the lot frontage edge facing the road, with `poster_slot` meta. Use `AP.first_existing([AP.BILLBOARD_POSTER, "res://models/real/props/billboard.glb"])`, so H's billboard (with its `Poster_0` surface) replaces the legacy one when it exists.
- Orbit keeps the old corner props.

**Bus stops** (`_maybe_bus_stop` 1230–1250). In FP use `AP.BUS_SHELTER` when it exists (H's shelter is 1.5 m = 0.075 u deep, with a `Poster_0` surface), centred at 0.4525 inside `FRONT_FURNITURE` (it spans 0.415–0.49, clear of the pedestrian band; the gf shelter at 0.43 is 0.15 deep and would block the band), facing the road, with `poster_slot` and `prop` meta. `bus_stops[i]` stores the side as a `Vector2i` (`has()` unchanged).

**Street-name signs.**
- **Tee tiles:** one pole at the free corner opposite the stem (`(±0.44, ±0.44)`), in `CURB_FURNITURE` radially. Two blades carry `directory.street_name` for each run, using `AP.STREET_SIGN`.
- **Cross tiles:** no pole of G1's own: E puts traffic lights on all four corners. The blades mount on E's NE light pole (`traffic.light_pole(i, 0)`, H's `SignText_A` / `SignText_B` empties on `traffic_light.glb`). Until E lands (or with no traffic feature, as in orbit), place G1's own pole at the NE corner; E removes it when it places its light. Record the agreement in `docs/fp/requests/E-G1-corners.md`.
- When the asset is missing, use a procedural pole plus `Label3D` blades with `no_depth_test = false`, `pixel_size = 0.00035`, white on green.

### Trees (422–597)

- In FP, the **near** kits use 8×8-tile chunks and `TREE_NEAR` 120 becomes **12** (240 m), with near margins 1.5 instead of 6. The **far** low-poly layer keeps large chunks (32 or 48 tiles) with `visibility_range_end = 50` and margin 2; beyond that the fog takes over. (One MultiMeshInstance3D per tree part per chunk, and the far layer has no end distance today, `city_view.gd:528-597`: at 8-tile far chunks about 120 chunks lie within 50 u against about 4 at 48, which would multiply far-layer draws against D11's 2,000.)
- Shadows only from the near layer within 6 u.
- Leaf cards use alpha hash (or alpha scissor) with FSR2's temporal AA, **not** alpha-to-coverage: that needs MSAA, and every G2 preset turns MSAA off.
- Optional: wind sway in a vertex shader.
- Rebuilding the chunks on a mode switch is acceptable (it happens inside `set_fp_mode`'s rebuild). Orbit keeps 48 and 120.

### FX at street scale (in FP; orbit keeps today's values)

| Effect | Today | FP |
|---|---|---|
| Fire `_add_fire` (1419–1446) | particle radius 0.08, velocity 0.5–1.0 u/s, emission box 0.3 | radius `0.6 * M`, velocity `2.0–3.0 * M` per second, box = building footprint × 0.4; light range 2.2 is kept (44 m) |
| Smoke `_add_smoke` (1394–1417) | velocity 0.25–0.4 | `1.5–2.5 * M`, scaled 0.6 |
| Dust puff and grow tween (1036–1041, 1449–1469) | 0.55 s squash-and-grow plus puff | no squash; a small dust puff only within 4 u of the player |
| Smog event (1625–1636) | 7 translucent balls of radius 1–1.6 at y 1.2–1.7 | an env fog tint ramp near the event; on High, a `FogVolume` box over the radius |
| Flood (1637–1646) | planes at y 0.12 (2.4 m) | y = `GROUND_Y + 0.008`, with the water shader |
| Flicker loop (1920–1923) | scans every tile child every frame | keep a `_flicker_lights` list maintained in `_add_fire` and `_build_tile` (a perf fix for both modes) |

### Light profile (`scripts/fp/street/light_profile.gd`), values in world units

| Setting | Orbit (today, restore exactly) | FP Medium | FP Low | FP High |
|---|---|---|---|---|
| Sun `directional_shadow_max_distance` | 90 | `WS.SHADOW_MAX_DIST` (12) | 8 | 16 |
| Sun PSSM splits 1, 2, 3 | 0.1, 0.2, 0.5 (defaults) | 0.06, 0.16, 0.4 | 0.1, 0.3, 0.6 (2 splits) | 0.05, 0.14, 0.38 |
| Sun `blend_splits` | false | true | false | true |
| `ssao_radius` / `ssao_intensity` | 0.35 / 1.6 | `WS.SSAO_RADIUS` (0.05) / 1.2 | 0.05 / 1.0 | 0.05 / 1.3 |
| `ssil_radius` / `ssil_intensity` | 1.5 / 0.7 | `WS.SSIL_RADIUS` (0.25) / 0.6 | off | 0.25 / 0.7 |
| Fog | exponential, density 0.0045, aerial 0.55, sky_affect 0.25 | `FOG_MODE_DEPTH`, begin `FOG_DEPTH_BEGIN` (20), end `min(FOG_DEPTH_END, 0.95 * camera_far(preset))`, curve 1.4, **density 1.0** (0.9 leaves 10% of geometry visible up to the far-plane cut), aerial 0.35, sky_affect 0.6 | same (end ≤ 0.95 × 45 = 42.75; the old 50 was beyond Low's far plane of 45) | same |
| Volumetric fog | off | off | off | on: length 6.0, density 0.008, detail_spread 2, anisotropy 0.3, temporal reprojection |
| Sky `process_mode` | REALTIME, radiance 256 (set by SkyDirector, `sky_director.gd:41-42`, not by the `.tres`) | INCREMENTAL | INCREMENTAL, radiance 64 | INCREMENTAL, radiance 256 |

Further light-profile items:
- Tune the Sun shadow bias and normal bias for 8 cm details: start at bias 0.02 and normal_bias 0.6, then verify on the photo tour.
- **Restoring orbit exactly.** SkyDirector replaces the `.tres` sky with its own REALTIME radiance-256 sky and rewrites sun energy, colour and shadow, ambient, fog colour and exposure every frame (`sky_director.gd:34-46, 89-98`), and `main.gd:104-105` owns `crisis`. So the orbit values are not the `.tres` file's: `light_profile` **snapshots** every key it owns on its first FP apply (or reads them from a `ResourceLoader.CACHE_MODE_IGNORE` load of the `.tres` and from the `main.tscn` Sun for keys SkyDirector never writes) and restores **only the keys it owns**: the table rows above plus `directional_shadow_mode`, `shadow_bias`, `shadow_normal_bias`, `directional_shadow_split_*`, `directional_shadow_blend_splits`, and the sky `process_mode` and `radiance_size`. Keys SkyDirector writes every frame are never touched by `light_profile`.
- The dusk HDRI `env/sky_night.hdr` has city silhouettes on the horizon. Replace it in FP with a pure-sky dusk HDRI: add one to `tools/polyhaven_fetch.py` and fetch it. Keep the old one for orbit unless the replacement looks equal from above.
- Apply the profile on `setup` with the current preset, re-apply on `quality_changed`, and apply `"orbit"` on teardown.
- G2 owns `project.godot` `[rendering]` and the atlas size and FSR. G1 only sets Environment and Sun properties.

### Night lighting

- Keep the emissive bulbs and the fake light pools (1287–1314).
- Add `street_lights.gd`: a pool of at most `quality.max_street_lights(preset)` `OmniLight3D`s (6 / 12 / 16 for Low / Medium / High; 12 until G2 lands), no shadows, range `12 * M`, energy following `view.night`.
- At 4 Hz, re-assign them to the nearest `Bulb_*` nodes within 4 u of the player. Collect the bulbs per tile on `tile_built`.

### Weather (`scripts/fp/street/weather.gd`)

- A deterministic daily state from `hash(city_seed, day)`: clear 60%, overcast 25%, rain 15%. Events with a `weather` key in `D.DISASTERS` force it.
- **Overcast:** `sky.weather_energy_mult = 0.55`, a sky tint, `sky.fog_begin_override = 15`.
- **Rain:** GPUParticles3D in a 1-unit box following the camera (streaks, about 3,000 particles on High and 800 on Low), wetness 0→1 over **120 real seconds at 1×** (scaled by `sim.speed`; "2 game-minutes" would be 1.7 s in FP and 0.02 s at the kit's 12 s day), and a darker exposure through `sky.weather_exposure_mult`.
- Save it in `to_dict` as `{"weather": state, "wet": f}`.
- Test and photo hooks on the streetscape feature: `force_weather(state: String)`, `force_rain_for_photo()` (forces rain with wetness 1 at once) and `clear_forced_weather()`. The last two are the `"prepare"` / `"restore"` methods of the `"rain"` photo shot (S0 §10.1, no arguments).

### Budgeted rebuild queue (`_on_tiles_changed` 787–800)

- **In FP only.** Enqueue the changed tiles and their road neighbours. `_process` builds them nearest-first to `priority_point` until `rebuild_budget_ms` (3.0) is spent, at a minimum of one tile per frame. Each built tile emits `tile_built`; the emission time counts inside the budget, and `tile_built` listeners (A, D, G2, I) must be O(1) per tile.
- Tiles within 1.5 u of the player are deferred until the player looks away (`not camera.is_position_in_frustum(tile_centre)`), or for at most 5 s of accumulated delta, so buildings do not pop next to you. Deferred tiles do not count toward the one-tile minimum.
- **No first-load stalls.** `_scene` loads synchronously and `_tune_materials` instantiates each model once (`city_view.gd:192-216`), and there are 38 zone and 16 service GLBs (5–13 MB per folder). At FP setup, warm every `_zone_options`, service and prop path with `ResourceLoader.load_threaded_request`, spread over frames; the queue re-queues a tile whose scene is not loaded yet instead of loading it on the main thread.
- `flush_rebuild_queue()` and `rebuild_pending()` (seams above); `setup()` clears the queue.
- **Orbit keeps the synchronous rebuild**, so the legacy smoke and tests are unchanged.
- `rebuild_all` (inside `setup`) stays synchronous.

### Streetscape feature (`scripts/fp/street/streetscape_feature.gd`)

- `setup`: apply the light profile, add the `wetness` global shader parameter, start the weather and street lights, warm the scene cache, and set `view.priority_point` every frame.
- `to_dict`: weather.
- `self_test`: the profile is applied (`is_equal_approx(env.ssao_radius, WS.SSAO_RADIUS)`), and building yaws match the frontage on 10 sampled lots.
- `photo_shots`: `"street_sign"` (a junction sign at 6 m) and `"rain"` (street pose, hour 16, `"prepare": "force_rain_for_photo"`, `"restore": "clear_forced_weather"`).

## Acceptance tests

`tools/tests/fp_streetscape_test.gd`, token `FP_STREETSCAPE_TEST: PASS`. It uses `fp_kit.make_ctx(root, {"view": true, "grow": true, "render": true})` (a private `CACHE_MODE_IGNORE` copy of the environment, the `main.tscn` Sun and a SkyDirector), then `view.set_fp_mode(true)` and `make_feature(ctx, "streetscape")`. **Every float comparison of an engine property uses `is_equal_approx` or a 1e-5 tolerance**: a probe read back `ssao_radius = 0.05` as 0.05000000074506, `scaling_3d_scale = 0.59` as 0.58999997377396, and `4.0 * 0.7` failed `==` against `visibility_range_end`.

- **Mode switch.** The view was built in orbit by `make_ctx`; `set_fp_mode(true)` rebuilds synchronously, emits `world_rebuilt` once and `fp_mode_changed(true)` once, and afterwards level-0 lots, furniture and tree chunks are in their FP form without any tile change. `set_fp_mode(true)` again rebuilds nothing.
- **Scale.** Every real zone `building_aabb` has an xz size between 0.86 and 0.95.
- **Orientation.** Every zone or service lot with a frontage has a model yaw (from the `building_xform` meta) within 0.5° of `frontage_yaw(i)`.
- **Ground.**
  - The ground meshes contain no triangle centred on a water tile.
  - `ground` y equals `WS.GROUND_Y` (approx).
  - The water mesh y equals `WS.WATER_Y`, and `WATER_Y < GROUND_Y`.
  - `SIDEWALK_TOP - GROUND_Y ≤ 0.0125`, which is `WS.STEP_HEIGHT`.
  - `abs(LOT_TOP - GROUND_Y) ≤ 0.005`.
- **Furniture.**
  - In FP, no prop under a road holder lies on the carriageway (`RoadTopology.is_carriageway` is false for each prop origin and each `colliders` entry), and none lies in `WS.PED_BAND`.
  - Every road holder with furniture, MultiMesh-batched or not, has a `colliders` meta entry per item, already present when its `tile_built` fires; every prop root has `prop` meta.
  - Every billboard and shelter carries `poster_slot` meta; every `bus_stops` value is a `Vector2i`.
  - Every tee tile has one street sign; every cross tile has blades with no G1 pole when a stub traffic feature provides `light_pole`, else one G1 pole at the NE corner. Blade texts equal the directory street names, and no sign Label3D has `no_depth_test`.
  - Decals use `distance_fade_enabled`, at most 3 per tile.
- **Level-0 lots in FP.** No material under the holder has emission enabled.
- **Light profile.**
  - After `apply(env, sun, "fp", "medium")`: `env.ssao_radius ≈ WS.SSAO_RADIUS`, `env.ssil_radius ≈ WS.SSIL_RADIUS`, `env.fog_mode == FOG_MODE_DEPTH`, `env.fog_density ≈ 1.0` and `sun.directional_shadow_max_distance ≈ WS.SHADOW_MAX_DIST`.
  - For every preset, `fog_depth_end < camera_far(preset)` (G2's accessor, or `WS.CAMERA_FAR` and 45 / 60 / 75 hardcoded until G2 lands).
  - After `apply(..., "orbit", ...)`, every key the profile owns equals its snapshot, compared against a fresh `ResourceLoader.CACHE_MODE_IGNORE` load of the `.tres` (a plain `load()` returns the cached Environment the camera is already mutating, so the comparison would pass trivially) and the `main.tscn` Sun values. Keys SkyDirector owns are not compared.
  - With `sky.weather_energy_mult = 0.55`, after one SkyDirector `_apply`, `sun.light_energy` is 0.55× the clear-weather value at the same hour (the multiplier survives the per-frame rewrite).
- **Rebuild queue.**
  - In FP, `_on_tiles_changed` with 120 indices, `priority_point` at least 2 u from every queued tile, builds fewer than 120 tiles in the first `_process(1/60)` and all 120 within 200 frames.
  - `tile_built` fires exactly once per index.
  - The first built tile is the nearest **non-deferred** tile to `priority_point`.
  - **Deferral:** a tile within 1.5 u of `priority_point` and inside the camera frustum is not built until it leaves the frustum or 5 s of accumulated `_process` delta pass.
  - `flush_rebuild_queue()` empties the queue synchronously (`rebuild_pending() == 0`) and emits the remaining `tile_built` signals.
  - In orbit, all `tile_built` emissions happen synchronously inside `_on_tiles_changed`.
- **Trees, kit and sky.**
  - In FP the near tree chunk size is 8, the near range ≤ 15, and the far layer's `visibility_range_end ≈ 50`.
  - `ConstructionKit` scale equals `WS.MACHINE_SCALE`.
  - `sky_director` uses INCREMENTAL in FP and REALTIME in orbit.
- **Weather.** The same seed and day give the same state. At `sim.speed == 1`, forced rain has wetness < 0.6 after 60 s of simulated `_process` delta and > 0.9 after 120 s; the result does not depend on `sim.day_seconds`.
- **Imports.** Every `textures/real/*.import` and `env/*.hdr.import` has `mipmaps/generate=true`.

FP smoke: the streetscape `self_test()` (above). The orbit smoke stays `GRIDFALL_SMOKE: PASS`.

Photo tour (attach to the hand-off):
- In `street`, `residential` and `downtown`, the doors and shopfronts face the camera's street.
- No floating water. A continuous sidewalk-to-lot transition.
- Ground texture crisp at 2–20 m without a visible repeat.
- Near shadows sharp.
- The `night` shot shows lit pools under lamps.
- `street_sign` is readable.

## Performance budget

- **Rebuild queue:** at most 3 ms per frame in FP, `tile_built` emissions included. Street lights: at most `max_street_lights` (16 on High) OmniLights, with no shadows.
- **Mode switch:** `set_fp_mode` on a real change is a one-time synchronous rebuild; measure it and record it in the hand-off (shown behind a toast; boot never pays it, S0 §6.1).
- **Trees:** the far layer on 32- or 48-tile chunks adds no more than today's far-layer draw count.
- **Furniture:** at most +400 draw calls in a downtown view. Share materials across props, and use a MultiMesh per prop type per 8-tile chunk once there are more than 30 instances.
- **Decals:** at most 3 per tile, faded out by 3 u (`distance_fade_*`).
- **Rain:** at most 0.8 ms of GPU on Medium. Volumetric fog only on High.
- **fp_bench:** `street_eye_nohud` on Medium must be no slower than before G1 by more than 5%, and the draw calls not higher by more than 10%. G2's HLOD then wins it back.

## Risks

- **Old saves.** Street-facing yaws and REAL_SCALE 1.0 change how existing saves look. That is expected and accepted.
- **Ground.** Moving the ground and water changes A's ground model. Change the `WS` values in the same commit and tell A in `docs/fp/requests/G1-notes.md`.
- **Orbit regressions.** Gate every FP-only change on `fp_mode`, and keep the orbit profile exact.
- **Shared file.** `city_view.gd` is a 2,000-line hotspot. Keep the S0 seam hunks intact, and do not move the public helpers others call.

## Do NOT touch

- `city_life.gd` and `resident_avatars.gd` (E).
- `scripts/fp/render/**`, `project.godot` `[rendering]` and the `models/**` `.import` parameters (G2). G1 owns the `textures/real/**` and `env/**` import parameters.
- `models/**` and `tools/blender/**` (H). `tools/polyhaven_fetch.py` may get one list entry, for the dusk HDRI; tell H.
- `main.gd` and the S0 files.
