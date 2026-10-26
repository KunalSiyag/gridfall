# Slice B: Lean HUD and map

Branch `fp/B-hud`, branched from `fp/integration` after S0. Read ARCHITECTURE D5, D6 and D13, then S0 §§9, 13 and 14.

## Goal (what the player sees)

A calm, glanceable, AAA-lean HUD (think GTA V or Watch Dogs: the world first, a few quiet indicators) with no AI or model branding anywhere. Today's S0 placeholder is one plain text line across the top (`Day 6 · 10:30 · Pop 1,168 · Mood 6.1/10 · -$3,222 · 1x`, see `/tmp/claude-1000/gf-gate-s0-render2/photos/street_hud.png` and `downtown_hud.png`) with no minimap; B replaces all of it:

- **Top bar.** Indicator chips for population, mood (0–10, with a face icon that changes colour), treasury, power, water, time and day (`Day 4 · 09:15`, plus the speed `2×`), and alerts (the active incident count with the latest label).
- **Bottom-left.** A rotating circular minimap: roads, zones, water, buildings, the player arrow, pings, incidents, and nearby cars and people.
- **Full-screen map on M.** It pans and zooms, and shows district names, street names (from the directory), incidents and the player. A click sets a waypoint ping.
- **Compass strip** with ping and waypoint markers.
- **Street-name label**, for example `Maple Street & Delgado Avenue`, shown under the minimap.
- **Toasts and an alert banner.**
- **Interact prompt.** In third person (the default, D13) there is **no crosshair** (at most a 4 px dot, off by default) and the prompt floats **over the target** itself; in first person a small centre crosshair and a prompt under it.
- **Pause menu on Esc:** Resume, Save, Load, Settings, Quit to orbit, Quit. Settings has sliders for mouse sensitivity and FOV, toggles for invert Y, head bob and show HUD, a quality preset (Low/Medium/High), music and SFX volume, and a **Camera** group: view (third / first person, also on V), third-person FOV, camera distance, shoulder (right / left, also on Q), auto shoulder swap, and the hero (male / female).
- **Place cards** for buildings and vehicles when the player presses E.
- A small time-speed indicator.

## Owned files (exclusive)

- `scripts/fp/ui/**` **except** `scripts/fp/ui/chat_panel*`, which C owns. This includes S0's `fp_hud.gd`: keep `class_name FpHud`, `setup(ctx)` (FpMode and `fp_kit` call it), `layer = 10` with `PROCESS_MODE_ALWAYS` (the smoke checks the HUD runs while paused), the `SLOTS` names, `slot()`, `set_hud_visible()`, `is_hud_visible()` and `show_toast()`. S0's `fp_core_test` reads toasts only through `slot("toasts")`: within 10 frames of `bus.toast`, some `Label` or `RichTextLabel` under that slot shows the de-branded text. S0's FP smoke (which B may not edit) reads the top bar only through `slot("top_bar")`: the visible `Label`s and `RichTextLabel`s under it must together show `Day <n>` (the smoke polls for up to 1 s, so a 0.25 s refresh is fine), and none of them, visible or not, may carry a brand word. Nothing else in the placeholders is a contract. The `chat_slot` geometry is shared with C; change it only by agreement, recorded in `docs/fp/requests/`.
- `scripts/fp/ui/hud_widgets_feature.gd` (feature id `hud_widgets`).
- `tools/tests/fp_hud_test.gd`.
- New UI assets under `ui/fp/**` (icons, shaders). Fonts are reused from `res://fonts/`.

## Seams consumed

| From | API |
|---|---|
| `CitySim` | `stats` (population, happiness, power_need/cap, water_need/cap, unpowered, unwatered, unemployment), `stats_updated` (emitted every tick, `city_sim.gd:2352`), `day`, `total_funds()`, `events`, `event_started`/`event_ended`, `tiles_changed(indices)`, `territory_changed`, `kind`/`level`/`terrain`/`district`/`burning` PackedArrays, `is_surveyed(x,y)`, `waiting_for_ai` |
| `Residents` | `is_active()`, `sentiment.mood` (0..1), `district_mood(d)`, `people` (dot positions: see deliverable 3; never `position_of` for hidden or unknown ids) |
| `SkyDirector` | `clock_text()`, `night` |
| `CityDirectory` | `street_at(p)`, `intersection_name`, `district_name`, `place_label`, `address`, `business_name`, `landmark_name`, `mayor_display` |
| `SimDefs` | `MAYORS[d].display`, `.color`, `.district`, `debrand()`, `idx/tx/ty`, `X0`/`Y0`/`W`/`H` |
| Settings (D13) | `camera_mode` (`"third"` / `"first"`), `tps_fov`, `tps_distance_m`, `shoulder`, `auto_shoulder`, `hero` (B writes them through `mode.apply_settings()` and reads `camera_mode` for the crosshair and the wheel) |
| `FpContext` / `FpMode` | `player` (position, yaw, `photo_mode`, `camera` for `unproject_position` / `is_position_behind`), `mode.time_scale`, `mode.set_paused()`, `mode.apply_settings()`, `settings`, `push_modal`/`pop_modal`, `main.save_game()`/`load_game()`/`exit_fp()` (deferred, see deliverable 10), `features` (E's `traffic` feature for nearby agent dots, via the optional `agents_near(p, r) -> Array[Dictionary]`, and resident dots via the optional `visible_near(p, r)`; draw nothing from E when it is absent) |
| `GameBus` | listens to `ping`, `toast`, `interact_target_changed` (the target dict's `pos` is the world anchor for the floating prompt), `interact_requested` (kinds `building`, `vehicle`, `pedestrian`; kind `resident` belongs to C), `player_tile_changed`, `time_scale_changed`, `pause_changed`, `settings_changed`, `world_ready`, `chat_posted` (optional unread dot); emits `ping(pos, "player")` for map waypoints and `card_action("ask_here", tile)` from the place card |
| `CityView` | nothing (the minimap reads sim arrays, never the scene) |

## Seams B may request

- E: `agents_near(p, r)` (fields in E's contract: `id`, `pos`, `kind`, `driver_id`, `heading`, `speed`, `vel`) and `visible_near(p, r) -> Array[{"id", "pos"}]` on the traffic feature. Both are already in E's spec.
- C: the `chat_slot` geometry, and whether the minimap unread badge is wanted.
- S0: none expected. FpHud is B's.

## Deliverables

1. **`fp_hud.gd`.** Replace S0's placeholders with the real layout. Keep the slot API.
   - **AAA lean look.** The world is the hero; the HUD is quiet:
     - No heavy panels. Chips are icon + value pills with at most a `Color(0.04, 0.05, 0.08, 0.35)` backing (or none), white text with a 1–2 px dark outline or soft shadow so it reads against bright sky and dark asphalt. Panels that hold controls (pause menu, card, map) may use the old BG `Color(0.055, 0.07, 0.11, 0.78)`.
     - Colour signals state only: white for normal, amber `#FFB547` for a warning, red `#FF5A5A` for a failure, the accent `#00E0FF` sparingly (the player arrow, the waypoint). No rainbow of chip colours.
     - Icons, not labels: a person for population, a face for mood, a coin for money, a bolt for power, a drop for water, a clock for time. A tooltip in the pause menu explains them.
     - Numbers in a font with tabular figures (Lilita One where it has them, else the project's UI font), compact formats (`1,168`, `$3.2k`, `−$3,222`).
     - Safe margins: 24 px from the screen edges at the 1600×900 base (the root stretches `canvas_items`, so sizes scale with the window).
     - Calm motion: a value change pulses its chip for 0.3 s; toasts slide and fade over 0.2 s; nothing blinks except a new red alert, twice.
     - Copy the helper functions (`_panel`, `_label`, `_fmt`) from `city_hud.gd:1124-1207` and restyle them; do not reference `CityHud`.
   - **Every passive control** uses `MOUSE_FILTER_IGNORE`.
2. **Chips.** Refresh on `stats_updated` and `time_scale_changed`, and every 0.25 s for the clock.
   - Mood: `sentiment.mood * 10` when residents are active, otherwise `stats.happiness * 10`.
   - Power and water are green, amber when need exceeds 0.85 × cap, and red when need > cap or anything is unpowered or unwatered (the `_set_util` formulas at `city_hud.gd:810-817`).
   - Alerts show the count, and the label of the newest event is debranded.
   - While `sim.waiting_for_ai`, show a small `"City hall in session"` dot.
3. **Minimap** (`scripts/fp/ui/minimap*.gd`):
   - A 192×192 `Image` painted from `kind`, `level`, `terrain` and `district`.
   - Repaint only the indices from `tiles_changed` and the plots on `territory_changed`. Do a full repaint on `world_ready`.
   - Display it in a 200 px circle at the top of `minimap_slot` (a TextureRect with a circular-mask shader, a soft edge and a thin ring, no square frame). Rotate it so the **view** heading points up: `yaw = atan2(−f.x, −f.z)` from `player.forward()`, which is the camera look direction in both cameras (A keeps that contract; in third person the body may face elsewhere), at 3.5 px per tile by default. The scroll wheel cycles 2, 3.5 and 6 **only in first person**: in third person the wheel is A's camera zoom (`zoom_in` / `zoom_out`), and the minimap keeps its scale (B listens to neither action; it reads the wheel only while `settings.camera_mode == "first"`). **Convention:** forward is `(-sin yaw, 0, -cos yaw)` (S0 §11), so `yaw = π/2` faces west (−X). Image rows grow toward +Z (north up when unrotated). The heading is up when `TextureRect.rotation = +yaw` about the centre (equivalently a UV rotation of `−yaw` in the shader). A probe confirmed that `Control.rotation = +π/2` moves a pixel left of centre to directly above it.
   - Markers are drawn in `_draw` at 10–15 Hz: player arrow, pings (fading over 30 s), incidents from `sim.events`, residents within 20 tiles, and E's agents. Resident dots come from E's `visible_near(p, 20)` when present; otherwise from **one pass** over `residents.people` that skips residents with an empty `route` whose state is indoors (`ResidentAvatars.INSIDE` or `"visiting…"`, `resident_avatars.gd:13,204`). Never call `avatars.position_of` for them: it returns the home or work tile centre for indoor residents (a dot on every home) and costs a linear `people.find` each (≥ 0.5 ms per 100 in a probe, over the 0.3 ms budget).
   - Unsurveyed plots are drawn hazed (`is_surveyed`).
   - **Never use a second Camera3D or SubViewport render of the city.**
4. **Full map on M.** Push the modal `&"map"`. It shows the same image at large size, plus district names, streets labelled at zoom ≥ 6 px per tile, and incidents. Dragging pans and the wheel zooms. Left click emits `ping(world, "player")` and stores a waypoint, which the compass and minimap show. Esc or M closes it; Esc is handled and consumed by the map.
   - **Input** (S0 §7.2): `map_toggle`, and every close key of every B UI, fire only from `_unhandled_input` on `event.is_action_pressed(…) and not event.is_echo()`, and the handler calls `set_input_as_handled()`. Never poll. M is ignored while another modal (chat, talk) is open or in photo mode.
5. **Compass strip.** Cardinal letters, plus the waypoint and up to 3 ping markers with their distance in metres (`dist / WS.M`).
6. **Street label.** On `player_tile_changed`, show `directory.street_at(player.position)`, fading in over 0.3 s. It sits inside `minimap_slot`, below the 200 px circle (slot y 216–236), because the slot ends 16 px above the screen bottom.
7. **Toasts and banner.**
   - At most 3 toasts on screen, each with a 4 s life, and identical consecutive toasts collapse into one.
   - `ping` with an `event:` reason becomes a red banner, for example `"Fire reported near 214 Maple Street"`, built with `directory.place_label`.
   - Every string goes through `SimDefs.debrand()`.
8. **Interact prompt and crosshair**, driven by `interact_target_changed` and `settings.camera_mode`:
   - **Third person:** no crosshair (an optional 4 px dot at 60 % alpha, off by default; a setting is not required). The prompt chip (`"E  Talk to Priya Gupta, nurse"`, the key in a small key-cap) floats **over the target**: every frame, `ctx.player.camera.unproject_position(target.pos + up * lift)` with `lift = 0.25 * M` above a resident's head anchor (`pos`) and 0 for other kinds; clamp to the screen inside the 24 px safe margin; hide it while `camera.is_position_behind(anchor)` or the anchor is off screen by more than the clamp. Smooth the screen position with a 0.05 s halflife so it does not jitter with the spring arm.
   - **First person:** the centre crosshair (a dot that grows slightly when a target exists) and the prompt chip just below it.
   - The prompt fades in over 0.12 s and out over 0.08 s. In photo mode, under any modal and during A's conversation camera it is hidden.
   - Switching cameras (V) moves the prompt to the new rule within one frame.
9. **Place card** (overlay) on `interact_requested`:
   - **Building:** place name, address, district, a density line, the residents who live or work there (from `residents.people` where home or work equals the tile, at most 6 names), and status (powered, watered, on fire, under construction from `sim.site_info(i)`). An **"Ask someone here"** button emits `bus.card_action("ask_here", tile)` and closes the card; C answers in its own dialogue. B makes no LLM call itself.
   - **Vehicle:** the target's `label` and `data` from E. For example, `"Priya Gupta, nurse · driving to work · mood 7/10"`.
   - **Pedestrian:** only ambient walkers reach B (`"a pedestrian"`). Kind `resident` is never B's: C opens a conversation for it.
   - No LLM call, no model and no source fields. It closes with E or Esc from `_unhandled_input` (consumed), and pushes the modal `&"card"`. A ignores the interact press in the frame the card pops its modal, so the card does not reopen.
10. **Pause menu** on `pause_changed(true)`. FpMode owns the `&"pause"` modal; B never pushes or pops it.
    - Resume calls `mode.set_paused(false)`.
    - Save and Load call `main.save_game()` / `load_game()`. They already notify through `bus.toast` (S0 §6.2), so B adds no toast of its own.
    - Settings writes through `mode.apply_settings()`, including the Camera group (`camera_mode`, `tps_fov` 50–75°, `tps_distance_m` 1.6–5.0, `shoulder` ±1, `auto_shoulder`, `hero` `"m"` / `"f"`). A applies them on `settings_changed`.
    - "Quit to orbit" calls `ctx.main.call_deferred("exit_fp")`: `exit_fp()` frees FpHud, which Godot refuses inside the button's own `pressed` emission. "Quit" calls `get_tree().quit()`.
    - It is keyboard navigable. Esc closes the menu and is consumed.
11. **After a load or New City** (S0 §7.2): on `bus.world_ready` and in `hud_widgets.from_dict()`, close the card and the full map, pop `&"card"` and `&"map"` if pushed, and repaint.
12. **`hud_widgets_feature.gd`.** Wires the minimap model, the waypoint state and saves the waypoint in `to_dict` (`{"waypoint": [x, z]}`).

## Acceptance tests

`tools/tests/fp_hud_test.gd`, token `FP_HUD_TEST: PASS`. It uses `fp_kit.make_ctx(root, {"grow": true})` (it includes `sky`, the stub `mode`, the player and the HUD) and `make_feature(ctx, "hud_widgets")`. Its assertions:

- **No branding.** After a forced `stats_updated`, collect the text of every `Label`, `RichTextLabel` and `Button` **that B created** (B tags its nodes, for example with `set_meta("fp_owner", "hud_widgets")`, and skips anything under C's chat panel, D's viewer, or the pause menu's **GMI Cloud** settings page — that page is the one piece of B chrome that names the service it configures, and its widgets carry `fp_owner = "gmi_key"` instead). None matches `/(Argon|DeepSeek|Kimi|Qwen|Grok|GMI|gemini|MiniMax|model|latency|cache|heuristic)/i`.
- **Chips.**
  - The population chip shows `sim.stats.population` with separators.
  - Mood equals `round(sentiment.mood*10, 1)` when residents are active.
  - Forcing `stats.power_need = power_cap + 1` and emitting `stats_updated` turns the power chip red.
- **Minimap image.**
  - The pixel at a road tile has the road colour, a water tile the water colour, and a C level-2 tile the C colour.
  - Changing one tile's kind and emitting `tiles_changed([i])` repaints only that pixel. Count it with a test hook `repainted_count`.
- **Rotation (behaviour, not a sign).** After `player.teleport(player.position, 90.0)` (facing west; `teleport` sets both the body and the camera yaw), the tile 5 tiles west of the player is drawn directly above the minimap centre: `|dx| < 1 px` and `dy < 0` after applying the minimap's transform. With `yaw = 0` the tile 5 tiles north (−Z) is above.
- **Pings.** `bus.ping.emit(Vector3(16,0,14), "event:fire")` adds one marker and one banner. The banner text contains a directory place label and no `"(16,14)"`-style coordinates.
- **Toasts.** 5 toasts in one frame show at most 3, and duplicates collapse.
- **Pause and settings.** `ctx.mode.set_paused(true)` (the kit's stub mode pushes `&"pause"` itself) shows the menu; B pushes no modal of its own for it. A settings slider change appends the patch to `ctx.mode.settings_log`. Save and Load produce exactly one toast each.
- **Street label.** `player_tile_changed` on a road tile updates the label to `directory.street_at`.
- **Prompt anchoring (third person).** With `make_ctx(…, {"camera_mode": "third"})`, a camera placed by the test and a target at a known `pos`, emitting `interact_target_changed(target)` puts the prompt's centre within 2 px of `camera.unproject_position(pos + lift)` (after the smoothing settles), shows no crosshair, and hides the prompt when the target is moved behind the camera. With `camera_mode = "first"` (patched through `mode.apply_settings`) the crosshair is visible and the prompt sits under the screen centre.
- **Wheel.** In third person a wheel event leaves the minimap scale unchanged; in first person it cycles 3.5 → 6.
- **Place card.** For a C lot, the card shows the business name and address, and no LLM call is made (count calls through a `GmiClient` stub injected with `make_ctx(…, {"client": stub})`). Pressing its "Ask someone here" button emits `card_action("ask_here", tile)` once. An interact event delivered with `Input.parse_input_event` + `Input.flush_buffered_events()` closes the card and pops `&"card"`.
- **Reload.** With the card and the map open, emitting `bus.world_ready` closes both and leaves `ctx.is_modal()` false.

FP smoke: the `hud_widgets` `self_test()` checks that the minimap texture exists, its size is 192×192, the chips are present, and no branding regex matches.

Photo tour: the `*_hud.png` shots show the chips top-centre, the minimap bottom-left, and the compass and street label. A's `tps_*_hud.png` shots (third person) show no crosshair. Run `tools/gate.sh render`, look at the shots, and attach two `_hud` shots (one third-person when A's shots exist) to the hand-off. Judge the look against the AAA-lean rules of deliverable 1: nothing should read as a debug overlay.

## Performance budget

- The HUD costs at most **1.0 ms per frame** in total.
- A minimap marker redraw costs at most 0.3 ms at 15 Hz. An incremental repaint costs at most 0.2 ms per `tiles_changed`; a full repaint is at most 15 ms, and only on `world_ready`.
- No per-frame string formatting outside the 4 Hz chip refresh.
- No RichTextLabel re-parse per frame.

## Risks

- **Mouse handling.** A `MOUSE_FILTER_STOP` under the crosshair eats clicks while the mouse is captured. Only modal UIs may use STOP.
- **Esc routing.** Esc must close the open modal UI first, mark the event handled, and only otherwise reach FpMode's pause toggle. B's UIs have no text field, so `_unhandled_input` is enough (a focused LineEdit would need `_input`, see C).
- **Mood source.** Mood comes from two sources (residents versus tile happiness). Show residents' mood when they are active, with a tooltip that says so.
- **Legacy HUD.** CityHud stays hidden and disabled. Do not reuse or edit it.

## Do NOT touch

- `scripts/ui/city_hud.gd`, `scripts/ui/gridfall_hud.gd`, `scripts/fp/ui/chat_panel*`, `scripts/fp/fp_*.gd`, `main.gd`, `project.godot`, and the sim, AI and world scripts.
- B does not make LLM calls.
