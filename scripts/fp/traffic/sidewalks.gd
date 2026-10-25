extends RefCounted
## Pedestrian network (docs/fp/slices/E-traffic.md §3 Pedestrians): sidewalk polylines whose
## centrelines sit at the middle of WS.PED_BAND from the road centreline, joined around junction
## corners, around corner tiles and around cul-de-sacs, plus a zebra edge across every arm of a tee
## or cross. Nodes are merged by position, so tiles join at their shared edges.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const HEAP := preload("res://scripts/fp/traffic/heap.gd")
## Walking line: the middle of the pedestrian band.
const LAT := (WS.PED_BAND[0] + WS.PED_BAND[1]) * 0.5
const ZEBRA := LG.ZEBRA_MID
const STEP := 0.04
## Loop radius around a cul-de-sac's turning circle (its centre is offset toward the closed end).
const END_R := WS.END_CIRCLE_R + (LAT - WS.ROAD_HALF)
const DIRS := LG.DIRS


## One walkable edge between two nodes.
class PedEdge extends RefCounted:
	var id: int = -1
	var a: int = -1
	var b: int = -1
	var tile: int = -1
	var zebra: bool = false
	var arm: int = -1                 # zebra: the arm it crosses
	var pts := PackedVector2Array()
	var ys := PackedFloat32Array()    # surface height per point
	var cum := PackedFloat32Array()
	var length: float = 0.0
	var walkers: Array = []           # walkers on it now (zebras: cars yield to them)
	var alive: bool = true


var sim: CitySim
var nodes := PackedVector2Array()
var adj: Array = []                   # node id -> Array[int] edge ids
var edges: Array = []                 # id -> PedEdge or null
var by_tile: Dictionary = {}          # tile -> Array[PedEdge]
## (tile * 4 + arm) -> zebra PedEdge.
var zebras: Dictionary = {}
var _node_key: Dictionary = {}
var _free: Array[int] = []


func setup(p_sim: CitySim) -> void:
	sim = p_sim
	clear()


func clear() -> void:
	for e: Variant in edges:
		if e != null:
			(e as PedEdge).alive = false
	nodes = PackedVector2Array()
	adj.clear()
	edges.clear()
	by_tile.clear()
	zebras.clear()
	_node_key.clear()
	_free.clear()


func rebuild_all() -> void:
	clear()
	for i in sim.active:
		if sim.kind[i] == D.ROAD:
			rebuild_tile(i)


func rebuild_around(i: int) -> void:
	rebuild_tile(i)
	var x := D.tx(i)
	var y := D.ty(i)
	for d: Vector2 in DIRS:
		if D.in_bounds(x + int(d.x), y + int(d.y)):
			rebuild_tile(D.idx(x + int(d.x), y + int(d.y)))


func edge_count() -> int:
	return edges.size() - _free.size()


func edge(id: int) -> PedEdge:
	return edges[id] if id >= 0 and id < edges.size() else null


func zebra_at(tile: int, arm: int) -> PedEdge:
	return zebras.get(tile * 4 + arm, null)


## Point and height at distance t along e.
func pos_at(e: PedEdge, t: float) -> Vector3:
	var n := e.pts.size()
	if t <= 0.0:
		return Vector3(e.pts[0].x, e.ys[0], e.pts[0].y)
	if t >= e.length:
		return Vector3(e.pts[n - 1].x, e.ys[n - 1], e.pts[n - 1].y)
	var k := clampi(int(t / STEP), 0, n - 2)
	while k > 0 and e.cum[k] > t:
		k -= 1
	while k < n - 2 and e.cum[k + 1] < t:
		k += 1
	var f := clampf((t - e.cum[k]) / maxf(e.cum[k + 1] - e.cum[k], 1e-6), 0.0, 1.0)
	var p := e.pts[k].lerp(e.pts[k + 1], f)
	# Heights step at the curb itself rather than ramping over (or snapping to) a whole sample.
	var y := e.ys[k]
	if e.ys[k + 1] != y:
		var m := RoadTopology.mask(sim, D.tx(e.tile), D.ty(e.tile))
		var lp := p - Vector2(D.tx(e.tile), D.ty(e.tile))
		y = WS.ASPHALT_TOP if RoadTopology.is_carriageway(m, lp) else WS.SIDEWALK_TOP
	return Vector3(p.x, y, p.y)


## Unit direction of e at t (a -> b).
func dir_at(e: PedEdge, t: float) -> Vector2:
	var n := e.pts.size()
	var k := clampi(int(clampf(t, 0.0, e.length) / STEP), 0, n - 2)
	while k > 0 and e.cum[k] > t:
		k -= 1
	while k < n - 2 and e.cum[k + 1] < t:
		k += 1
	var d := e.pts[k + 1] - e.pts[k]
	return d.normalized() if d.length_squared() > 0.0 else Vector2(1, 0)


## The node at the far end of edge e from node n.
func other(e: PedEdge, n: int) -> int:
	return e.b if e.a == n else e.a


## Nearest node to world xz point p among the nodes of tile i (and its edges), or -1.
func nearest_node(p: Vector2, i: int) -> int:
	var best := -1
	var bd := INF
	for e: PedEdge in by_tile.get(i, []):
		if e.zebra:
			continue
		for n: int in [e.a, e.b]:
			var d := nodes[n].distance_squared_to(p)
			if d < bd:
				bd = d
				best = n
	return best


## Nearest point on a sidewalk (non-zebra) edge of tile i to p: [edge, t] or [].
func nearest_on_tile(p: Vector2, i: int) -> Array:
	var best: Array = []
	var bd := INF
	for e: PedEdge in by_tile.get(i, []):
		if e.zebra:
			continue
		for k in range(e.pts.size() - 1):
			var a := e.pts[k]
			var ab := e.pts[k + 1] - a
			var u := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
			var d := (a + ab * u).distance_squared_to(p)
			if d < bd:
				bd = d
				best = [e, e.cum[k] + u * (e.cum[k + 1] - e.cum[k])]
	return best


## A* over the network from node `from` to node `to`: [[edge id, dir (+1 a->b, -1 b->a)], ...]
## or [] when unreachable within max_nodes expansions.
func route(from: int, to: int, max_nodes: int = 6000) -> Array:
	if from < 0 or to < 0:
		return []
	if from == to:
		return []
	var goal := nodes[to]
	var heap: HEAP = HEAP.new()
	heap.push(0.0, from)
	var g := {from: 0.0}
	var prev := {}
	var expanded := 0
	while not heap.is_empty() and expanded < max_nodes:
		var cur: int = heap.pop()
		expanded += 1
		if cur == to:
			var out: Array = []
			var c := cur
			while c != from:
				var eid: int = prev[c]
				var e: PedEdge = edges[eid]
				out.push_front([eid, 1 if e.b == c else -1])
				c = other(e, c)
			return out
		for eid: int in adj[cur]:
			var e: PedEdge = edges[eid]
			if e == null:
				continue
			var nn := other(e, cur)
			var ng := float(g[cur]) + e.length * (1.6 if e.zebra else 1.0)
			if ng < float(g.get(nn, INF)):
				g[nn] = ng
				prev[nn] = eid
				heap.push(ng + nodes[nn].distance_to(goal), nn)
	return []


# ------------------------------------------------------------------ building

func _node(p: Vector2) -> int:
	var key := Vector2i(roundi(p.x * 4000.0), roundi(p.y * 4000.0))
	if _node_key.has(key):
		return _node_key[key]
	var id := nodes.size()
	nodes.append(p)
	adj.append([])
	_node_key[key] = id
	return id


func _drop_tile(i: int) -> void:
	for e: PedEdge in by_tile.get(i, []):
		e.alive = false
		(adj[e.a] as Array).erase(e.id)
		(adj[e.b] as Array).erase(e.id)
		edges[e.id] = null
		_free.append(e.id)
		if e.zebra:
			zebras.erase(i * 4 + e.arm)
	by_tile.erase(i)


func _add(i: int, local: PackedVector2Array, zebra: bool = false, arm: int = -1) -> PedEdge:
	var c := Vector2(D.tx(i), D.ty(i))
	var e := PedEdge.new()
	if _free.is_empty():
		e.id = edges.size()
		edges.append(e)
	else:
		e.id = _free.pop_back()
		edges[e.id] = e
	e.tile = i
	e.zebra = zebra
	e.arm = arm
	var m := RoadTopology.mask(sim, D.tx(i), D.ty(i))
	var n := local.size()
	e.pts.resize(n)
	e.ys.resize(n)
	e.cum.resize(n)
	var acc := 0.0
	for k in range(n):
		e.pts[k] = local[k] + c
		e.ys[k] = WS.ASPHALT_TOP if zebra and RoadTopology.is_carriageway(m, local[k]) else WS.SIDEWALK_TOP
		if k > 0:
			acc += e.pts[k].distance_to(e.pts[k - 1])
		e.cum[k] = acc
	e.length = acc
	e.a = _node(e.pts[0])
	e.b = _node(e.pts[n - 1])
	# Snap the ends onto the merged nodes so neighbouring tiles share exact points.
	e.pts[0] = nodes[e.a]
	e.pts[n - 1] = nodes[e.b]
	(adj[e.a] as Array).append(e.id)
	(adj[e.b] as Array).append(e.id)
	if not by_tile.has(i):
		by_tile[i] = []
	(by_tile[i] as Array).append(e)
	if zebra:
		zebras[i * 4 + arm] = e
	return e


## Rebuilds the sidewalk edges of tile i (removes them when it is no longer a road).
func rebuild_tile(i: int) -> void:
	_drop_tile(i)
	if sim.kind[i] != D.ROAD:
		return
	var m := RoadTopology.mask(sim, D.tx(i), D.ty(i))
	var arms: Array[int] = []
	for e in range(4):
		if m & (1 << e):
			arms.append(e)
	if arms.is_empty():
		return
	if arms.size() == 1:
		_end(i, arms[0])
	elif arms.size() == 2 and arms[1] == LG.OPP[arms[0]]:
		var a := DIRS[arms[0]]
		var p := _perp(a)
		for s: float in [1.0, -1.0]:
			_add(i, _line(-a * 0.5 + p * (s * LAT), a * 0.5 + p * (s * LAT)))
	elif arms.size() == 2:
		_corner(i, arms[0], arms[1])
	else:
		_junction(i, m)


static func _perp(a: Vector2) -> Vector2:
	return Vector2(-a.y, a.x)


func _end(i: int, arm: int) -> void:
	var a := DIRS[arm]
	var p := _perp(a)
	var o := -a * WS.END_CIRCLE_OFFSET
	# Where the arm sidewalk (lateral LAT) meets the loop of radius END_R about o.
	var t0 := sqrt(END_R * END_R - LAT * LAT) - WS.END_CIRCLE_OFFSET
	var ins: Array[Vector2] = []
	for s: float in [1.0, -1.0]:
		var q := a * t0 + p * (s * LAT)
		_add(i, _line(a * 0.5 + p * (s * LAT), q))
		ins.append(q)
	# Around the closed end, from the +1 side to the -1 side.
	var a0 := (ins[0] - o).angle()
	var a1 := (ins[1] - o).angle()
	var mid := (-a).angle()
	var da := wrapf(a1 - a0, -PI, PI)
	# Go the long way round (through the closed end).
	if absf(wrapf(a0 + da * 0.5 - mid, -PI, PI)) > PI * 0.5:
		da = da - TAU if da > 0.0 else da + TAU
	_add(i, _arc(o, END_R, a0, da))


func _corner(i: int, e1: int, e2: int) -> void:
	var a1 := DIRS[e1]
	var a2 := DIRS[e2]
	var cc := (a1 + a2) * 0.5
	# Inner and outer sidewalks: quarter arcs about the shared corner, from edge e1 to edge e2.
	for r: float in [0.5 - LAT, 0.5 + LAT]:
		var ang0 := (-a2).angle()
		var ang1 := (-a1).angle()
		_add(i, _arc(cc, r, ang0, wrapf(ang1 - ang0, -PI, PI)))


func _junction(i: int, m: int) -> void:
	# Quadrants between consecutive directions d and d + 1 (NE, SE, SW, NW).
	var closed := -1
	for e in range(4):
		if not (m & (1 << e)):
			closed = e
	for d in range(4):
		var ea := d
		var eb := (d + 1) % 4
		if ea == closed or eb == closed:
			continue
		var a := DIRS[ea]
		var b := DIRS[eb]
		var pa := a * ZEBRA + b * LAT
		var pb := b * ZEBRA + a * LAT
		var corner := (a + b) * LAT
		_add(i, _quad_bezier(pa, corner, pb))
		_add(i, _line(pa, a * 0.5 + b * LAT))
		_add(i, _line(pb, b * 0.5 + a * LAT))
	if closed >= 0:
		# The sidewalk runs straight past the closed side, from arm (closed - 1) to arm (closed + 1).
		var c := DIRS[closed]
		var a1 := DIRS[(closed + 3) % 4]
		var a2 := DIRS[(closed + 1) % 4]
		var p1 := a1 * ZEBRA + c * LAT
		var p2 := a2 * ZEBRA + c * LAT
		_add(i, _line(p1, p2))
		_add(i, _line(p1, a1 * 0.5 + c * LAT))
		_add(i, _line(p2, a2 * 0.5 + c * LAT))
	for e in range(4):
		if not (m & (1 << e)):
			continue
		var a := DIRS[e]
		var p := _perp(a)
		_add(i, _line(a * ZEBRA - p * LAT, a * ZEBRA + p * LAT), true, e)


func _line(p: Vector2, q: Vector2) -> PackedVector2Array:
	var n := maxi(1, int(ceil(p.distance_to(q) / STEP)))
	var out := PackedVector2Array()
	out.resize(n + 1)
	for k in range(n + 1):
		out[k] = p.lerp(q, float(k) / float(n))
	return out


func _arc(c: Vector2, r: float, a0: float, da: float) -> PackedVector2Array:
	var n := maxi(2, int(ceil(absf(da) * r / STEP)))
	var out := PackedVector2Array()
	out.resize(n + 1)
	for k in range(n + 1):
		var a := a0 + da * float(k) / float(n)
		out[k] = c + Vector2(cos(a), sin(a)) * r
	return out


func _quad_bezier(p0: Vector2, p1: Vector2, p2: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := 6
	for k in range(n + 1):
		var t := float(k) / float(n)
		var u := 1.0 - t
		out.append(p0 * (u * u) + p1 * (2.0 * u * t) + p2 * (t * t))
	return out
