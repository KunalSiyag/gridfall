extends RefCounted
## The heuristic mayor's road orders (CityBrain._heuristic_mayor): new roads to open land, at as
## cheap a grade as the funds call for, and paving rough roads that lots have grown along. Static,
## reads the sim only. No nodes.

const D := preload("res://scripts/sim/sim_defs.gd")
## A heuristic mayor with more than this to spend paves a rough road that lots have grown along.
const PAVE_FUNDS := 9000


## The day's road order for mayor mi, if any, appended to actions with a note: new road to open
## land when fewer than 6 lots are left, else paving a rough road beside built lots.
static func road_step(
	sim: CitySim, mi: int, open_lots: int, funds: int, actions: Array, notes: Array
) -> void:
	var road: Dictionary = {}
	if open_lots < 6 and funds > 300:
		road = plan_road(sim, mi)
		var grade := thrifty_grade(funds)
		if not road.is_empty() and grade != "paved" and sim.road_grades:
			road["grade"] = grade
			var label := str(D.grade_info(D.grade_of(grade))["label"]).to_lower()
			notes.append("opening land with a cheap %s" % label)
		elif not road.is_empty():
			notes.append("extending roads to open land")
	elif funds > PAVE_FUNDS:
		road = plan_paving(sim, mi)
		if not road.is_empty():
			notes.append("paving a busy track")
	if not road.is_empty():
		actions.append(road)


## The road grade a heuristic mayor with funds to spare builds new roads at.
static func thrifty_grade(funds: int) -> String:
	if funds < 800:
		return "trail"
	if funds < 2500:
		return "dirt"
	return "gravel" if funds < 6000 else "paved"


## A paving order along an unpaved road tile with a built-up lot beside it: its straight run of
## unpaved tiles in the district, up to 12 long. Empty when there is none.
static func plan_paving(sim: CitySim, mi: int) -> Dictionary:
	var b := sim.district_rect(mi)
	for y in range(b.position.y, b.end.y):
		for x in range(b.position.x, b.end.x):
			if not _rough(sim, mi, D.idx(x, y)) or not _built_beside(sim, x, y):
				continue
			var run := _unpaved_run(sim, mi, Vector2i(x, y), Vector2i(1, 0))
			if run[0] == run[1]:
				run = _unpaved_run(sim, mi, Vector2i(x, y), Vector2i(0, 1))
			var a := run[0]
			var z := run[1]
			return {"type": "road", "x": a.x, "y": a.y, "x2": z.x, "y2": z.y, "grade": "paved"}
	return {}


## A paved road order of up to 12 tiles across empty land in mi's district that starts or ends
## next to an existing road. Empty when there is none.
static func plan_road(sim: CitySim, mi: int) -> Dictionary:
	var b := sim.district_rect(mi)
	for step in range(2, 16, 4):
		for horizontal in [true, false]:
			var line: Array[Vector2i] = []
			if horizontal:
				var y := b.position.y + step
				if y >= b.end.y:
					continue
				for x in range(b.position.x, b.end.x):
					line.append(Vector2i(x, y))
			else:
				var x2 := b.position.x + step
				if x2 >= b.end.x:
					continue
				for y2 in range(b.position.y, b.end.y):
					line.append(Vector2i(x2, y2))
			var seg := _open_segment(sim, mi, line)
			if seg.size() >= 3:
				var first: Vector2i = seg[0]
				var last: Vector2i = seg[mini(seg.size() - 1, 11)]
				var d0: int = sim.road_dist[D.idx(first.x, first.y)]
				var d1: int = sim.road_dist[D.idx(last.x, last.y)]
				if d0 <= 1 or d1 <= 1:
					return {"type": "road", "x": first.x, "y": first.y, "x2": last.x, "y2": last.y}
	return {}


## The empty or forest tiles of line in mi's district, up to the first tile built on.
static func _open_segment(sim: CitySim, mi: int, line: Array[Vector2i]) -> Array[Vector2i]:
	var seg: Array[Vector2i] = []
	for p in line:
		var i := D.idx(p.x, p.y)
		if sim.district[i] != mi:
			continue
		var k := sim.kind[i]
		if k == D.EMPTY or k == D.FOREST:
			seg.append(p)
		elif k != D.ROAD:
			break
	return seg


## An unpaved road tile i in mi's district.
static func _rough(sim: CitySim, mi: int, i: int) -> bool:
	return sim.kind[i] == D.ROAD and sim.level[i] != D.GRADE_PAVED and sim.district[i] == mi


static func _built_beside(sim: CitySim, x: int, y: int) -> bool:
	for d: Vector2i in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
		if D.in_bounds(x + d.x, y + d.y):
			var j := D.idx(x + d.x, y + d.y)
			if D.is_zone(sim.kind[j]) and sim.level[j] > 0:
				return true
	return false


## [first, last] of the straight run of unpaved road through p along step (both ways), in mi's
## district and at most 12 tiles long.
static func _unpaved_run(sim: CitySim, mi: int, p: Vector2i, step: Vector2i) -> Array[Vector2i]:
	var ends: Array[Vector2i] = [p, p]
	for k in range(2):
		var s := step if k == 1 else -step
		var q := p + s
		while (ends[1] - ends[0]).length() < 11.0 and D.in_bounds(q.x, q.y):
			if not _rough(sim, mi, D.idx(q.x, q.y)):
				break
			ends[k] = q
			q += s
	return ends
