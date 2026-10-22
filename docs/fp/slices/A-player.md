# Slice A: Player and interaction

Branch `fp/A-player`, in its own worktree, branched from `fp/integration` after S0 has merged. Read `docs/fp/ARCHITECTURE.md` first (D2 and **D13**), then `docs/fp/S0-foundation.md` §§7–12, then TPS_PLAN §2 (`/tmp/claude-1000/-home-kunalsiyag-Ambassador-Gmi-Cloud-gridfall/ed910984-b548-4cd5-88e0-8f11330d4e8e/scratchpad/tps/TPS_PLAN.md`), which deliverable 6 condenses.

## Goal (what the player sees)

Walking GridFall feels like a AAA third-person game at human scale (GTA V, Watch Dogs):

- **You see your character from behind, over the right shoulder.** The character is realistic and animated: it turns to face where it walks, leans into turns, jogs and runs with mocap motion, looks where you look, and lands from a jump. Until HC's characters merge it is the legacy static person (a placeholder); the camera work never waits for assets.
- **The camera behaves.** It follows smoothly, never goes inside a building or under the ground, pulls in before a wall instead of clipping, eases back out, recentres behind you while you run (never while you stand), and swaps shoulders on Q. The wheel zooms (1.6–5.0 m).
- **V switches to first person** at eye height (and back) with a short blend. In first person your body still casts its shadow.
- **Talking to a resident cuts to a two-shot** over your shoulder that frames both faces, then eases back.

Everything below holds in both cameras:

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

- `scripts/fp/player/**`. This includes S0's `player.gd`; keep `class_name FpPlayer` and every public member listed in S0 §11. New: `tps_rig.gd` (`TpsRig`, RefCounted), `spring_math.gd` (static), `player_avatar.gd` (the Avatar node).
- `scripts/fp/world/collision_world.gd`. Keep `class_name CollisionWorld` and every S0 §12 signature; add `sweep_sphere` (deliverable 6).
- `scripts/fp/interact/**` (entry point `interact_feature.gd`, id `interact`).
- `tools/tests/fp_player_test.gd` and `tools/tests/fp_tps_test.gd`.

## Seams consumed

| From | API |
|---|---|
| S0 `WS` | `EYE`, `CROUCH_EYE`, `PLAYER_RADIUS`, `PLAYER_HEIGHT`, `CROUCH_HEIGHT`, `WALK`, `RUN`, `CROUCH_WALK`, `ACCEL`, `GRAVITY`, `JUMP_SPEED`, `STEP_HEIGHT`, `PITCH_LIMIT_DEG`, `PHOTO_FLY_SPEED`, `TALK_RANGE`, `INTERACT_RANGE`, `CAMERA_*`, `ASPHALT_TOP`, `SIDEWALK_TOP`, `CURB_RISE`, `GROUND_Y`, `LOT_TOP`, `PAD_TOP` |
| S0 `RoadTopology` | `surface_height`, `is_carriageway`, `is_bridge`, `mask` |
| `CityView` (S0 seam) | `building_aabb(i)` (picking only), `site_boxes(i)` (site collision), `tile_holder(i)` (meta `building_path`, `building_xform`, `colliders`; the holder's `Site` child carries the kit's own `colliders`), `in_setup`, `tile_built` / `tile_cleared` / `world_rebuilt`, `bus_stops`. `avatars` only as the last-resort resident source (below). |
| `FpContext` | `bus`, `collision`, `player`, `hud`, `directory`, `features`, `settings`, `is_modal()`, `push_modal()` / `pop_modal()`, `world_root`, `mode.apply_settings(patch, persist)` |
| S0 settings (D13) | `camera_mode` (`"third"` default, `"first"`), `fov` (first person, 72), `tps_fov` (60), `tps_distance_m` (3.2), `shoulder` (1 right, -1 left), `auto_shoulder` (false), `hero` (`"m"`, `"f"`). Tests get `camera_mode = "first"` from `fp_kit` unless they pass `{"camera_mode": "third"}`. |
| S0 input (D13) | `view_toggle` (V), `shoulder_swap` (Q), `zoom_in` / `zoom_out` (wheel), `look_left` / `look_right` / `look_up` / `look_down` (gamepad right stick, dead zone 0.15) |
| `GameBus` | emits `interact_target_changed`, `interact_requested`, `talk_requested`, `player_tile_changed`; listens to `settings_changed` (fov, sensitivity, `invert_y`, `head_bob`, `camera_mode`, `tps_fov`, `tps_distance_m`, `shoulder`, `auto_shoulder`, `hero`), `modal_changed`, `conversation_changed` (C is the only emitter; A runs the two-shot) |
| HC (stage A2) | `AP.HERO_M` / `AP.HERO_F`, `AP.CHAR_LIB_M` / `AP.CHAR_LIB_F` (clip names bare, `speed_mps` meta), `AP.PERSON_TPS_ANIMS`, `rest_height_m` in `AP.CHAR_ROSTER`, the per-rig `forward_axis` for head look. Until HC lands: the legacy `AP.PEOPLE_LEGACY_DIR + "person_a.glb"` at `WS.PEOPLE_SCALE`. |
| E's traffic feature (optional) | `anchor_of(id)` (the NPC head for the two-shot), `agents_near(p, r)` (camera inside a car box pulls the arm in) |
| C's chat feature (optional) | `is_typing() -> bool` (the optional reverse shot while the player types) |
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
- S0 owner: gamepad events for `move_*`, `jump`, `interact`, `sprint`. This is a `project.godot` `[input]` edit. (The right-stick `look_*` actions already exist.)

## Deliverables

1. **Controller** (`player.gd` and helpers under `scripts/fp/player/`):
   - Keep S0's signature `simulate(wish, sprint, delta, crouch := false, jump := false)`; `simulate` itself zeroes `wish` and `jump` while `ctx.is_modal()` (gravity and ground snap still run). `_process` polls only the held state (`move_*`, `sprint`, `crouch`, `jump`) and passes it in.
   - **Keep S0's long-frame guard.** `_process` passes `minf(delta, MAX_FRAME_DELTA)` (0.1 s), and `simulate` sub-steps so that no collision step moves farther than `PLAYER_RADIUS`, whatever `delta` it is given; a velocity component whose move was blocked drops to zero. Sim tick stalls make 0.7–2.7 s frames in real FP play, and pressing T runs 1–4 ticks in one frame; without the guard one such frame at `RUN` steps straight through a 0.008 u hoarding (0.038 u once grown by the radius). Jump and gravity sub-step the same way.
   - Kinematic movement. The velocity follows a critically damped **velocity spring** (deliverable 6.4) in both cameras; it replaces `move_toward(ACCEL)`. A 3 s walk then covers 92.8 % of `WALK*3`, inside `fp_core_test`'s ±15 % and this spec's ±10 %.
   - Sprint (`RUN`) and crouch (`CROUCH_EYE`, `CROUCH_WALK`; you cannot stand up under a ceiling box).
   - Jump with `JUMP_SPEED` and `GRAVITY`, with coyote time of 0.1 s.
   - Step-up of up to `STEP_HEIGHT`, so the curb works but the 0.021 u grass-to-sidewalk ledge does not, unless G1 has raised the ground. The camera y lerps after a step.
   - **Interim soft step** (until G1 changes `WS.GROUND_Y`): at **any** tile edge whose lower side is at `GROUND_Y`, allow a soft step of up to `0.03 u` as a ramp over the outer 0.05 u of the higher tile. Lots and pads to grass are 0.016–0.018 and rubble has no box, so restricting the ramp to sidewalks would trap a player who drops onto an interior grass tile. Remove the rule in the commit that follows G1's `GROUND_Y` change.
   - Head bob, with an amplitude of `0.03 * M` vertical and `0.015 * M` lateral, scaled by speed. It is on when `settings.head_bob` is set, and only in first person.
   - FOV from settings: `"fov"` in first person (sprint widens it by 4°, tied to `head_bob` for comfort), `"tps_fov"` in third person (the rig adds its own +6° while running).
   - Footstep events: emit a local signal `stepped(surface: String, pos: Vector3)` on `FpPlayer`, which I (audio) connects to. The surface comes from `CollisionWorld.surface_at`. While the avatar animates (both cameras: in first person it still runs for the shadow), fire it on the locomotion clip's **foot contacts**: HC phase-aligns every loop so the left heel strikes at t = 0, the right at half the cycle, so the sound matches the visible stride; `pos` is that foot's ground point. Without an animated avatar, fire every `0.7 * M` of horizontal travel as before.
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
   - Every `0.1 s`, cast from `player.eye_position()` along the camera forward in first person. In third person use deliverable 6.7: from the camera through the screen centre, starting at the point on that line closest to the head.
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
   - Free-fly at `PHOTO_FLY_SPEED` through walls, but never lower than `TpsRig.GROUND_CLEAR` above the ground (the water surface off the land), starting from the current camera transform (in third person, the arm's position). Down is `crouch` (Ctrl) and up is `jump` (Space); Q (`shoulder_swap`), V (`view_toggle`), the wheel and C are ignored, and E is `interact`. On exit the previous camera mode resumes with a snapped rig.
   - In photo mode A ignores `interact`; FpMode ignores `hud_toggle` (F1) and C ignores `chat_open`. A sets S0's `FpPlayer.photo_mode` flag, which they read.
   - Hides the HUD (`hud.set_hud_visible(false)`) and pushes no modal, so the mouse stays captured.
   - The player position is saved on entry and restored on exit.
   - The sim keeps running.
5. **Save.** `FpPlayer.to_dict()` / `from_dict()` keep the S0 shape and add `crouched`, `photo` (false on load), `cam_yaw`, `cam_pitch` and `camera_mode`. Old saves without them still load (`cam_yaw = yaw`, `cam_pitch = pitch`, `camera_mode` from the settings). The camera mode the player last chose on V is also written to the settings with `mode.apply_settings({"camera_mode": …})`, so the next session boots in it.

6. **Third-person camera, avatar and conversation camera** (D13; TPS_PLAN §2). Stage A1 builds 6.1–6.8 and 6.10 with the placeholder avatar; stage A2 adds 6.9 on HC's hero (see "Stages" below).

   **6.1 Contracts that must not change** (existing tests depend on them):
   - **Camera.** `player.camera` stays the one current `Camera3D` (`fp_smoke` lines 57, 64 and 179). In third person, set `camera.top_level = true` and give it a world transform each frame; in first person set it back to `false`.
   - **`eye_position()`** is still the head (`position + up·EYE`). `TALK_RANGE` and `INTERACT_RANGE` are measured from it. Add `view_position()` and `view_dir()` for the camera.
   - **`forward()`** is the camera look direction. After `teleport(pos, yaw, pitch)` it equals the teleport yaw and pitch, as `fp_core_test` requires.
   - **`teleport()`** sets `cam_yaw = body_yaw = yaw` and `cam_pitch = pitch`, and **snaps the rig**: springs, pivot, arm, release timers and blend. No swoop after a load, spawn or photo shot.
   - **`simulate(wish, sprint, delta, crouch, jump)`** keeps its signature. The wish vector is rotated by **`cam_yaw`**.
   - **Settings.** `"fov"` stays the first-person FOV (`fp_core_test`). Third person reads `"tps_fov"`.

   **6.2 Node layout.**

   ```
   Player (FpPlayer, Node3D at the feet; yaw = body_yaw)
   ├─ Camera3D            top_level in third person; the rig writes global_transform
   ├─ Avatar (player_avatar.gd)   CharacterRoot (scale WS.M·h_target/h_rest) → hero GLB → %GeneralSkeleton, AnimationTree
   │                               HeadLook: LookAtModifier3D (child of Skeleton3D)
   └─ (logic) TpsRig (tps_rig.gd, RefCounted), SpringMath (spring_math.gd, static)
   ```

   - **Placeholder** (stage A1, and whenever the hero GLB is missing): the legacy static `AP.PEOPLE_LEGACY_DIR + "person_a.glb"` at `WS.PEOPLE_SCALE`, yawed with the body, with lean applied. Camera work is never blocked on assets.
   - **First person:** the Avatar's `cast_shadow = SHADOWS_ONLY`, so you see your shadow but no body; the animation keeps running.
   - **Player fade:** camera-to-head distance ≤ 0.45 m → hidden; ≥ 0.90 m → opaque (`GeometryInstance3D.transparency` on the hero).

   **6.3 Modes, settings, input.**
   - `view_toggle`, `shoulder_swap`, `zoom_in` and `zoom_out` are discrete: `_unhandled_input` only, on `is_action_pressed(…) and not is_echo()` (rule 7). They are ignored while `ctx.is_modal()` and in photo mode, so the wheel never zooms under chat, the map or a card. `zoom_*` does nothing in first person (B's minimap uses the wheel there).
   - `look_*` is analog: read `Input.get_vector("look_left", "look_right", "look_up", "look_down")` each frame (radial dead zone from the actions, 0.15).
   - **Mode switch** blends over 0.35 s (smoothstep on position and FOV, slerp on the basis). Head bob applies only in first person.
   - `settings_changed` applies `camera_mode`, `tps_fov`, `tps_distance_m`, `shoulder`, `auto_shoulder` and `hero` at once (`hero` swaps the avatar body; a missing body keeps the placeholder).
   - The photo tour and `fp_bench` force first person with `apply_settings({"camera_mode": "first"}, false)` (S0), so their baselines stay valid. A adds third-person shots through `interact_feature.photo_shots()`: `tps_street` (the street pose, third person, hour 10.5) and `tps_crossing` (behind the hero at a crossing), with `"prepare": "photo_third_person"` and `"restore": "photo_first_person"`, methods on the interact feature that call `ctx.mode.apply_settings({"camera_mode": …}, false)` and snap the rig.

   **6.4 Movement** (both cameras; code-driven, in place, analytic collision):

   | Parameter | Value | Notes |
   |---|---|---|
   | Speeds | WALK 1.45, RUN 4.5 (Shift), CROUCH_WALK 0.8 m/s | Unchanged (`WS`) |
   | Acceleration | Critically damped velocity spring: halflife **0.15 s** speeding up, **0.10 s** slowing, **0.5 s** in the air | Replaces `move_toward(ACCEL)`. Stop distance from a run 0.65 m, from a walk 0.21 m. |
   | Body yaw (third person) | Spring toward `atan2(−v.x, −v.z)` when speed > 0.2 m/s; halflife **0.10 s**, max **720°/s** walking, **450°/s** running | About a 0.57 m turn radius at 4.5 m/s. Standing still never follows the camera (as in GTA). |
   | Body yaw (first person) | `= cam_yaw` | |
   | Pivot turn | angle(wish, v) > 135° and speed > 2.5 m/s → 0.3 s PIVOT: velocity halflife 0.06 s toward 0, yaw halflife 0.08 s, backward lean | Stage A3 adds the `turn_*180_walk` clips |
   | Jump | `JUMP_SPEED` 3.4 m/s (apex 0.59 m), coyote **0.10 s**, buffer **0.12 s** | Vertical speed > 4 m/s on landing → heavy land: 0.3 s at half speed |
   | Curb step | Feet snap as now (`STEP_HEIGHT` 0.25 m); avatar visual y damped with halflife 0.05 s; camera vertical halflife 0.08 s | Never attach the camera to a bone |
   | Procedural lean | roll = clamp(0.35·atan(v·ω/g), ±8°); pitch = clamp(0.5·atan(a_fwd/g), −5°, +7°); spring halflife 0.1 s | Applied to the Avatar node about the feet |
   | Scripted facing | Talk or interact with a facing error > 60° at < 0.2 m/s → turn in place at 270°/s | Stage A3 adds the `turn_l90` / `turn_r90` clips |

   **6.5 Camera rig parameters** (prototype values; all pass the 15 headless checks of `.../scratchpad/tps/probe_proj/tps_rig_test.gd`). Port `spring_math.gd` (exact damper and critically damped spring) and `tps_rig.gd` from `.../scratchpad/tps/probe_proj/tps_math.gd` and `tps_camera_rig.gd`.

   | Parameter | Value | Notes |
   |---|---|---|
   | Pivot | **1.55 m** above the feet (neck and shoulder) + a "hand" 0.10 m up | Eye height is 1.65 m |
   | Shoulder offset | **0.40 m** × `settings.shoulder` (Q swaps; `side` spring halflife 0.12 s, about 0.4 s for a full swap) | The hero sits about 6 % of the screen width left of centre: a mild over-the-shoulder view |
   | Arm length | `settings.tps_distance_m` (**3.2 m** default); zoom **1.6–5.0 m** in 0.4 m steps (halflife 0.12 s); **+0.4 m** while running | The hero is about 47 % of the screen height at 60° vertical FOV |
   | Pitch | rest **−10°**, limits **−70° (down) / +50° (up)**; rate eased in the last 10° on a gamepad | First person keeps ±85° |
   | Pitch → distance | ×1.15 looking fully down, ×0.6 looking fully up (linear in pitch) | Pulls in instead of hitting the ground |
   | FOV (vertical) | `settings.tps_fov` (**60°**); **+6°** running (halflife 0.25 s); **45°** in conversation | First person stays at `"fov"` (72°) |
   | Probe radius | **0.20 m** | ≥ the near-plane corner (0.124 m at 60°, 0.154 m at 21:9 with +6°) and < `PLAYER_RADIUS`. Keep `CAMERA_NEAR` (8 cm). |
   | Pivot follow (halflives, camera-local) | lateral **0.03 s**, depth **0.05 s**, vertical **0.08 s** (**0.30 s** in the air) | Measured lag at a 4.5 m/s run: 0.325 m |
   | Look-ahead | lateral lead = clamp(dot(v, cam_right)·0.12 s, ±0.4 m), halflife 0.35 s | |
   | Mouse | `settings.mouse_sensitivity` (0.0022 rad/px) on `screen_relative`, applied raw in `_unhandled_input`, **never smoothed** | S0's stretch-free rule holds |
   | Gamepad | radial dead zone 0.15 (`Input.get_vector`), response x², 270°/s yaw, 160°/s pitch, 400°/s after 0.3 s at full deflection | |
   | Auto-recenter | After **1.0 s** with no look input while speed > 0.3 m/s: yaw damps toward `body_yaw` with halflife 1.6 s (walk) to 0.8 s (run); pitch damps toward −10° at 1.5× that. **Skipped when \|Δyaw\| > 135°.** No recentering while idle. | Measured: 90° off → within 10° after 2.53 s; 180° → no movement |
   | Idle sway | Off in v1 | Not worth a test risk |

   **6.6 Camera collision** (an analytic spring arm; no `SpringArm3D`, because D2 rules out physics):
   - **New query** `CollisionWorld.sweep_sphere(origin: Vector3, dir: Vector3, max_dist: float, radius: float) -> float` (the free distance along `dir`). A ray against the AABBs of `boxes(i)` grown by `radius` (a Minkowski sum), skipping boxes that contain the origin, over only the 3×3 tiles around the pivot (maximum reach 5.0 + 0.4 + 0.4 m = 0.29 u < 0.5 u). Prototype cost 32 µs per full rig update; budget ≤ 100 µs.
   - **Per frame:**
     1. **Root → shoulder** sweep at radius × 1.05, so a wall at the shoulder never swallows the pivot.
     2. **Hand → camera is a hard limit**: pull in on the same frame.
     3. **Predictive feelers, soft.** Each is (yaw°, pitch°, weight, retrace every N frames): (±16, 0, 0.75, 3), (±32, 0, 0.5, 5), (0, +20, 1.0, 4), (0, −20, 0.5, 4). A blocked feeler retraces every frame. Blocked fraction = `1 − (1 − t/len)·weight`; the arm takes the minimum. Pull in with halflife 0.05 s. To release, **hold 0.15 s, then ease out with halflife 0.20 s** (measured: 1.32 → 1.32 m on the first free frame, 2.32 m after 0.5 s, then 3.27 m).
     4. **The ground lifts the camera:** `cam.y = max(cam.y, ground_height(cam.xz) + 0.20 m)`. A hill is not a wall.
   - **Ignored by the arm (v1):** thin props (lamps, signs, trees, the `CURB_FURNITURE` band; the camera may graze them for a frame, and a v2 G1 hook can dither-fade them), people, and moving or parked cars **unless** the camera is inside an agent box from E's `agents_near()`, which pulls in hard.
   - **Auto shoulder swap** (`settings.auto_shoulder`, off by default): if the shoulder-side sweep is blocked below 50 % for more than 0.5 s, swap sides. Pressing Q clears the auto state.

   **6.7 Interaction in third person.**
   - **Ray** from the camera through the screen centre, **starting at the point on that line closest to the head**, so objects between the camera and the player are never picked.
   - **Range** is measured from `eye_position()`. Keep 10 Hz.
   - **Fallback** when the ray finds nothing: candidates within `TALK_RANGE` inside ±35° of the camera's horizontal forward, scored `0.7·angle + 0.3·distance`, with 0.2 s of hysteresis before switching targets.
   - **Soft assist.** While a target is focused, with no look input for 0.5 s and speed below walk, bias the camera at most 10° in yaw and 6° in pitch toward it (halflife 0.6 s). Never right after the player turned the camera.
   - The target dict's `pos` is the anchor B unprojects for the prompt (the head for residents, the label point for buildings and posters).

   **6.8 Conversation camera** (on C's `conversation_changed(id, true)`). P is the player's head, N the NPC's head (E's `anchor_of(id)` when present, else the visible avatar's position + `EYE`), `u` the horizontal unit vector P→N, and `s` = `u` rotated −90° about Y, times the sign of the side the camera is already on (keeping that side keeps the 180° rule).
   - **Two-shot:** camera `C = P − u·0.9 + s·0.6 + up·0.1`; look target `L = P + (N−P)·0.6 − up·0.05`; FOV 45°. Sweep P→C at radius 0.2; if the free fraction is < 0.7, flip `s`; if both sides are blocked, shorten the back offset to 0.6 m. Keep both heads in the upper 60 % of the frame: C's dialogue panel covers the bottom 220 px.
   - **Blending:** in over 0.6 s with smoothstep (no spring overshoot); out over 0.45 s. On exit, set `cam_yaw` / `cam_pitch` from the final view, so there is no snap.
   - **The player faces the NPC** (body-yaw spring, 0.3 s). Head look targets the NPC's head (6.9).
   - **Optional reverse shot** while the player types (C's `is_typing()`): `C' = N + u·0.9 + s·0.6`. Hard-cut at most once every 2.5 s.
   - In first person the conversation only turns the view toward N (same blend times); there is no two-shot.

   **6.9 Player animation** (stage A2, on HC's hero; `player_avatar.gd`, AnimationTree, `callback_mode_process = IDLE`, HC's library as the default library `""`, `root_motion_track = %GeneralSkeleton:Root`):
   - **StateMachine:** Locomotion (BlendSpace1D on `speed_mps`, then a TimeScale node); Crouch (BlendSpace1D of `crouch_idle` at 0 and `crouch_walk` at 0.75); Air (`jump_start` → `fall` loop → `land`); Talk (`talk` loop); Sit (`sit_down` → `sit` → `stand_up`); OneShot (`interact`, `wave`, `phone`, `door_try`).
   - **Locomotion blend points** at the measured authored speeds. Male hero: idle 0, walk 1.35, walk_fast 1.50, run 3.07, run_fast 5.84. Female hero: idle 0, walk 1.21, walk_fast 1.53, run 3.16, run_fast 5.38. `sync_mode = SYNC_MODE_CYCLIC_MUTABLE`. At WALK 1.45 the male blend is walk / walk_fast at 0.33 / 0.67; at RUN 4.5, run / run_fast at 0.48 / 0.52 (both phase-aligned by HC).
   - **Foot-slide correction.** `TimeScale = clamp(v / v_anim, 0.5, 1.5)`, where `v_anim = Σ wᵢ·Sᵢ / Σ wᵢ·Tᵢ`, Sᵢ = speedᵢ·Tᵢ is the stride per cycle and T the cycle length. Feed `v` = horizontal speed in m/s (`Vector2(vel.x, vel.z).length() / WS.M`), scaled for body height (`speed_mps × h_target / 1.75`).
   - **Cross-fades:** Locomotion→jump_start 0.08 s; jump_start→fall at end 0.1 s; fall→land when grounded 0.06 s; land→Locomotion at end 0.15 s (input may interrupt after 50 %); ↔Crouch 0.2 s; ↔Talk 0.3 s.
   - **Drive the tree from code** with `parameters/playback.travel()` and parameters, never advance expressions, so it can be tested.
   - **Head look:** `LookAtModifier3D` on `Head`, and a second on `Neck` at influence 0.35 (limit 45°, ordered above Head). `primary_rotation_axis = Y`, secondary on, `symmetry_limitation = true`, limits 70° / 35°, `duration = 0.35` with SINE / IN_OUT, `origin_safe_margin = 0.5 m·M`. Target priority: the conversation NPC's head → the focused interactable → **the point 10 m along the camera view** (the character looks where you look). When `is_target_within_limitation()` turns false (read it after `modification_processed`), tween the influence to 0 over 0.3 s. `forward_axis` per rig comes from HC (its test asserts it).
   - **Footsteps** follow the foot contacts (deliverable 1).

   **6.10 Frame order and budget.**
   1. `_unhandled_input`: mouse look applies to `cam_yaw` and `cam_pitch` immediately.
   2. `_process(delta)`: `simulate()` → avatar parameters (speed, grounded, state) → `rig.update(delta, player_state, collision)` → write `camera.global_transform` and `fov`.

   Budget: player, collision, interact and rig ≤ **0.5 ms** of GDScript at 60 fps; `rig.update` < 100 µs; the hero AnimationTree ≤ 0.1 ms.

## Stages (TPS_PLAN §3)

| Stage | TPS_PLAN | Content | Needs |
|---|---|---|---|
| A1 | T2 (+ the A part of T6 without HC) | Deliverables 1–5; 6.1–6.8 and 6.10 with the **placeholder** avatar: `spring_math.gd`, `tps_rig.gd`, `CollisionWorld.sweep_sphere`, the yaw split, the velocity spring, the teleport snap, the mode toggle, interaction in third person, the two-shot on C's signal; `fp_tps_test` items 1–10 and 12 (item 11 when C has merged, else against a test emission of `conversation_changed`) | S0 D13 hooks |
| A2 | T5–T6 | 6.9 on HC's hero: AnimationTree, lean on the real body, head look, first-person shadow-only, fade; foot-contact footsteps; `fp_tps_test` item 11 and the avatar items | HC1 + HC2 merged |
| A3 | T10 (with HC) | Polish: `walk_start` / `run_start` for the first 0.4 s; stops with distance matching (on release from above walk speed, `walk_stop` / `run_stop` with the clip time set from the remaining stop distance `v·hl/ln2`); 180° pivots with `turn_*180_walk`; turn-in-place clips; foot IK (`TwoBoneIK3D`) when idle on curb edges | HC4 |

A1 merges like any slice (ARCHITECTURE §7) and must pass without `models/characters/**`. A2 and A3 are follow-up branches (`fp/A2-hero`, `fp/A3-polish`) after HC merges.

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
- **Photo mode.** Entering and exiting restores the position and the HUD visibility. Crouch moves down and jump moves up, and flying down stops 0.20 m above the road; interact does nothing while in photo mode.
- **Save.** `to_dict` / `from_dict` round-trips, including crouch.

**Third person: `tools/tests/fp_tps_test.gd`**, token `FP_TPS_TEST: PASS`, built on `fp_kit.make_ctx(root, {"view": true, "grow": true, "camera_mode": "third"})`:

1. The camera is current, `== player.camera`, and `top_level`. `eye_position()` equals `position + up·EYE` within 1e-6.
2. **Teleport snap.** After `teleport(p, yaw)` on a street, on the next frame the camera is behind the player: the horizontal camera→pivot direction · body forward > 0.95, and the arm is 3.2 ± 0.05 m. After a 100 m teleport the camera is within 3.3 m of the player on the next frame.
3. **Never inside a building.** With the back 1 m from a building, sweep `cam_yaw` through 360° over 240 frames: `collision.is_blocked(cam, 0.2 * M)` is never true. The arm recovers to the default after the release time.
4. **Ground.** At pitch +50°, `cam.y ≥ ground + 0.20 * M − 1e-4`.
5. **Recenter.** Running with the camera 90° off and no look input brings |Δyaw| < 10° by 2.6 s. At 180° nothing changes.
6. **Frame-rate independence.** The same 2 s input at 30 fps and at 144 fps puts the camera within 2 cm of the same point.
7. **Speed gate.** A 3 s walk covers 90–100 % of `WALK*3`. Run is faster than walk.
8. **Body faces travel.** With `cam_yaw = 0` and wish (1, 0) for 0.5 s, the body yaw is within 5° of the +X travel, and the camera yaw has not moved.
9. **Interaction.** A fake pickable placed between the camera and the player is not picked; a building in front is.
10. **Toggle.** A `view_toggle` event (`Input.parse_input_event` + `Input.flush_buffered_events()`) → after 0.35 s the camera sits at `eye_position()` ± 1e-4, `top_level` is false and the FOV is the `"fov"` setting. Toggling back restores the third-person arm. Neither toggle fires while a modal is pushed. The settings log records the chosen mode.
11. **Conversation.** On `conversation_changed(id, true)`, both heads are inside the frustum after 0.6 s and the camera stays on its original side of the P–N line. On exit, `cam_yaw` matches the final view (Δ < 1°).
12. **Performance.** The average `rig.update` is < 100 µs over 600 frames.
13. **Avatar** (stage A2, skipped with a printed note while `AP.HERO_M` is missing): the hero body loads with HC's library; walking at `WALK` puts the locomotion TimeScale within [0.9, 1.1]; in first person the avatar's `cast_shadow` is `SHADOWS_ONLY`; `stepped` fires within ±1 frame of each foot contact.

Existing `fp_core_test`, `fp_player_test` and the other kit-based tests run in first person (the kit default) unchanged. The FP smoke boots with the default settings (third person once A1 lands), so its checks must hold there too.

FP smoke: `interact_feature.self_test()` returns ok when a building target was produced by a forward ray from the spawn pose, which faces City Hall (in either camera).

Photo tour: the base shots stay first person (S0 forces it). A adds `tps_street` and `tps_crossing` (deliverable 6.3) and may add `"crouch_street"`. Run `tools/gate.sh render` and look at the third-person shots: the hero is left of centre, about half the screen height, feet on the ground, not clipped by the near plane.

## Performance budget

- Player, collision, interact and the camera rig together cost at most **0.5 ms per frame** of GDScript at 60 fps; `rig.update` under 100 µs; the hero AnimationTree at most 0.1 ms.
- The interact ray runs at 10 Hz and costs at most 0.2 ms.
- Collider caches rebuild per tile on demand, at most 0.2 ms per tile, with no full rebuild on `tile_built`.
- No `PhysicsBody`, `Area3D` or `CollisionShape3D` nodes (D2).

## Risks

- **Ground datum.** The base ground sits at `GROUND_Y` = −0.012 and the sidewalks at 0.009. That 42 cm ledge blocks walking off the road onto grass until G1 raises the ground. The interim soft step (deliverable 1) covers it; remove it once G1 lands, since G1 changes `WS.GROUND_Y`.
- **Body boxes.** Per-surface bodies (deliverable 2) may still over-block at awnings and porches. Tune the small-surface filter, never the tests: the tests only require that feet stay out of `boxes(i)`, that bodies sit inside `building_aabb`, and that place cards stay reachable.
- **Mouse and focus.** Mouse capture belongs to FpMode. Do not set `Input.mouse_mode` in A, except in photo mode, where it stays captured.
- **Avatar picking.** `ResidentAvatars.pick` has no range or line of sight, so do not use it as the primary picker.
- **Thin props.** The arm ignores lamps, signs and trees in v1, so the camera may graze one for a frame at 8 cm near. Accepted; a v2 fade hook from G1.
- **Placeholder look.** Until A2, the hero is a static mid-stride mannequin that slides. That is expected; do not tune the camera to it (the rig values are for a 1.75 m body).

## Do NOT touch

- `scripts/world/*`, `scripts/sim/*`, `scripts/ai/*`, `scripts/fp/fp_*.gd`, `scripts/fp/world_scale.gd`, `project.godot`, `main.gd`.
- Any other slice's directory.

To change a `WS` value, follow S0 §4.3: you may change the player values in `WS` in the same commit as the controller change.
