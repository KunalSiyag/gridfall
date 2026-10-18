# S0 needs

Requests from S0 (foundation) to slices that own the files involved. Fix round 2 added the site
collider seam directly, because the old `CityView.site_bounds` contract was wrong and A builds on
it; what remains below belongs to the owners.

## To G1 (owner of `scripts/world/construction_kit.gd` and `scripts/world/city_view.gd`)

1. **Keep the site `colliders` meta complete.** `ConstructionKit.build_site` now bakes every part
   marked with `solid(node)` or `solid_box(node, aabb)` into the `Site` node's `colliders` meta
   (format and rules in `S0-foundation.md` §15.1), and `CityView.site_boxes(i)` serves it to A.
   Mark every new blocking part you add to the kit (hoarding panels from `AP.HOARDING`, barriers,
   new machines). `fp_seams_test` fails when a drawn part a walker can bump into (at least
   `STEP_HEIGHT` tall, starting below `PLAYER_HEIGHT`) lies outside every box, except under
   `Boom` arms and the progress groups `Trees`, `Stumps`, `Rebar`, `Debris` and `Planting`.
2. **Site parts stand outside the lot, on the neighbouring tile.** Measured with a scratch probe
   (not in the repo) over 819 staged-site samples with animation running: builds, zone growth,
   demolitions and road works. Each figure is how far the drawn part reaches past the tile edge:
   - **Tower crane:** up to 0.20 u (4 m). It stands at `(-foot/2 - 0.1, -foot/2 - 0.1)` in
     `build_site`'s `big` branch, so next to a road its base covers the whole sidewalk at the
     corner, and the hoarding at ±0.47 runs through it. Move the crane inside the hoarding, or set
     the hoarding back around it.
   - **Machines poking out of the hoarding:** the demolition dump truck at `(0.3, 0, -0.38)` with
     yaw `PI/2` reaches 0.11 u; the other dump trucks reach 0.06 to 0.07 u, the mixers 0.03 to
     0.05 u, and the excavator 0.04 u. Keep machine footprints inside ±0.46, or open the hoarding
     where a truck stands. `MACHINE_SCALE` (1/20 instead of 1/16) shrinks these by 20%.
   - The floodlight at `(foot/2 + 0.06, -foot/2 - 0.06)` stands between the footprint and the
     hoarding, inside the tile. This is only a note.

   Collision follows whatever the kit draws, so moving these parts needs no change on A's side.
3. **Meaning of `pos` in furniture `colliders`.** The site meta defines `pos` as the centre of the
   box's base, holder-local. Please use the same convention for road furniture (G1 spec, "`colliders`
   meta"), so A reads both with one function (`ConstructionKit.collider_aabb` already does it
   for boxes).
