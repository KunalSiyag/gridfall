extends RefCounted
## GPS route for the waypoint (slice B): a breadth-first search over road tiles from the road
## nearest the player to the road nearest the waypoint, returned as world points (x, z) with only
## the corners kept: the player, every turn, the waypoint. Empty when either end has no road
## within reach or the roads do not connect.

const D := preload("res://scripts/sim/sim_defs.gd")
const N4 := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
## Tiles searched around each end for a road.
const REACH := 4


## Route from world point a to world point b along roads, as world (x, z) points.
static func find(sim: CitySim, a: Vector3, b: Vector3) -> PackedVector2Array:
	var out := PackedVector2Array()
	if sim == null or sim.kind.size() != D.W * D.H:
		return out
	var ra := near_road(sim, a)
	var rb := near_road(sim, b)
	if ra < 0 or rb < 0:
		return out
	var parent := PackedInt32Array()
	parent.resize(D.W * D.H)
	parent.fill(-2)
	parent[ra] = -1
	var q := PackedInt32Array([ra])
	var head := 0
	var kind := sim.kind
	while head < q.size() and parent[rb] == -2:
		var c := q[head]
		head += 1
		var cx := D.tx(c)
		var cy := D.ty(c)
		for dv: Vector2i in N4:
			var nx := cx + dv.x
			var ny := cy + dv.y
			if not D.in_bounds(nx, ny):
				continue
			var ni := D.idx(nx, ny)
			if parent[ni] != -2 or kind[ni] != D.ROAD:
				continue
			parent[ni] = c
			q.append(ni)
	if parent[rb] == -2:
		return out
	var tiles: Array[Vector2i] = []
	var t := rb
	while t >= 0:
		tiles.append(Vector2i(D.tx(t), D.ty(t)))
		t = parent[t]
	tiles.reverse()
	out.append(Vector2(a.x, a.z))
	for k in range(tiles.size()):
		var keep := k == 0 or k == tiles.size() - 1
		if not keep:
			keep = (tiles[k] - tiles[k - 1]) != (tiles[k + 1] - tiles[k])
		if keep:
			out.append(Vector2(tiles[k]))
	out.append(Vector2(b.x, b.z))
	return out


## The road tile nearest world point p within REACH tiles, or -1.
static func near_road(sim: CitySim, p: Vector3) -> int:
	var x := roundi(p.x)
	var y := roundi(p.z)
	var best := -1
	var best_d := INF
	for dy in range(-REACH, REACH + 1):
		for dx in range(-REACH, REACH + 1):
			if not D.in_bounds(x + dx, y + dy):
				continue
			var i := D.idx(x + dx, y + dy)
			if sim.kind[i] != D.ROAD:
				continue
			var d := Vector2(x + dx - p.x, y + dy - p.z).length_squared()
			if d < best_d:
				best_d = d
				best = i
	return best
