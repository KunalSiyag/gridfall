# Slice H: Assets

Branch `fp/H-assets`, branched from `fp/integration` after S0. Read ARCHITECTURE D1, D10 and D13, S0 §4 (scale) and §4.4 (`asset_paths.gd`). In `understand.md`, read "LOOK & ASSETS" and CRITIC (d), which covers the scale verdicts and the door defect. The pipeline is `tools/blender/make_realistic_city.py` plus `tools/blender/realcity/*.py`, validated by `tools/blender/validate_real.py`.

## Goal (what the player sees)

Close-up assets that hold up at eye level and over the hero's shoulder:

- **Cars** are true 1.0× size, with wheels that spin and see-through tinted glass, plus headlights, tail lights and brake lights.
- **Street hardware:** traffic lights, pedestrian signals, street-name signs, stop and yield signs, curb ramps at crosswalks, bike racks, parking meters and "For lease" boards.
- **Poster carriers:** a bus shelter, a billboard, a wall poster frame and a construction hoarding. Each has a real UV'd poster surface.
- **Doors** are tall enough for a person to walk through.

Every asset is validated, and every consumer falls back gracefully when a file is missing.

**People are no longer H's (D13, T-D4).** The procedural rigged people of the old §1 are dropped: the trial looked "stiff, crouched, clay-figure" at 2–4 m, which the third-person camera shows constantly. Slice HC builds every person (hero, residents, crowd) from Microsoft Rocketbox and Quaternius (`docs/fp/slices/HC-characters.md`). H keeps the legacy `models/real/people/person_{a..h}.glb` untouched: they are the fallback when a character file is missing and A's placeholder hero until HC lands.

## Owned files (exclusive)

- `tools/blender/**`, including `realcity/*.py`, `make_realistic_city.py`, `validate_real.py` and `render_real.py`.
- `models/real/**`, both the GLBs and their extracted textures. Import **parameters** belong to G2: when you regenerate files, run `python3 -I tools/optimize_imports.py --apply <your paths>` **if the script exists** (G2 merges before H; H rebases onto it, ARCHITECTURE §7), so its settings survive. New `.import` files start with default parameters and would fail G2's `--check` otherwise.
- `scripts/fp/asset_paths.gd`, the path list only, **except HC's marked `# --- HC characters ---` section** at the end of the file (D13). Add constants freely outside it; never rename the S0 ones. `PEOPLE_RIGGED_DIR` stays as a constant (S0 names are never renamed) but is retired: nothing produces or reads it.
- `tools/polyhaven_fetch.py`. G1 may add one HDRI entry; accept it.
- `tools/tests/fp_assets_test.gd`.

## Seams consumed

| From | API |
|---|---|
| S0 `WS` | `M` (= `core.M`, 1/20), `PERSON_H` (1.75 m), `VEHICLE_V2_SCALE` (1.0), `ROAD_HALF`, `SIDEWALK_TOP`, `ASPHALT_TOP`, `LAMP_HEIGHT`, `LOT_FOOTPRINT`, `CURB_FURNITURE`, `FRONT_FURNITURE`. `fp_world_scale_test` parses `roads.py` `ZA` / `ZS` / `HW`, the `ZM = ZA + <n>` expression, and `core.py` `M`; **do not change those authoring constants or the form of the `ZM` line.** |
| S0 `AP` | every constant in S0 §4.4 is a delivery target, including the node-name prefixes `POSTER_NODE_PREFIX`, `POSTER_SPOT_PREFIX`, `DOOR_SPOT_PREFIX`, `COLBOX_PREFIX`, and `WHEEL_NODES` / `BIKE_WHEEL_NODES`. Not H's: `PEOPLE_RIGGED_DIR` (retired), `PERSON_ANIMS` / `PERSON_LOOPING` (now HC's animation-library contract) and HC's section. |
| Consumers (contracts to honour) | E: `VEHICLES_V2_DIR` (`AP.WHEEL_NODES`, `Seat_Driver`, light surfaces, `<name>_lod1.glb`), `TRAFFIC_LIGHT` (with `SignText_A` / `SignText_B`), `PED_SIGNAL`, `STOP_SIGN`, `YIELD_SIGN`, `BICYCLE`, `Door_<n>` empties. G1: `STREET_SIGN`, `BUS_SHELTER`, `BILLBOARD_POSTER`, `CROSSWALK_RAMP`, `BIKE_RACK`, `PARKING_METER`, `LEASE_SIGN`, door fix. D: `BILLBOARD_POSTER`, `BUS_SHELTER`, `POSTER_FRAME`, `HOARDING`, `LEASE_SIGN` (`Poster_<n>` nodes), `PosterSpot_<n>` empties on zone and building walls. A and G2: `ColBox_<n>` empties (optional). |

## Seams H may request

- From G2: a re-import window after large re-exports. Coordinate it in `docs/fp/requests/H-needs.md`.

## Deliverables: the GLBs and their target paths

Run every build headless with `blender --background --python tools/blender/make_realistic_city.py -- <category|key>`. Blender is a flatpak and cannot see `/tmp`, so keep scratch output under `$HOME` or a gitignored folder in the repo. Seeds stay `crc32(key)` for existing keys; a **new key that re-builds a legacy asset** (`vehicles_v2/sedan_blue`, …) seeds with the crc32 of its **legacy** key (`vehicles/sedan_blue`), so identities and palettes match (`make_realistic_city.py:59`). Register the new categories in `registry()`: `street` and `vehicles_v2`.

**Named parts survive the merge.** `build()` merges all geometry into `<name>_body` and `<name>_foliage` (`make_realistic_city.py:63-64`). Every node-name contract below (`Poster_<n>`, `Wheel_*`, `Signal_*`, `Walk_0`, `SignText_*`, `PosterSpot_<n>`, `Door_<n>`, `ColBox_<n>`, `Seat_Driver`) is created as its own object **outside** that merge (the way `part()` already builds `Bulb_<n>`, `roads.py:146`), so it reaches the GLB as its own node.

### 1. People: superseded (D13, T-D4)

H builds no people. Rigged, animated people come from slice HC (`models/characters/**`). Do not create `models/real/people_rigged/`, and leave `tools/blender/realcity/people.py` and the legacy `models/real/people/` outputs unchanged.

### 2. Vehicles at 1.0×: `models/real/vehicles_v2/<name>.glb`

- Same keys as `vehicles/`: sedan_*, hatchback_*, suv_*, coupe_*, pickup_*, van_*, taxi, police, ambulance, firetruck, bus, truck, garbage_truck. Add `bicycle`.
- Built with `VS = M` (real size), using a `vehicles.py` parameter that leaves the legacy `VS = 1.2*M` path and its outputs unchanged.
- **Wheels are separate nodes** `Wheel_FL`, `Wheel_FR`, `Wheel_RL` and `Wheel_RR` (`AP.WHEEL_NODES`), with the origin at the hub so they spin about local X. The bicycle has `Wheel_F` and `Wheel_R` (`AP.BIKE_WHEEL_NODES`).
- A `Seat_Driver` empty.
- `Glass_Car` is semi-transparent and tinted (alpha about 0.55).
- Separate light surfaces with the materials `Light_Head`, `Light_Tail`, `Light_Brake`, `Light_Indicator_L` and `Light_Indicator_R`.
- Emergency vehicles keep `Siren_0` and `Siren_1`. Wheels touch y = 0 and the front faces +Z.
- At most 9,000 tris and at most 8 materials.
- **LOD variants for E's batching:** `<name>_lod1.glb` next to each vehicle: a **single material** (an atlas or vertex colours), wheels merged and static, at most 1,500 tris. E draws them as one MultiMesh per model beyond 2 u; without them 60 cars × 8 materials is about 480 draws before shadows. (People LODs are HC's `<Name>_lod1.glb`.)
- The legacy `vehicles/` files stay untouched.

### 3. The street kit: `models/real/street/`

Sizes are in metres; divide by 20 for units. The front faces +Z, the base sits at y = 0, and the footprint is at most 0.25 u unless noted.

| File | Content and contract |
|---|---|
| `traffic_light.glb` | A 4.5 m pole at the origin with a **5.5 m mast arm along local −X** (E stands it at a corner (±0.42, ±0.42); from there a 2.5 m arm would end at 0.295, never over the lane at 0.15) and one 3-lamp head at the arm's end facing +Z. **Footprint exception:** ≤ 0.3 u along X. The lamp nodes are named `Signal_Red_0`, `Signal_Amber_0` and `Signal_Green_0`, each with its own material (E swaps on and off states per instance with `material_override`). Include a small pedestrian head with `Walk_0` and `DontWalk_0`, and `SignText_A` / `SignText_B` empties on the pole at 3.0 m (blade anchors for G1's street names on cross tiles, A along X, B along Z). |
| `ped_signal.glb` | A 2.6 m post with `Walk_0` / `DontWalk_0` |
| `street_sign.glb` | A 3.2 m pole with two perpendicular blades. `Blade_A` runs along X and `Blade_B` along Z, each 0.9 × 0.2 m, and each carries a 0..1 UV `SignFace` surface plus empties `SignText_A` and `SignText_B` at the blade centres facing outward (Label3D anchors for G1). |
| `stop_sign.glb`, `yield_sign.glb` | 2.4 m posts with standard shapes. No text geometry; the face has a 0..1 UV `SignFace`. |
| `bus_shelter.glb` | 2.5 m tall, 4 m wide and 1.5 m deep (0.075 u, so it fits `WS.FRONT_FURNITURE`), open to +Z (the road side). A lightbox with a **`Poster_0` node, 1.26 × 2.12 m portrait** and `Lamp_Glow`, plus a bench. |
| `billboard.glb` | The same silhouette as `props/billboard.glb`, with a **`Poster_0` node, 6.8 × 3.0 m** on the +Z face, a centre 5.5 m up, and lamps `Bulb_0` and `Bulb_1` |
| `poster_frame.glb` | A wall-mounted frame, 4 cm deep, with a **`Poster_0` node of 1.2 × 1.8 m**, its back plane at z = 0 |
| `hoarding.glb` | A construction hoarding panel, 6 m × 2.4 m, with **two nodes `Poster_0` and `Poster_1`** of 2.9 × 2.2 m and support feet |
| `curb_ramp.glb` | A crosswalk curb ramp for the 0.3–0.5 sidewalk band, dropping from `SIDEWALK_TOP` to `ASPHALT_TOP` over 1.2 m, with tactile paving. It aligns with the `roads.py` zebra (0.375–0.47). |
| `bike_rack.glb`, `parking_meter.glb` | Simple, at most 1,500 tris |
| `lease_sign.glb` | A "For lease" board on two posts, 1.8 × 1.2 m, with a `Poster_0` node |

**The `Poster_<n>` contract** (`AP.POSTER_NODE_PREFIX`): each poster face is its own `MeshInstance3D` object named `Poster_<n>` (n from 0), with **one surface**, material `Poster`, UVs spanning exactly 0..1, and its normal along **+Z in node space**, kept out of the `<name>_body` merge (otherwise the hoarding's two faces collapse into one surface). D finds them with `find_children("Poster_*", "MeshInstance3D")` and sets `material_override` on each. `SignFace` surfaces follow the same UV rule. Planar box UVs like the current billboard's `Sign_Blue` do not count.

### 4. Door fix (zones and buildings)

- `arch.py` door leaves are 0.088 u (1.76 m), shorter than the people: a door opening spans `v0 = z0 + 0.002` to `v1 = z0 + 0.112` (`arch.py:116`) and the leaf ends at `split = v1 − 0.022` (`arch.py:66`). Raise `v1` to **`z0 + 0.129`**, which gives a **0.105 u (2.1 m)** leaf, and adjust the lintels and transoms within the 0.15 storey.
- **Name the leaf, not the material family.** Today `Door_*` materials are also used for shutters (`zones_res.py:27, 196, 219-220`) and sign lettering (`zones_ind.py:101, 216`), and some doors use `Glass_Shop` (`zones_ind.py:32`, `zones_com.py:237`); in house_bungalow, `Door_Black` spans 0.08 because it is the shutters. Rename the leaf materials `DoorLeaf_*` and the shutter materials `Shutter_*` (lettering keeps its name).
- **Door empties.** Emit one `Door_<n>` empty per doorway (`AP.DOOR_SPOT_PREFIX`): at the bottom centre of the opening, +Z pointing out of the building, `scale.y` = leaf height. E (walk-in targets) and A can use them.
- **Poster spots.** Emit `PosterSpot_<n>` empties (`AP.POSTER_SPOT_PREFIX`) on blank walls of every zone and building model (at least one on the facade that faces +Z where a blank 1.2 × 1.8 m area exists): +Z out of the wall, `scale` = poster size in units. D places wall posters on them.
- **Baked parked cars.** `arch.parked_car` builds blocky primitive cars that read as toys at street level and over the hero's shoulder (G1 must-fix 13, seen in `/tmp/claude-1000/gf-gate-s0-render2/photos/residential.png`). It is called from `zones_res.py` (houses, under carports), `zones_com.py`, `zones_ind.py`, `services.py` and `indkit.py` (parking lots). On the same re-export, rebuild that one function from the `vehicles_v2` body generator at 1.0× (same `color` palette, merged into the model, no wheel nodes), so every call site improves at once; if that breaks a zone budget, drop the calls on the R houses (`zones_res.py:100, 180, 208`) and keep the lots' cars.
- Re-export `models/real/zones/**` and `models/real/buildings/**`, keeping the file names, footprints (≤ 0.94), storey heights (FH 0.15, OFH 0.17) and material names (`WindowLit*`, `Bulb*`, `Beacon`, `Rotor_*`, `Floodlight_*`, `StackTop_*`). G1's night system and the validators depend on those names.
- Optional collision proxies: `ColBox_<n>` **empties** (`AP.COLBOX_PREFIX`; position = box centre, scale = half extents, no mesh, no name suffix) for the body, porch and awnings. **Never** `-colonly` meshes: with `nodes/use_name_suffixes=true` the importer turns them into `StaticBody3D` + `CollisionShape3D` in every instance, orbit included, which breaks ARCHITECTURE D2.

### 5. `validate_real.py` updates

- **New categories.**
  - `vehicles_v2`: length 0.17–0.65 and width ≤ 0.13 for road vehicles (a sedan is about 0.2375 u and a bus about 0.6 u); wheels on y = 0; the 4 `Wheel_*` objects (the bicycle: `Wheel_F`, `Wheel_R`, exempt from the length rule), each wheel's origin within **0.001** of its mesh bounds centre; `Light_Head` faces +Z; each `_lod1` has one material.
  - `street`: footprint ≤ 0.25, except `bus_shelter` (≤ 0.2 × 0.08), `billboard` and `hoarding` (≤ 0.36) and `traffic_light` (≤ 0.3 along X); every `Poster_<n>` object has one surface, material `Poster`, UVs within [0, 1] ± 1e-4 and a +Z normal; every `SignFace` UV set within [0, 1] ± 1e-4; required parts (`traffic_light`: `Signal_Red_*`, `Signal_Amber_*`, `Signal_Green_*`, `SignText_A`, `SignText_B`; `street_sign`: `SignText_A`, `SignText_B`; `hoarding`: `Poster_0`, `Poster_1`).
- **Door rule.** Every zone and building model has at least one `Door_<n>` empty, each with `scale.y ≥ 0.1`; every `DoorLeaf_*` surface is at least 0.1 u tall. No object name ends in `-colonly` (or another physics suffix).
- **Budgets.**

  | Category | Tris | MB |
  |---|---|---|
  | `vehicles_v2` | 9,000 | 1.5 |
  | `street` | 3,000 | 0.8 |

- The legacy checks for `people/` and `vehicles/` (1.2× length 0.2–0.8) stay as they are.

### 6. After every re-export

1. If `tools/optimize_imports.py` exists: `python3 -I tools/optimize_imports.py --apply <the re-exported paths>`, so G2's import settings survive. If it does not exist yet, skip this; the integrator runs it after merging (ARCHITECTURE §7).
2. One heavy `godot --headless --path . --import` under `flock /tmp/claude-1000/gf-heavy.lock`.
3. `tools/gate.sh full`.
4. Commit the GLBs, the extracted textures and their `.import` files together.

## Acceptance tests

1. **Blender validation** (not part of the gate, since it needs Blender): `blender --background --python tools/blender/validate_real.py -- --json $HOME/.cache/gridfall_validate.json` prints a `SUMMARY` with 0 flagged models. Attach the summary line to the hand-off.
2. **`tools/tests/fp_assets_test.gd`**, token `FP_ASSETS_TEST: PASS`, headless Godot:
   - Every `AP` constant path that exists loads through `AP.load_scene()` as a PackedScene and instantiates without errors. Print the list of missing ones; missing is allowed, but the hand-off must list zero missing among H's paths (`PEOPLE_RIGGED_DIR` and HC's section are excluded).
   - Each `vehicles_v2` road vehicle has the 4 `AP.WHEEL_NODES` (the bicycle `AP.BIKE_WHEEL_NODES`), with each wheel's origin within 0.001 of its mesh AABB centre. The sedan length is 0.21–0.25 and the bus 0.55–0.65. Each `_lod1` exists and has one material.
   - **Poster nodes, checked per node:** billboard `Poster_0` local AABB 0.34 × 0.15 ± 0.005; hoarding has `Poster_0` and `Poster_1`; bus shelter, poster frame and lease sign have `Poster_0`; each is a `MeshInstance3D` with one surface, UVs within [0, 1] and a +Z normal.
   - `traffic_light` has `Signal_Red_0`, `Signal_Amber_0`, `Signal_Green_0`, `SignText_A` and `SignText_B`, and its mast reaches x ≤ −0.25.
   - For 2 sampled r1 and c1 zone models, there is at least one `Door_<n>` empty with `scale.y ≥ 0.1`, and at least one `PosterSpot_<n>` on a model that has a blank wall.
   - No instantiated zone, building or street model contains a `StaticBody3D`, `CollisionShape3D` or any other physics node.
   - S0's `fp_world_scale_test` still passes.
3. **Gates.** `tools/gate.sh full` passes, and `render` shows no regressions in the shots.

## Performance budget

| Category | Tris | Materials |
|---|---|---|
| Vehicles | ≤ 9,000 | ≤ 8 |
| `_lod1` variants | ≤ 1,500 | 1 |
| Street props | ≤ 3,000 | ≤ 3 base materials, **plus** the functional ones their contracts require: `Poster*`, `SignFace`, `Signal_*`, `Walk` / `DontWalk`, `Lamp_Glow`, `Bulb*` (the traffic light alone needs `Signal_Red`, `Signal_Amber`, `Signal_Green`, `Walk`, `DontWalk` and a housing) |

- Reuse the Poly Haven 512² derived textures. Add no new 2k textures.
- File sizes are as in the validator.

## Risks

- **Re-export churn.** Re-exporting zones regenerates hundreds of extracted textures and `.import` files, a large diff. Do it once, at the end, after a dry run in a scratch copy under `$HOME`.
- **Licences.** Everything H makes is procedural (own work) or Poly Haven (CC0). Do not import Mixamo or other third-party content into `models/real/**`. The MIT (Rocketbox) and CC0 (Quaternius) exception of T-D1 applies only to HC's `models/characters/**`, with its licence files, and to the animals feature's dogs and cat in `models/real/animals/` (Quaternius, CC0; `models/real/LICENSES/quaternius-dogs.txt`, `models/real/LICENSES/quaternius-cat.txt`).

## Do NOT touch

- Every `scripts/**` file except `scripts/fp/asset_paths.gd`.
- `project.godot`, and the `.import` *parameters* (use G2's script).
- `textures/real` contents (G1).
- The legacy Kenney `models/*.glb` and `models/blender/*`.
- HC's `tools/characters/**`, `models/characters/**` and HC's section of `scripts/fp/asset_paths.gd`.
