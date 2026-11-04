extends RefCounted
## What the on-foot tree tests share (fp_tree_stream_test.gd, fp_tree_cost_test.gd): the 27 x 27
## grid of FP chunks, a few spots on the map and the documented stream radius (layer end + range
## margin + chunk half-diagonal + hysteresis) restated from the constants, so that it is an oracle
## for CityView's own (_tree_reach and friends), not a copy of it.

const D := preload("res://scripts/sim/sim_defs.gd")
## The old plant: every FP chunk of the 216 x 216 tile grid (the map plus its ring of woods).
const FULL := 729
## The Planner's plant: the chunks of the same grid in CityView.TREE_CHUNK_ORBIT tiles (flag
## orbit_tree_chunks, default on): 14 x 14, where 48-tile chunks were 5 x 5.
const ORBIT := 196
const SPAWN := Vector2(15.5, 13.5)
const CORNER := Vector2(100.0, 100.0)
## An interior spot ~77 u from the spawn: the windows of the web and medium presets do not meet.
const LANDING := Vector2(60.0, -50.0)
const EPS := 1e-4

static var _grid: Array[Vector3i] = []


## Every chunk of the grid.
static func grid() -> Array[Vector3i]:
	if _grid.is_empty():
		var n := ceili(float(D.W + 2 * CityView.TREE_RING) / CityView.TREE_CHUNK_FP)
		for cy in range(n):
			for cx in range(n):
				_grid.append(Vector3i(cx, cy, 1))
	return _grid


## The middle of chunk c's tiles (tile (x, z) sits on whole coordinates, so 8 tiles centre 3.5 in).
static func mid(c: Vector3i) -> Vector2:
	var size := float(CityView.TREE_CHUNK_FP)
	var first := Vector2(D.X0 - CityView.TREE_RING, D.Y0 - CityView.TREE_RING)
	return first + Vector2(c.x, c.y) * size + Vector2.ONE * (size - 1.0) * 0.5


static func dist(c: Vector3i, p: Vector2) -> float:
	return p.distance_to(mid(c))


## The stream radius for layers that end at `end`: the range margin, the chunk's half-diagonal (and
## half a unit for what the tree meshes add) and one hysteresis step on top.
static func reach(end: float) -> float:
	var half_diag := float(CityView.TREE_CHUNK_FP) * 0.7071 + 0.5
	return end + CityView.TREE_MARGIN_FP + half_diag + CityView.TREE_STREAM_HYSTERESIS


## The window (far layers) and the near ring (full trees) at vis_mult v.
static func window(v: float) -> float:
	return reach(CityView.TREE_FAR_FP * v)


static func ring(v: float) -> float:
	return reach(CityView.TREE_NEAR_FP * v)


## The chunks whose middle lies within r of p.
static func within(p: Vector2, r: float) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for c in grid():
		if dist(c, p) <= r:
			out.append(c)
	return out


## The tile indices of chunk c inside the map (the chunks of the ring have fewer, or none).
static func tiles(c: Vector3i) -> Array[int]:
	var out: Array[int] = []
	var x0 := D.X0 - CityView.TREE_RING + c.x * CityView.TREE_CHUNK_FP
	var z0 := D.Y0 - CityView.TREE_RING + c.y * CityView.TREE_CHUNK_FP
	for gx in range(x0, x0 + CityView.TREE_CHUNK_FP):
		for gz in range(z0, z0 + CityView.TREE_CHUNK_FP):
			if D.in_bounds(gx, gz):
				out.append(D.idx(gx, gz))
	return out


## The chunks v has planted.
static func planted(v: CityView) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for c: Vector3i in v._tree_chunks.keys():
		out.append(c)
	return out


## True when v has every chunk of a planted.
static func has_all(v: CityView, a: Array[Vector3i]) -> bool:
	for c in a:
		if not v._tree_chunks.has(c):
			return false
	return true
