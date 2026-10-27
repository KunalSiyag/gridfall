extends RefCounted
## City fixtures shared by the street-level tests (fp_prop_collision_test,
## fp_walker_collision_test): a signalled cross with E's junction poles, a tee with its stop sign
## and an open construction site. Each builds only what the grown city is missing; call them from
## the test's _init, after make_ctx and before set_fp_mode, so the view grows them in.

const D := preload("res://scripts/sim/sim_defs.gd")
## Known service buildings, for opening a construction site when the grown city has none.
const SERVICES := ["water_pump", "fire_station", "coal_plant", "sewage_plant"]


## A signal-controlled cross tile, when the grown city has none: a road order on the empty
## column beside the long east-west street crosses it (a cross where it meets it, a tee where it
## reaches the L-shaped road).
static func ensure_cross(sim: CitySim) -> void:
	for i in sim.active:
		if sim.kind[i] != D.ROAD:
			continue
		if str(RoadTopology.piece(RoadTopology.mask(sim, D.tx(i), D.ty(i)))[0]) == "cross":
			return
	for x: int in [8, 3]:
		var res: Dictionary = sim.apply_action(
			0, {"type": "road", "x": x, "y": 1, "x2": x, "y2": 12}
		)
		if bool(res.get("ok", false)):
			return


## A tee tile for the stop sign, when neither the grown city nor the cross order made one: a
## one-tile road stub onto a plain straight road gives it a third arm. The stub touches nothing
## else (no other road neighbour), so no cross gains an arm.
static func ensure_tee(sim: CitySim) -> void:
	for i: int in sim.active:
		if sim.kind[i] != D.ROAD:
			continue
		if str(RoadTopology.piece(RoadTopology.mask(sim, D.tx(i), D.ty(i)))[0]) == "tee":
			return
	for i: int in sim.active:
		if sim.kind[i] != D.ROAD:
			continue
		var x := D.tx(i)
		var y := D.ty(i)
		if RoadTopology.arms(RoadTopology.mask(sim, x, y)).size() != 2:
			continue
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx := x + d.x
			var ny := y + d.y
			if not D.in_bounds(nx, ny):
				continue
			var nj := D.idx(nx, ny)
			if sim.kind[nj] != D.EMPTY or sim.terrain[nj] == D.WATER:
				continue
			var others := 0
			for e: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				if e == -d:
					continue
				if (
					D.in_bounds(nx + e.x, ny + e.y)
					and sim.kind[D.idx(nx + e.x, ny + e.y)] == D.ROAD
				):
					others += 1
			if others > 0:
				continue
			var res: Dictionary = sim.apply_action(
				0, {"type": "road", "x": nx, "y": ny, "x2": nx, "y2": ny}
			)
			if bool(res.get("ok", false)):
				return


## An open construction site, when the grown city has none: a service build order on the first
## empty lot by a road opens one at once.
static func ensure_site(sim: CitySim) -> void:
	if not sim.sites.is_empty():
		return
	for i: int in sim.active:
		if sim.kind[i] != D.EMPTY or sim.terrain[i] == D.WATER:
			continue
		var x := D.tx(i)
		var y := D.ty(i)
		if not _by_a_road(sim, x, y):
			continue
		for name: String in SERVICES:
			var res: Dictionary = sim.apply_action(
				0, {"type": "build", "building": name, "x": x, "y": y}
			)
			if bool(res.get("ok", false)):
				return
		return


static func _by_a_road(sim: CitySim, x: int, y: int) -> bool:
	for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if D.in_bounds(x + d.x, y + d.y) and sim.kind[D.idx(x + d.x, y + d.y)] == D.ROAD:
			return true
	return false
