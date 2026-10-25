extends RefCounted
## Read-only previews for the phone Build app. Each one mirrors CitySim's own checks (_act_road,
## _act_zone, _act_build, _act_bulldoze) so the ghost tiles, the owner and the price match what
## apply_action will do. The sim stays the judge: it checks the order again when it is placed.

const D := preload("res://scripts/sim/sim_defs.gd")

const TOOLS: Array[String] = ["road", "zone_r", "zone_c", "zone_i", "build", "bulldoze"]
const TOOL_LABELS := {
	"road": "Road",
	"zone_r": "Homes",
	"zone_c": "Shops",
	"zone_i": "Industry",
	"build": "Build",
	"bulldoze": "Bulldoze",
}
## Tools that take two corners (road start and end, zone rectangle); the rest act on one tile.
const TWO_POINT: Array[String] = ["road", "zone_r", "zone_c", "zone_i"]
## The Build tool's list, cheapest first.
const BUILDINGS: Array[String] = [
	"park",
	"police",
	"fire_station",
	"water_pump",
	"school",
	"landfill",
	"hospital",
	"sewage_plant",
	"solar_farm",
	"train_station",
	"wind_farm",
	"coal_plant",
	"university",
	"stadium",
	"airport",
]
## CitySim._can_afford lets a mayor go this far into debt.
const DEBT_FLOOR := -2000
const ZONES := {"zone_r": "R", "zone_c": "C", "zone_i": "I"}


## The mayor index that owns tile (x, y), or -1 for unclaimed land and outside the world.
static func owner_of(sim: CitySim, x: int, y: int) -> int:
	if not D.in_bounds(x, y):
		return -1
	var d := sim.district[D.idx(x, y)]
	return d if d >= 0 and d < sim.mayors.size() else -1


## The L-shaped road from a to b that CitySim builds: along x first, then along y.
static func road_path(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	var sx := 1 if b.x >= a.x else -1
	for x in range(a.x, b.x + sx, sx):
		path.append(Vector2i(x, a.y))
	if a.y != b.y:
		var sy := 1 if b.y >= a.y else -1
		for y in range(a.y + sy, b.y + sy, sy):
			path.append(Vector2i(b.x, y))
	if path.size() > D.MAX_ROAD_LEN:
		path.resize(D.MAX_ROAD_LEN)
	return path


## What placing tool at target would do. a is the first corner of a two-point tool (D.NO_TILE
## before it is set). Returns {"ok", "mi", "tiles" (Array[Vector2i] to draw), "cost", "reason",
## "action" (the apply_action dict)}; reason says what is wrong when ok is false. grade is the
## road tool's surface (D.ROAD_GRADES index).
static func preview(
	sim: CitySim,
	tool: String,
	a: Vector2i,
	target: Vector2i,
	building: String,
	grade: int = D.GRADE_PAVED
) -> Dictionary:
	var from := a if a != D.NO_TILE and TWO_POINT.has(tool) else target
	var mi := owner_of(sim, from.x, from.y)
	var out := {"ok": false, "mi": mi, "tiles": [] as Array[Vector2i], "cost": 0, "reason": ""}
	if not D.in_bounds(target.x, target.y):
		out["reason"] = "Outside the city"
		return out
	if mi < 0:
		out["reason"] = "Unclaimed land: no mayor to build for"
		return out
	match tool:
		"road":
			_road(sim, mi, from, target, grade if sim.road_grades else D.GRADE_PAVED, out)
		"zone_r", "zone_c", "zone_i":
			_zone(sim, mi, from, target, str(ZONES[tool]), out)
		"build":
			_build(sim, mi, target, building, out)
		"bulldoze":
			_bulldoze(sim, mi, target, out)
		_:
			out["reason"] = "Unknown tool"
			return out
	if bool(out["ok"]) and int(sim.mayors[mi]["treasury"]) - int(out["cost"]) < DEBT_FLOOR:
		out["ok"] = false
		out["reason"] = "%s cannot afford it" % D.MAYORS[mi]["district"]
	return out


static func _road(
	sim: CitySim, mi: int, a: Vector2i, b: Vector2i, grade: int, out: Dictionary
) -> void:
	var info := D.grade_info(grade)
	var tiles: Array[Vector2i] = []
	var cost := 0
	for p in road_path(a, b):
		if not D.in_bounds(p.x, p.y):
			out["reason"] = "The road leaves the city"
			return
		var i := D.idx(p.x, p.y)
		var k := sim.kind[i]
		# A road of this grade or better stays; a rougher one is resurfaced.
		var resurface := k == D.ROAD and sim.level[i] > grade
		if (
			(k == D.ROAD and not resurface)
			or (sim.sites.has(i) and int(sim.sites[i]["target_kind"]) == D.ROAD)
		):
			continue
		if sim.district[i] != mi:
			out["reason"] = "The road crosses into another district"
			out["tiles"] = tiles
			return
		if not (
			resurface
			or k == D.EMPTY
			or k == D.FOREST
			or k == D.RUBBLE
			or (D.is_zone(k) and sim.level[i] == 0)
		):
			out["reason"] = "Blocked by %s" % str(D.KIND_NAMES[k]).replace("_", " ")
			out["tiles"] = tiles
			return
		tiles.append(p)
		cost += D.ROAD_COST * 5 if sim.terrain[i] == D.WATER else int(info["cost"])
	out["tiles"] = tiles
	if tiles.is_empty():
		out["reason"] = "There is a road here already"
		return
	out["ok"] = true
	out["cost"] = cost
	out["action"] = {"type": "road", "x": a.x, "y": a.y, "x2": b.x, "y2": b.y}
	if grade != D.GRADE_PAVED:
		out["action"]["grade"] = str(info["key"])


static func _zone(
	sim: CitySim, mi: int, a: Vector2i, b: Vector2i, z: String, out: Dictionary
) -> void:
	var x0 := mini(a.x, b.x)
	var y0 := mini(a.y, b.y)
	var w := mini(absi(b.x - a.x) + 1, D.MAX_ZONE_SIDE)
	var h := mini(absi(b.y - a.y) + 1, D.MAX_ZONE_SIDE)
	var zk := D.ZONE_R if z == "R" else (D.ZONE_C if z == "C" else D.ZONE_I)
	var tiles: Array[Vector2i] = []
	for y in range(y0, y0 + h):
		for x in range(x0, x0 + w):
			if not D.in_bounds(x, y):
				continue
			var i := D.idx(x, y)
			if sim.district[i] != mi or sim.terrain[i] == D.WATER:
				continue
			var k := sim.kind[i]
			if k == D.EMPTY or k == D.FOREST or (D.is_zone(k) and k != zk and sim.level[i] == 0):
				tiles.append(Vector2i(x, y))
	out["tiles"] = tiles
	if tiles.is_empty():
		out["reason"] = "No open land to zone here"
		return
	out["ok"] = true
	out["cost"] = tiles.size() * D.ZONE_COST
	out["action"] = {"type": "zone", "zone": z, "x": x0, "y": y0, "w": w, "h": h}


static func _build(sim: CitySim, mi: int, t: Vector2i, key: String, out: Dictionary) -> void:
	if not D.BUILDINGS.has(key):
		out["reason"] = "Pick a building"
		return
	var spot := _build_spot(sim, mi, t)
	if spot == D.NO_TILE:
		out["reason"] = "No free lot here"
		return
	out["tiles"] = [spot] as Array[Vector2i]
	out["ok"] = true
	out["cost"] = int(D.BUILDINGS[key]["cost"])
	out["action"] = {"type": "build", "building": key, "x": t.x, "y": t.y}


## CitySim._find_build_spot: the tile itself, else a free lot within 2 tiles that has road access.
static func _build_spot(sim: CitySim, mi: int, t: Vector2i) -> Vector2i:
	if _buildable(sim, mi, t.x, t.y):
		return t
	for r in range(1, 3):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var x := t.x + dx
				var y := t.y + dy
				if _buildable(sim, mi, x, y) and sim.road_dist[D.idx(x, y)] <= 2:
					return Vector2i(x, y)
	return D.NO_TILE


static func _buildable(sim: CitySim, mi: int, x: int, y: int) -> bool:
	if not D.in_bounds(x, y):
		return false
	var i := D.idx(x, y)
	if sim.district[i] != mi or sim.terrain[i] == D.WATER:
		return false
	var k := sim.kind[i]
	return k == D.EMPTY or k == D.FOREST or k == D.RUBBLE or (D.is_zone(k) and sim.level[i] == 0)


static func _bulldoze(sim: CitySim, _mi: int, t: Vector2i, out: Dictionary) -> void:
	var i := D.idx(t.x, t.y)
	var k := sim.kind[i]
	var demolishing := sim.sites.has(i) and int(sim.sites[i]["target_kind"]) == D.EMPTY
	if k == D.EMPTY or k == D.HALL or demolishing:
		out["reason"] = (
			"Nothing to clear"
			if k == D.EMPTY
			else ("City Hall stays" if k == D.HALL else "Already being cleared")
		)
		return
	out["tiles"] = [t] as Array[Vector2i]
	out["ok"] = true
	out["cost"] = D.BULLDOZE_COST
	out["action"] = {"type": "bulldoze", "x": t.x, "y": t.y}


## Crew seconds the previewed order p would take one of the player's crews
## (CitySim.apply_player_order), or -1 when there is no estimate: zoning and bulldozing (what is
## on the tile decides), a refused order, or instant construction. A road's grade comes from p.
static func crew_seconds(sim: CitySim, tool: String, building: String, p: Dictionary) -> float:
	if not sim.staged() or not bool(p.get("ok", false)):
		return -1.0
	if tool == "build":
		return D.build_crew_seconds(building)
	if tool != "road":
		return -1.0
	var a: Dictionary = p.get("action", {})
	var plan := str(D.grade_info(D.grade_of(str(a.get("grade", ""))))["plan"])
	var secs := 0.0
	for t: Vector2i in p["tiles"]:
		var wet := sim.terrain[D.idx(t.x, t.y)] == D.WATER
		secs += float(D.CREW_TILE_S["bridge" if wet else plan])
	return clampf(secs, D.CREW_JOB_MIN_S, D.CREW_MAX_S)
