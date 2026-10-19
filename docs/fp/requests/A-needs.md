# A needs

Requests from slice A (player, camera, collision, interaction) to the owners of other files. Every
item has a local fallback in A's code, so nothing here blocks a merge.

## To S0's owner (`project.godot` `[input]`)

1. **Gamepad bindings for the on-foot actions.** The right-stick `look_*` actions exist; nothing else
   has a joypad event yet. Please add: `move_forward` / `move_back` / `move_left` / `move_right` on
   the left stick (axes 1 and 0, dead zone 0.15, so `Input.get_vector` gives a radial dead zone),
   `jump` on A (button 0), `interact` on X (button 2), `sprint` on the left stick click (button 7),
   `crouch` on B (button 1), `view_toggle` on the right stick click (button 8), `shoulder_swap` on
   the right bumper (button 10) and `photo_mode` on Back (button 4). A already reads all of them;
   only the bindings are missing.

## To G1 (`scripts/world/city_view.gd`, `construction_kit.gd`)

1. **Furniture colliders meta** (already in G1's spec): every furniture placement, batched or not,
   is also written to `holder.set_meta("colliders", [{"shape": "cyl"|"box", "pos": Vector3
   (holder-local, the centre of the base), "r": float | "size": Vector3, "yaw": float, "h": float
   (optional cylinder height; A assumes 3 m)}])` before `tile_built` fires. A then reads only the
   meta for that holder's props (`fp_player_test` checks it). Until then A scans the holder: lamp
   poles from `Bulb_*` on lit straights, bus shelters, `models/**/props/*.glb` children by file
   name, and the cul-de-sac tree.
2. **Lit straights put two posts on the sidewalk centre line.** `road_straight_lights.glb` has the
   small posts of `roads.py:168-169` at model-local (±0.4, ∓0.2), right where people walk (E's
   `PED_BAND` is 0.355-0.405). A collides with them (the walker slides round a post it meets
   head-on), but a pedestrian lane through them will look odd. Consider moving them into the
   `CURB_FURNITURE` band when the road set is re-exported.
3. **v2 camera fade hook (optional).** The third-person arm ignores thin props (lamps, signs, tree
   trunks), so the camera can graze one for a frame. A dither-fade on props within 0.3 m of
   `player.view_position()` would hide that; A can call a `fade_props_near(p, r)` if G1 adds one.
4. **When `WS.GROUND_Y` moves** (the raised base ground), tell A: the interim soft step in
   `CollisionWorld.walk_height` (`SOFT_STEP` / `SOFT_BAND`) is removed in A's follow-up commit.

## To H (`tools/blender/**`, `models/real/**`)

1. **`ColBox_<n>` empties** in building GLBs (position = box centre, scale = half extents, no mesh,
   no suffix, `AP.COLBOX_PREFIX`). When present they replace A's computed bodies for that model.
   Never `-colonly` meshes.
2. **After re-exporting any building or zone GLB**, re-run the body bake (CollisionWorld analyses
   a model whose bounds changed at runtime, with a warning, but that costs 10-300 ms per model on
   first sight):
   `godot --headless --path . -s res://scripts/fp/player/body_bake.gd`
   and commit `scripts/fp/player/body_table.gd` (A owns it; H may regenerate it).
3. `school.glb` and `solar_farm.glb` fence the whole lot with no gap, so their yards cannot be
   entered on foot. A gate gap (at least 1.2 m) in the frontage fence would make them walkable.

## To E (traffic feature)

A uses these when they exist and skips them otherwise:

- `anchor_of(id) -> Vector3`: the resident's head for the conversation two-shot (A refreshes it
  every frame while talking). `Vector3.ZERO` or NAN means "not drawn".
- `visible_near(p, r)`: when present, A stops finding residents itself and uses it for the
  third-person fallback cone (6.7).
- `blockers_near(p, r) -> Array[AABB]`: stopped vehicles become walls for the walker (polled at
  10 Hz within 2 m).
- `agents_near(p, r)`: A reads `kind`, `pos`, `vel` and `heading` (radians about +Y, either
  forward convention) to pull the camera arm out of car, bus, truck and emergency boxes.
- `pick()` kinds as in S0 §9; A rewrites a `pedestrian` with `data.driver_id` into that resident.

## To B (HUD)

- In third person, hide the crosshair and anchor the prompt over `target.pos` with
  `player.camera.unproject_position()`; the S0 placeholder still draws its centre dot.
- Settings UI: `camera_mode`, `tps_fov`, `tps_distance_m`, `shoulder`, `auto_shoulder`,
  `head_bob` all apply live through `mode.apply_settings()`.

## To I (audio)

- `FpPlayer.stepped(surface: String, pos: Vector3)` fires on each heel strike of the player's gait
  (left at phase 0, right at PI; about 0.70 m apart at a walk and 1.35 m at a run), so it matches
  the placeholder's visible stride; `pos` is that foot's ground point, 9 cm either side of the
  body. Stage A2 keeps the same contract on the hero's clips. `FpPlayer.photo_mode_changed(on)` is
  there if photo mode should duck anything.

## To HC (stage A2)

- A2 needs `AP.HERO_M` / `AP.HERO_F`, `AP.CHAR_LIB_M` / `AP.CHAR_LIB_F` (bare clip names,
  `speed_mps` meta) and `rest_height_m` per body in `AP.CHAR_ROSTER`. The avatar node is
  `scripts/fp/player/player_avatar.gd`; until then it shows the legacy `person_a.glb` (hero `m`)
  or `person_b.glb` (hero `f`), re-rigged at load into a jointed puppet with a procedural walk,
  run, crouch, jump and landing (`placeholder_puppet.gd`; also the fallback whenever a hero GLB
  is missing).
