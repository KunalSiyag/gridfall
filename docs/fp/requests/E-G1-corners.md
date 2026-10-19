# E and G1: cross-tile corners

Recorded agreement (ARCHITECTURE §7.4, `slices/E-traffic.md` §2).

- **E owns all four corners of every cross tile** (mask 15). E places a traffic-light pole at each
  corner, at tile-local `(±0.42, ±0.42)` on the sidewalk (`junctions.gd`, `POLE_AT`), with its
  mast along local −X reaching over the inbound lane it serves:
  NE serves northbound traffic (from the S arm), SE eastbound (W arm), SW southbound (N arm) and
  NW westbound (E arm).
- E also places a pedestrian signal at both ends of every zebra, in `CURB_FURNITURE`
  (0.325 u from the arm's axis), just beyond the zebra's far edge (`ZEBRA_FAR + 0.3 m`, 0.485 u
  from the centre), beside the crossing rather than in the walking line.
- **G1 places no pole of its own on cross tiles.** G1's street-name blades mount on E's NE pole:
  `traffic.light_pole(i, 0)` returns it (`null` while the feature is not built or the tile is not a
  cross). It carries two empties, `SignText_A` (4.6 m, facing the pole's +Z) and `SignText_B`
  (4.35 m, turned 90°), from H's traffic-light asset when present, else from E's procedural pole.
- E rebuilds a junction's furniture on `view.tile_built` / `tile_cleared` for that tile and its
  neighbours, and on `world_rebuilt`. G1 should look the pole up again after those signals rather
  than keep a reference (the old pole is freed).
- Tee tiles: E puts a stop sign (yield on a residential stem) on the stem's right-hand curb at the
  stop point, in `CURB_FURNITURE`. G1 may place a name blade on tees on its own pole, clear of
  that sign.
