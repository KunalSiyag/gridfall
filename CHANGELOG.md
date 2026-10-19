# Changelog

All notable changes to GridFall. Generated from conventional commits by tools/changelog.py.

## [Unreleased] - 2026-10-20

### Features

- **fp**: city overview to watch construction, Tab between street and top views (f78e62e)
- **fp/A**: both crouching feet on the ground, camera fade check (d75726e)
- **fp/A**: grounded crouch and landing, moving landings, walk and run photo shots (8414d05)
- **fp/A**: HC's animated hero on the player (stage A2) (93e732d)
- **fp**: H real-size parked cars in the zone generator (re-export deferred) (ced264b)
- **fp**: G1 props fade at the lens, metric lawns, textured kerb ramps and tactile paving (2e2fd7f)
- **fp/I**: rain and wet steps, passers-by footsteps, calmer horns and blips (295f0d4)
- **fp**: H vehicles_v2 at 1.0x and the street kit (3d1df9c)
- **fp/E**: lamps and headlight beams after dark, signals beside the zebras, light street bubbles (e02fcd4)
- **fp/I**: positional city audio, area beds, footsteps and on-foot routing (3b9e689)
- **fp**: G1 street-level asphalt, lamps on unlit straights, lamplight decals, damp walls (e70773d)
- **fp/D**: poster director, surfaces, compositor, viewer and save (a25919e)
- **fp/G2**: mid-LOD twins for road pieces; G1 mode-switch guards (b1bc48a)
- **fp**: B full map hover card names what is under the cursor (6898c31)
- **fp**: B district caption on arrival and on entering a district (ae00f7e)
- **fp/G2**: merged mid-LOD building twins; G1-matched windows and glass (cbd204a)
- **fp/E**: density where it is seen, traffic photo at a red light, crew A* budget (0e20963)
- **fp/E**: walking placeholder people, lamps on far cars after dark, waiting crowds (05d428a)
- **fp/G2**: fp_bench presets, third-person row, enforce mode (414a2af)
- **fp/A**: hero head look, turn-in-place steps, idle breathing (c4f8930)
- **fp/G2**: quality presets, visibility ranges, chunk impostors and occluders (4c29c2a)
- **fp/G2**: optimize_imports.py; VRAM-compressed, mipmapped model textures (404b94a)
- **fp**: B compass on a soft band, markers on the strip, white distances (3a69ed3)
- **fp/D**: HY image client, pre-baked poster set and generator (8039d54)
- **fp/A**: jointed placeholder hero with a procedural gait (0d197fd)
- **fp/F**: spread sources for day-start listeners besides the minds (052cd26)
- **fp/F**: public Residents.remember and nudge_mood for slice C (eac9f49)
- **fp**: B map renders joined city blocks, varied footprints, solid wide roads (b0a96a9)
- **fp/A**: traffic blockers, camera pull-in out of cars, perf checks, requests (8a5daa1)
- **fp/E**: lane graph, junctions, IDM traffic, pedestrians, resident trips, fleets (021d083)
- **fp**: G1 tool runs pin clear weather; subtler rain streaks (9ba0c9f)
- **fp**: B GPS route to the waypoint on the minimap and the map (7c8ebe4)
- **fp/C**: @-mentions with Tab, Tab never closes a text field (6c0bb33)
- **fp**: G1 trees, glass, windows, foliage and a pure-sky dusk on foot (d22202a)
- **hc**: 38 resident bodies, far LODs and the full roster (2cca43c)
- **fp/A**: third-person controller, V toggle, two-shot and interaction (1283e3a)
- **fp/A**: building bodies, props, soft step, sweep_sphere and the TPS rig (b565012)
- **fp/C**: single-Control chat rows, ticker, natural offline voices (56fe167)
- **fp**: B compact money, redraw guards, requests to A, C, E, G2, I (8c2eb61)
- **fp/F**: sim_perf feature and slice F acceptance test (8468e77)
- **fp**: G1 light profile, weather, street lights, construction kit at street scale (b5263c0)
- **hc**: character pipeline, hero bodies and shared animation libraries (889fe86)
- **fp/C**: global chat panel, talk dialogue and chat feature (26e9ed3)
- **fp/C**: chat display filter, drip feed and chatter minds (b1dd3bc)
- **fp**: G1 street level ground, water, furniture and rebuild queue (6b3d66e)
- **fp**: B lean HUD, minimap, map, prompt, pause menu and place card (c451b2a)
- **fp**: S0 third-person hooks (D13) (815c682)
- **fp**: first-person boot with FpMode, player, collision and HUD shell (861d23a)
- **fp**: world scale, asset paths, road topology and city directory (d3aa434)
- **fp**: S0 seams in legacy sim, AI and view files (909b9df)

### Bug fixes

- **fp**: tests accept H's atlas-masked emission and nested SignText empties (35c53c7)
- **fp**: fp_audio_test polls a plain walker now that FpPlayer has stepped (eb0cef5)
- **fp**: G1 lamp heads baked into model bodies follow the night on foot (4d5ac05)
- **fp/E**: headlight beams fall off gently, so people in front of a car are lit, not blown out (15cff5d)
- **fp**: G1 asphalt noise, iron covers, unlit lamps by day, softer near rain (c180c71)
- **fp**: H far LODs in flat colour groups for E's merge (5df8e1c)
- **fp/D**: night glow, async composite readback, nearest-first composites (ac6c717)
- **fp/E**: a zebra crowd steps off staggered and keeps its spread (1d44d84)
- **fp/E**: bus lines that survive road changes, room past short lanes, chats, sirens (45b3d65)
- **fp**: B interact prompt is sentence case (ada2f61)
- **fp**: B minimap car blips no longer bead the roads (f60e86b)
- **fp**: G1 leaf cards whole again, leafy hedges, tree grates, knitted site netting (96821ea)
- **fp**: B compass distance labels slide aside instead of vanishing (03157c5)
- **fp**: B vehicle card shows no mood for a driverless car (c4bc2d9)
- **fp**: G1 warm-up waits for its own threaded load, headless loads on the main thread (1e9bca9)
- **fp/C**: spread public letters, honest decree refusals, motion polish (819ba83)
- **fp**: B layout and map polish from the first screenshots (774df9f)
- **fp**: S0 fix round 3 (long-frame tunnelling, HUD test seams) (70ef6b4)
- **fp**: S0 fix round 2 (site colliders from the kit, stretch-free mouse look) (c6ec74b)
- **fp**: S0 fix round 1 (pause, time, traps, de-branding, render size) (a78c3e9)
- **fp**: frame the downtown shot from across the street; -$ funds (b7e6144)
- **fp**: parse_all skips reloading its own running script (6f521d0)

### Performance

- **fp/I**: per-frame emitter work scales with the pool, not the city (b3e2bb9)
- **fp/E**: place cached lane shapes with one native transform (d4d8676)
- **fp/E**: skip people out of drawing range, softer siren wash at night (b8ae4ab)
- **fp**: G1 merged construction sites, E's corner poles, G2 texture rules, smog volumes (072d116)
- **fp/G2**: report render_opt's own frame and post-pass cost (c3f1b07)
- **fp/E**: tiered simulation LOD with drawn extrapolation, one agent snapshot per frame (946279d)
- **fp/E**: cached lane geometry, conflict points in the box, patient yields (d0681d8)
- **fp/F**: report the forced-finish count in slice_stats and self_test (43b281c)
- **fp**: G1 far trees as card impostors, batched aprons, models load on demand (f9041fc)
- **fp/F**: predict each pump step from its own step kind (7aa05a1)
- **fp/F**: spread incident reactions over frames in sliced mode (6985dd3)
- **fp**: B halves the HUD's draw calls; compass and vehicle card polish (fdee2e0)
- **fp/F**: tune sliced work units, frame-aware pumps, profiling (42ecb7d)
- **fp/F**: prune and skip the session cache flush (87b6238)
- **fp/F**: resumable sliced sim tick with exact sync equivalence (5ffd3a4)

### Documentation

- **fp/G2**: requests to the integrator, G1, H, E and A (86e0f3c)
- **fp**: B notes to E and C (blips, driverless mood, caption corner) (fb8a8da)
- **fp/F**: cold building-model loads are the worst day-end frames (to G1) (2be708c)
- **fp/F**: requests to S0, G1 and G2 with frame measurements (a17f115)
- **hc**: usage notes and requests for A, E and G2 (17b8d73)
- **fp**: D13 third-person default and slice HC (96b71e8)
- **fp**: architecture, S0 spec and slice contracts (a32657a)

### Tests

- **fp**: B minimap draws E's agents_near and visible_near (296a8c9)
- **fp/A**: fp_player_test; escape-point walk-out, eye height in simulate (d1a5cf9)
- **fp/F**: track fp_simperf_test uid (8ed03e4)
- **fp**: gate script, parse_all, fp_kit, S0 tests, FP smoke and photo tour (aa1f9d5)

### Chores

- **fp**: apply G2 import settings to H vehicles_v2 and street textures (ecc0285)

### Other changes

- Add MIT license (611d727)
- Add v4 showcase screenshots: chaos director, fire response, transit (c0c6979)
- Add v4 screenshots: matte roofs, staged construction, frontier haze (53394b2)
- Matte roofs, slow gradual construction, 192x192 frontier world (1d8adf5)
- a SimCity-style city run by GMI Cloud AI mayors and residents (ba1636e)
