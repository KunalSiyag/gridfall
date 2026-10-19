# Slice HC: Characters

Branch `fp/HC-characters`, in its own worktree, branched from `fp/integration` after S0's D13 hooks. Read ARCHITECTURE D1, D2, D10, D11, D13 and rules 11–12, S0 §4.4 (`asset_paths.gd`), then TPS_PLAN §1, which this spec condenses:
`/tmp/claude-1000/-home-kunalsiyag-Ambassador-Gmi-Cloud-gridfall/ed910984-b548-4cd5-88e0-8f11330d4e8e/scratchpad/tps/TPS_PLAN.md`.
The scratch artefacts it cites (manifest, converters, BoneMaps, probes) are listed under "Scratch artefacts" below. The scratchpad is not permanent: copy what you need into `tools/characters/` in your first commit.

## Goal (what the player sees)

- **The hero** is a realistic, clothed person seen from behind: `Male_Adult_06` (red long-sleeve and jeans, the default) or `Female_Adult_04` (brown leather jacket and boots, `settings.hero = "f"`). Both were chosen for a strong silhouette against grey streets.
- The hero moves with **motion-captured animation**: idle, walk, jog, run, starts and stops, turns, jump, fall and land, crouch, talk, phone, wave, sit, interact.
- **The 100 residents and the street crowd** use 38 distinct Rocketbox bodies chosen by job and gender: nurses look like nurses, police like police, builders wear hard hats. A resident always looks the same, across runs and after save/load. Natural heights run 1.61–1.80 m.
- **One shared animation set** on Godot's humanoid skeleton (`%GeneralSkeleton`) drives everyone: one library per gender, so the memory is paid once.
- **Clean licences.** Microsoft Rocketbox is MIT and Quaternius UAL is CC0. The licence files and a provenance record are committed. The raw sources (2.61 GB of FBX/TGA plus 35 MB of zips) never are.

## Owned files (exclusive)

- `tools/characters/**`: `manifest.json`, `quaternius.json`, `fetch.py`, `build_bodies.py`, `build_clips.py`, `build_anim_library.gd`, `README.md`.
- `models/characters/**`, **including its `.import` files**. The BoneMap retarget, bone renamer, rest fixer and track-removal options are content, not optimisation, so this is an exception to ARCHITECTURE rule 11 (T-D5). G2's `optimize_imports.py` may only set texture compression and mipmaps here.
- The character entries of `scripts/fp/asset_paths.gd` (deliverable 7), in a marked `# --- HC characters ---` section at the end of the file. H owns the rest of the list. Never rename S0's constants.
- `tools/tests/fp_characters_test.gd`.

## Seams consumed

| From | API |
|---|---|
| S0 `WS` | `M`, `PERSON_H` (1.75 m), `VIS_PERSON` |
| S0 `AP` | `load_scene()`, `PERSON_ANIMS` (`idle, walk, run, talk, sit`: names kept, so E's and the legacy contract hold), `PERSON_LOOPING` |
| `Residents` | `FIRST_NAMES` (`residents.gd:73`, 60 names, for `name_gender`) and the job titles (`residents.gd:38-45`, for the job pools) |
| G2 | `tools/optimize_imports.py --check` / `--apply <paths>`; on `models/characters/**` it touches texture keys only (G2's allow-list) |

## Seams HC provides

| Consumer | What |
|---|---|
| A (stage A2) | `AP.HERO_M` / `AP.HERO_F` bodies, `AP.CHAR_LIB_M` / `AP.CHAR_LIB_F` libraries with every `AP.PERSON_TPS_ANIMS` clip, the `speed_mps` meta on each clip, `rest_height_m` per body in `roster.json`. The `LookAtModifier3D` `forward_axis` for `Head` and `Neck` per rig (the test asserts it, deliverable 9). |
| E (stage E2) | `AP.CHAR_ROSTER` (`roster.json`: bodies, groups, genders, job pools, `name_gender`), `AP.CHAR_BODIES_DIR` bodies and their `<Name>_lod1.glb` (2 surfaces, no skin, for the MultiMesh tier), the same libraries. |
| G2 | Import settings that `optimize_imports.py` must leave alone (`retarget/*`, `_subresources`); the texture sizes below for the VRAM report. |

## Deliverables

### 1. Sources (every URL checked on 2026-10-19, TPS_PLAN §5)

| Source | Licence | What we take | Fetch (primary, then fallback) | Integrity |
|---|---|---|---|---|
| **Microsoft Rocketbox**, pinned to `master` = `0943055db6ec570bcef9f2c8b41c9e5467c808f9` (repo archived 2022-10-02) | MIT, "Copyright (c) 2020 Microsoft" | 40 avatars (FBX plus `*_color` / `*_normal` TGAs; specular dropped) and 50 mocap clips | `https://cdn.jsdelivr.net/gh/microsoft/Microsoft-Rocketbox@0943055db6ec570bcef9f2c8b41c9e5467c808f9/<path>`, then `https://raw.githubusercontent.com/microsoft/Microsoft-Rocketbox/0943055db6ec570bcef9f2c8b41c9e5467c808f9/<path>` (works, about 14 KB/s). Listing: `https://api.github.com/repos/microsoft/Microsoft-Rocketbox/git/trees/0943055db6ec570bcef9f2c8b41c9e5467c808f9?recursive=1` | git blob SHA-1 per file, from the tree listing (recorded in the manifest) |
| **Quaternius UAL1 Standard** (v3, 2026-06-16) | CC0 (bundled `License.txt`, itch page) | 10 clips from `Unreal-Godot/UAL1_Standard.glb` (in place) | `https://quaternius.itch.io/universal-animation-library` → POST `/download_url` → POST `/file/17958403?source=game_download` (signed CDN URL) | 15,904,933 B, sha256 `cc73fc4e495b82958207316596317a3f40b9fa38065bde1027937452da537724` |
| **Quaternius UAL2 Standard** (2026-06-16) | CC0 (bundled `License.txt`, itch page) | 7 clips from `Unreal-Godot/UAL2_Standard.glb` | `https://quaternius.itch.io/universal-animation-library-2` → `/file/17958478?...` | 18,735,003 B, sha256 `4008ea208a604773a2b2177d965f0f5d3195498b5bf838c3f5785d68e95f2a68` |

Not used: the OpenGameArt UAL2 mirror (an older January 2026 build with `_RM` clips mixed in; emergency mirror only), the OGA UAL1 copy (stale Rigify `DEF-*` bones), Universal Base Characters (underwear only), Ready Player Me (shut down), Kenney (blocky), Mixamo (excluded), MPFB2 (untested; a later variety option), H's procedural rigs (T-D4: "stiff, crouched, clay-figure" at 2–4 m).

**Quaternius licence note.** Since 2026-08-28 quaternius.com publishes the QAL v1.0, which allows use inside a game without credit but forbids redistributing the assets *as assets*. The files we hold say CC0. Shipping them inside GridFall is fine under either. Never publish the clips as a standalone pack.

### 2. Roster v1: 40 avatars (the VRAM cap is about 40 unique bodies)

| Group | Avatars | Used for (resident `job_title`) |
|---|---|---|
| **Hero** (player only, never a resident) | `Male_Adult_06` (default), `Female_Adult_04` | The player |
| Casual, 16 | Male_Adult_01, 02, 03, 04, 08, 12, 15, 18 · Female_Adult_01, 02, 03, 05, 06, 08, 12, 14 | shop owner, cashier, barista, artist, student, teacher, retiree (Male_Adult_03 is older), stadium and airport staff, bus driver, and the fallback for every group |
| Business, 5 | Business_Female_01, 02 · Business_Male_01, 02, 07 | software developer, accountant, city clerk, professor, civil engineer |
| Police, 3 | Police_Male_01, Police_Male_05, Security_Female_01 | police officer |
| Medical, 4 | Medical_Female_01 (nurse), Medical_Female_02 (doctor), Medical_Male_02 (paramedic), Medical_Male_04 (scrubs) | nurse, caregiver, doctor, paramedic |
| Fire, 2 | Fire_Male_03, Fire_Female_01 | firefighter |
| Trades, 4 | Construction_Male_01 (plaid shirt, hard hat), Construction_Male_02, Construction_Male_07 (orange vest), Construction_Female_01 | construction worker, electrician, power line technician, plumber, water utility engineer, sanitation worker |
| Service, 4 | Chef_Female_01, Delivery_Male_01, Gardener_Male_01, Wood_Male_01 | chef, truck driver, warehouse worker, factory worker, mechanic, power plant operator |

- **Excluded:** military, children (there are no child residents), swimwear, and the fire variants with breathing masks.
- **Material parts vary by avatar** (body+head+opacity ×21, body+head ×8, +helmet ×4, and single cases with glasses, equipment, pistol, hat, stethoscope, protection, tools, flashlight, mask). Derive the parts from the FBX material names `<id>_<part>`; never hard-code them. Handle the `_a` suffix (`f110_head_color_a.tga`).
- **Drop `pistol` parts.**
- The manifest is ready (309 files with size and git blob SHA-1, plus the avatar → id / group / gender / parts mapping; 2.61 GB of source; all 309 URLs returned 200 on 2026-10-19). Commit it as `tools/characters/manifest.json`.

### 3. Fetch: `tools/characters/fetch.py` (run with `python3 -I`; needs network)

- **Inputs:** `tools/characters/manifest.json` and `tools/characters/quaternius.json` (upload ids, byte sizes, sha256).
- **Cache:** `~/.cache/gridfall/characters/`, outside the repo and shared by every worktree. The Blender flatpak can read `$HOME` but **not** `/tmp`.
- **Retries:** 3 with backoff, then the raw.githubusercontent fallback. In the 2026-10-19 sweep, 3 of 309 jsDelivr requests returned a cached 403 that cleared on retry.
- **Verification:** reject any file whose git blob SHA-1 (Rocketbox) or sha256 (Quaternius zip) does not match.
- **Provenance:** copy `LICENSE.md` and each zip's `License.txt` into `models/characters/LICENSES/` and write `models/characters/PROVENANCE.json` (URL, commit or upload id, Last-Modified, hash, date fetched).
- The itch flow is already scripted and verified: port `.../scratchpad/tps/scripts/itch_fetch.sh` or `.../scratchpad/tps/verify/itch_head.sh`.
- Never print an API key or cookie; the itch flow needs none.

### 4. Bodies: `tools/characters/build_bodies.py` (headless Blender)

`blender --background --factory-startup --python tools/characters/build_bodies.py -- <cache> <out>`, with `<out>` under `$HOME` or a gitignored repo folder, then copy into `models/characters/bodies/`. For each roster entry:

1. **Import** the FBX. The armature arrives as `Bip01` at scale 0.01, plus a `Bip01 Footsteps` empty: delete it. The mesh is one object.
2. **Add a `Root` bone** at the origin, at ground level, as the parent of `Bip01`, with no weights. Every body and every clip then has a real root, and root motion is a single track (deliverable 5).
3. **Rebuild the materials** from the material names (the FBX texture paths are absolute and broken):
   - each part gets a Principled BSDF with `<id>_<part>_color` as base colour and `<id>_<part>_normal` through a Normal Map node (Non-Color);
   - `opacity` and `glasses_opacity`: alpha from the TGA alpha through a Math `ROUND` node, so glTF gets `alphaMode MASK` (Godot imports alpha scissor);
   - roughness 0.7; specular maps dropped.
4. **Texture sizes.** The hero uses 1024² for every map. Residents use body 512², head 1024², opacity 512². Colour and normal maps are JPEG at quality 88/90, opacity PNG. No 2K maps.
5. **Export** `models/characters/bodies/<Name>.glb`: metric and unscaled (armature object scale 1 after applying the 0.01), feet at y = 0, facing +Z, at most 4 influences per vertex (`vertex_group_limit_total(4)`), no animations.
6. **Far LOD** `models/characters/bodies/<Name>_lod1.glb`: decimated to ≤ 1,500 tris, posed at frame 8 of `walk` (mid-stride), no skin, no opacity part, 256² body and head maps: 2 surfaces, for E's MultiMesh tier.
7. **Report** `models/characters/roster.json`: name, group, gender, Rocketbox id, parts, `rest_height_m`, tris, surfaces, bytes, the job pools of deliverable 2 and `name_gender` (deliverable 8).

Measured on `Male_Adult_06` with the scratch converter (`.../scratchpad/tps/verify/rb_convert.py`): 7,456 tris, 80 bones, 3 surfaces, rest height **1.831 m** (feet at −0.8 mm), **2.97 MB** with all maps at 1024 (the opacity PNG alone is 1.85 MB), 1.06 MB with all maps at 512, 2.5–3.8 s per avatar. Residents at body 512 / head 1K / opacity 512 come to about 1.35 MB each and about 2.9 MB of VRAM after BC compression with mips: about 120 MB for 38 residents plus one hero, well inside D11.

### 5. Clips: `tools/characters/build_clips.py` (headless Blender)

**Rocketbox clips**, one file per gender: `models/characters/anim/rb_m.glb` and `rb_f.glb`, each a skeleton with no mesh and one action per clip, named `<canonical>-loop` for loops. Per clip:

1. `scene.render.fps = 30`. A factory-empty scene defaults to 24 fps, which stretches clips by 1.25×.
2. **Root extraction** (the `xy` / `xyz` source clips carry the travel on `Bip01`):
   - loops: `Root` gets the straight-line ground travel `(p_end − p_0)·t/T` (yaw 0); `Bip01` keeps the residual, so hip sway and bob stay;
   - one-shots (start, stop, turn, sit-down): `Root` gets the ground projection of `Bip01`, smoothed over a 0.1 s window, plus yaw from the pelvis heading;
   - `static` clips get a static `Root`.
3. **Phase-align** loops so frame 0 is the left-heel strike (lowest left-foot z with near-zero foot velocity). Two loops must be aligned before a BlendSpace blends them, or the legs scissor.
4. Record `speed_mps` (the measured `Root` speed) as a custom property; it becomes the Godot meta `speed_mps`.

**UAL clips:** `models/characters/anim/ual.glb` holds the 17 clips of deliverable 6, copied out of `UAL1_Standard.glb` and `UAL2_Standard.glb` (in place; root `root` → `Root`), with the mannequin mesh deleted.

### 6. Canonical clip set

`AP.PERSON_ANIMS` (`idle, walk, run, talk, sit`) is kept. Speeds were measured from root displacement over one loop (`.../scratchpad/tps/verify/rb_speed.py`); Rocketbox loop seams are ≤ 1.3°.

| Canonical | Male source | Female source | Type | Authored speed m/s (m / f) |
|---|---|---|---|---|
| `idle` | static/m_idle_neutral_01 | static/f_idle_neutral_01 | loop | 0 |
| `idle_look`, `idle_wait` | static/m_idle_look_around_01, m_idle_waiting_01 | f_ equivalents | loop (idle variety) | 0 |
| `walk` | xy/m_walk_neutral_02 | xy/f_walk_neutral_01 | loop | **1.35 / 1.21** |
| `walk_fast` | xy/m_walk_fast_01 | xy/f_walk_fast_01 | loop | **1.50 / 1.53** |
| `run` (AP "run" = jog) | xy/m_run_neutral | xy/f_run_neutral | loop | **3.07 / 3.16** |
| `run_fast` | xy/m_run_fast_01 | xy/f_run_fast_01 | loop | **5.84 / 5.38** |
| `walk_start`, `walk_stop`, `run_start`, `run_stop` | xy/m_* | xy/f_* | one-shot, root motion (phase 4) | – |
| `turn_l90`, `turn_r90`, `turn_l180_walk`, `turn_r180_walk` | xyz/m_turn_* | xyz/f_turn_* | one-shot, root motion (phase 4) | – |
| `talk`, `talk_2` | static/m_gestic_talk_neutral_01/02 | f_ equivalents | loop | 0 |
| `phone` | static/m_cell_phone_talk_01 | xyz/f_cell_phone_talk_01 | loop | 0 |
| `wave`, `knock`, `door_try` | static/m_wave_01, m_knock_door, m_try_door_inwards | f_ equivalents | one-shot | – |
| `sit_down`, `sit` (AP "sit"), `stand_up` | xyz/m_sit_down_chair_01, static/m_sit_chair_idle_neutral_01, xyz/m_sit_stand_up_chair_01 | f_ equivalents | one-shot / loop / one-shot | – |
| `jump_start`, `fall`, `land` | UAL1 Jump_Start, Jump_Loop, Jump_Land | same | one-shot / loop / one-shot | – |
| `crouch_idle`, `crouch_walk` | UAL1 Crouch_Idle_Loop, Crouch_Fwd_Loop | same | loop | 0 / **0.75** |
| `interact`, `push`, `pickup`, `drive` | UAL1 Interact, Push_Loop, PickUp_Table, Driving_Loop | same | mixed | – |
| `carry`, `phone_idle`, `fold_arms`, `yes`, `no`, `climb_1m`, `knockback` | UAL2 Walk_Carry_Loop, Idle_TalkingPhone_Loop, Idle_FoldArms_Loop, Yes, Idle_No_Loop, ClimbUp_1m, Hit_Knockback | same | mixed | Walk_Carry ≈ walk |

### 7. Godot import (HC owns these `.import` files) and `AP` entries

- **BoneMaps** to `SkeletonProfileHumanoid`:
  - `models/characters/bonemap_rocketbox.tres` maps `Root`→`Root` and **`Hips`→`Bip01`**. Mapping Hips to `Bip01 Pelvis` doubles the hip height (verified in the probe).
  - `models/characters/bonemap_ual.tres` maps `root`→`Root`, `pelvis`→`Hips`, and so on.
  - Port both from `.../scratchpad/tps/gprobe_assets/bonemap_{rb,ual}.tres`, then add the Root mapping.
- **Import options** on every body GLB and anim GLB, key `PATH:<Armature>/Skeleton3D`:

  ```
  "retarget/bone_map": Resource("res://models/characters/bonemap_rocketbox.tres"),   # or bonemap_ual
  "retarget/bone_renamer/rename_bones": true,
  "retarget/bone_renamer/unique_node/make_unique": true,
  "retarget/bone_renamer/unique_node/skeleton_name": "GeneralSkeleton",
  "retarget/rest_fixer/fix_silhouette/enable": true,
  "retarget/rest_fixer/overwrite_axis": true,
  "retarget/rest_fixer/normalize_position_tracks": true,   # present in the 4.7.2 binary; per-body motion_scale
  "retarget/remove_tracks/unimportant_positions": true,    # keeps only the Root and Hips position tracks
  "retarget/remove_tracks/unmapped_bones": true
  ```

  Also `nodes/use_name_suffixes=true` (so `-loop` becomes `LOOP_LINEAR` and the suffix is stripped), `animation/fps=30` and `meshes/generate_lods=true`.
- **Reimport pitfall.** Editing a BoneMap `.tres` does not trigger a reimport. Touch the GLB. Run the heavy `--import` under `flock /tmp/claude-1000/gf-heavy.lock`.
- **G2.** Run `python3 -I tools/optimize_imports.py --check models/characters` when the script exists; it may set texture VRAM compression and mipmaps, never `retarget/*` or `_subresources`.
- **`AP` entries** (HC's marked section of `scripts/fp/asset_paths.gd`):
  - `CHARACTERS_DIR = "res://models/characters/"`, `CHAR_BODIES_DIR = CHARACTERS_DIR + "bodies/"`, `CHAR_ROSTER = CHARACTERS_DIR + "roster.json"`
  - `CHAR_LIB_M = CHARACTERS_DIR + "anim/lib_m.tres"`, `CHAR_LIB_F = CHARACTERS_DIR + "anim/lib_f.tres"`
  - `HERO_M = CHAR_BODIES_DIR + "Male_Adult_06.glb"`, `HERO_F = CHAR_BODIES_DIR + "Female_Adult_04.glb"`
  - `PERSON_TPS_ANIMS`: the deliverable 6 names the player needs (`idle`, `walk`, `walk_fast`, `run`, `run_fast`, `crouch_idle`, `crouch_walk`, `jump_start`, `fall`, `land`, `talk`, `sit_down`, `sit`, `stand_up`, `interact`, `wave`, `phone`, `door_try`, plus the phase 4 starts, stops and turns once they exist)
  - `PEOPLE_RIGGED_DIR` is **retired** (T-D4): keep the S0 constant (never rename), but nothing reads it.

### 8. Shared animation library and variety data

- **Builder.** `tools/characters/build_anim_library.gd` is a headless Godot tool script that runs after import. It writes every clip to `models/characters/anim/clips/<gender>_<canonical>.res` (UAL clips once, as `u_<canonical>.res`) and two `AnimationLibrary` resources, `lib_m.tres` and `lib_f.tres`, that reference those `.res` files (UAL clips shared, not duplicated). It sets the meta `speed_mps` and `loop` on each Animation.
- **Use** (A and E). Every character's `AnimationPlayer` or `AnimationTree` adds its gender's library as the **default library `""`**, so clip names stay bare (`"walk"`) and `AP.PERSON_ANIMS` is unchanged.
- **Root motion.** `root_motion_track = NodePath("%GeneralSkeleton:Root")` on every mixer. Loops then play in place, because Root is not applied, and code owns displacement. One-shots read `get_root_motion_position()` when wanted.
- **Scale** (feet at y = 0, natural proportions). Skeletons stay metric. Each character has one parent node, `CharacterRoot`, with `scale = WS.M * (h_target / h_rest)` and `h_rest` from `roster.json`. Never apply the 0.05 inside the skeleton: the shared metric clips depend on it. Targets: male hero `WS.PERSON_H / WS.M` = 1.75 m; female hero 1.75 × 0.95 = 1.66 m; residents 1.75 m × (1.00 male | 0.95 female) × a jitter in [0.97, 1.03] from `crc32(resident_id)`, that is 1.61–1.80 m (0.081–0.090 u). Animations need no rescaling: `normalize_position_tracks` plus the skeleton `motion_scale` handle hip translation per body. Playback-rate correction uses `speed_mps × (h_target / 1.75)` as the authored speed of a scaled body.
- **`name_gender`.** `roster.json` maps each of the 60 `Residents.FIRST_NAMES` to `"m"` or `"f"`; ambiguous names (Quinn, Sami, Wren and the like) are omitted, and consumers fall back to `crc32(id) & 1`.
- **Assignment rule** (E implements it; HC supplies the data): the job's pool from deliverable 2 intersected with the resident's gender; if empty, the casual pool for that gender; index by `crc32(resident_id) % n`. The two hero avatars are never used for residents. Ambient pedestrians reuse the 38 resident bodies (60 % casual, 25 % business, 15 % uniforms).
- **Later (not v1):** per-avatar clothing tint masks through an `instance uniform`; MPFB2 scripted bodies for unlimited CC0 variety; Rocketbox `_facial.fbx` blendshapes for lip-sync in conversation close-ups.

### 9. Files

```
tools/characters/            (HC)
  manifest.json  quaternius.json  fetch.py  build_bodies.py  build_clips.py  build_anim_library.gd  README.md
models/characters/           (HC, committed outputs only)
  LICENSES/rocketbox-MIT.txt  LICENSES/quaternius-UAL1-License.txt  LICENSES/quaternius-UAL2-License.txt  PROVENANCE.json
  bonemap_rocketbox.tres  bonemap_ual.tres  roster.json
  bodies/<Name>.glb  bodies/<Name>_lod1.glb   (+ .import)
  anim/rb_m.glb  anim/rb_f.glb  anim/ual.glb  (+ .import)  anim/clips/*.res  anim/lib_m.tres  anim/lib_f.tres
~/.cache/gridfall/characters/  raw downloads (2.61 GB Rocketbox + 35 MB zips), never committed
```

Plain git, no LFS (T-D2): about 60–70 MB in all (40 avatars at 1.0–3.0 MB measured, about 4 MB of LODs and 6–10 MB of animation estimated). Add the cache path and any local build folder to `.gitignore` only if they live inside the repo.

## Stages (TPS_PLAN §3) and merge order

| Stage | TPS_PLAN | Content | Unblocks |
|---|---|---|---|
| HC1 | T3 | `fetch.py`, manifest, provenance and licences; `build_bodies.py` for the two heroes first; BoneMaps and import settings; the bodies part of `fp_characters_test` | A's stage A2 (with HC2) |
| HC2 | T4 | `build_clips.py` (Root extraction, phase alignment, 30 fps, `-loop`), UAL extraction, `build_anim_library.gd`, `lib_m` / `lib_f`; the rest of `fp_characters_test` | A2, E2 |
| HC3 | T7 | The 38 resident bodies plus their `_lod1`; `roster.json` with pools and `name_gender` | E's stage E2 |
| HC4 | T10 (with A) | Phase 4 polish clips (starts, stops, pivots, turns with root motion); optional `_facial` lip-sync | – |

HC merges after G2, like H (ARCHITECTURE §7). A and E merge first against placeholders and are wired to HC's assets in their follow-up stages.

## Acceptance tests

`tools/tests/fp_characters_test.gd`, token `FP_CHARACTERS_TEST: PASS`, headless. It runs in the gate's quick tier with the other `fp_*_test.gd` files.

- **Bodies.**
  - Every roster body loads through `AP.load_scene`.
  - It has `%GeneralSkeleton` with at least `Root, Hips, Spine, Chest, Neck, Head, LeftUpperLeg, LeftLowerLeg, LeftFoot, RightFoot, LeftHand, RightHand`.
  - One skinned mesh with 1–6 surfaces and ≤ 9,000 tris.
  - With `CharacterRoot` scaling, the AABB height is 0.08–0.095 u.
  - Each `_lod1` exists, has no skin, ≤ 1,500 tris and 2 surfaces.
- **Libraries.**
  - `lib_m` and `lib_f` contain every `AP.PERSON_ANIMS` and `AP.PERSON_TPS_ANIMS` name.
  - Loops are `LOOP_LINEAR`; every clip has the `speed_mps` meta.
  - At least 95 % of each clip's tracks resolve on every roster skeleton.
- **Retarget sanity.**
  - `walk` on every body for 1 s: the hips sit at 0.48–0.56 × body height, the lowest foot is ≥ −2 cm, and there are no NaNs.
  - `sit` puts the hips at ≤ 0.33 × height.
  - Seek, then `force_update_all_bone_transforms()` before reading poses.
- **Root.**
  - For loops, `Root` travel equals `speed_mps × T` within ±3 %, and the residual `Hips` horizontal drift over the loop is < 5 cm.
  - `walk`, `run` and `run_fast` have the left foot lowest at t = 0 ± 1 frame.
- **Head look.** For each rig, the chosen `forward_axis` of `Head` and `Neck` is the bone axis with the largest dot product with the model's +Z in the rest pose (A's `LookAtModifier3D` setup reads it).
- **Roster.** Every resident job title in `residents.gd` maps to a non-empty pool for both genders (falling back to casual); `name_gender` values are `"m"` or `"f"`; no roster entry is a hero avatar.
- **Licences.** The licence files exist, and the `PROVENANCE.json` hashes match `manifest.json` and `quaternius.json`.
- **Gates.** `tools/gate.sh full` passes. Attach a windowed screenshot of the two heroes and six residents standing on a street (a scratch scene, not committed) to the hand-off, and look at it before handing off.

## Performance budget

| Item | Budget |
|---|---|
| Body | ≤ 9,000 tris, ≤ 6 surfaces, ≤ 4 bone influences per vertex |
| `_lod1` | ≤ 1,500 tris, 2 surfaces, no skin |
| Textures | hero 1024² for every map; residents body 512², head 1024², opacity 512²; LODs 256²; no 2K maps |
| Disk | about 1.35 MB per resident, about 3 MB per hero, ≤ 70 MB committed in all |
| VRAM | about 120 MB for 38 residents plus one hero (BC compressed with mips) |
| Runtime (E and G2 measure) | ≤ 1.5 ms of animation CPU per frame and ≤ 150 character draws (ARCHITECTURE D11; E's LOD tiers) |

## Risks

| Risk | Mitigation |
|---|---|
| Blending two mocap loops from different actors (`walk_neutral_02` with `walk_fast_01`, `run_neutral` with `run_fast_01`) looks mushy | Phase-align at the left-heel strike (deliverable 5). If it still reads badly, drop `walk_fast` / `run_fast` and play the single clip at a TimeScale of 0.86–1.15. |
| Inserting the Root bone breaks the verified retarget (the probe mapped Hips→Bip01 with **no** Root) | The retarget sanity test (hip and foot heights on every body) gates HC2. Fallback: no Root bone, de-trended `Bip01` travel for loops, and no root motion for one-shots. |
| Rocketbox alpha-scissor hair looks aliased at 1600×900 | Switch the opacity surface to `ALPHA_HASH` through an import material override on the hero only. |
| jsDelivr transient 403s, or the itch flow changes | Retry, raw GitHub fallback, hash verification. Downloads happen once; the committed outputs keep the build offline (D9, D10). |
| Quaternius licence ambiguity (website QAL versus bundled CC0) | Keep the bundled `License.txt` and the zip hashes in `models/characters/LICENSES/`. QAL allows this use anyway. Never publish the clips as a pack. |
| Animation CPU over 1.5 ms with 52-track Rocketbox rigs | E lowers the T1 cap and rate; off-screen mixers inactive; a v2 bone-texture MultiMesh for T2. |
| Repo weight | Raw sources never enter the repo; the gate's import cache under `.godot/` stays gitignored. |

## Scratch artefacts

All under `/tmp/claude-1000/-home-kunalsiyag-Ambassador-Gmi-Cloud-gridfall/ed910984-b548-4cd5-88e0-8f11330d4e8e/scratchpad/tps/`:

- `verify/manifest/rb_manifest.json` (the manifest)
- `verify/rb_convert.py`, `verify/rb_speed.py`, `verify/rb_loop.py`, `verify/itch_head.sh`, `scripts/itch_fetch.sh`
- `gprobe_assets/bonemap_{rb,ual}.tres`, `gprobe_assets/probe{,2}.gd`
- `verify/sheet_{adults,prof}.png` (contact sheets of all 115 avatars)
- `TPS_provenance_seed.json`

## Do NOT touch

- `models/real/**` and `tools/blender/**` (H), including the legacy `models/real/people/person_*.glb`, which stay as the fallback when a character file is missing.
- `project.godot`, `main.gd`, every `scripts/**` file except HC's section of `scripts/fp/asset_paths.gd`.
- `tools/optimize_imports.py` (G2) and other slices' files.
- Never commit anything from `~/.cache/gridfall/characters/`.
