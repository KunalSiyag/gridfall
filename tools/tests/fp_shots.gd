extends RefCounted
## Deterministic eye-level shots for a grown city (docs/fp/S0-foundation.md §17.5). Each shot is
## {"name", "pos" (feet), "yaw" (deg), "pitch" (deg), "hour"}. The FP photo tour and fp_bench use it.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const DAY_HOUR := 10.5
const ORDER := ["street", "intersection", "downtown", "park", "residential", "river", "dusk", "night"]


## Deterministic eye-level shots for a grown city. Each: {"name", "pos" (feet), "yaw", "pitch", "hour"}.
## Always returns the 8 named shots; one that cannot be found falls back to the street pose.
static func find(sim: CitySim, dir: CityDirectory, col: CollisionWorld) -> Array:
	var found := {}
	found["street"] = _street(sim, col)
	found["intersection"] = _intersection(sim, col)
	found["downtown"] = _downtown(sim, dir, col)
	found["park"] = _park(sim, dir, col)
	found["residential"] = _residential(sim, dir, col)
	found["river"] = _river(sim, col)
	if (found["street"] as Dictionary).is_empty():
		found["street"] = _pose(col, Vector3(15.0, 0.0, 14.6), Vector3(0, 0, -1), 2.0)
	found["dusk"] = (found["street"] as Dictionary).duplicate()
	found["night"] = (found["intersection"] as Dictionary).duplicate() if not (found["intersection"] as Dictionary).is_empty() else (found["street"] as Dictionary).duplicate()
	var out: Array = []
	for n: String in ORDER:
		var s: Dictionary = found[n]
		if s.is_empty():
			s = (found["street"] as Dictionary).duplicate()
		s["name"] = n
		s["hour"] = 18.4 if n == "dusk" else (23.0 if n == "night" else DAY_HOUR)
		out.append(s)
	return out


## The street shot: a straight road with 5+ road tiles ahead along its axis and the most zone
## levels within 7 tiles on both sides (fp_bench's algorithm); sidewalk +1 side, looking along it.
static func _street(sim: CitySim, col: CollisionWorld) -> Dictionary:
	var best := -1
	var best_score := -1
	var best_dir := Vector2i(1, 0)
	for i in sim.active:
		if sim.kind[i] != D.ROAD or sim.terrain[i] == D.WATER:
			continue
		var m := RoadTopology.mask(sim, D.tx(i), D.ty(i))
		if m != RoadTopology.NS and m != RoadTopology.EW:
			continue
		var x := D.tx(i)
		var y := D.ty(i)
		for dv: Vector2i in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]:
			if (dv.x != 0) != (m == RoadTopology.EW):
				continue
			var straight := 0
			var score := 0
			for k in range(1, 8):
				var ax := x + dv.x * k
				var ay := y + dv.y * k
				if D.in_bounds(ax, ay) and sim.kind[D.idx(ax, ay)] == D.ROAD:
					straight += 1
				for side: int in [-1, 1]:
					var sx := ax + dv.y * side
					var sy := ay + dv.x * side
					if D.in_bounds(sx, sy) and D.is_zone(sim.kind[D.idx(sx, sy)]):
						score += sim.level[D.idx(sx, sy)]
			if straight >= 5 and score > best_score:
				best_score = score
				best = i
				best_dir = dv
	if best < 0:
		return {}
	var fwd := Vector3(best_dir.x, 0, best_dir.y)
	var right := Vector3(-fwd.z, 0, fwd.x)
	return _pose(col, Vector3(D.tx(best), 0, D.ty(best)) + right * WS.SIDEWALK_CENTER - fwd * 0.3, fwd, 2.0)


## The junction with the most developed tiles within 3, seen from the corner opposite its most
## developed quadrant, looking diagonally across.
static func _intersection(sim: CitySim, col: CollisionWorld) -> Dictionary:
	var best := -1
	var best_n := -1
	for i in sim.active:
		if sim.kind[i] != D.ROAD:
			continue
		if RoadTopology.arms(RoadTopology.mask(sim, D.tx(i), D.ty(i))).size() < 3:
			continue
		var n := _developed_near(sim, D.tx(i), D.ty(i), 3, Vector2i.ZERO)
		if n > best_n:
			best_n = n
			best = i
	if best < 0:
		return {}
	var q := Vector2i(1, 1)
	var qn := -1
	for c: Vector2i in [Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)]:
		var n := _developed_near(sim, D.tx(best), D.ty(best), 3, c)
		if n > qn:
			qn = n
			q = c
	var look := Vector3(q.x, 0, q.y).normalized()
	var pos := Vector3(D.tx(best) - q.x * WS.SIDEWALK_CENTER, 0, D.ty(best) - q.y * WS.SIDEWALK_CENTER)
	return _pose(col, pos, look, 3.0)


## The densest commercial lot (level >= 2, ties by land value) with a frontage, from its sidewalk.
static func _downtown(sim: CitySim, dir: CityDirectory, col: CollisionWorld) -> Dictionary:
	var best := -1
	for i in sim.active:
		if sim.kind[i] != D.ZONE_C or sim.level[i] < 2 or dir.frontage(i) < 0:
			continue
		if best < 0 or sim.level[i] > sim.level[best] or (sim.level[i] == sim.level[best] and sim.land_value[i] > sim.land_value[best]):
			best = i
	return _facing(sim, dir, col, best, 15.0)


## A park with a frontage, else the first forest tile next to a road.
static func _park(sim: CitySim, dir: CityDirectory, col: CollisionWorld) -> Dictionary:
	for i in sim.active:
		if sim.kind[i] == D.PARK and dir.frontage(i) >= 0:
			return _facing(sim, dir, col, i, 4.0)
	for i in sim.active:
		if sim.kind[i] == D.FOREST and dir.frontage(i) >= 0:
			return _facing(sim, dir, col, i, 4.0)
	return {}


## The residential lot (level >= 1) with the most residential neighbours, with a frontage.
static func _residential(sim: CitySim, dir: CityDirectory, col: CollisionWorld) -> Dictionary:
	var best := -1
	var best_n := -1
	for i in sim.active:
		if sim.kind[i] != D.ZONE_R or sim.level[i] < 1 or dir.frontage(i) < 0:
			continue
		var n := 0
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var x := D.tx(i) + dx
				var y := D.ty(i) + dy
				if (dx != 0 or dy != 0) and D.in_bounds(x, y) and sim.kind[D.idx(x, y)] == D.ZONE_R:
					n += 1
		if n > best_n:
			best_n = n
			best = i
	return _facing(sim, dir, col, best, 6.0)


## A bridge sidewalk looking along the river, else a road by core water looking at the water.
static func _river(sim: CitySim, col: CollisionWorld) -> Dictionary:
	for i in sim.active:
		if RoadTopology.is_bridge(sim, i) and str(RoadTopology.piece(RoadTopology.mask(sim, D.tx(i), D.ty(i)))[0]) == "straight":
			var m := RoadTopology.mask(sim, D.tx(i), D.ty(i))
			var right := RoadTopology.run_right(m)
			return _pose(col, RoadTopology.sidewalk_point(sim, i, 1), (right + RoadTopology.run_dir(m) * 0.6).normalized(), 0.0)
	var best := -1
	var best_n := 0
	var best_dir := Vector2i.ZERO
	for i in sim.active:
		if sim.kind[i] != D.ROAD or sim.terrain[i] == D.WATER or not D.in_core(D.tx(i), D.ty(i)):
			continue
		var n := 0
		var wdir := Vector2i.ZERO
		for dv: Vector2i in [Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, -1), Vector2i(-1, 0)]:
			var x := D.tx(i) + dv.x
			var y := D.ty(i) + dv.y
			if D.in_bounds(x, y) and sim.terrain[D.idx(x, y)] == D.WATER and sim.kind[D.idx(x, y)] != D.ROAD:
				n += 1
				if wdir == Vector2i.ZERO:
					wdir = dv
		if n > best_n:
			best_n = n
			best = i
			best_dir = wdir
	if best < 0:
		return {}
	var w := Vector3(best_dir.x, 0, best_dir.y)
	return _pose(col, Vector3(D.tx(best), 0, D.ty(best)) + w * WS.SIDEWALK_CENTER, w, -4.0)


## Standing on the frontage sidewalk of lot i, facing it.
static func _facing(sim: CitySim, dir: CityDirectory, col: CollisionWorld, i: int, pitch: float) -> Dictionary:
	if i < 0:
		return {}
	var f := dir.frontage(i)
	if f < 0:
		return {}
	var to := Vector3(D.tx(i) - D.tx(f), 0, D.ty(i) - D.ty(f))
	return _pose(col, Vector3(D.tx(f), 0, D.ty(f)) + to * WS.SIDEWALK_CENTER, to, pitch)


## A shot dict with the feet on the ground at pos, facing look (flattened) with pitch degrees.
static func _pose(col: CollisionWorld, pos: Vector3, look: Vector3, pitch: float) -> Dictionary:
	var g := col.ground_height(pos) if col != null else NAN
	pos.y = g if not is_nan(g) else 0.0
	return {"pos": pos, "yaw": rad_to_deg(atan2(-look.x, -look.z)), "pitch": pitch}


## Developed tiles (zones at level > 0 and services) within r of (x, y); quadrant q limits the
## count to one corner (q.x, q.y signs), Vector2i.ZERO counts all.
static func _developed_near(sim: CitySim, x: int, y: int, r: int, q: Vector2i) -> int:
	var n := 0
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if q != Vector2i.ZERO and (signi(dx) != q.x or signi(dy) != q.y):
				continue
			if not D.in_bounds(x + dx, y + dy):
				continue
			var j := D.idx(x + dx, y + dy)
			var k := sim.kind[j]
			if (D.is_zone(k) and sim.level[j] > 0) or D.is_service(k):
				n += 1
	return n
