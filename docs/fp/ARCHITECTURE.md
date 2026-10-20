# GridFall on foot (internal id `fp`): architecture and build plan

GridFall started as a top-down city builder. This plan turns it into an **on-foot exploration of a living AI city**. You walk the streets as a visible, animated character seen over the shoulder (third person, the default since D13), and V switches to first person at eye height. Residents with GMI minds drive their own cars on their own commutes. Mayors campaign on real posters printed by `hy-image-v3.5-preview`. The whole city talks in a Clash of Clans–style global chat.

The sim, the GMI brain and the resident minds stay as they are. This project changes what you see and how you take part.

Research behind every decision below: the subsystem deep-read, with file:line references and measurements, in
`/tmp/claude-1000/-home-kunalsiyag-Ambassador-Gmi-Cloud-gridfall/ed910984-b548-4cd5-88e0-8f11330d4e8e/scratchpad/understand.md`.
Read the sections for your subsystem before you change it. The third-person research (camera and controller parameters, character sources, measurements) is
`/tmp/claude-1000/-home-kunalsiyag-Ambassador-Gmi-Cloud-gridfall/ed910984-b548-4cd5-88e0-8f11330d4e8e/scratchpad/tps/TPS_PLAN.md` (cited below as TPS_PLAN).

**Naming.** The internal id `fp` (`scripts/fp/**`, `FpMode`, `FpPlayer`, `GRIDFALL_VIEW=fp`, `fp_*` tests, `save["fp"]`) predates D13 and now means **on-foot play**, in either camera. Nothing is renamed.

---

## 1. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | **Keep the world unit: 1 unit = 1 tile = 20 m.** New code writes physical quantities in metres times `WS.M` (`WS.M = 0.05` units per metre), e.g. `var eye := 1.65 * WS.M`. Do not rescale the world or any parent node. | About 2,300 float literals, the Blender exporter (`core.py M = 1/20`), `validate_real.py`, saves and the tools all use tile units. Mixed scales across parallel slices would be far worse. Float precision at \|x\| ≤ 112 is about 0.15 mm, and Godot uses reverse-Z depth. |
| D2 | **No engine physics.** The player is a kinematic controller that collides against an analytic `CollisionWorld`: building body boxes per tile, ground and curb height, water, prop cylinders. Picking is also analytic (ray against the full building AABBs, plus each feature's `pick()` for agents and posters). | The project has no bodies today. Physics engine defaults assume metres (gravity, snap, slop), and thousands of colliders would cost frame time. A grid query is cheap and deterministic in headless tests. |
| D3 | **Two view modes, one composition root.** Normal play boots **on foot** (`fp`; third-person camera by default since D13). `GRIDFALL_VIEW=orbit`, and every existing tool mode (smoke, photo tour, cinematic), keeps the legacy orbit camera and `CityHud` unchanged. A new `GRIDFALL_FP_SMOKE=1` headless test covers first person. | The existing gates stay green while first person grows next to them. |
| D4 | **Real-time day.** `CitySim.day_seconds` becomes a runtime variable (default 12 s, so orbit and tests are unchanged). First person sets **1,200 s (a 20-minute game day)**. The player can change speed with `[` and `]` (1×, 2×, 4×, 8×), and `T` skips to the next morning. | A 12 s day strobes the sky and forces agents to move at 26–150 m/s. |
| D5 | **Mayors get human display names everywhere the player can see.** Model ids stay internal and are used only for API calls. Lean HUD, chat, posters, world labels and the LLM prompts that produce player-facing text all use the display name: Ada Okafor (argon), Viktor Han (deepseek), Mei Kimura (kimi), Rosa Quintero (qwen), Duke Granger (grok). | The user asked for the distracting model-branded HUD to go. Branding leaks through `city_log`, `owner_name()` and the prompts. |
| D6 | **Lean HUD only on foot.** Top: indicator chips (population, mood, treasury, power, time/day, alerts). Bottom-left: minimap. Global chat panel. Interact prompt (anchored over the target in third person; a crosshair only in first person, D13). No mayor cards, GMI log, model names or tabs. `CityHud` survives only in orbit mode. | The user asked for this directly. |
| D7 | **Feature modules behind seams.** Everything new in first person lives in `scripts/fp/**`. It is built from feature modules registered in one file that S0 pre-populates with stubs, one per slice. A slice edits only its own files plus the shared-file hunks the ownership table assigns to it. | This is the "build vertically" rule, so parallel slices can't break each other. |
| D8 | **One owner per legacy monolith.** `city_view.gd`, `construction_kit.gd`, `sky_director.gd` and `main-environment.tres` belong to G1 (streetscape). `city_life.gd` and `resident_avatars.gd` belong to E (traffic). `city_sim.gd` and `residents.gd` belong to F (sim performance). S0 adds only the seams listed in §4. Every other slice consumes those seams. | Conflicts stay confined to a single slice. |
| D9 | **Offline is first-class.** Every GMI feature has a deterministic offline path: replay cache, heuristics, templates, and a pre-baked poster set under `res://assets/posters/`. Gates always run with `GRIDFALL_OFFLINE=1`. Nobody sets `GRIDFALL_RECORD=1`, because it rewrites the tracked replay cache. | Tests must be free and deterministic, and must not race each other. |
| D10 | **Assets come from headless Blender.** Run `blender --background --python tools/blender/...` and re-run `validate_real.py`. Assets land at the paths in `scripts/fp/asset_paths.gd`, and every consumer falls back if the file is missing. | MCP servers are not available inside workflow agents, and headless runs can be repeated. |
| D11 | **Performance is a feature.** Targets at street level on an RTX 3050 Laptop (4 GB): p50 ≤ 16.7 ms and p99 ≤ 33 ms at 1600×900, under 2,000 draw calls, no single sim stall over 50 ms, VRAM ≤ 1.5 GB. | Today's measurements: 36–41 fps, 5.3 k draw calls, 2.09 GB VRAM, 280–765 ms tick stalls. |
| D12 | **Budgets for paid calls.** Global-chat chatter makes one batched call every 60 s of real time (4–8 lines). A player chat message triggers one call. Each spoken line in a direct conversation triggers one call. Live posters are capped at 6 per game day and 30 per session, and cached forever under `user://posters/`. The pre-baked set is about 24 posters, made once by `tools/gmi/generate_posters.py`. | Spend stays bounded. |
| D13 | **Third person is the default camera; `fp` means on-foot play.** Interactive play boots an over-the-shoulder follow camera (`settings.camera_mode = "third"`): an analytic spring arm 3.2 m behind and 0.4 m right of a pivot 1.55 m above the feet, 60° FOV, collision by `CollisionWorld.sweep_sphere` (no physics, D2), with a visible, animated, realistic hero. **V** (`view_toggle`) switches to first person at `EYE` (72° FOV) and back; the choice is saved in the settings. Characters (hero, residents, crowd) are Microsoft Rocketbox bodies (MIT) and Rocketbox mocap plus Quaternius UAL clips (CC0), retargeted onto Godot's humanoid skeleton with one shared animation library per gender; their licence files are committed under `models/characters/LICENSES/` and the raw sources (2.6 GB) never are. H's procedural rigged people are dropped; the new slice **HC** owns the character pipeline. Tests stay first person: `fp_kit.make_ctx` sets `camera_mode = "first"` unless `opts.camera_mode` says otherwise, and the photo tour and `fp_bench` force first person with a non-persistent settings patch. | The user changed direction: GTA V / Watch Dogs feel with a visible character. CEO decisions T-D1 to T-D5 (TPS_PLAN §0): MIT and CC0 allowed with licence files, plain git (about 60–70 MB of character binaries), third person default, H §1 superseded, new slice HC. Keeping the `fp` id avoids a churn rename across every slice. |

## 2. Units and constants (`scripts/fp/world_scale.gd`, a const-only file preloaded as `WS`)

```
M = 0.05                      # units per metre
EYE = 1.65 m                  # camera height when standing
CROUCH_EYE = 1.0 m
PLAYER_RADIUS = 0.3 m
WALK = 1.45 m/s
RUN = 4.5 m/s
CAR_CITY = 13.9 m/s (50 km/h)
LANE_OFFSET = 0.15 u          # right-hand lane centre from the road centreline (painted lanes, roads.py HW=0.3)
ROAD_HALF = 0.3 u             # carriageway half-width
SIDEWALK_TOP = 0.009 u        # 18 cm curb (confirm against roads.py)
CAMERA_NEAR = 0.004 u
CAMERA_FAR = 60 u
FOV = 72
REAL_SCALE = 1.0              # buildings (was 0.9)
PEOPLE_SCALE = 1.0            # was 1.5
VEHICLE_SCALE = 0.833         # real vehicles were authored at 1.2x; becomes 1.0 once H re-exports them
MACHINE_SCALE = 1/20          # construction machines (was 1/16)
AUDIO_UNIT_SIZE = 0.5
CURB_FURNITURE / PED_BAND / FRONT_FURNITURE = [0.305, 0.345] / [0.355, 0.405] / [0.415, 0.49] u from the road centreline
PARK_OFFSET = 0.245 u, PASS_OFFSET = 0.12 u   # curb parking slot; moving lane beside parked cars
```

The full table, with sources, is S0 §4.1. The file ends with one marked section per slice; a slice adds constants only inside its own (S0 §4.3).

Coordinates: tile (x, y) has its centre at world `Vector3(x, 0, y)`. A tile covers `[x-0.5, x+0.5]`. The world spans x, y ∈ [-80, 111]. The built core is 0..31.

## 3. Runtime shape on foot (`fp`)

```
Main (main.gd)                        ← composition root, unchanged except for the S0 hunks
├─ CitySim, GmiClient, CityBrain, AudioDirector, CityView(fp_mode=true), View (orbit rig, disabled), Sun, HUD (CityHud, hidden)
├─ Residents, ResidentMinds, SkyDirector
└─ FpMode (scripts/fp/fp_mode.gd)     ← built only in on-foot play / FP smoke; owns ctx.settings (camera_mode, tps_*, shoulder, hero, …)
   ├─ FpContext (refs to everything; the service locator slices use)
   ├─ GameBus (signals across slices)
   ├─ CollisionWorld (A)              ← analytic ground and walls; sweep_sphere for the camera arm
   ├─ Player (A): FpPlayer (feet; yaw = body yaw)
   │   ├─ Camera3D                    ← the one current camera, shares the Environment; top_level in third person,
   │   │                                 where TpsRig (spring arm, RefCounted) writes its transform each frame
   │   └─ Avatar (player_avatar.gd)   ← CharacterRoot (scale WS.M·h_target/h_rest) → hero GLB (HC) → %GeneralSkeleton
   │                                     + AnimationTree + LookAtModifier3D; legacy person_a.glb placeholder until HC
   │                                     lands; shadow-only in first person
   ├─ Features/ (one node per registered FpFeature: traffic, chat, posters, audio, render_opt, …)
   └─ FpHud (B) CanvasLayer           ← slots: top_bar, minimap, chat, center (prompt; crosshair in first person only), toasts, overlay (pause and map)
```

Camera ownership: A owns every camera behaviour (follow, collision, V toggle, the conversation two-shot on C's `conversation_changed`). No other slice moves `player.camera`.

`FpFeature` lifecycle (base class `scripts/fp/fp_feature.gd`):
`setup(ctx: FpContext)` → `on_world_rebuilt()` (after `view.setup` re-runs on load or new city) → `to_dict()` / `from_dict(d)` (saved under `save["fp"][feature_id]`) → `teardown()`.

## 4. Seams S0 adds to shared or legacy files (the only cross-slice hunks)

- `main.gd`: reads `GRIDFALL_VIEW` after the boot ladder and builds `FpMode` in first person; sets `view.fp_mode` before the first `view.setup` when it will enter FP, so FP geometry is built once. `focus(p, dist)` dispatcher: orbit focuses the camera, first person emits `GameBus.ping(p, reason)` and does not teleport. Save and load include `fp`. Disasters no longer yank the camera in first person.
- `city_view.gd`:
  - `var fp_mode: bool` and `set_fp_mode()`. In first person it hides overlays, the frontier haze ceiling, district border strips and labels, the mayor bots and their bubbles, citizen-voice Label3Ds, the cursor and the event labels. It also disables the anonymous ambient cars and peds (E replaces them).
  - Signals `tile_built(i: int, holder: Node3D)`, `tile_cleared(i: int)`, `world_rebuilt()` and `fp_mode_changed(on: bool)`; flag `in_setup`.
  - Public `building_aabb(i: int) -> AABB` (world space, the whole model including the lot slab; for picking, not for walls or occluders), `site_boxes(i) -> Array[AABB]` (the blocking parts the construction kit drew: hoarding segments, machines, crane mast, …, read from the `colliders` meta that `ConstructionKit.build_site` writes on the holder's `Site` node), `site_bounds(i) -> AABB` (their merged bound) and `tile_holder(i) -> Node3D`.
- `residents.gd`: signals `resident_said(id: String, text: String, kind: String)` (from `say`, `_post_message`, letters) and `trip_started(id: String, from_i: int, to_i: int, mode: String)` (mode always one of car, bus, bike, walk).
- `city_sim.gd`: `var day_seconds: float = SimDefs.BASE_DAY_SECONDS`, read wherever `BASE_DAY_SECONDS` is used today.
- `city_brain.gd` and `sim_defs.gd`: `MAYORS[i]["display"]` (human name). The display name replaces the model name in prompts, `city_log`, `owner_name()` and inspector text. `model` stays for the API. The offline Gazette editorial and the inspector prompt stop saying "AI mayors".
- S0's own FP files also carry shared contracts that slices build on: `GameBus.card_action`, `CityDirectory.planned_name`, `CollisionWorld.boxes()`, `AP.load_scene()` and the GLB node-name prefixes, `FpPlayer.photo_mode`, and the `fp_kit` test context. S0 §23 (D-S0-17 to D-S0-22) lists them.
- `project.godot`: FP input actions (`move_forward`, `move_back`, `move_left`, `move_right`, `sprint`, `crouch`, `jump`, `interact`, `chat_open`, `map_toggle`, `pause_menu`, `time_faster`, `time_slower`, `time_skip`, `photo_mode`, `hud_toggle`, `quick_save`, `quick_load`) and, for D13, the camera actions `view_toggle` (V), `shoulder_swap` (Q), `zoom_in` / `zoom_out` (mouse wheel up / down) and `look_left` / `look_right` / `look_up` / `look_down` (gamepad right stick, dead zone 0.15). The existing `camera_*` actions stay. The integration overview adds `overview_toggle` (Tab, gamepad Back), `site_next` (N), `site_prev` (B), `site_go` (F) and `site_waypoint` (G). Driving adds `vehicle_enter` (F, gamepad Y; on foot it only takes the press with a car in reach, so Y still opens the map elsewhere), `drive_throttle` (right trigger) and `drive_brake` (left trigger); on the keyboard the move keys drive.
- `FpMode.DEFAULT_SETTINGS` (D13): `camera_mode: "third"`, `tps_fov: 60.0`, `tps_distance_m: 3.2`, `shoulder: 1` (right; -1 left), `auto_shoulder: false`, `hero: "m"` (or `"f"`). `"fov"` stays the first-person FOV. `apply_settings(patch, persist := true)`: `persist = false` changes the settings for this run without writing `user://gridfall_fp_settings.json` (the photo tour and `fp_bench` use it).

## 5. Slices (built in parallel after S0)

| Slice | Owns (exclusive edit rights) | Delivers |
|---|---|---|
| **S0 Foundation** (serial, first) | `main.gd`, `project.godot` `[input]`, `scripts/fp/{fp_mode,fp_context,game_bus,fp_feature,fp_features,world_scale,asset_paths,city_directory}.gd`, the §4 seams, a stub file per slice, `tools/gate.sh`, `tools/tests/{parse_all,fp_smoke}*`, `tools/tests/fp_kit.gd` | On-foot boot with a basic walking camera. Clutter hidden. All seams. The gate. D13 hooks: camera settings and actions, the kit's first-person default. |
| **A Player & interaction** | `scripts/fp/player/**` (including `tps_rig.gd`, `spring_math.gd`, `player_avatar.gd`), `scripts/fp/world/collision_world.gd`, `scripts/fp/interact/**` | Kinematic controller: walk, run, crouch, jump, step onto curbs, head bob (first person), building and prop collision, water edge. **Third-person over-the-shoulder camera** (analytic spring arm, collision sweep, recenter, shoulder swap, zoom), **V toggle** to first person, the **hero avatar** (placeholder until HC, then HC's animated hero with head look), the **conversation two-shot**. Interaction with residents, buildings, posters and cars (raises `GameBus` events). Photo mode (free-fly). |
| **B Lean HUD & map** | `scripts/fp/ui/**` except `chat_panel*` | Top indicator chips. Rotating circular minimap (roads, zones, water, player arrow, pings, incidents, nearby cars and people). Full-screen map (M). Compass. Street-name label. Toasts. Interact prompt anchored over its target in third person (crosshair only in first person). Pause menu (resume, save, load, settings for sensitivity, FOV, bob, quality preset and camera, quit to orbit, quit). Time-speed display. No model branding. |
| **C Chat & conversations** | `scripts/fp/chat/**`, `scripts/ai/chatter_minds.gd`, `scripts/fp/ui/chat_panel*` | Clash of Clans–style global chat panel: collapsible, unread badge, role colours, district badges, relative time, system cards, a drip queue so lines don't burst. Chatter minds: residents and mayors talk about real events, gossip, reply to each other and to the player. Player input (Enter). Direct face-to-face conversations: E on a resident opens a dialogue that runs through that resident's mind. Offline templates. Save and load. |
| **D Posters** | `scripts/ai/gmi_image_client.gd`, `scripts/fp/posters/**`, `tools/gmi/generate_posters.py`, `assets/posters/**` | Async HY image client (submit, poll, download, `user://` cache keyed by prompt hash). Poster director: mayor campaigns, Gazette front pages, shop ads using `CityDirectory` names, incident notices, ordinance notices. Surfaces: billboards, bus shelters, walls, hoardings at construction sites. Night lighting. The pre-baked offline set. |
| **E Traffic & pedestrians** | `scripts/fp/traffic/**`, `scripts/world/city_life.gd`, `scripts/world/resident_avatars.gd` | One road-agent system. Residents and ambient walkers drawn with HC's roster bodies and shared animation libraries in four LOD tiers (legacy static people until HC lands). Lane graph (right-hand traffic, turn arcs). IDM car-following. Intersections with traffic lights (4-way) and yield (T). Resident drivers whose trips come from their minds (`trip_started`). Ambient filler traffic and pedestrians on sidewalks. Buses, trucks and emergency crews on lanes. Agents yield to the player. Spinning wheels where the model allows. Keeps `vehicle_counts()`, `visible_count()`, `pick()`, `position_of()` and `select()`. |
| **F Sim performance** | `scripts/sim/city_sim.gd`, `scripts/sim/residents.gd`, `scripts/ai/resident_minds.gd` (perf only) | Time-sliced tick (frame budget ≤ 4 ms in first person, synchronous path kept for tests). A `tick_progress` signal. No stall over 50 ms. |
| **G1 Streetscape & look** | `scripts/world/city_view.gd`, `scripts/world/construction_kit.gd`, `scripts/world/sky_director.gd`, `scenes/main-environment.tres`, `shaders/**`, `textures/real/**` and `env/**` (contents and `.import` params) | Scale fixes (REAL_SCALE, people, vehicles, machines via `WS`). Street-level ground: anti-tiling PBR, curbs, lane markings, crosswalks, sidewalk detail. Street furniture density. Street-name signs at intersections. First-person light profile (shadow distance, SSAO and SSIL radii in units, fog, volumetric fog for night and smog). Weather (clear, overcast, rain with wet roads). A budgeted view-rebuild queue. |
| **G2 Render performance** | `scripts/fp/render/**`, `project.godot` `[rendering]`, `tools/optimize_imports.py`, the `.import` params under `models/**` **except `models/characters/**`** (HC) | Visibility ranges, HLOD and impostors, occluders (applied by a post-pass on `tile_built`). Quality presets (Low, Medium, High) applied at runtime: FSR2, shadow atlas, SSAO, SSIL. VRAM texture compression and mipmaps on imports (an allow-list keeps HC's retarget settings). `fp_bench` perf gate, including a third-person street shot and the animated-people budget. |
| **H Assets** | `tools/blender/**`, `models/real/**`, `scripts/fp/asset_paths.gd` (path list only, except HC's entries) | Vehicles at 1.0× with separate wheel nodes. Traffic lights, street-name signs, bus shelter with a poster panel, billboard with a UV'd poster surface, wall poster frame, crosswalk and curb pieces, fixed door heights. All validated by `validate_real.py`. |
| **HC Characters** (D13) | `tools/characters/**`, `models/characters/**` **including its `.import` files** (the BoneMap retarget settings are content; exception to rule 11), the character entries of `scripts/fp/asset_paths.gd` (`CHARACTERS_DIR`, `CHAR_BODIES_DIR`, `CHAR_ROSTER`, `CHAR_LIB_M`, `CHAR_LIB_F`, `HERO_M`, `HERO_F`, `PERSON_TPS_ANIMS`), `tools/tests/fp_characters_test.gd` | Realistic clothed people from Microsoft Rocketbox (MIT): 2 hero bodies and 38 resident bodies plus far LODs, on Godot's humanoid skeleton. Mocap clips (Rocketbox, plus Quaternius UAL CC0 for jump, crouch, interact, drive, carry) in one shared animation library per gender. `roster.json` with job pools and name genders. Licences and provenance. |
| **I Audio** | `scripts/fp/audio/**`, `sounds/fp/**`, `scripts/audio_director.gd` | 3D positional engines, horns and sirens, footsteps by surface (in step with the hero's stride when the avatar animates), area ambience (traffic hum, park birds, river, construction), and a UI chat blip. Assets synthesized procedurally or with the existing ACE-Step tool. |
| **Integration: city overview** | `scripts/fp/overview/**`, `tools/tests/fp_overview_test.gd` | Tab on foot: an aerial camera over the city (through `FpPlayer.set_view_override`, so `player.camera` stays the one camera) with a marker per open construction site and a site list. N / B pick sites, F walks the hero to a vantage point by the site, G sets a waypoint, Tab or Esc return. "Planner view" leaves for orbit; Tab in orbit comes back to where the hero stood (`Main._fp_saved`). |
| **Integration: driving** | `scripts/fp/drive/**`, `tools/tests/fp_drive_test.gd` | F by a car takes it over (its resident's trip ends; traffic hands over a `player`-role car of the same model that the AI no longer steps). An arcade bicycle model (`drive_model.gd`: throttle, brake, reverse, speed-scaled steering, grip by surface, handbrake slide) moves it through `TrafficFeature.drive_car`; the hero sits in the driver's seat. Chase camera (sweep-checked) or driver view on V, a speedometer and gear chip, crashes bounce off `CollisionWorld` boxes. AI cars and walkers yield to player cars as oriented boxes. F again gets out on the driver's side when slow (under 8.5 m/s) and there is room; a left car is removed once out of range and out of sight. |

## 6. Rules for every slice

1. Work only in your git worktree and branch (`fp/<slice>`). Commit there often. Never touch `main` or `fp/integration`. The integrator merges.
2. Edit only the files your slice owns, plus a new test under `tools/tests/fp_<slice>_test.gd`. If you need a change in someone else's file, write it in `docs/fp/requests/<slice>-needs.md` and build a local fallback.
3. Before you commit, `tools/gate.sh quick` must pass. Before you hand off, `tools/gate.sh full` must pass. Heavy Godot runs take a machine-wide lock (`flock`). Never run two at once.
4. GMI is offline in gates. Never print or log the API key. Never set `GRIDFALL_RECORD=1`.
5. Match the surrounding GDScript style: typed GDScript, tabs, `##` doc comments on classes and public functions, sparse inline comments.
6. Write metres times `WS.M`. Never use a bare magic scale.
7. **Input.** Discrete actions fire only from `_unhandled_input` on `event.is_action_pressed(name) and not event.is_echo()`, never by polling; a UI with a text field catches Esc in `_input()`; tests inject `InputEventAction`s with `Input.parse_input_event` + `Input.flush_buffered_events()` (S0 §7.2).
8. **No FP node under CityView**, except decorations a feature re-attaches to tile holders on every `tile_built`, tags with `fp_owner` meta and frees in `teardown()` (S0 §3).
9. **After a load or New City**, every slice closes its transient UI, pops its modals and drops stored resident dictionaries, on `bus.world_ready` and in `from_dict()`.
10. **Tests build on `fp_kit`.** Use `make_ctx` (with `"grow": true` for a populated city) and assert your fixtures exist before testing them; never pass vacuously on an empty city. Compare engine floats with `is_equal_approx`. Drive time through test hooks or injected clocks, never the wall clock. Movement tests assert against `collision.boxes(i)`, never `view.building_aabb`.
11. **Import parameters** belong to the slice that owns the asset files: G2 `models/**` (except `models/characters/**`), HC `models/characters/**` (retarget BoneMaps, bone renamer, rest fixer and track removal are content), G1 `textures/real/**` and `env/**`, D `assets/posters/**`, I `sounds/fp/**`. Apply G2's settings with `tools/optimize_imports.py --apply <paths>` when the script exists; on `models/characters/**` it touches texture compression and mipmaps only.
12. **Camera mode in tests.** Every test runs in first person through `fp_kit` unless it passes `{"camera_mode": "third"}`; a test that needs third person says so. The FP smoke boots Main with the player's default settings (third person once A lands), so its checks must hold in either camera.

## 7. Integration (the integrator's checklist)

1. Merge S0 first. Then A, B, C, D, E, F, G1 and I in any order, then **G2**, then **H** and **HC** (each rebases onto integration with G2 merged; H re-applies the import settings to its re-exported files, HC runs `--check` on `models/characters/**` and keeps its own retarget settings).
   - **Placeholder, then wire.** A and E build and merge against placeholders (A: the legacy `person_a.glb` avatar; E: the legacy static people) and must pass without `models/characters/**`. After HC merges, two follow-up branches wire the real assets: A's stage A2 (TPS_PLAN T5–T6: `player_avatar.gd` on HC's hero, AnimationTree, head look, conversation two-shot) and E's stage E2 (T8: roster bodies, shared libraries, LOD tiers). Then G2's T9 measures the result (`fp_bench` third-person shot, animation CPU, draws, VRAM). HC's T7 (the 36 remaining resident bodies) may merge after A2 but must precede E2.
2. After every merge: if `tools/optimize_imports.py` exists, run `python3 -I tools/optimize_imports.py --check`; on failure run `--apply`, then a heavy `flock /tmp/claude-1000/gf-heavy.lock godot --headless --path . --import`, and commit the `.import` changes.
3. Then `tools/gate.sh full`. The gate re-imports by itself whenever any `.import` or asset file is newer than its stamp (S0 §18), so a warm worktree never tests against missing assets.
4. Requests between slices live in `docs/fp/requests/`. Recorded agreements already in the specs: E owns all four corners of cross tiles and G1 mounts street-name blades on E's NE light pole; G1 writes `colliders`, `prop` and `poster_slot` metas; E provides `visible_near`, `agents_near` with speeds, `light_pole` and the CityLife and ResidentAvatars `external` hooks. For D13: C is the only emitter of `conversation_changed`, and A (two-shot camera), E (stop and face the player) and I (duck) listen; A takes the NPC head from E's `anchor_of(id)`; A's `FpPlayer.stepped` fires on the hero's foot contacts when the avatar animates; HC supplies `roster.json`, E assigns bodies from it.
