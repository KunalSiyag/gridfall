# HC needs

Requests from HC (characters) to the slices that consume its assets. The usage notes behind them are
in `tools/characters/README.md` and in HC's section of `scripts/fp/asset_paths.gd`.

## To A (stage A2: the hero)

1. **Scale by the stature.** `roster.json` `rest_height_m` is the stature to the skull top
   (1.795 m for every man, 1.716 m for every woman: Rocketbox uses one skeleton per gender), not
   the mesh height; `aabb_height_m` is the mesh. `CharacterRoot.scale = WS.M * h_target /
   rest_height_m` as planned.
2. **Playback rate.** A body covers `speed_mps * hip_m / speed_ref_hip_m` m/s of Root travel
   (both metas are on every clip, `hip_m` is in the roster), then times the `CharacterRoot` scale.
   The plan's `speed_mps * h_target / 1.75` is about 2.5 % off for men and 2 % for women.
3. **Locked phases when blending loops.** walk (1.07 s), walk_fast (1.07 s), run (0.77 s) and
   run_fast (0.60 s) all start on the left-heel strike, but `AnimationNodeBlendSpace1D.sync` does
   not equalise cycle lengths: give each clip a TimeScale so the blended clips share one cycle,
   or the legs drift apart after a few strides. A 50/50 walk/run blend inside one cycle was checked
   in a side-view render.
4. **Mixer root.** Add the library as `""` and set `root_motion_track = AP.CHAR_ROOT_MOTION_TRACK`;
   the AnimationPlayer or AnimationTree's root node must be the body's scene root so
   `%GeneralSkeleton` resolves.
5. **Head look.** `LookAtModifier3D.forward_axis = AP.CHAR_LOOK_AXIS` (+Z) for `Head` and `Neck` on
   every body (the HC test checks it on all 40).
6. **Clip notes.** `crouch_idle` / `crouch_walk` (UAL) put the hips 0.27 m behind the origin, as a
   real crouch does; `sit` is a loop (AP `PERSON_LOOPING` predates it); one-shots with root motion
   start at the origin facing +Z.

## To E (stage E2: residents and the crowd)

1. **Assignment** as planned: `job_pools[job]` filtered by the body's gender, else
   `casual_pools[gender]`, index `crc32(resident_id) % n`. There is no female firefighter (every
   Rocketbox `Fire_Female_*` wears a breathing mask on a male body), so women firefighters fall back
   to the casual pool. `name_gender` covers 52 of the 60 first names.
2. **Far LOD.** `<Name>_lod1.glb` is posed mid-stride (walk frame 8) and keeps only the body and head
   surfaces, so hard hats and helmets disappear past the LOD switch (about 2 px at 60 m).
3. **Static clip lengths.** The idles, talks, phone and sit loops are 4.5–12 s; start each instance
   at a random phase.

## To G2

1. `tools/optimize_imports.py` may set texture compression and mipmaps under `models/characters/**`
   (the texture `.import` files already use VRAM compression with mipmaps) but must keep the
   scene `.import` `_subresources` (BoneMap retarget, external materials) as they are.
2. Budget facts for the VRAM report: hero maps 1024² (body, head, opacity), resident maps body 512²,
   head 1024², opacity 512², LOD maps 256²; 56 MB on disk in all.
