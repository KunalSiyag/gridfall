class_name CollisionWorld
extends Node
## Analytic first-person collision: walkable ground height per point, building boxes per tile
## (from CityView.building_aabb), water. Deterministic and headless-safe.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")

var ctx: FpContext
## Tile index -> cached merged blocking box (AABB() when the tile has none).
var _boxes: Dictionary = {}


## Stores the context; boxes are computed lazily from ctx.view.
func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx


## Drops every cached box (after view.setup).
func rebuild_all() -> void:
	_boxes.clear()


## Invalidates tile i's cached box.
func on_tile_built(i: int, _holder: Node3D) -> void:
	_boxes.erase(i)


## Invalidates tile i's cached box.
func on_tile_cleared(i: int) -> void:
	_boxes.erase(i)


## Tile index at a world point (round x/z, D.idx) or -1 outside the world.
func tile_at(p: Vector3) -> int:
	var x := roundi(p.x)
	var y := roundi(p.z)
	return D.idx(x, y) if D.in_bounds(x, y) else -1


## World y of the walkable surface at p.x/p.z; NAN when not walkable (water, bridge parapet).
func ground_height(p: Vector3) -> float:
	var i := tile_at(p)
	if i < 0:
		return WS.GROUND_Y
	var sim := ctx.sim
	var k := sim.kind[i]
	if k == D.ROAD:
		return RoadTopology.surface_height(sim, i, Vector2(p.x - D.tx(i), p.z - D.ty(i)))
	if sim.terrain[i] == D.WATER:
		return NAN
	if D.is_zone(k):
		if sim.level[i] <= 0:
			return WS.GROUND_Y
		return WS.LOT_TOP if k == D.ZONE_R else WS.PAD_TOP
	if k == D.RUBBLE:
		return WS.PAD_TOP
	if k == D.EMPTY or k == D.FOREST or k == D.SITE:
		return WS.GROUND_Y
	return WS.LOT_TOP


## Surface name for footsteps and audio: "asphalt"|"sidewalk"|"lot"|"grass"|"dirt"|"water"|"bridge".
func surface_at(p: Vector3) -> String:
	var i := tile_at(p)
	if i < 0:
		return "grass"
	var sim := ctx.sim
	var k := sim.kind[i]
	if k == D.ROAD:
		if RoadTopology.is_bridge(sim, i):
			return "bridge"
		var m := RoadTopology.mask(sim, D.tx(i), D.ty(i))
		return "asphalt" if RoadTopology.is_carriageway(m, Vector2(p.x - D.tx(i), p.z - D.ty(i))) else "sidewalk"
	if sim.terrain[i] == D.WATER:
		return "water"
	if k == D.EMPTY or k == D.FOREST or k == D.PARK or (D.is_zone(k) and sim.level[i] <= 0):
		return "grass"
	if k == D.SITE or k == D.RUBBLE:
		return "dirt"
	return "lot"


## True if a circle of `radius` at p (feet) intersects a building box or unwalkable ground.
## Boxes are grown by radius in xz (a square, so it agrees with tests that grow AABBs).
func is_blocked(p: Vector3, radius: float) -> bool:
	if is_nan(ground_height(p)):
		return true
	var cx := roundi(p.x)
	var cz := roundi(p.z)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if not D.in_bounds(cx + dx, cz + dz):
				continue
			var b := box(D.idx(cx + dx, cz + dz))
			if b.size.x <= 0.0 or p.y >= b.end.y:
				continue
			if p.x > b.position.x - radius and p.x < b.end.x + radius and p.z > b.position.z - radius and p.z < b.end.z + radius:
				return true
	return false


## Moves from `from` by `motion` (y ignored), sliding along blockers. S0: try full move, else x-only,
## else z-only, else stay. Returns the new feet position (y unchanged).
func move_and_slide(from: Vector3, motion: Vector3, radius: float) -> Vector3:
	var full := Vector3(from.x + motion.x, from.y, from.z + motion.z)
	if not is_blocked(full, radius):
		return full
	if motion.x != 0.0:
		var xo := Vector3(from.x + motion.x, from.y, from.z)
		if not is_blocked(xo, radius):
			return xo
	if motion.z != 0.0:
		var zo := Vector3(from.x, from.y, from.z + motion.z)
		if not is_blocked(zo, radius):
			return zo
	return from


## Ray against building boxes (tile DDA, ≤ max_dist) and the ground.
## {"hit": bool, "pos": Vector3, "normal": Vector3, "tile": int, "kind": "building"|"ground", "dist": float}
func raycast(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	var miss := {"hit": false, "pos": Vector3.ZERO, "normal": Vector3.ZERO, "tile": -1, "kind": "", "dist": max_dist}
	if dir.length_squared() < 1e-12 or max_dist <= 0.0:
		return miss
	var d := dir.normalized()
	var ox := origin.x + 0.5
	var oz := origin.z + 0.5
	var gx := floori(ox)
	var gz := floori(oz)
	var step_x := 1 if d.x > 0.0 else -1
	var step_z := 1 if d.z > 0.0 else -1
	var t_max_x := INF
	var t_max_z := INF
	var t_dx := INF
	var t_dz := INF
	if absf(d.x) > 1e-9:
		t_dx = 1.0 / absf(d.x)
		t_max_x = ((gx + 1 - ox) if d.x > 0.0 else (ox - gx)) * t_dx
	if absf(d.z) > 1e-9:
		t_dz = 1.0 / absf(d.z)
		t_max_z = ((gz + 1 - oz) if d.z > 0.0 else (oz - gz)) * t_dz
	var best := miss
	var best_t := INF
	var t := 0.0
	var guard := 0
	while t <= max_dist and guard < 4096:
		guard += 1
		var seg_end := minf(minf(t_max_x, t_max_z), max_dist)
		var i := D.idx(gx, gz) if D.in_bounds(gx, gz) else -1
		if i >= 0:
			var b := box(i)
			if b.size.x > 0.0:
				var hit := _ray_box(origin, d, b)
				if not hit.is_empty() and float(hit["t"]) < best_t and float(hit["t"]) <= max_dist:
					best_t = float(hit["t"])
					best = {"hit": true, "pos": origin + d * best_t, "normal": hit["normal"], "tile": i, "kind": "building", "dist": best_t}
		# Ground: the walkable height at the segment middle (water and parapets use the water surface).
		var mid := origin + d * ((t + seg_end) * 0.5)
		var g := ground_height(mid)
		if is_nan(g):
			g = WS.WATER_Y
		var ya := origin.y + d.y * t
		var yb := origin.y + d.y * seg_end
		if ya >= g and yb <= g and d.y < 0.0:
			var tg := (g - origin.y) / d.y
			if tg < best_t:
				best_t = tg
				best = {"hit": true, "pos": origin + d * tg, "normal": Vector3.UP, "tile": i, "kind": "ground", "dist": tg}
		if best_t <= seg_end or seg_end >= max_dist:
			break
		t = seg_end
		if t_max_x < t_max_z:
			gx += step_x
			t_max_x += t_dx
		else:
			gz += step_z
			t_max_z += t_dz
	return best


## Blocking bodies on tile i for movement, world space. S0 returns [box(i)] when box(i) has a size,
## else []. A replaces it with per-part bodies (at most 4 per building) plus a site box.
func boxes(i: int) -> Array[AABB]:
	var out: Array[AABB] = []
	var b := box(i)
	if b.size.x > 0.0:
		out.append(b)
	return out


## Merged bound of boxes(i) (AABB() when none). Movement and tests use boxes(); interaction
## raycasts use the full view.building_aabb(i).
func box(i: int) -> AABB:
	if i < 0:
		return AABB()
	var cached: Variant = _boxes.get(i)
	if cached != null:
		return cached
	var b := AABB()
	if ctx != null and ctx.view != null and ctx.sim != null:
		b = ctx.view.building_aabb(i)
		if ctx.sim.sites.has(i):
			var s := ctx.view.site_bounds(i)
			if s.size.x > 0.0:
				b = s if b.size.x <= 0.0 else b.merge(s)
	_boxes[i] = b
	return b


## Slab test; {"t": float, "normal": Vector3} for the entry point, {} on a miss or when the origin is inside.
static func _ray_box(o: Vector3, d: Vector3, b: AABB) -> Dictionary:
	var t0 := -INF
	var t1 := INF
	var n := Vector3.ZERO
	for axis in range(3):
		var lo := b.position[axis]
		var hi := b.end[axis]
		if absf(d[axis]) < 1e-12:
			if o[axis] < lo or o[axis] > hi:
				return {}
			continue
		var a := (lo - o[axis]) / d[axis]
		var c := (hi - o[axis]) / d[axis]
		var nsign := -1.0
		if a > c:
			var tmp := a
			a = c
			c = tmp
			nsign = 1.0
		if a > t0:
			t0 = a
			n = Vector3.ZERO
			n[axis] = nsign
		t1 = minf(t1, c)
		if t0 > t1:
			return {}
	if t0 < 0.0:
		return {}
	return {"t": t0, "normal": n}
