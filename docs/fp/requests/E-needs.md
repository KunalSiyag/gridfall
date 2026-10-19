# E needs

Requests from slice E (traffic and pedestrians) to the slices that own the files involved. Every
item has a local fallback in E, so nothing here blocks E's merge.

## To G1 (road markings) and H (`tools/blender/roads.py`)

1. **The stop line belongs on the approach side of the zebra.** `roads.py:109-115` paints the stop
   bar with its inner edge at `WS.STOP_LINE` (0.35 u from the junction centre), and the zebra spans
   `ZEBRA_NEAR`..`ZEBRA_FAR` (0.375..0.47). A car held at the painted line would stand on the
   crossing while people walk it, so E holds car fronts at
   `LaneGraph.STOP_FRONT = ZEBRA_FAR + 0.4 m` (0.49 u), just outside the zebra, and
   `fp_traffic_test` checks that window instead of `STOP_LINE..STOP_LINE + 0.03`. Please move the
   painted bar to the approach side (inner edge at about 0.48 u, 0.4 m wide, as on real streets)
   and change `WS.STOP_LINE` to match through S0's request process; E then derives `STOP_FRONT`
   from it. Until then the cars stop a few metres behind the painted bar.
2. **Keep the parking strip clear.** Parked cars stand at `PARK_OFFSET` (0.245 u) and cover
   0.19..0.30 u from the road centreline, two slots per side of a straight, centred 3 m either side
   of the tile middle (`LaneGraph.slot_pose(i, k)`; `slot_valid(i, k)` drops slots near junctions,
   bridges and bus stops). Nothing that stands up (hydrants, bins, bollards) should be placed in
   that strip. If G1 paints parking bays, `slot_pose` and `slot_valid` are the ground truth.
3. **Bus stop side.** `view.bus_stops[i]` as a `Vector2i` toward the shelter's lot (G1's planned
   format). E infers the side from the neighbouring R or C lot when the value is not a `Vector2i`.
   The curb in front of a shelter is kept free of parking so the bus can pull in.

## To H (assets)

E loads each of these when present and falls back otherwise:

1. `vehicles_v2/<name>.glb` with `Wheel_FL/FR/RL/RR` hub nodes (spin about local X) and a
   single-material `<name>_lod1.glb`. E's far LOD merges whatever it gets into one vertex-coloured
   surface and flags emissive materials as lamps (head and tail lamps glow after dark), so please
   keep the lamp materials emissive in `lod1` too.
2. `street/traffic_light.glb`: mast along local −X (5.5 m, so the head hangs over the inbound lane
   from a pole at (±0.42, ±0.42)), head facing +Z, lamp meshes named `Signal_Red_*`,
   `Signal_Amber_*`, `Signal_Green_*` (E swaps per-instance `material_override`s on them), and
   `SignText_A` / `SignText_B` empties for G1's blades.
3. `street/ped_signal.glb` (not yet consumed: E draws its own until the node names are agreed).
   Proposed: a pole with its head facing +Z and two meshes `Ped_Stop` (hand) and `Ped_Walk` (person).
4. `street/stop_sign.glb` and `street/yield_sign.glb`: plate facing +Z, origin at the pole foot.
5. `vehicles_v2/bicycle.glb` with `Wheel_F` / `Wheel_R`. Until then a cyclist is a procedural
   bike and rider.

## To F (sim)

1. **Trip purpose.** A `Residents.trip_purpose(r)` helper or a purpose argument on `trip_started`.
   E derives it from `r.state` at departure ("driving to work", "driving to the shops").
2. **Car ownership.** `r.car` (or a helper). Until then every resident whose commute is `car`
   owns one, the model picked by `hash(id)`.
3. **Morning burst.** Up to 100 `_go` calls in one tick. E staggers them with a 0–6 s departure
   jitter and keeps far trips as data; spreading the calls across the sliced tick would help too.

## To A (player and interaction)

1. `anchor_of(id)` never returns NAN or `Vector3.ZERO`: when E is not drawing the resident it
   returns the tile they are at plus head height. Use `is_resident_visible(id)` to know whether
   they are drawn.
2. `blockers_near(p, r)` returns world AABBs of vehicles slower than 0.1 m/s, parked cars included.

## To B (HUD and minimap)

1. `agents_near` fills `vel` (u/s) for every moving agent and reports `heading` in S0 §11's
   convention (forward = `(-sin h, 0, -cos h)`), so stopped cars keep their orientation.
2. Kinds are `car`, `bus`, `truck`, `emergency` and `pedestrian`; cyclists report as `pedestrian`.
3. Vehicle `pick()` data: `driver_id`, `state` ("driving to work", "parked", "line 2 to Elm
   Street", "responding", "at the scene"), `dest_label` and `mood` (0..1, or "" for nobody).
4. **Cost.** E builds one snapshot of every moving agent per frame and filters it per call, so a
   second call in the same frame costs only the filter. The dictionaries are each agent's own,
   refreshed once per frame (read them at once; copy one to keep it); refreshing ~110 of them is
   the expensive part of the first call. For the minimap, `agents_packed(p, r)` returns the same
   agents as parallel packed arrays `{"pos", "vel", "heading", "kind"}` with no dictionaries
   (about 20 µs for 110 agents); please switch `_collect_markers` to it when convenient.

## To G2 (render performance)

1. People (legacy bodies, stage E1) draw as one MultiMesh per body model and layer: at most 16
   draws for every person in range (8 models × shadowed near and unshadowed far), plus shadow
   passes. The people shader swings legs and arms on the GPU, so they cost no animation CPU.
   `anim_stats()` reports `char_draws` from that; the tier counts stay 0 until stage E2.
2. Vehicles: full GLBs within 2 u (capped at 40, 11 surfaces each with the legacy models), one
   MultiMesh per model beyond.
