# Slice A: Player and interaction

Branch `fp/A-player`, in its own worktree, branched from `fp/integration` after S0 has merged. Read `docs/fp/ARCHITECTURE.md` first, then `docs/fp/S0-foundation.md` §§7–12.

## Goal (what the player sees)

Walking GridFall feels like a real first-person game at human scale:

- You can walk, run, crouch and jump.
- You step up onto 12 cm curbs smoothly, but cannot climb a 40 cm ledge.
- Buildings, lamp posts, hydrants, benches, trees and parked cars stop you. You cannot walk into the river.
- An optional, subtle head bob can be switched off.
- Look at a resident, building, poster or car within reach and a prompt appears. Press E and something happens:
  - a resident: you talk (C)
  - a building: a place card (B)
  - a poster: the poster opens full-screen (D)
  - a car: the driver card (B)
- P toggles a free-fly photo mode with the HUD hidden.

## Owned files (exclusive)

- `scripts/fp/player/**`. This includes S0's `player.gd`; keep `class_name FpPlayer` and every public member listed in S0 §11.
- `scripts/fp/world/collision_world.gd`. Keep `class_name CollisionWorld` and every S0 §12 signature.
- `scripts/fp/interact/**` (entry point `interact_feature.gd`, id `interact`).
- `tools/tests/fp_player_test.gd`.

## Seams consumed

| From | API |
|---|---|
| S0 `WS` | `EYE`, `CROUCH_EYE`, `PLAYER_RADIUS`, `PLAYER_HEIGHT`, `CROUCH_HEIGHT`, `WALK`, `RUN`, `CROUCH_WALK`, `ACCEL`, `GRAVITY`, `JUMP_SPEED`, `STEP_HEIGHT`, `PITCH_LIMIT_DEG`, `PHOTO_FLY_SPEED`, `TALK_RANGE`, `INTERACT_RANGE`, `CAMERA_*`, `ASPHALT_TOP`, `SIDEWALK_TOP`, `CURB_RISE`, `GROUND_Y`, `LOT_TOP`, `PAD_TOP` |
| S0 `RoadTopology` | `surface_height`, `is_carriageway`, `is_bridge`, `mask` |
| `CityView` (S0 seam) | `building_aabb(i)` (picking only), `site_boxes(i)` (site collision), `tile_holder(i)` (meta `building_path`, `building_xform`, `colliders`; the holder's `Site` child carries the kit's own `colliders`), `in_setup`, `tile_built` / `tile_cleared` / `world_rebuilt`, `bus_stops`. `avatars` only as the last-resort resident source (below). |
| `FpContext` | `bus`, `collision`, `player`, `hud`, `directory`, `features`, `settings`, `is_modal()`, `push_modal()` / `pop_modal()`, `world_root` |
| `GameBus` | emits `interact_target_changed`, `interact_requested`, `talk_requested`, `player_tile_changed`; listens to `settings_changed` (fov, sensitivity, `invert_y`, `head_bob`), `modal_changed`, `conversation_changed` |
| `FpFeature.pick(origin, dir, max_dist)` | queried on every registered feature: E answers for named residents on foot (kind `resident`), vehicles and ambient pedestrians; D for posters |
| E's traffic feature (optional) | `visible_near(p, r) -> Array[{"id", "pos"}]` (visible named residents only), `is_resident_visible(id)`, `blockers_near(p, r)` |
| `CityDirectory` | `place_label`, `business_name`, `address`, `landmark_name` (labels for building targets) |
| `Residents` | `find(id)` for name and job (resident labels) |
| `FpHud` | `set_hud_visible()` (photo mode) |

## Seams A may request

Write requests to `docs/fp/requests/A-needs.md`:

- G1 (contract already in G1's spec): every furniture placement, batched into a MultiMesh or not, is also written to `holder.set_meta("colliders", [{"shape": "cyl"|"box", "pos": Vector3 (holder-local), "r": float | "size": Vector3, "yaw": float}])` **before** `tile_built` fires. When a holder has that meta, A reads only the meta for that holder's props. Until G1 lands, A scans the holder itself (deliverable 2).
- H: `ColBox_<n>` empties in building GLBs (position = box centre, scale = half extents, no mesh, no suffix; `AP.COLBOX_PREFIX`). When present they replace A's per-surface bodies for that model. Never `-colonly` meshes: the importer would turn them into physics bodies (D2).
- E: `visible_near(p, r)` and `is_resident_visible(id)` on the traffic feature (resident positions without the indoor and unknown-id errors of `ResidentAvatars.position_of`).
- S0 owner: gamepad events for `move_*`, `jump`, `interact`, `sprint`. This is a `project.godot` `[input]` edit.

## Deliverables

1. **Controller** (`player.gd` and helpers under `scripts/fp/player/`):
   - Keep S0's signature `simulate(wish, sprint, delta, crouch := false, jump := false)`; `simulate` itself zeroes `wish` and `jump` while `ctx.is_modal()` (gravity and ground snap still run). `_process` polls only the held state (`move_*`, `sprint`, `crouch`, `jump`) and passes it in.
   - **Keep S0's long-frame guard.** `_process` passes `minf(delta, MAX_FRAME_DELTA)` (0.1 s), and `simulate` sub-steps so that no collision step moves farther than `PLAYER_RADIUS`, whatever `delta` it is given; a velocity component whose move was blocked drops to zero. Sim tick stalls make 0.7–2.7 s frames in real FP play, and pressing T runs 1–4 ticks in one frame; without the guard one such frame at `RUN` steps straight through a 0.008 u hoarding (0.038 u once grown by the radius). Jump and gravity sub-step the same way.
   - Kinematic movement with acceleration and friction.
   - Sprint (`RUN`) and crouch (`CROUCH_EYE`, `CROUCH_WALK`; you cannot stand up under a ceiling box).
   - Jump with `JUMP_SPEED` and `GRAVITY`, with coyote time of 0.1 s.
   - Step-up of up to `STEP_HEIGHT`, so the curb works but the 0.021 u grass-to-sidewalk ledge does not, unless G1 has raised the ground. The camera y lerps after a step.
   - **Interim soft step** (until G1 changes `WS.GROUND_Y`): at **any** tile edge whose lower side is at `GROUND_Y`, allow a soft step of up to `0.03 u` as a ramp over the outer 0.05 u of the higher tile. Lots and pads to grass are 0.016–0.018 and rubble has no box, so restricting the ramp to sidewalks would trap a player who drops onto an interior grass tile. Remove the rule in the commit that follows G1's `GROUND_Y` change.
   - Head bob, with an amplitude of `0.03 * M` vertical and `0.015 * M` lateral, scaled by speed. It is on when `settings.head_bob` is set.
   - FOV from settings. Sprint widens the FOV by 4° (also tied to `head_bob`, for comfort).
   - Footstep events: emit a local signal `stepped(surface: String, pos: Vector3)` on `FpPlayer`, which I (audio) connects to. The surface comes from `CollisionWorld.surface_at`.
2. **CollisionWorld** (same file, same API including S0's `boxes(i)`, new internals):
   - **Building bodies (movement only).** The whole-model AABB cannot be split into slab and body: per-surface measurements show the geometry above the slab fills the lot (house_bungalow above-slab x[−0.371, 0.470] z[−0.470, 0.470] while its Brick/Siding walls span only x[−0.223, 0.323] z[−0.223, 0.170]; city_hall ±0.47 above the slab but glass at ±0.392; park.glb ±0.47 from trees). Instead, once per unique `building_path`:
     1. read every surface's vertex AABB with `mesh.surface_get_arrays(s)` across the model's MeshInstance3Ds (a probe: 1.3 ms per model; the material names Grass, Sidewalk, Brick_Red… are available);
     2. drop ground surfaces (top ≤ `LOT_TOP + 0.002`);
     3. drop small low surfaces (xz area < (0.6 m)² **and** height < `STEP_HEIGHT`);
     4. merge what is left into at most 4 boxes (greedy merge of the closest pair by added volume);
     5. cache the local boxes per path; per tile, transform by the holder transform × `building_xform` meta.
     `boxes(i)` returns those; `box(i)` their merged bound. When the model has `ColBox_<n>` empties (H), use them instead. Tree surfaces (`Leaves*`, `Bark*`, `Hedge*` and the `*_foliage` node) are excluded from the bodies, so parks and gardens stay walkable; trunks are optional cylinders (r = `0.25 * M`) at the xz centres of connected `Bark*` vertex clusters, when A can isolate them cheaply (the foliage of a model is one merged mesh).
   - **Picking.** `raycast` for building targets uses the full `view.building_aabb(i)`, never the bodies, so a set-back house (body 0.447 u = 9 m behind the frontage sidewalk, beyond `INTERACT_RANGE`) still yields its place card from the sidewalk.
   - **Construction sites.** Every box of `view.site_boxes(i)` on a tile with a drawn site (the kit's `colliders` meta on the `Site` node: hoarding segments with the gate gap, machines over their shuttle run and animation poses, the crane's base and mast, the floodlight pole, slabs, berms, mounds, frame, scaffold, the old or finished building). Keep them as separate boxes (or as yawed boxes from the meta itself, `ConstructionKit.collider_aabb`); never merge them into `view.site_bounds(i)`, which also covers the gate. Parts can reach up to 0.2 u into a neighbouring tile (the crane base), so query them from the 3×3 neighbourhood as S0 does.
   - **Props.** Prop cylinders (lamp r = `0.15 * M`, hydrant, bin, bench box, tree trunk r = `0.25 * M`, bus shelter box) and bridge parapets. Sources, in order:
     1. the holder's `colliders` meta (G1), when present: use only it;
     2. lit-road lamps: they are baked into `road_straight_lights.glb` (`roads.py:166-167`, poles at x = ±0.34; bridges `roads.py:303-304`, poles at ±0.36), and `city_view.gd:905` picks the lit straights. For each `Bulb_*` node under a road holder, add a cylinder of r = `0.008` at the bulb's xz pushed `0.08 u` outward (away from the road centreline) along the sign of the bulb's model-local x (the arm reaches 0.08 toward the road, `roads.py:138-139`; for example `Bulb_0` at (−0.26, 0.44, 0.25) gives a pole at (−0.34, 0.25)). Also add the two small posts of lit straights at model-local (−0.4, −0.2) and (0.4, 0.2) in Godot xz (Blender y is flipped), r = `0.0035` (`roads.py:168-169`), rotated with the road piece;
     3. bus stops: `scene_file_path` equal to `res://models/props/bus_stop.glb` (the one `_maybe_bus_stop` uses today, `city_view.gd:1242`), `res://models/real/props/bus_stop.glb` or `AP.BUS_SHELTER` → a box of the model's AABB; the procedural shelter (a holder child with an empty `scene_file_path` at offset 0.43) → a 0.34 × 0.20 box;
     4. other props: `scene_file_path` under `res://models/real/props/` or `res://models/props/` → radius-limited cylinders;
     5. `road_end` tiles: the tree trunk at the island centre (`END_ISLAND_R` island is walkable at `SIDEWALK_TOP`).
   - Water: not walkable, and the edge is blocked.
   - Proper circle-vs-box sliding, so the player slides along walls rather than stopping dead.
   - `raycast` returns the nearest hit across buildings, props and ground.
   - Colliders refresh on `tile_built` / `tile_cleared`, lazily on first query.
   - Moving agents: query E's feature through `pick`. Collision against moving cars is E's responsibility (cars brake for the player). A only stops the player walking *into* a stopped vehicle box, if E exposes `blockers_near(p, r) -> Array[AABB]`. Request it; if it is absent, skip it.
3. **Interact feature** (`scripts/fp/interact/interact_feature.gd`):
   - Every `0.1 s`, cast from `player.eye_position()` along the camera forward.
   - Candidates:
     - every feature's `pick()`. E returns kind `resident` for a named resident on foot;
     - residents A finds itself, **only when no `traffic` feature with `visible_near` exists**: within `TALK_RANGE` and inside an 8° cone of the screen centre, with line of sight checked by `collision.raycast`. Positions come from E's `visible_near(p, TALK_RANGE)` when present; otherwise from **one pass over `residents.people`** that skips residents with an empty `route` whose `state` is indoors (`ResidentAvatars.INSIDE`, or a state beginning with `"visiting"`, the rule at `resident_avatars.gd:13,204`) and reads the avatar root position only for the rest. Never call `position_of` for a hidden or unknown id: it returns the home or work tile centre for hidden residents and (15.5, 0, 15.5) for unknown ids (`resident_avatars.gd:313-324`), and each hidden lookup is a linear `people.find` (a 100-resident scan cost ≥ 0.5 ms in a probe, over this 0.2 ms budget);
     - buildings, from `collision.raycast` against the full `view.building_aabb(i)` within `INTERACT_RANGE`.
   - **Normalise:** a target of kind `pedestrian` or `vehicle` is left alone, except that a `pedestrian` with a non-empty `data.driver_id` is rewritten to `{"kind": "resident", "id": driver_id, "label": "Talk to <Name>, <job>"}` (defensive; E already returns `resident` for them). Drop A's own resident candidate when a feature already returned that id.
   - Choose the nearest. Emit `interact_target_changed(target)` only when the target changes (by kind and id).
   - **Hide the prompt** under UIs: on `modal_changed(true)` and on entering photo mode emit `interact_target_changed({})`; on `modal_changed(false)` and on leaving photo mode re-evaluate at once.
   - **Input** (S0 §7.2, D-S0-17): `interact` fires only from `_unhandled_input` on `event.is_action_pressed("interact") and not event.is_echo()`, never by polling. Ignore it while `ctx.is_modal()`, in photo mode, and **during the frame in which `modal_changed(false)` fired** (record `Engine.get_process_frames()`), because the card or viewer that just closed on E consumed the same key press.
   - On `interact` with a valid target: emit `interact_requested(target)`, and also `talk_requested(id)` when the kind is `resident`.
   - Labels:
     - resident: `"Talk to <Name>, <job>"`
     - building: `"<place_label>"`, for example `"Maple Street Bakery"`
     - vehicle and pedestrian: from E's target label
     - poster: from D
4. **Photo mode** (`photo_mode` action, P, from `_unhandled_input`):
   - Free-fly with no collision at `PHOTO_FLY_SPEED`. Down is `crouch` (Ctrl) and up is `jump` (Space); Q and C are unbound and E is `interact`.
   - In photo mode A ignores `interact`; FpMode ignores `hud_toggle` (F1) and C ignores `chat_open`. A sets S0's `FpPlayer.photo_mode` flag, which they read.
   - Hides the HUD (`hud.set_hud_visible(false)`) and pushes no modal, so the mouse stays captured.
   - The player position is saved on entry and restored on exit.
   - The sim keeps running.
5. **Save.** `FpPlayer.to_dict()` / `from_dict()` keep the S0 shape and add `crouched` and `photo` (false on load).

## Acceptance tests

`tools/tests/fp_player_test.gd`, token `FP_PLAYER_TEST: PASS`. It uses `fp_kit.make_ctx(root, {"view": true, "grow": true})` (the kit's player is a headless `FpPlayer`). Its assertions:

- **Speeds.** Walking 3 s from rest along a straight sidewalk covers `WALK*3 ± 10%` (after the ramp); running covers `RUN*3 ± 10%`; crouch-walk covers `CROUCH_WALK*3 ± 10%`. The crouched eye is at `CROUCH_EYE ± 1e-4` above the ground.
- **Curb.** Moving from the carriageway centre perpendicular onto the sidewalk ends with feet at `SIDEWALK_TOP ± 1e-4`, so a 12 cm step succeeds. A scripted 0.02 u ledge, built through a test-only `CollisionWorld.add_test_box()`, blocks the move.
- **Jump.** The apex is between `0.5 * M` and `0.7 * M` above the take-off ground, and the player lands within 1 s.
- **Walls.** Walking into every building tile within 3 tiles of City Hall for 4 s each never puts the feet inside any `collision.boxes(i)` grown by `PLAYER_RADIUS * 0.99`. A diagonal walk along a wall keeps at least 50% of the tangential speed (sliding).
- **Bodies.** For every zone tile at level > 0, each body box lies inside `view.building_aabb(i)` and there are at most 4. A park tile (or any lot whose above-slab geometry is only trees) is walkable across its centre. From the frontage sidewalk point of every building lot, a forward ray hits that building within `INTERACT_RANGE` (place cards stay reachable for set-back houses).
- **Sites.** On staged build sites, walking at a hoarding side without the gate stops at the hoarding (`0.474 + PLAYER_RADIUS` from the centre, ± 0.02); a single `simulate(Vector2(0, 1), true, 0.7)` (and 2.72) pressed against the hoarding, and a 2.72 s step from a standing start 0.66 u out, never end inside a box or past the hoarding (S0's `fp_core_test` keeps the same case); walking into any site, through the gate included, never puts the feet inside any box of `view.site_boxes(j)` grown by `PLAYER_RADIUS * 0.99`; and every drawn part under the `Site` node that is ≥ `STEP_HEIGHT` tall and starts below `PLAYER_HEIGHT` (outside `Boom` arms and the progress groups) lies inside one of `collision.boxes(i)`.
- **Soft step.** From the centre of an empty grass tile (`GROUND_Y`) next to a lot, the player can walk onto the lot and back; no tile edge with a `GROUND_Y` lower side traps the player.
- **Water.** Walking toward a water tile stops at the edge: `ground_height` stays finite and the feet never end up over a water tile.
- **Props.** On a lit straight road tile, the pole derived from `Bulb_0` blocks the player (the feet never come within `PLAYER_RADIUS + 0.008` of it). A bus-stop tile from `view.bus_stops` blocks at the shelter. A holder with a test-injected `colliders` meta uses only that meta.
- **Interact.** Facing a building within `INTERACT_RANGE` produces exactly one `interact_target_changed` with kind `building` and a non-empty label. A fake resident, injected through a stub feature's `pick()` at 2 m, wins over a building 5 m away. A stub `pick()` returning kind `pedestrian` with `data.driver_id` is delivered as kind `resident` with that id. Pressing interact — `Input.parse_input_event(InputEventAction{action = "interact", pressed = true})`, `Input.flush_buffered_events()`, one frame — emits `interact_requested`, and `talk_requested` for residents. While modal (`ctx.push_modal(&"test")`), `simulate` moves nothing and interact does nothing; pushing a modal emits `interact_target_changed({})`; an interact event in the same frame as `pop_modal` does nothing.
- **Photo mode.** Entering and exiting restores the position and the HUD visibility. Crouch moves down and jump moves up; interact does nothing while in photo mode.
- **Save.** `to_dict` / `from_dict` round-trips, including crouch.

FP smoke: `interact_feature.self_test()` returns ok when a building target was produced by a forward ray from the spawn pose, which faces City Hall.

Photo tour: no change is required. A may add `photo_shots()` entries, for example `"crouch_street"`.

## Performance budget

- Player, collision and interact together cost at most **0.5 ms per frame** of GDScript at 60 fps.
- The interact ray runs at 10 Hz and costs at most 0.2 ms.
- Collider caches rebuild per tile on demand, at most 0.2 ms per tile, with no full rebuild on `tile_built`.
- No `PhysicsBody`, `Area3D` or `CollisionShape3D` nodes (D2).

## Risks

- **Ground datum.** The base ground sits at `GROUND_Y` = −0.012 and the sidewalks at 0.009. That 42 cm ledge blocks walking off the road onto grass until G1 raises the ground. The interim soft step (deliverable 1) covers it; remove it once G1 lands, since G1 changes `WS.GROUND_Y`.
- **Body boxes.** Per-surface bodies (deliverable 2) may still over-block at awnings and porches. Tune the small-surface filter, never the tests: the tests only require that feet stay out of `boxes(i)`, that bodies sit inside `building_aabb`, and that place cards stay reachable.
- **Mouse and focus.** Mouse capture belongs to FpMode. Do not set `Input.mouse_mode` in A, except in photo mode, where it stays captured.
- **Avatar picking.** `ResidentAvatars.pick` has no range or line of sight, so do not use it as the primary picker.

## Do NOT touch

- `scripts/world/*`, `scripts/sim/*`, `scripts/ai/*`, `scripts/fp/fp_*.gd`, `scripts/fp/world_scale.gd`, `project.godot`, `main.gd`.
- Any other slice's directory.

To change a `WS` value, follow S0 §4.3: you may change the player values in `WS` in the same commit as the controller change.
