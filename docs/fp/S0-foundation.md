# S0 Foundation: implementer spec

S0 is the serial slice that every other slice builds on. When it lands:

- `godot --path .` boots into first person. You can walk the city at eye height with WASD and the mouse, speed up time, skip to morning, pause, and save and load.
- `GRIDFALL_VIEW=orbit` and every existing tool mode (orbit smoke, photo tour, cinematic) behave exactly as they do today.
- Every seam listed in ARCHITECTURE §4 exists, along with the shared FP plumbing: `FpMode`, `FpContext`, `GameBus`, `FpFeature`, the feature registry with one stub per slice, `WS`, `CityDirectory`, `RoadTopology`, a minimal `FpPlayer`, `CollisionWorld` and `FpHud`.
- `tools/gate.sh quick|full|render` exists and passes.

Read `docs/fp/ARCHITECTURE.md` first. Decisions D1–D12 are binding. This spec adds the decisions in §23, and those are binding too.

Line numbers refer to commit `611d727` (the base of `fp/integration`). Before you edit, re-anchor each hunk by its quoted text, not by line number alone.

---

## 1. Rules for the S0 implementer

- Branch: `fp/S0-foundation`, created from `fp/integration`. Never touch `main`. Never push. Every commit message ends with a blank line followed by `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Style: typed GDScript, tabs, a `##` doc comment on every class and public function, and sparse inline comments. Write physical quantities as metres × `WS.M`. Never use a bare magic scale.
- Determinism: never draw from `sim.rng`, `randf()` or `randi()` in FP code that tests depend on. Seed your own `RandomNumberGenerator` from `sim.city_seed`.
- Godot runs: set `XDG_DATA_HOME` to a fresh directory under `/tmp/claude-1000/`, set `GRIDFALL_OFFLINE=1`, and wrap the run in `timeout`. Heavy runs (headless main scene, windowed, `--import`) also go under `flock /tmp/claude-1000/gf-heavy.lock`. `tools/gate.sh` does all of this for you.
- Never print the GMI key. Never set `GRIDFALL_RECORD=1`.

---

## 2. File map

### 2.1 New files (S0 creates them; the owner column says who edits them afterwards)

| Path | Class / role | Owner after S0 |
|---|---|---|
| `scripts/fp/world_scale.gd` | const-only, `preload` as `WS` (no class_name) | S0 (frozen; see §4.3 for who may change which values) |
| `scripts/fp/asset_paths.gd` | const-only, `preload` as `AP` (no class_name) | H (path list only) |
| `scripts/fp/road_topology.gd` | `class_name RoadTopology` (static helpers) | S0 (frozen) |
| `scripts/fp/city_directory.gd` | `class_name CityDirectory extends RefCounted` | S0 (frozen; additions by request) |
| `scripts/fp/fp_mode.gd` | `class_name FpMode extends Node3D` | S0 |
| `scripts/fp/fp_context.gd` | `class_name FpContext extends RefCounted` | S0 |
| `scripts/fp/game_bus.gd` | `class_name GameBus extends Node` | S0 (new signals by request) |
| `scripts/fp/fp_feature.gd` | `class_name FpFeature extends Node3D` | S0 |
| `scripts/fp/fp_features.gd` | registry, const-only | S0 (pre-populated; slices never edit it) |
| `scripts/fp/player/player.gd` | `class_name FpPlayer extends Node3D` (minimal) | A |
| `scripts/fp/world/collision_world.gd` | `class_name CollisionWorld extends Node` (minimal) | A |
| `scripts/fp/ui/fp_hud.gd` | `class_name FpHud extends CanvasLayer` (shell plus placeholders) | B |
| `scripts/fp/sim/sim_perf_feature.gd` | stub, id `sim_perf` | F |
| `scripts/fp/street/streetscape_feature.gd` | stub, id `streetscape` | G1 |
| `scripts/fp/render/render_opt_feature.gd` | stub, id `render_opt` | G2 |
| `scripts/fp/traffic/traffic_feature.gd` | stub, id `traffic` | E |
| `scripts/fp/interact/interact_feature.gd` | stub, id `interact` | A |
| `scripts/fp/ui/hud_widgets_feature.gd` | stub, id `hud_widgets` | B |
| `scripts/fp/chat/chat_feature.gd` | stub, id `chat` | C |
| `scripts/fp/posters/poster_feature.gd` | stub, id `posters` | D |
| `scripts/fp/audio/audio_feature.gd` | stub, id `audio` | I |
| `tools/gate.sh` | the gate (§18) | S0 |
| `tools/tests/parse_all.gd` | compiles every `.gd` (§17.1) | S0 |
| `tools/tests/fp_kit.gd` | shared test helpers (§17.2) | S0 (additions by request) |
| `tools/tests/fp_smoke.gd` | FP headless smoke, run by `main.gd` (§17.4) | S0 |
| `tools/tests/fp_shots.gd` | deterministic street-shot finder (§17.5) | S0 |
| `tools/tests/fp_photo_tour.gd` | FP windowed photo tour (§17.5) | S0 |
| `tools/tests/fp_bench.gd` | FP perf report (§17.6) | G2 after S0 |
| `tools/tests/fp_world_scale_test.gd` | unit test | S0 |
| `tools/tests/fp_seams_test.gd` | unit test | S0 |
| `tools/tests/fp_directory_test.gd` | unit test | S0 |
| `tools/tests/fp_core_test.gd` | unit test (collision, player, registry) | S0 |

### 2.2 Edited files (S0 seam hunks only, listed in §15)

`scripts/main.gd`, `project.godot` (`[input]` only), `scripts/world/city_view.gd`, `scripts/world/construction_kit.gd` (the site `colliders` meta, §15.1), `scripts/sim/residents.gd`, `scripts/sim/city_sim.gd`, `scripts/sim/sim_defs.gd`, `scripts/ai/city_brain.gd`, `scripts/ai/resident_minds.gd` (one line), `scripts/world/resident_avatars.gd` (one line), `scripts/world/sky_director.gd` (one line).

S0 does **not** edit `scenes/main.tscn`. The FP nodes are created in code, so `main.tscn` keeps the orbit `View/Camera` as its only camera. The cinematic and the photo tour depend on that.

---

## 3. Runtime shape

```
Main (main.gd)
├─ CitySim, GmiClient, CityBrain, AudioDirector, CityView(fp_mode), View(orbit rig, processing off), Sun, HUD(CityHud, hidden, PROCESS_MODE_DISABLED)
├─ Residents, ResidentMinds, SkyDirector
└─ FpMode (Node3D at identity, PROCESS_MODE_ALWAYS)          built only by Main.enter_fp()
   ├─ GameBus "Bus"
   ├─ CollisionWorld "Collision"
   ├─ FpPlayer "Player" (PROCESS_MODE_PAUSABLE)
   │   └─ Camera3D "Camera" (current, environment = Main.camera.environment)
   ├─ Node3D "World"   (ctx.world_root: in-world FP nodes that must survive view.setup)
   ├─ Node3D "Features" (PROCESS_MODE_PAUSABLE)
   │   └─ one FpFeature per registry entry, in registry order
   └─ FpHud "FpHud" (CanvasLayer layer 10, PROCESS_MODE_ALWAYS)
```

`view.setup()` frees every child of CityView, and it runs again on load and on New City. So **no FP node may live under CityView**. Every FP node that is placed in the world goes under `ctx.world_root`, or under the feature itself, since `FpFeature` is a Node3D at identity.

**One exception: decorations of a tile holder.** A feature may add a child to a tile holder (`view.tile_holder(i)`) when the node only decorates that tile (D's poster quads and materials on billboards and shelters). Such nodes die with the holder, so the feature re-attaches them on every `tile_built(i, …)` and full pass, tags each one with `set_meta("fp_owner", feature_id())`, and frees every tagged node in `teardown()`. Nothing else may be parented under CityView.

---

## 4. `scripts/fp/world_scale.gd` (preloaded as `WS`)

Const-only, `extends RefCounted`, no class_name. Use it with `const WS := preload("res://scripts/fp/world_scale.gd")`.

### 4.1 Contents (exact names and values)

Comments in the file give the metre value and the source. The **Source** column records where each authoring value was verified.

| Const | Value | Metres / meaning | Source |
|---|---|---|---|
| `M` | `0.05` | units per metre | `core.py:19` `M = 1/20` |
| `TILE_M` | `20.0` | metres per tile | same |
| **Player** | | | |
| `EYE` | `1.65 * M` (0.0825) | standing eye height | ARCH §2 |
| `CROUCH_EYE` | `1.0 * M` | crouched eye height | ARCH §2 |
| `PLAYER_RADIUS` | `0.3 * M` (0.015) | capsule radius | ARCH §2 |
| `PLAYER_HEIGHT` | `1.8 * M` | standing height | |
| `CROUCH_HEIGHT` | `1.2 * M` | crouched height | |
| `WALK` | `1.45 * M` | 1.45 m/s | ARCH §2 |
| `RUN` | `4.5 * M` | 4.5 m/s | ARCH §2 |
| `CROUCH_WALK` | `0.8 * M` | | |
| `ACCEL` | `10.0 * M` | m/s², ground acceleration | |
| `GRAVITY` | `9.81 * M` (0.4905) | | crit §d |
| `JUMP_SPEED` | `3.4 * M` | apex ≈ 0.59 m | |
| `STEP_HEIGHT` | `0.25 * M` (0.0125) | max auto step; clears the 12 cm curb | |
| `MOUSE_SENSITIVITY` | `0.0022` | radians per pixel (default setting) | |
| `PITCH_LIMIT_DEG` | `85.0` | | |
| `PHOTO_FLY_SPEED` | `8.0 * M` | photo-mode free-fly | |
| **Camera** | | | |
| `CAMERA_NEAR` | `0.004` | 8 cm (probe-verified: Godot keeps 0.004) | ARCH §2 |
| `CAMERA_FAR` | `60.0` | 1.2 km | ARCH §2 |
| `FOV` | `72.0` | degrees, vertical | ARCH §2 |
| **Roads** (authoring values) | | | |
| `ROAD_HALF` | `0.3` | 6 m carriageway half-width | `roads.py:27` `HW = 0.3` |
| `LANE_OFFSET` | `0.15` | right-hand lane centre | `roads.py` dashes at x = 0, carriageway ±0.3 |
| `ASPHALT_TOP` | `0.003` | 6 cm | `roads.py:24` `ZA` |
| `SIDEWALK_TOP` | `0.009` | 18 cm above the tile datum | `roads.py:25` `ZS` (verified) |
| `CURB_RISE` | `SIDEWALK_TOP - ASPHALT_TOP` (0.006) | 12 cm curb face | `roads.py:45` curb from `ZA` to `ZS` |
| `MARKING_TOP` | `0.0033` | | `roads.py:26` `ZM` |
| `SIDEWALK_INNER` | `0.3` | sidewalk band starts at the curb | `roads.py` `_straight_sides` |
| `SIDEWALK_OUTER` | `0.5` | tile edge | same |
| `SIDEWALK_CENTER` | `0.4` | sidewalk band centre (spawn point, `sidewalk_point`) | |
| `CURB_FURNITURE` | `[0.305, 0.345]` | band for lamps, signs, bins, bollards and tree pits (origins). The baked lamps of `road_straight_lights.glb` stand at ±0.34 | `roads.py:166-167` |
| `PED_BAND` | `[0.355, 0.405]` | band for pedestrian centrelines (E) | review DEH-20 |
| `FRONT_FURNITURE` | `[0.415, 0.49]` | band for shelters, racks and meters against the lot edge | review DEH-20 |
| `STOP_LINE` | `0.35` | stop-line inner edge from the junction centre (line spans 0.35–0.36) | `roads.py:109-115` |
| `ZEBRA_NEAR` | `0.375` | | `roads.py:92-106` |
| `ZEBRA_FAR` | `0.47` | | same |
| `CORNER_INNER_R` | `0.2` | corner carriageway inner radius about the tile corner | `roads.py:173-181` |
| `CORNER_OUTER_R` | `0.8` | | same |
| `CORNER_LANE_R_IN` | `0.35` | inner lane arc | 0.5 ∓ 0.15 |
| `CORNER_LANE_R_OUT` | `0.65` | outer lane arc | |
| `CORNER_FILLET_R` | `0.09` | junction curb fillet | `roads.py:188` |
| `END_CIRCLE_R` | `0.38` | cul-de-sac turning circle | `roads.py:244` |
| `END_CIRCLE_OFFSET` | `0.04` | circle centre offset toward the closed end | `roads.py:245` (Blender +Y is Godot −Z) |
| `END_ISLAND_R` | `0.11` | raised grass island (top at `SIDEWALK_TOP`) with a tree at the turning-circle centre | `roads.py:263-266` |
| `BRIDGE_SIDEWALK_OUT` | `0.428` | walkable bridge sidewalk ends; parapet beyond | `roads.py:270-281` (W = 0.44, parapet at W − 0.012) |
| `LAMP_HEIGHT` | `0.42` | 8.4 m | `roads.py:127` |
| **Ground datum** (current CityView geometry) | | | |
| `GROUND_Y` | `-0.012` | base grass plane | `city_view.gd:278` |
| `LOT_TOP` | `0.004` | real-model lot slab top | ARCH research (validate_real) |
| `PAD_TOP` | `0.006` | C/I pad and rubble plane | `city_view.gd:934, 989` |
| `WATER_Y` | `0.03` | water surface (G1 plans to lower it) | `city_view.gd:290` |
| `RIVERBED_Y` | `-0.004` | | `city_view.gd:285` |
| `LOT_FOOTPRINT` | `0.94` | authored lot width before REAL_SCALE | validate_real |
| **Asset multipliers** (targets the slices apply) | | | |
| `REAL_SCALE` | `1.0` | buildings (CityView uses 0.9 today) | ARCH §2 |
| `PEOPLE_SCALE` | `1.0` | (avatars use 1.5 today) | ARCH §2 |
| `VEHICLE_SCALE` | `1.0 / 1.2` | legacy real vehicles were authored at 1.2× | `vehicles.py:22` `VS = 1.2*M` |
| `VEHICLE_V2_SCALE` | `1.0` | H's re-exported vehicles | |
| `MACHINE_SCALE` | `1.0 / 20.0` | construction machines (kit uses 1/16 today) | `construction_kit.gd:9` |
| `PERSON_H` | `1.75 * M` | authored person height | `people.py:1` |
| **Agent speeds** (E) | | | |
| `CAR_CITY` | `13.9 * M` | 50 km/h | ARCH §2 |
| `CAR_RESIDENTIAL` | `8.3 * M` | 30 km/h | |
| `BUS_SPEED` | `11.1 * M` | 40 km/h | |
| `EMERGENCY_SPEED` | `19.4 * M` | 70 km/h | |
| `PED_WALK` | `1.35 * M` | | |
| `PARK_OFFSET` | `0.245` | curb parking slot centre from the road centreline | review DEH-11 (sedan half-width 0.0525 at `VEHICLE_SCALE`) |
| `PASS_OFFSET` | `0.12` | moving-lane centre alongside occupied parking slots | review DEH-11 |
| **Interaction** (A) | | | |
| `TALK_RANGE` | `3.0 * M` | | |
| `INTERACT_RANGE` | `6.0 * M` | buildings, posters, cars | |
| **Audio** (I) | | | |
| `AUDIO_UNIT_SIZE` | `0.5` | AudioStreamPlayer3D `unit_size` (10 m) | ARCH §2 |
| **Light profile targets** (G1) | | | |
| `SHADOW_MAX_DIST` | `12.0` | 240 m | crit §d (8–15) |
| `SSAO_RADIUS` | `1.0 * M` | | crit §d |
| `SSIL_RADIUS` | `5.0 * M` | | crit §d |
| `FOG_DEPTH_BEGIN` | `20.0` | 400 m | |
| `FOG_DEPTH_END` | `58.0` | just inside `CAMERA_FAR` | |
| **Visibility targets** (G2, E) | | | |
| `VIS_BUILDING` | `30.0` | 600 m | |
| `VIS_PROP` | `4.0` | 80 m | |
| `VIS_PERSON` | `4.0` | | |
| `VIS_CAR` | `10.0` | | |
| `VIS_SITE_PART` | `8.0` | | |
| `TRAFFIC_RADIUS` | `15.0` | full traffic sim radius (300 m) | |
| **Time** | | | |
| `FP_DAY_SECONDS` | `1200.0` | 20-minute game day (D4) | ARCH D4 |
| `TIME_SCALES` | `[1, 2, 4, 8]` | allowed FP speeds | ARCH D4 |

### 4.2 Rules

- Do not add `class_name` to `world_scale.gd`.
- Every value that derives from metres is written as `<metres> * M` in the source.

### 4.3 Who may change a value after S0

Values are frozen. Two kinds of change are allowed:

- A slice may **add** a new constant, but only inside its own section. S0 ends the file with one empty section per slice, in this order, separated by two blank lines so that parallel additions never touch the same hunk:

  ```gdscript
  # --- A player (owned by A)
  # end A


  # --- B hud (owned by B)
  # end B


  # --- C chat (owned by C)
  # end C
  ```

  …and likewise for D, E, F, G1, G2, H and I. Add constants between your two marker lines only; never edit another section or the S0 body.
- These existing values may be changed by their owner in the same commit that changes the geometry they describe:
  - `GROUND_Y`, `WATER_Y`, `LOT_TOP` and `PAD_TOP` by G1.
  - The `VIS_*` values by G2.
  - The speeds by E.
  - The player values by A.

  Anything else goes through `docs/fp/requests/<slice>-needs.md`.

### 4.4 `scripts/fp/asset_paths.gd` (preloaded as `AP`; H owns the list after S0)

S0 writes this file exactly as shown. None of the new files exist yet, so every consumer loads through `AP.load_scene(path)` and falls back when it returns null. **`ResourceLoader.exists()` alone is not a safe check:** a probe showed `exists() == true` and `load() == null` for a GLB whose `.import` file is present but whose import cache is missing (a warm worktree after H merges, before re-import).

```gdscript
extends RefCounted
## First-person asset paths. Slice H owns this list and produces the files; every consumer loads
## them with load_scene() and falls back to the legacy asset or a procedural stand-in on null.

const PEOPLE_LEGACY_DIR := "res://models/real/people/"
const PEOPLE_RIGGED_DIR := "res://models/real/people_rigged/"
const VEHICLES_LEGACY_DIR := "res://models/real/vehicles/"
const VEHICLES_V2_DIR := "res://models/real/vehicles_v2/"
const STREET_DIR := "res://models/real/street/"
const TRAFFIC_LIGHT := STREET_DIR + "traffic_light.glb"
const PED_SIGNAL := STREET_DIR + "ped_signal.glb"
const STREET_SIGN := STREET_DIR + "street_sign.glb"
const STOP_SIGN := STREET_DIR + "stop_sign.glb"
const YIELD_SIGN := STREET_DIR + "yield_sign.glb"
const BUS_SHELTER := STREET_DIR + "bus_shelter.glb"
const BILLBOARD_POSTER := STREET_DIR + "billboard.glb"
const POSTER_FRAME := STREET_DIR + "poster_frame.glb"
const HOARDING := STREET_DIR + "hoarding.glb"
const CROSSWALK_RAMP := STREET_DIR + "curb_ramp.glb"
const BIKE_RACK := STREET_DIR + "bike_rack.glb"
const PARKING_METER := STREET_DIR + "parking_meter.glb"
const LEASE_SIGN := STREET_DIR + "lease_sign.glb"
const BOLLARD := "res://models/real/props/bollard.glb"
const BICYCLE := VEHICLES_V2_DIR + "bicycle.glb"
## Animation names every rigged person provides, as Godot lists them after import. H names the
## Blender actions "<name>-loop" (and "sit") so the importer sets LOOP_LINEAR; H's test confirms
## the suffix is stripped on 4.7.2. If it is not, H changes this list to the suffixed names.
const PERSON_ANIMS := ["idle", "walk", "run", "talk", "sit"]
const PERSON_LOOPING := ["idle", "walk", "run", "talk"]
## Separate wheel nodes on vehicles_v2 road vehicles (origin at the hub, spin about local X).
const WHEEL_NODES := ["Wheel_FL", "Wheel_FR", "Wheel_RL", "Wheel_RR"]
const BIKE_WHEEL_NODES := ["Wheel_F", "Wheel_R"]
## Node-name contracts inside H's GLBs (all optional; consumers fall back when absent).
## Poster_<n>: MeshInstance3D, one surface, material "Poster", UV 0..1, normal +Z in node space.
const POSTER_NODE_PREFIX := "Poster_"
## PosterSpot_<n>: empty on a blank wall, +Z out of the wall, scale = poster size in units.
const POSTER_SPOT_PREFIX := "PosterSpot_"
## Door_<n>: empty at the bottom centre of a doorway, +Z out, scale.y = leaf height.
const DOOR_SPOT_PREFIX := "Door_"
## ColBox_<n>: empty, position = box centre, scale = half extents (collision proxy, no mesh).
const COLBOX_PREFIX := "ColBox_"

## First path in the list that load_scene() can load, or "".
static func first_existing(paths: Array) -> String
## The PackedScene at path, or null. Returns non-null only when ResourceLoader.exists(path) is
## true, load(path) is non-null and the result is a PackedScene. Cached per path.
static func load_scene(path: String) -> PackedScene
```

---

## 5. `scripts/fp/road_topology.gd` (`class_name RoadTopology`)

These are static helpers shared by collision, traffic, the directory, the minimap and the streetscape. They mirror `CityView._road_mask` and `_road_piece` (`city_view.gd:803-855`) **exactly**:

- Mask bits are N=1, E=2, S=4, W=8. North is −Z, so S is +Z, E is +X and W is −X.
- Base pieces: straight runs N–S (mask 5); corner joins S+W (mask 12); tee joins E+S+W (mask 14); end opens S (mask 4); cross is mask 15.
- A yaw of +90° maps N→W, E→N, S→E and W→S.

```gdscript
class_name RoadTopology
extends RefCounted
const N := 1
const E := 2
const S := 4
const W := 8
## Neighbour mask of road tile (x, y): ROAD neighbours only, exactly like CityView._road_mask.
static func mask(sim: CitySim, x: int, y: int) -> int
## [piece: String, yaw_deg: float] for a mask; piece in straight|corner|tee|cross|end. Mirrors _road_piece with real roads present.
static func piece(m: int) -> Array
## Unit directions (dx, dy) of the open arms, in N, E, S, W order. dy is world +Z.
static func arms(m: int) -> Array[Vector2i]
## True when local point lp = (wx - x, wz - y) of a road tile with mask m is on the carriageway.
static func is_carriageway(m: int, lp: Vector2) -> bool
## Walkable surface height at lp on road tile i: ASPHALT_TOP on the carriageway, SIDEWALK_TOP on the sidewalk,
## NAN outside the bridge parapet (bridge = ROAD on WATER terrain, straight only).
static func surface_height(sim: CitySim, i: int, lp: Vector2) -> float
## World point at the centre of the sidewalk on `side` (+1 right, -1 left of the run) of a straight road tile.
static func sidewalk_point(sim: CitySim, i: int, side: int) -> Vector3
## True if road tile i is a bridge (ROAD on WATER terrain).
static func is_bridge(sim: CitySim, i: int) -> bool
```

Carriageway geometry, in tile-local coordinates `lp` with `|lp.x|, |lp.y| ≤ 0.5` (`lp.y` is world +Z):

- **Straight, and isolated (mask 0):** `|perp| < ROAD_HALF`, where perp is the coordinate across the run. Mask 0 counts as N–S.
- **Corner (two adjacent arms):** the corner centre is `c = (a1 + a2) * 0.5` for the two arm unit vectors. For mask 12 (S+W) that is `(-0.5, +0.5)`. The point is on the carriageway iff `CORNER_INNER_R ≤ |lp − c| ≤ CORNER_OUTER_R`.
- **Tee and cross:** the union of the central square `|x|,|y| < ROAD_HALF` with a strip `|perp| < ROAD_HALF` running from the centre to the edge along each open arm. The 0.09 fillets are ignored.
- **End (one arm):** the arm strip on the open half, or `|lp − o| ≤ END_CIRCLE_R`, where `o = −arm * END_CIRCLE_OFFSET`, **minus** the island `|lp − o| < END_ISLAND_R`. On the island `surface_height` returns `SIDEWALK_TOP` (raised grass, `roads.py:263-264`); its tree trunk is a collider (A).
- **Bridge:** a straight carriageway. The sidewalk is `ROAD_HALF ≤ |perp| ≤ BRIDGE_SIDEWALK_OUT`. Beyond that `surface_height` returns `NAN`, which means blocked.

---

## 6. Boot, view modes and `main.gd`

### 6.1 Env vars and precedence

The legacy ladder (`main.gd:84-99`) runs first and is unchanged. The new block is inserted **after line 99** (after the `GRIDFALL_PHOTO_DIR` branch) and **before** `sim.start()` on line 100.

**Early FP flag.** The view is first built at `main.gd:37`, long before the ladder. So that G1's FP-only geometry is built once and not twice at boot, add a static helper `static func wants_fp() -> bool` (true iff none of `GRIDFALL_CINEMATIC`, `GRIDFALL_SMOKE_TEST`, `GRIDFALL_PHOTO_DIR` is set and either `GRIDFALL_FP_SMOKE == "1"`, `GRIDFALL_FP_PHOTO_DIR` is set or `GRIDFALL_VIEW != "orbit"`), and just before line 37 set the field directly: `view.fp_mode = wants_fp()`. This only sets the field (no `_apply_fp_visibility`, no signal); `enter_fp()` later calls `set_fp_mode(true)`, which sees no value change and only re-applies visibility. The ladder block below uses `wants_fp()` too, so the two can never disagree.

| Order | Env var | Mode | View |
|---|---|---|---|
| 1 | `GRIDFALL_CINEMATIC=prep\|record` | cinematic (unchanged) | orbit |
| 2 | `GRIDFALL_SMOKE_TEST=1` | orbit smoke (unchanged) | orbit |
| 3 | `GRIDFALL_PHOTO_DIR=<dir>` | orbit photo tour (unchanged) | orbit |
| 4 | `GRIDFALL_FP_SMOKE=1` | FP headless smoke (`tools/tests/fp_smoke.gd`) | fp |
| 5 | `GRIDFALL_FP_PHOTO_DIR=<dir>` | FP windowed photo tour (`tools/tests/fp_photo_tour.gd`) | fp |
| 6 | `GRIDFALL_VIEW=orbit` | play | orbit (legacy, unchanged) |
| 7 | none of the above (`GRIDFALL_VIEW` unset or `fp`) | play | **fp** |

`GRIDFALL_SPEED` keeps working. In FP it is snapped to the nearest value in `WS.TIME_SCALES` and passed to `fp.set_time_scale()`.

### 6.2 `main.gd` hunks

The block below adds a const and two vars after line 21 (`var sky: SkyDirector`):

```gdscript
const WS := preload("res://scripts/fp/world_scale.gd")
## First-person composition (null in orbit mode). Built by enter_fp(), freed by exit_fp().
var fp: FpMode = null
## "orbit" or "fp"; tools and saves can read it.
var view_mode: String = "orbit"
```

Replace the camera yanks so they go through `focus()`:

| Line | Old | New |
|---|---|---|
| 52 | `camera_rig.focus_world_point(view.avatars.position_of(id), 14.0)` | `focus(view.avatars.position_of(id), 14.0, "resident:" + id)` |
| 61 | `...camera_rig.focus_world_point(Vector3(x, 0, y), 30.0))` | `...focus(Vector3(x, 0, y), 30.0, "tile"))` |
| 79 | `camera_rig.focus_world_point(Vector3(int(ev["x"]), 0, int(ev["y"])), 34.0)` | `focus(Vector3(int(ev["x"]), 0, int(ev["y"])), 34.0, "event:" + str(ev["type"]))` |
| 128 | `camera_rig.focus_world_point(Vector3(c.x, 0, c.y), 36.0)` | `focus(Vector3(c.x, 0, c.y), 36.0, "district:%d" % mi)` |

The direct `camera_rig.focus_world_point` calls in `_run_photo_tour` (231–259) and in `cinematic.gd` stay as they are. Those code paths are orbit-only by construction.

Insert after line 99:

```gdscript
	var fp_smoke := OS.get_environment("GRIDFALL_FP_SMOKE") == "1"
	var fp_photo := OS.get_environment("GRIDFALL_FP_PHOTO_DIR")
	if wants_fp():
		enter_fp()
	if fp_smoke:
		var smoke: Node = (load("res://tools/tests/fp_smoke.gd") as GDScript).new()
		smoke.name = "FpSmoke"
		add_child(smoke)
		smoke.call("run", self)
		return
	if not fp_photo.is_empty():
		var tour: Node = (load("res://tools/tests/fp_photo_tour.gd") as GDScript).new()
		tour.name = "FpPhotoTour"
		add_child(tour)
		tour.call("run", self, fp_photo)
		return
```

Lines 100–104 become:

```gdscript
	sim.start()
	var start_speed := int(OS.get_environment("GRIDFALL_SPEED")) if OS.has_environment("GRIDFALL_SPEED") else 1
	if fp != null:
		fp.set_time_scale(start_speed)
		notify("Welcome to GridFall. WASD to walk, Enter to chat, M for the map, Esc to pause.")
	else:
		sim.set_speed(start_speed)
		hud.set_speed_display(start_speed)
		hud.toast("Five GMI mayors are drafting their first plans...")
```

Changes to save and load:

- `save_game` (131–140): after the `data` literal, add `if fp != null: data["fp"] = fp.to_dict()`. Replace the two `hud.toast(...)` calls with `notify(...)`.
- `load_game` (143–167): line 158 becomes `view.setup(sim, active_camera())`. After line 160 (`hud.setup_people`), add `if fp != null: fp.from_dict(d.get("fp", {}))`. Replace the `hud.toast` calls with `notify`. Old saves have no `"fp"` key, so `from_dict({})` runs and spawns the player at the spawn point.
- `new_game` (170–179): line 174 becomes `view.setup(sim, active_camera())`. After line 176 (`hud.setup_people`), add `if fp != null: fp.from_dict({})`. Replace `hud.toast` with `notify`.

New public functions on Main:

```gdscript
## Draws attention to a world point. Orbit: moves the camera rig (old behaviour).
## First person: never teleports; emits GameBus.ping(p, reason) for the HUD and minimap.
## reason: "event:<type>" | "resident:<id>" | "tile" | "district:<mi>" | "" .
func focus(p: Vector3, dist: float, reason: String = "") -> void:
	if fp != null:
		fp.bus.ping.emit(p, reason)
		return
	camera_rig.focus_world_point(p, dist)

## Player-facing notice: CityHud toast in orbit, GameBus.toast in first person.
## kind: "info" | "alert" | "success" | "system".
func notify(text: String, kind: String = "info") -> void

## The camera the city view should use for picking and shake.
func active_camera() -> Camera3D:
	return fp.player.camera if fp != null else camera

## Switches to first person (see §6.3). Safe to call twice.
func enter_fp() -> void
## Back to the orbit view and CityHud (used by B's "Quit to orbit"). Safe to call twice.
## It frees FpHud, so a caller inside an FP node's signal (a Button's pressed) must use
## ctx.main.call_deferred("exit_fp"); a locked object cannot be freed mid-emit.
func exit_fp() -> void

## Grows the city offline at full speed with the legacy 12 s day, for tests and tours, then restores
## the current day length and speed 0. The caller must have called sim.start(). Returns when
## sim.day >= days or after cap_ms of wall clock time.
func grow_offline(days: int, cap_ms: int) -> void   # coroutine
```

`grow_offline` body: `client.set_live(false)`. Save `sim.day_seconds` and `var was_sliced = sim.get("sliced")` (F's flag; `null` before F lands). If it is true, `sim.set("sliced", false)`, because sliced mode runs one tick per job and would starve growth. Call `sim.set_day_seconds(D.BASE_DAY_SECONDS)` and `sim.set_speed(16)`. Loop awaiting `get_tree().process_frame` until `sim.day >= days` or the cap is hit. Then `sim.set_speed(0)`, restore the day length with `sim.set_day_seconds(saved)`, restore `sliced` when it was true, and drain the view: `if view.has_method("flush_rebuild_queue"): view.call("flush_rebuild_queue")` (G1's queue, §15.1). `fp.time_scale` is not touched; consumers that need the live sim rate read `sim.speed` (D-S0-1).

### 6.3 `enter_fp()` and `exit_fp()`, step by step

`enter_fp()`:

1. If `fp != null`, return. Set `view_mode = "fp"`.
2. Disable the orbit rig with the same three calls cinematic uses (`cinematic.gd:49-51`): `camera_rig.set_process(false)`, `camera_rig.set_process_input(false)`, `camera_rig.set_process_unhandled_input(false)`.
3. Run `hud.visible = false` and `hud.process_mode = Node.PROCESS_MODE_DISABLED`. This stops CityHud's `_process` and its hotkeys (Space, Esc, 1–4, F5, F9 at `city_hud.gd:600-625`). Its signal connections still fire, so `focus_tile_requested` coming from `_on_chaos` reaches `focus()`, which emits a ping.
4. Call `view.set_fp_mode(true)` (§15.1). At boot the field is already true (§6.1 early flag), so this only re-applies visibility; it emits `fp_mode_changed` only on a real change.
5. Remember the orbit speed (`_orbit_speed = sim.speed`, or 1 when the sim has not started yet), then `sim.set_day_seconds(WS.FP_DAY_SECONDS)`. Every day-length change goes through `set_day_seconds` (§15.3), which rescales the pending tick time so the time of day does not jump.
6. `fp = FpMode.new(); fp.name = "FpMode"; add_child(fp); fp.setup(self)` (§7).
7. `view.set_camera(fp.player.camera)`. The FP camera already shares the Environment (§11) and is current.

`exit_fp()` reverses those steps:

1. `fp.teardown()` then `fp.queue_free()`, and set `fp = null`.
2. `view.set_fp_mode(false)` and `view.set_camera(camera)`, then `camera.make_current()`.
3. Turn the three rig process flags back on, then `hud.process_mode = Node.PROCESS_MODE_INHERIT` and `hud.visible = true`.
4. `sim.set_day_seconds(D.BASE_DAY_SECONDS)`, then `sim.set_speed(_orbit_speed)` and `hud.set_speed_display(_orbit_speed)` (the FP time scale does not carry over), `get_tree().paused = false`, `Input.mouse_mode = Input.MOUSE_MODE_VISIBLE`, and `view_mode = "orbit"`. A raw `day_seconds` write here would leave up to one 300 s FP tick pending against a 3 s orbit tick, and `city_sim._process` would drain it eight ticks per frame (a probe saw 84 ticks, 21 game days, in 40 frames).

### 6.4 Save format

```json
{ "sim": {...}, "brain": {...}, "client": {...}, "residents": {...}, "minds": {...}, "saved_at": "...",
  "fp": { "version": 1,
          "player": {"pos": [x, y, z], "yaw": deg, "pitch": deg},
          "time_scale": 1,
          "day_phase": 0.42,
          "<feature_id>": { ...feature.to_dict()... } } }
```

- `version`, `player`, `time_scale` and `day_phase` are reserved keys. A feature id must not use them.
- `day_phase` is `sim.tick_phase()` at save time. The sim saves only whole ticks, and an FP tick is 300 s (6 game hours), so without it a load rewinds the clock to the last tick boundary. `from_dict` calls `sim.set_tick_phase(day_phase)`, or `set_tick_phase(0)` when the key is missing (fresh city, old save).
- A feature whose `to_dict()` returns `{}` is left out.
- An orbit save has no `"fp"` key. Loading it in FP spawns the player at the spawn point. Loading an FP save in orbit ignores the `"fp"` key.

---

## 7. `scripts/fp/fp_mode.gd` (`class_name FpMode extends Node3D`)

```gdscript
class_name FpMode
extends Node3D
## First-person composition root: builds the context, bus, player, collision, HUD and every
## registered feature, owns time controls, pause, the mouse and the FP save section.

const WS := preload("res://scripts/fp/world_scale.gd")
const REGISTRY := preload("res://scripts/fp/fp_features.gd")
const SETTINGS_PATH := "user://gridfall_fp_settings.json"
## camera_mode is "third" (over-the-shoulder, the default for play, D13) or "first"; "fov" is the
## first-person FOV and "tps_fov" the third-person one; shoulder is 1 (right) or -1 (left); hero
## is "m" or "f". fp_kit.make_ctx overrides camera_mode to "first" unless a test asks otherwise.
const DEFAULT_SETTINGS := {
	"mouse_sensitivity": 0.0022, "invert_y": false, "fov": 72.0, "head_bob": true,
	"quality": "medium", "show_hud": true, "music_volume_db": 0.0, "sfx_volume_db": 0.0,
	"camera_mode": "third", "tps_fov": 60.0, "tps_distance_m": 3.2, "shoulder": 1,
	"auto_shoulder": false, "hero": "m",
}

var ctx: FpContext
var bus: GameBus
var player: FpPlayer
var collision: CollisionWorld
var hud: FpHud
var directory: CityDirectory
var time_scale: int = 1
var paused: bool = false
## Every patch passed to apply_settings, in order (tests read it; also filled when not set up).
var settings_log: Array[Dictionary] = []

## Builds everything. main is the Main node (main.gd); reads its sim, residents, minds, brain,
## client, view, sky, audio, camera and sun_light fields.
func setup(main: Node3D) -> void
## Tears down the features (reverse order) and the HUD, releases the mouse, unpauses.
func teardown() -> void
## Save section, see §6.4.
func to_dict() -> Dictionary
## Restores the save section. {} means a fresh city: player at spawn_point(), features reset.
func from_dict(d: Dictionary) -> void
## Sets the sim speed to s, snapped to WS.TIME_SCALES; emits bus.time_scale_changed. Paused: stored, applied on resume.
func set_time_scale(s: int) -> void
## +1 / -1 through WS.TIME_SCALES (bound to time_faster / time_slower).
func step_time_scale(dir: int) -> void
## Runs the rest of today's ticks now, so the next day starts at 06:00 (bound to time_skip). Coroutine:
## toasts "Skipping to morning...", awaits 2 frames, then calls sim.skip_to_next_day().
func skip_to_morning() -> void
## Pauses the whole SceneTree (get_tree().paused). The FpHud and FpMode keep running. Emits bus.pause_changed.
func set_paused(p: bool) -> void
## Appends patch to settings_log, merges it into ctx.settings, saves SETTINGS_PATH (skipped when
## setup() never ran, as in fp_kit's stub mode, or when persist is false, as for the photo tour's
## and fp_bench's camera override), emits bus.settings_changed(settings) and, if "quality" changed,
## bus.quality_changed(preset).
func apply_settings(patch: Dictionary, persist: bool = true) -> void
## Feet position and yaw for a fresh player: the sidewalk in front of City Hall (see §7.3).
func spawn_point() -> Dictionary   # {"pos": Vector3, "yaw": float(deg)}
```

### 7.1 `setup(main)` order

1. `process_mode = PROCESS_MODE_ALWAYS`. Load the settings: `DEFAULT_SETTINGS` merged with `SETTINGS_PATH` when it exists. Wrap the file read so a bad file falls back to the defaults.
2. Create `bus` (GameBus, `"Bus"`) and `directory` (`CityDirectory.new(); directory.setup(main.sim)`).
3. Create `ctx` and fill every field in §8.
4. Create `collision` (`"Collision"`), call `collision.setup(ctx)`, then set `ctx.collision`.
5. Create `world_root` (`Node3D "World"`, `process_mode = PROCESS_MODE_PAUSABLE`: FpMode itself is ALWAYS, so without it every in-world node a slice puts there would keep running while paused, against D-S0-2), then `player` (`FpPlayer "Player"`, `process_mode = PROCESS_MODE_PAUSABLE`), then `player.setup(ctx)`. The player builds its camera, shares the Environment, and makes the camera current.
6. Create `hud` (`FpHud "FpHud"`) and call `hud.setup(ctx)`.
7. Create `Node3D "Features"` (`PROCESS_MODE_PAUSABLE`). For each entry in `REGISTRY.FEATURES`, in order:
   - If `ResourceLoader.exists(path)` is false, call `push_warning` and skip the entry.
   - Otherwise `var f: FpFeature = (load(path) as GDScript).new()`, `f.name = id`, `features_node.add_child(f)`, `ctx.features[id] = f`.
   - Then, in a **second loop**, call `f.setup(ctx)` on every feature. That way setup code can already see its sibling features in `ctx.features`.
8. Connect `ctx.view.world_rebuilt` to `_on_world_rebuilt`, and `ctx.view.tile_built` / `tile_cleared` to `collision.on_tile_built` / `on_tile_cleared`. Then connect `tile_built` to `_on_tile_built` (after the collision handler, so the box cache is already invalidated): outside `view.in_setup`, when the tile is within one tile of the player's, it calls `unstick_player()`, which moves the player to `collision.nearest_free(pos, PLAYER_RADIUS, 2.0)` (else the spawn point) if they now stand inside a box, and toasts "Moved you clear of new construction.". `from_dict` also calls `unstick_player()` after restoring the player.
9. Call `_on_world_rebuilt()` once now, because the view was already built before FP existed. Then `from_dict({})` to spawn the player.

`_on_world_rebuilt()`:

1. `collision.rebuild_all()` and `directory.rebuild()`.
2. `player.snap_to_ground()`.
3. Call `on_world_rebuilt()` on every feature, in registry order.
4. `bus.world_ready.emit()`.

### 7.2 Input handled by FpMode (`_unhandled_input`)

FpMode only reacts to events that nobody consumed. Any open UI (chat, pause menu, map, dialogue) handles its own keys, Esc included, and calls `get_viewport().set_input_as_handled()`.

**Input rule for every slice (binding, D-S0-17).** Discrete actions (`interact`, `photo_mode`, `map_toggle`, `chat_open`, `pause_menu`, `time_*`, `hud_toggle`, `quick_*`) fire **only** from `_unhandled_input(event)` on `event.is_action_pressed(name) and not event.is_echo()`. Never poll them with `Input.is_action_just_pressed`: probes showed that polling still sees a key a UI already consumed with `set_input_as_handled()` (so a card closed with E reopens in the same frame) and still sees letters typed into a focused LineEdit. Only continuous state (`move_*`, `sprint`, `crouch`, `jump` held) is polled. A focused LineEdit eats Esc before `_unhandled_input`, so any UI with a text field catches `pause_menu` in `_input()` while it is open (see `slices/C-chat.md` §2). Tests inject actions with `Input.parse_input_event(ev)` where `ev` is an `InputEventAction` (`action = "interact"`, `pressed = true`), then `Input.flush_buffered_events()`, then one frame; a probe confirmed this reaches `_unhandled_input` headless. `Input.action_press` does not.

**Hotkeys are blocked by other UIs.** `time_faster`, `time_slower`, `time_skip`, `hud_toggle`, `quick_save` and `quick_load` are ignored while `ctx.is_modal()` and the only modal is not `&"pause"` (`ctx.is_modal() and not (ctx.modal_count() == 1 and ctx.has_modal(&"pause"))`). The pause card advertises F5 and F9, so they work while paused, but never under chat, talk, the map, a card or the poster viewer. A probe showed F9 still reaches `_unhandled_input` with a LineEdit focused.

| Action | Effect |
|---|---|
| `pause_menu` (Esc) | `set_paused(not paused)` |
| `time_faster` (`]`) / `time_slower` (`[`) | `step_time_scale(+1 / -1)` and a toast `"Time 4x"` |
| `time_skip` (T) | `skip_to_morning()` |
| `hud_toggle` (F1) | `hud.set_hud_visible(not hud.is_hud_visible())`; ignored while `player.photo_mode` |
| `quick_save` (F5) / `quick_load` (F9) | `main.save_game()` / `main.load_game()` |
| left mouse press while the mouse is not captured and `not ctx.is_modal()` and not paused | recapture the mouse |

**After a load or New City** every slice closes its transient UI (cards, map, chat input, talk dialogue, poster viewer), pops its modals and ends conversations, on `bus.world_ready` and in its feature's `from_dict()`. Loading replaces `residents.people` (`residents.gd:94`), so any stored resident dictionary is stale.

The mouse rule (`_update_mouse_mode()`): the mouse is `MOUSE_MODE_CAPTURED` iff not paused, `not ctx.is_modal()`, and the window has focus. Otherwise it is `MOUSE_MODE_VISIBLE`. The rule is re-evaluated on `bus.modal_changed`, on `pause_changed`, and on `NOTIFICATION_APPLICATION_FOCUS_IN/OUT`. Headless runs skip it, which is detected with `DisplayServer.get_name() == "headless"`.

Pause:

- `set_paused(true)` does `get_tree().paused = true`, `ctx.push_modal(&"pause")` and `bus.pause_changed.emit(true)`.
- `set_paused(false)` does the reverse and re-applies `time_scale`.
- FpMode and FpHud are `PROCESS_MODE_ALWAYS`. The player, features, CityView, CitySim and SkyDirector are pausable, so pause freezes the world.

### 7.3 Spawn point

1. Find the `D.HALL` tile in `sim.active`. A new city puts it at (15, 14) (`city_sim.gd:162`).
2. Let `r = directory.frontage(hall)`.
3. If `r >= 0`: `pos = Vector3(tx(r), 0, ty(r)) + dir * WS.SIDEWALK_CENTER`, where `dir` is the unit step from the road tile toward the hall. Yaw faces the hall.
4. Otherwise, use the road tile nearest to `(15.5, 13.5)` and stand on `RoadTopology.sidewalk_point(sim, i, +1)`, facing along the run.
5. If there are no roads at all, use `(15.5, 0, 13.5)`.
6. In every case, y is `collision.ground_height(pos)`.

---

## 8. `scripts/fp/fp_context.gd` (`class_name FpContext extends RefCounted`)

```gdscript
class_name FpContext
extends RefCounted
## Service locator for first-person slices. FpMode fills it once in setup(); fields never change
## identity until FpMode.teardown() (CityView keeps its identity across view.setup()).

const WS := preload("res://scripts/fp/world_scale.gd")
var main: Node3D                  # main.gd; call main.save_game(), main.focus(), main.notify(), main.exit_fp()
var mode: FpMode
var sim: CitySim
var residents: Residents          # may be inactive (GRIDFALL_RESIDENTS=0): check residents.is_active()
var minds: ResidentMinds
var brain: CityBrain
var client: GmiClient
var view: CityView
var sky: SkyDirector
var audio: GridFallAudioDirector
var sun: DirectionalLight3D
var env: Environment              # the shared Environment (Main.camera.environment), mutated by SkyDirector
var bus: GameBus
var player: FpPlayer
var hud: FpHud
var collision: CollisionWorld
var directory: CityDirectory
var world_root: Node3D            # FpMode/World: put in-world FP nodes here, never under CityView
var features: Dictionary = {}     # feature_id -> FpFeature
var settings: Dictionary = {}     # see FpMode.DEFAULT_SETTINGS; change only via mode.apply_settings()
var ws: GDScript = WS             # convenience; prefer your own `const WS := preload(...)` for typing
var _modal: Dictionary = {}       # owner StringName -> true

## The registered feature with this id, or null.
func feature(id: String) -> FpFeature
## A UI that needs the mouse and keyboard (chat input, pause menu, map, dialogue) pushes itself;
## while any owner is pushed, the player ignores movement and look, and the mouse is visible.
func push_modal(owner: StringName) -> void      # emits bus.modal_changed(true) on 0 -> 1
func pop_modal(owner: StringName) -> void       # emits bus.modal_changed(false) on 1 -> 0
func is_modal() -> bool
func has_modal(owner: StringName) -> bool
func modal_count() -> int
## Feet position of the player (world units). Without a player (some unit tests): mode.spawn_point().pos
## when mode is set up, else Vector3.ZERO.
func player_position() -> Vector3
## Tile index under the player (D.idx), or -1 outside the world.
func player_tile() -> int
```

---

## 9. `scripts/fp/game_bus.gd` (`class_name GameBus extends Node`)

The bus only carries signals. It holds no state. Slices may **emit** and **connect**. New signals are added by request to S0's owner (the integrator).

```gdscript
class_name GameBus
extends Node
## Signals that cross first-person slices. Emitters and listeners are listed in docs/fp/S0-foundation.md §9.

signal ping(world_pos: Vector3, reason: String)
signal toast(text: String, kind: String)
signal interact_target_changed(target: Dictionary)
signal interact_requested(target: Dictionary)
signal talk_requested(resident_id: String)
signal conversation_changed(resident_id: String, active: bool)
signal chat_posted(msg: Dictionary)
signal poster_ready(poster: Dictionary)
signal player_tile_changed(x: int, y: int)
signal time_scale_changed(scale: int)
signal settings_changed(settings: Dictionary)
signal pause_changed(paused: bool)
signal quality_changed(preset: String)
signal modal_changed(active: bool)
signal world_ready()
## A button on a place card: action "ask_here" (C answers through brain.inspect_tile). Emitted by B.
signal card_action(action: String, tile: int)
## The hero got into a car (true) or out of it (false). Emitted by the drive feature.
signal drive_changed(active: bool)
## The player's car hit something hard: the contact point, the closing speed (u/s) and what was
## hit, "wall" (anything fixed) or "car". Emitted by the drive feature.
signal car_impact(at: Vector3, speed: float, what: String)
## The driver's door of the player's car opened (true) or slammed shut (false), at its handle.
## Emitted by the drive feature.
signal car_door(at: Vector3, open: bool)
## A street prop was knocked over at a point (its StreetDressing kind: "bin", "bench" ...) and
## flies off at speed (u/s). Emitted by the props feature.
signal prop_knocked(at: Vector3, kind: String, speed: float)
## Someone on foot was hit at a point (their feet): cause "shove" or "punch" (the hero), "car"
## (the car the player drives) or "carjack" (dragged out of the car the player takes); info is
## traffic_feature.gd hit_walker()'s {"walker", "resident_id", "name", "down", "street",
## "strength", "witnesses", "crew"}. Emitted by traffic.
signal person_hit(at: Vector3, cause: String, info: Dictionary)
## The hero swung, gestured or got over something: action "jab", "cross", "shove", an emote
## ("wave", "yes", "no", "shout", "dance") or a parkour move ("vault", "hop", "climb", "roll" off
## a hard landing, or "grab" taking hold of a wall), as it starts, at their feet. Emitted by the
## actions and parkour features.
signal hero_action(action: String, at: Vector3)
## Someone answered the hero: a resident face to face (their id and name), or whoever answered
## "Ask someone here" (resident_id "" and their role, "Shopkeeper"). reply is filtered for
## display. Emitted by chat.
signal talk_replied(resident_id: String, speaker: String, reply: String)
## The player filed a story for the Gazette: reporter_feature.gd file_story()'s {"agent",
## "headline", "place", "quote", "by", "tile", "district", "day", "scoop", "local", "sharp",
## "points", "text"}. Emitted by the reporter feature; chat runs "text" as a Gazette line.
signal story_filed(story: Dictionary)
## Something struck the hero on foot: at is where the blow came from (a fist, a car's front, a
## dog's jaws), cause "punch" (someone fighting back), "car" (a car that could not stop for them)
## or "bite" (a dog defending its owner), strength 0..1 and push the xz velocity (u/s) it throws
## the hero along. Emitted by traffic and the animals feature; the health feature takes the damage.
signal hero_hit(at: Vector3, cause: String, strength: float, push: Vector3)
## The hero lost amount of health to cause: "punch", "car" or "bite" (hero_hit), "crash" (in the
## car they drive) or "fall" (a hard landing); health is what is left (0..100, 0 knocked out) and
## down is true when it put them on the ground. Emitted by the health feature.
signal hero_hurt(amount: float, cause: String, health: float, down: bool)
## An animal called out at a point (its head): a dog's "bark", "growl" or "whine", a pigeon's
## "coo", a lone pigeon's "flap" or a flock's "takeoff"; size is its height at the shoulder (m),
## so a small dog yaps higher. Emitted by the animals feature.
signal animal_called(at: Vector3, call: String, size: float)
```

| Signal | Payload | Emitted by | Typical listeners |
|---|---|---|---|
| `ping` | `world_pos` in world units at y = 0. `reason`: `"event:<type>"`, `"resident:<id>"`, `"tile"`, `"district:<mi>"`, `"player"` (waypoint set on the map) | `Main.focus()` (S0); B's map (`"player"`) | B (minimap and compass marker, toast), I (alert blip) |
| `toast` | `kind`: `info`, `alert`, `success`, `system` | `Main.notify()`, FpMode, any slice | B (S0 placeholder until then) |
| `interact_target_changed` | target dict (below), `{}` when nothing is targeted | A | B (centre prompt) |
| `interact_requested` | target dict | A (E pressed) | B (building and vehicle cards), D (`kind == "poster"`), Integration: animals (`kind == "dog"`: pets it; `kind == "pigeons"`: throws the flock crumbs) |
| `talk_requested` | resident id | A (E on a resident within `TALK_RANGE`) | C |
| `conversation_changed` | id, active | C | E (stop the agent and face the player), I (duck ambience) |
| `chat_posted` | chat message dict (below) | C | I (chat blip), B (unread badge on the minimap, optional) |
| `poster_ready` | `{"key": String, "kind": String, "texture": Texture2D, "meta": Dictionary}` | D | B (optional "new poster" toast) |
| `player_tile_changed` | tile x, y | FpPlayer (S0) | B (street label), C (district tab), I (area ambience), E (spawn ring) |
| `time_scale_changed` | 1, 2, 4 or 8 | FpMode | B, E, I |
| `settings_changed` | full settings dict | FpMode | A (fov, sensitivity, bob), I (volumes), B |
| `pause_changed` | paused | FpMode | B (pause menu), I (pause bus) |
| `quality_changed` | `"low"`, `"medium"` or `"high"` | FpMode | G2 (presets), G1 (light profile) |
| `modal_changed` | any modal UI is open | FpContext | A, B |
| `world_ready` | none | FpMode after `on_world_rebuilt` | B (minimap full repaint), B, C, D (close transient UI, §7.2) |
| `card_action` | `"ask_here"`, tile index | B (place-card button) | C (the "Ask someone here" answer) |
| `drive_changed` | in a car | Integration: driving (getting in and out) | A's interact (no targets from behind the wheel), the phone (puts itself away) |
| `car_impact` | `at`: the contact point, at half the car's height. `speed`: the closing speed (u/s), at least 1.5 m/s. `what`: `"wall"` or `"car"`. The hardest hit of a step, at most one every 0.25 s; knocked props report themselves | Integration: driving | I (crash sound at the contact) |
| `car_door` | `at`: the driver's door handle. `open`: `true` as the latch lets go (the pull on the handle getting in, the door starting to open getting out), `false` as the door slams shut | Integration: driving (the `car_doors` climb in and out) | I (the latch and the slam at the door) |
| `prop_knocked` | `at`: where it was hit (by the player's car, the hero, someone walking, traffic or another prop). `kind`: its StreetDressing kind. `speed`: how fast it flies off (u/s); a fallen prop hit again reports from 1 m/s | Integration: props | I (clatter, clang or thud by kind) |
| `person_hit` | `at`: the person's drawn feet. `cause`: `"shove"` or `"punch"` (the hero), `"car"` (the car the player drives) or `"carjack"` (dragged out of the car the player takes). `info`: `walker` (the walker id), `resident_id` and `name` (`""` for an ambient walker), `down` (knocked down), `street` (the street label, may be `""`), `strength` 0..1, `witnesses` (the resident ids of those who saw it), `crew` (`"police"`, `"ambulance"` or `""`: the crew this blow called) | E (`hit_walker`, called by Integration: body actions and by the drive feature's car body; `carjack.gd` when the player takes a car from its driver) | C (the victim's and a witness's lines, a crew's City Alert card), I (the blow and the fall), Integration: animals (the dog of someone the hero punches or shoves goes for the hero; the dogs within 8 m flinch) |
| `hero_action` | `action`: `"jab"`, `"cross"` or `"shove"` as a swing starts, or the emote as it starts (`"wave"`, `"yes"`, `"no"`, `"shout"`, `"dance"`), or the parkour move as it starts (`"vault"`, `"hop"`, `"climb"`, `"roll"` off a hard landing, or `"grab"` taking hold of a wall). `at`: the hero's feet | Integration: body actions, Integration: parkour | I (the whoosh of a swing, the thud of a roll), Integration: animals (a swing, a shove or a shout startles the dogs close by; a wave cheers the friendly ones) |
| `talk_replied` | `resident_id`: the resident's id, `""` for the "Ask someone here" answer. `speaker`: the resident's name, or the role that answered (`"Shopkeeper"`). `reply`: the line as shown | C (`talk_dialog.gd`: each reply face to face, and the ask answer) | Integration: reporter (the quote for the story on assignment) |
| `story_filed` | the story as filed: `agent` (`"0"`..`"4"`, `"council"` or `"chaos"`), `headline`, `place`, `quote`, `by`, `tile` (index), `district`, `day`, `scoop`, `local`, `sharp`, `points`, `text` (the Gazette's line) | Integration: reporter (K files) | C (a Gazette line in the chat and a chatter topic) |
| `hero_hit` | `at`: where the blow came from (the fist of someone fighting back, at shoulder height; a car's front, half a metre up). `cause`: `"punch"` (`fight_back`), `"car"` (`hit_by_cars`) or `"bite"` (a dog defending its owner, from its head). `strength` 0..1 (a jab 0.45, a cross 0.6; a car its speed over 14 m/s; a bite 0.25). `push`: the xz velocity (u/s) it throws the hero along (a car's heading at its speed; a bite 0.6 m/s away from the dog) | E (`reactions.gd` through `on_hero_hit`, `vehicles.gd` through `on_hit_player`), Integration: animals (`bite`); only while the hero is on foot, in control and the health feature is on | Integration: health (the damage, the flinch or the knock-down) |
| `hero_hurt` | `amount`: the health it took. `cause`: `"punch"`, `"car"`, `"bite"`, `"crash"` (`car_impact` over 7 m/s) or `"fall"` (landing over 6 m/s). `health`: what is left, 0..100 (0: knocked out). `down`: it put the hero on the ground | Integration: health | I (the thump of a punch or a car on the hero, a bite's snap at the knee, and their fall) |
| `animal_called` | `at`: the animal's head. `call`: a dog's `"bark"` (each bark of a volley), `"growl"` or `"whine"`; a pigeon's `"coo"`, a lone pigeon's `"flap"` (fluttering off) or a flock's `"takeoff"` (going up together). `size`: its height at the shoulder (m) | Integration: animals | I (one of three barks, a growl or a whine at the head, pitched by size; one of two coos, a flutter or a flock's clatter of wings) |

The **target** dict: `{"kind": "resident"|"building"|"poster"|"vehicle"|"pedestrian"|"dog"|"pigeons", "id": String, "tile": int, "pos": Vector3, "dist": float, "label": String, "data": Dictionary}`.

- `label` is the prompt text, for example `"Talk to Priya Gupta, nurse"` or `"Maple Street Bakery"`.
- `data` holds kind-specific fields.
- Kind ownership: `"resident"` is a **named resident** you can talk to (A's own candidates, or E's `pick()` for a resident on foot); `"vehicle"` is a car, bus or truck (`data.driver_id` names the resident driver when there is one); `"pedestrian"` is **only** an ambient, unnamed walker; `"dog"` is a dog within reach to pet (Integration: animals' `pick()`; `data.breed`, and `data.owner` the owner's resident id or `""`); `"pigeons"` is a flock to feed (Integration: animals' `pick()`; `id` the flock's key, `pos` where the view meets the ground, `data.birds`). A target of kind `"resident"` opens C's conversation, never B's card.

The **chat message** dict: `{"seq": int, "author_id": String, "author": String, "role": "resident"|"mayor"|"press"|"council"|"system"|"player", "district": int, "text": String, "kind": String, "day": int, "clock": String, "t_ms": int, "reply_to": int, "refs": Dictionary}`.

- `t_ms` is the chat feed's own clock (`ChatFeed.now_ms`, advanced only by `pump(dt)`), not the wall clock, so tests are deterministic.
- `reply_to` is -1 when the message is not a reply.
- `refs` hold only String or int values (JSON round-trips). Loaders cast `seq`, `reply_to`, `day`, `district` and int refs back to int, because Godot's JSON parser returns floats.

---

## 10. Features: `fp_feature.gd`, the registry and the stubs

### 10.1 Base class

```gdscript
class_name FpFeature
extends Node3D
## A first-person feature module owned by one slice. FpMode instantiates it from the registry,
## adds it under FpMode/Features (Node3D at identity, so children are in world space) and drives
## the lifecycle: setup -> on_world_rebuilt (after every view.setup) -> to_dict/from_dict -> teardown.

var ctx: FpContext

## Stable id; also the key in ctx.features and in save["fp"]. Override.
func feature_id() -> String:
	return ""
## Store ctx, connect signals, build nodes that do not depend on the city geometry.
func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
## The city view was rebuilt (boot, load, New City). Re-attach anything tied to tiles.
func on_world_rebuilt() -> void:
	pass
## Feature state for save["fp"][feature_id()]. Return {} for nothing.
func to_dict() -> Dictionary:
	return {}
## Restore state; d is {} for a fresh city or an old save.
func from_dict(_d: Dictionary) -> void:
	pass
## Disconnect from long-lived objects (sim, view, residents, brain, bus); FpMode frees the node after.
func teardown() -> void:
	pass
## Interaction pick along a ray (A's interact queries every feature). Return a target dict
## (§9) or {} when this feature owns nothing on the ray within max_dist.
func pick(_origin: Vector3, _dir: Vector3, _max_dist: float) -> Dictionary:
	return {}
## Called by the FP smoke after the world is up. {"ok": bool, "detail": String}.
func self_test() -> Dictionary:
	return {"ok": true, "detail": "stub"}
## Extra named eye-level shots for the FP photo tour:
## [{"name": String, "pos": Vector3 (feet), "yaw": float deg, "pitch": float deg, "hour": float,
##   "prepare": String (optional), "restore": String (optional)}].
## "prepare" / "restore" name methods on this feature that the tour calls (no arguments) before
## the shot is placed and after it is saved, for example forcing rain and clearing it again.
func photo_shots() -> Array:
	return []
```

### 10.2 Registry: `scripts/fp/fp_features.gd`

```gdscript
extends RefCounted
## Every first-person feature, in setup order. Pre-populated by S0; slices edit only their own
## feature file, never this list.
const FEATURES := [
	{"id": "sim_perf", "slice": "F", "path": "res://scripts/fp/sim/sim_perf_feature.gd"},
	{"id": "streetscape", "slice": "G1", "path": "res://scripts/fp/street/streetscape_feature.gd"},
	{"id": "render_opt", "slice": "G2", "path": "res://scripts/fp/render/render_opt_feature.gd"},
	{"id": "traffic", "slice": "E", "path": "res://scripts/fp/traffic/traffic_feature.gd"},
	{"id": "interact", "slice": "A", "path": "res://scripts/fp/interact/interact_feature.gd"},
	{"id": "hud_widgets", "slice": "B", "path": "res://scripts/fp/ui/hud_widgets_feature.gd"},
	{"id": "chat", "slice": "C", "path": "res://scripts/fp/chat/chat_feature.gd"},
	{"id": "posters", "slice": "D", "path": "res://scripts/fp/posters/poster_feature.gd"},
	{"id": "audio", "slice": "I", "path": "res://scripts/fp/audio/audio_feature.gd"},
]
```

H has no runtime feature. It owns assets and `asset_paths.gd`.

### 10.3 Stub template (one per row, S0 writes all nine)

```gdscript
extends FpFeature
## Traffic and pedestrians on lanes (slice E). S0 stub: inert until slice E lands.

func feature_id() -> String:
	return "traffic"
```

Stubs have no class_name. A slice may split its feature into more files under its own directory. The registered file stays the entry point.

---

## 11. `scripts/fp/player/player.gd` (`class_name FpPlayer`, minimal; owned by A)

```gdscript
class_name FpPlayer
extends Node3D
## First-person walker: feet at `position`, camera at eye height. Kinematic only (no physics
## bodies); collides through ctx.collision. S0 version: walk, run, mouse look, ground snap,
## building and water blocking.

const WS := preload("res://scripts/fp/world_scale.gd")
var ctx: FpContext
var camera: Camera3D
var yaw: float = 0.0        # radians; rotation.y of the body. Forward = (-sin(yaw), 0, -cos(yaw)).
var pitch: float = 0.0      # radians, clamped to ±PITCH_LIMIT_DEG; rotation.x of the camera
var velocity: Vector3 = Vector3.ZERO
var input_enabled: bool = true   # false for tests and scripted tours
var photo_mode: bool = false     # A's free-fly photo mode; FpMode ignores hud_toggle and C ignores chat_open while true

func setup(p_ctx: FpContext) -> void
## Places the feet at pos (y snapped to the ground when snap is true) and faces yaw/pitch (degrees).
func teleport(pos: Vector3, yaw_deg: float, pitch_deg: float = 0.0, snap: bool = true) -> void
## Faces a world point (yaw and pitch).
func look_toward(target: Vector3) -> void
func eye_position() -> Vector3
func forward() -> Vector3
## Tile index under the feet or -1.
func tile() -> int
func snap_to_ground() -> void
## One deterministic movement step; _process calls it with the input state, tests call it directly.
## wish: x = strafe right, y = forward, each -1..1. While ctx.is_modal(), simulate itself zeroes
## wish and jump (gravity and ground snap still run), so tests and _process behave the same.
## S0 ignores crouch and jump; A implements them without changing the signature.
func simulate(wish: Vector2, sprint: bool, delta: float, crouch: bool = false, jump: bool = false) -> void
func to_dict() -> Dictionary        # {"pos": [x, y, z], "yaw": deg, "pitch": deg}
func from_dict(d: Dictionary) -> void   # {} -> ctx.mode.spawn_point()
```

S0 behaviour:

- **Camera.** `camera = Camera3D.new()` at `position.y = WS.EYE`, with `near = WS.CAMERA_NEAR`, `far = WS.CAMERA_FAR` and `fov = ctx.settings.fov`. Set `camera.environment = ctx.env`, which is the **same resource** as `Main.camera.environment`, so SkyDirector's sky, fog, ambient and exposure changes apply. Then `camera.make_current()`.
- **Look.** In `_unhandled_input` handle `InputEventMouseMotion` when `Input.mouse_mode == MOUSE_MODE_CAPTURED` and `not ctx.is_modal()` by calling the public `mouse_look(event)`: `yaw -= rel.x * sens` and `pitch -= rel.y * sens * (-1 if invert_y else 1)`, where `rel` is `event.screen_relative`, never `event.relative`. The root window stretches (`canvas_items`, 1600×900 base, `expand`), and Godot scales `relative` by the inverse stretch: a 100 px move measured 0.352 rad at 1000×600 and 0.44 rad at 800×450 instead of 0.22, and 2500 px in the 64×64 headless window. `screen_relative` is the unscaled pixel delta, so `mouse_sensitivity` stays radians per screen pixel at every window size.
- **Move.** When `input_enabled`, `_process` reads `Input.get_vector("move_left", "move_right", "move_back", "move_forward")`, `Input.is_action_pressed("sprint")`, `"crouch"` and `"jump"`, and calls `simulate(...)` with the frame delta clamped to `MAX_FRAME_DELTA` (0.1 s, so a sim tick stall of 0.7–2.7 s moves the player one 10 fps frame's worth instead of lurching ahead); when `input_enabled` is false, `_process` does not move the player at all (tests and tours drive `simulate()` or `teleport()` themselves). The modal gate lives inside `simulate`. Speed is `WALK` or `RUN`. Velocity approaches the target at `ACCEL`.
- **Collide.** `simulate` splits `delta` into `n = ceil(max(|velocity|, |target|) * delta / PLAYER_RADIUS)` equal sub-steps (at least 1), so no collision step moves farther than `PLAYER_RADIUS`: `move_and_slide` tests only the destination, and a 0.008 u hoarding grown by the radius is only 0.038 u thick, which one 0.17 s step at `RUN` would jump. Each sub-step accelerates, then `new_pos = ctx.collision.move_and_slide(position, velocity * h, WS.PLAYER_RADIUS)`, then clamps to the world rect `[X0 − 0.5 + r, X0 + W − 0.5 − r]`. A velocity component whose move was not applied (blocked by a box, water or the world edge) drops to zero, so pushing into a wall does not keep full speed. Any `delta` is therefore safe to pass to `simulate`; A keeps this guard (`slices/A-player.md`).
- **Ground.** `position.y` approaches `collision.ground_height(position)` at 20 /s. Snap it when the gap is above `0.05`. S0 has **no step limit, no jump and no crouch**; A adds them.
- **Tile events.** Emit `bus.player_tile_changed(x, y)` when `tile()` changes.
- **Settings.** On `bus.settings_changed`, re-read `fov` and `mouse_sensitivity`.

---

## 12. `scripts/fp/world/collision_world.gd` (`class_name CollisionWorld`, minimal; owned by A)

This is analytic collision: no physics engine. A keeps every signature below when it replaces the internals.

```gdscript
class_name CollisionWorld
extends Node
## Analytic first-person collision: walkable ground height per point, building boxes per tile
## (from CityView.building_aabb), water. Deterministic and headless-safe.

var ctx: FpContext
func setup(p_ctx: FpContext) -> void
## Drops every cached box (after view.setup).
func rebuild_all() -> void
func on_tile_built(i: int, _holder: Node3D) -> void   # invalidates tile i's cached box
func on_tile_cleared(i: int) -> void
## Tile index at a world point (round x/z, D.idx) or -1 outside the world.
func tile_at(p: Vector3) -> int
## World y of the walkable surface at p.x/p.z; NAN when not walkable (water, bridge parapet).
func ground_height(p: Vector3) -> float
## Surface name for footsteps and audio: "asphalt"|"sidewalk"|"lot"|"grass"|"dirt"|"water"|"bridge".
## Mapping in the table below; A keeps it.
func surface_at(p: Vector3) -> String
## True if a circle of `radius` at p (feet) intersects a building box or unwalkable ground.
func is_blocked(p: Vector3, radius: float) -> bool
## Moves from `from` by `motion` (y ignored), sliding along blockers. S0: try full move, else x-only,
## else z-only, else stay. When `from` already overlaps a box (a building or site appeared where
## the player stands), a candidate is also accepted if it enters no new box and goes no deeper into
## the ones it overlaps, so the player can always walk out. Returns the new feet position (y unchanged).
func move_and_slide(from: Vector3, motion: Vector3, radius: float) -> Vector3
## The closest point to p (xz, y on the ground) where a circle of `radius` is not blocked, searched
## on rings 1 m apart out to max_dist; Vector3(NAN, NAN, NAN) when there is none.
func nearest_free(p: Vector3, radius: float, max_dist: float) -> Vector3
## Ray against building boxes (tile DDA, ≤ max_dist) and the ground.
## {"hit": bool, "pos": Vector3, "normal": Vector3, "tile": int, "kind": "building"|"ground", "dist": float}
func raycast(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary
## Blocking bodies on tile i for movement, world space. S0 returns [box(i)] when box(i) has a size,
## else []. A replaces it with per-part bodies (at most 4 per building) plus a site box.
func boxes(i: int) -> Array[AABB]
## Merged bound of boxes(i) (AABB() when none). Movement and tests use boxes(); interaction
## raycasts use the full view.building_aabb(i).
func box(i: int) -> AABB
```

**Tests never assert against `view.building_aabb`.** Movement tests (S0's and every slice's) assert that the feet never end inside any `collision.boxes(i)` grown by `PLAYER_RADIUS * 0.99`, so A can tighten bodies without breaking S0's tests.

`surface_at` mapping (A keeps it; I relies on it):

| Where | Surface |
|---|---|
| Road tile, carriageway (`is_carriageway`) | `"asphalt"` (`"bridge"` when `is_bridge`) |
| Road tile, sidewalk band or end island | `"sidewalk"` (`"bridge"` when `is_bridge`) |
| `EMPTY`, `FOREST`, `PARK`, zones at level 0, out of world | `"grass"` |
| `SITE`, `RUBBLE` | `"dirt"` |
| Zones at level > 0, every other service kind | `"lot"` |
| `WATER` terrain that is not a road | `"water"` |

S0 ground model, using `i = tile_at(p)` and `lp = (p.x − tx, p.z − ty)`:

| Tile | Height |
|---|---|
| `ROAD` | `RoadTopology.surface_height(sim, i, lp)` |
| `ZONE_R` at level > 0, any service kind | `LOT_TOP` |
| `ZONE_C` / `ZONE_I` at level > 0, `RUBBLE` | `PAD_TOP` |
| `WATER` terrain that is not a road | `NAN` (blocked) |
| anything else (`EMPTY`, `FOREST`, `SITE`, level-0 zones, out of world) | `GROUND_Y` |

Building blocking: `boxes(i)` is `ctx.view.building_aabb(i)` (when non-empty) followed by every box of `ctx.view.site_boxes(i)` (the construction kit's parts: hoarding segments, machines, the crane mast, …; §15.1), cached per tile until `tile_built` / `tile_cleared`; `box(i)` is their merged bound. Site parts can reach into a neighbouring tile (a crane base stands up to 0.2 u past the tile edge), which the 3×3 search covers. `is_blocked` checks the 3×3 tiles around `p`. The point is blocked if, in xz, the circle overlaps any box in `boxes(j)` grown by `radius`, and `p.y < box.end.y`; `_overlaps` and the walk-out rule key each box by `Vector2i(tile, index)`, and `raycast` tests each box. Note that the real-model AABB includes the 0.94 lot slab, so in S0 the player cannot step onto lots at all. A refines this with per-surface body boxes (see `slices/A-player.md`) or H's `ColBox_<n>` proxies.

**Boxes can appear under the player.** The player may stand on empty land or a level-0 lot, and the sim can open a site or level the lot up under them. Two rules keep them free, and A keeps both when it replaces the internals: `move_and_slide` lets a player who already overlaps a box move as long as the move enters no new box and does not go deeper (depth = distance to the nearest side of the grown box), and FpMode's `_on_tile_built` (§7.1) moves the player to `nearest_free` when a tile within one of theirs is rebuilt around them. `fp_core_test` and the FP smoke cover both.

Performance: `is_blocked` costs at most 9 dictionary lookups and allocates nothing per frame.

---

## 13. `scripts/fp/ui/fp_hud.gd` (`class_name FpHud`, shell; owned by B)

```gdscript
class_name FpHud
extends CanvasLayer
## First-person HUD shell: named slot Controls the HUD, chat and other slices fill. S0 ships
## placeholders (status line, crosshair, toasts, pause card) so FP is usable before slice B.

const SLOTS := ["top_bar", "minimap_slot", "chat_slot", "center", "toasts", "overlay"]
var ctx: FpContext
var root: Control
func setup(p_ctx: FpContext) -> void
## The slot Control by name (one of SLOTS); asserts on unknown names.
func slot(slot_name: String) -> Control
## Hides or shows every slot except "overlay" (F1 and photo mode).
func set_hud_visible(v: bool) -> void
func is_hud_visible() -> bool
## Queues a toast in the "toasts" slot. kind: info|alert|success|system|chat.
func show_toast(text: String, kind: String = "info") -> void
```

Layer: `layer = 10`, `process_mode = PROCESS_MODE_ALWAYS`. `root` is a full-rect Control with `mouse_filter = MOUSE_FILTER_IGNORE`. Every slot is a plain `Control` with `mouse_filter = MOUSE_FILTER_IGNORE`. A slice whose UI needs clicks sets `STOP` on its own children, and only while that UI is modal.

Slot geometry (anchors and offsets in the 1600×900 base viewport, `canvas_items` stretch):

| Slot | Anchors | Offsets (left, top, right, bottom) | Purpose |
|---|---|---|---|
| `top_bar` | top-wide | 16, 12, −16, 64 | indicator chips (B) |
| `minimap_slot` | bottom-left | 16, −252, 252, −16 (236×236) | circular minimap (B) |
| `chat_slot` | left-wide (top 0, bottom 1) | 0, 80, 460, −268 | CoC-style chat panel and edge tab (C) |
| `center` | full-rect | 0, 0, 0, 0 | crosshair and interact prompt (B) |
| `toasts` | center-top | −320, 76, 320, 236 | toasts and alert banner (B) |
| `overlay` | full-rect | 0, 0, 0, 0 | pause menu, full map, dialogue, poster viewer (B, C, D) |

Fitting the slots: the minimap slot ends 16 px above the screen bottom, so B draws a 200 px circle at the top of `minimap_slot` and the street label inside the same slot, below the circle (y 216–236 of the slot). C's chat panel is 440 px wide, left-aligned in the 460 px `chat_slot`; the remaining 20 px on its right hold the edge tab.

S0 placeholders, all of which B may replace. Whatever B puts in `top_bar` must show `Day <n>` in a `Label` or `RichTextLabel` (the FP smoke reads it there, §17.4 step 8):

- A `Label` in `top_bar` refreshed at 4 Hz: `"Day %d · %s · Pop %s · Mood %.1f/10 · $%s · %dx"`. The fields are:
  - `sim.day`
  - `ctx.sky.clock_text()`
  - `sim.stats.population` with thousands separators
  - mood = `residents.sentiment.mood * 10` when `residents.is_active()`, otherwise `stats.happiness * 10`
  - `sim.total_funds()`
  - `mode.time_scale`

  The font is `res://fonts/lilita_one_regular.ttf` at 18 px with an outline of 6.
- A centre crosshair: a 4×4 px white `ColorRect` at 85% alpha.
- Toasts: up to 4 Labels in a VBox. Each fades out after 4 s. The panel is fed by `bus.toast`, and by `bus.ping` as `"Attention: <reason label> near <directory.place_label(tile)>"`.
- A pause card in `overlay` that shows while paused: `"Paused · Esc resume · F5 save · F9 load · F1 hide HUD"`.

No placeholder may show model names, sources or latencies (D5, D6).

---

## 14. `scripts/fp/city_directory.gd` (`class_name CityDirectory extends RefCounted`)

The directory gives deterministic human place names. They depend only on `sim.city_seed` and the tile arrays, so two instances on the same sim always agree. That is how G1 can build its own instance in orbit mode. The consumers are B (street label, map labels), C (chat and prompts), D (shop ads, notices), G1 (building orientation, street signs), A (interact labels) and E (driver cards).

```gdscript
class_name CityDirectory
extends RefCounted
## Human place names for the city: streets for road runs, addresses for lots, business and
## landmark names, district names. Deterministic from sim.city_seed; never uses sim.rng.

var sim: CitySim
func setup(p_sim: CitySim) -> void
## Recomputes the seed-dependent permutations (call after load / New City; cheap).
func rebuild() -> void
## Name of the street a road tile belongs to ("Maple Street", "Delgado Avenue"); for a junction the
## name of its longer run. "" for non-road tiles.
func street_name(i: int) -> String
## "Maple Street & Delgado Avenue" for junction tiles (3+ arms), else street_name(i).
func intersection_name(i: int) -> String
## The road tile lot i fronts (4-neighbour ROAD with the longest run; ties S, E, N, W), or -1.
func frontage(i: int) -> int
## Yaw in degrees that turns a model's +Z face toward frontage(i) (S=0, E=90, N=180, W=-90); NAN if none.
func frontage_yaw(i: int) -> float
## "214 Maple Street" for a lot with frontage; "" otherwise.
func address(i: int) -> String
## Business name for a ZONE_C / ZONE_I tile at level > 0 ("Alvarez's Bakery"), else "".
func business_name(i: int) -> String
## "bakery", "warehouse", ... for C/I lots at level > 0, else "".
func business_kind(i: int) -> String
## Landmark name for a service tile ("GridFall City Hall", "Maple Street Fire Station"), else "".
func landmark_name(i: int) -> String
## Best name for a tile: landmark, business, apartment name (R2/R3 "Maple Court"), else "".
func place_name(i: int) -> String
## Best label for a tile: place_name, else address, else street_name, else district_name.
func place_label(i: int) -> String
## District name: D.MAYORS[d]["district"] for claimed land, "the river" on water, else "the frontier".
func district_name(i: int) -> String
## Mayor display name for district d (D.MAYORS[d]["display"]), "" for d < 0.
func mayor_display(d: int) -> String
## Street label for a world point: road -> intersection_name; lot -> its frontage street; else the
## nearest road within 2 tiles; else district_name.
func street_at(p: Vector3) -> String
## The name tile i will carry once a construction site finishes as (target_kind, target_level):
## the same rules as landmark_name / business_name / place_name, computed for the target instead
## of the current kind. "" when the target has no name (roads, R1 houses, demolition).
func planned_name(i: int, target_kind: int, target_level: int) -> String
```

### 14.1 Algorithms

- **Hash.** Use `_mix(a: int, b: int, c: int) -> int`, which returns `absi((a * 73856093) ^ (b * 19349663) ^ (c * 83492791)) & 0x7fffffff`. Mix the seed in as `a = sim.city_seed`.
- **Permutations.** Build them in `rebuild()` with a local `RandomNumberGenerator` whose seed is `sim.city_seed * 7907 + 11`. Fisher–Yates `perm_h` over `STREET_NAMES` (64 entries) and `perm_v` over `AVENUE_NAMES` (64 entries).
- **Street names come from coordinates, not connectivity**, so a name never changes as the city grows:
  - An E–W run in row y is named `STREET_NAMES[perm_h[(y - D.Y0) % 64]] + " Street"`.
  - A N–S run in column x is named `AVENUE_NAMES[perm_v[(x - D.X0) % 64]] + " Avenue"`.
  - Band qualifiers keep the 192-row world unique. Rows: `(y - Y0) / 64` gives 0 → `"North "`, 1 → `""`, 2 → `"South "`. Columns: 0 → `"West "`, 1 → `""`, 2 → `"East "`. The core (0..31) falls in band 1, so it has no qualifier.
- **Which run a road tile belongs to.** A tile belongs to its E–W run if it has an E or W road neighbour, and to its N–S run if it has an N or S neighbour. A junction belongs to both. `street_name` picks the longer run, counting contiguous road tiles in each direction capped at 32, and breaks ties in favour of E–W. A tile with mask 0 counts as E–W.
- **Bridges.** `place_label` of a bridge tile is `street_name + " Bridge"`. For example, `"Maple Street Bridge"`.
- **Frontage.** Look for 4-neighbour ROAD tiles. The run that counts is the one perpendicular to the lot's direction: a lot to the north or south of the road faces that road's E–W run. Pick the candidate whose run is longest, and break ties in the order S (+Z), E, N, W.
- **House numbers.** `along` is `tx(i)` for an E–W street and `ty(i)` for a N–S street. The number is `(along - D.X0) * 4 + side`, where `side = 1` when the lot is north or west of the street and `2` otherwise. The address is `"%d %s" % [number, street_name(frontage)]`.
- **Business names.** Let `h = _mix(city_seed, i, kind * 10 + level)`. `planned_name` uses the same formula with the target kind and level, so a "Coming soon" name equals the name the shop gets when it opens. The kind is `KINDS[k][level][h % n]`. The template is `h >> 8 % 4`:
  - 0 → `"<Surname>'s <Kind>"`
  - 1 → `"<StreetShort> <Kind>"`, where StreetShort is the frontage street name without its suffix
  - 2 → `"The <Adj> <Kind>"`
  - 3 → `"<Surname> & <Surname2> <Kind>"`

  Level 3 (C3, I3) uses only templates 0 and 1, without the possessive: `"Alvarez Tower"`, `"Maple Plaza"`.
- **Landmarks.**

  | Kind | Name |
  |---|---|
  | `HALL` | `"GridFall City Hall"` |
  | `STADIUM` | `"GridFall Arena"` |
  | `UNIVERSITY` | `"University of GridFall"` |
  | `AIRPORT` | `"GridFall International Airport"` |
  | `PARK` | `"<StreetShort> Park"` |
  | `FIRE` | `"Fire Station No. %d" % (1 + h % 60)` |
  | everything else | `"<StreetShort> " + LANDMARK_SUFFIX[k]` |

  `LANDMARK_SUFFIX`: `POLICE` "Police Station", `HOSPITAL` "General Hospital", `SCHOOL` "Elementary School", `COAL` "Power Station", `SOLAR` "Solar Farm", `PUMP` "Water Works", `SEWAGE` "Treatment Plant", `WIND` "Wind Farm", `TRAIN` "Station", `LANDFILL` "Recycling Yard". With no frontage, use `"<District first word> <suffix>"`.
- **R2/R3 apartment names.** `"<StreetShort> Court"` (template 0), `"<Surname> House"` (1), `"<StreetShort> Towers"` (2, R3 only), `"The <Adj> Apartments"` (3). R1 houses get `""`.

### 14.2 Name tables (exact; 64 / 64 / 48 entries)

```
STREET_NAMES = Maple Oak Cedar Birch Willow Elm Pine Aspen Chestnut Laurel Juniper Hawthorn Magnolia
  Sycamore Poplar Alder Linden Spruce Hazel Rowan Cypress Acacia Beech Holly Ivy Mulberry Hickory Walnut
  Orchard Meadow Harbor River Canal Mill Market Station Union Liberty Garden Lake Bridge Church School
  Park Spring Summit Valley Granite Copper Foundry Quarry Ferry Lantern Beacon Harvest Prospect Highland
  Clover Fern Heather Sparrow Wren Lark Kestrel
AVENUE_NAMES = Addison Barrett Calloway Delgado Easton Fairview Grafton Halsey Irving Jefferson Kensington
  Lindgren Monroe Newton Prescott Quincy Ramsey Sterling Thornton Underwood Vance Whitman Yardley Abbott
  Bellamy Carver Dalton Ellison Fletcher Garrison Holloway Ingram Kingsley Lowell Mercer Nash Osborne
  Pemberton Radcliffe Sinclair Tolliver Upton Vickers Wexford York Ashby Brennan Colby Dorsey Emerson
  Finch Gideon Harlow Ives Jarvis Keller Langley Merritt Norwood Oakley Porter Rutherford Sheridan Talbot
SURNAMES = Alvarez Brooks Chen Dubois Edwards Fischer Garcia Haddad Ito Jensen Kowalski Lopez Moreau
  Nakamura O'Brien Patel Quinn Rossi Silva Tanaka Usman Varga Weber Xu Yilmaz Zhou Bianchi Costa Dimitrov
  Eriksen Ferreira Grant Hughes Ivanova Jovanovic Kim Larsen Mensah Novak Ortega Popescu Reyes Sato
  Torres Ueda Volkov Walsh Young
ADJECTIVES = Golden Blue Corner Little Lucky Green Daily Bright Copper Silver Red Door Old Town
KINDS[ZONE_C] = {1: [Cafe, Bakery, Bookshop, Florist, Diner, Barbershop, Deli, Pharmacy, Hardware,
  Laundromat, Noodle Bar, Corner Store], 2: [Market, Bistro, Fitness Club, Dental Clinic, Savings Bank,
  Cinema, Design Studio, Electronics, Hotel, Tailors], 3: [Tower, Plaza, Center, Exchange, Building]}
KINDS[ZONE_I] = {1: [Workshop, Garage, Print Works, Joinery, Auto Repair], 2: [Warehouse, Foundry,
  Logistics, Bottling Plant, Textiles], 3: [Works, Manufacturing, Steel, Chemicals, Assembly Plant]}
```

Rules for the tables:

- `ADJECTIVES` has 12 entries. `"Red Door"` and `"Old Town"` are single entries.
- `business_kind()` returns the lower-cased kind.
- No table entry may contain a mayor's display surname (Okafor, Han, Kimura, Quintero, Granger) or a model brand. The directory test asserts this.

---

## 15. Legacy seams (the only edits to files other slices own)

### 15.1 `scripts/world/city_view.gd` (owned by G1)

**Signals.** Add after line 9:

```gdscript
## Tile i's holder was (re)built; holder is the Node3D under Tiles that owns all of its nodes.
## Fires for every holder, including the full build inside setup().
signal tile_built(i: int, holder: Node3D)
## Tile i lost its holder and nothing replaced it (cleared to empty land or unburnt woods).
signal tile_cleared(i: int)
## setup() finished: every tile, CityLife and the avatars exist again.
signal world_rebuilt()
## fp_mode changed value (set_fp_mode with a different value). Not emitted by the boot-time field set.
signal fp_mode_changed(on: bool)
```

And a read-only flag with the other vars:

```gdscript
## True while setup() runs (from its first line until just before world_rebuilt.emit()). tile_built
## listeners that do per-tile work skip it while in_setup and do one full pass on world_rebuilt.
var in_setup: bool = false
```

Emission points:

- `tile_cleared`: in `_build_tile`, remember `var had := _tile_nodes.has(i)` before line 881. At the early `return` on lines 888–889, emit `if had: tile_cleared.emit(i)`.
- `tile_built`: at the end of `_build_tile`, after line 1041 (the grow-tween block), emit `tile_built.emit(i, holder)`. Line 889 is the only early return in `_build_tile`, so this line is always reached when a holder exists.
- `world_rebuilt`: at the end of `setup()`, after line 182 (the signal-connection block), emit `world_rebuilt.emit()`.

**Building bounds.** Just before line 1027 (`if model != null:`), insert:

```gdscript
	if model != null and k != D.ROAD:
		holder.set_meta("building_path", model.scene_file_path)
		holder.set_meta("building_xform", model.transform)   # final transform, before the grow tween
```

Refactor `_model_bounds` (1155–1172). Extract the uncached-bounds computation (1159–1169) into `func _local_bounds(path: String) -> AABB`, keeping `_bounds_cache`. `_model_bounds` keeps its signature and behaviour.

Add these public functions:

```gdscript
## World-space bounds of the building model on tile i (zone or service); AABB() (size zero) when the
## tile has no building model: roads, rubble, sites without a model, empty land, woods.
func building_aabb(i: int) -> AABB:
	var holder: Node3D = _tile_nodes.get(i, null)
	if holder == null or not is_instance_valid(holder) or not holder.has_meta("building_path"):
		return AABB()
	var path := str(holder.get_meta("building_path"))
	if path.is_empty():
		return AABB()
	var local := _local_bounds(path)
	return holder.transform * ((holder.get_meta("building_xform") as Transform3D) * local)

## World-space blocking boxes of the construction site drawn on tile i, one per entry of the
## `colliders` meta that ConstructionKit.build_site writes on the holder's "Site" node before
## tile_built fires: hoarding segments (with the gate gap), machine bodies (stretched over their
## shuttle run, without the swinging arms), the crane's base and mast, the floodlight pole, slabs,
## formwork, berms, mounds, the frame, the scaffold and the old or finished building. Each entry is
## a box yawed about +Y; this returns the box of its rotated corners. Parts can reach past the
## tile (a tower crane's base up to 0.2 u into the neighbours). [] when no site is drawn on tile i.
func site_boxes(i: int) -> Array[AABB]:
	var out: Array[AABB] = []
	var holder: Node3D = _tile_nodes.get(i, null)
	if holder == null or not is_instance_valid(holder):
		return out
	var site := holder.get_node_or_null("Site") as Node3D
	if site == null:
		return out
	for c: Dictionary in site.get_meta("colliders", []):
		out.append(holder.transform * ConstructionKit.collider_aabb(c))
	return out

## Merged world-space bound of site_boxes(i): contains every blocking part the construction kit
## drew for the site on tile i, and can reach past the tile. AABB() when no site is drawn. For
## movement use site_boxes(i): this bound also covers the gaps between parts (the hoarding gate).
func site_bounds(i: int) -> AABB:
	var b := AABB()
	for a: AABB in site_boxes(i):
		b = a if b.size == Vector3.ZERO else b.merge(a)
	return b

## The Node3D holding everything drawn on tile i, or null.
func tile_holder(i: int) -> Node3D:
	return _tile_nodes.get(i, null)

## Camera used for picking, shake and avatar picking (orbit rig camera or the FP camera).
func set_camera(c: Camera3D) -> void:
	camera = c
	if avatars != null:
		avatars.camera = c
```

**Site colliders come from what the kit draws** (fix round 2). An earlier `site_bounds` returned the future building's `_model_bounds` (±0.423 for a real lot) and claimed that hoardings, scaffolds and machines stay inside it. They do not: the hoarding stands at ±0.47 (0.008 thick) with the ground slab at ±0.49, the scaffold at `foot/2 + 0.035` plus boards, the tower crane at `(−foot/2 − 0.1, −foot/2 − 0.1)` and the floodlight outside the footprint, and a probe measured machines up to 3.8 m outside it. So `ConstructionKit` (G1's file; S0 adds this seam) marks every blocking part it draws with `solid(node)` (or `solid_box(node, local_aabb)` for the crane's base and mast, not its jib), and `build_site` bakes them, before `_apply_progress`, into the Site root's meta:

```gdscript
site.set_meta("colliders", [{"shape": "box", "pos": Vector3, "size": Vector3, "yaw": float}])
# pos: centre of the box's base, holder-local; size: full extents in the box's own frame; yaw:
# radians about +Y. ConstructionKit.collider_aabb(entry) gives its holder-space AABB.
```

The rules: each part is boxed at its full built size in a frame turned by its yaw (tilted parts stay inside); a machine is boxed over the poses its own animations reach (the mixer drum as the cylinder it spins through, the dump-truck bed tipped, the excavator house slewed) and stretched over its `shuttle` run, without its `Boom` arm; parts that progress shows or hides one by one (felled trees, stumps, rebar, debris, planting) are not marked, because colliders are baked once per build. Road works now block at their cones, machines and piling rig (a gravel strip is walkable), and every demolition stage blocks at its machines and rubble mounds. A stage change re-marks the tile, so `tile_built` refreshes the cached collision boxes. A probe over 820 staged-site samples (builds, zone growth, demolitions, road works, with animation running) found no drawn part a walker can bump into (≥ `STEP_HEIGHT` tall, starting below `PLAYER_HEIGHT`) outside every box.

A probe confirmed that `Transform3D * AABB` yields the box of the transformed corners, which is exact for the 90° yaws used here, and that an instanced scene root carries its `scene_file_path`. CityView and `Tiles` stay at identity, so CityView-local space is world space. G1 must keep it that way.

**FP mode.** Add these with the other vars after line 118:

```gdscript
## Street-level presentation: hides builder aids and the AI presentation layer, stops ambient
## traffic, picking and camera shake. Persists across setup().
var fp_mode: bool = false

## S0 version: toggles visibility. G1 extends it: on a real change it also rebuilds the FP-only
## geometry synchronously (trees, tiles) and emits world_rebuilt (see slices/G1-streetscape.md).
func set_fp_mode(on: bool) -> void:
	var changed := on != fp_mode
	fp_mode = on
	_apply_fp_visibility()
	if changed:
		fp_mode_changed.emit(on)
```

`setup()` sets `in_setup = true` on its first line and `in_setup = false` just before `world_rebuilt.emit()`. `_apply_fp_visibility()` is called at the end of `setup()`, before `world_rebuilt.emit()`, and from `set_fp_mode`. The hiding list:

| # | What | Where it is built | FP behaviour |
|---|---|---|---|
| 1 | District floor labels (mayor name and district, 64 px) | `_build_district_borders` 599–612, under `_labels_root` | `_labels_root.visible = not fp_mode` |
| 2 | Citizen-voice Label3Ds (`no_depth_test`, y = 1.5) | `show_citizen_voices` 1710–1728, under `_labels_root` | hidden by #1; also `show_citizen_voices` returns early when `fp_mode`, so no nodes are created |
| 3 | Territory: border strips (y 0.07), dim wilds (y 0.05), **FrontierHaze** ceiling (y 1.1), "Unclaimed land" labels | `_rebuild_territory` 616–712, under `_territory_root` (recreated on `territory_changed`) | `_territory_root.visible = not fp_mode`, set after line 621 and in `_apply_fp_visibility` |
| 4 | Data-overlay columns (36,864 instances) | `_make_overlay_multimesh` 373–394, created at 137–139 | `set_overlay(mode)` (1497) returns early in FP unless `mode == "none"`; `_apply_fp_visibility` calls the body for `"none"` |
| 5 | Power and water icon spheres (y 1.25–1.75) | 402–418, created at 140–141, refreshed 1474–1494, pulsed 1872–1876 | `_power_icons.visible = _water_icons.visible = not fp_mode`; `_refresh_status()` returns early in FP (a perf win); `_apply_fp_visibility` calls `_refresh_status()` when switching back to orbit |
| 6 | Cursor torus | `_build_cursor` 714–727, moved at 1955–1961 | `_cursor.visible = false`; `_unhandled_input` returns at the top when `fp_mode` (no `tile_clicked`, so no `brain.inspect_tile` LLM call) |
| 7 | Mayor robots, their rings, name labels and bubbles | `_build_avatars` 729–763, animated 1877–1892 | `(av["root"] as Node3D).visible = not fp_mode` for every entry in `_avatars`; `show_mayor_decision` and `show_mayor_thinking` keep working on hidden nodes |
| 8 | Event label (`"<label>\n(<source>)"`, y 2.6) and the pulsing event ring | `_make_event_fx` 1667–1681 | `ring.set_meta("orbit_only", true)`, `lbl.set_meta("orbit_only", true)`, each with `.visible = not fp_mode`; `_apply_fp_visibility` toggles every `orbit_only` child of `_event_nodes` |
| 9 | Ambient Kenney cars and capsule pedestrians | `_spawn_agent` / `_update_population` 1763–1857, called at 1870 | line 1870 becomes `if not fp_mode: _update_population(delta)`; `_apply_fp_visibility` frees the existing `_cars` and `_peds` nodes and clears both lists when entering FP; `_cars_root` and `_peds_root` visible only in orbit |
| 10 | Earthquake camera shake (±0.25 u = 5 m) | 1924–1930 | wrap the block in `if not fp_mode:`; the `event_started` handler sets `_shake = 1.2` only when not `fp_mode`, and `_apply_fp_visibility` zeroes `_shake`, so a quake felt in FP never shakes the orbit camera after `exit_fp()` |
| 11 | Resident speech bubbles (billboard Label3D, `pixel_size 0.0035`, 420 px wide: about 29 m of text at street level) | `resident_avatars.gd:137-146`, shown at 234-235 | `_apply_fp_visibility` sets `avatars.fp_hidden = fp_mode`; the bubble line ANDs `not fp_hidden` (§15.6). The avatars themselves stay visible. E restyles the bubbles for street level and then owns the rule |

These stay **visible** in FP. G1 restyles them for street level: tiles, ground, water, trees, construction sites, fires and smoke, smog, flood and tornado FX, light pools, CityLife fleets, resident avatars (not their bubbles, #11).

**Display names.** Lines 602 and 753 keep `D.MAYORS[d]["name"]`, the brand label. Both labels exist only in orbit (FP hides `_labels_root` and every mayor root), and D-S0-7 keeps orbit and the cinematic branded: the cinematic's "mayors" shot is captioned "Each one a different model" and frames these labels.

### 15.2 `scripts/sim/residents.gd` (owned by F)

Add after line 11:

```gdscript
## A resident spoke out loud or wrote to their mayor. kind: "say" (daily plan line), "react"
## (incident reaction line), "letter" (message to the mayor). text is never empty.
signal resident_said(id: String, text: String, kind: String)
## A resident set off from tile from_i to tile to_i (sim arrival is instant; the view animates
## the trip). mode: car | bus | bike | walk.
signal trip_started(id: String, from_i: int, to_i: int, mode: String)
```

Emission points:

| Where | After | Emit |
|---|---|---|
| `apply_plan` | line 677 `r["say"] = ...` | `if not str(r["say"]).strip_edges().is_empty(): resident_said.emit(str(r["id"]), str(r["say"]), "say")` |
| `respond` | line 699 `r["say"] = ...` | the same, with kind `"react"` |
| `_post_message` | the end of the function, at one-tab indentation **after** the `if messages.size() > 300:` block (736 is `messages.pop_front()` inside that `if`; 737 is blank) | `resident_said.emit(str(r["id"]), text, "letter")` |
| `_go` | line 1015 (mode set), before `resident_moved.emit(r)` | `if from != to: trip_started.emit(str(r["id"]), from, to, _trip_mode(str(r["mode"])))` |

`_trip_mode(m)` returns `m if m in ["car", "bus", "bike", "walk"] else "walk"`. Line 1015 copies `plan.commute` for long non-work trips, and `COMMUTES` includes `"stay_home"` (`residents.gd:23`), so without it a stay-home commuter walking to the park would emit `"stay_home"`. `r["mode"]` itself is unchanged.

**De-branding at the source (D-S0-8).** The tracked replay cache has branded resident text (91 thoughts, 85 letters, 29 mood reasons and 3 say lines on seed 7), and these fields reach FP bubbles, chat, letters and the mayor prompts. `apply_plan` wraps `mood_reason`, `thought`, `say` and `message_to_mayor` in `D.debrand(...)` before `.left(n)`; `respond` does the same for `thought`, `say` and `message_to_mayor`. So `resident_said`, `messages` and the resident card never carry a brand word. F keeps these wraps.

`apply_plan` runs in batches of 10, so roughly 100 `say` lines arrive within seconds once a day. Consumers must queue them (C drips them out). No other code may emit these two signals.

### 15.3 `scripts/sim/city_sim.gd` (owned by F)

After line 48 (`var speed: int = 1`):

```gdscript
## Real seconds per game day at speed 1. Orbit and tests keep SimDefs.BASE_DAY_SECONDS (12);
## first person sets WS.FP_DAY_SECONDS (1200). Not saved: the view mode sets it at boot.
var day_seconds: float = D.BASE_DAY_SECONDS
```

Add after `day_progress()` (391–393):

```gdscript
## Real seconds per growth tick at speed 1.
func tick_seconds() -> float:
	return day_seconds / float(D.GROWTH_TICKS_PER_DAY)

## Changes the day length and rescales the time already accumulated toward the next tick, so
## day_progress() and tick_phase() are unchanged.
func set_day_seconds(s: float) -> void:
	if s <= 0.0:
		return
	if day_seconds > 0.0:
		_time_accum *= s / day_seconds
	day_seconds = s

## Sets how far the current growth tick has run (0..1), e.g. when a save restores the time of day.
func set_tick_phase(p: float) -> void:
	_time_accum = clampf(p, 0.0, 1.0) * tick_seconds()

## Runs the rest of today's growth ticks synchronously so the next day starts at dawn
## (FP "skip to morning"). Stops early if the day gate holds the boundary. Returns true when
## the new day has started.
func skip_to_next_day() -> bool:
	var n := D.GROWTH_TICKS_PER_DAY - tick_in_day
	for _k in range(n):
		if waiting_for_ai:
			break
		step_tick()
	_time_accum = 0.0
	return not waiting_for_ai
```

Code that changes the day length while a day runs (`main.gd` `enter_fp`, `exit_fp`, `grow_offline`; `fp_bench`) calls `set_day_seconds`, never a raw `day_seconds =` write: the accumulator holds up to one tick of real time, and a 300 s FP tick left pending against a 3 s orbit tick runs as dozens of ticks in a few frames. FpMode's save section restores the phase with `set_tick_phase` (§6.4).

Every `BASE_DAY_SECONDS` read site (there are exactly four in the repo):

| Site | Old | New |
|---|---|---|
| `city_sim.gd:383` (`_process`) | `D.BASE_DAY_SECONDS / float(D.GROWTH_TICKS_PER_DAY)` | `tick_seconds()` |
| `city_sim.gd:392` (`day_progress`) | same | `tick_seconds()` |
| `city_sim.gd:1315` (`tick_phase`) | `(D.BASE_DAY_SECONDS / float(D.GROWTH_TICKS_PER_DAY))` | `tick_seconds()` |
| `resident_avatars.gd:194` (`_on_moved`) | `D.BASE_DAY_SECONDS / float(D.GROWTH_TICKS_PER_DAY) / float(maxi(sim.speed, 1))` | `sim.tick_seconds() / float(maxi(sim.speed, 1))` |

Mayor display names live in the sim data (D5):

- Line 135, in `new_city`: `"name": m["display"]`. The comment: `## "name" is the mayor's human display name; "id" and "model" stay for the API.`
- After line 2253, in `from_dict`, normalize old saves:

  ```gdscript
  	for mi in range(mini(mayors.size(), D.MAYORS.size())):
  		mayors[mi]["name"] = D.MAYORS[mi]["display"]
  ```

The **`name` key keeps its meaning** of "what we call this mayor". Its value is now the human name, so saves still carry `name`, old saves load, and `sim_test.gd:31` still prints a name. With that one change, every sim-side use is de-branded with no further edits: all `_log` lines (354, 1569, 1637, 1696, 1719, 1720, 1740, 1762, 1763, 1785), `owner_name()` (270–273), contractors (1278), the incident crews (1964), the city_summary events (2131, 2133), `sample_citizens` (2169), `tile_report.district_mayor` (2192), residents' memory (`residents.gd:788`), `card().home.mayor` (`residents.gd:1131`) and the photo-tour print (`main.gd:306`).

### 15.4 `scripts/sim/sim_defs.gd` (S0 seam)

**Display names.** Add `"display"` to each entry in `MAYORS` (169–195), and rewrite each `persona` (173, 178, 183, 188, 193) so it opens with the display name and the district:

| id | display | persona opening (the rest of the sentence is kept verbatim) |
|---|---|---|
| argon | Ada Okafor | "You are Ada Okafor, mayor of the Northwest Civic Campus and a meticulous civic planner. You build reliable power, …" |
| deepseek | Viktor Han | "You are Viktor Han, mayor of the Northeast Tech Corridor and a first-principles systems engineer. You optimize …" |
| kimi | Mei Kimura | "You are Mei Kimura, the coalition mayor of the Central Plaza. You prioritize …" |
| qwen | Rosa Quintero | "You are Rosa Quintero, mayor of the Southwest Eco Quarter and a fiscally careful pragmatist. You balance …" |
| grok | Duke Granger | "You are Duke Granger, mayor of the Southeast Boomtown and a witty, aggressive growth maximalist. You chase …" |

`"name"` in `D.MAYORS` stays the brand label (for example `"DeepSeek-V4"`). Only the orbit CityHud and the cinematic trailer read it (see the table in §15.7). `"id"` and `"model"` are unchanged, so the replay keys `mayor|<id>` still resolve.

**Helpers.** Add these static functions:

```gdscript
## Human display name of mayor mi ("" when out of range).
static func mayor_display(mi: int) -> String
## Replaces model branding in free text (LLM output, replay cache, old saves) with display names:
## model ids (D.MAYORS[*].model) and brand names (D.MAYORS[*].name, also with a trailing ".x" or
## "-Flash" style suffix) become the display name; a bare brand word (Argon|DeepSeek|Kimi|Qwen|Grok,
## case-sensitive, whole word) becomes "Mayor <Surname>".
static func debrand(text: String) -> String
```

Implementation notes:

- Replace in this order: model ids, then brand names with any suffix, then bare words.
- For the last two steps, use a `RegEx` compiled once into a `static var`, with `\b` boundaries.
- Example: `debrand("DeepSeek-V4 says Grok's towers are ugly")` returns `"Viktor Han says Mayor Granger's towers are ugly"`.

### 15.5 `scripts/ai/city_brain.gd` (S0 seam; nobody else owns this file)

| Line | Change |
|---|---|
| 155 | Replace `You are one of five autonomous AI mayors in GridFall, a SimCity-style city. Each mayor is a different AI model and controls ONLY their own district.` with `You are one of the five elected mayors of GridFall, a SimCity-style city. Each mayor controls ONLY their own district.` |
| 185 | `"DAY %d. You are %s, mayor of %s (district %d, x %d..%d, y %d..%d)." % [day, m["display"], m["district"], mi, ...]`, dropping the model id |
| 202 | `D.MAYORS[oi]["display"]` |
| 267, 268, 292 | `m["display"]` (`m` is `D.MAYORS[mi]` from line 236) |
| 276–277 | `var thought := D.debrand(str(data.get("thought", ""))).left(260)` and `var post := D.debrand(str(data.get("public_post", ""))).left(200)`. Replayed posts from `data/gmi_replay_cache.json` carry brand names (Grok 96×, Argon 63× …), so de-brand them at the source. |
| 621 | Build the Gazette system prompt from `D.MAYORS`: `"...governed by five elected mayors: Ada Okafor (Northwest Civic Campus), Viktor Han (Northeast Tech Corridor), ..."`. Join `"%s (%s)" % [display, district]`. |
| 624–626 | After `var paper := res["data"].duplicate()`, de-brand `headline`, `editorial`, and each `stories[*].title` and `stories[*].body`. |
| 651, 692 | `"mayor": D.MAYORS[mi]["display"]` |
| 693 | Build the operator prompt's district list from `D.MAYORS`: `"(0 Ada Okafor NW, 1 Viktor Han NE, 2 Mei Kimura center, 3 Rosa Quintero SW, 4 Duke Granger SE)"`. |
| 639 | The heuristic Gazette editorial `"Five AI mayors, one power grid. Somebody will have to share."` becomes `"Five mayors, one power grid. Somebody will have to share."` |
| 800 | In the inspector system prompt, `"in a SimCity-style city run by AI mayors"` becomes `"in a SimCity-style city run by five elected mayors"` |
| 805 | Wrap the mayor post: `D.debrand(str(mayor_state[...].get("post", "")))` |
| 212, 217 | Wrap the resident letter text and the citizen thought: `D.debrand(str(md["text"]))`, `D.debrand(str(vd.get("thought", "")))`. Residents now de-brand at the source (§15.2); this covers letters restored from old saves. |
| 223, 737 | Proposal votes are keyed by mayor id, and the ids are the lowercase brand words (`argon`, `deepseek` ...), which `D.debrand` does not catch. Serialise them into the mayor and council prompts through `_votes_by_name(votes)`, which keys them by display name (`{"Ada Okafor": "yes"}`). The stored keys stay ids (`_yes_votes`, the heuristic). |
| `_run_council` | The council system prompt says `"Five elected mayors vote on ordinances"` (was "Five AI mayors"), and the ruling's `statement` is de-branded before `.left(240)`: C shows it to players. |
| `from_dict` | Ends with `_debrand_restored()`: de-brands `proposals[*].by`, each `mayor_state` post, thoughts and log entries (`thought`, `post`), `last_paper` (through the shared `_debrand_paper`, also used by `_run_news`) and `last_council.statement`, so old saves feed no brand words to the prompts or the HUDs. |

### 15.6 One-line seams in other files

- **`scripts/ai/resident_minds.gd:170`:** `"mayor": D.MAYORS[mi]["display"]`, and `"said_yesterday": D.debrand(said)`.
- **`scripts/world/resident_avatars.gd:194`:** see §15.3.
- **`scripts/world/resident_avatars.gd`, bubbles:** `## Set by CityView in first person (S0 seam): speech bubbles stay hidden until slice E restyles them.` `var fp_hidden: bool = false`, and the bubble line becomes `var show_bubble := float(a["bubble_t"]) > 0.0 and root.visible and _bubbles < MAX_BUBBLES and not fp_hidden`. CityView sets it in `_apply_fp_visibility` (§15.1 #11). When E moves the bubbles to street-level anchors (`slices/E-traffic.md`), E decides whether to keep honouring the flag and files a request to move `fp_seams_test`'s bubble check into its own test.
- **`scripts/world/sky_director.gd:54`:** `if sim == null or sim.day_seconds / float(maxi(sim.speed, 1)) < MIN_CYCLE_DAY_SECONDS:`. Add `const MIN_CYCLE_DAY_SECONDS := 3.0` below line 13, documented as `## Days shorter than this many real seconds hold at HOLD_HOUR instead of strobing.` Keep `MAX_CYCLE_SPEED`. This is exactly today's behaviour in orbit: 12 / 5 = 2.4 holds and 12 / 4 = 3.0 cycles. In FP at 8× the day lasts 150 s, so the sky cycles and does not freeze at 13:00.

### 15.7 Every use of a model-derived mayor name, and what happens to it

| File:line | Visible to | Disposition |
|---|---|---|
| `sim_defs.gd:171,176,181,186,191` (`name`) | orbit HUD, cinematic | stays the brand label; `display` is added |
| `sim_defs.gd:173,178,183,188,193` (`persona`) | mayor prompt, so it reaches posts | rewritten (§15.4) |
| `city_sim.gd:135` and 2253 (`sim.mayors[].name`) | logs, reports, chat, prompts | becomes the display name (§15.3) |
| `city_sim.gd:270-273, 354, 1278, 1569, 1637, 1696, 1719-1720, 1740, 1762-1763, 1785, 1964, 2131, 2133, 2169, 2192` | city_log (chat feed), tile_report, prompts | fixed automatically by §15.3 |
| `residents.gd:788, 1131` | resident memory and card (prompts) | fixed automatically |
| `city_brain.gd:155, 185, 202, 267, 268, 276-277, 292, 621, 624-626, 639, 651, 692, 693, 800, 805` | prompts, posts, day feed, Gazette | §15.5 |
| `resident_minds.gd:170` | resident plan prompt | §15.6 |
| `city_view.gd:602, 753` | world labels (orbit only after the FP hide) | **stay the brand label** (§15.1, D-S0-7) |
| `main.gd:306` | stdout print | fixed automatically |
| `city_hud.gd:347, 356, 439, 446, 849, 850, 930, 948, 1060, 1099, 1105` | **orbit CityHud only** | **brand labels unchanged by decision** (§23 D-S0-7). The log, the Gazette and the posts now say "Ada Okafor" / "Mayor Okafor" (D-S0-6, D-S0-8), so the mayor inspector (`_render_mayor`) adds a `Mayor <display> · <district> · <style>` line and each mayor card gets the tooltip `Mayor <display> · <district>`, linking both names. B's FpHud must use display names only. |
| `cinematic.gd:266-267` | trailer stdout | unchanged |
| `gridfall_hud.gd:298, 437` | dead code | unchanged |
| `data/gmi_replay_cache.json` (brand names in posts and Gazette text) | chat, posters | `D.debrand` at the source (§15.5) and again at display in C, D and B |

---

## 16. `project.godot` `[input]` (S0 owns the block)

Keep the five `camera_*` actions. Append the actions below. Each event uses the existing serialization exactly:

```
Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":<PK>,"key_label":0,"unicode":<U>,"location":0,"echo":false,"script":null)
```

Separate several events with a newline followed by `, `, as in the existing block. Movement actions use `"deadzone": 0.2`. Every other action uses `0.5`.

| Action | Keys (physical_keycode / unicode) |
|---|---|
| `move_forward` | W 87/119, Up 4194320/0 |
| `move_back` | S 83/115, Down 4194322/0 |
| `move_left` | A 65/97, Left 4194319/0 |
| `move_right` | D 68/100, Right 4194321/0 |
| `sprint` | Shift 4194325/0 |
| `crouch` | Ctrl 4194326/0 |
| `jump` | Space 32/32 |
| `interact` | E 69/101 |
| `chat_open` | Enter 4194309/0, Keypad Enter 4194310/0 |
| `map_toggle` | M 77/109 |
| `pause_menu` | Escape 4194305/0 |
| `time_faster` | `]` 93/93 |
| `time_slower` | `[` 91/91 |
| `time_skip` | T 84/116 |
| `photo_mode` | P 80/112 |
| `hud_toggle` | F1 4194332/0 |
| `quick_save` | F5 4194336/0 |
| `quick_load` | F9 4194340/0 |

Every special-key value above was probe-verified in Godot 4.7.2, including `KEY_F5 = 4194336` and `KEY_F9 = 4194340`.

S0 adds no gamepad bindings for these. A requests them if needed. The FP smoke asserts `InputMap.has_action()` for all 18 actions.

**Camera actions (D13, added with the third-person decision).** Eight more actions, appended after `quick_load`:

| Action | Binding | Dead zone |
|---|---|---|
| `view_toggle` | V 86/118 | 0.5 |
| `shoulder_swap` | Q 81/113 | 0.5 |
| `zoom_in` | mouse wheel up (`button_index` 4) | 0.5 |
| `zoom_out` | mouse wheel down (`button_index` 5) | 0.5 |
| `look_left` / `look_right` | gamepad right stick X (`axis` 2), −1 / +1 | 0.15 |
| `look_up` / `look_down` | gamepad right stick Y (`axis` 3), −1 / +1 | 0.15 |

The mouse-button and joypad events use Godot 4.7.2's own serialization (probe: `var_to_str` of each event), with `"device":-1`:

```
Object(InputEventMouseButton,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"button_mask":0,"position":Vector2(0, 0),"global_position":Vector2(0, 0),"factor":1.0,"button_index":<4|5>,"canceled":false,"pressed":false,"double_click":false,"script":null)
Object(InputEventJoypadMotion,"resource_local_to_scene":false,"resource_name":"","device":-1,"axis":<2|3>,"axis_value":<-1.0|1.0>,"script":null)
```

V, Q, the wheel and the right stick are bound to no other game action (the orbit camera reads the wheel directly, `camera_controller.gd:79-81`, and is disabled on foot). `view_toggle`, `shoulder_swap` and `zoom_*` are discrete (rule D-S0-17); `look_*` is analog and polled with `Input.get_vector`. `fp_core_test` asserts the eight actions, their bindings, their exclusivity and the 0.15 dead zone.

---

## 17. Test tooling

### 17.1 `tools/tests/parse_all.gd`

This is a port of the scratch tool (`.../scratchpad/tools/parse_all.gd`):

- Walk `res://scripts` and `res://tools` for `*.gd`, skipping `.` dirs and `__pycache__`.
- For each script, `ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript` must be non-null and `can_instantiate()`.
- Print `PARSE_ALL: PASS <n> scripts in <ms> ms` or `PARSE_ALL: FAIL <n> failed: [paths]`.
- `quit(0|1)`.

### 17.2 `tools/tests/fp_kit.gd` (static helpers; `extends RefCounted`, no class_name)

```gdscript
## The scripted growth recipe used by "grow" (probe-verified on seed 7, see below).
const GROW_ACTIONS := [ ...the nine actions at residents_test.gd:29-37, verbatim...,
	{"type": "road", "x": 9, "y": 12, "x2": 4, "y2": 14} ]   # L-leg: corner at (4,12), tee at (10,12)
## CitySim(new_city(seed)) + Residents (+ ResidentMinds when minds = true) + a GmiClient (the
## injected client, else a new offline one with live_enabled = false), all under root. An injected
## client keeps the live_enabled and api_key it came with: GmiClient._ready (run by add_child) would
## otherwise force live off under GRIDFALL_OFFLINE=1 and load the real key into the fake.
## Returns {"sim", "people", "minds", "client"}.
static func make_sim(root: Node, seed: int = 7, minds: bool = false, client: GmiClient = null) -> Dictionary
## Applies GROW_ACTIONS through sim.apply_action(0, a), calls sim.start(), then step_tick()s until
## at least min_ticks ticks ran AND people has >= 5 residents AND >= 1 ZONE_C lot is at level >= 1,
## capped at 120 ticks. Returns the tick count.
static func grow(sim: CitySim, people: Residents, min_ticks: int = 40) -> int
## Runs n synchronous ticks.
static func ticks(sim: CitySim, n: int) -> void
## A CityView set up on sim with a throwaway Camera3D (needs the .godot import cache).
static func make_view(root: Node, sim: CitySim) -> CityView
## An FpContext wired for unit tests without Main. See the field table below.
## opts (defaults): {"seed": 7, "minds": false, "grow": false, "ticks": 0, "view": false,
##   "render": false, "player": true, "hud": true, "audio": false, "client": null,
##   "camera_mode": "first"}. camera_mode overrides FpMode's play default ("third", D13), so every
##   test runs in first person unless it passes "third".
static func make_ctx(root: Node, opts: Dictionary = {}) -> FpContext
## A headless FpPlayer (input_enabled = false) under the kit root; sets ctx.player and
## ctx.mode.player, teleports to spawn_point(). make_ctx calls it when opts.player is true.
static func make_player(ctx: FpContext) -> FpPlayer
## Instantiates a registered feature by id from fp_features.gd, adds it under the kit's
## "Features" Node3D (so it is inside the tree and its _process runs when the test yields frames),
## sets ctx.features[id], then runs setup(ctx) and on_world_rebuilt().
static func make_feature(ctx: FpContext, id: String) -> FpFeature
## Prints "<TOKEN>: PASS" or "<TOKEN>: FAIL <fails>" and quits 0/1. fails is Array[String].
static func finish(tree: SceneTree, token: String, fails: Array) -> void
```

`make_ctx` builds, in this order, under one `Node3D "FpKit"` added to `root` (it mirrors FpMode's layout):

| Step | Field | What |
|---|---|---|
| 1 | `sim`, `residents`, `minds`, `client` | `make_sim(root, seed, minds, opts.client)`. An injected client (C's and D's counting fakes) is in place **before** anything below is set up. |
| 2 | (growth) | if `grow`: `grow(sim, residents, max(opts.ticks, 40))`; else if `ticks > 0`: `sim.start()` then `ticks(sim, ticks)`. Growth runs **before** the brain and the view exist: no mayor acts during it (so the recipe stays probe-verified) and there are no per-tick rebuilds. Growth is always offline: with an injected client and minds, the minds talk to an offline stand-in `GmiClient` (sharing the injected client's replay cache) during growth and get the injected client back afterwards, so a counting fake sees **no** `live_json` call before the test starts (a probe counted 27 before this rule). A fake's `live_enabled = true` survives `make_ctx`; tests no longer need to set it afterwards. |
| 3 | `brain` | `CityBrain` under root, `setup(sim, client)`, `brain.minds = minds`, and `minds.plans_done.connect(brain.residents_spoke)` when minds exist. From here on its listeners are live: a test that ticks through a day boundary sees offline mayors act. |
| 4 | `view` | if `view`: `make_view(root, sim)`; else null. |
| 5 | `env`, `sun` | if `render`: a current `Camera3D` whose `environment` is `scenes/main-environment.tres` loaded with `ResourceLoader.CACHE_MODE_IGNORE` (a private copy), and a `DirectionalLight3D` with the `main.tscn` Sun values. Else both null. |
| 6 | `sky` | `SkyDirector` under root, `setup(sim, env, sun, view)` (headless-safe with nulls, `sky_director.gd:25-46`). Always present, so `sky.clock_text()` works. |
| 7 | `bus`, `directory`, `collision`, `world_root` | `GameBus`, `CityDirectory.setup(sim)`, `CollisionWorld.setup(ctx)` + `rebuild_all()` when a view exists, `Node3D "World"` (`PROCESS_MODE_PAUSABLE`, as in FpMode). |
| 8 | `mode` | a **stub** `FpMode.new()` added under the kit root but never `setup()`: `ctx`, `bus`, `collision`, `directory` fields set, `time_scale = 1`, `paused = false`. Its `set_time_scale`, `step_time_scale`, `set_paused` and `apply_settings` work (they only touch `sim`, the tree pause, `ctx` modals, `settings_log` and the bus); `spawn_point()` works when a view or roads exist. |
| 9 | `player` | if `player`: `make_player(ctx)`. |
| 10 | `hud` | if `hud`: `FpHud` under the kit root, `setup(ctx)`. |
| 11 | `audio` | if `audio`: a `GridFallAudioDirector` under root. |
| — | `settings` | a copy of `FpMode.DEFAULT_SETTINGS` with `camera_mode = opts.camera_mode` (`"first"` by default, D13). |
| — | `main` | always null in unit tests. Code that calls `ctx.main` null-guards it. |

**Fixtures of the grown kit city** (seed 7, `grow`, 40 ticks, offline, no minds; measured with a headless probe): 45 residents (36 at home with a job), 16 R lots and 7 C lots at level > 0, road masks include a corner (mask 6 at (4,12)), tees (masks 7, 13) and crosses (mask 15, 4 tiles), and one bus-stop tile. **No billboard is guaranteed**: tests that need one (D) add it themselves (see `slices/D-posters.md`). `fp_core_test` asserts these fixtures, so a recipe change that loses one fails S0's own gate first. Without `grow`, the kit city has 0 population (a probe at 32 and 40 ticks: pop 0, no R or C lots, no corners).

Every `tools/tests/fp_*_test.gd` follows the same shape: `extends SceneTree`, run in `_init`, finish through `fp_kit.finish`. The token is the upper-cased file basename, for example `fp_world_scale_test.gd` prints `FP_WORLD_SCALE_TEST: PASS`. The gate derives the token from the file name.

### 17.3 S0 unit tests

| File | Asserts |
|---|---|
| `fp_world_scale_test.gd` | `WS.M * WS.TILE_M == 1`; `EYE == 1.65 * M`; `CURB_RISE == SIDEWALK_TOP - ASPHALT_TOP`; `LANE_OFFSET == ROAD_HALF / 2`; `abs(VEHICLE_SCALE * 1.2 - 1) < 1e-6`. Parses `res://tools/blender/realcity/roads.py` (`ZA =`, `ZS =`, `HW =`) and `core.py` (`M = 1.0 / 20.0`), and checks they equal `ASPHALT_TOP`, `SIDEWALK_TOP`, `ROAD_HALF` and `M`. `ZM` is an expression (`ZM = ZA + 0.0003`, `roads.py:26`), so the test parses `ZM = ZA + <n>` and checks `abs((MARKING_TOP − ASPHALT_TOP) − n) < 1e-9`. This is a drift detector, and H must keep it passing. |
| `fp_seams_test.gd` | Headless, seed 7, with a view. `sim.day_seconds == 12` and `tick_seconds() == 3`; at 1200, `tick_seconds() == 300` and `day_progress` scales. `set_day_seconds` keeps `day_progress` (12 → 1200 → 12, a pending 240 s FP accumulator becomes 2.4 s); `set_tick_phase` sets and clamps. `skip_to_next_day()` leaves `tick_in_day == 0`, `day + 1` and `day_progress() < 0.01`. `apply_plan` with `{"say": "Hi"}` emits `resident_said(id, "Hi", "say")`; `_post_message` emits `"letter"` while `messages.size() < 300` (and also at 300+); `apply_plan` and `respond` with branded `say`, `thought`, `mood_reason` and `message_to_mayor` emit and store de-branded text; the mayor prompt with a branded resident letter and id-keyed votes carries no brand word and no quoted mayor id, `_votes_by_name` keys by display name, and `brain.from_dict` of a branded save de-brands proposals, posts, thoughts, the Gazette and the council statement; `_go` to a different tile emits `trip_started` with `from == old at`, and a resident whose `plan.commute == "stay_home"` sent on a non-work trip longer than 6 tiles emits mode `"walk"`. Every `sim.mayors[i].name` equals `D.MAYORS[i].display` after `new_city`, and after `from_dict` of a dict whose mayors carry brand names. `owner_name(D.idx(5, 5))` is a display name. `D.debrand` cases. View: `world_rebuilt` fires once per `setup`; `tile_built` fires once per holder (count equals `_tile_nodes.size()` after setup), and `in_setup` is true inside those emissions and false inside `world_rebuilt`; `building_aabb` of every zone tile at level > 0 is non-empty, sits inside `[x − 0.5, x + 0.5]`, and has `position.y ≈ 0`; road tiles return size zero. `site_boxes` (staged mode: a police build, a one-tile road and a bulldozed district-0 zone building, then one tick; each fixture asserted) is non-empty on every drawn site, road works included; `site_bounds` equals their merge; every visible mesh under the Site node that is ≥ `STEP_HEIGHT` tall and starts below `PLAYER_HEIGHT` (outside `Boom` arms and the progress groups) lies in xz inside one of the boxes; and both are empty on every tile without a site. `set_fp_mode(true)` hides `_labels_root`, `_territory_root`, both icon multimeshes and every mayor root, zeroes a pending `_shake`, sets `avatars.fp_hidden` and keeps a fresh resident bubble hidden, emits `fp_mode_changed(true)` once, and `set_fp_mode(true)` again emits nothing; a quake triggered in FP queues no shake; `set_fp_mode(false)` restores the layers and bubbles. `set_overlay("power")` in FP leaves `_tiles_root.visible` true. `tile_cleared` fires when a built tile is bulldozed to `EMPTY` (use `sim.apply_action` bulldoze, then tick until the demolition site finishes, or set `kind` directly and call `view._on_tiles_changed`). The 18 input actions exist. |
| `fp_directory_test.gd` | Two directories on the same seed agree on every road tile in `sim.active`; a different seed changes at least one name. In the 32×32 core, distinct rows give distinct street names and distinct columns give distinct avenue names. Every `ZONE_C` / `ZONE_I` lot at level > 0 has a non-empty `business_name`. Every lot with a road neighbour has a non-empty `address` matching `^\d+ .+ (Street\|Avenue)$`. `frontage()` is a 4-neighbour ROAD. `frontage_yaw` is in {0, 90, 180, −90}. City Hall's `landmark_name` is `"GridFall City Hall"`. No output contains `Argon`, `DeepSeek`, `Kimi`, `Qwen`, `Grok`, `GMI` or a mayor display surname. 1,000 calls of `place_label` take under 50 ms (report only). |
| `fp_core_test.gd` | Uses `make_ctx(root, {"view": true, "grow": true})` (headless `FpPlayer` and `CollisionWorld`). **Fixtures:** asserts every fixture listed in §17.2 (≥ 5 residents, ≥ 1 resident at home with `work >= 0`, ≥ 1 C lot with a non-empty `business_name`, ≥ 1 `view.bus_stops` entry, ≥ 1 corner, tee and cross mask). Every registry path exists and loads as an `FpFeature` with a matching `feature_id()`, and ids are unique. `make_feature` puts the feature inside the tree. `ground_height` on a straight road gives `ASPHALT_TOP` at the centre and `SIDEWALK_TOP` at offset 0.4, `NAN` on a non-road water tile, and `SIDEWALK_TOP` on an end tile's island. `surface_at` follows the §12 table on a road centre, a sidewalk, a park or empty tile and a lot. Calling `player.simulate(Vector2(0, 1), false, 1/60.0)` 180 times (3 s) along a sidewalk moves the player `WALK * 3 ± 15%`, after the acceleration ramp; with `ctx.push_modal(&"test")` the same calls move nothing. Walking into a building for 5 s never lands the feet inside any `collision.boxes(i)` grown by `PLAYER_RADIUS * 0.99` (never `building_aabb`). `raycast` from the sidewalk toward that building hits `kind == "building"` within `INTERACT_RANGE`. `player.to_dict` → `from_dict` round-trips the position (ε 1e-4) and yaw (ε 0.01°). `AP.load_scene` returns null for a missing path and for a non-scene resource. **HUD** (through the slot API only, so B can replace the placeholders): the six slots exist; `set_hud_visible(false)` hides all but `overlay`; a `bus.toast` carrying a brand word shows, de-branded, in a `Label` or `RichTextLabel` under `slot("toasts")` within 10 frames. **Mouse look:** a 100 × 40 px `InputEventMouseMotion` pushed through the root viewport at `content_scale_factor` 1, 2 and 0.5 arrives with a different stretched `relative` each time, and `player.mouse_look(event)` turns yaw and pitch by exactly `px * mouse_sensitivity` each time. **Sites** (last, it starts sites on open lots): three staged builds, one tick; from 0.66 u outside a hoarding side without the gate (`h % 4`), 2.5 s of sprinting toward the centre stops the feet at `0.474 + PLAYER_RADIUS` (± 0.02), never inside any `collision.boxes(j)` grown by `PLAYER_RADIUS * 0.99`; the velocity into the hoarding is then under `RUN / 4`; and single long steps — `simulate(Vector2(0, 1), true, dt)` with dt 0.25, 0.7 and 2.72 while pressed against the hoarding, and 2.72 from a standing start at the run-up point — never end inside a box or past the hoarding. **Trapped:** the player stands at the centre of an empty lot with a frontage; the lot becomes `ZONE_R` level 1 (`view._on_tiles_changed`), so the player is now blocked; 5 s of sprinting toward the frontage gets them out; just inside the front face, backing into the house moves them no deeper; `nearest_free` from the lot centre returns an unblocked point within 1 u. |

### 17.4 `tools/tests/fp_smoke.gd` (FP headless smoke; `extends Node`, `run(main)`)

This script runs inside Main through `GRIDFALL_FP_SMOKE=1`. Steps (a failure is collected, never aborted on):

1. `main.client.set_live(false)`, then `main.sim.start()`, then `await main.grow_offline(3, 60000)`. Assert `sim.day >= 3`. This is a hard check, unlike the legacy smoke.
2. Assert the FP wiring:
   - `main.fp != null` and `view_mode == "fp"`.
   - `get_viewport().get_camera_3d() == main.fp.player.camera`.
   - `main.fp.player.camera.environment == main.camera.environment` (the same resource).
   - The rig is not processing.
   - `main.hud.visible == false` and `main.hud.process_mode == PROCESS_MODE_DISABLED`.
   - `view.fp_mode` is true, and the hidden nodes from §15.1 are invisible: labels, territory, icons, cursor, and every mayor root.
   - `sim.day_seconds == WS.FP_DAY_SECONDS`.
3. All 18 input actions exist. Every registry feature is present in `ctx.features`.
4. Time: `fp.set_time_scale(4)` sets `sim.speed == 4` and `time_scale_changed(4)` is received. `step_time_scale(+1)` gives 8. Then set it back to 1. `skip_to_morning()` advances `sim.day` by 1 and leaves `tick_in_day == 0`.
5. Player:
   - After `from_dict({})` the player stands within 1.5 tiles of City Hall's frontage road, on ground (`abs(y − ground_height) < 0.002`).
   - Set `input_enabled = false` and walk along the sidewalk for 2 s with `simulate`. The displacement is greater than 0.1 u.
   - Walk toward City Hall for 5 s. The feet never end inside any `collision.boxes(hall)` grown by `PLAYER_RADIUS * 0.99`.
   - `player_tile_changed` fired at least once.
6. No camera yank. Record `p0 = player.position` and `cam0 = main.camera_rig.target_position`. Then `sim.trigger_disaster("fire", 16, 14, "player", "fp smoke")`, wait 30 frames, and `main.focus(Vector3(3, 0, 3), 20.0, "tile")`. Assert:
   - `bus.ping` was received at least twice, and one reason begins with `"event:"`.
   - The player position is unchanged.
   - The rig target is unchanged (`camera_rig.target_position == cam0`).
7. Directory: `street_at(player.position)` is non-empty. There is at least one `business_name` in the city when any C lot exists.
8. De-branding:
   - Every `sim.mayors[i].name` is a display name.
   - `D.debrand("Argon-4")` returns `"Ada Okafor"`.
   - The top bar is read through the slot API only: the visible text of the `Label`s and `RichTextLabel`s under `hud.slot("top_bar")` contains `"Day"` within 1 s, and no `Label` or `RichTextLabel` under it contains a brand word. The smoke calls nothing B-internal, so B can replace the placeholder.
9. HUD: all six slots exist and `hud.is_hud_visible()`. Toggling with `set_hud_visible(false)` then `(true)` works.
10. Pause: `fp.set_paused(true)` sets `get_tree().paused`, `ctx.is_modal()` is true, and `pause_changed(true)` is received. Then unpause.
11. Save and load:
    - Call `main.save_game("user://fp_smoke_save.json")`. The file JSON has `fp.player.pos`.
    - Teleport the player 2 tiles away.
    - `main.load_game("user://fp_smoke_save.json")` returns true. The position is restored (ε 0.01). `world_ready` was received again. `view.fp_mode` is still true.
    - The camera is still the FP camera, and `view.camera == fp.player.camera`.
12. Run 30 frames first (features settle after the load). Feature self-tests: for each feature, `var r := f.self_test()`. Print `FP_SMOKE: feature <id> ok=<ok> <detail>`. Every result must be ok.
13. Run 60 more frames, then print a summary: `FP_SMOKE: day=%d pop=%d features=%d pings=%d`.
14. Print `FP_SMOKE: PASS` or `FP_SMOKE: FAIL <reasons>`. Then `main.audio._exit_tree()` and `get_tree().quit(0 if pass else 1)`.

### 17.5 `tools/tests/fp_shots.gd` and `tools/tests/fp_photo_tour.gd`

`fp_shots.gd` (static, `extends RefCounted`):

```gdscript
## Deterministic eye-level shots for a grown city. Each: {"name", "pos" (feet), "yaw", "pitch", "hour"}.
static func find(sim: CitySim, dir: CityDirectory, col: CollisionWorld) -> Array
```

| Shot | Selection (first match in `sim.active` order) | Camera | Hour |
|---|---|---|---|
| `street` | the straight road tile with at least 5 straight neighbours along its axis and the highest sum of zone levels within 7 tiles on both sides (the fp_bench algorithm) | sidewalk point (+1 side), looking along the run, pitch 2° | 10.5 |
| `intersection` | the tee or cross tile with the most developed tiles within 3 | corner sidewalk `(±0.4, ±0.4)` toward the most developed quadrant, looking diagonally across the junction | 10.5 |
| `downtown` | the `ZONE_C` tile with the highest level (≥ 2; ties by land_value) that has a frontage | frontage sidewalk facing the building, pitch +15° | 10.5 |
| `park` | a `PARK` tile with a frontage, else the first `FOREST` tile next to a road | frontage sidewalk facing the park | 10.5 |
| `residential` | the `ZONE_R` level ≥ 1 tile with the most R neighbours, with a frontage | frontage sidewalk facing it | 10.5 |
| `river` | a bridge tile if any, else the road tile next to core water with the most water neighbours | bridge sidewalk looking along the river (or at the water) | 10.5 |
| `dusk` | the `street` pose | | 18.4 |
| `night` | the `intersection` pose | | 23.0 |

Shots that cannot be found fall back to the `street` pose with their own name. The tour therefore always writes 8 shots.

`fp_photo_tour.gd` (`extends Node`, `run(main, dir)`):

1. `DirAccess.make_dir_recursive_absolute(dir)` and `get_tree().root.size = TARGET_SIZE` (`Vector2i(1600, 900)`, D11): on this machine's display the window opens at 1280×660 despite `--resolution 1600x900`. Then `main.fp.apply_settings({"camera_mode": "first"}, false)` (the base shots are eye-level; not saved, D13), `main.sim.start()`, then `await main.grow_offline(int(env GRIDFALL_PHOTO_DAYS or 6), 240000)`. Third-person shots come from features' `photo_shots()` with their own `prepare` / `restore` (A's `tps_*`).
2. Keep the sim paused (speed 0) so no disaster interrupts the tour. Set `main.fp.player.input_enabled = false`.
3. `shots = fp_shots.find(...)` plus every feature's `photo_shots()`.
4. For each shot:
   - If the shot has `"prepare"`, call it on the feature that returned the shot (`f.call(shot.prepare)`).
   - Set `main.sky.fixed_hour = shot.hour` and `player.teleport(pos, yaw, pitch)`.
   - Wait 1.6 s (2.4 s when the hour changed), then `await RenderingServer.frame_post_draw`.
   - Save `<dir>/<name>_hud.png`.
   - `hud.set_hud_visible(false)`, wait 2 frames and `frame_post_draw`, save `<dir>/<name>.png`, then `set_hud_visible(true)`.
   - If the shot has `"restore"`, call it.
   - Print `FP_PHOTO: shot <name> pos=(x,y,z) yaw=<deg> labels=<n>`, where n counts the visible Label3Ds under CityView (report-only; S0 shows none).
5. Print `FP_PHOTO: DONE n=<shots> day=<d> pop=<p> size=<w>x<h>` (the real root size). Then `main.audio._exit_tree()` and `quit(0)`.

### 17.6 `tools/tests/fp_bench.gd` (perf report; owned by G2 after S0)

This is a port of `.../scratchpad/tools/fp_bench.gd`, with these changes:

1. Set `get_root().size = TARGET_SIZE` (`Vector2i(1600, 900)`, D11; the window can open smaller than `--resolution`) after the boot frames and again after placing the player, never in `_init` before the window is up (the window manager overrides that). Before instantiating `main.tscn`, call `OS.set_environment("GRIDFALL_VIEW", "fp")`. Then `sim.start()` and `await main.grow_offline(env FPBENCH_DAYS or 6, 120000)`.
2. Right after the boot frames, `fp.apply_settings({"camera_mode": "first"}, false)` so every label stays comparable with the S0 baseline (D13; G2 adds its own third-person label). Place the player with `fp_shots.find(...)` (`street`).
3. Measure 4 s each:
   - `street_eye_hud`.
   - `street_eye_nohud`, using `hud.set_hud_visible(false)`.
   - `street_cross_nohud`, after turning 90°.
   - `street_tick`: `sim.set_day_seconds(12.0)` and `sim.set_speed(1)` for 6.5 s, so two ticks run through the normal `_process` path, then restore. This is the stall the F slice must remove.
   - `street_day_end`: the same, after setting `sim.tick_in_day = 3`, so the window contains a day end and a day start (the 690 ms boundary measured in `tick_split.log`).
4. Each measurement prints `FPBENCH {json}` with the scratch fields (`avg_ms`, `p50_ms`, `p99_ms`, `max_ms`, `gpu_ms`, `rcpu_ms`, `draws`, `objects`, `prims`, `vram_mb`, `nodes`, `hitches_over_33ms`) plus `viewport` (`"<w>x<h>"`, the real root size). Finish with `FPBENCH: DONE` and `quit(0)`. It is report-only.
5. Save `bench_street.png` to `FPBENCH_DIR`.

---

## 18. `tools/gate.sh`

```
usage: tools/gate.sh quick|full|render [--only <step-substring>] [--keep]
env:   GODOT (default: godot)   GATE_LOG_DIR (default: /tmp/claude-1000/gf-gate-<branch>-<UTC ts>)
       DISPLAY (render only; default :1)
```

Behaviour:

1. **Setup.** Run with `set -u -o pipefail`. `cd "$(dirname "$0")/.."`. `mkdir -p "$GATE_LOG_DIR"`. A `trap` removes the temporary XDG directories unless `--keep` is given.
2. **Environment for every Godot step.** Use a fresh `XDG_DATA_HOME=$(mktemp -d /tmp/claude-1000/gf-xdg.XXXXXX)` and `GRIDFALL_OFFLINE=1`. Clear the inherited variables: `env -u GMI_API_KEY -u GRIDFALL_RECORD -u GRIDFALL_VIEW -u GRIDFALL_SPEED -u GRIDFALL_HOUR -u GRIDFALL_RESIDENTS`. Wrap the command in `timeout <secs>`.
3. **Heavy steps** (import, orbit smoke, FP smoke, photo tour, bench) are prefixed with `flock -w 3600 /tmp/claude-1000/gf-heavy.lock`.
4. **Import pre-flight.** Run a heavy `"$GODOT" --headless --path . --import` (timeout 900) when any of these holds: `.godot/imported` is missing or empty (the cold-worktree case, 85 s, 2.2 GB); `.godot/gate_import.stamp` is missing; or any `*.import` file, or any asset file under `models/`, `textures/`, `env/`, `sounds/` or `assets/`, is newer than the stamp (`find … -newer .godot/gate_import.stamp -print -quit`). After a successful import, `touch .godot/gate_import.stamp`. Godot's import is incremental, so a warm checkout after a merge only re-imports what changed. A warm worktree with stale imports therefore never runs tests against missing assets.
5. **Step runner.** `run_step <name> <token> <timeout> <heavy:0|1> -- <env...> -- <godot args...>` writes `$GATE_LOG_DIR/<name>.log` and records RESULT and SECS. Results, in order of precedence:
   - `TIMEOUT` when the exit code is 124.
   - `FAIL(script-error)` when the log matches `SCRIPT ERROR|Parse Error|Failed to load script|Failed loading resource|No loader found`.
   - `FAIL(no-token)` when the token is missing.
   - `FAIL(exit=N)` when the exit code is not 0.
   - `PASS` otherwise.
6. **Steps.**

| Mode | Step | Command (after the env) | Token | Timeout |
|---|---|---|---|---|
| quick | `parse_all` | `--headless --path . -s tools/tests/parse_all.gd` | `PARSE_ALL: PASS` | 180 |
| quick | `sim_test`, `buildings_test`, `residents_test`, `expansion_test`, `construction_test` | `--headless --path . -s tools/tests/<name>.gd` | `SIM_TEST: PASS` and so on | 300 each |
| quick | every `tools/tests/fp_*_test.gd`, sorted | `--headless --path . -s <file>` | `FP_..._TEST: PASS` (from the file name) | 300 each |
| full | quick, plus `orbit_smoke` (heavy) | `GRIDFALL_SMOKE_TEST=1` / `--headless --path .` | `GRIDFALL_SMOKE: PASS` | 400 |
| full | `fp_smoke` (heavy) | `GRIDFALL_FP_SMOKE=1` / `--headless --path .` | `FP_SMOKE: PASS` | 400 |
| render | `fp_photo` (heavy) | `DISPLAY=${DISPLAY:-:1} GRIDFALL_FP_PHOTO_DIR=$GATE_LOG_DIR/photos GRIDFALL_PHOTO_DAYS=6` / `--path . --resolution 1600x900 --audio-driver Dummy` | `FP_PHOTO: DONE` | 400 |
| render | `fp_bench` (heavy) | `DISPLAY=… FPBENCH_DIR=$GATE_LOG_DIR/bench` / `--path . --resolution 1600x900 --audio-driver Dummy -s tools/tests/fp_bench.gd` | `FPBENCH: DONE` | 400 |

   `render` does not include quick or full. After `fp_photo` passes, the gate also checks that 16 PNGs exist (`<shot>.png` and `<shot>_hud.png` for the 8 named shots). If any are missing the step becomes `FAIL(photos)`. If the `FP_PHOTO: DONE` line does not say `size=1600x900`, the step becomes `FAIL(size)`. After `fp_bench` passes, every `FPBENCH {json}` row must carry `"viewport":"1600x900"`, else the step becomes `FAIL(size)`: D11's budgets are for 1600×900, and on this machine's display the window opened at 1280×660 (41 % fewer pixels) until the scripts set the size themselves.
7. **Summary.** A fixed-width table: `STEP | RESULT | SECS | LOG`. For `render`, also print the `FPBENCH` JSON lines as a table (label, fps, avg, p99, max, draws, vram_mb, viewport). The perf numbers are **report-only**. Print the photo directory path. The last line is `GATE <mode>: PASS` or `GATE <mode>: FAIL (<n> failed)`.
8. **Exit code.** 0 iff every step passed; 1 otherwise; 2 on bad usage.

The live tests (`brain_live_test`, `residents_live`, `dump_prompts`) are never run.

---

## 19. Acceptance criteria for S0

Run all of these from the worktree root.

1. `tools/gate.sh quick` exits 0. The summary shows PASS for `parse_all`, the five legacy unit tests, `fp_core_test`, `fp_directory_test`, `fp_seams_test` and `fp_world_scale_test`.
2. `tools/gate.sh full` exits 0. It adds `GRIDFALL_SMOKE: PASS` and `FP_SMOKE: PASS`. The orbit smoke log still shows `GRIDFALL_SMOKE: save/load ok=true` and `day 6->6`. The FP smoke log shows nine `FP_SMOKE: feature <id> ok=true stub` lines.
3. `tools/gate.sh render` exits 0. `$GATE_LOG_DIR/photos/` holds the 16 PNGs. The shots are at eye level: the horizon sits near mid-frame, and there are no mayor robots, floating labels, haze ceiling or cursor. The `_hud` variants show the status line and crosshair. FPBENCH lines are printed.
4. Manual windowed check, with `XDG_DATA_HOME=$(mktemp -d /tmp/claude-1000/gf-xdg.XXXXXX) GRIDFALL_OFFLINE=1 DISPLAY=:1 timeout 300 godot --path .` under the heavy lock:
   - The game boots into first person with the mouse captured.
   - WASD and the arrow keys walk, and Shift runs.
   - Buildings block, and water blocks.
   - `]` and `[` cycle 1×, 2×, 4×, 8×, and the sky keeps cycling at 8×.
   - T skips to morning.
   - Esc pauses and shows the pause card. F5 and F9 save and load. F1 hides the HUD.
   - A fire or quake never moves the camera.
5. `GRIDFALL_VIEW=orbit` under the same command boots today's orbit game, CityHud included, with no visible change except the name links: mayor and district labels, cards and the cinematic keep the brand names (D-S0-7), the log, Gazette, posts and resident text use display names (D-S0-6, D-S0-8), and the mayor inspector line and card tooltips connect the two.
6. `git diff --stat fp/integration...` touches only the files in §2. Within the edited legacy files, only the hunks in §15 and §6.2 appear: `git diff -U0` on each file is reviewable against this spec.
7. `grep -rn "focus_world_point" scripts/main.gd` shows only the `focus()` body and the orbit-only modes (`_run_photo_tour`).
8. `grep -rn "BASE_DAY_SECONDS" scripts` shows only `sim_defs.gd:22`, the default in `city_sim.gd`, `grow_offline` and `exit_fp`.

---

## 20. What S0 must NOT do (left to the slices)

- No jump, crouch, step-up limit, head bob, capsule collision against props, interact prompt or photo mode (A).
- No chips, minimap, full map, compass, street label, real pause menu or settings UI (B). S0 only ships placeholders.
- No chat, chatter LLM role or talk dialogue (C). No image client or posters (D).
- No lane graph, new agents, or changes to CityLife or ResidentAvatars beyond line 194 (E). Ambient Kenney traffic is only switched off in FP.
- No time slicing or other perf changes to the sim, residents or minds (F).
- No `REAL_SCALE`, people, vehicle or machine rescale. No ground, water, tree, light-profile, environment, weather or yaw-to-street changes. No new shaders (G1). In particular, S0 does **not** touch `main-environment.tres`, the Sun or the FOV of the orbit camera.
- No `[rendering]` changes, visibility ranges, occluders, import edits or quality presets (G2).
- No Blender runs and no asset changes (H). No audio changes (I).
- No new autoloads, no physics nodes, no edits to `scenes/main.tscn`, no deleting of legacy code (`gridfall_hud.gd`, `gridfall_world.gd` and the Kenney models stay).

---

## 21. S0 performance budget

- FpMode, the player, collision queries and the HUD placeholders together cost at most 0.5 ms per frame of GDScript. The placeholder label refreshes at 4 Hz. Hot paths make no per-frame allocations.
- S0's `view.set_fp_mode(true)` (visibility only) costs at most 20 ms, one time. G1's version also rebuilds FP-only geometry on a real value change; that is a measured one-time cost (record it in G1's hand-off) shown behind a `"Entering the street…"` toast, and boot avoids it entirely through the early flag (§6.1).
- `building_aabb()` costs at most 5 µs per call: dictionary lookups plus the cached `_local_bounds`.
- FP mode must not be slower than the orbit baseline at the same camera pose, measured by fp_bench `street_eye_nohud`. Expect a small gain, because ambient traffic and `_refresh_status` are off.

---

## 22. Risks and notes for the S0 implementer

- **Signal ordering on load.** `view.setup()` emits `world_rebuilt` before `main.load_game` calls `fp.from_dict()`. Features must therefore treat `on_world_rebuilt` as "geometry is back" and `from_dict` as "state is back", in that order.
- **`hud.setup()` on load.** It still runs on the hidden CityHud (`main.gd:159`). That is harmless, and it keeps the orbit smoke and `exit_fp()` working.
- **`grow_offline` timing.** It runs with FP active, so features see a fast-forwarded city. Slices whose features do per-tick work must survive 16× speed with 12 s days during tests.
- **A paused tree stalls HTTPRequests.** In-flight LLM calls stall while paused. That is acceptable: offline gates never pause.
- **Real-model lot AABBs.** They cover the whole 0.846 lot, so S0 blocks the player from lots. That is expected until A refines it. Per-surface measurements show the geometry above the slab also fills the lot (trees, hedges, awnings), so A cannot simply split the AABB; A builds body boxes from per-surface vertex bounds (`slices/A-player.md`). `building_aabb` stays the full bound for picking.
- **Untested assumption.** If `model.scene_file_path` is empty for an imported GLB root, which the probe did not test, store the model path from `_build_tile` instead. The zone branch has `pick` and the service branch has `spath`. `building_aabb` must not change its contract either way. `fp_seams_test` catches this case.

---

## 23. Decisions taken in this spec (binding)

| # | Decision | Why |
|---|---|---|
| D-S0-1 | First person runs on a **20-minute game day** (`FP_DAY_SECONDS = 1200`). Time scales are 1, 2, 4 and 8, mapped directly onto `sim.set_speed`. | This is D4. Using `sim.speed` keeps one clock. |
| D-S0-2 | **Pause uses `get_tree().paused`.** FpMode and FpHud are `PROCESS_MODE_ALWAYS`; everything else is pausable. | Traffic, sky, sim and agents freeze with no per-slice code. |
| D-S0-3 | **The modal stack lives in FpContext**, and the mouse is captured iff nothing is modal and the game is not paused. | One owner for mouse capture. Chat, the map, menus and dialogue just push and pop. |
| D-S0-4 | **The FP smoke, photo tour and bench live in `tools/tests/`.** Main loads them at runtime with `load()` (not `preload`). | This matches the ARCHITECTURE ownership row, and nothing test-only is preloaded into the game. |
| D-S0-5 | **Spawn on City Hall's frontage sidewalk**, facing the hall. | It is deterministic, central, and always exists in a new city. |
| D-S0-6 | **`sim.mayors[i]["name"]` becomes the display name** in new cities and on load. `D.MAYORS[i]["name"]` stays the brand label, and `display` is new. | One choke point de-brands every log line, report and prompt that reads `sim.mayors`, and saves keep their shape. |
| D-S0-7 | **The orbit CityHud, the orbit world labels (`city_view.gd` district and mayor-bot labels) and the cinematic keep model branding.** The mayor inspector and card tooltips add `Mayor <display>` so both names are linked. | D6 keeps CityHud only for orbit, as the legacy GMI showcase. Every FP surface uses display names. |
| D-S0-8 | **`D.debrand()` runs at the LLM source** (mayor post and thought, Gazette, council statement, resident say, thought, mood reason and letters, restored brain state) and again at display in B, C and D. | The tracked replay cache contains brand names, and it must not be rewritten (D9). |
| D-S0-9 | **Street names come from row and column coordinates**, with band qualifiers outside the core. They are never derived from connectivity. | Names never change as the city grows, which posters, chat and saves rely on. |
| D-S0-10 | **`CityDirectory.frontage()` is the single rule for which street a lot faces.** G1 orients buildings with `frontage_yaw()`. | Addresses, shop signs, posters and building fronts all agree. |
| D-S0-11 | **Feature hooks `pick()`, `self_test()` and `photo_shots()` are added to `FpFeature`**, beyond the lifecycle in ARCHITECTURE §3. | Interaction, the smoke and the tour can then grow inside slice-owned files, without anyone editing shared files. |
| D-S0-12 | **Ownership additions.** F owns `scripts/fp/sim/**`, G1 owns `scripts/fp/street/**`, and B owns `scripts/fp/ui/hud_widgets_feature.gd`. S0 owns `scripts/fp/road_topology.gd`, `tools/tests/fp_kit.gd`, `fp_shots.gd` and `fp_photo_tour.gd`. G2 owns `tools/tests/fp_bench.gd` after S0. | Each slice needs a home for its feature entry point. |
| D-S0-13 | **The sky hold uses day length, not speed** (`sky_director.gd:54`). This is one extra seam beyond ARCHITECTURE §4. | Without it, FP at 8× freezes the sky at 13:00. Orbit behaviour is identical. |
| D-S0-14 | **The seams add `city_sim.tick_seconds()` and `skip_to_next_day()`** (beyond `day_seconds`). | One read path for the tick length, and a correct "T" skip that lands at 06:00 without FP touching sim internals. |
| D-S0-15 | **Extra input actions:** `hud_toggle` (F1), `quick_save` (F5) and `quick_load` (F9). | CityHud's F5 and F9 are disabled in FP, and photo and HUD toggles need keys. |
| D-S0-16 | **The world scale was verified:** `SIDEWALK_TOP = 0.009` (18 cm above the tile datum), with a 12 cm curb face (`CURB_RISE = 0.006`) above asphalt at 0.003. | Confirmed against `roads.py` `ZA` / `ZS`. The ARCHITECTURE wording "18 cm curb" refers to the sidewalk top. |
| D-S0-17 | **Discrete input fires only from `_unhandled_input`** on `is_action_pressed(…) and not is_echo()`; UIs with a text field catch Esc in `_input()`; FpMode's hotkeys are blocked under any modal except pause (§7.2). | Polling sees keys a UI already consumed and letters typed into a LineEdit, which reopens closed cards and fires hotkeys mid-chat. |
| D-S0-18 | **Movement collides against `CollisionWorld.boxes(i)`; picking uses `view.building_aabb(i)`.** Every movement test asserts against `boxes()`. | A must be free to tighten bodies without breaking S0's tests; the full AABB keeps place cards reachable. |
| D-S0-19 | **`fp_kit.make_ctx` builds a complete context** (brain, sky, stub mode, player, HUD, optional render/audio, injectable client) and an optional scripted growth recipe with asserted fixtures. | Slice tests otherwise dereference null fields or test an empty city. |
| D-S0-20 | **`WS` ends with one marked section per slice**; a slice adds constants only inside its own. | Parallel appends at the end of one file always conflict in git. |
| D-S0-21 | **New seams beyond ARCHITECTURE §4:** `CityView.site_boxes` / `site_bounds` and the construction kit's `colliders` meta on the Site node (§15.1), `in_setup`, `fp_mode_changed`; `CityDirectory.planned_name`; `GameBus.card_action`; `AP.load_scene` and node-name prefixes; `RoadTopology` end island; the early `view.fp_mode` flag in `main.gd`; the `trip_started` mode normalisation; two de-branding lines in `city_brain.gd` (639, 800). | Each one removes a guess or a crash that a reviewer found in a slice contract. |
| D-S0-22 | **The gate re-imports whenever imports or assets are newer than a stamp**, and fails on loader errors. | A warm worktree must never pass tests with missing assets after H or G2 merges. |
| D-S0-23 | **Third-person hooks (ARCHITECTURE D13).** `DEFAULT_SETTINGS` gains `camera_mode: "third"`, `tps_fov`, `tps_distance_m`, `shoulder`, `auto_shoulder` and `hero`; `project.godot` gains `view_toggle`, `shoulder_swap`, `zoom_in` / `zoom_out` and `look_*` (§16); `fp_kit.make_ctx` defaults `camera_mode` to `"first"`; `apply_settings(patch, persist := true)` with `persist = false` for scripted overrides; the photo tour and `fp_bench` force first person with it. S0's `FpPlayer` ignores the camera settings until A implements them. | Interactive play is third person, but every existing test, baseline shot and bench label keeps its first-person meaning; a scripted override must never rewrite the player's saved camera choice. |

---

## Review log

Three reviews (ABC: S0, A, B, C — 28 issues; DEH: D, E, H — 45 issues; FGI: F, G1, G2, I — 41 issues) were checked against the code at `611d727`. The load-bearing claims were re-verified by reading the cited lines (`roads.py` lamps and end island, `city_view.gd` bus stops, hashes and material tuning, `residents.gd` `_post_message`, `_go`, `_check_home`, `district_mood`, `city_brain.gd` mood words, `last_paper`, inspector and chaos paths, `gmi_client.gd` offline paths and caches, `city_sim.gd` tick, day boundary and log lines, `resident_avatars.gd`, `city_life.gd`, `sky_director.gd`, `audio_director.gd`, `project.godot` `[rendering]`, `make_realistic_city.py`, `arch.py`, the test files), and by one headless probe of the `fp_kit` growth recipe (seed 7).

**Rejected: none.** Every issue was valid and is fixed in the files listed below.

**Where the fix deviates from the reviewer's proposal** (one line each):

- ABC-8 + DEH-18 (same defect): E's `pick()` returns kind `resident` for named residents on foot, and A also rewrites a `pedestrian` with `driver_id` defensively; A stops its own avatar scan when E provides `visible_near`.
- DEH-1: the probe found **no billboard** in the grown kit city, so the fixture is not guaranteed; D's test instantiates one on a C-lot holder instead of failing. Corner, tee, cross, bus stop and resident fixtures are guaranteed and asserted by `fp_core_test`.
- DEH-20: band values adjusted for the lamps baked into `road_straight_lights.glb` at ±0.34 (the proposed `PED_BAND [0.33, 0.40]` contained them): `CURB_FURNITURE [0.305, 0.345]`, `PED_BAND [0.355, 0.405]`, `FRONT_FURNITURE [0.415, 0.49]`; H's 0.075-deep shelter is centred at 0.4525.
- DEH-23: `v1 = z0 + 0.129`, not `0.127`; with `split = v1 − 0.022` and `v0 = z0 + 0.002` that gives the 0.105 u leaf H targets (0.127 gives 0.103).
- DEH-11: the overlap at the new `PARK_OFFSET` against `LANE_OFFSET` is 20 cm (the 0.5 m figure was for the old 0.23 slot); the fix (`PASS_OFFSET`) is unchanged.
- DEH-26 vs FGI-14 (conflicting merge orders): G2 merges before H, H re-applies, and the integrator runs `--check` after every merge (ARCHITECTURE §7).
- FGI-3: "prefer H's `*-col` proxy" became H's `ColBox_<n>` empties, because DEH-24 showed `-colonly` would create physics bodies.
- FGI-4: besides G1's rebuild on change, `main.gd` sets `view.fp_mode` before the first `view.setup` (§6.1), so boot builds FP geometry once.
- FGI-7: F cannot edit `city_brain.gd`; brain listeners are excluded from F's 50 ms budget and reported as `brain_ms` until the S0-owner request lands.
- FGI-10: the hard budget check is structural (work units per pump); wall-clock stays report-only in `quick` and hard in the locked FP smoke.
- FGI-36: the rain wetness ramp is 120 real seconds at 1×, not "2 game-minutes" (1.7 s at FP day length, 0.02 s at the kit's 12 s day).
- FGI-37: the tick-SFX throttle applies in orbit too (a bug fix in both modes); FP suppresses `gridlock_alert`.
- FGI-38: the director runs `PROCESS_MODE_ALWAYS` in FP so the music keeps playing, muffled, in the pause menu; FP world players pause with the tree.
- FGI-41: occlusion culling is enabled on the FP viewport at runtime, so orbit pays nothing; the project setting is the fallback if a probe shows it is required.
- FGI-15: the added failure strings (`Failed loading resource`, `No loader found`) were checked against every baseline log in the research scratchpad (`logs/*.log`): none matches today.
- ABC-28: besides C's display filter, S0 fixes the two sources (`city_brain.gd:639` editorial, `:800` inspector prompt).

**Where each fix lives.**

| File | Issues |
|---|---|
| S0 (this file) | ABC-1, 4, 6, 10, 13, 15, 16, 18, 19, 20, 22, 24, 26, 27, 28; DEH-1, 3, 11, 16, 17, 20, 22, 25, 30, 33, 35, 43, 44; FGI-4, 5, 15, 16, 18, 26, 31, 36 |
| ARCHITECTURE | ABC-4; DEH-26, 35; FGI-14 (rules 7–11, §7 integration) |
| A-player | ABC-1, 2, 3, 4, 8, 9, 17, 18, 19, 20, 21; DEH-18, 24 |
| B-hud | ABC-4, 6, 9, 14, 22, 23, 24, 27, 28 |
| C-chat | ABC-4, 5, 6, 7, 10, 11, 12, 13, 22, 25, 26, 27, 28 |
| D-posters | DEH-1, 2, 4, 5, 6, 7, 8, 9, 10, 27, 28, 29, 30, 31, 32, 33, 34, 35; ABC-4 |
| E-traffic | ABC-8, 9; DEH-1, 3, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 36, 37, 38, 39, 40, 41; FGI-25 |
| F-simperf | FGI-1, 2, 7, 8, 9, 10, 27, 28, 29, 30 |
| G1-streetscape | ABC-3; DEH-19, 20, 27, 30; FGI-4, 5, 6, 12, 13, 14, 17, 20, 21, 22, 32, 33, 34, 35, 36 |
| G2-renderperf | DEH-13, 26; FGI-3, 11, 12, 13, 14, 17, 18, 19, 23, 35, 41 |
| H-assets | DEH-6, 10, 13, 19, 20, 21, 22, 23, 24, 26, 41, 42, 43, 44, 45 |
| I-audio | FGI-24, 25, 26, 37, 38, 39, 40 |
