class_name GroundProfile
extends RefCounted
## The height of the ground under a point of a land tile, written once. The meshes that CityView
## and the street dressing build (the C/I pad, the rubble slab, the lot apron), the road and lot
## models authored in Blender (their heights are the WS constants, checked against the real meshes
## by tools/tests/fp_ground_profile_test.gd) and CollisionWorld.ground_height (which the hero's
## feet and everybody else's follow) all read the numbers here, so what the eye sees under the
## feet is what the feet stand on, and a step of the mesh is a step of the collision.
##
## Const-only and static: no state, no nodes, no randomness (the sim stays headless-safe).
## Local coordinates (lx, lz) are the offsets from the tile centre in tile units, -0.5 .. 0.5.
## Preload as GP, or use the class name.
##
## Lot slabs. A real building model (every zone R, C and I lot and every service building on foot)
## stands on its own slab, 8 cm high (WS.LOT_TOP) and 0.94 tile wide (WS.LOT_FOOTPRINT, half
## LOT_HALF); fresh rubble is a slightly wider slab (PAD_HALF, PAD_TOP), and so is the fallback
## pad of a stand-in model (within 1 cm of the slab's height, so the slab's number serves). The
## 0.03 tile (0.6 m) all round a slab is the lawn at GROUND_Y, so the slab edge is a step of
## LOT_TOP. Where the lot fronts a road, the apron (street_dressing.gd) climbs from the slab edge
## to the road's sidewalk over the last 0.03.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")

## Half the width of a real lot slab (the model's own, authored 0.94 wide).
const LOT_HALF := WS.LOT_FOOTPRINT * 0.5
## Half the width of the rubble slab and of a stand-in C/I model's pad (CityView builds them 0.96
## wide).
const PAD_HALF := 0.48
## The tile edge, where the road's sidewalk begins.
const TILE_HALF := 0.5
## The apron runs from the lot slab's edge to the tile edge, toward the road.
const APRON_FROM := LOT_HALF
const APRON_TO := TILE_HALF
## The sides an apron can lie on, as (dx, dy) toward the road (the order of the bits of apron_mask).
const SIDES: Array[Vector2i] = [Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, -1), Vector2i(-1, 0)]


## The height of the slab of land tile i (a built lot, a service building's lot, rubble), or
## WS.GROUND_Y where the tile has none (open ground, a vacant lot, a construction site).
static func slab_top(sim: CitySim, i: int) -> float:
	var k := sim.kind[i]
	if k == D.EMPTY or k == D.FOREST or k == D.SITE:
		return WS.GROUND_Y
	if D.is_zone(k):
		return WS.GROUND_Y if sim.level[i] <= 0 else WS.LOT_TOP
	if k == D.RUBBLE:
		return WS.PAD_TOP
	return WS.LOT_TOP


## Half the width of the slab slab_top() describes: the rubble is a little wider than a real
## model's own slab.
static func slab_half(sim: CitySim, i: int) -> float:
	return PAD_HALF if sim.kind[i] == D.RUBBLE else LOT_HALF


## Which sides of tile i carry an apron, as bits in SIDES order: a built zone lot has one on the
## road it fronts (frontage, a road tile index or -1; every road side for a C/I lot), a service
## building's lot on every road side. 0 for tiles that are not a built lot.
static func apron_mask(sim: CitySim, i: int, frontage: int) -> int:
	var k := sim.kind[i]
	if k == D.ROAD or k == D.EMPTY or k == D.FOREST or k == D.SITE or k == D.RUBBLE:
		return 0
	if sim.terrain[i] == D.WATER:
		return 0
	var every := true
	if D.is_zone(k):
		if sim.level[i] <= 0:
			return 0
		every = k != D.ZONE_R
	var x := D.tx(i)
	var y := D.ty(i)
	var mask := 0
	for s in range(4):
		var nx := x + SIDES[s].x
		var ny := y + SIDES[s].y
		if not D.in_bounds(nx, ny) or sim.kind[D.idx(nx, ny)] != D.ROAD:
			continue
		if every or D.idx(nx, ny) == frontage:
			mask |= 1 << s
	return mask


## The apron's height at distance t (tile units from the tile centre, toward the road): the slab
## edge's LOT_TOP at APRON_FROM, the sidewalk's SIDEWALK_TOP at APRON_TO.
static func apron_height(t: float) -> float:
	var u := clampf((t - APRON_FROM) / (APRON_TO - APRON_FROM), 0.0, 1.0)
	return lerpf(WS.LOT_TOP, WS.SIDEWALK_TOP, u)


## The walkable surface height at local (lx, lz) of tile i: the road's own profile on a road tile
## (RoadTopology.surface_height), NAN over open water, else the slab of a lot, the lawn, and the
## aprons of a lot that fronts a road (directory, a CityDirectory, says which road a lot fronts;
## null: none). NAN means not walkable; the shallows of a river are the river bed's (riverbed.gd),
## which the CollisionWorld offers a wader.
static func tile_height(
	sim: CitySim, i: int, lx: float, lz: float, directory: CityDirectory = null
) -> float:
	if sim.kind[i] == D.ROAD:
		return RoadTopology.surface_height(sim, i, Vector2(lx, lz))
	if sim.terrain[i] == D.WATER:
		return NAN
	var top := slab_top(sim, i)
	if top <= WS.GROUND_Y:
		return WS.GROUND_Y
	var edge := maxf(absf(lx), absf(lz))
	var h := top if edge <= slab_half(sim, i) else WS.GROUND_Y
	if edge <= APRON_FROM:
		return h
	# Only the road sides the point lies toward can carry an apron under it, and only a
	# residential lot's apron follows its frontage (apron_mask): the frontage lookup is not free
	# (it walks the road run and allocates), so it is made for no other lot and for no point that
	# is not beside a road.
	var near := 0
	for s in range(4):
		if lx * float(SIDES[s].x) + lz * float(SIDES[s].y) <= APRON_FROM:
			continue
		var nx := D.tx(i) + SIDES[s].x
		var ny := D.ty(i) + SIDES[s].y
		if D.in_bounds(nx, ny) and sim.kind[D.idx(nx, ny)] == D.ROAD:
			near |= 1 << s
	if near == 0:
		return h
	var front := -1
	if directory != null and sim.kind[i] == D.ZONE_R:
		front = directory.frontage(i)
	var aprons := apron_mask(sim, i, front) & near
	for s in range(4):
		if aprons & (1 << s):
			var t := lx * float(SIDES[s].x) + lz * float(SIDES[s].y)
			h = maxf(h, apron_height(t))
	return h
