class_name CitySim
extends Node
## Tile-based SimCity-style simulation: zoning + demand-driven growth, power/water/sewage
## networks with load shedding, service coverage, pollution/crime/land value/traffic maps,
## per-district budgets and taxes, city-wide ordinances, disasters, time speeds, save/load.

signal tiles_changed(indices: PackedInt32Array)
signal day_started(day: int)
signal day_ended(day: int)
signal territory_changed(mi: int)
signal stats_updated()
signal event_started(ev: Dictionary)
signal event_ended(ev: Dictionary)
signal city_log(message: String, category: String)
signal waiting_changed(waiting: bool)
signal tick_done(tick: int)
signal incident_progress(ev: Dictionary)
signal site_started(site: Dictionary)
signal site_stage(site: Dictionary)
signal site_finished(site: Dictionary)

const D := preload("res://scripts/sim/sim_defs.gd")
const N4 := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]

var kind := PackedInt32Array()
var level := PackedInt32Array()
var terrain := PackedInt32Array()
var district := PackedInt32Array()
var powered := PackedByteArray()
var watered := PackedByteArray()
var burning := PackedInt32Array()
var pollution := PackedFloat32Array()
var crime := PackedFloat32Array()
var land_value := PackedFloat32Array()
var traffic := PackedFloat32Array()
var happiness := PackedFloat32Array()
var road_dist := PackedInt32Array()
var cov_police := PackedFloat32Array()
var cov_fire := PackedFloat32Array()
var cov_health := PackedFloat32Array()
var cov_school := PackedFloat32Array()
var cov_park := PackedFloat32Array()
var cov_leisure := PackedFloat32Array()
var cov_transit := PackedFloat32Array()

var day: int = 1
var tick_in_day: int = 0
var speed: int = 1
## Real seconds per game day at speed 1. Orbit and tests keep SimDefs.BASE_DAY_SECONDS (12);
## first person sets WS.FP_DAY_SECONDS (1200). Not saved: the view mode sets it at boot. Change it
## through set_day_seconds() while a day is running, so the time of day stays put.
var day_seconds: float = D.BASE_DAY_SECONDS
var waiting_for_ai: bool = false
var day_gate: Callable = Callable()
var rng := RandomNumberGenerator.new()
var city_seed: int = 7

var mayors: Array[Dictionary] = []
var ordinances: Dictionary = {}
var events: Array[Dictionary] = []
var disabled_until: Dictionary = {}
var grid_priority: Array = [2, 0, 1, 3, 4]
var demand: Dictionary = {"r": 1.0, "c": 0.6, "i": 0.8}
var stats: Dictionary = {}
var history: Array[Dictionary] = []
var log_lines: Array[String] = []

## The AI residents (Residents node). When attached, human behaviour (mood, commuting, spending,
## moving, fixing what breaks) comes from their decisions instead of fixed formulas.
var people: Residents = null
## Road tiles cut by a downed power line: tile -> incident id.
var broken_roads: Dictionary = {}

var _time_accum: float = 0.0
var _event_seq: int = 0
var _changed: Dictionary = {}
var _district_rects: Dictionary = {}
## Tiles the per-tick systems process: claimed land plus a small margin. Unclaimed wilds hold no
## roads or buildings, so skipping them keeps a 192x192 world as cheap as the founding city.
var active := PackedInt32Array()
## Open construction sites: tile -> site. "auto" stages construction whenever residents run the
## city; "staged" / "instant" force it either way.
var sites: Dictionary = {}
var construction_mode: String = "auto"
var _site_seq: int = 0
## Surveyed plots (Vector2i -> true), rebuilt with the active area.
var _surveyed: Dictionary = {}
## Set by from_dict when the save used an older world layout: {w, h, x0, y0} of that layout,
## so other systems (residents) can move their saved tile indices across with remap_index.
var load_remap: Dictionary = {}
var _wet2 := PackedByteArray()


func _ready() -> void:
	if kind.is_empty():
		new_city(city_seed)


func new_city(seed_value: int) -> void:
	city_seed = seed_value
	load_remap = {}
	_wet2 = PackedByteArray()
	rng.seed = seed_value
	var n := D.W * D.H
	kind = _ints(n)
	level = _ints(n)
	terrain = _ints(n)
	district = _ints(n)
	burning = _ints(n)
	road_dist = _ints(n)
	powered = _bytes(n)
	watered = _bytes(n)
	pollution = _floats(n)
	crime = _floats(n)
	land_value = _floats(n)
	traffic = _floats(n)
	happiness = _floats(n)
	cov_police = _floats(n)
	cov_fire = _floats(n)
	cov_health = _floats(n)
	cov_school = _floats(n)
	cov_park = _floats(n)
	cov_leisure = _floats(n)
	cov_transit = _floats(n)
	sites.clear()
	_site_seq = 0
	day = 1
	tick_in_day = 0
	_time_accum = 0.0
	ordinances.clear()
	events.clear()
	disabled_until.clear()
	broken_roads.clear()
	history.clear()
	log_lines.clear()
	mayors.clear()
	for m in D.MAYORS:
		## "name" is the mayor's human display name; "id" and "model" stay for the API.
		mayors.append({
			"id": m["id"], "name": m["display"], "model": m["model"], "color": m["color"],
			"treasury": D.START_FUNDS, "tax_r": 9, "tax_c": 9, "tax_i": 9,
			"last_income": 0, "last_upkeep": 0, "actions_ok": 0, "actions_rejected": 0,
			"pop": 0, "jobs": 0, "happiness": 0.5, "annexed": 0,
		})
	district.fill(-1)
	# The founding city is generated exactly as before (same RNG draws) so its layout is stable.
	for y in range(D.CORE):
		for x in range(D.CORE):
			var i := D.idx(x, y)
			district[i] = D.district_of(x, y)
			var river_x := 27 + int(round(sin(float(y) * 0.33) * 1.6))
			if x == river_x or x == river_x + 1:
				terrain[i] = D.WATER
			elif rng.randf() < 0.13:
				kind[i] = D.FOREST
	_generate_wilds(seed_value)
	road_dist.fill(99)
	_rebuild_active()
	# Arterial ring + spokes so every district starts connected to the center.
	for t in range(D.CORE):
		_seed_road(10, t)
		_seed_road(21, t)
		_seed_road(t, 10)
		_seed_road(t, 21)
	for x in range(11, 21):
		_seed_road(x, 15)
	kind[D.idx(15, 14)] = D.HALL
	_recompute_all()
	_log("GridFall founded. Five GMI-powered mayors take office.", "city")
	_flush_changes(true)


## Unclaimed land around the founding city: the river keeps flowing, woods cluster, and a
## few lakes appear away from the city edge.
func _generate_wilds(seed_value: int) -> void:
	var woods := FastNoiseLite.new()
	woods.seed = seed_value + 11
	woods.frequency = 0.07
	var lakes := FastNoiseLite.new()
	lakes.seed = seed_value + 23
	lakes.frequency = 0.045
	var wr := RandomNumberGenerator.new()
	wr.seed = seed_value + 37
	for y in range(D.Y0, D.Y0 + D.H):
		for x in range(D.X0, D.X0 + D.W):
			if D.in_core(x, y):
				continue
			var i := D.idx(x, y)
			var river_x := 27 + int(round(sin(float(y) * 0.33) * 1.6))
			var edge := maxi(maxi(-x, x - D.CORE + 1), maxi(-y, y - D.CORE + 1))
			if x == river_x or x == river_x + 1:
				terrain[i] = D.WATER
			elif edge >= 4 and lakes.get_noise_2d(x, y) < -0.48:
				terrain[i] = D.WATER
			elif woods.get_noise_2d(x, y) > 0.12 or wr.randf() < 0.06:
				kind[i] = D.FOREST


# ---------------------------------------------------------------- territory

## Bounding box of the tiles district d owns (it grows as the mayor annexes plots).
func district_rect(d: int) -> Rect2i:
	if _district_rects.has(d):
		return _district_rects[d]
	var lo := Vector2i(1 << 20, 1 << 20)
	var hi := Vector2i(-(1 << 20), -(1 << 20))
	for i in range(district.size()):
		if district[i] == d:
			var x := D.tx(i)
			var y := D.ty(i)
			lo = Vector2i(mini(lo.x, x), mini(lo.y, y))
			hi = Vector2i(maxi(hi.x, x), maxi(hi.y, y))
	var r := Rect2i(lo, hi - lo + Vector2i.ONE) if hi.x >= lo.x else Rect2i(0, 0, 0, 0)
	_district_rects[d] = r
	return r


func _rebuild_active() -> void:
	_district_rects.clear()
	var r := owned_rect().grow(3).intersection(Rect2i(D.X0, D.Y0, D.W, D.H))
	active = PackedInt32Array()
	active.resize(r.size.x * r.size.y)
	var k := 0
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			active[k] = D.idx(x, y)
			k += 1
	_rebuild_survey()


## A plot is claimed once any of its tiles belongs to a district (annexation takes whole plots;
## the founding city's districts split its plots between them).
func plot_claimed(p: Vector2i) -> bool:
	var r := D.plot_rect(p)
	for y in [r.position.y, r.end.y - 1]:
		for x in [r.position.x, r.end.x - 1]:
			if D.in_bounds(x, y) and district[D.idx(x, y)] >= 0:
				return true
	return false


func _rebuild_survey() -> void:
	_surveyed.clear()
	var lo := D.plot_of(D.X0, D.Y0)
	var hi := D.plot_of(D.X0 + D.W - 1, D.Y0 + D.H - 1)
	var o := owned_rect()
	var plo := D.plot_of(o.position.x, o.position.y)
	var phi := D.plot_of(o.end.x - 1, o.end.y - 1)
	for py in range(plo.y, phi.y + 1):
		for px in range(plo.x, phi.x + 1):
			if not plot_claimed(Vector2i(px, py)):
				continue
			for sy in range(maxi(py - D.SURVEY_RANGE, lo.y), mini(py + D.SURVEY_RANGE, hi.y) + 1):
				for sx in range(maxi(px - D.SURVEY_RANGE, lo.x), mini(px + D.SURVEY_RANGE, hi.x) + 1):
					_surveyed[Vector2i(sx, sy)] = true


## Whether tile x,y lies on surveyed land (claimed or within SURVEY_RANGE plots of it).
func is_surveyed(x: int, y: int) -> bool:
	return _surveyed.has(D.plot_of(x, y))


func surveyed_plots() -> Array:
	return _surveyed.keys()


## Union of all districts: the developed part of the world.
func owned_rect() -> Rect2i:
	var r := district_rect(0)
	for d in range(1, mayors.size()):
		r = r.merge(district_rect(d))
	return r


func owner_name(i: int) -> String:
	if i < 0 or i >= district.size() or district[i] < 0 or district[i] >= mayors.size():
		return "unclaimed land"
	return str(mayors[district[i]]["name"])


func annex_cost(mi: int) -> int:
	return D.ANNEX_BASE_COST + D.ANNEX_STEP_COST * int(mayors[mi].get("annexed", 0))


## Plots that are entirely unclaimed and share an edge with land district mi already owns.
func annexable_plots(mi: int) -> Array:
	var out: Array = []
	var b := district_rect(mi)
	if b.size.x <= 0:
		return out
	# Only plots next to the district's bounding box can touch it, so the search stays small
	# however large the world is.
	var pmin := D.plot_of(D.X0, D.Y0)
	var pmax := D.plot_of(D.X0 + D.W - 1, D.Y0 + D.H - 1)
	var lo := D.plot_of(b.position.x - 1, b.position.y - 1)
	var hi := D.plot_of(b.end.x, b.end.y)
	for py in range(maxi(lo.y, pmin.y), mini(hi.y, pmax.y) + 1):
		for px in range(maxi(lo.x, pmin.x), mini(hi.x, pmax.x) + 1):
			var r := D.plot_rect(Vector2i(px, py))
			if not _plot_touches(r, mi):
				continue
			var free := true
			var counts := {"land": 0, "water": 0, "forest": 0}
			for y in range(r.position.y, r.end.y):
				for x in range(r.position.x, r.end.x):
					var i := D.idx(x, y)
					if district[i] != -1:
						free = false
						break
					if terrain[i] == D.WATER:
						counts["water"] = int(counts["water"]) + 1
					elif kind[i] == D.FOREST:
						counts["forest"] = int(counts["forest"]) + 1
					else:
						counts["land"] = int(counts["land"]) + 1
				if not free:
					break
			if free:
				out.append({"px": px, "py": py, "x": r.position.x, "y": r.position.y, "w": D.PLOT, "h": D.PLOT, "cost": annex_cost(mi), "open_land": counts["land"], "forest": counts["forest"], "water": counts["water"]})
	return out


## Whether district mi owns a tile just outside one of the edges of plot rect r.
func _plot_touches(r: Rect2i, mi: int) -> bool:
	for t in range(D.PLOT):
		for p: Vector2i in [Vector2i(r.position.x + t, r.position.y - 1), Vector2i(r.position.x + t, r.end.y), Vector2i(r.position.x - 1, r.position.y + t), Vector2i(r.end.x, r.position.y + t)]:
			if D.in_bounds(p.x, p.y) and district[D.idx(p.x, p.y)] == mi:
				return true
	return false



func _act_annex(mi: int, a: Dictionary) -> Dictionary:
	var x := int(a.get("x", -9999))
	var y := int(a.get("y", -9999))
	if not D.in_bounds(x, y):
		return {"ok": false, "reason": "(%d,%d) is outside the world" % [x, y]}
	var p := D.plot_of(x, y)
	var plot: Dictionary = {}
	for c: Dictionary in annexable_plots(mi):
		if int(c["px"]) == p.x and int(c["py"]) == p.y:
			plot = c
			break
	if plot.is_empty():
		return {"ok": false, "reason": "plot at (%d,%d) is claimed or does not border your district" % [x, y]}
	var cost := annex_cost(mi)
	if not _can_afford(mi, cost):
		return {"ok": false, "reason": "annexing costs $%d" % cost}
	_spend(mi, cost)
	var r := D.plot_rect(p)
	for yy in range(r.position.y, r.end.y):
		for xx in range(r.position.x, r.end.x):
			var i := D.idx(xx, yy)
			district[i] = mi
			_changed[i] = true
	mayors[mi]["annexed"] = int(mayors[mi].get("annexed", 0)) + 1
	_rebuild_active()
	_recompute_all()
	_log("%s annexed the land at x %d-%d, y %d-%d for $%d." % [mayors[mi]["name"], r.position.x, r.end.x - 1, r.position.y, r.end.y - 1, cost], "city")
	territory_changed.emit(mi)
	return {"ok": true, "reason": "annexed plot x %d-%d, y %d-%d" % [r.position.x, r.end.x - 1, r.position.y, r.end.y - 1], "cost": cost}


func _seed_road(x: int, y: int) -> void:
	var i := D.idx(x, y)
	kind[i] = D.ROAD
	level[i] = 0


# ---------------------------------------------------------------- time

func set_speed(s: int) -> void:
	speed = clampi(s, 0, 16)
	stats_updated.emit()


func _process(delta: float) -> void:
	if speed <= 0 or kind.is_empty():
		return
	if waiting_for_ai:
		if day_gate.is_valid() and not bool(day_gate.call()):
			return
		waiting_for_ai = false
		waiting_changed.emit(false)
		_begin_day()
		return
	_time_accum += delta * float(speed)
	var tick_len := tick_seconds()
	var guard := 0
	while _time_accum >= tick_len and guard < 8 and not waiting_for_ai:
		_time_accum -= tick_len
		guard += 1
		step_tick()


func day_progress() -> float:
	var tick_len := tick_seconds()
	return clampf((float(tick_in_day) + _time_accum / tick_len) / float(D.GROWTH_TICKS_PER_DAY), 0.0, 1.0)


## Real seconds per growth tick at speed 1.
func tick_seconds() -> float:
	return day_seconds / float(D.GROWTH_TICKS_PER_DAY)


## Changes the day length and rescales the time already accumulated toward the next tick, so
## day_progress() and tick_phase() are unchanged (a raw switch from a 1200 s to a 12 s day would
## leave up to a whole 300 s tick pending and run dozens of ticks at once).
func set_day_seconds(s: float) -> void:
	if s <= 0.0:
		return
	if day_seconds > 0.0:
		_time_accum *= s / day_seconds
	day_seconds = s


## Sets how far the current growth tick has run (0..1), e.g. when a save restores the time of day.
func set_tick_phase(p: float) -> void:
	_time_accum = clampf(p, 0.0, 1.0) * tick_seconds()


## Runs the rest of today's growth ticks synchronously so the next day starts at dawn
## (FP "skip to morning"). Stops early if the day gate holds the boundary. Returns true when
## the new day has started.
func skip_to_next_day() -> bool:
	var n := D.GROWTH_TICKS_PER_DAY - tick_in_day
	for _k in range(n):
		if waiting_for_ai:
			break
		step_tick()
	_time_accum = 0.0
	return not waiting_for_ai


func step_tick() -> void:
	_growth_tick()
	tick_done.emit(tick_in_day)
	tick_in_day += 1
	if tick_in_day >= D.GROWTH_TICKS_PER_DAY:
		tick_in_day = 0
		_end_day()


## Emits day_started for the very first day (call once after wiring listeners).
func start() -> void:
	day_started.emit(day)


func _end_day() -> void:
	_collect_budget()
	history.append({
		"day": day, "pop": int(stats.get("population", 0)), "funds": total_funds(),
		"happiness": float(stats.get("happiness", 0.0)), "jobs": int(stats.get("jobs", 0)),
	})
	if history.size() > 120:
		history.pop_front()
	day_ended.emit(day)
	day += 1
	var still: Array[Dictionary] = []
	for ev in events:
		if not work_based() and int(ev.get("until_day", 0)) < day:
			event_ended.emit(ev)
			_log("%s at (%d,%d) is over." % [ev.get("label", "Event"), int(ev["x"]), int(ev["y"])], "event")
		else:
			still.append(ev)
	events = still
	for k in disabled_until.keys():
		if int(disabled_until[k]) < day:
			disabled_until.erase(k)
	if day_gate.is_valid() and not bool(day_gate.call()):
		waiting_for_ai = true
		waiting_changed.emit(true)
		return
	_begin_day()


func _begin_day() -> void:
	day_started.emit(day)


# ---------------------------------------------------------------- simulation core

## True when residents decide behaviour; incidents then end only when someone fixes them.
func work_based() -> bool:
	return people != null and people.is_active()


func global_tick() -> int:
	return day * D.GROWTH_TICKS_PER_DAY + tick_in_day


func _growth_tick() -> void:
	_recompute_all()
	_grow_zones()
	_construction_tick()
	_update_fires()
	_random_fires()
	if work_based():
		_incident_tick()
	# Growth and fires change tiles, so refresh networks and stats to match what is rendered.
	_recompute_all()
	_flush_changes(false)


func _recompute_all() -> void:
	if people != null:
		people.rebuild_maps()
	_compute_road_dist()
	_compute_utilities()
	_compute_coverage()
	_compute_traffic()
	_compute_pollution()
	_compute_crime_land_happiness()
	_compute_demand()
	_compute_stats()


func _conductive(i: int) -> bool:
	var k := kind[i]
	if k == D.EMPTY or k == D.FOREST or k == D.RUBBLE:
		return false
	if terrain[i] == D.WATER and k != D.ROAD:
		return false
	if broken_roads.has(i):
		return false
	return true


func _operational(i: int) -> bool:
	return not disabled_until.has(i) and burning[i] == 0


func power_need(i: int) -> float:
	var k := kind[i]
	var l := level[i]
	match k:
		D.ZONE_R:
			return 0.2 + float(l) * 1.0
		D.ZONE_C:
			return 0.2 + float(l) * 1.5
		D.ZONE_I:
			return 0.2 + float(l) * 2.2
		D.PUMP, D.SEWAGE, D.POLICE, D.FIRE, D.HOSPITAL, D.SCHOOL, D.HALL, D.TRAIN:
			return 3.0
		D.LANDFILL:
			return 1.0
		D.UNIVERSITY:
			return 4.0
		D.STADIUM:
			return 6.0
		D.AIRPORT:
			return 8.0
	return 0.0


func water_need(i: int) -> float:
	var k := kind[i]
	var l := float(level[i])
	var mult := 0.75 if ordinances.has("water_conservation") else 1.0
	match k:
		D.ZONE_R:
			return l * 1.0 * mult
		D.ZONE_C:
			return l * 0.8 * mult
		D.ZONE_I:
			return l * 1.2 * mult
		D.HOSPITAL:
			return 3.0 * mult
		D.SCHOOL, D.HALL, D.UNIVERSITY, D.AIRPORT:
			return 2.0 * mult
		D.STADIUM:
			return 3.0 * mult
	return 0.0


func waste_need(i: int) -> float:
	var l := float(level[i])
	match kind[i]:
		D.ZONE_R:
			return l * 0.6
		D.ZONE_C:
			return l * 0.5
		D.ZONE_I:
			return l * 1.0
		D.STADIUM, D.AIRPORT:
			return 2.0
	return 0.0


func sewage_need(i: int) -> float:
	var k := kind[i]
	var l := float(level[i])
	match k:
		D.ZONE_R:
			return l
		D.ZONE_C:
			return l * 0.8
		D.ZONE_I:
			return l * 1.5
	return 0.0


func _blackout_zone(x: int, y: int) -> bool:
	for ev in events:
		if str(ev["type"]) == "blackout":
			if absi(int(ev["x"]) - x) + absi(int(ev["y"]) - y) <= int(ev.get("radius", 4)):
				return true
	return false


func _bfs_network(sources: Array[int]) -> Array[int]:
	var order: Array[int] = []
	var seen := {}
	var queue: Array[int] = []
	for s in sources:
		seen[s] = true
		queue.append(s)
	var head := 0
	while head < queue.size():
		var cur: int = queue[head]
		head += 1
		order.append(cur)
		var cx := D.tx(cur)
		var cy := D.ty(cur)
		for dv: Vector2i in N4:
			var nx := cx + dv.x
			var ny := cy + dv.y
			if not D.in_bounds(nx, ny):
				continue
			var ni := D.idx(nx, ny)
			if seen.has(ni) or not _conductive(ni):
				continue
			seen[ni] = true
			queue.append(ni)
	return order


func _compute_utilities() -> void:
	var n := D.W * D.H
	powered.fill(0)
	watered.fill(0)
	var p_sources: Array[int] = []
	var cap := 0.0
	var solar_mult := 1.5 if ordinances.has("green_energy_subsidy") else 1.0
	for i in active:
		if D.is_power_plant(kind[i]) and _operational(i):
			p_sources.append(i)
			if kind[i] == D.COAL:
				cap += float(D.BUILDINGS["coal_plant"]["power"])
			elif kind[i] == D.WIND:
				# Open water and the map edge are windier.
				var gust := 1.25 if _near_water(D.tx(i), D.ty(i), 2) or D.tx(i) <= D.X0 + 1 or D.tx(i) >= D.X0 + D.W - 2 or D.ty(i) <= D.Y0 + 1 or D.ty(i) >= D.Y0 + D.H - 2 else 1.0
				cap += float(D.BUILDINGS["wind_farm"]["power"]) * solar_mult * gust
			else:
				cap += float(D.BUILDINGS["solar_farm"]["power"]) * solar_mult
	var connected := _bfs_network(p_sources)
	var total_need := 0.0
	for i in active:
		total_need += power_need(i)
	var connected_need := 0.0
	var consumers: Array[int] = []
	for i in connected:
		var pn := power_need(i)
		if pn > 0.0:
			consumers.append(i)
			connected_need += pn
		else:
			powered[i] = 1
	if connected_need > cap:
		# Load shedding: Grid Operator priority order decides which districts keep power.
		var rank := {}
		for r in range(grid_priority.size()):
			rank[int(grid_priority[r])] = r
		consumers.sort_custom(func(a: int, b: int) -> bool:
			return int(rank.get(district[a], 9)) < int(rank.get(district[b], 9))
		)
	var used := 0.0
	for i in consumers:
		var pn2 := power_need(i)
		if used + pn2 <= cap and not _blackout_zone(D.tx(i), D.ty(i)):
			used += pn2
			powered[i] = 1
	stats["power_cap"] = cap
	stats["power_need"] = total_need
	stats["power_used"] = used

	var w_sources: Array[int] = []
	var wcap := 0.0
	for i in active:
		if kind[i] == D.PUMP and _operational(i) and powered[i] == 1:
			w_sources.append(i)
			var bonus := 1.5 if _near_water(D.tx(i), D.ty(i), 2) else 1.0
			wcap += float(D.BUILDINGS["water_pump"]["water"]) * bonus
	var w_conn := _bfs_network(w_sources)
	var wneed_total := 0.0
	for i in active:
		wneed_total += water_need(i)
	var wused := 0.0
	for i in w_conn:
		var wn := water_need(i)
		if wn <= 0.0:
			watered[i] = 1
		elif wused + wn <= wcap:
			wused += wn
			watered[i] = 1
	stats["water_cap"] = wcap
	stats["water_need"] = wneed_total
	stats["water_used"] = wused

	var scap := 0.0
	var sneed := 0.0
	for i in active:
		if kind[i] == D.SEWAGE and _operational(i) and powered[i] == 1:
			scap += float(D.BUILDINGS["sewage_plant"]["sewage"])
		sneed += sewage_need(i)
	stats["sewage_cap"] = scap
	stats["sewage_need"] = sneed
	stats["sewage_ratio"] = 1.0 if sneed <= 0.01 else clampf(scap / sneed, 0.0, 1.0)

	var wcap2 := 0.0
	var wneed2 := 0.0
	for i in active:
		if kind[i] == D.LANDFILL and _operational(i):
			wcap2 += float(D.BUILDINGS["landfill"]["waste"]) * (1.25 if ordinances.has("recycling") else 1.0)
		wneed2 += waste_need(i)
	stats["waste_cap"] = wcap2
	stats["waste_need"] = wneed2
	# A small town copes without a landfill; shortages only bite once there is real trash.
	stats["waste_ratio"] = 1.0 if wneed2 <= 25.0 else clampf(wcap2 / wneed2, 0.0, 1.0)


func _near_water(x: int, y: int, r: int) -> bool:
	# Terrain never changes after generation, so the common radius-2 answer is cached per tile
	# (0 unknown, 1 dry, 2 near water).
	if r == 2:
		if _wet2.size() != D.W * D.H:
			_wet2 = PackedByteArray()
			_wet2.resize(D.W * D.H)
			_wet2.fill(0)
		var i := D.idx(x, y)
		if _wet2[i] == 0:
			_wet2[i] = 2 if _scan_water(x, y, 2) else 1
		return _wet2[i] == 2
	return _scan_water(x, y, r)


func _scan_water(x: int, y: int, r: int) -> bool:
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var nx := x + dx
			var ny := y + dy
			if D.in_bounds(nx, ny) and terrain[D.idx(nx, ny)] == D.WATER:
				return true
	return false


func _compute_road_dist() -> void:
	var n := D.W * D.H
	road_dist.fill(99)
	var queue: Array[int] = []
	for i in active:
		if kind[i] == D.ROAD:
			road_dist[i] = 0
			queue.append(i)
	var head := 0
	while head < queue.size():
		var cur: int = queue[head]
		head += 1
		var d0 := road_dist[cur]
		if d0 >= 4:
			continue
		var cx := D.tx(cur)
		var cy := D.ty(cur)
		for dv: Vector2i in N4:
			var nx := cx + dv.x
			var ny := cy + dv.y
			if not D.in_bounds(nx, ny):
				continue
			var ni := D.idx(nx, ny)
			if road_dist[ni] > d0 + 1:
				road_dist[ni] = d0 + 1
				queue.append(ni)


func _compute_coverage() -> void:
	var n := D.W * D.H
	# One flat buffer (5 layers) because packed arrays are copied by value when aliased.
	var buf := _floats(n * 7)
	for i in active:
		var k := kind[i]
		var layer := 0
		var radius := 0
		match k:
			D.POLICE:
				layer = 0
				radius = 7
			D.FIRE:
				layer = 1
				radius = 7
			D.HOSPITAL:
				layer = 2
				radius = 8
			D.SCHOOL:
				layer = 3
				radius = 8
			D.PARK:
				layer = 4
				radius = 3
			D.UNIVERSITY:
				layer = 3
				radius = 11
			D.STADIUM:
				layer = 5
				radius = 10
			D.TRAIN:
				layer = 6
				radius = 8
			_:
				continue
		var effective := 1.0
		if k != D.PARK and (powered[i] == 0 or not _operational(i)):
			effective = 0.35
		var cx := D.tx(i)
		var cy := D.ty(i)
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var nx := cx + dx
				var ny := cy + dy
				if not D.in_bounds(nx, ny):
					continue
				var dist := sqrt(float(dx * dx + dy * dy))
				if dist > float(radius):
					continue
				var v := (1.0 - dist / float(radius + 1)) * effective
				var bi := layer * n + D.idx(nx, ny)
				if v > buf[bi]:
					buf[bi] = v
	cov_police = buf.slice(0, n)
	cov_fire = buf.slice(n, n * 2)
	cov_health = buf.slice(n * 2, n * 3)
	cov_school = buf.slice(n * 3, n * 4)
	cov_park = buf.slice(n * 4, n * 5)
	cov_leisure = buf.slice(n * 5, n * 6)
	cov_transit = buf.slice(n * 6, n * 7)


func _event_strength(type_name: String, x: int, y: int) -> float:
	var best := 0.0
	for ev in events:
		if str(ev["type"]) != type_name:
			continue
		var r := float(ev.get("radius", 4))
		var d := Vector2(float(int(ev["x"]) - x), float(int(ev["y"]) - y)).length()
		if d <= r:
			best = maxf(best, 1.0 - d / (r + 1.0))
	return best


func _compute_traffic() -> void:
	var n := D.W * D.H
	traffic.fill(0.0)
	var mult := 0.7 if ordinances.has("public_transit") else 1.0
	if work_based():
		# Traffic is the residents' actual chosen trips, each standing in for its share of people.
		var trips: PackedFloat32Array = people.trip_load
		for i in active:
			if kind[i] != D.ROAD:
				continue
			var t := trips[i] / 160.0 * mult
			t += _event_strength("gridlock", D.tx(i), D.ty(i)) * 0.75 + _event_strength("car_crash", D.tx(i), D.ty(i)) * 0.6
			traffic[i] = clampf(t, 0.0, 1.0)
		return
	for i in active:
		if kind[i] != D.ROAD:
			continue
		var cx := D.tx(i)
		var cy := D.ty(i)
		var load := 0.0
		var roads := 0
		for dy in range(-3, 4):
			for dx in range(-3, 4):
				var nx := cx + dx
				var ny := cy + dy
				if not D.in_bounds(nx, ny):
					continue
				var ni := D.idx(nx, ny)
				if kind[ni] == D.ROAD:
					roads += 1
				else:
					load += float(tile_pop(ni) + tile_jobs(ni))
		var t := load / maxf(1.0, float(roads) * 38.0) * mult * (1.0 - cov_transit[i] * 0.4)
		t += _event_strength("gridlock", cx, cy) * 0.75
		traffic[i] = clampf(t, 0.0, 1.0)


func _compute_pollution() -> void:
	var n := D.W * D.H
	var raw := PackedFloat32Array()
	raw.resize(n)
	var ind_mult := 0.6 if ordinances.has("clean_air_act") else 1.0
	var sources: Array[int] = []
	for i in active:
		var v := 0.0
		match kind[i]:
			D.ZONE_I:
				v = float(level[i]) * 0.24 * ind_mult
			D.COAL:
				v = 1.0 if _operational(i) else 0.2
			D.LANDFILL:
				v = 0.45
			D.AIRPORT:
				v = 0.5 if _operational(i) else 0.1
			D.ROAD:
				v = traffic[i] * 0.22
		if burning[i] > 0:
			v += 0.7
		if v > 0.01:
			raw[i] = v
			sources.append(i)
	pollution.fill(0.0)
	for s in sources:
		var sx := D.tx(s)
		var sy := D.ty(s)
		for dy in range(-4, 5):
			for dx in range(-4, 5):
				var nx := sx + dx
				var ny := sy + dy
				if not D.in_bounds(nx, ny):
					continue
				var dist := sqrt(float(dx * dx + dy * dy))
				if dist > 4.5:
					continue
				var ni := D.idx(nx, ny)
				pollution[ni] += raw[s] * (1.0 - dist / 5.0) * 0.32
	var rec := 0.85 if ordinances.has("recycling") else 1.0
	var sewage_short := 1.0 - float(stats.get("sewage_ratio", 1.0))
	var waste_short := 1.0 - float(stats.get("waste_ratio", 1.0))
	for i in active:
		var x := D.tx(i)
		var y := D.ty(i)
		var p := pollution[i] * rec - cov_park[i] * 0.25
		p += _event_strength("smog", x, y) * 0.55 + _event_strength("sewage_burst", x, y) * 0.35
		if level[i] > 0 and D.is_zone(kind[i]):
			p += sewage_short * 0.18 + waste_short * 0.14
		pollution[i] = clampf(p, 0.0, 1.0)


func _compute_crime_land_happiness() -> void:
	var n := D.W * D.H
	var crime_mult := 1.0
	if ordinances.has("neighborhood_watch"):
		crime_mult *= 0.8
	if ordinances.has("curfew"):
		crime_mult *= 0.7
	var sewage_short := 1.0 - float(stats.get("sewage_ratio", 1.0))
	var waste_short := 1.0 - float(stats.get("waste_ratio", 1.0))
	for i in active:
		var x := D.tx(i)
		var y := D.ty(i)
		var k := kind[i]
		var lv := 0.35 + cov_park[i] * 0.3 + cov_school[i] * 0.15 + cov_health[i] * 0.1
		lv += cov_transit[i] * 0.1 + cov_leisure[i] * 0.08
		if _near_water(x, y, 2):
			lv += 0.12
		lv -= pollution[i] * 0.45 + crime[i] * 0.25
		land_value[i] = clampf(lv, 0.0, 1.0)
		var c := 0.0
		if D.is_zone(k) and level[i] > 0:
			c = 0.08 * float(level[i]) + (0.15 if powered[i] == 0 else 0.0) + (0.1 if land_value[i] < 0.3 else 0.0)
			c = maxf(0.0, c - cov_police[i] * 0.7) * crime_mult
		crime[i] = clampf(c, 0.0, 1.0)
		var h := 0.0
		if k == D.ZONE_R and level[i] > 0 and work_based():
			# Each resident judges their own life; nearby residents speak for homes without one.
			h = people.mood_map[i]
		elif k == D.ZONE_R and level[i] > 0:
			var m: Dictionary = mayors[district[i]]
			h = 0.58 + land_value[i] * 0.25 - pollution[i] * 0.35 - crime[i] * 0.25
			h -= 0.3 if powered[i] == 0 else 0.0
			h -= 0.2 if watered[i] == 0 else 0.0
			h -= commute(x, y) * 0.15
			h += cov_health[i] * 0.08 + cov_school[i] * 0.05
			h -= float(int(m["tax_r"]) - 7) * 0.02
			h -= sewage_short * 0.25 + waste_short * 0.15
			h += cov_leisure[i] * 0.08
			h -= _event_strength("sewage_burst", x, y) * 0.2 + _event_strength("smog", x, y) * 0.15
			if ordinances.has("free_clinics"):
				h += 0.05
			if ordinances.has("curfew"):
				h -= 0.05
		happiness[i] = clampf(h, 0.0, 1.0)


func commute(x: int, y: int) -> float:
	var best := 0.0
	var count := 0
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			var nx := x + dx
			var ny := y + dy
			if D.in_bounds(nx, ny) and kind[D.idx(nx, ny)] == D.ROAD:
				best += traffic[D.idx(nx, ny)]
				count += 1
	return best / float(maxi(count, 1))


func tile_pop(i: int) -> int:
	return int(D.R_POP[level[i]]) if kind[i] == D.ZONE_R else 0


func tile_jobs(i: int) -> int:
	if kind[i] == D.ZONE_C:
		return int(D.C_JOBS[level[i]])
	if kind[i] == D.ZONE_I:
		return int(D.I_JOBS[level[i]])
	match kind[i]:
		D.AIRPORT:
			return 30
		D.UNIVERSITY:
			return 14
		D.STADIUM:
			return 12
		D.LANDFILL, D.TRAIN:
			return 8
	if D.is_service(kind[i]) and kind[i] != D.PARK:
		return 6
	return 0


func _compute_demand() -> void:
	var pop := 0
	var jobs_c := 0
	var jobs_i := 0
	var jobs_s := 0
	for i in active:
		pop += tile_pop(i)
		if kind[i] == D.ZONE_C:
			jobs_c += tile_jobs(i)
		elif kind[i] == D.ZONE_I:
			jobs_i += tile_jobs(i)
		else:
			jobs_s += tile_jobs(i)
	var workers := float(pop) * 0.55
	var jobs := float(jobs_c + jobs_i + jobs_s)
	var r := ((jobs + 70.0) - workers) / maxf(70.0, workers * 0.5)
	var c_want := float(pop) * 0.22 + 20.0
	var c := (c_want - float(jobs_c)) / maxf(30.0, c_want)
	var i_want := float(pop) * 0.28 + 40.0
	var ii := (i_want - float(jobs_i)) / maxf(40.0, i_want)
	var hap := float(stats.get("happiness", 0.6))
	if work_based():
		# Residents' word of mouth and decisions to leave set housing demand; shop demand follows
		# what they actually spent; industry slows when workers do not show up.
		var s: Dictionary = people.sentiment
		r = r * 0.5 + (float(s["recommend"]) - 5.0) / 5.0 * 0.6 - float(s["leaving"]) * 1.5
		var spend := float(s["spend_local"])
		c = (spend - float(jobs_c) * 9.0) / maxf(90.0, float(jobs_c) * 9.0) + 0.15
		ii -= (1.0 - float(s["attendance"])) * 0.5
	else:
		r += (hap - 0.5) * 0.4
	for i in active:
		if not _operational(i) or powered[i] == 0:
			continue
		match kind[i]:
			D.AIRPORT:
				c += 0.15
				ii += 0.15
			D.STADIUM:
				c += 0.06
			D.UNIVERSITY:
				r += 0.05
				c += 0.05
	if ordinances.has("tourism_campaign"):
		c += 0.15
	if ordinances.has("trade_expo"):
		ii += 0.2
	if ordinances.has("clean_air_act"):
		ii -= 0.1
	demand["r"] = clampf(r, -1.0, 1.0)
	demand["c"] = clampf(c, -1.0, 1.0)
	demand["i"] = clampf(ii, -1.0, 1.0)


func _compute_stats() -> void:
	var pop := 0
	var jobs := 0
	var hap_sum := 0.0
	var poll_sum := 0.0
	var crime_sum := 0.0
	var developed := 0
	var unpowered := 0
	var unwatered := 0
	var traffic_sum := 0.0
	var roads := 0
	for m in mayors:
		m["pop"] = 0
		m["jobs"] = 0
		m["hap_sum"] = 0.0
	for i in active:
		var p := tile_pop(i)
		var j := tile_jobs(i)
		pop += p
		jobs += j
		if district[i] < 0:
			continue
		var m: Dictionary = mayors[district[i]]
		m["pop"] = int(m["pop"]) + p
		m["jobs"] = int(m["jobs"]) + j
		if p > 0:
			hap_sum += happiness[i] * float(p)
			m["hap_sum"] = float(m["hap_sum"]) + happiness[i] * float(p)
		if D.is_zone(kind[i]) and level[i] > 0:
			developed += 1
			poll_sum += pollution[i]
			crime_sum += crime[i]
			if powered[i] == 0:
				unpowered += 1
			if watered[i] == 0:
				unwatered += 1
		if kind[i] == D.ROAD:
			roads += 1
			traffic_sum += traffic[i]
	for m in mayors:
		m["happiness"] = float(m["hap_sum"]) / float(maxi(int(m["pop"]), 1)) if int(m["pop"]) > 0 else 0.5
		m.erase("hap_sum")
	stats["population"] = pop
	stats["jobs"] = jobs
	stats["unemployment"] = clampf(1.0 - float(jobs) / maxf(1.0, float(pop) * 0.55), 0.0, 1.0) if pop > 0 else 0.0
	stats["happiness"] = hap_sum / float(maxi(pop, 1)) if pop > 0 else 0.6
	stats["pollution"] = poll_sum / float(maxi(developed, 1))
	stats["crime"] = crime_sum / float(maxi(developed, 1))
	stats["traffic"] = traffic_sum / float(maxi(roads, 1))
	stats["developed"] = developed
	stats["unpowered"] = unpowered
	stats["unwatered"] = unwatered
	stats["roads"] = roads


func _grow_zones() -> void:
	var open_sites := zone_site_counts()
	for i in active:
		var k := kind[i]
		if not D.is_zone(k) or burning[i] > 0 or terrain[i] == D.WATER or sites.has(i):
			continue
		var m: Dictionary = mayors[district[i]]
		var dem := 0.0
		var tax := 9
		match k:
			D.ZONE_R:
				dem = float(demand["r"])
				tax = int(m["tax_r"])
			D.ZONE_C:
				dem = float(demand["c"])
				tax = int(m["tax_c"])
			D.ZONE_I:
				dem = float(demand["i"])
				tax = int(m["tax_i"])
		dem -= float(tax - 7) * 0.035
		var l := level[i]
		if road_dist[i] > 2:
			if l > 0 and rng.randf() < 0.08:
				_set_level(i, l - 1)
			continue
		if powered[i] == 0:
			if l > 0 and rng.randf() < 0.10:
				_set_level(i, l - 1)
			continue
		var max_lvl := 1
		if watered[i] == 1:
			max_lvl = 2
			match k:
				D.ZONE_R:
					if land_value[i] >= 0.45:
						max_lvl = 3
				D.ZONE_C:
					if land_value[i] >= 0.5 or cov_school[i] > 0.2:
						max_lvl = 3
				D.ZONE_I:
					max_lvl = 3
		var desir := 0.0
		match k:
			D.ZONE_R:
				desir = land_value[i] - pollution[i] * 0.6 - crime[i] * 0.4
			D.ZONE_C:
				desir = land_value[i] * 0.6 + commute(D.tx(i), D.ty(i)) * 0.15 - crime[i] * 0.3
			D.ZONE_I:
				desir = 0.45 - land_value[i] * 0.1
		var p_grow := 0.10 + 0.40 * maxf(dem, 0.0) + 0.25 * desir
		if dem > -0.05 and l < max_lvl and rng.randf() < p_grow * 0.5:
			if staged():
				if int(open_sites[district[i]]) < D.MAX_ZONE_SITES:
					_start_zone_site(i, k, l + 1)
					open_sites[district[i]] = int(open_sites[district[i]]) + 1
			else:
				_set_level(i, l + 1)
		elif (dem < -0.35 or l > max_lvl) and l > 0 and rng.randf() < 0.06:
			_set_level(i, l - 1)
		elif k == D.ZONE_R and l > 0 and happiness[i] < 0.22 and rng.randf() < 0.05:
			_set_level(i, l - 1)


func _set_level(i: int, l: int) -> void:
	if level[i] != l:
		level[i] = l
		_mark(i)


# ---------------------------------------------------------------- construction

## Staged construction is on whenever residents run the city, unless forced either way.
func staged() -> bool:
	match construction_mode:
		"staged":
			return true
		"instant":
			return false
	return work_based()


## Opens a construction site on tile i. Service, road and demolition sites turn the tile into a
## SITE until they finish; zone sites sit on top of the lot, so people keep living and working in
## the old building while the bigger one goes up.
func _start_site(i: int, type: String, mi: int, target_kind: int, target_level: int, plan: String, ticks: int, label: String) -> Dictionary:
	_site_seq += 1
	var stages: Array = (D.SITE_STAGES[plan] as Array).duplicate()
	# Every stage gets at least one shift, so even small jobs show each step on site.
	ticks = maxi(ticks, stages.size())
	var s := {
		"id": _site_seq, "i": i, "x": D.tx(i), "y": D.ty(i), "type": type, "plan": plan, "owner": mi,
		"from_kind": kind[i], "from_level": level[i], "target_kind": target_kind, "target_level": target_level,
		"stages": stages, "stage": 0, "progress": 0.0, "stage_work": float(maxi(ticks, 1)) * D.CREW_RATE / float(stages.size()),
		"crew": {}, "label": label, "start_tick": global_tick(), "rate": D.CREW_RATE, "tick_work": D.CREW_RATE,
	}
	sites[i] = s
	if type != "zone":
		kind[i] = D.SITE
		level[i] = 0
		burning[i] = 0
	_mark(i)
	site_started.emit(s)
	return s


func _start_zone_site(i: int, k: int, target: int) -> void:
	var plan := "zone_up"
	if target == 1:
		plan = "zone_house" if k == D.ZONE_R else "zone_new"
	elif target >= 3:
		plan = "zone_tower"
	var ticks := int(D.ZONE_SITE_TICKS[plan])
	var what: String = {D.ZONE_R: ["Houses", "Apartments", "Apartment tower"], D.ZONE_C: ["Shops", "Office block", "Office tower"], D.ZONE_I: ["Workshop", "Factory", "Heavy plant"]}[k][clampi(target - 1, 0, 2)]
	_start_site(i, "zone", district[i], k, target, plan, ticks, what)


## Adds construction work to the site on tile i. Returns true once the whole site is finished.
func add_site_work(i: int, amount: float, who: String) -> bool:
	if not sites.has(i):
		return false
	var s: Dictionary = sites[i]
	if who != _contractor(s):
		var used := float(s.get("helper_work", 0.0))
		amount = minf(amount, maxf(D.HELPER_CAP * D.CREW_RATE - used, 0.0))
		s["helper_work"] = used + amount
	if amount <= 0.0:
		return false
	s["progress"] = float(s["progress"]) + amount
	s["tick_work"] = float(s.get("tick_work", 0.0)) + amount
	var crew: Dictionary = s["crew"]
	crew[who] = float(crew.get(who, 0.0)) + amount
	while float(s["progress"]) >= float(s["stage_work"]):
		s["progress"] = float(s["progress"]) - float(s["stage_work"])
		s["stage"] = int(s["stage"]) + 1
		if int(s["stage"]) >= (s["stages"] as Array).size():
			_finish_site(s)
			return true
		_mark(i)
		site_stage.emit(s)
	return false


func _finish_site(s: Dictionary) -> void:
	var i := int(s["i"])
	sites.erase(i)
	kind[i] = int(s["target_kind"])
	level[i] = int(s["target_level"])
	burning[i] = 0
	_mark(i)
	if str(s["type"]) == "build" or str(s["plan"]) == "zone_tower" or str(s["plan"]) == "bridge":
		_log("%s at (%d,%d) is finished after %d ticks. Built by: %s." % [s["label"], int(s["x"]), int(s["y"]), global_tick() - int(s["start_tick"]), ", ".join(PackedStringArray(crew_names(s, 5)))], "build")
	site_finished.emit(s)


## Builders on a site, residents first, then the contractor.
func crew_names(s: Dictionary, max_n: int) -> Array:
	var people_first: Array = []
	var firms: Array = []
	for who: String in (s["crew"] as Dictionary).keys():
		if who.ends_with("contractors") or who.ends_with("developers"):
			firms.append(who)
		else:
			people_first.append(who)
	people_first.append_array(firms)
	return people_first.slice(0, max_n)


func _site_valid(s: Dictionary) -> bool:
	var i := int(s["i"])
	if str(s["type"]) == "zone":
		return kind[i] == int(s["target_kind"]) and level[i] == int(s["from_level"])
	return kind[i] == D.SITE


func _contractor(s: Dictionary) -> String:
	if str(s["type"]) == "zone":
		return "private developers"
	var mi := int(s["owner"])
	return "%s's contractors" % mayors[mi]["name"] if mi >= 0 and mi < mayors.size() else "contractors"


## Paid contractors put in a steady shift on every open site; residents add their own work.
func _construction_tick() -> void:
	for i: int in sites.keys():
		if not sites.has(i):
			continue
		var s: Dictionary = sites[i]
		if not _site_valid(s):
			sites.erase(i)
			_mark(i)
			continue
		# Last tick's total work (contractor plus residents) lets the view animate between ticks.
		s["rate"] = float(s.get("tick_work", D.CREW_RATE))
		s["tick_work"] = 0.0
		s["helper_work"] = 0.0
		if burning[i] > 0 or disabled_until.has(i):
			s["rate"] = 0.0
			continue
		add_site_work(i, D.CREW_RATE, _contractor(s))


## Finishes every open site at once (showcase and tests).
func finish_all_sites() -> void:
	for i: int in sites.keys():
		var s: Dictionary = sites[i]
		if _site_valid(s):
			_finish_site(s)
		else:
			sites.erase(i)
	_recompute_all()
	_flush_changes(true)


## 0..1 progress through the current growth tick, so views can interpolate between ticks.
func tick_phase() -> float:
	return clampf(_time_accum / tick_seconds(), 0.0, 1.0)


## Open developer (zone) sites per district.
func zone_site_counts() -> Array:
	var out: Array = []
	out.resize(mayors.size())
	out.fill(0)
	for s: Dictionary in sites.values():
		if str(s["type"]) == "zone" and int(s["owner"]) >= 0 and int(s["owner"]) < out.size():
			out[int(s["owner"])] = int(out[int(s["owner"])]) + 1
	return out


## 0..1 completion of a site across all its stages.
func site_fraction(s: Dictionary) -> float:
	var n := (s["stages"] as Array).size()
	return clampf((float(s["stage"]) + float(s["progress"]) / maxf(float(s["stage_work"]), 0.01)) / float(n), 0.0, 1.0)


func site_stage_name(s: Dictionary) -> String:
	var st: Array = s["stages"]
	return str(st[clampi(int(s["stage"]), 0, st.size() - 1)])


func site_info(i: int) -> Dictionary:
	if not sites.has(i):
		return {}
	var s: Dictionary = sites[i]
	return {
		"building": s["label"], "stage": site_stage_name(s), "stage_label": D.STAGE_LABELS.get(site_stage_name(s), site_stage_name(s)),
		"stage_number": int(s["stage"]) + 1, "stages": (s["stages"] as Array).size(), "percent_done": int(round(site_fraction(s) * 100.0)),
		"crew": crew_names(s, 6),
	}


## Short lines describing a district's open sites, for prompts and the HUD.
func site_summary(d: int, max_n: int = 8) -> Array:
	var out: Array = []
	var roads := 0
	var road_done := 0.0
	var homes := 0
	for s: Dictionary in sites.values():
		if int(s["owner"]) != d:
			continue
		match str(s["type"]):
			"road":
				roads += 1
				road_done += site_fraction(s)
			"zone":
				homes += 1
			_:
				if out.size() < max_n:
					out.append("%s at (%d,%d): %s, %d%% done" % [s["label"], int(s["x"]), int(s["y"]), D.STAGE_LABELS.get(site_stage_name(s), ""), int(round(site_fraction(s) * 100.0))])
	if roads > 0:
		out.append("%d road tiles being paved, %d%% done on average" % [roads, int(round(road_done / float(roads) * 100.0))])
	if homes > 0:
		out.append("%d zoned lots being built up by private developers" % homes)
	return out

func _update_fires() -> void:
	var spread: Array[int] = []
	for i in active:
		if burning[i] <= 0:
			continue
		var fc := cov_fire[i]
		# With residents, fires only go out when someone fights them (see resolve_incident).
		if not work_based() and rng.randf() < 0.12 + 0.6 * fc:
			burning[i] = 0
			if D.is_zone(kind[i]) and level[i] > 1:
				level[i] -= 1
			_mark(i)
			continue
		burning[i] -= 1
		if burning[i] <= 0:
			kind[i] = D.RUBBLE
			level[i] = 0
			_mark(i)
			_log("A fire destroyed a building at (%d,%d)." % [D.tx(i), D.ty(i)], "disaster")
			continue
		var cx := D.tx(i)
		var cy := D.ty(i)
		for dv: Vector2i in N4:
			var nx := cx + dv.x
			var ny := cy + dv.y
			# Fires stay on claimed land, which is all the tick loops track.
			if D.in_bounds(nx, ny) and district[D.idx(nx, ny)] >= 0 and _flammable(D.idx(nx, ny)) and rng.randf() < 0.22 * (1.0 - fc * (0.5 if work_based() else 1.0)):
				spread.append(D.idx(nx, ny))
	for s in spread:
		if burning[s] == 0:
			burning[s] = 6
			_mark(s)


func _flammable(i: int) -> bool:
	var k := kind[i]
	return (D.is_zone(k) and level[i] > 0) or (D.is_service(k) and k != D.PARK) or k == D.FOREST


func _random_fires() -> void:
	if rng.randf() > 0.25:
		return
	var area := owned_rect()
	for _attempt in range(3):
		var i := D.idx(rng.randi_range(area.position.x, area.end.x - 1), rng.randi_range(area.position.y, area.end.y - 1))
		if D.is_zone(kind[i]) and level[i] > 0 and burning[i] == 0 and rng.randf() < 0.05 * (1.0 - cov_fire[i]):
			if work_based():
				trigger_disaster("fire", D.tx(i), D.ty(i), "accident", "an electrical fault started a fire")
				return
			burning[i] = 6
			_mark(i)
			_log("Fire broke out at (%d,%d)!" % [D.tx(i), D.ty(i)], "disaster")
			return


func _collect_budget() -> void:
	var ord_cost := 0.0
	for key: String in ordinances.keys():
		ord_cost += float(D.ORDINANCES[key]["cost"])
	var income := [0.0, 0.0, 0.0, 0.0, 0.0]
	var upkeep := [0.0, 0.0, 0.0, 0.0, 0.0]
	var wb := work_based()
	if wb:
		# Income and sales taxes come from what residents actually earned and spent today.
		var money: Array = people.district_money()
		for d in range(mayors.size()):
			income[d] += float(money[d]["wages"]) * float(mayors[d]["tax_r"]) / 100.0
			income[d] += float(money[d]["sales"]) * float(mayors[d]["tax_c"]) / 100.0 * 0.5
	for i in active:
		var d := district[i]
		if d < 0:
			continue
		var m: Dictionary = mayors[d]
		var k := kind[i]
		match k:
			D.ZONE_R:
				if not wb:
					income[d] += float(tile_pop(i)) * float(m["tax_r"]) * 0.035
			D.ZONE_C:
				if not wb:
					income[d] += float(tile_jobs(i)) * float(m["tax_c"]) * 0.045
			D.ZONE_I:
				var att := float(people.sentiment["attendance"]) if wb else 1.0
				income[d] += float(tile_jobs(i)) * float(m["tax_i"]) * 0.04 * att
			D.ROAD:
				upkeep[d] += 0.15
			_:
				var bk := D.building_key_for_kind(k)
				if not bk.is_empty():
					upkeep[d] += float(D.BUILDINGS[bk]["upkeep"])
	for d in range(mayors.size()):
		var m: Dictionary = mayors[d]
		var up: float = upkeep[d] + ord_cost / float(mayors.size())
		m["last_income"] = int(round(income[d]))
		m["last_upkeep"] = int(round(up))
		m["treasury"] = int(m["treasury"]) + int(round(income[d] - up))


func total_funds() -> int:
	var t := 0
	for m in mayors:
		t += int(m["treasury"])
	return t


# ---------------------------------------------------------------- mayor actions

## Applies one AI (or player) action for the mayor at index mi. Returns {ok, reason, cost}.
func apply_action(mi: int, a: Dictionary) -> Dictionary:
	if mi < 0 or mi >= mayors.size():
		return {"ok": false, "reason": "unknown mayor"}
	var m: Dictionary = mayors[mi]
	var t := str(a.get("type", "")).to_lower()
	var res: Dictionary
	match t:
		"road":
			res = _act_road(mi, a)
		"zone":
			res = _act_zone(mi, a)
		"build":
			res = _act_build(mi, a)
		"bulldoze":
			res = _act_bulldoze(mi, a)
		"set_tax", "tax":
			m["tax_r"] = clampi(int(a.get("r", m["tax_r"])), 0, 20)
			m["tax_c"] = clampi(int(a.get("c", m["tax_c"])), 0, 20)
			m["tax_i"] = clampi(int(a.get("i", m["tax_i"])), 0, 20)
			res = {"ok": true, "reason": "taxes R%d C%d I%d" % [m["tax_r"], m["tax_c"], m["tax_i"]], "cost": 0}
		"emergency":
			res = _act_emergency(mi, a)
		"grant":
			res = _act_grant(mi, a)
		"annex":
			res = _act_annex(mi, a)
		_:
			res = {"ok": false, "reason": "unknown action type '%s'" % t}
	if bool(res.get("ok", false)):
		m["actions_ok"] = int(m["actions_ok"]) + 1
	else:
		m["actions_rejected"] = int(m["actions_rejected"]) + 1
	_flush_changes(true)
	return res


func _can_afford(mi: int, cost: int) -> bool:
	return int(mayors[mi]["treasury"]) - cost >= -2000


func _spend(mi: int, cost: int) -> void:
	mayors[mi]["treasury"] = int(mayors[mi]["treasury"]) - cost


func _act_road(mi: int, a: Dictionary) -> Dictionary:
	var x1 := int(a.get("x", -99999))
	var y1 := int(a.get("y", -99999))
	var x2 := int(a.get("x2", x1))
	var y2 := int(a.get("y2", y1))
	var path: Array[Vector2i] = []
	var sx := 1 if x2 >= x1 else -1
	for x in range(x1, x2 + sx, sx):
		path.append(Vector2i(x, y1))
	var sy := 1 if y2 >= y1 else -1
	for y in range(y1 + sy, y2 + sy, sy):
		if y1 != y2:
			path.append(Vector2i(x2, y))
	if path.size() > D.MAX_ROAD_LEN:
		path.resize(D.MAX_ROAD_LEN)
	var to_build: Array[int] = []
	var cost := 0
	for p in path:
		if not D.in_bounds(p.x, p.y):
			return {"ok": false, "reason": "road leaves the map at (%d,%d)" % [p.x, p.y]}
		var i := D.idx(p.x, p.y)
		if kind[i] == D.ROAD or (sites.has(i) and int(sites[i]["target_kind"]) == D.ROAD):
			continue
		if district[i] != mi:
			return {"ok": false, "reason": "road tile (%d,%d) is outside your district" % [p.x, p.y]}
		var k := kind[i]
		if not (k == D.EMPTY or k == D.FOREST or k == D.RUBBLE or (D.is_zone(k) and level[i] == 0)):
			return {"ok": false, "reason": "road blocked by %s at (%d,%d)" % [D.KIND_NAMES[k], p.x, p.y]}
		to_build.append(i)
		cost += D.ROAD_COST * (5 if terrain[i] == D.WATER else 1)
	if to_build.is_empty():
		return {"ok": false, "reason": "road already exists there"}
	if not _can_afford(mi, cost):
		return {"ok": false, "reason": "cannot afford road ($%d)" % cost}
	_spend(mi, cost)
	if staged():
		var bridges := 0
		for i in to_build:
			var wet := terrain[i] == D.WATER
			bridges += 1 if wet else 0
			_start_site(i, "road", mi, D.ROAD, 0, "bridge" if wet else "road", D.BRIDGE_TICKS if wet else D.ROAD_TICKS, "Bridge" if wet else "Road")
		var note := " including %d bridge spans" % bridges if bridges > 0 else ""
		_log("%s's road crews started %d tiles of road%s." % [mayors[mi]["name"], to_build.size(), note], "build")
		return {"ok": true, "reason": "road construction started on %d tiles%s (open in about %s with contractors alone)" % [to_build.size(), note, "two and a half days" if bridges > 0 else "a day"], "cost": cost}
	for i in to_build:
		kind[i] = D.ROAD
		level[i] = 0
		_mark(i)
	return {"ok": true, "reason": "built %d road tiles" % to_build.size(), "cost": cost}


func _act_zone(mi: int, a: Dictionary) -> Dictionary:
	var zname := str(a.get("zone", "R")).to_upper().left(1)
	var zk := D.ZONE_R
	if zname == "C":
		zk = D.ZONE_C
	elif zname == "I":
		zk = D.ZONE_I
	var x0 := int(a.get("x", -99999))
	var y0 := int(a.get("y", -99999))
	var w := clampi(int(a.get("w", 1)), 1, D.MAX_ZONE_SIDE)
	var h := clampi(int(a.get("h", 1)), 1, D.MAX_ZONE_SIDE)
	var tiles: Array[int] = []
	for y in range(y0, y0 + h):
		for x in range(x0, x0 + w):
			if not D.in_bounds(x, y):
				continue
			var i := D.idx(x, y)
			if district[i] != mi or terrain[i] == D.WATER:
				continue
			var k := kind[i]
			if k == D.EMPTY or k == D.FOREST or (D.is_zone(k) and k != zk and level[i] == 0):
				tiles.append(i)
	if tiles.is_empty():
		return {"ok": false, "reason": "no zonable empty land in rect (%d,%d %dx%d) of your district" % [x0, y0, w, h]}
	var cost := tiles.size() * D.ZONE_COST
	if not _can_afford(mi, cost):
		return {"ok": false, "reason": "cannot afford zoning ($%d)" % cost}
	var near_road := 0
	for i in tiles:
		kind[i] = zk
		level[i] = 0
		if road_dist[i] <= 2:
			near_road += 1
		_mark(i)
	_spend(mi, cost)
	var note := "" if near_road == tiles.size() else " (%d tiles lack road access within 2)" % (tiles.size() - near_road)
	return {"ok": true, "reason": "zoned %d %s tiles%s" % [tiles.size(), zname, note], "cost": cost}


func _act_build(mi: int, a: Dictionary) -> Dictionary:
	var key := str(a.get("building", "")).to_lower()
	if not D.BUILDINGS.has(key):
		return {"ok": false, "reason": "unknown building '%s'" % key}
	var spec: Dictionary = D.BUILDINGS[key]
	var cost := int(spec["cost"])
	if not _can_afford(mi, cost):
		return {"ok": false, "reason": "cannot afford %s ($%d)" % [key, cost]}
	var x := int(a.get("x", -99999))
	var y := int(a.get("y", -99999))
	var spot := _find_build_spot(mi, x, y)
	if spot == D.NO_TILE:
		return {"ok": false, "reason": "no free land near (%d,%d) in your district" % [x, y]}
	var i := D.idx(spot.x, spot.y)
	_spend(mi, cost)
	var moved := "" if spot == Vector2i(x, y) else " (moved to %d,%d)" % [spot.x, spot.y]
	if staged():
		var plan := "park" if key == "park" else ("light" if D.LIGHT_BUILDS.has(key) else "build")
		var ticks := maxi(D.build_ticks(key), (D.SITE_STAGES[plan] as Array).size())
		_start_site(i, "build", mi, int(spec["kind"]), 1, plan, ticks, str(spec["label"]))
		_log("%s broke ground on a %s at (%d,%d)." % [mayors[mi]["name"], spec["label"], spot.x, spot.y], "build")
		return {"ok": true, "reason": "construction of %s started%s; contractors alone need about %.1f days, local builders speed it up" % [spec["label"], moved, float(ticks) / float(D.GROWTH_TICKS_PER_DAY)], "cost": cost, "x": spot.x, "y": spot.y, "site": true}
	kind[i] = int(spec["kind"])
	level[i] = 1
	_mark(i)
	return {"ok": true, "reason": "built %s%s" % [spec["label"], moved], "cost": cost, "x": spot.x, "y": spot.y}


func _buildable(mi: int, x: int, y: int) -> bool:
	if not D.in_bounds(x, y):
		return false
	var i := D.idx(x, y)
	if district[i] != mi or terrain[i] == D.WATER:
		return false
	var k := kind[i]
	return k == D.EMPTY or k == D.FOREST or k == D.RUBBLE or (D.is_zone(k) and level[i] == 0)


func _find_build_spot(mi: int, x: int, y: int) -> Vector2i:
	if _buildable(mi, x, y):
		return Vector2i(x, y)
	for r in range(1, 3):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if _buildable(mi, x + dx, y + dy) and road_dist[D.idx(x + dx, y + dy)] <= 2:
					return Vector2i(x + dx, y + dy)
	return D.NO_TILE


func _act_bulldoze(mi: int, a: Dictionary) -> Dictionary:
	var x0 := int(a.get("x", -99999))
	var y0 := int(a.get("y", -99999))
	var w := clampi(int(a.get("w", 1)), 1, 3)
	var h := clampi(int(a.get("h", 1)), 1, 3)
	var tiles: Array[int] = []
	for y in range(y0, y0 + h):
		for x in range(x0, x0 + w):
			if not D.in_bounds(x, y):
				continue
			var i := D.idx(x, y)
			var demolishing := sites.has(i) and int(sites[i]["target_kind"]) == D.EMPTY
			if district[i] == mi and kind[i] != D.EMPTY and kind[i] != D.HALL and not demolishing:
				tiles.append(i)
	if tiles.is_empty():
		return {"ok": false, "reason": "nothing to bulldoze in your district at (%d,%d)" % [x0, y0]}
	var cost := tiles.size() * D.BULLDOZE_COST
	var crews := 0
	for i in tiles:
		var k := kind[i]
		var had_site := sites.has(i)
		sites.erase(i)
		if staged() and k != D.SITE and not (D.is_zone(k) and level[i] == 0):
			var plan := "clear" if k == D.FOREST else ("haul" if k == D.RUBBLE else "demolish")
			var ticks := 2 if plan == "clear" else (4 if plan == "haul" else (4 + 2 * level[i] if D.is_zone(k) else 8))
			var what := "rubble" if k == D.RUBBLE else ("trees" if k == D.FOREST else str(D.KIND_NAMES[k]).replace("_", " "))
			_start_site(i, "demolish", mi, D.EMPTY, 0, plan, ticks, "Clearing " + what if plan != "demolish" else "Demolition of " + what)
			crews += 1
			continue
		if had_site and k == D.SITE:
			_log("%s cancelled the construction site at (%d,%d)." % [mayors[mi]["name"], D.tx(i), D.ty(i)], "build")
		kind[i] = D.EMPTY
		level[i] = 0
		burning[i] = 0
		_mark(i)
	_spend(mi, cost)
	if crews > 0:
		return {"ok": true, "reason": "demolition crews started on %d tiles, %d cleared at once" % [crews, tiles.size() - crews], "cost": cost}
	return {"ok": true, "reason": "cleared %d tiles" % tiles.size(), "cost": cost}


func _act_emergency(mi: int, a: Dictionary) -> Dictionary:
	var x := int(a.get("x", -99999))
	var y := int(a.get("y", -99999))
	if not _can_afford(mi, D.EMERGENCY_COST):
		return {"ok": false, "reason": "cannot afford emergency crews"}
	if work_based():
		# Paid crews are extra hands: they work the incident for a few ticks, they do not end it by decree.
		var hit := 0
		for ev in events.duplicate():
			if absi(int(ev["x"]) - x) + absi(int(ev["y"]) - y) <= 4:
				ev["crew_ticks"] = int(ev.get("crew_ticks", 0)) + 3
				hit += 1
				_log("%s sent paid city crews to %s at (%d,%d)." % [mayors[mi]["name"], ev["label"], int(ev["x"]), int(ev["y"])], "response")
				add_incident_work(int(ev["id"]), 30.0, "%s's city crews" % mayors[mi]["name"])
		if hit == 0:
			return {"ok": false, "reason": "no incident within 4 tiles of (%d,%d)" % [x, y]}
		_spend(mi, D.EMERGENCY_COST)
		return {"ok": true, "reason": "city crews dispatched to %d incident(s)" % hit, "cost": D.EMERGENCY_COST}
	var fixed := 0
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			if D.in_bounds(x + dx, y + dy):
				var i := D.idx(x + dx, y + dy)
				if burning[i] > 0:
					burning[i] = 0
					fixed += 1
					_mark(i)
	var still: Array[Dictionary] = []
	for ev in events:
		var close := absi(int(ev["x"]) - x) + absi(int(ev["y"]) - y) <= 4
		if close and str(ev["type"]) in ["sewage_burst", "gridlock", "smog", "blackout", "fire"]:
			fixed += 1
			event_ended.emit(ev)
			_log("%s crews resolved %s at (%d,%d)." % [mayors[mi]["name"], ev["label"], int(ev["x"]), int(ev["y"])], "response")
			for k in disabled_until.keys():
				if absi(D.tx(int(k)) - x) + absi(D.ty(int(k)) - y) <= 4:
					disabled_until.erase(k)
		else:
			still.append(ev)
	events = still
	if fixed == 0:
		return {"ok": false, "reason": "no fire or emergency near (%d,%d)" % [x, y]}
	_spend(mi, D.EMERGENCY_COST)
	return {"ok": true, "reason": "emergency crews fixed %d problems" % fixed, "cost": D.EMERGENCY_COST}


func _act_grant(mi: int, a: Dictionary) -> Dictionary:
	var to := D.mayor_index(str(a.get("to", "")))
	var amount := int(a.get("amount", 0))
	if to < 0 or to == mi:
		return {"ok": false, "reason": "invalid grant recipient"}
	if amount <= 0 or amount > int(mayors[mi]["treasury"]):
		return {"ok": false, "reason": "invalid grant amount"}
	_spend(mi, amount)
	mayors[to]["treasury"] = int(mayors[to]["treasury"]) + amount
	_log("%s granted $%d to %s." % [mayors[mi]["name"], amount, mayors[to]["name"]], "deal")
	return {"ok": true, "reason": "granted $%d to %s" % [amount, mayors[to]["name"]], "cost": amount}


func enact_ordinance(key: String) -> bool:
	if not D.ORDINANCES.has(key) or ordinances.has(key):
		return false
	ordinances[key] = day
	_log("Council enacted %s." % D.ORDINANCES[key]["label"], "council")
	return true


func repeal_ordinance(key: String) -> bool:
	if not ordinances.has(key):
		return false
	ordinances.erase(key)
	_log("Council repealed %s." % D.ORDINANCES[key]["label"], "council")
	return true


func gift_funds(mi: int, amount: int) -> void:
	if mi >= 0 and mi < mayors.size():
		mayors[mi]["treasury"] = int(mayors[mi]["treasury"]) + amount
		_log("Player granted $%d to %s." % [amount, mayors[mi]["name"]], "player")
		stats_updated.emit()


# ---------------------------------------------------------------- disasters

func trigger_disaster(type_name: String, x: int, y: int, source: String = "player", reason: String = "") -> Dictionary:
	if not D.DISASTERS.has(type_name):
		return {}
	x = clampi(x, D.X0, D.X0 + D.W - 1)
	y = clampi(y, D.Y0, D.Y0 + D.H - 1)
	_event_seq += 1
	var spec: Dictionary = D.DISASTERS[type_name]
	var ev := {
		"id": _event_seq, "type": type_name, "label": spec["label"], "x": x, "y": y,
		"radius": 4, "start_day": day, "until_day": day + int(spec["days"]) - 1,
		"source": source, "reason": reason, "tiles": [],
		"work": float(spec.get("work", 80)), "progress": 0.0, "skills": spec.get("skills", []),
		"helpers": {}, "reports": 0, "disabled": [], "start_tick": global_tick(),
	}
	if work_based():
		ev["until_day"] = 1 << 30
	match type_name:
		"water_main":
			var pump := _nearest(x, y, 8, func(i: int) -> bool: return kind[i] == D.PUMP)
			if pump >= 0:
				disabled_until[pump] = int(ev["until_day"])
				(ev["disabled"] as Array).append(pump)
				ev["x"] = D.tx(pump)
				ev["y"] = D.ty(pump)
			ev["radius"] = 4
		"power_line":
			var road := _nearest(x, y, 6, func(i: int) -> bool: return kind[i] == D.ROAD and terrain[i] == D.LAND)
			if road >= 0:
				broken_roads[road] = int(ev["id"])
				ev["x"] = D.tx(road)
				ev["y"] = D.ty(road)
				_mark(road)
			ev["radius"] = 3
		"car_crash":
			var cr := _nearest(x, y, 6, func(i: int) -> bool: return kind[i] == D.ROAD)
			if cr >= 0:
				ev["x"] = D.tx(cr)
				ev["y"] = D.ty(cr)
			ev["radius"] = 2
		"fire":
			var target := _nearest(x, y, 3, func(i: int) -> bool: return _flammable(i) and kind[i] != D.FOREST)
			if target < 0:
				target = _nearest(x, y, 3, func(i: int) -> bool: return _flammable(i))
			if target >= 0:
				burning[target] = 6
				ev["x"] = D.tx(target)
				ev["y"] = D.ty(target)
				_mark(target)
			ev["radius"] = 2
		"blackout":
			var plant := _nearest(x, y, 40, func(i: int) -> bool: return D.is_power_plant(kind[i]))
			if plant >= 0 and absi(D.tx(plant) - x) + absi(D.ty(plant) - y) <= 6:
				disabled_until[plant] = int(ev["until_day"])
				(ev["disabled"] as Array).append(plant)
				ev["x"] = D.tx(plant)
				ev["y"] = D.ty(plant)
			ev["radius"] = 5
		"sewage_burst":
			var sp := _nearest(x, y, 5, func(i: int) -> bool: return kind[i] == D.SEWAGE)
			if sp >= 0:
				disabled_until[sp] = int(ev["until_day"])
				(ev["disabled"] as Array).append(sp)
			ev["radius"] = 4
		"gridlock":
			ev["radius"] = 5
		"smog":
			ev["radius"] = 6
		"earthquake":
			ev["radius"] = 10
			for i in active:
				var d := Vector2(float(D.tx(i) - x), float(D.ty(i) - y)).length()
				if d > 10.0:
					continue
				if D.is_zone(kind[i]) and level[i] > 0:
					var r := rng.randf()
					if r < 0.10:
						kind[i] = D.RUBBLE
						level[i] = 0
						_mark(i)
						(ev["tiles"] as Array).append(i)
					elif r < 0.16:
						burning[i] = 6
						_mark(i)
		"flood":
			ev["radius"] = 8
			for i in active:
				var tx := D.tx(i)
				var ty := D.ty(i)
				if terrain[i] == D.WATER or Vector2(float(tx - x), float(ty - y)).length() > 8.0:
					continue
				if _near_water(tx, ty, 2):
					(ev["tiles"] as Array).append(i)
					if D.is_zone(kind[i]) and level[i] > 0 and rng.randf() < 0.35:
						level[i] = 0
						_mark(i)
		"tornado":
			ev["radius"] = 2
			var px := x
			var py := y
			for _s in range(10):
				if D.in_bounds(px, py):
					var ti := D.idx(px, py)
					(ev["tiles"] as Array).append(ti)
					if (D.is_zone(kind[ti]) and level[ti] > 0) or (D.is_service(kind[ti]) and kind[ti] != D.HALL):
						kind[ti] = D.RUBBLE
						level[ti] = 0
						_mark(ti)
				px += rng.randi_range(-1, 1)
				py += rng.randi_range(0, 1) if rng.randf() < 0.5 else 1
	events.append(ev)
	var who := "Player" if source == "player" else source
	_log("%s: %s at (%d,%d)! %s" % [who, ev["label"], int(ev["x"]), int(ev["y"]), reason], "disaster")
	event_started.emit(ev)
	_recompute_all()
	_flush_changes(true)
	return ev


## Adds repair/response work to an incident and resolves it once enough work is done.
func add_incident_work(ev_id: int, amount: float, who: String) -> bool:
	for ev in events:
		if int(ev["id"]) != ev_id:
			continue
		ev["progress"] = float(ev["progress"]) + amount
		var helpers: Dictionary = ev["helpers"]
		helpers[who] = float(helpers.get(who, 0.0)) + amount
		incident_progress.emit(ev)
		if float(ev["progress"]) >= float(ev["work"]):
			resolve_incident(ev, who)
			return true
		return false
	return false


func find_event(ev_id: int) -> Dictionary:
	for ev in events:
		if int(ev["id"]) == ev_id:
			return ev
	return {}


func resolve_incident(ev: Dictionary, finisher: String) -> void:
	if not events.has(ev):
		return
	events.erase(ev)
	for t: Variant in ev.get("disabled", []):
		disabled_until.erase(int(t))
	for key: int in broken_roads.keys():
		if int(broken_roads[key]) == int(ev["id"]):
			broken_roads.erase(key)
			_mark(key)
	if str(ev["type"]) in ["fire", "earthquake", "tornado"]:
		var r := int(ev.get("radius", 2)) + 1
		for i in active:
			if burning[i] > 0 and absi(D.tx(i) - int(ev["x"])) + absi(D.ty(i) - int(ev["y"])) <= r:
				burning[i] = 0
				_mark(i)
	var names: Array = (ev["helpers"] as Dictionary).keys()
	_log("%s at (%d,%d) was fixed after %d ticks. Done by: %s." % [ev["label"], int(ev["x"]), int(ev["y"]), global_tick() - int(ev.get("start_tick", global_tick())), ", ".join(PackedStringArray(names.slice(0, 5))) if not names.is_empty() else finisher], "response")
	event_ended.emit(ev)
	_recompute_all()
	_flush_changes(true)


## Weather fades, paid crews keep working, stray fires become incidents, and worn
## infrastructure sometimes fails on its own.
func _incident_tick() -> void:
	for ev in events.duplicate():
		var spec: Dictionary = D.DISASTERS.get(str(ev["type"]), {})
		if spec.has("weather"):
			add_incident_work(int(ev["id"]), float(spec["weather"]), "the weather")
		if int(ev.get("crew_ticks", 0)) > 0 and events.has(ev):
			ev["crew_ticks"] = int(ev["crew_ticks"]) - 1
			add_incident_work(int(ev["id"]), 20.0, "%s's city crews" % owner_name(D.idx(int(ev["x"]), int(ev["y"]))))
	for i in active:
		if burning[i] <= 0:
			continue
		var covered := false
		for ev in events:
			if str(ev["type"]) in ["fire", "earthquake", "tornado"] and absi(D.tx(i) - int(ev["x"])) + absi(D.ty(i) - int(ev["y"])) <= int(ev.get("radius", 2)) + 1:
				covered = true
				break
		if not covered:
			trigger_disaster("fire", D.tx(i), D.ty(i), "accident", "the fire spread")
	if events.size() < 3 and rng.randf() < 0.05:
		var pick := rng.randi_range(0, 2)
		var t: String = ["power_line", "water_main", "car_crash"][pick]
		var cand: Array[int] = []
		for i in active:
			if (t == "water_main" and kind[i] == D.PUMP) or (t != "water_main" and kind[i] == D.ROAD and traffic[i] > 0.3):
				cand.append(i)
		if not cand.is_empty():
			var c := cand[rng.randi_range(0, cand.size() - 1)]
			trigger_disaster(t, D.tx(c), D.ty(c), "wear and tear", "infrastructure failed under load")


## A resident moving away empties part of their building.
func resident_left(home_i: int) -> void:
	if home_i >= 0 and home_i < kind.size() and kind[home_i] == D.ZONE_R and level[home_i] > 0 and rng.randf() < 0.6:
		_set_level(home_i, level[home_i] - 1)


func _nearest(x: int, y: int, max_d: int, pred: Callable) -> int:
	var best := -1
	var best_d := 1 << 30
	for i in active:
		var d := absi(D.tx(i) - x) + absi(D.ty(i) - y)
		if d <= max_d and d < best_d and bool(pred.call(i)):
			best = i
			best_d = d
	return best


func clear_all_events() -> void:
	for ev in events:
		event_ended.emit(ev)
	events.clear()
	disabled_until.clear()
	for key: int in broken_roads.keys():
		_mark(key)
	broken_roads.clear()
	for i in active:
		if burning[i] > 0:
			burning[i] = 0
			_mark(i)
	_log("Player restored all city systems.", "player")
	_recompute_all()
	_flush_changes(true)


# ---------------------------------------------------------------- AI summaries

func district_summary(d: int) -> Dictionary:
	var b := district_rect(d)
	var counts := {"r": 0, "c": 0, "i": 0, "r_dev": 0, "c_dev": 0, "i_dev": 0, "roads": 0, "empty": 0, "forest": 0, "rubble": 0, "burning": 0, "unpowered": 0, "unwatered": 0, "no_road": 0}
	var services := {}
	var poll := 0.0
	var cr := 0.0
	var tr := 0.0
	var dev := 0
	for y in range(b.position.y, b.end.y):
		for x in range(b.position.x, b.end.x):
			var i := D.idx(x, y)
			if district[i] != d:
				continue
			var k := kind[i]
			match k:
				D.ZONE_R, D.ZONE_C, D.ZONE_I:
					var key: String = D.ZONE_CHAR[k]
					counts[key] = int(counts[key]) + 1
					if level[i] > 0:
						counts[key + "_dev"] = int(counts[key + "_dev"]) + 1
						dev += 1
						poll += pollution[i]
						cr += crime[i]
						if powered[i] == 0:
							counts["unpowered"] = int(counts["unpowered"]) + 1
						if watered[i] == 0:
							counts["unwatered"] = int(counts["unwatered"]) + 1
					if road_dist[i] > 2:
						counts["no_road"] = int(counts["no_road"]) + 1
				D.ROAD:
					counts["roads"] = int(counts["roads"]) + 1
					tr += traffic[i]
				D.EMPTY:
					if terrain[i] == D.LAND:
						counts["empty"] = int(counts["empty"]) + 1
				D.FOREST:
					counts["forest"] = int(counts["forest"]) + 1
				D.RUBBLE:
					counts["rubble"] = int(counts["rubble"]) + 1
				_:
					var nm: String = D.KIND_NAMES[k]
					services[nm] = int(services.get(nm, 0)) + 1
			if burning[i] > 0:
				counts["burning"] = int(counts["burning"]) + 1
	var m: Dictionary = mayors[d]
	return {
		"counts": counts, "services": services,
		"avg_pollution": snappedf(poll / float(maxi(dev, 1)), 0.01),
		"avg_crime": snappedf(cr / float(maxi(dev, 1)), 0.01),
		"avg_traffic": snappedf(tr / float(maxi(int(counts["roads"]), 1)), 0.01),
		"pop": m["pop"], "jobs": m["jobs"], "happiness": snappedf(float(m["happiness"]), 0.01),
		"treasury": m["treasury"], "income": m["last_income"], "upkeep": m["last_upkeep"],
		"tax": {"r": m["tax_r"], "c": m["tax_c"], "i": m["tax_i"]},
		"under_construction": site_summary(d),
	}


func tile_char(i: int) -> String:
	if burning[i] > 0:
		return "*"
	var k := kind[i]
	if k == D.SITE:
		return "+"
	if terrain[i] == D.WATER and k != D.ROAD:
		return "~"
	if D.is_zone(k):
		return str(D.DEV_CHAR[k]) if level[i] > 0 else str(D.ZONE_CHAR[k])
	return str(D.MAP_CHAR.get(k, "?"))


func district_ascii(d: int) -> String:
	var b := district_rect(d)
	var lines: Array[String] = []
	var header := "     "
	for x in range(b.position.x, b.end.x):
		header += str(x % 10)
	lines.append("x->  " + header.substr(5) + "   (x from %d to %d)" % [b.position.x, b.end.x - 1])
	for y in range(b.position.y, b.end.y):
		var row := "y%02d  " % y
		for x in range(b.position.x, b.end.x):
			var i := D.idx(x, y)
			row += tile_char(i) if district[i] == d else " "
		lines.append(row)
	return "\n".join(lines)


## Empty land tiles in district d next to a road (best spots for zoning/buildings).
func open_lots(d: int, max_n: int = 14) -> Array:
	var out: Array = []
	var b := district_rect(d)
	for y in range(b.position.y, b.end.y):
		for x in range(b.position.x, b.end.x):
			var i := D.idx(x, y)
			if district[i] == d and road_dist[i] == 1 and (kind[i] == D.EMPTY or kind[i] == D.FOREST) and terrain[i] == D.LAND:
				out.append([x, y])
	if out.size() > max_n:
		var step := float(out.size()) / float(max_n)
		var sampled: Array = []
		for k in range(max_n):
			sampled.append(out[int(float(k) * step)])
		return sampled
	return out


func city_summary() -> Dictionary:
	var ev_list: Array = []
	for ev in events:
		if work_based():
			ev_list.append("%s at (%d,%d) in %s: %d%% repaired, %d resident reports, helpers: %s" % [ev["label"], int(ev["x"]), int(ev["y"]), owner_name(D.idx(int(ev["x"]), int(ev["y"]))), int(100.0 * float(ev["progress"]) / maxf(1.0, float(ev["work"]))), int(ev.get("reports", 0)), ", ".join(PackedStringArray((ev["helpers"] as Dictionary).keys().slice(0, 4))) if not (ev["helpers"] as Dictionary).is_empty() else "nobody yet"])
		else:
			ev_list.append("%s at (%d,%d) in %s until day %d" % [ev["label"], int(ev["x"]), int(ev["y"]), owner_name(D.idx(int(ev["x"]), int(ev["y"]))), int(ev["until_day"])])
	var fires := 0
	for i in active:
		if burning[i] > 0:
			fires += 1
	return {
		"day": day, "population": stats.get("population", 0), "jobs": stats.get("jobs", 0),
		"unemployment": snappedf(float(stats.get("unemployment", 0.0)), 0.01),
		"happiness": snappedf(float(stats.get("happiness", 0.0)), 0.01),
		"demand": {"R": snappedf(float(demand["r"]), 0.01), "C": snappedf(float(demand["c"]), 0.01), "I": snappedf(float(demand["i"]), 0.01)},
		"power": "%d/%d MW used/capacity (need %d)" % [int(stats.get("power_used", 0)), int(stats.get("power_cap", 0)), int(stats.get("power_need", 0))],
		"water": "%d/%d used/capacity (need %d)" % [int(stats.get("water_used", 0)), int(stats.get("water_cap", 0)), int(stats.get("water_need", 0))],
		"sewage": "%d/%d capacity/need" % [int(stats.get("sewage_cap", 0)), int(stats.get("sewage_need", 0))],
		"waste": "%d/%d landfill capacity/need" % [int(stats.get("waste_cap", 0)), int(stats.get("waste_need", 0))],
		"avg_pollution": snappedf(float(stats.get("pollution", 0.0)), 0.01),
		"avg_crime": snappedf(float(stats.get("crime", 0.0)), 0.01),
		"avg_traffic": snappedf(float(stats.get("traffic", 0.0)), 0.01),
		"active_events": ev_list, "fires_burning": fires,
		"ordinances": ordinances.keys(),
	}


func sample_citizens(n: int) -> Array:
	var homes: Array[int] = []
	for i in active:
		if kind[i] == D.ZONE_R and level[i] > 0:
			homes.append(i)
	homes.shuffle()
	var out: Array = []
	var first := ["Ava", "Ben", "Chen", "Dara", "Eli", "Fatima", "Gus", "Hana", "Ivan", "Jade", "Kofi", "Lena", "Mateo", "Nia", "Omar", "Priya", "Quinn", "Rosa", "Sami", "Tomas", "Uma", "Vik", "Wren", "Yuki", "Zane"]
	for k in range(mini(n, homes.size())):
		var i := homes[k]
		var x := D.tx(i)
		var y := D.ty(i)
		out.append({
			"id": "c%d" % i, "name": first[(i * 7 + day) % first.size()], "x": x, "y": y,
			"district_mayor": owner_name(i), "density": level[i],
			"has_power": powered[i] == 1, "has_water": watered[i] == 1,
			"pollution": snappedf(pollution[i], 0.01), "crime": snappedf(crime[i], 0.01),
			"commute_traffic": snappedf(commute(x, y), 0.01), "happiness": snappedf(happiness[i], 0.01),
			"near_fire_station": cov_fire[i] > 0.2, "near_hospital": cov_health[i] > 0.2,
			"near_school": cov_school[i] > 0.2, "near_park": cov_park[i] > 0.2,
			"tax_rate": mayors[district[i]]["tax_r"] if district[i] >= 0 else 0,
		})
	return out


func tile_report(x: int, y: int) -> Dictionary:
	if not D.in_bounds(x, y):
		return {}
	var i := D.idx(x, y)
	var k := kind[i]
	var label: String = D.KIND_NAMES[k]
	if terrain[i] == D.WATER and k != D.ROAD:
		label = "river"
	var bk := D.building_key_for_kind(k)
	if not bk.is_empty():
		label = str(D.BUILDINGS[bk]["label"])
	return {
		"x": x, "y": y, "kind": label, "density": level[i], "district_mayor": owner_name(i),
		"district_index": district[i], "powered": powered[i] == 1, "watered": watered[i] == 1,
		"burning": burning[i] > 0, "pollution": snappedf(pollution[i], 0.01), "crime": snappedf(crime[i], 0.01),
		"land_value": snappedf(land_value[i], 0.01), "traffic": snappedf(traffic[i] if k == D.ROAD else commute(x, y), 0.01),
		"happiness": snappedf(happiness[i], 0.01), "residents": tile_pop(i), "jobs": tile_jobs(i),
		"road_access": road_dist[i] <= 2, "disabled": disabled_until.has(i), "construction": site_info(i),
		"coverage": {"police": snappedf(cov_police[i], 0.01), "fire": snappedf(cov_fire[i], 0.01), "health": snappedf(cov_health[i], 0.01), "school": snappedf(cov_school[i], 0.01), "park": snappedf(cov_park[i], 0.01), "leisure": snappedf(cov_leisure[i], 0.01), "transit": snappedf(cov_transit[i], 0.01)},
	}


# ---------------------------------------------------------------- save / load

func to_dict() -> Dictionary:
	return {
		"version": 3, "seed": city_seed, "day": day, "tick_in_day": tick_in_day,
		"world": {"w": D.W, "h": D.H, "x0": D.X0, "y0": D.Y0},
		"kind": Array(kind), "level": Array(level), "terrain": Array(terrain), "burning": Array(burning), "district": Array(district),
		"mayors": mayors.duplicate(true), "ordinances": ordinances.duplicate(), "events": events.duplicate(true),
		"disabled_until": disabled_until.duplicate(), "grid_priority": grid_priority.duplicate(), "broken_roads": broken_roads.duplicate(),
		"history": history.duplicate(true), "log": log_lines.duplicate(), "event_seq": _event_seq,
		"sites": sites.values().duplicate(true), "site_seq": _site_seq,
	}


func from_dict(data: Dictionary) -> bool:
	# Version 1 saves predate the 96x96 world and are not converted. Version 2 saves (96x96)
	# are placed into the bigger world; the fresh wilds generated around them stay.
	var version := int(data.get("version", 0))
	if version != 2 and version != 3:
		return false
	new_city(int(data.get("seed", 7)))
	var n := D.W * D.H
	var world: Dictionary = data.get("world", D.LEGACY_WORLD)
	var src := {"w": int(world.get("w", 96)), "h": int(world.get("h", 96)), "x0": int(world.get("x0", -32)), "y0": int(world.get("y0", -32))}
	var same := int(src["w"]) == D.W and int(src["h"]) == D.H and int(src["x0"]) == D.X0 and int(src["y0"]) == D.Y0
	var k_arr: Array = data.get("kind", [])
	var d_arr: Array = data.get("district", [])
	var src_n := int(src["w"]) * int(src["h"])
	if k_arr.size() != src_n or d_arr.size() != src_n:
		return false
	if same:
		kind = PackedInt32Array(k_arr)
		level = PackedInt32Array(data.get("level", []))
		terrain = PackedInt32Array(data.get("terrain", []))
		burning = PackedInt32Array(data.get("burning", []))
		district = PackedInt32Array(d_arr)
	else:
		load_remap = src
		kind = _place_tiles(k_arr, kind)
		level = _place_tiles(data.get("level", []), level)
		terrain = _place_tiles(data.get("terrain", []), terrain)
		burning = _place_tiles(data.get("burning", []), burning)
		district = _place_tiles(d_arr, district)
	if district.size() != n:
		return false
	_wet2 = PackedByteArray()
	_rebuild_active()
	day = int(data.get("day", 1))
	tick_in_day = int(data.get("tick_in_day", 0))
	mayors.clear()
	for m in data.get("mayors", []):
		mayors.append(m as Dictionary)
	for mi in range(mini(mayors.size(), D.MAYORS.size())):
		mayors[mi]["name"] = D.MAYORS[mi]["display"]
	ordinances = data.get("ordinances", {})
	events.clear()
	for ev in data.get("events", []):
		var e: Dictionary = ev
		if not load_remap.is_empty():
			e["tiles"] = (e.get("tiles", []) as Array).map(func(t: Variant) -> int: return remap_index(int(t)))
		events.append(e)
	disabled_until.clear()
	var du: Dictionary = data.get("disabled_until", {})
	for key in du.keys():
		disabled_until[remap_index(int(key))] = int(du[key])
	grid_priority = data.get("grid_priority", [2, 0, 1, 3, 4])
	broken_roads.clear()
	var br: Dictionary = data.get("broken_roads", {})
	for key in br.keys():
		broken_roads[remap_index(int(key))] = int(br[key])
	history.clear()
	for h in data.get("history", []):
		history.append(h as Dictionary)
	log_lines.clear()
	for l in data.get("log", []):
		log_lines.append(str(l))
	_event_seq = int(data.get("event_seq", 0))
	sites.clear()
	for v: Variant in data.get("sites", []):
		var s: Dictionary = (v as Dictionary).duplicate(true)
		for key in ["id", "i", "x", "y", "owner", "from_kind", "from_level", "target_kind", "target_level", "stage", "start_tick"]:
			s[key] = int(s.get(key, 0))
		s["i"] = D.idx(int(s["x"]), int(s["y"]))
		s["progress"] = float(s.get("progress", 0.0))
		s["stage_work"] = float(s.get("stage_work", D.CREW_RATE))
		s["rate"] = float(s.get("rate", D.CREW_RATE))
		s["tick_work"] = float(s.get("tick_work", D.CREW_RATE))
		sites[int(s["i"])] = s
	_site_seq = int(data.get("site_seq", sites.size()))
	for i in range(n):
		if kind[i] == D.SITE and not sites.has(i):
			kind[i] = D.EMPTY
	_recompute_all()
	_flush_changes(true)
	return true


## Copies a saved per-tile array from the load_remap layout onto base (the current world).
func _place_tiles(src: Array, base: PackedInt32Array) -> PackedInt32Array:
	var out := base.duplicate()
	var w := int(load_remap["w"])
	for k in range(mini(src.size(), w * int(load_remap["h"]))):
		var x := k % w + int(load_remap["x0"])
		var y := k / w + int(load_remap["y0"])
		if D.in_bounds(x, y):
			out[D.idx(x, y)] = int(src[k])
	return out


## Moves a tile index saved in an older world layout to the current one (-1 if it falls outside).
func remap_index(i: int) -> int:
	if load_remap.is_empty() or i < 0:
		return i
	var w := int(load_remap["w"])
	var x := i % w + int(load_remap["x0"])
	var y := i / w + int(load_remap["y0"])
	return D.idx(x, y) if D.in_bounds(x, y) else -1


# ---------------------------------------------------------------- helpers

func _ints(n: int) -> PackedInt32Array:
	var a := PackedInt32Array()
	a.resize(n)
	a.fill(0)
	return a


func _bytes(n: int) -> PackedByteArray:
	var a := PackedByteArray()
	a.resize(n)
	a.fill(0)
	return a


func _floats(n: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(n)
	a.fill(0.0)
	return a

func _mark(i: int) -> void:
	_changed[i] = true


func _flush_changes(force_stats: bool) -> void:
	if not _changed.is_empty():
		var arr := PackedInt32Array()
		for key in _changed.keys():
			arr.append(int(key))
		_changed.clear()
		tiles_changed.emit(arr)
	stats_updated.emit()
	if force_stats:
		pass


func _log(msg: String, category: String) -> void:
	var line := "Day %d: %s" % [day, msg]
	log_lines.append(line)
	if log_lines.size() > 200:
		log_lines.pop_front()
	city_log.emit(line, category)
