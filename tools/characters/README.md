# Character pipeline (slice HC)

Realistic people for on-foot play: Microsoft Rocketbox bodies (MIT) and mocap, plus Quaternius UAL clips
(CC0), on Godot's humanoid skeleton. Spec: `docs/fp/slices/HC-characters.md`.

Only the outputs under `models/characters/` are committed. The raw sources (2.6 GB) live in
`~/.cache/gridfall/characters/`, shared by every worktree. The Blender flatpak cannot read `/tmp`, so keep
the cache and the output under `$HOME`, and pass absolute paths (the flatpak starts in `/app/blender`).

## Rebuild

```bash
R=$PWD                                   # repo root
C=$HOME/.cache/gridfall/characters
python3 -I tools/characters/fetch.py     # download + verify (git blob SHA-1 / sha256), LICENSES, PROVENANCE.json
blender --background --factory-startup --python $R/tools/characters/build_bodies.py -- $C $R/models/characters
blender --background --factory-startup --python $R/tools/characters/build_clips.py -- $C $R/models/characters
flock /tmp/claude-1000/gf-heavy.lock godot --headless --path . --import
godot --headless --path . -s tools/characters/build_anim_library.gd
godot --headless --path . -s tools/tests/fp_characters_test.gd
```

`build_bodies.py --only Name,Name` rebuilds some bodies (the roster keeps the others' reports, cached in
`$C/build/reports/`); `--roster-only` rewrites `roster.json` alone. `build_clips.py --only rb_m,rb_f,ual`
and `--clips walk,run` rebuild part of the clip set. Editing a BoneMap does not trigger a reimport: touch
the GLBs.

## Files

| File | What |
|---|---|
| `manifest.json` | Rocketbox at commit `0943055`: every file with size and git blob SHA-1; avatar → id, group, gender, parts |
| `quaternius.json` | UAL1 / UAL2 itch.io upload ids, sizes, sha256 |
| `roster_rules.json` | Heroes, dropped parts, job pools, ambient weights, height targets, `name_gender` |
| `fetch.py` | Fetch with retries and the raw GitHub fallback; writes `LICENSES/` and `PROVENANCE.json` |
| `rb_rig.py` | Shared Blender helpers: the clean rig (`Root → Bip01 → Biped`, thighs under the pelvis, clavicles under Spine2) and the Biped-to-Biped pose transfer |
| `build_bodies.py` | Bodies (`bodies/<Name>.glb`, external materials and JPEG/PNG maps, ≤ 9,000 tris, ≤ 4 influences), far LODs (`<Name>_lod1.glb`: walk frame 8, ≤ 1,500 tris, 2 surfaces, no skin), `roster.json` |
| `build_clips.py` | `anim/rb_m.glb`, `anim/rb_f.glb` (Rocketbox, 30 fps, Root extraction, left-heel phase, loops cut to ≤ 12 s), `anim/ual.glb`, `anim/clips.json` |
| `build_anim_library.gd` | `anim/clips/<m|f|u>_<clip>.res` and `anim/lib_m.tres`, `anim/lib_f.tres` with the `speed_mps`, `speed_ref_hip_m`, `loop` and `root_turn_deg` metas |

## Using the characters (A, E)

- Instance a body under a `CharacterRoot` node with `scale = WS.M * h_target_m / rest_height_m`
  (`roster.json`); never scale the skeleton itself.
- Add `AP.CHAR_LIB_M` or `AP.CHAR_LIB_F` as the default library `""` and set
  `root_motion_track = AP.CHAR_ROOT_MOTION_TRACK` on the AnimationPlayer or AnimationTree. The mixer's
  root node must be the body's scene root (so `%GeneralSkeleton` resolves).
- Loops play in place; their Root carries the travel. A body covers
  `speed_mps * hip_m / speed_ref_hip_m` metres per second (before `CharacterRoot` scaling); match the
  playback rate to the ground speed with that.
- One-shots with root motion (`walk_start`, `run_stop`, `turn_*`, `sit_down`, `stand_up`) start at the
  origin facing +Z; read `get_root_motion_position()` / `get_root_motion_rotation()` to move the node.
  Static clips centre the pelvis over the origin; `sit` matches the end of `sit_down`.
- Head look: `LookAtModifier3D.forward_axis = AP.CHAR_LOOK_AXIS` for `Head` and `Neck`.
- Never publish the Quaternius clips as a standalone pack (see `quaternius.json`).
