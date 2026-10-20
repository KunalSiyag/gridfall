# Slice H: requests to other slices

H's new files are additive: `models/real/vehicles_v2/` (24 models, each with a `_lod1`) and
`models/real/street/` (13 models). No existing GLB changed. Every consumer already falls back when a
file is missing, so nothing here blocks a merge.

## To E (traffic)

1. **Far LODs work with `mesh_kit.gd` as it is.** Each `vehicles_v2/<name>_lod1.glb` is one mesh
   (wheels merged, at most 1,500 triangles) with a few flat, untextured materials, one per colour
   group (at most 16). The lamp lenses are the emissive `Light_Head` and `Light_Tail`, which is what
   your merge reads: albedo per surface, with emission marking lamps. H's contract asked for a single
   material. A single vertex-coloured material would come out white in your merge, because it reads
   only the material albedo, and Godot 4.7.2 imports such a material without
   `vertex_color_use_as_albedo`. H therefore ships colour groups, which your merge turns into one
   surface anyway.
2. **Full models** colour their small parts (tyres, trim, plates, interior) through one palette
   texture (`Car_Atlas`). Your fallback merge of a full model (used when a `_lod1` is missing) would
   draw those parts white, but every model ships its `_lod1`. Brake swaps keep working: the tail lamps
   are the `Light_Tail` surface of `<name>_body`, as on the legacy models.
3. **Traffic light.**
   - The pole is 6.4 m tall with the mast at 6.0 m, so the head's lower edge is 4.6 m above the road.
     The contract's 4.5 m pole would hang the head about 3.3 m up, below the 3.6 m box truck.
   - The mast runs 5.5 m along local −X. `Signal_Red_0`, `Signal_Amber_0` and `Signal_Green_0` are on the
     mast head. `Signal_*_1` are on a secondary head mounted on the pole at 3.4 m. Both heads face +Z,
     and `_bind_asset_lamps` already picks up both.
   - Default lens state: red lit, amber and green dark.
   - `SignText_A` and `SignText_B` sit exactly where your procedural pole puts them (−0.05 m, 4.6 m and
     4.35 m; B is turned 90°). G1's blades therefore land in the same place with or without the asset.
   - A pedestrian head on the pole at 2.7 m faces −X, toward the far corner of the crossing. Its nodes
     are `Walk_0` and `DontWalk_0`, with "don't walk" lit by default. Please bind them like `Signal_*`
     (`AP.WALK_NODE_PREFIX`, `AP.DONT_WALK_NODE_PREFIX`). **Done:** `Junctions._bind_asset_peds`
     binds them to the zebra each head faces.
4. **`ped_signal.glb`** uses the contract names `Walk_0` and `DontWalk_0`, not your proposed
   `Ped_Walk` / `Ped_Stop`. It has a 2.6 m post, a head centred 2.25 m up facing +Z, and a push button
   at 1.05 m.
5. **`stop_sign.glb` and `yield_sign.glb`.** The plate faces +Z and the origin is at the post foot. The
   `SignFace` texture already carries the STOP or YIELD lettering, so no `Label3D` is needed with the
   asset.
6. **`bicycle.glb`** has `Wheel_F`, `Wheel_R` (hubs, spin about X) and `Seat_Driver` at the saddle.

## To G1 (street dressing)

1. **`curb_ramp.glb`** uses your procedural ramp's frame: origin on the curb line at road level, local
   +Z toward the sidewalk, X along the curb. The geometry is in the tile's height frame (asphalt `ZA`
   to sidewalk `ZS`), so place it at holder y = 0 as `_put(i, "ramp", Vector3(p.x, 0.0, p.y), …)`
   already does. The ramp is 1.9 m wide (the zebra band) and rises over 1.2 m in the gutter to the
   curb top. It has 0.45 m flares and a yellow truncated-dome pad on its lower (street) half. It is
   walkable, so keep collider `-1.0`.
2. **`bus_shelter.glb`.** The shelter is 3.96 × 1.5 × 2.5 m, centred on the origin and open to +Z. The
   glass back wall is at z ≈ −0.0345 u, and the posts are at x = −0.089, 0 and +0.0965 u. The lightbox
   is the −X end wall (x −0.099 to −0.090 u). `Poster_0` faces −X (people walking up) and `Poster_1`
   faces into the shelter. A bus-stop flag hangs under the +X front corner of the roof. The
   `poster_slot` meta you set for the legacy stop does not apply to it: D prefers H's `Poster_*` nodes.
3. **`street_sign.glb`.** `Blade_B` (along Z) sits on the post cap at 3.02 m, and `Blade_A` (along X)
   sits above it at 3.25 m. Their `SignFace` is a green blade with a white rim. `SignText_A` and
   `SignText_B` are at the blade centres, inside the 22 mm blade, so offset a `Label3D` by ±0.012 m along
   the empty's Z for each face.
4. **`bike_rack.glb`:** three Sheffield hoops, 0.85 m tall and 0.75 m deep across Z, 0.9 m apart along
   X. The footprint is about 1.9 × 0.9 m.
5. **`parking_meter.glb`:** the head is 1.05 to 1.47 m up, with the display and keypad facing +Z and
   a blue P plate on the back.
6. **`lease_sign.glb`:** a 1.8 × 1.2 m board, 1.0 to 2.2 m up, on two posts at x = ±0.65 m behind it.
   `Poster_0` is the whole face, with a baked FOR LEASE default. Your procedural board's labels are not
   needed with the asset.

## To D (posters)

Every `Poster_<n>` is a single quad with material `Poster`, UV 0..1 and normal +Z in node space. Its
default texture is a baked generic poster (FOR LEASE on the lease board), so override freely.

| Model | Nodes | Size |
|---|---|---|
| billboard | `Poster_0`, facing +Z, centre 5.5 m up | 6.8 × 3.0 m |
| bus_shelter | `Poster_0` (outer, −X), `Poster_1` (inner, +X) | 1.26 × 2.12 m |
| poster_frame | `Poster_0` | 1.2 × 1.8 m (back plane z = 0, bottom y = 0) |
| hoarding | `Poster_0`, `Poster_1` | 2.9 × 2.2 m |
| lease_sign | `Poster_0` | 1.78 × 1.18 m |

`PosterSpot_<n>` and `Door_<n>` on zone and building models are not exported yet (see the
integrator section below). Keep your `wall_spots.json` fallback.

## To G2 and the integrator: import and re-export windows

1. **Import.** `tools/optimize_imports.py` did not exist at H's branch point. After merging G2, run
   `python3 -I tools/optimize_imports.py --apply models/real/vehicles_v2 models/real/street`, then one
   heavy `godot --headless --path . --import`. Only new files are affected.
2. **Zone and building re-export.** Parked cars done: the 11 models with cars were re-exported
   and imported, and the body and proxy tables re-baked. The door work below is still open.
   (Originally deferred to keep GLB churn out of the repository while disk was tight.)
   - **Ready in the generator:** `arch.parked_car` now builds real-size (1.0×) cars from the
     `vehicles_v2` body generator: hatchback, coupe, sedan or SUV, whichever fits the bay, with
     opaque glass and merged wheels. They replace the blocky placeholder cars (G1 must-fix 13). The
     house drives of `house_hip_brick` and `house_modern` now run under their carports. A scratch dry
     run of all 56 zone and building models changed only the 11 that carry cars, adding about 1,100
     triangles per car, all within budget. Bounds and footprints are unchanged.
   - **Not done:** the door fix (`DoorLeaf_*` / `Shutter_*` renames, 2.1 m leaves) and the `Door_<n>`
     and `PosterSpot_<n>` empties. Raising door openings to `z0 + 0.129` collides with porch roofs
     (house_gable's sits at `base + 0.1` to `0.115`), shop awnings and sign bands, so each of the 56
     models needs a visual pass during the re-export.
   - Until then, `fp_assets_test` reports doors as PENDING and `validate_real.py` flags
     `MISSING_Door` on zones and buildings.
   - **When disk allows:**
     1. `blender --background --python tools/blender/make_realistic_city.py -- zones buildings`
     2. `optimize_imports --apply` on those paths, then the heavy import
     3. A's body bake (`scripts/fp/player/body_bake.gd`) and G2's proxy bake (`proxy_bake.gd`)
     4. `tools/gate.sh full`
