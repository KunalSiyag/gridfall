# D needs

Requests from slice D (posters) to the slices that own the files involved. D already works
without each of them (fallback noted), and `fp_posters_test` covers the precedence with fixtures,
so each seam lights up as soon as its owner merges.

## To G1 (`construction_kit.gd`, `city_view.gd`)

1. **`poster_slot` metas** (already in G1's contract): `{"kind", "size": Vector2 (units),
   "xform": Transform3D local to the prop}` on billboards (`"billboard"`), bus shelters
   (`"bus_shelter"`), the construction kit's frontage hoarding segment (`"hoarding"`) and lease
   boards on FP level-0 lots (`"lease"`). D reads them in `poster_surfaces.gd` (`_carrier_slot`,
   `_hoarding_slot`). Fallback today: measured quads on the legacy billboard and the gf stop, and a
   banner on the S0 kit's frontage fence. **Lease boards only appear once G1 places them.**
2. **Taller hoarding on the street side.** The S0 fence is 1 m tall (0.05 u), so the "Coming soon"
   banner is only 0.8 m high. A 2.4 m plywood hoarding on the frontage segment with a
   `poster_slot` over its outer face lets D print a full-size wrap (the layout already switches to
   the wide hoarding design for aspects under 4:1).
3. **Billboard pose (low priority).** The legacy zone-prop billboard sometimes stands close behind
   the corner of a neighbouring building, so part of its face is hidden from the spot 6 m in front
   of it (seen in the slice D photo tour). Facing it to `frontage_yaw` at the lot's street edge
   would keep every face readable.

## To H (`asset_paths.gd`, models)

1. `Poster_<n>` meshes on the billboard, shelter, hoarding and lease assets and `PosterSpot_<n>`
   empties on building walls (already in H's contract). D sets `material_override` on each
   `Poster_*` and adds no quad of its own; wall posters use the first `PosterSpot_*` facing the
   street. Fallback: D's baked wall spots (`assets/posters/wall_spots.json`).
