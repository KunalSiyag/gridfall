# G1 needs

Requests from G1 (streetscape) to the slices that own the files involved. G1 has a local fallback
for every item, so none of them blocks a merge. Values are in world units (1 u = 20 m) unless
metres are given.

## To H (`tools/blender/**`, `models/**`)

1. **Done:** the 11 zone and building models with parked cars were re-exported with real-size
   `vehicles_v2` cars.
   **Box cars and a white carport frame in the R zone models** (G1 must-fix item 13). The
   residential zone GLBs bake `arch.parked_car` (`tools/blender/realcity/zones_res.py:100, 180, 208`,
   built by `arch.py:512`, also used by the C, I and service parking lots) as a black or red box on
   a white frame. At street level it is the most fake-looking thing on a residential street. Please
   rebuild it as a real car (or drop it: E parks the residents' own cars at the curb) on your next
   zone re-export. G1 cannot fix it by material.
2. **Done:** the posts stand at ±0.325 (`WS.CURB_FURNITURE`) in the re-exported road set.
   **Lit straights put two small posts in the pedestrian band.** `road_straight_lights.glb` has the
   posts of `roads.py:168-169` at model-local (±0.4, ∓0.2), inside `WS.PED_BAND` (0.355-0.405),
   where E's pedestrians walk (A raised the same point). Please move them into `WS.CURB_FURNITURE`
   (0.305-0.345) when the road set is re-exported.
3. **Manhole covers** (`Metal_Dark` in every road GLB) are untextured. On foot G1 swaps them for a
   mottled cast-iron material; a UV-mapped lid with a cast pattern would read better.
4. **Tree leaf cards.** The exporter shifts every leaf card's 0..1 UVs by one random offset per
   material, which cut each card's leaf cluster into quarters ("torn paper" trees). G1's foliage
   shader subtracts the offset it reads from the mesh's first card, so an export without the shift
   needs no change on G1's side (the offset then reads as zero).
5. **`tools/polyhaven_fetch.py` has one new entry** (G1's, as the slice contract allows): the CC0
   pure-sky dusk HDRI `qwantani_dusk_2_puresky`, saved as `env/sky_dusk.hdr`, which replaces
   `sky_night.hdr`'s city skyline on foot. Keep it when you edit the list.
6. G1 loads these when present and falls back otherwise: `AP.STREET_SIGN`, `AP.BUS_SHELTER` (with a
   `Poster_0` surface), `AP.BILLBOARD_POSTER`, `AP.CROSSWALK_RAMP`, `AP.BOLLARD`, `AP.BIKE_RACK`,
   `AP.PARKING_METER`, `AP.LEASE_SIGN`.

## To G2 (render performance)

1. **Road mid-LOD twins lose the street-level asphalt.** On foot G1 overrides two surfaces of every
   road piece per instance: `Asphalt` gets `CityView.road_fp_material()` (world-mapped asphalt with
   lane wear; instance parameter `lane_axis`, 0 is fine far away) and `Metal_Dark` a cast-iron
   material. G2's merged road twins (b1bc48a) bake the GLB's own asphalt, so the carriageway changes
   tone at the 80 m switch. Please give the twin's asphalt `view.road_fp_material()` on foot, or
   leave road pieces without twins.
2. **Construction sites (your request 1): done.** `ConstructionKit` now merges each site's static
   parts per group and material after the colliders are baked (`_merge_static`). On the day-6 test
   city the sites went from 8,236 surfaces to 3,072, and those drawn out to `CRANE_FAR` from 5,587 to
   2,072; on foot the small parts end at `WS.VIS_SITE_PART * vis_mult`. Big parts (frame floors,
   scaffold runs, hoarding) still carry to 30 u, now as a few merged meshes per site, so tall frames
   do not pop out at 160 m. A site's stage rebuild costs about 1.5 ms more CPU (merging).
3. **Texture imports (your request 2): done** with your `optimize_imports.py` rules on
   `textures/real` and `env` (VRAM compression and mipmaps; normal maps RGTC). `--check` passes on
   G1's paths. `shaders/water.gdshader` rebuilds the blue channel of the now two-channel normal map.

## To E (traffic)

1. **Cross-tile corners** follow your record, `docs/fp/requests/E-G1-corners.md` (on `fp/E`; G1 does
   not add a copy, to avoid an add/add conflict). With the traffic feature present G1 stands no pole
   on cross tiles and hangs its blades at your NE pole's `SignText_B` (`light_pole(i, 0)`), or at
   (0.42, -0.42), 4.35 m up, while that pole is not built yet. Tiles built at boot, before the
   features exist, are re-hung when the streetscape feature finds yours
   (`CityView.set_light_pole_source`), before FpMode rebuilds collision. Please tell G1 if
   `POLE_AT` or the `SignText_*` heights change.
2. **Parking strip** (your request 2): G1 puts nothing between 0.19 and 0.30 u from the centreline;
   its furniture starts at 0.305 u. Road wear and puddle decals are flat and do not block.

## To A (player)

1. **Camera fade hook** (your request 3, optional v2): done in the materials instead of a call.
   G1's batched street props (benches, bins, bollards, lamps, trees, ...) and every street-level
   leaf dither out between 1.4 m and 0.35 m from the camera (`street_dressing.gd` `NEAR_FADE`), so
   a camera backed into them sees through. Not covered: the lamp poles baked into lit road pieces,
   signs, shelters and lease boards (single nodes, rarely in the arm's way). No `fade_props_near`
   is needed; tell G1 if A still wants one.
