# Slice E: Traffic and pedestrians

Branch `fp/E-traffic`, branched from `fp/integration` after S0. Read ARCHITECTURE D1, D2, D8 and D13, S0 §§4, 5, 9, 10 and 15.2–15.3, and the research section "MOVING LIFE" in `understand.md`.

## Goal (what the player sees)

Streets that behave like streets:

- Cars drive in right-hand lanes at 30–50 km/h, follow each other, stop at red lights and yield at T-junctions.
- The cars belong to residents. Priya the nurse leaves home in her own car at the time her mind chose, drives the real road route to the hospital, parks at the curb and walks in.
- Pedestrians walk the sidewalks and cross at zebras. They are realistic, animated people (HC's Rocketbox bodies): a nurse in scrubs, a builder in a hard hat, office workers, a few on the phone or carrying a box, pairs stopping to chat. Until HC lands they are the legacy static people.
- Buses stop at shelters. Fire trucks and ambulances run to incidents with sirens.
- Everyone stops for you. Look at a car and you see who is driving it, and where they are going.

## Owned files (exclusive)

- `scripts/fp/traffic/**` (entry point `traffic_feature.gd`, id `traffic`; `lane_graph.gd`, `junctions.gd`, `agents.gd`, `idm.gd`, …)
- `scripts/world/city_life.gd` (fleets, crews, boats, aircraft)
- `scripts/world/resident_avatars.gd`. Line 194 already holds S0's `sim.tick_seconds()` seam; keep it.
- `tools/tests/fp_traffic_test.gd`

## Seams consumed

| From | API |
|---|---|
| `Residents` (S0 seam) | `trip_started(id, from_i, to_i, mode)` with mode `car`, `bus`, `bike` or `walk` (emitted in `_go` before `resident_moved`; the sim treats arrival as instant, `r.at == to_i`). S0 normalises any other commute value to `"walk"`: `COMMUTES` includes `"stay_home"` (`residents.gd:23`), which line 1015 copies for long non-work trips. `resident_moved(r)` (with `r.route`, an `Array[Vector2i]` of start tile, road tiles, end tile); `resident_departed`; `find(id)`; `people`; `route_between(a, b)`; `trip_load` |
| `CitySim` | `kind`, `terrain`, `traffic[i]` (congestion 0..1), `broken_roads`, `events` (`car_crash` and `power_line` block a road tile), `event_started` / `event_ended`, `day_started`, `speed`, `day_seconds`, `tick_seconds()`, `city_seed` |
| S0 `RoadTopology` | `mask`, `piece`, `arms`, `is_carriageway`, `sidewalk_point`, `is_bridge` (exactly mirrors CityView's road pieces) |
| S0 `WS` | `LANE_OFFSET`, `PARK_OFFSET`, `PASS_OFFSET`, `ROAD_HALF`, `ASPHALT_TOP`, `SIDEWALK_TOP`, `SIDEWALK_CENTER`, `PED_BAND`, `CURB_FURNITURE`, `FRONT_FURNITURE`, `STOP_LINE`, `ZEBRA_NEAR` / `ZEBRA_FAR`, `CORNER_LANE_R_IN` / `OUT`, `END_CIRCLE_R` / `OFFSET`, `END_ISLAND_R`, `CAR_CITY`, `CAR_RESIDENTIAL`, `BUS_SPEED`, `EMERGENCY_SPEED`, `PED_WALK`, `PEOPLE_SCALE`, `VEHICLE_SCALE`, `VEHICLE_V2_SCALE`, `TRAFFIC_RADIUS`, `VIS_CAR`, `VIS_PERSON`, `PLAYER_RADIUS`, `FP_DAY_SECONDS` |
| `CityView` | `bus_stops` (tile idx → truthy; G1 stores the shelter side as a `Vector2i`, `has()` unchanged), `life` (CityLife), `avatars` (ResidentAvatars), `tile_built` / `tile_cleared` / `world_rebuilt`, `in_setup`, `fp_mode`; in FP the ambient Kenney cars and pedestrians are already off (S0 §15.1 #9) |
| `CityDirectory` | `frontage(i)` (curb parking spot and door side), `street_name`, `place_label` (driver card destination text) |
| `FpContext` | `player` (position, for yielding and the spawn ring), `player_position()` (falls back to the spawn point), `world_root`, `collision.ground_height` |
| `GameBus` | listens to `conversation_changed(id, active)` (stop the agent and face the player), `pause_changed`; no emits required |
| `AP` (HC, stage E2) | `CHAR_ROSTER` (`roster.json`: bodies, groups, genders, job pools, `name_gender`, `rest_height_m`), `CHAR_BODIES_DIR` (`<Name>.glb` and `<Name>_lod1.glb`), `CHAR_LIB_M` / `CHAR_LIB_F` (shared libraries; clip names bare, including `AP.PERSON_ANIMS`, `walk_fast`, `idle_look`, `idle_wait`, `phone`, `phone_idle`, `carry`, `talk_2`, `fold_arms`; `speed_mps` meta). `PEOPLE_RIGGED_DIR` is retired (D13, T-D4): H no longer builds rigged people. Until HC lands, people are the legacy `AP.PEOPLE_LEGACY_DIR` GLBs. |
| `AP` (H) | `load_scene()`, `VEHICLES_V2_DIR` (`AP.WHEEL_NODES`, `AP.BIKE_WHEEL_NODES`, `<name>_lod1.glb` variants), `TRAFFIC_LIGHT` (`Signal_Red_*`, `Signal_Amber_*`, `Signal_Green_*`, `SignText_A` / `SignText_B`), `STOP_SIGN`, `YIELD_SIGN`, `PED_SIGNAL`, `Door_<n>` empties (`AP.DOOR_SPOT_PREFIX`); fall back to the legacy GLBs when they are missing |

## Seams E provides to others (part of E's contract)

On `traffic_feature.gd`:

```gdscript
## Agents near p for the minimap and audio:
## [{"id": int (stable for the agent's life), "pos": Vector3, "vel": Vector3 (u/s), "speed": float (u/s),
##   "kind": "car"|"bus"|"truck"|"emergency"|"pedestrian", "driver_id": String, "heading": float,
##   "stalled_s": float (seconds below 0.1 * M speed)}]
func agents_near(p: Vector3, r: float) -> Array
## Visible named residents near p (on foot, in a car, or standing outdoors; never indoors): [{"id", "pos"}]. O(n).
func visible_near(p: Vector3, r: float) -> Array
func is_resident_visible(id: String) -> bool
## FpFeature.pick (S0 §10). Target kinds:
##   "resident"   a named resident on foot: id = resident id, label "Talk to Priya Gupta, nurse"
##   "vehicle"    a car, bus or truck: label "Priya Gupta, nurse" or "a commuter"; data {"driver_id","state","dest_label","mood"}
##   "pedestrian" an ambient, unnamed walker only: label "a pedestrian"
func pick(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary
## Optional, for A: boxes of stopped vehicles near p (world AABBs).
func blockers_near(p: Vector3, r: float) -> Array
## The traffic-light pole on cross tile i at corner (0..3 = NE, SE, SW, NW), or null. G1 mounts the
## street-name blades on the NE pole (H's SignText_A / SignText_B empties).
func light_pole(i: int, corner: int) -> Node3D
## Live anchor (world, head height) of resident id while E draws them: the speech bubble, and A's
## conversation two-shot (the NPC head). With HC bodies it is the Head bone's world position.
func anchor_of(id: String) -> Vector3
## CityLife.external hooks (deliverable 5).
func spawn_fleet(kind: String, start: Vector2i) -> void
func dispatch_crew(kind: String, station: Vector2i, target: Vector2i) -> void
func vehicle_counts() -> Dictionary
## Animated-people stats for G2's bench (stage E2): {"t0": int, "t1": int, "t2": int, "t3": int,
##   "anim_us": float (time in E's manual advance() round robin this frame), "char_draws": int}
func anim_stats() -> Dictionary
```

Existing APIs that must keep working, in orbit **and** in FP:

- `view.life.vehicle_counts()` returns the keys `buses`, `trucks`, `crews`, `boats` and `aircraft`. The orbit smoke and the photo tour print it at `main.gd:263` and `:391`.
- `view.avatars.visible_count()` returns `walking`, `driving`, `standing` and `total`.
- `view.avatars.pick(screen_pos) -> String`, `position_of(id) -> Vector3` and `select(id)` keep their signatures.

## Seams E may request

- F: a `Residents.trip_purpose(r) -> String` helper, or a purpose argument on `trip_started`. Until then, derive the purpose from `r.state`.
- F: car ownership (`r.car`). Until then, every resident whose commute is `car` owns one, and the model is picked by `hash(id)`.
- G1: a `parking` meta on lots (curb slot), plus lane-marking ground truth if road GLBs change. Cross-tile corners: E owns all four light corners and G1 mounts its blades on E's NE pole (`light_pole`); record the agreement in `docs/fp/requests/E-G1-corners.md`.
- H: `vehicles_v2` (plus single-material `<name>_lod1.glb`), the traffic-light GLB (5.5 m mast along local −X), stop and yield signs, pedestrian signals.
- HC: the character roster, bodies, far LODs and animation libraries (deliverable 9). Rigged people no longer come from H (D13).

## Deliverables

### 1. Lane graph (`lane_graph.gd`, pure data)

Build it from `sim.kind` and `RoadTopology`. Rebuild only a changed road tile and its 4 neighbours on `view.tile_built` / `view.tile_cleared` for road tiles (not on `sim.tiles_changed`: G1 defers road visuals in FP, and lanes must match what is drawn), skip those while `view.in_setup`, and do a full rebuild on `world_rebuilt`.

Each road tile has an **entry** and an **exit** node on every open edge, with the lane centre at `LANE_OFFSET` to the right of the travel direction. Heading north (−Z), right is +X.

| Piece | Lanes |
|---|---|
| Straight and bridge | 2 lanes |
| Corner | 2 arcs about the shared tile corner (§5 of S0), radius `CORNER_LANE_R_IN` for the inner turn and `CORNER_LANE_R_OUT` for the outer turn |
| Tee and cross | A movement from every entry to every other exit: straight, plus right and left turns as cubic Béziers. Each starts at the stop line (`STOP_LINE` from the centre) and ends at the exit edge. |
| End | A U-turn loop around the turning circle, outside the `END_ISLAND_R` island |

Further rules:

- Sample each lane as a polyline every `0.02 u`, and store its length in units.
- Speed limit: `CAR_RESIDENTIAL` when the majority of the zone tiles within 1 tile are R, otherwise `CAR_CITY`.
- A lane is blocked when its tile is in `sim.broken_roads` or under an active `car_crash` / `power_line` event.
- **Routing for resident trips: from `r.route`**, the sim's BFS tile path, which already exists. Walk it tile by tile, picking the entry and exit lane for each tile from the neighbouring tiles: O(route length), no search.
- **A\*** over lane nodes (costs: length / speed limit × (1 + 2 × `sim.traffic[tile]`)) only for ambient cars and crews, **at most 4 path builds per frame**; further requests wait in a queue.
- **Moving lane alongside parked cars.** Where a run has occupied parking slots, its lane centre shifts to `PASS_OFFSET` (0.12) for that run; `LANE_OFFSET` holds on runs with no parked cars. A sedan at `VEHICLE_SCALE` is 0.105 wide (`sedan_blue.glb` x ±0.063 × 0.833). Parked at `PARK_OFFSET` (0.245) it spans 0.1925–0.2975, so a moving car at 0.15 (outer edge 0.2025) would overlap it by 20 cm; at 0.12 the gap is 40 cm. (The old 0.23 slot overlapped by 0.5 m.)

### 2. Junctions (`junctions.gd`)

**Cross tiles (mask 15): 4-way traffic lights.**
- Phases are N–S green, then amber, then all-red, then E–W green, and so on.
- Durations in game-scaled real seconds: green 12, amber 3, all-red 1. Phases are offset per tile by `hash(i)`.
- Pedestrian walk phases follow the parallel green.
- Use the `AP.TRAFFIC_LIGHT` model at the 4 corners at `(±0.42, ±0.42)`, the mast along local −X reaching over the inbound lane (H builds a 5.5 m mast: from 0.42 a 2.5 m mast would end at 0.295, never over the lane at 0.15). Imported materials are shared between instances, so E swaps the lamps' on and off states with per-instance `material_override` from two shared materials per colour, never by editing the imported material. When the asset is missing, draw a small procedural pole with 3 emissive spheres.
- E owns all four corners of a cross tile. G1's street-name blades mount on E's NE pole (`light_pole(i, 0)`, H's `SignText_A` / `SignText_B` empties); G1 places no pole of its own on cross tiles.
- Pedestrian signals (`AP.PED_SIGNAL`) at both ends of each zebra, in `CURB_FURNITURE`.

**Tee tiles: priority rule.** The stem yields to the through road. The stem waits at the stop line until there is a gap of at least 3 s on the crossing lanes. E places a stop sign (`AP.STOP_SIGN`; `AP.YIELD_SIGN` where the stem is a residential street) on the stem's right-hand curb, in `CURB_FURNITURE`, at the stop line.

**Box reservation.** First in, first out. A car enters only if its exit lane has room for its length plus `s0`. This prevents gridlock.

### 3. Agents (`agents.gd`)

Use packed arrays, or one small Dictionary per agent pooled from a free list. Node instances are pooled too.

**Cars.**
- IDM with `v0` = lane limit (crews use `EMERGENCY_SPEED`), `T = 1.5 s`, `a = 1.0 * M`, `b = 2.0 * M` (m/s²), `s0 = 2.0 * M` and `δ = 4`.
- The leader is the next car on the lane, a red or yield stop line, or **the player** when they are within the forward corridor (lateral ≤ `ROAD_HALF / 2`, ahead ≤ braking distance + `2 * M`).
- Cars never pass through each other or through the player.

**Placement.**
- Wheels sit on `ASPHALT_TOP`. **Only when `view.fp_mode` is true**, drop the y = 0.05 float at `city_life.gd:241` and `resident_avatars.gd:269, 281, 291`, and apply `WS.PEOPLE_SCALE` instead of the 1.5 at `resident_avatars.gd:158`. Orbit keeps today's heights and scales (§5 and §7 forbid orbit changes).
- Yaw follows the lane tangent.
- Vehicles are scaled `WS.VEHICLE_SCALE` (legacy GLBs) or `VEHICLE_V2_SCALE` (H). People are scaled `WS.PEOPLE_SCALE` in FP.
- When wheel nodes exist (`AP.WHEEL_NODES`, or `AP.BIKE_WHEEL_NODES` on the bicycle), spin them at `v / wheel_radius`.
- **Draw calls.** Vehicles: full models only within 2 u of the player; beyond, one `MultiMeshInstance3D` per H `<name>_lod1.glb` model (single material, static wheels), filled each frame from the agent arrays. People follow the LOD tiers of deliverable 9 (HC bodies) or, before HC, the same 2 u rule with the legacy GLBs. With the legacy multi-material GLBs (sedan_blue 11 materials, person_a 5), 60 cars and 80 people would cost about 960 draws before shadows.

**Pedestrians.**
- They walk sidewalk polylines with centrelines inside `WS.PED_BAND` ([0.355, 0.405] from the road centreline) at `PED_WALK` (±15% per person), with feet on `SIDEWALK_TOP`. Lamps and signs stand in `CURB_FURNITURE` and shelters, racks and meters in `FRONT_FURNITURE`, so the band is clear except for the two small posts baked into lit straights at model-local (±0.4, ±0.2) (`roads.py:168-169`), which walkers sidestep.
- They cross only on zebra bands during their walk phase, or at tees when no car is within 2 s.
- They keep 0.6 m from each other (pushing apart on a spatial hash), sidestep the player, and play the walk and idle clips when rigged (HC bodies, deliverable 9).

**Time.**
- Agent motion uses `delta * float(ctx.sim.speed)`, sub-stepped to a maximum of 1/30 s per step, so fast-forward looks fast-forwarded. In FP `time_scale == sim.speed` (D-S0-1), but `grow_offline` sets `sim.speed` to 16 directly and the photo tour holds speed 0, and `ctx.mode` is a stub in unit tests; `sim.speed` is right in all three.
- Every duration in this spec (light phases, waits, jitter, dwell) is **real seconds at 1×**, multiplied out by `sim.speed`. There is no other "game-second".
- Paused means frozen, because the feature is pausable.
- FP code uses its own `RandomNumberGenerator` seeded from `sim.city_seed` (CityLife uses the global `randi()` / `randf()` today, `city_life.gd:195, 225, 287-288`).

### 4. Resident trips (the AI link)

Sim arrival is instant (`r.at = to`). E plays the trip visually, lagging the sim by its real duration. When `trip_started(id, from_i, to_i, mode)` arrives:

| Mode | What happens |
|---|---|
| `car` | Spawn, or reuse, that resident's car parked at the curb slot of `directory.frontage(from_i)`. The person walks from the lot door (H's `Door_<n>` empty when present) to the car, then drives the lane path built from `r.route` to `frontage(to_i)` and parks at the curb slot (`WS.PARK_OFFSET` from the road centre, along the run, with slot spacing `6.0 * M`). Then the person walks to the door and hides inside if the state is an "inside" state (`ResidentAvatars.INSIDE`). The car **stays parked** until that resident's next car trip. |
| `bus` | Walk to the nearest `view.bus_stops` tile on the route. Wait up to 90 s (real seconds at 1×) for a bus on a line that serves a stop within 3 tiles of the destination; board, ride and get off there, then walk. Otherwise walk the whole way. In FP the buses run **seeded closed lines** through at least 2 `bus_stops` (deliverable 5), not today's random wander (`city_life.gd:216-227`). |
| `bike` | A pedestrian at `4.0 * M`, on the carriageway edge (lateral `ROAD_HALF − 0.04`). H may later provide a bike model (`AP.BICYCLE`). |
| `walk` | Sidewalks and zebras the whole way. Any mode outside these four arrives as `"walk"` (S0 normalises it). |

Scale rules (D11 forbids stalls over 50 ms; residents depart in a burst every morning, up to 100 in one tick, `residents.gd:16, 386-411`):

- **Spawn trips only from `trip_started`.** The forwarded `_on_moved` (deliverable 7) only updates the resident's state and route; it never spawns a second agent for the same move.
- **Beyond `TRAFFIC_RADIUS`** of the player a trip is data only: position comes from elapsed time along its lane path, with no node and no IDM. It becomes an agent when it enters the radius.
- **Parked cars** are instantiated only within `VIS_CAR` of the player; beyond that they are entries in the parked table.
- **While `sim.day_seconds < WS.FP_DAY_SECONDS`** (`grow_offline` and tests at 12 s days, a morning every 0.75 s at 16×) skip visual trips entirely and only update the parked table.
- **Departure jitter** 0–6 s (real, at 1×), seeded by `hash(id, day)`; a test hook `jitter_enabled := true` turns it off.

Edge cases:

- A new trip for a resident who is still en route first **completes the current trip instantly**: the agent jumps to the destination parking spot or door.
- `position_of(id)` returns the live agent position while en route.
- `conversation_changed(id, true)` stops that resident's agent (a car pulls over or a pedestrian halts), and it turns to face the player until the conversation ends.
- `_check_home` moves a resident by setting `r.at` without `_go` (`residents.gd:913-914`), so no trip fires and their car can be stranded at the old home. On `sim.day_started`, reconcile the parked table with `r.home` / `r.work`: move or drop cars whose owner no longer lives or works next to them.

### 5. Fleets (`city_life.gd`)

- Add `var external: Object = null` to CityLife. When it is set, CityLife forwards fleet maintenance and crew dispatch to `external.spawn_fleet(kind, start)` and `external.dispatch_crew(kind, station, target)`, its own road agents stay idle, and `vehicle_counts()` asks `external` (same 5 keys). Boats and aircraft stay in CityLife.
- CityLife is recreated inside every `view.setup()` (`city_view.gd:156-168`), and its `setup()` already dispatches crews for existing events (`city_life.gd:66-67`) before `world_rebuilt`, so before E can attach. E therefore sets `view.life.external` (and `view.avatars.external`, deliverable 7) in **every** `on_world_rebuilt()`, then re-dispatches crews for every event in `sim.events`; it clears both fields in `teardown()`.
- Buses, trucks, garbage trucks and crews move on the lane graph in FP. Buses run 2–4 **seeded closed lines** (RNG from `sim.city_seed`), each a loop through at least 2 `bus_stops`, rebuilt on `world_rebuilt` and when stops change.
- Crews run red lights at reduced speed with sirens, and park at the curb nearest the event.
- Drivers are named after residents with matching jobs (`bus driver`, `truck driver`, `sanitation worker`, `firefighter`, `paramedic`, `police officer`, from `residents.gd:38-45`) when such residents are free. Otherwise the label is "city crew".
- Boats and aircraft keep their current motion. Centre the plane loop on the airport if one exists.
- **In orbit, CityLife keeps today's behaviour** (`external == null`). Gate the new code on `view.fp_mode`.

### 6. Ambient filler

- Only within `TRAFFIC_RADIUS` of the player.
- Density per road tile comes from `sim.traffic[i]` and `residents.trip_load[i]`, with caps of 40 cars and 60 pedestrians.
- Spawn and despawn only outside a 6 u radius **and** behind the player (dot product < 0), or at map edges. Never pop agents in view.
- **First fill is synchronous.** `on_world_rebuilt()` and `from_dict()` fill ambient traffic at once (anywhere outside the view frustum on that first fill), with a floor of 2 cars and 2 pedestrians when roads exist, so the FP smoke's `self_test` right after a load finds agents (S0 §17.4 steps 11–12; in-flight agents are dropped on load).
- Ambient agents are labelled "a commuter", "a cyclist" or "a pedestrian". Never claim a name for them.

### 7. ResidentAvatars in FP

- Hide the selection ring and the `no_depth_test` name tag (`resident_avatars.gd:97-115`).
- Speech bubbles are depth-tested. Show them only within `1.5` u (30 m), at `pixel_size 0.0006` and placed `0.12` above the head.
- Bubbles are optional, because C mirrors every line into chat.
- Delegate to the traffic feature through a field `var external: Object = null`. While it is set:
  - `_on_moved` forwards to it (state update only; E spawns from `trip_started`);
  - `_process` (`resident_avatars.gd:217+`) skips `_advance`, `_idle` and every `root.visible` toggle, and hides every avatar root, so residents are not drawn twice;
  - the speech bubble (today a child of the hidden root, `:137`) is moved to a separate bubble node under ResidentAvatars that follows `external.anchor_of(id)`;
  - `pick` (`:327`), `visible_count` (`:350`) and `position_of` ask `external` (same signatures and keys).
- E sets `external` in every `on_world_rebuilt()` (a new ResidentAvatars is created by each `view.setup()`, `city_view.gd:169-173`) and clears it in `teardown()`.
- With no FpMode (orbit), the legacy behaviour is exactly unchanged.

### 8. Save (`traffic_feature.to_dict`)

- `{"parked": {resident_id: [tile, slot]}}` (cast both back to int on load).
- Agents in flight are not saved. On load, residents appear at their `r.at` (inside or parked), and ambient traffic is filled synchronously (deliverable 6).

### 9. Animated people from HC's roster (D13; TPS_PLAN §1.10–1.11)

**Placeholder, then wire.** Stage E1 (this branch) builds everything above with the legacy static people (`AP.PEOPLE_LEGACY_DIR`, scaled `WS.PEOPLE_SCALE` in FP) and merges without `models/characters/**`. Stage E2 (TPS_PLAN T8, a follow-up branch `fp/E2-people` after HC3 merges) swaps in HC's bodies, libraries and the LOD tiers below. Every code path keeps the legacy fallback when `AP.CHAR_ROSTER` is missing.

**Assignment** (HC supplies the data, E applies it):
- **Gender:** `roster.json`'s `name_gender[first_name]`; names it omits (Quinn, Sami, Wren, …) fall back to `crc32(id) & 1`.
- **Body:** the pool for the resident's `job_title` (HC's job pools) intersected with that gender; if empty, the casual pool for the gender. Index by `crc32(resident_id) % n`, so a resident looks the same in every run and after save/load. Never the two hero avatars.
- **Height:** `CharacterRoot.scale = WS.M * (h_target / rest_height_m)`, with `h_target` = 1.75 m × (1.00 male | 0.95 female) × a jitter in [0.97, 1.03] from `crc32(resident_id)` (1.61–1.80 m). Never scale the skeleton itself. This replaces `WS.PEOPLE_SCALE` for HC bodies.
- **Library:** the gender's `AP.CHAR_LIB_M` / `AP.CHAR_LIB_F` as the default library `""`, `root_motion_track = %GeneralSkeleton:Root` (clips play in place; E owns displacement).
- **Playback rate:** `speed_scale = v / (speed_mps × h_target / 1.75)` from the clip's `speed_mps` meta, so feet do not slide.

**Ambient pedestrian variety** (reusing the 38 resident bodies):
- body mix 60 % casual, 25 % business, 15 % uniforms (police, medical, trades), seeded per agent from `sim.city_seed`;
- the height jitter above;
- walking speed U(1.15, 1.50) m/s with the playback rate matched to it;
- an idle variant (`idle`, `idle_look`, `idle_wait`) and a random phase offset per agent;
- 10 % carry (`carry` while walking), 8 % phone (`phone` while walking or `phone_idle` standing), 5 % stop to talk in pairs (`talk` / `talk_2` facing each other, 10–40 s, at a sidewalk spot outside `PED_BAND`'s flow, then resume).
- Named residents on foot use the same rules with their own job body.

**LOD tiers** for animated people (10 % hysteresis on each boundary):

| Tier | Distance, cap | Node | Update rate | Shadows |
|---|---|---|---|---|
| T0 | ≤ 12 m, max 8 | Body GLB + `AnimationTree` (StateMachine, crossfades); `LookAtModifier3D` allowed for at most 6 NPCs (the conversation partner looks at the player) | every frame | on |
| T1 | 12–30 m, max 40 | Body GLB + `AnimationPlayer`, `callback_mode_process = MANUAL`, `advance(acc)` round robin, `play(name, 0.25)` crossfades, `speed_scale = v / speed_mps` | 30 Hz to 20 m, 15 Hz to 30 m | to 20 m |
| T2 | 30–60 m | Same as T1 | 10 Hz | off |
| T3 | 60–80 m (`VIS_PERSON`) | `<Name>_lod1.glb` in one `MultiMeshInstance3D` per avatar (2 surfaces) | static pose | off |

- **Off screen:** `active = false` and no `advance()` (frustum test against `ctx.player.camera`, which is the third-person camera when that is active).
- **Pools:** body instances are pooled per avatar name and re-skinned to a new agent on reuse (reset the mixer, set the library once); never instantiate in a burst of more than 4 bodies per frame.
- **Budget:** ≤ **1.5 ms per frame** of animation CPU (`anim_stats().anim_us` plus the T0 AnimationTree time) and ≤ **150 character draws** (T0 + T1 ≈ 48 bodies × 3 surfaces, shadows extra), inside the 500 agent draws of the performance budget below.
- **Benchmark caveat.** The micro-benchmark gave about 28 µs per AnimationPlayer update and about 50 µs per AnimationTree update on a 17-bone rig with the machine at load 40+. G2 re-measures with Rocketbox's 52 mapped tracks in `fp_bench` (release build, `low_processor_mode_sleep_usec = 0`); lower the T1 cap and rates if the budget is exceeded.
- **v2:** a bone-texture baked MultiMesh for T2 and T3 (built in Godot at load).

## Acceptance tests

`tools/tests/fp_traffic_test.gd`, token `FP_TRAFFIC_TEST: PASS`. It uses `fp_kit.make_ctx(root, {"view": true, "grow": true})` (the kit's headless player is `ctx.player`) and `make_feature(ctx, "traffic")`. Time is driven with `feature.step(dt)` (a test hook) at 1/30 s, with `sim.speed == 1`. Before the trip tests it sets `sim.day_seconds = WS.FP_DAY_SECONDS` (visual trips are skipped at 12 s days) and `feature.jitter_enabled = false`.

**Fixtures first.** Assert that the grown city has at least one corner (mask 3, 6, 9 or 12), one tee, one cross, one `view.bus_stops` entry and one resident at home with `work >= 0` (S0 §17.2). FAIL, never pass vacuously, if one is missing.

**Lane graph.**
- Every road tile in `sim.active` has at least one lane per open arm.
- Lane endpoints on a shared tile edge coincide (ε 1e-5).
- On a mask-5 tile with no parked cars, the lane heading −Z sits at x = tile x + `LANE_OFFSET` (right-hand); with a parked car on that run, at `PASS_OFFSET`.
- Corner lane polylines stay within ε 0.005 of radius 0.35 or 0.65 about the corner (the fixture corner at (4,12)).
- Every lane polyline stays on the carriageway (`RoadTopology.is_carriageway`), including the end-tile U-turn outside the island.
- Bulldozing a road tile and emitting `view.tile_cleared` updates the graph; `sim.tiles_changed` alone does not.

**Car following.** Put two cars on a 10-tile straight route and stop the leader. The follower stops with a gap of at least `s0 * 0.9`, and no overlap occurs over 30 s.

**Parking clearance.** Over 60 s with cars parked along a run and through traffic on it, no moving car's AABB ever overlaps a parked car's AABB.

**Lights.** On a cross tile, a car arriving on red stops with its front between `STOP_LINE` and `STOP_LINE + 0.03` from the centre, then proceeds on green. Lamp states are per-instance `material_override`s; the imported material is unchanged.

**Tee yield.** A stem car waits while a through car is within 2 s. The stem has a stop or yield sign in `CURB_FURNITURE`.

**Resident driver.**
- Set `plan.commute = "car"` on the fixture resident and force a morning (`sim.step_tick()` with `tick_in_day == 0`).
- Within 1 frame, an agent exists with `driver_id == id`; exactly one, even though `_on_moved` is also forwarded.
- With jitter disabled it parks at its destination frontage within `(route_tiles * 20 / 13.9) * 1.6 + 15` simulated seconds.
- `view.avatars.position_of(id)` stays within 0.05 of the agent's root while en route, and the legacy avatar root stays hidden (no double draw).
- `pick()` along a ray into that resident on foot returns kind `resident` with `id == id`; into an ambient walker, kind `pedestrian`; into the car, kind `vehicle` with `data.driver_id == id`.
- `visible_near(p, r)` never contains a resident whose state is indoors.

**Walker.**
- A walk-mode trip keeps every sample on sidewalks (`!is_carriageway`), except on zebra bands while crossing, and every sidewalk sample's lateral offset inside `PED_BAND`.
- Feet are at `SIDEWALK_TOP ± 0.002` on sidewalk samples only (zebras are at `ASPHALT_TOP`; lot endpoints differ).
- A resident with `plan.commute = "stay_home"` sent to a park more than 6 tiles away arrives as a `walk` trip.

**Player yield.**
- With the player in a lane 1.0 u ahead of a car at `CAR_CITY`, the car stops with its AABB at least `PLAYER_RADIUS + 1.5 * M` from the player.
- No car's AABB (not its origin) ever comes within `PLAYER_RADIUS` of the player.

**Conversation.** `conversation_changed(id, true)` stops the agent within 2 s, it turns to face the player, and `anchor_of(id)` stays within `0.1 * M` of its head while it stands.

**People (stage E2; skipped with a printed note while `AP.CHAR_ROSTER` is missing).**
- The same resident id gets the same body in two fresh runs and after `to_dict` → `from_dict`; no resident or ambient walker uses a hero avatar; a nurse resident's body is from the medical pool (or casual when the pool is empty for that gender).
- Every HC body's world AABB height is 0.080–0.090 u (1.61–1.80 m).
- With 80 walkers spread over 0–80 m, the tier counts respect the caps (T0 ≤ 8, T1 ≤ 40), T3 bodies are MultiMesh instances, off-screen mixers are inactive, and `anim_stats().char_draws ≤ 150`.
- A walker at 1.30 m/s has `speed_scale` within 2 % of `1.30 / (speed_mps × h_target / 1.75)`.

**Fleets.** After `on_world_rebuilt`, `view.life.external` and `view.avatars.external` are the feature; a second `view.setup()` followed by `world_rebuilt` re-attaches them to the new instances; `teardown()` clears them. An event present before the rebuild gets a crew dispatched through E.

**API compatibility.**
- `vehicle_counts()` has exactly the 5 legacy keys and `visible_count()` the 4.
- `pick(Vector2)` returns a String.
- In a CityView without FpMode (orbit), `_on_moved` still sets `a["speed"]` from `sim.tick_seconds()` as before, and avatar y and scale are unchanged.

**Save.** Parked cars survive `to_dict` → JSON → `from_dict`. Right after `from_dict`, with no frame in between, at least 2 cars and 2 pedestrians exist when roads exist.

**FP smoke and photo tour.**
- FP smoke: `self_test()` passes when the lane graph is non-empty and at least 1 car (moving, ambient or parked) and at least 1 pedestrian agent exist within `TRAFFIC_RADIUS` of the player. It runs after the post-load fill, so it never depends on frames having passed.
- Photo tour: `street` and `intersection` show cars in the correct lanes and pedestrians on sidewalks. Add a `photo_shots()` entry `"traffic"`: a cross tile with lights, from a corner at 1.65 m. The orbit smoke still prints `life=` and `avatars=` lines.

## Performance budget

- At most **2.5 ms per frame** of GDScript with 60 cars and 80 pedestrians active within `TRAFFIC_RADIUS`.
- At most 0.5 ms for an incremental lane graph rebuild per changed tile. A full rebuild of 600 road tiles takes at most 60 ms, once.
- Agent draw calls: at most **500**, counted inside G2's 2,000 total, of which animated people at most **150**. Vehicles: full models within 2 u only; beyond, one MultiMesh per `lod1` model (§3). People: the tiers of deliverable 9.
- Animated people (stage E2): at most **1.5 ms per frame** of animation CPU. Shared materials and pooled instances, with `visibility_range_end` (`VIS_CAR` for cars, `VIS_PERSON` for people) and no shadows beyond 3 u. Until H's `lod1` files exist, cap full-detail agents at 40 and report the draw count in the hand-off.
- Routing: resident trips cost O(route length); at most 4 A\* builds per frame for ambient cars and crews. A morning burst of 100 trips at 16× stays under 5 ms per frame.
- No physics nodes.

## Risks

- **Trip lag.** Visual trips lag sim arrivals. The sim can count a resident at work before the car parks. That is accepted; never feed visual state back into the sim.
- **Bursty departures.** Up to 100 departures fire on one tick. Stagger them with the 0–6 s departure jitter (real seconds at 1×) seeded by `hash(id, day)`, keep far trips as data, and skip visual trips at short days (§4). F may also spread `_go` calls in sliced mode.
- **Removed roads.** Roads removed under a car must reroute or despawn the car behind the player, never in view.
- **Physical speeds.** Real speeds at 8× time scale look fast. That is intended: fast-forward.

## Do NOT touch

- `scripts/sim/*` (request F), `city_view.gd` (its ambient traffic is off in FP; leave the code for orbit), `main.gd`, `project.godot`, S0 files and other slices' directories.
