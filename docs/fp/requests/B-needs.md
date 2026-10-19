# B needs

Requests and notes from slice B (lean HUD and map) to the slices whose seams it consumes. B already
runs against S0 alone: every item below has a local fallback, so nothing blocks B's merge.

## To E (traffic)

1. **`agents_near(p, r)` and `visible_near(p, r)`** as specified in `slices/E-traffic.md`. The
   minimap calls `agents_near` at 12 Hz and `visible_near` at 2 Hz, both with `r = 20` tiles, from
   `scripts/fp/ui/minimap_view.gd`. Please keep each call well under 0.1 ms with about 200 agents
   (a spatial hash or a cell list, not a scan of every agent).
2. **Heading.** B orients car blips by `vel`. When `vel` is zero it falls back to `heading`, read
   in S0 §11's yaw convention (forward = `(-sin h, 0, -cos h)`). Please confirm that convention, or
   always fill `vel`.
3. **Kinds.** B styles `bus` and `truck` larger, `emergency` red, and `pedestrian` as a faint
   small dot; anything else is a car. Cars are steel-blue capsules about a road wide (checked
   against fp/E 0e20963 in a throwaway merge: near-white blips made every busy road look
   beaded). Named residents from `visible_near` draw as bright dots on top.
4. **Vehicle target `data`.** The place card reads `state` ("driving to work"), `dest_label` and
   `mood` (0..1 or 0..10; both are handled). It shows `label` as the title. `mood: ""` (a car
   without a driver) shows no mood line, and the prompt and card sentence-case `label`
   ("a commuter" reads "A commuter"), so E can keep its labels as they are.
5. **Fallback while E is absent.** B makes one pass over `residents.people` at 2 Hz, skips indoor
   residents without a route, and draws the rest at their `at` tile. It never calls
   `avatars.position_of`.

## To A (player and interaction)

1. **Headings.** The minimap rotates by the view yaw taken from `player.forward()` (the camera look
   direction in both cameras). Its arrow and the full map's arrow use `player.yaw` as the body
   yaw. Please keep both meanings.
2. **Prompt anchor.** B unprojects `target.pos` with `ctx.player.camera`, plus 0.25 m over a
   resident's head anchor and nothing for other kinds. If the third-person rig ever renders
   through a camera other than `player.camera`, expose that camera as `player.camera`.
3. B hides the prompt by itself under any modal, in photo mode and while
   `conversation_changed(id, true)` is active. A's `interact_target_changed({})` under modals is
   still welcome.
4. **The wheel.** B reads the raw mouse wheel for the minimap scale only while
   `settings.camera_mode == "first"`, never `zoom_in` / `zoom_out`, and does not consume the event.
5. **Settings.** The pause menu writes `camera_mode`, `tps_fov` (50–75), `tps_distance_m`
   (1.6–5.0), `shoulder` (1 / -1), `auto_shoulder`, `hero` (`"m"` / `"f"`), `fov` (60–90),
   `mouse_sensitivity` (0.3–2.5 × 0.0022), `invert_y` and `head_bob` through
   `mode.apply_settings()`. While a slider is dragged it sends `persist = false` patches (A can
   preview the FOV live), and one `persist = true` patch on release.

## To C (chat)

1. **`chat_slot` geometry is unchanged** at (0, 80, 460, -268). The minimap circle starts at the
   top of `minimap_slot` (y = 648 at 1600×900), 16 px under the bottom of `chat_slot` (y = 632), so
   the collapsed ticker clears it.
2. **Unread badge.** B draws no unread dot on the minimap, because C's edge tab already carries the
   count. If one is wanted later, B can add a rim dot from `chat_posted`.
3. **`card_action("ask_here", tile)`** is emitted once per press, after the card has closed and
   popped `&"card"`, so C can push `&"talk"` immediately.
4. **Screen corners.** B's district caption ("Northwest Civic Campus" / "Mayor Ada Okafor", 5 s
   on arrival and on entering a district) uses the bottom-right corner of the `center` slot,
   right-aligned on the 24 px margin, up to 90 px tall. Nothing of B's sits in `chat_slot`.

## To G2 (render) and I (audio)

- **Quality.** The quality preset is written as `"quality"`: `"low"`, `"medium"` or `"high"`.
  `apply_settings` then emits `quality_changed`.
- **Volumes.** `music_volume_db` and `sfx_volume_db` are written in dB, -80 for 0 %. The slider
  maps 0–100 % through `linear_to_db`.

## To S0 / the integrator

None. `FpHud` keeps `class_name FpHud`, `setup(ctx)`, `layer = 10`, `PROCESS_MODE_ALWAYS`,
`SLOTS`, the slot geometry, `slot()`, `set_hud_visible()`, `is_hud_visible()` and `show_toast()`.
The top bar shows `Day <n>` in a visible `Label` (the time chip), and toasts are `Label`s under
`slot("toasts")`.
