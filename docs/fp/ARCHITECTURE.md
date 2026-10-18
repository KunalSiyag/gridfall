# GridFall: First Person — architecture and build plan

GridFall started as a top-down city builder. This plan turns it into a **first-person exploration of a living AI city**. You walk the streets at eye height. Residents with GMI minds drive their own cars on their own commutes. Mayors campaign on real posters printed by `hy-image-v3.5-preview`. The whole city talks in a Clash of Clans–style global chat.

The sim, the GMI brain and the resident minds stay as they are. This project changes what you see and how you take part.

Research behind every decision below: the subsystem deep-read, with file:line references and measurements, in
`/tmp/claude-1000/-home-kunalsiyag-Ambassador-Gmi-Cloud-gridfall/ed910984-b548-4cd5-88e0-8f11330d4e8e/scratchpad/understand.md`.
Read the sections for your subsystem before you change it.

---

## 1. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | **Keep the world unit: 1 unit = 1 tile = 20 m.** New code writes physical quantities in metres times `WS.M` (`WS.M = 0.05` units per metre), e.g. `var eye := 1.65 * WS.M`. Do not rescale the world or any parent node. | About 2,300 float literals, the Blender exporter (`core.py M = 1/20`), `validate_real.py`, saves and the tools all use tile units. Mixed scales across parallel slices would be far worse. Float precision at \|x\| ≤ 112 is about 0.15 mm, and Godot uses reverse-Z depth. |
| D2 | **No engine physics.** The player is a kinematic controller that collides against an analytic `CollisionWorld`: building body boxes per tile, ground and curb height, water, prop cylinders. Picking is also analytic (ray against the full building AABBs, plus each feature's `pick()` for agents and posters). | The project has no bodies today. Physics engine defaults assume metres (gravity, snap, slop), and thousands of colliders would cost frame time. A grid query is cheap and deterministic in headless tests. |
| D3 | **Two view modes, one composition root.** Normal play boots **first person**. `GRIDFALL_VIEW=orbit`, and every existing tool mode (smoke, photo tour, cinematic), keeps the legacy orbit camera and `CityHud` unchanged. A new `GRIDFALL_FP_SMOKE=1` headless test covers first person. | The existing gates stay green while first person grows next to them. |
| D4 | **Real-time day.** `CitySim.day_seconds` becomes a runtime variable (default 12 s, so orbit and tests are unchanged). First person sets **1,200 s (a 20-minute game day)**. The player can change speed with `[` and `]` (1×, 2×, 4×, 8×), and `T` skips to the next morning. | A 12 s day strobes the sky and forces agents to move at 26–150 m/s. |
| D5 | **Mayors get human display names everywhere the player can see.** Model ids stay internal and are used only for API calls. Lean HUD, chat, posters, world labels and the LLM prompts that produce player-facing text all use the display name: Ada Okafor (argon), Viktor Han (deepseek), Mei Kimura (kimi), Rosa Quintero (qwen), Duke Granger (grok). | The user asked for the distracting model-branded HUD to go. Branding leaks through `city_log`, `owner_name()` and the prompts. |
| D6 | **Lean HUD only in first person.** Top: indicator chips (population, mood, treasury, power, time/day, alerts). Bottom-left: minimap. Global chat panel. Crosshair and interact prompt. No mayor cards, GMI log, model names or tabs. `CityHud` survives only in orbit mode. | The user asked for this directly. |
| D7 | **Feature modules behind seams.** Everything new in first person lives in `scripts/fp/**`. It is built from feature modules registered in one file that S0 pre-populates with stubs, one per slice. A slice edits only its own files plus the shared-file hunks the ownership table assigns to it. | This is the "build vertically" rule, so parallel slices can't break each other. |
| D8 | **One owner per legacy monolith.** `city_view.gd`, `construction_kit.gd`, `sky_director.gd` and `main-environment.tres` belong to G1 (streetscape). `city_life.gd` and `resident_avatars.gd` belong to E (traffic). `city_sim.gd` and `residents.gd` belong to F (sim performance). S0 adds only the seams listed in §4. Every other slice consumes those seams. | Conflicts stay confined to a single slice. |
| D9 | **Offline is first-class.** Every GMI feature has a deterministic offline path: replay cache, heuristics, templates, and a pre-baked poster set under `res://assets/posters/`. Gates always run with `GRIDFALL_OFFLINE=1`. Nobody sets `GRIDFALL_RECORD=1`, because it rewrites the tracked replay cache. | Tests must be free and deterministic, and must not race each other. |
| D10 | **Assets come from headless Blender.** Run `blender --background --python tools/blender/...` and re-run `validate_real.py`. Assets land at the paths in `scripts/fp/asset_paths.gd`, and every consumer falls back if the file is missing. | MCP servers are not available inside workflow agents, and headless runs can be repeated. |
| D11 | **Performance is a feature.** Targets at street level on an RTX 3050 Laptop (4 GB): p50 ≤ 16.7 ms and p99 ≤ 33 ms at 1600×900, under 2,000 draw calls, no single sim stall over 50 ms, VRAM ≤ 1.5 GB. | Today's measurements: 36–41 fps, 5.3 k draw calls, 2.09 GB VRAM, 280–765 ms tick stalls. |
| D12 | **Budgets for paid calls.** Global-chat chatter makes one batched call every 60 s of real time (4–8 lines). A player chat message triggers one call. Each spoken line in a direct conversation triggers one call. Live posters are capped at 6 per game day and 30 per session, and cached forever under `user://posters/`. The pre-baked set is about 24 posters, made once by `tools/gmi/generate_posters.py`. | Spend stays bounded. |

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

## 3. Runtime shape in first person

```
Main (main.gd)                        ← composition root, unchanged except for the S0 hunks
├─ CitySim, GmiClient, CityBrain, AudioDirector, CityView(fp_mode=true), View (orbit rig, disabled), Sun, HUD (CityHud, hidden)
├─ Residents, ResidentMinds, SkyDirector
└─ FpMode (scripts/fp/fp_mode.gd)     ← built only in FP play / FP smoke
   ├─ FpContext (refs to everything; the service locator slices use)
   ├─ GameBus (signals across slices)
   ├─ CollisionWorld (A)              ← analytic ground and walls
   ├─ Player (A): CharacterController + Camera3D (current, shares the Environment)
   ├─ Features/ (one node per registered FpFeature: traffic, chat, posters, audio, render_opt, …)
   └─ FpHud (B) CanvasLayer           ← slots: top_bar, minimap, chat, center (crosshair and prompt), toasts, overlay (pause and map)
```

`FpFeature` lifecycle (base class `scripts/fp/fp_feature.gd`):
`setup(ctx: FpContext)` → `on_world_rebuilt()` (after `view.setup` re-runs on load or new city) → `to_dict()` / `from_dict(d)` (saved under `save["fp"][feature_id]`) → `teardown()`.

## 4. Seams S0 adds to shared or legacy files (the only cross-slice hunks)

- `main.gd`: reads `GRIDFALL_VIEW` after the boot ladder and builds `FpMode` in first person; sets `view.fp_mode` before the first `view.setup` when it will enter FP, so FP geometry is built once. `focus(p, dist)` dispatcher: orbit focuses the camera, first person emits `GameBus.ping(p, reason)` and does not teleport. Save and load include `fp`. Disasters no longer yank the camera in first person.
- `city_view.gd`:
  - `var fp_mode: bool` and `set_fp_mode()`. In first person it hides overlays, the frontier haze ceiling, district border strips and labels, the mayor bots and their bubbles, citizen-voice Label3Ds, the cursor and the event labels. It also disables the anonymous ambient cars and peds (E replaces them).
  - Signals `tile_built(i: int, holder: Node3D)`, `tile_cleared(i: int)`, `world_rebuilt()` and `fp_mode_changed(on: bool)`; flag `in_setup`.
  - Public `building_aabb(i: int) -> AABB` (world space, the whole model including the lot slab; for picking, not for walls or occluders), `site_bounds(i) -> AABB` and `tile_holder(i) -> Node3D`.
- `residents.gd`: signals `resident_said(id: String, text: String, kind: String)` (from `say`, `_post_message`, letters) and `trip_started(id: String, from_i: int, to_i: int, mode: String)` (mode always one of car, bus, bike, walk).
- `city_sim.gd`: `var day_seconds: float = SimDefs.BASE_DAY_SECONDS`, read wherever `BASE_DAY_SECONDS` is used today.
- `city_brain.gd` and `sim_defs.gd`: `MAYORS[i]["display"]` (human name). The display name replaces the model name in prompts, `city_log`, `owner_name()` and inspector text. `model` stays for the API. The offline Gazette editorial and the inspector prompt stop saying "AI mayors".
- S0's own FP files also carry shared contracts that slices build on: `GameBus.card_action`, `CityDirectory.planned_name`, `CollisionWorld.boxes()`, `AP.load_scene()` and the GLB node-name prefixes, `FpPlayer.photo_mode`, and the `fp_kit` test context. S0 §23 (D-S0-17 to D-S0-22) lists them.
- `project.godot`: FP input actions (`move_forward`, `move_back`, `move_left`, `move_right`, `sprint`, `crouch`, `jump`, `interact`, `chat_open`, `map_toggle`, `pause_menu`, `time_faster`, `time_slower`, `time_skip`, `photo_mode`). The existing `camera_*` actions stay.

## 5. Slices (built in parallel after S0)

| Slice | Owns (exclusive edit rights) | Delivers |
|---|---|---|
| **S0 Foundation** (serial, first) | `main.gd`, `project.godot` `[input]`, `scripts/fp/{fp_mode,fp_context,game_bus,fp_feature,fp_features,world_scale,asset_paths,city_directory}.gd`, the §4 seams, a stub file per slice, `tools/gate.sh`, `tools/tests/{parse_all,fp_smoke}*` | First-person boot with a basic walking camera. Clutter hidden. All seams. The gate. |
| **A Player & interaction** | `scripts/fp/player/**`, `scripts/fp/world/collision_world.gd`, `scripts/fp/interact/**` | Kinematic controller: walk, run, crouch, jump, step onto curbs, head bob (toggle), building and prop collision, water edge. Centre-screen interaction with residents, buildings, posters and cars (raises `GameBus` events). Photo mode (free-fly). |
| **B Lean HUD & map** | `scripts/fp/ui/**` except `chat_panel*` | Top indicator chips. Rotating circular minimap (roads, zones, water, player arrow, pings, incidents, nearby cars and people). Full-screen map (M). Compass. Street-name label. Toasts. Pause menu (resume, save, load, settings for sensitivity, FOV, bob and quality preset, quit to orbit, quit). Time-speed display. No model branding. |
| **C Chat & conversations** | `scripts/fp/chat/**`, `scripts/ai/chatter_minds.gd`, `scripts/fp/ui/chat_panel*` | Clash of Clans–style global chat panel: collapsible, unread badge, role colours, district badges, relative time, system cards, a drip queue so lines don't burst. Chatter minds: residents and mayors talk about real events, gossip, reply to each other and to the player. Player input (Enter). Direct face-to-face conversations: E on a resident opens a dialogue that runs through that resident's mind. Offline templates. Save and load. |
| **D Posters** | `scripts/ai/gmi_image_client.gd`, `scripts/fp/posters/**`, `tools/gmi/generate_posters.py`, `assets/posters/**` | Async HY image client (submit, poll, download, `user://` cache keyed by prompt hash). Poster director: mayor campaigns, Gazette front pages, shop ads using `CityDirectory` names, incident notices, ordinance notices. Surfaces: billboards, bus shelters, walls, hoardings at construction sites. Night lighting. The pre-baked offline set. |
| **E Traffic & pedestrians** | `scripts/fp/traffic/**`, `scripts/world/city_life.gd`, `scripts/world/resident_avatars.gd` | One road-agent system. Lane graph (right-hand traffic, turn arcs). IDM car-following. Intersections with traffic lights (4-way) and yield (T). Resident drivers whose trips come from their minds (`trip_started`). Ambient filler traffic and pedestrians on sidewalks. Buses, trucks and emergency crews on lanes. Agents yield to the player. Spinning wheels where the model allows. Keeps `vehicle_counts()`, `visible_count()`, `pick()`, `position_of()` and `select()`. |
| **F Sim performance** | `scripts/sim/city_sim.gd`, `scripts/sim/residents.gd`, `scripts/ai/resident_minds.gd` (perf only) | Time-sliced tick (frame budget ≤ 4 ms in first person, synchronous path kept for tests). A `tick_progress` signal. No stall over 50 ms. |
| **G1 Streetscape & look** | `scripts/world/city_view.gd`, `scripts/world/construction_kit.gd`, `scripts/world/sky_director.gd`, `scenes/main-environment.tres`, `shaders/**`, `textures/real/**` and `env/**` (contents and `.import` params) | Scale fixes (REAL_SCALE, people, vehicles, machines via `WS`). Street-level ground: anti-tiling PBR, curbs, lane markings, crosswalks, sidewalk detail. Street furniture density. Street-name signs at intersections. First-person light profile (shadow distance, SSAO and SSIL radii in units, fog, volumetric fog for night and smog). Weather (clear, overcast, rain with wet roads). A budgeted view-rebuild queue. |
| **G2 Render performance** | `scripts/fp/render/**`, `project.godot` `[rendering]`, `tools/optimize_imports.py`, the `.import` params under `models/**` | Visibility ranges, HLOD and impostors, occluders (applied by a post-pass on `tile_built`). Quality presets (Low, Medium, High) applied at runtime: FSR2, shadow atlas, SSAO, SSIL. VRAM texture compression and mipmaps on imports. `fp_bench` perf gate. |
| **H Assets** | `tools/blender/**`, `models/real/**`, `scripts/fp/asset_paths.gd` (path list only) | Rigged and animated people (walk, idle, sit or talk). Vehicles at 1.0× with separate wheel nodes. Traffic lights, street-name signs, bus shelter with a poster panel, billboard with a UV'd poster surface, wall poster frame, crosswalk and curb pieces, fixed door heights. All validated by `validate_real.py`. |
| **I Audio** | `scripts/fp/audio/**`, `sounds/fp/**`, `scripts/audio_director.gd` | 3D positional engines, horns and sirens, footsteps by surface, area ambience (traffic hum, park birds, river, construction), and a UI chat blip. Assets synthesized procedurally or with the existing ACE-Step tool. |

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
11. **Import parameters** belong to the slice that owns the asset files: G2 `models/**`, G1 `textures/real/**` and `env/**`, D `assets/posters/**`, I `sounds/fp/**`. Apply G2's settings with `tools/optimize_imports.py --apply <paths>` when the script exists.

## 7. Integration (the integrator's checklist)

1. Merge S0 first. Then A, B, C, D, E, F, G1 and I in any order, then **G2**, then **H** (H rebases onto integration with G2 merged and re-applies the import settings to its re-exported files).
2. After every merge: if `tools/optimize_imports.py` exists, run `python3 -I tools/optimize_imports.py --check`; on failure run `--apply`, then a heavy `flock /tmp/claude-1000/gf-heavy.lock godot --headless --path . --import`, and commit the `.import` changes.
3. Then `tools/gate.sh full`. The gate re-imports by itself whenever any `.import` or asset file is newer than its stamp (S0 §18), so a warm worktree never tests against missing assets.
4. Requests between slices live in `docs/fp/requests/`. Recorded agreements already in the specs: E owns all four corners of cross tiles and G1 mounts street-name blades on E's NE light pole; G1 writes `colliders`, `prop` and `poster_slot` metas; E provides `visible_near`, `agents_near` with speeds, `light_pole` and the CityLife and ResidentAvatars `external` hooks.
