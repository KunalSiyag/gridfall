extends SceneTree
## Boats on the river (scripts/world/city_life.gd): they sail open water only, never through a
## bridge, turn back where a bridge stands ahead of them, and float with their waterline at the
## water surface. A grown city with a river and its bridges; time runs through _update_boats.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const DT := 0.1
const STEPS := 3000
const DIRS := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]

var fails: Array[String] = []
var sim: CitySim
var life: CityLife
var bridges: Array[int] = []


func _init() -> void:
	await process_frame
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true})
	sim = ctx.sim
	life = ctx.view.life
	var water := 0
	for i in sim.active:
		if sim.terrain[i] == D.WATER:
			water += 1
			if sim.kind[i] == D.ROAD:
				bridges.append(i)
	var fixture := "fixture: a river with bridges (%d tiles, %d bridges)" % [water, bridges.size()]
	K.check(fails, water > 20 and not bridges.is_empty(), fixture)
	var boats: Array = life.get("_boats")
	K.check(fails, not boats.is_empty(), "boats sail the river (%d)" % boats.size())
	if bridges.is_empty() or boats.is_empty():
		K.finish(self, "FP_BOATS_TEST", fails)
		return
	_check_sailing(boats)
	_check_turn_back(boats[0])
	K.finish(self, "FP_BOATS_TEST", fails)


func _bridge(t: Vector2i) -> bool:
	return sim.kind[D.idx(t.x, t.y)] == D.ROAD


## STEPS steps of DT: every boat stays on open water at the surface and keeps moving.
func _check_sailing(boats: Array) -> void:
	var on_bridge := 0
	var worst_y := 0.0
	var moves := 0
	var last: Array = boats.map(func(b: Dictionary) -> Vector2i: return b["from"])
	for _k in range(STEPS):
		life.call("_update_boats", DT)
		for j in range(boats.size()):
			var b: Dictionary = boats[j]
			if _bridge(b["from"]) or _bridge(b["to"]):
				on_bridge += 1
			if b["from"] != last[j]:
				moves += 1
				last[j] = b["from"]
			var y := (b["node"] as Node3D).position.y
			worst_y = maxf(worst_y, absf(y - WS.WATER_Y))
	K.check(fails, on_bridge == 0, "no boat sails through a bridge (%d steps on one)" % on_bridge)
	K.check(
		fails,
		worst_y <= CityLife.BOB + 1e-6,
		"boats float at the water surface (%.2f m off at most)" % (worst_y / WS.M)
	)
	K.check(fails, moves >= boats.size() * 30, "and keep moving (%d tiles sailed)" % moves)


## A boat heading from open water into a bridge turns back where it is and sails on elsewhere.
func _check_turn_back(b: Dictionary) -> void:
	var br := -1
	var open := Vector2i.ZERO
	for i: int in bridges:
		for dv: Vector2i in DIRS:
			var n := Vector2i(D.tx(i), D.ty(i)) + dv
			if br < 0 and D.in_bounds(n.x, n.y) and sim.terrain[D.idx(n.x, n.y)] == D.WATER:
				if not _bridge(n):
					br = i
					open = n
	K.check(fails, br >= 0, "fixture: open water beside a bridge")
	if br < 0:
		return
	var bt := Vector2i(D.tx(br), D.ty(br))
	var nbrs: Array = life.call("_water_neighbors", open)
	K.check(fails, not nbrs.has(bt), "the bridge is not a way on from beside it (%s)" % str(nbrs))
	b["from"] = open
	b["to"] = bt
	b["t"] = 0.3
	var want := Vector2(open).lerp(Vector2(bt), 0.3 + float(b["speed"]) * DT)
	life.call("_update_boats", DT)
	var node := b["node"] as Node3D
	var at := Vector2(node.position.x, node.position.z)
	var turned: bool = b["to"] == open and b["from"] == bt and at.distance_to(want) < 1e-4
	var turn_msg := "it turns back where it is (%s -> %s, %.4f off)"
	K.check(fails, turned, turn_msg % [b["from"], b["to"], at.distance_to(want)])
	var turn_d := at.distance_to(Vector2(bt))
	var closest := INF
	for _k in range(100):
		life.call("_update_boats", DT)
		at = Vector2(node.position.x, node.position.z)
		closest = minf(closest, at.distance_to(Vector2(bt)))
	K.check(
		fails,
		closest >= turn_d - 1e-4,
		"and gets no closer to the bridge (%.2f tiles, %.2f at the turn)" % [closest, turn_d]
	)
