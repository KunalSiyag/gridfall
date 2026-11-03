extends RefCounted
## The river-bed height, written once. CityView builds the bed mesh from node_height() and
## CollisionWorld lets the hero wade on tile_height(), which interpolates the mesh's own triangles,
## so what the eye sees under the water is what the feet stand on. Const-only: no state, no nodes,
## no randomness, so the sim stays headless-safe. Preload as RB.
##
## A water tile is a 4x4 grid of nodes at 0, BANK_W, 1 - BANK_W and 1 along each axis, split into
## 3x3 cells of two triangles each (a-b-c and a-c-d, a the corner nearest the tile's origin). A node
## sits at GROUND_Y where it touches land and sinks to RIVERBED_Y a bank's width inside the tile, so
## the banks are straight ramps of slope (GROUND_Y - RIVERBED_Y) / BANK_W (0.4 here, 22 degrees).

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")

## Bank width in tile units (4 m): the ramp from the grass down to the bed. A gentler shelf than the
## old 2 m, whose 0.8 slope no walker could climb (STEP_HEIGHT is 25 cm).
const BANK_W := 0.2
## The node coordinates along each axis of a water tile.
const NODES: Array[float] = [0.0, BANK_W, 1.0 - BANK_W, 1.0]
const CORNERS: Array[Vector2] = [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]


## True for an in-world water tile. Outside the world counts as land (the bank closes the edge).
static func is_water_at(sim: CitySim, x: int, y: int) -> bool:
	return D.in_bounds(x, y) and sim.terrain[D.idx(x, y)] == D.WATER


## Which of the eight neighbours of tile (x, y) are land: north, east, south, west (the
## edges), then the north-west, north-east, south-east and south-west corners (CORNERS order).
static func land_flags(sim: CitySim, x: int, y: int) -> Array[bool]:
	var out: Array[bool] = [
		not is_water_at(sim, x, y - 1),
		not is_water_at(sim, x + 1, y),
		not is_water_at(sim, x, y + 1),
		not is_water_at(sim, x - 1, y),
		not is_water_at(sim, x - 1, y - 1),
		not is_water_at(sim, x + 1, y - 1),
		not is_water_at(sim, x + 1, y + 1),
		not is_water_at(sim, x - 1, y + 1),
	]
	return out


## Distance (tile units) from the point (gx, gy) of a water tile, each 0..1 across the tile, to the
## land that touches it: an edge neighbour counts from its shared edge, a corner neighbour from the
## shared corner. 2.0 when no neighbour is land.
static func land_distance(land: Array[bool], gx: float, gy: float) -> float:
	var dist := 2.0
	if land[0]:
		dist = minf(dist, gy)
	if land[1]:
		dist = minf(dist, 1.0 - gx)
	if land[2]:
		dist = minf(dist, 1.0 - gy)
	if land[3]:
		dist = minf(dist, gx)
	for k in range(4):
		if land[4 + k]:
			dist = minf(dist, Vector2(gx, gy).distance_to(CORNERS[k]))
	return dist


## The bed height at node (gx, gy): GROUND_Y at the land, RIVERBED_Y a bank's width away.
static func node_height(land: Array[bool], gx: float, gy: float) -> float:
	return lerpf(WS.GROUND_Y, WS.RIVERBED_Y, smoothstep(0.0, BANK_W, land_distance(land, gx, gy)))


## The bed height at (lx, ly) of a water tile, each 0..1 across it: the mesh's own triangle there.
static func tile_height(land: Array[bool], lx: float, ly: float) -> float:
	var x := clampf(lx, 0.0, 1.0)
	var y := clampf(ly, 0.0, 1.0)
	var c := clampi(_cell(x), 0, 2)
	var r := clampi(_cell(y), 0, 2)
	var u := (x - NODES[c]) / (NODES[c + 1] - NODES[c])
	var v := (y - NODES[r]) / (NODES[r + 1] - NODES[r])
	var ha := node_height(land, NODES[c], NODES[r])
	var hb := node_height(land, NODES[c + 1], NODES[r])
	var hc := node_height(land, NODES[c + 1], NODES[r + 1])
	var hd := node_height(land, NODES[c], NODES[r + 1])
	if u >= v:
		return ha + u * (hb - ha) + v * (hc - hb)
	return ha + u * (hc - hd) + v * (hd - ha)


## The bed height under world point (x, z), or NAN when its tile is not water.
static func bed_height(sim: CitySim, x: float, z: float) -> float:
	var tx := roundi(x)
	var ty := roundi(z)
	if not is_water_at(sim, tx, ty):
		return NAN
	return tile_height(land_flags(sim, tx, ty), x - float(tx) + 0.5, z - float(ty) + 0.5)


## How deep the water is over the bed at world point (x, z), in world units: 0 on land and where
## the bed is above the surface (the dry part of a bank), WATER_Y - bed elsewhere.
static func depth_at(sim: CitySim, x: float, z: float) -> float:
	var bed := bed_height(sim, x, z)
	return 0.0 if is_nan(bed) else maxf(0.0, WS.WATER_Y - bed)


static func _cell(t: float) -> int:
	if t < NODES[1]:
		return 0
	return 1 if t < NODES[2] else 2
