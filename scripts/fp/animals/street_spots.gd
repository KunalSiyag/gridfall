extends RefCounted
## Street-spot search shared by the animals feature's guaranteed spawns (pigeons.gd's ambient
## flock, cats.gd's ambient stray): the spot of the nearest straight road tile to someone, through
## each caller's own per-tile builder.

const D := preload("res://scripts/sim/sim_defs.gd")


## The spot build(i) built for the nearest road tile within r of me (flat), the nearest tile
## winning, {} when none is near or none of them has one. build(i) -> the tile's spot Dictionary
## (pigeons.gd _road_spot, cats.gd _road_side).
static func nearest_road(sim: CitySim, me: Vector3, r: float, build: Callable) -> Dictionary:
	var best := {}
	var best_d := INF
	var lim := ceili(r)
	for y in range(roundi(me.z) - lim, roundi(me.z) + lim + 1):
		for x in range(roundi(me.x) - lim, roundi(me.x) + lim + 1):
			if not D.in_bounds(x, y):
				continue
			var i := D.idx(x, y)
			if sim.kind[i] != D.ROAD:
				continue
			var d := Vector2(float(D.tx(i)) - me.x, float(D.ty(i)) - me.z).length()
			if d >= best_d or d > r:
				continue
			var s: Dictionary = build.call(i)
			if s.is_empty():
				continue
			best = s
			best_d = d
	return best
