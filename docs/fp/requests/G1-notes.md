# G1 notes for other slices

Notes from G1 (streetscape) about changes other slices consume. Values are in world units
(1 u = 20 m) unless metres are given.

## To A (player and collision): the ground datum moved

G1 changed the ground datum in `scripts/fp/world_scale.gd` in the same commit as the geometry (S0 §4.3):

| Constant | Before | Now | Geometry |
|---|---|---|---|
| `GROUND_Y` | -0.012 | **0.0** | Base grass, now merged land quads per 64-tile chunk; no ground under water tiles. |
| `LOT_TOP` | 0.004 | 0.004 | Real-model lot slab top (unchanged). |
| `PAD_TOP` | 0.006 | **`LOT_TOP + 0.0002`** | FP rubble is a closed earth slab up to `PAD_TOP`; C/I fallback pads sit there. |
| `WATER_Y` | 0.03 | **-0.03** (-0.6 m) | Water surface, 60 cm below the banks. |
| `RIVERBED_Y` | -0.004 | **-0.08** (-1.6 m) | Riverbed; the banks slope from `GROUND_Y` at the tile edge down to the bed over 0.1 u (2 m) inside each water tile that touches land. |

What this means for `CollisionWorld`:

- `ground_height` needs no change: it already returns `GROUND_Y` / `LOT_TOP` / `PAD_TOP` by kind.
  The step from grass up to the sidewalk is now 0.009 u (18 cm), inside `STEP_HEIGHT`.
- Water tiles stay unwalkable (`NAN`). The visible bank slope lies inside the water tile, so the
  edge where walking stops is still the tile edge, now with a drop to the water 60 cm below.
- The ray's water fallback (`g = WS.WATER_Y`) now hits the water 60 cm below the bank, which is
  where it is drawn.
- Vacant lots on foot are flush earth patches at `GROUND_Y` (no pad), as `ground_height` says.
- Sidewalk aprons (a sloped paving strip from the lot slab at `LOT_TOP`, 0.47 from the lot centre, up
  to `SIDEWALK_TOP` at the tile edge) fill the 0.03 u gap on a lot's frontage side (every road side
  for C, I and service lots). `ground_height` returns the lot height there; the difference is at most
  10 cm.

## To A: furniture colliders

Every road holder built on foot carries `colliders` meta before `tile_built` fires, also when it
holds no furniture (an empty Array). Entries use the site convention (`pos` = centre of the base,
holder-local) and add `"h"` (height) on cylinders and `"kind"` (tree, bench, bin, bollard, hydrant,
mailbox, planter, utility, rack, meter, lamp, sign, shelter, billboard, lease) for debugging. The baked
lamp poles of lit straights are included. Tree grates and kerb ramps are walkable and have none.
Lease boards and billboards on vacant lots put their entries on the lot holder.

## To A: cross-tile sign poles and merged site meshes

- With E's traffic feature present, cross tiles carry no G1 sign pole (E's NE light pole holds the
  blades), so no `kind: "sign"` collider on them. Tiles built at boot get their pole and its collider
  removed when the streetscape feature sets up, which runs before FpMode's `collision.rebuild_all()`.
- `ConstructionKit` merges each site's static parts into a few meshes per group and material after
  baking the `colliders` meta. The meta and `CityView.site_boxes(i)` are unchanged; every merged mesh
  stays inside one collider box (`fp_seams_test` checks it).
