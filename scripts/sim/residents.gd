class_name Residents
extends Node
## The people of GridFall: up to 100 named residents, each standing in for an equal share of the
## population. Their GMI minds (ResidentMinds) choose how they commute, spend, feel, whether they
## stay, and whether they help when something breaks. This node turns those choices into the
## traffic, mood, money and repair work that CitySim reads.

signal resident_arrived(r: Dictionary)
signal resident_departed(r: Dictionary, reason: String)
signal resident_moved(r: Dictionary)
signal day_ready(day: int)
## A resident spoke out loud or wrote to their mayor. kind: "say" (daily plan line), "react"
## (incident reaction line), "letter" (message to the mayor). text is never empty.
signal resident_said(id: String, text: String, kind: String)
## A resident set off from tile from_i to tile to_i (sim arrival is instant; the view animates
## the trip). mode: car | bus | bike | walk.
signal trip_started(id: String, from_i: int, to_i: int, mode: String)

const D := preload("res://scripts/sim/sim_defs.gd")
const MAX_RESIDENTS := 100
## One named resident per this many people until the cap is reached.
const PEOPLE_PER_RESIDENT := 10.0
## Personal dollars -> city tax base for the share of people a resident stands for.
const WAGE_SCALE := 0.0175
const SALES_SCALE := 0.06
const TRIP_SCALE := 0.35
const MODE_WEIGHT := {"car": 1.0, "bus": 0.25, "bike": 0.05, "walk": 0.0, "stay_home": 0.0}
const LIVING_COST := 30
const N4 := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
## Residents handled per work unit of a sliced tick, and the route-search cache size (one
## 192x192 parent map per origin road tile).
const RES_PER_UNIT := 4
const BFS_CACHE_MAX := 160
const _BIG := 1 << 30
const COMMUTES := ["car", "bus", "bike", "walk", "stay_home"]
const SPEND_WHERE := ["local", "downtown", "online", "none"]
const EVENINGS := ["home", "shopping", "park", "stadium", "visit_friend", "help_neighbors", "protest", "work_overtime"]
const INTENTS := ["stay", "considering_leaving", "leaving"]
const COMPLAINTS := ["none", "power", "water", "sewage", "trash", "pollution", "crime", "traffic", "taxes", "rent", "jobs", "health", "incident", "noise"]
const ACTIONS := ["help", "report", "avoid", "evacuate", "ignore"]

## wage is personal dollars per working day; "at" lists the tile kinds that employ them.
const OCCUPATIONS := {
	"electrician": {"skills": ["power", "construction"], "wage": 210, "at": [D.ZONE_I, D.ZONE_C, D.COAL, D.SOLAR, D.WIND]},
	"power line technician": {"skills": ["power"], "wage": 230, "at": [D.COAL, D.SOLAR, D.WIND, D.ZONE_I]},
	"power plant operator": {"skills": ["power", "industry"], "wage": 245, "at": [D.COAL, D.SOLAR, D.WIND]},
	"plumber": {"skills": ["water", "sewage"], "wage": 195, "at": [D.ZONE_C, D.ZONE_I, D.PUMP]},
	"water utility engineer": {"skills": ["water", "construction"], "wage": 235, "at": [D.PUMP, D.SEWAGE]},
	"sanitation worker": {"skills": ["sewage"], "wage": 150, "at": [D.SEWAGE, D.LANDFILL]},
	"firefighter": {"skills": ["fire", "rescue"], "wage": 205, "at": [D.FIRE]},
	"paramedic": {"skills": ["medical", "rescue"], "wage": 190, "at": [D.HOSPITAL, D.FIRE]},
	"nurse": {"skills": ["medical", "care"], "wage": 200, "at": [D.HOSPITAL]},
	"doctor": {"skills": ["medical"], "wage": 380, "at": [D.HOSPITAL]},
	"police officer": {"skills": ["order", "traffic"], "wage": 210, "at": [D.POLICE]},
	"bus driver": {"skills": ["traffic"], "wage": 160, "at": [D.TRAIN, D.ZONE_C]},
	"truck driver": {"skills": ["traffic", "industry"], "wage": 170, "at": [D.ZONE_I, D.LANDFILL]},
	"mechanic": {"skills": ["traffic", "industry"], "wage": 170, "at": [D.ZONE_I, D.ZONE_C]},
	"construction worker": {"skills": ["construction", "rescue"], "wage": 180, "at": [D.ZONE_I, D.ZONE_C]},
	"civil engineer": {"skills": ["construction", "water"], "wage": 265, "at": [D.ZONE_C, D.HALL]},
	"factory worker": {"skills": ["industry"], "wage": 160, "at": [D.ZONE_I]},
	"warehouse worker": {"skills": ["industry"], "wage": 140, "at": [D.ZONE_I]},
	"shop owner": {"skills": [], "wage": 200, "at": [D.ZONE_C]},
	"cashier": {"skills": [], "wage": 120, "at": [D.ZONE_C]},
	"chef": {"skills": [], "wage": 150, "at": [D.ZONE_C]},
	"barista": {"skills": [], "wage": 110, "at": [D.ZONE_C]},
	"software developer": {"skills": [], "wage": 320, "at": [D.ZONE_C]},
	"accountant": {"skills": [], "wage": 260, "at": [D.ZONE_C, D.HALL]},
	"teacher": {"skills": ["care"], "wage": 190, "at": [D.SCHOOL, D.UNIVERSITY]},
	"professor": {"skills": ["care"], "wage": 300, "at": [D.UNIVERSITY]},
	"city clerk": {"skills": ["order"], "wage": 170, "at": [D.HALL]},
	"airport worker": {"skills": ["traffic"], "wage": 200, "at": [D.AIRPORT]},
	"stadium staff": {"skills": [], "wage": 130, "at": [D.STADIUM]},
	"caregiver": {"skills": ["care", "medical"], "wage": 150, "at": [D.HOSPITAL, D.ZONE_C]},
	"artist": {"skills": [], "wage": 110, "at": [D.ZONE_C]},
	"student": {"skills": [], "wage": 0, "at": [D.SCHOOL, D.UNIVERSITY]},
	"retiree": {"skills": ["care"], "wage": 0, "at": []},
}
const FIRST_NAMES := ["Ava", "Ben", "Chen", "Dara", "Eli", "Fatima", "Gus", "Hana", "Ivan", "Jade", "Kofi", "Lena", "Mateo", "Nia", "Omar", "Priya", "Quinn", "Rosa", "Sami", "Tomas", "Uma", "Vik", "Wren", "Yuki", "Zane", "Aiko", "Bruno", "Carmen", "Dmitri", "Esi", "Farid", "Greta", "Hugo", "Imani", "Jonas", "Keiko", "Luis", "Maya", "Nikhil", "Olga", "Pablo", "Rania", "Sven", "Tara", "Ugo", "Valeria", "Wei", "Ximena", "Yara", "Zoltan", "Amara", "Bilal", "Clara", "Desmond", "Elif", "Femi", "Gloria", "Hamza", "Ines", "Jamal"]
const LAST_NAMES := ["Diaz", "Okafor", "Nguyen", "Kowalski", "Haddad", "Silva", "Brennan", "Tanaka", "Petrov", "Mensah", "Larsen", "Gupta", "Moreau", "Rossi", "Kim", "Abebe", "Fischer", "Chowdhury", "Santos", "Novak", "Ibrahim", "Lindqvist", "Park", "Mwangi", "Oyelaran", "Castillo", "Weber", "Sato", "Hughes", "Rahman", "Costa", "Jovanovic", "Achebe", "Yilmaz", "Murphy", "Zhou", "Alvarez", "Banerjee", "Dubois", "Eriksen"]
const TRAITS := ["anxious", "frugal", "sociable", "stubborn", "optimistic", "proud", "lazy", "caring", "grumpy", "brave", "ambitious", "cautious", "civic-minded", "impatient", "generous", "skeptical", "hardworking", "laid-back", "outspoken", "shy", "curious", "loyal to the city", "restless", "practical", "romantic", "cynical", "family-first", "thrifty", "adventurous", "community organizer"]
const HOUSEHOLDS := ["lives alone", "lives with a partner", "single parent of one", "parent of two young kids", "shares a flat with roommates", "cares for an elderly parent", "newlywed", "big family of five", "lives with a dog", "empty nester"]

var sim: CitySim
var enabled: bool = true
var people: Array[Dictionary] = []
var departed: Array[Dictionary] = []
var messages: Array[Dictionary] = []
var protests: Array = [0, 0, 0, 0, 0]
var trip_load := PackedFloat32Array()
var mood_map := PackedFloat32Array()
var sentiment: Dictionary = {"recommend": 6.0, "leaving": 0.0, "spend_local": 0.0, "attendance": 1.0, "mood": 0.6}
## People each resident stands for right now.
var share: float = 0.0
var _money: Array = []
var _seq: int = 0
var _rng := RandomNumberGenerator.new()
var _road_sig: int = -1
var _trips_dirty: bool = true
var _blocked: Dictionary = {}
var _blocked_epoch: int = 0
# Sliced work driven by CitySim's job (see begin_tick / begin_day); {} when idle.
var _tk: Dictionary = {}
var _dj: Dictionary = {}
# Route searches per origin road tile, valid while the roads (sim.road_epoch) and the blocked
# tiles (_blocked_epoch) stay the same; the result is identical to a fresh search.
var _bfs_cache: Dictionary = {}
var _bfs_sig := Vector2i(-1, -1)


func setup(p_sim: CitySim) -> void:
	sim = p_sim
	_rng.seed = sim.city_seed * 31 + 5
	people.clear()
	departed.clear()
	messages.clear()
	protests = [0, 0, 0, 0, 0]
	_seq = 0
	_reset_money()
	if not sim.tick_done.is_connected(_on_tick):
		sim.tick_done.connect(_on_tick)
		sim.day_started.connect(_on_day_started)
		sim.day_ended.connect(_on_day_ended)
		sim.event_ended.connect(_on_event_ended)
		sim.site_finished.connect(_on_site_finished)
	sim.people = self
	abort_jobs()
	_bfs_cache.clear()
	_bfs_sig = Vector2i(-1, -1)
	_trips_dirty = true
	rebuild_maps()


func is_active() -> bool:
	return enabled and not people.is_empty()


func key(r: Dictionary) -> String:
	return "%s:%s" % [r["id"], r["name"]]


func find(id: String) -> Dictionary:
	for r in people:
		if str(r["id"]) == id:
			return r
	return {}


func district_money() -> Array:
	return _money


func _reset_money() -> void:
	_money = []
	for _d in range(D.MAYORS.size()):
		_money.append({"wages": 0.0, "sales": 0.0})


# ---------------------------------------------------------------- maps read by CitySim

func rebuild_maps() -> void:
	var st := {}
	while not maps_step(st, _BIG):
		pass


## One step of a resumable rebuild_maps() that keeps its state in st (CitySim's recompute task, or
## a fresh dictionary): share, road signature, trips (one origin's road search per unit), mood map
## and sentiment, in that order. lim is this call's work budget in tile visits. True when done.
func maps_step(st: Dictionary, lim: int) -> bool:
	if not st.has("ms"):
		var n := D.W * D.H
		if sim == null or sim.kind.size() != n:
			return true
		if mood_map.size() != n:
			mood_map.resize(n)
		if trip_load.size() != n:
			trip_load.resize(n)
			trip_load.fill(0.0)
		st["ms"] = 0
		st["mk"] = 0
		st["mact"] = sim.active
		st["mpop"] = 0
	var big := lim >= _BIG
	var act: PackedInt32Array = st["mact"]
	match int(st["ms"]):
		0:
			var k := int(st["mk"])
			var end := act.size() if big else mini(act.size(), k + maxi(1, lim / 4))
			var pop: int = st["mpop"]
			for kk in range(k, end):
				pop += sim.tile_pop(act[kk])
			st["mpop"] = pop
			st["mk"] = end
			if end < act.size():
				return false
			share = float(pop) / float(maxi(people.size(), 1))
			st["ms"] = 1
			st["mk"] = 0
			st["mh"] = 17
		1:
			var k := int(st["mk"])
			var end := act.size() if big else mini(act.size(), k + lim)
			var h: int = st["mh"]
			for kk in range(k, end):
				var i := act[kk]
				if sim.kind[i] == D.ROAD:
					h = (h * 31 + i) % 1000000007
			st["mh"] = h
			st["mk"] = end
			if end < act.size():
				return false
			var sig := _finish_road_signature(h)
			if sig != _road_sig:
				_road_sig = sig
				_trips_dirty = true
			st["mk"] = 0
			if _trips_dirty:
				_trips_dirty = false
				st["ms"] = 2
				st["mtl"] = _floats(D.W * D.H)
				st["morig"] = {}
				st["mpc"] = {}
			else:
				st["ms"] = 4
		2:
			var by_origin: Dictionary = st["morig"]
			var pc: Dictionary = st["mpc"]
			var k := int(st["mk"])
			var end := people.size() if big else mini(people.size(), k + maxi(1, lim / 256))
			while k < end:
				_trip_pairs(people[k], by_origin, pc)
				k += 1
				if sim.step_heavy():
					break
			st["mk"] = k
			if k < people.size():
				return false
			st["morder"] = by_origin.keys()
			st["ms"] = 3
			st["mk"] = 0
		3:
			var by_origin: Dictionary = st["morig"]
			var order: Array = st["morder"]
			var tl: PackedFloat32Array = st["mtl"]
			var k := int(st["mk"])
			var work := lim
			while k < order.size() and work > 0:
				var o: int = order[k]
				k += 1
				var parent := _bfs(o)
				for item: Variant in by_origin[o]:
					var pair: Array = item
					var c := int(pair[0])
					if parent[c] == -2:
						continue
					var guard := 0
					while c >= 0 and guard < 400:
						tl[c] += float(pair[1])
						c = parent[c]
						guard += 1
					work -= 8 + guard
				if sim.step_heavy():
					break
			st["mk"] = k
			if k < order.size():
				return false
			trip_load = tl
			st["ms"] = 4
			st["mk"] = 0
		4:
			if not st.has("mm"):
				_mood_begin(st)
			if not _mood_step(st, act, lim, big):
				return false
			st["ms"] = 5
		5:
			_compute_sentiment()
			return true
	return false


func _update_share() -> void:
	var pop := 0
	for i in sim.active:
		pop += sim.tile_pop(i)
	share = float(pop) / float(maxi(people.size(), 1))


## Ends the road signature started over the road tiles (h): rebuilds the blocked tiles (downed
## lines, crashes) and folds them in. A change of the blocked set invalidates cached road searches.
func _finish_road_signature(h: int) -> int:
	var blocked: Dictionary = {}
	for k: Variant in sim.broken_roads.keys():
		blocked[int(k)] = true
	for ev in sim.events:
		if str(ev["type"]) == "car_crash":
			blocked[D.idx(int(ev["x"]), int(ev["y"]))] = true
	if blocked != _blocked:
		_blocked_epoch += 1
	_blocked = blocked
	for k: int in _blocked.keys():
		h = (h * 37 + k + 7) % 1000000007
	return h


## Adds r's commute (and shop run) to by_origin: road tile -> [[goal road tile, weight], ...].
func _trip_pairs(r: Dictionary, by_origin: Dictionary, pc: Dictionary) -> void:
	var p: Dictionary = r.get("plan", {})
	var w := int(r["work"])
	if w < 0 or not _as_bool(p.get("go_to_work", true)):
		return
	var mode := str(p.get("commute", "car"))
	var weight := share * TRIP_SCALE * float(MODE_WEIGHT.get(mode, 1.0))
	if weight <= 0.0:
		return
	var o := _near_road(int(r["home"]))
	var g := _near_road(w)
	if o < 0 or g < 0:
		return
	if not by_origin.has(o):
		by_origin[o] = []
	(by_origin[o] as Array).append([g, weight])
	var shop := _shop_for(r, pc)
	if shop >= 0:
		var sg := _near_road(shop)
		if sg >= 0:
			(by_origin[o] as Array).append([sg, weight * 0.4])


## Homes with named residents, in first-seen order, as flat arrays for the mood map pass.
func _mood_begin(st: Dictionary) -> void:
	st["mm"] = _floats(D.W * D.H)
	st["mk"] = 0
	if people.is_empty():
		st["mn"] = 0
		return
	var at_home: Dictionary = {}
	var avg := 0.0
	for r in people:
		var h := int(r["home"])
		var m := clampf(float(r["mood"]) / 10.0, 0.0, 1.0)
		avg += m
		if not at_home.has(h):
			at_home[h] = [0.0, 0]
		var a: Array = at_home[h]
		a[0] = float(a[0]) + m
		a[1] = int(a[1]) + 1
	avg /= float(people.size())
	var hx := PackedInt32Array()
	var hy := PackedInt32Array()
	var hs: Array = []
	var hc := PackedInt32Array()
	for h: int in at_home.keys():
		var a: Array = at_home[h]
		hx.append(D.tx(h))
		hy.append(D.ty(h))
		hs.append(float(a[0]))
		hc.append(int(a[1]))
	st["mat"] = at_home
	st["mhx"] = hx
	st["mhy"] = hy
	st["mhs"] = hs
	st["mhc"] = hc
	st["mavg"] = avg
	st["mn"] = 1


## Homes without a named resident take the mood of the neighbours who live nearby. Only `active`
## can hold developed homes, so the pass skips the wilds (identical result, mood_map starts at 0).
func _mood_step(st: Dictionary, act: PackedInt32Array, lim: int, big: bool) -> bool:
	var mm: PackedFloat32Array = st["mm"]
	if int(st["mn"]) == 0:
		mood_map = mm
		return true
	var at_home: Dictionary = st["mat"]
	var hx: PackedInt32Array = st["mhx"]
	var hy: PackedInt32Array = st["mhy"]
	var hs: Array = st["mhs"]
	var hc: PackedInt32Array = st["mhc"]
	var avg: float = st["mavg"]
	var nh := hx.size()
	var k := int(st["mk"])
	var work := lim
	while k < act.size() and (big or work > 0):
		var i := act[k]
		k += 1
		work -= 1
		if sim.kind[i] != D.ZONE_R or sim.level[i] <= 0:
			continue
		if at_home.has(i):
			var a: Array = at_home[i]
			mm[i] = float(a[0]) / float(a[1])
			continue
		work -= nh
		var wsum := 0.0
		var msum := 0.0
		var x := D.tx(i)
		var y := D.ty(i)
		for j in range(nh):
			var d := absi(hx[j] - x) + absi(hy[j] - y)
			if d > 6:
				continue
			var wgt := 1.0 / (1.0 + float(d))
			wsum += wgt * float(hc[j])
			msum += wgt * float(hs[j])
		mm[i] = msum / wsum if wsum > 0.0 else avg
	st["mk"] = k
	if k < act.size():
		return false
	mood_map = mm
	return true


func _floats(n: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(n)
	a.fill(0.0)
	return a


func _compute_sentiment() -> void:
	if people.is_empty():
		return
	var rec := 0.0
	var leaving := 0.0
	var spend := 0.0
	var workers := 0
	var going := 0
	var mood := 0.0
	for r in people:
		var p: Dictionary = r.get("plan", {})
		rec += float(r["recommend"])
		mood += float(r["mood"]) / 10.0
		var intent := str(r["intent"])
		if intent == "leaving":
			leaving += 1.0
		elif intent == "considering_leaving":
			leaving += 0.5
		if str(p.get("spend_where", "local")) in ["local", "downtown"]:
			spend += float(p.get("spend", 30)) * share * SALES_SCALE
		if int(r["work"]) >= 0:
			workers += 1
			if _as_bool(p.get("go_to_work", true)) and str(p.get("commute", "car")) != "stay_home":
				going += 1
	var nf := float(people.size())
	sentiment["recommend"] = rec / nf
	sentiment["leaving"] = leaving / nf
	sentiment["spend_local"] = spend
	sentiment["attendance"] = float(going) / float(workers) if workers > 0 else 1.0
	sentiment["mood"] = mood / nf


func district_mood(d: int) -> Dictionary:
	var n := 0
	var mood := 0.0
	var approve := 0.0
	var leaving := 0
	var unemployed := 0
	var complaints: Dictionary = {}
	for r in people:
		if sim.district[int(r["home"])] != d:
			continue
		n += 1
		mood += float(r["mood"])
		approve += float(r["approve"])
		if str(r["intent"]) != "stay":
			leaving += 1
		if int(r["work"]) < 0 and str(r["job_title"]) not in ["retiree", "student"]:
			unemployed += 1
		var c := str(r["complaint"])
		if c != "none":
			complaints[c] = int(complaints.get(c, 0)) + 1
	return {
		"residents": n, "avg_mood": snappedf(mood / float(maxi(n, 1)), 0.1), "approval": snappedf(approve / float(maxi(n, 1)), 0.1),
		"thinking_of_leaving": leaving, "unemployed": unemployed, "complaints": complaints, "protested_yesterday": int(protests[d]),
	}


func messages_for(d: int, max_n: int = 6) -> Array:
	var out: Array = []
	for i in range(messages.size() - 1, -1, -1):
		var m: Dictionary = messages[i]
		if int(m["district"]) == d and sim.day - int(m["day"]) <= 1:
			out.append(m)
			if out.size() >= max_n:
				break
	return out


# ---------------------------------------------------------------- daily life

func _on_day_started(day: int) -> void:
	# Sliced: the sim's day job runs this work through begin_day() / pump_day() after the emission.
	if sim != null and sim.day_start_deferred():
		return
	begin_day(day)
	while not _day_unit(_BIG):
		pass


## Starts the day-start work (moves, new jobs, arrivals, maps, then day_ready) as a resumable job.
func begin_day(day: int) -> void:
	_dj = {"day": day, "s": 0, "k": 0, "pop": 0}


## Advances the day-start job: one unit when budget_ms <= 0, else units until budget_ms is spent.
## Emits day_ready and returns true when the job is done.
func pump_day(budget_ms: float) -> bool:
	var t0 := Time.get_ticks_usec()
	while true:
		if _day_unit(RES_PER_UNIT):
			return true
		if budget_ms <= 0.0 or Time.get_ticks_usec() - t0 >= int(budget_ms * 1000.0):
			return false
	return false


## True while a sliced day-start job is in flight.
func day_job_running() -> bool:
	return not _dj.is_empty()


## Up to n residents (stopping after a heavy one), one arrival, or n * 64 tiles of a scan per call.
func _day_unit(n: int) -> bool:
	if _dj.is_empty():
		return true
	var day := int(_dj["day"])
	match int(_dj["s"]):
		0:
			if not enabled or sim == null:
				_dj = {}
				day_ready.emit(day)
				return true
			if not _pop_scan(_dj, n):
				return false
			share = float(int(_dj["pop"])) / float(maxi(people.size(), 1))
			_dj["list"] = people.duplicate()
			_dj["s"] = 1
		1:
			var list: Array = _dj["list"]
			var k := int(_dj["k"])
			var end := mini(list.size(), k + n)
			while k < end:
				_check_home(list[k], day)
				k += 1
				if sim.step_heavy():
					break
			_dj["k"] = k
			if k >= list.size():
				_dj["s"] = 2
				_dj["k"] = 0
		2:
			var k := int(_dj["k"])
			var end := mini(people.size(), k + n)
			while k < end:
				_check_job(people[k], day)
				k += 1
				if sim.step_heavy():
					break
			_dj["k"] = k
			if k >= people.size():
				_dj["s"] = 3
				_dj["k"] = 0
				_dj["pop"] = 0
		3:
			if not _pop_scan(_dj, n):
				return false
			var target := clampi(int(ceil(float(int(_dj["pop"])) / PEOPLE_PER_RESIDENT)), 0, MAX_RESIDENTS)
			_dj["target"] = target
			_dj["max_new"] = maxi(3, target / 8)
			_dj["made"] = 0
			_dj["demand_ok"] = float(sim.demand["r"]) > -0.25 or people.size() < 4
			_dj["s"] = 4
		4:
			var made := int(_dj["made"])
			if people.size() < int(_dj["target"]) and made < int(_dj["max_new"]) and bool(_dj["demand_ok"]) and not _spawn(day).is_empty():
				_dj["made"] = made + 1
				return false
			_trips_dirty = true
			_dj["maps"] = {}
			_dj["s"] = 5
		5:
			if not maps_step(_dj["maps"], CitySim.UNIT_WORK if n < _BIG else _BIG):
				return false
			_dj = {}
			day_ready.emit(day)
			return true
	return false


## Sums tile_pop over sim.active into state["pop"], n * 64 tiles per call; true when done.
func _pop_scan(state: Dictionary, n: int) -> bool:
	var act := sim.active
	var k := int(state["k"])
	var end := act.size() if n >= _BIG else mini(act.size(), k + n * 64)
	var pop: int = state["pop"]
	for kk in range(k, end):
		pop += sim.tile_pop(act[kk])
	state["pop"] = pop
	state["k"] = end
	if end < act.size():
		return false
	state["k"] = 0
	return true


func _on_day_ended(_day: int) -> void:
	_reset_money()
	var keep: Array[Dictionary] = []
	for m in messages:
		if sim.day - int(m["day"]) <= 2:
			keep.append(m)
	messages = keep


func _target_count() -> int:
	var pop := 0
	for i in sim.active:
		pop += sim.tile_pop(i)
	return clampi(int(ceil(float(pop) / PEOPLE_PER_RESIDENT)), 0, MAX_RESIDENTS)


func _on_tick(t: int) -> void:
	# Sliced: the sim's tick job already ran this tick's work through begin_tick() / pump_tick().
	if sim != null and sim.is_tick_running():
		return
	if not is_active():
		return
	begin_tick(t)
	while not _tick_unit(_BIG):
		pass


## Starts tick t's resident work (the daily routine phase, then helpers on sites and incidents) as a
## resumable job.
func begin_tick(t: int) -> void:
	_tk = {"t": t, "s": 0, "k": 0, "pop": 0}


## Advances the tick job: one unit when budget_ms <= 0, else units until budget_ms is spent. Stops
## early when the sim queued nested work (an incident resolved). True when the tick's work is done.
func pump_tick(budget_ms: float) -> bool:
	var t0 := Time.get_ticks_usec()
	while true:
		if _tick_unit(RES_PER_UNIT):
			return true
		if budget_ms <= 0.0 or sim.job_yield_requested() or Time.get_ticks_usec() - t0 >= int(budget_ms * 1000.0):
			return false
	return false


func _tick_unit(n: int) -> bool:
	if _tk.is_empty():
		return true
	var t := int(_tk["t"])
	match int(_tk["s"]):
		0:
			if not is_active():
				_tk = {}
				return true
			if not _pop_scan(_tk, n):
				return false
			share = float(int(_tk["pop"])) / float(maxi(people.size(), 1))
			match t:
				0:
					protests = [0, 0, 0, 0, 0]
					_tk["load"] = {}
					_tk["list"] = people
				1, 2:
					_tk["list"] = people
				3:
					_tk["list"] = people.duplicate()
				_:
					_tk["list"] = []
			_tk["pc"] = {}
			_tk["s"] = 1
		1:
			var list: Array = _tk["list"]
			var k := int(_tk["k"])
			var c := 0
			while k < list.size() and c < n:
				var r: Dictionary = list[k]
				k += 1
				c += 1
				match t:
					0:
						_morning_one(r, _tk["load"])
					1:
						_midday_one(r)
					2:
						_evening_one(r, _tk["pc"])
					3:
						_night_one(r)
				if sim.job_yield_requested() or sim.step_heavy():
					break
			_tk["k"] = k
			if k >= list.size():
				_tk["s"] = 2
				_tk["k"] = 0
		2:
			var k := int(_tk["k"])
			var c := 0
			while k < people.size() and c < n:
				var r: Dictionary = people[k]
				k += 1
				c += 1
				_helpers_one(r)
				if sim.job_yield_requested() or sim.step_heavy():
					break
			_tk["k"] = k
			if k >= people.size():
				_tk = {}
				_trips_dirty = true
				return true
	return false


## Drops the sliced tick and day jobs (the sim replaced the city).
func abort_jobs() -> void:
	_tk = {}
	_dj = {}


func _morning_one(r: Dictionary, site_load: Dictionary) -> void:
	r["worked"] = false
	r["spent"] = 0
	r["site"] = -1
	if int(r["helping"]) >= 0:
		return
	if _join_site(r, site_load):
		return
	var p: Dictionary = r.get("plan", {})
	var w := int(r["work"])
	var mode := str(p.get("commute", "car"))
	if w >= 0 and _as_bool(p.get("go_to_work", true)) and mode != "stay_home":
		if not _workplace_open(w):
			_remember(r, "my workplace at (%d,%d) was closed when I got there" % [D.tx(w), D.ty(w)])
			_go(r, int(r["home"]), "home")
			return
		if _go(r, w, "work"):
			r["worked"] = true
		else:
			_remember(r, "could not get to work, every road was blocked")
	else:
		_go(r, int(r["home"]), "home")


func _midday_one(r: Dictionary) -> void:
	var title := str(r["job_title"])
	var tax := int(sim.mayors[sim.district[int(r["home"])]]["tax_r"])
	if bool(r["worked"]) and (int(r["work"]) >= 0 or int(r["site"]) >= 0):
		if int(r["site"]) < 0 and not _workplace_open(int(r["work"])):
			r["worked"] = false
			_remember(r, "sent home early, my workplace lost power or was shut")
			if int(r["helping"]) < 0:
				_go(r, int(r["home"]), "home")
			return
		var wage := float(r["wage"])
		r["savings"] = float(r["savings"]) + wage * (1.0 - float(tax) / 100.0)
		(_money[sim.district[int(r["home"])]] as Dictionary)["wages"] = float(_money[sim.district[int(r["home"])]]["wages"]) + wage * share * WAGE_SCALE
	elif title == "retiree":
		r["savings"] = float(r["savings"]) + 85.0
	elif title == "student":
		r["savings"] = float(r["savings"]) + 25.0
	elif int(r["work"]) < 0:
		r["savings"] = float(r["savings"]) + 40.0


## pc caches tile lookups for this phase (kinds and levels do not change during the evening loop).
func _evening_one(r: Dictionary, pc: Dictionary) -> void:
	var p: Dictionary = r.get("plan", {})
	var spend := int(p.get("spend", 30))
	var where := str(p.get("spend_where", "local"))
	var shop := _shop_for(r, pc)
	if spend > 0 and where != "none":
		spend = mini(spend, maxi(0, int(float(r["savings"]))) + 20)
		r["savings"] = float(r["savings"]) - float(spend)
		r["spent"] = spend
		if shop >= 0 and where != "online":
			(_money[sim.district[shop]] as Dictionary)["sales"] = float(_money[sim.district[shop]]["sales"]) + float(spend) * share * SALES_SCALE
	r["site"] = -1
	if int(r["helping"]) >= 0:
		return
	var ev_choice := str(p.get("evening", "home"))
	match ev_choice:
		"shopping":
			if shop >= 0:
				_go(r, shop, "shopping")
		"park":
			_go_kind(r, D.PARK, "at the park", pc)
		"stadium":
			if not _go_kind(r, D.STADIUM, "at the stadium", pc):
				_go_kind(r, D.PARK, "at the park", pc)
		"visit_friend":
			if people.size() > 1:
				var f: Dictionary = people[_rng.randi_range(0, people.size() - 1)]
				if f != r:
					_go(r, int(f["home"]), "visiting %s" % str(f["name"]).split(" ")[0])
		"help_neighbors":
			var ev := _nearest_event(int(r["home"]), 10)
			if not ev.is_empty():
				_start_help(r, ev)
				_remember(r, "went to help with the %s near home" % ev["label"])
		"protest":
			var hall := _nearest_kind(int(r["home"]), D.HALL, 64, pc)
			if hall >= 0:
				_go(r, hall, "protesting at city hall")
				protests[sim.district[int(r["home"])]] = int(protests[sim.district[int(r["home"])]]) + 1
		"work_overtime":
			if bool(r["worked"]) and _workplace_open(int(r["work"])):
				r["savings"] = float(r["savings"]) + float(r["wage"]) * 0.35
				r["state"] = "working late"
		_:
			_go(r, int(r["home"]), "home")


func _night_one(r: Dictionary) -> void:
	var rent := rent_for(r)
	r["savings"] = float(r["savings"]) - float(rent + LIVING_COST)
	if float(r["savings"]) < 0.0:
		r["broke_days"] = int(r["broke_days"]) + 1
	else:
		r["broke_days"] = 0
	if str(r["intent"]) == "leaving":
		_depart(r, str(r.get("mood_reason", "decided to move away")))
		return
	if int(r["broke_days"]) >= 3:
		_depart(r, "could no longer afford rent")
		return
	if int(r["helping"]) < 0:
		_go(r, int(r["home"]), "home")


func rent_for(r: Dictionary) -> int:
	var h := int(r["home"])
	return int(round(20.0 + sim.land_value[h] * 80.0 + float(sim.level[h]) * 8.0))


## One resident is a fraction of a contractor crew (CREW_RATE per tick), but a few local
## builders working the morning and midday shifts roughly double a site's pace.
func build_amount(r: Dictionary) -> float:
	var amount := 1.5
	if str(r["job_title"]) in ["construction worker", "civil engineer"]:
		amount = 2.5
	var traits: Array = r["traits"]
	if traits.has("hardworking"):
		amount *= 1.3
	elif traits.has("lazy"):
		amount *= 0.7
	if int(r["age"]) > 60:
		amount *= 0.7
	return amount


## People with construction skills spend their working day on the nearest open site, which
## pays them a day rate instead of their usual job.
func _join_site(r: Dictionary, load: Dictionary) -> bool:
	if not (r["skills"] as Array).has("construction") or sim.sites.is_empty():
		return false
	var p: Dictionary = r.get("plan", {})
	if not _as_bool(p.get("go_to_work", true)) or str(p.get("commute", "car")) == "stay_home":
		return false
	var home := int(r["home"])
	var best: Dictionary = {}
	var best_score := INF
	for s: Dictionary in sim.sites.values():
		var d := absi(int(s["x"]) - D.tx(home)) + absi(int(s["y"]) - D.ty(home))
		if d > 14:
			continue
		var score := float(d) + 3.0 * float(load.get(int(s["i"]), 0))
		if str(s["type"]) == "build":
			score -= 5.0
		elif str(s["type"]) == "road":
			score += 2.0
		if score < best_score:
			best_score = score
			best = s
	if best.is_empty():
		return false
	var si := int(best["i"])
	load[si] = int(load.get(si, 0)) + 1
	r["site"] = si
	r["worked"] = true
	if int(r.get("last_site", -1)) != int(best["id"]):
		r["last_site"] = int(best["id"])
		_remember(r, "joined the crew building the %s at (%d,%d)" % [str(best["label"]).to_lower(), int(best["x"]), int(best["y"])])
	_go(r, si, "building the %s" % str(best["label"]).to_lower())
	return true


func _on_site_finished(s: Dictionary) -> void:
	var notable := str(s["type"]) == "build" or str(s["plan"]) == "zone_tower"
	var crew: Dictionary = s["crew"]
	for r in people:
		if notable and crew.has("%s (%s)" % [r["name"], r["job_title"]]):
			_remember(r, "helped build the %s at (%d,%d), it is open now" % [str(s["label"]).to_lower(), int(s["x"]), int(s["y"])])
		if int(r.get("site", -1)) == int(s["i"]):
			r["site"] = -1
			_go(r, int(r["home"]), "home")
	_trips_dirty = true


## One resident's shift on a site and at an incident (after the day's routine, every tick). An
## incident it resolves queues the sim's recompute; nothing after that here reads the maps.
func _helpers_one(r: Dictionary) -> void:
	var si := int(r.get("site", -1))
	if si >= 0:
		if not sim.sites.has(si):
			r["site"] = -1
		else:
			sim.add_site_work(si, build_amount(r), "%s (%s)" % [r["name"], r["job_title"]])
	var eid := int(r["helping"])
	if eid < 0:
		return
	var ev := sim.find_event(eid)
	if ev.is_empty():
		_stop_help(r)
		return
	if int(r["help_eta"]) > 0:
		r["help_eta"] = int(r["help_eta"]) - 1
		return
	r["help_ticks"] = int(r["help_ticks"]) + 1
	var amount := help_amount(r, ev)
	var label := "%s (%s)" % [r["name"], r["job_title"]]
	sim.add_incident_work(eid, amount, label)
	if int(r["helping"]) >= 0 and int(r["help_ticks"]) >= 8:
		_remember(r, "spent hours at the %s and had to go home, it is still not fixed" % ev["label"])
		_stop_help(r)


func help_amount(r: Dictionary, ev: Dictionary) -> float:
	var amount := 4.0
	for s: Variant in r["skills"]:
		if (ev.get("skills", []) as Array).has(str(s)):
			amount = 15.0
			break
	var traits: Array = r["traits"]
	if traits.has("hardworking") or traits.has("brave"):
		amount *= 1.3
	if int(r["age"]) > 70:
		amount *= 0.5
	return amount


func _start_help(r: Dictionary, ev: Dictionary) -> void:
	var t := D.idx(int(ev["x"]), int(ev["y"]))
	var from := int(r["at"])
	var dist := absi(D.tx(from) - D.tx(t)) + absi(D.ty(from) - D.ty(t))
	r["helping"] = int(ev["id"])
	r["help_eta"] = dist / 10
	r["help_ticks"] = 0
	ev["reports"] = int(ev.get("reports", 0)) + 1
	_go(r, t, "helping at the %s" % ev["label"])


func _stop_help(r: Dictionary) -> void:
	r["helping"] = -1
	r["help_eta"] = 0
	r["help_ticks"] = 0
	_go(r, int(r["home"]), "home")


func _on_event_ended(ev: Dictionary) -> void:
	for r in people:
		if int(r["helping"]) == int(ev["id"]):
			_remember(r, "helped fix the %s at (%d,%d)" % [ev["label"], int(ev["x"]), int(ev["y"])])
			_stop_help(r)
	_trips_dirty = true


func _nearest_event(tile: int, max_d: int) -> Dictionary:
	var best: Dictionary = {}
	var bd := max_d + 1
	for ev in sim.events:
		var d := absi(int(ev["x"]) - D.tx(tile)) + absi(int(ev["y"]) - D.ty(tile))
		if d < bd:
			bd = d
			best = ev
	return best


# ---------------------------------------------------------------- decisions from the minds

## Models sometimes answer a number field with null, a word or "7/10"; float() would crash on those.
func _num(v: Variant, fallback: float) -> float:
	match typeof(v):
		TYPE_INT, TYPE_FLOAT:
			return float(v)
		TYPE_STRING:
			var s := str(v).strip_edges().get_slice("/", 0)
			return s.to_float() if s.is_valid_float() else fallback
	return fallback


func apply_plan(r: Dictionary, d: Dictionary, source: String, model: String) -> void:
	var p := {
		"go_to_work": _as_bool(d.get("go_to_work", true)),
		"commute": _pick(str(d.get("commute", "car")).replace("train", "bus").replace("none", "stay_home"), COMMUTES, "car"),
		"spend": clampi(int(_num(d.get("spend"), 30.0)), 0, 400),
		"spend_where": _pick(str(d.get("spend_where", "local")).replace("local_shops", "local"), SPEND_WHERE, "local"),
		"evening": _pick(str(d.get("evening", "home")).replace("volunteer", "help_neighbors").replace("visit_friends", "visit_friend"), EVENINGS, "home"),
	}
	r["plan"] = p
	_set_mood(r, d.get("mood", r["mood"]))
	r["mood_reason"] = D.debrand(str(d.get("mood_reason", ""))).left(100)
	r["intent"] = _pick(str(d.get("intent", "stay")), INTENTS, "stay")
	r["recommend"] = clampf(_num(d.get("recommend"), float(r["recommend"])), 0.0, 10.0)
	r["approve"] = clampf(_num(d.get("approve_mayor"), float(r["approve"])), 0.0, 10.0)
	r["complaint"] = _pick(str(d.get("complaint", "none")).to_lower(), COMPLAINTS, "none")
	r["thought"] = D.debrand(str(d.get("thought", ""))).left(220)
	r["say"] = D.debrand(str(d.get("say", ""))).left(90)
	if not str(r["say"]).strip_edges().is_empty():
		resident_said.emit(str(r["id"]), str(r["say"]), "say")
	r["source"] = source
	r["model"] = model
	r["plan_day"] = sim.day
	var msg := D.debrand(str(d.get("message_to_mayor", ""))).strip_edges().left(180)
	r["message"] = msg
	if not msg.is_empty() and msg.to_lower() not in ["none", "n/a", "-"]:
		_post_message(r, msg, "daily")
	if not str(r["thought"]).is_empty():
		_remember(r, str(r["thought"]).left(110))
	if str(r["intent"]) == "leaving":
		sim._log("%s (%s) has decided to move out of GridFall: \"%s\"" % [r["name"], r["job_title"], r["mood_reason"]], "people")
	_trips_dirty = true


func respond(r: Dictionary, ev: Dictionary, d: Dictionary, source: String, model: String) -> String:
	var action := _pick(str(d.get("action", "ignore")).to_lower(), ACTIONS, "ignore")
	if d.has("mood"):
		_set_mood(r, d["mood"])
	var th := D.debrand(str(d.get("thought", ""))).left(200)
	if not th.is_empty():
		r["thought"] = th
	r["say"] = D.debrand(str(d.get("say", ""))).left(90)
	if not str(r["say"]).strip_edges().is_empty():
		resident_said.emit(str(r["id"]), str(r["say"]), "react")
	r["reaction"] = action
	r["reaction_thought"] = th
	r["reaction_event"] = ev["label"]
	r["source"] = source
	if not model.is_empty():
		r["model"] = model
	var where := "the %s at (%d,%d)" % [ev["label"], int(ev["x"]), int(ev["y"])]
	match action:
		"help":
			if int(r["helping"]) < 0 and sim.events.has(ev):
				_start_help(r, ev)
				_remember(r, "rushed to help with " + where)
		"report":
			ev["reports"] = int(ev.get("reports", 0)) + 1
			_remember(r, "called in " + where)
		"evacuate":
			var safe := _nearest_kind(int(r["home"]), D.PARK, 30, {})
			if safe < 0:
				safe = _nearest_kind(int(r["home"]), D.HALL, 64, {})
			if safe >= 0 and int(r["helping"]) < 0:
				_go(r, safe, "sheltering away from the %s" % ev["label"])
			_remember(r, "got away from " + where)
		"avoid":
			_remember(r, "stayed clear of " + where)
	var msg := D.debrand(str(d.get("message_to_mayor", ""))).strip_edges().left(180)
	if not msg.is_empty() and msg.to_lower() not in ["none", "n/a", "-"]:
		_post_message(r, msg, "incident")
	return action


func _post_message(r: Dictionary, text: String, kind: String) -> void:
	messages.append({
		"id": r["id"], "name": r["name"], "job": r["job_title"], "mood": int(round(float(r["mood"]))),
		"district": sim.district[int(r["home"])], "day": sim.day, "text": text, "kind": kind,
	})
	if messages.size() > 300:
		messages.pop_front()
	resident_said.emit(str(r["id"]), text, "letter")


func _set_mood(r: Dictionary, v: Variant) -> void:
	var m := float(v) if typeof(v) in [TYPE_INT, TYPE_FLOAT] else str(v).to_float()
	if m > 10.0:
		m /= 10.0
	r["mood"] = clampf(m, 0.0, 10.0)


func _remember(r: Dictionary, line: String) -> void:
	var mem: Array = r["memory"]
	if not mem.is_empty() and str(mem[-1]).ends_with(": " + line):
		return
	mem.append("Day %d: %s" % [sim.day, line])
	while mem.size() > 8:
		mem.pop_front()


# ---------------------------------------------------------------- arrivals, homes, jobs

func _spawn(day: int) -> Dictionary:
	var home := _pick_home()
	if home < 0:
		return {}
	var occ := _pick_occupation()
	var spec: Dictionary = OCCUPATIONS[occ]
	_seq += 1
	# Identity comes from its own seed so resident #N is the same person in every run of this city,
	# which lets cached minds replay for the right people.
	var idr := RandomNumberGenerator.new()
	idr.seed = sim.city_seed * 7919 + _seq
	var age := idr.randi_range(23, 62)
	if occ == "student":
		age = idr.randi_range(17, 24)
	elif occ == "retiree":
		age = idr.randi_range(66, 86)
	var t1: String = TRAITS[idr.randi_range(0, TRAITS.size() - 1)]
	var t2: String = TRAITS[idr.randi_range(0, TRAITS.size() - 1)]
	var traits: Array = [t1] if t1 == t2 else [t1, t2]
	var r := {
		"id": "r%d" % _seq, "name": _unique_name(idr), "age": age, "job_title": occ, "skills": (spec["skills"] as Array).duplicate(),
		"traits": traits, "household": HOUSEHOLDS[idr.randi_range(0, HOUSEHOLDS.size() - 1)],
		"home": home, "work": -1, "wage": int(round(float(spec["wage"]) * idr.randf_range(0.85, 1.2))),
		"savings": float(idr.randi_range(150, 2600)), "mood": 6.5, "mood_reason": "just moved in",
		"memory": [], "plan": {}, "intent": "stay", "recommend": 6.0, "approve": 5.0, "complaint": "none",
		"message": "", "thought": "", "say": "", "reaction": "", "state": "home", "at": home,
		"helping": -1, "help_eta": 0, "help_ticks": 0, "source": "", "model": "", "arrived": day,
		"broke_days": 0, "worked": false, "spent": 0, "plan_day": 0, "site": -1, "last_site": -1,
	}
	people.append(r)
	_find_job(r)
	_remember(r, "moved to GridFall, into a home at (%d,%d) in %s's district%s" % [D.tx(home), D.ty(home), sim.mayors[sim.district[home]]["name"], "" if int(r["work"]) >= 0 or occ in ["retiree", "student"] else ", still looking for work"])
	sim._log("%s, a %d-year-old %s, moved to GridFall." % [r["name"], age, occ], "people")
	resident_arrived.emit(r)
	return r


func _unique_name(idr: RandomNumberGenerator) -> String:
	for _a in range(40):
		var nm := "%s %s" % [FIRST_NAMES[idr.randi_range(0, FIRST_NAMES.size() - 1)], LAST_NAMES[idr.randi_range(0, LAST_NAMES.size() - 1)]]
		var taken := false
		for r in people:
			if str(r["name"]) == nm:
				taken = true
				break
		if not taken:
			return nm
	return "Resident %d" % _seq


func _pick_home() -> int:
	# Residents per home counted once (was one pass over everyone per candidate home).
	var at: Dictionary = {}
	for r in people:
		var h := int(r["home"])
		at[h] = int(at.get(h, 0)) + 1
	var best := -1
	var best_score := INF
	for i in sim.active:
		if sim.kind[i] != D.ZONE_R or sim.level[i] <= 0 or sim.burning[i] > 0:
			continue
		var score := float(int(at.get(i, 0))) / float(sim.tile_pop(i)) + _rng.randf() * 0.01
		if score < best_score:
			best_score = score
			best = i
	sim.note_units(sim.active.size() / CitySim.UNIT_WORK)
	return best


## Workplace tiles (tile_jobs > 0) in `active` order. Cached for the day-start job, where jobs do
## not change; computed fresh elsewhere.
func _job_tiles() -> PackedInt32Array:
	if not _dj.is_empty() and _dj.has("jt"):
		return _dj["jt"]
	var out := PackedInt32Array()
	for i in sim.active:
		if sim.tile_jobs(i) > 0:
			out.append(i)
	sim.note_units(sim.active.size() / CitySim.UNIT_WORK)
	if not _dj.is_empty() and int(_dj["s"]) >= 2:
		_dj["jt"] = out
	return out


func _pick_occupation() -> String:
	var cap: Dictionary = {}
	for i in _job_tiles():
		var s := _slots(i)
		if s > 0.0:
			cap[sim.kind[i]] = float(cap.get(sim.kind[i], 0.0)) + s
	var filled: Dictionary = {}
	for r in people:
		var w := int(r["work"])
		if w >= 0:
			filled[sim.kind[w]] = int(filled.get(sim.kind[w], 0)) + 1
	var roll := _rng.randf()
	if roll < 0.07:
		return "retiree"
	if roll < 0.12 and (cap.has(D.SCHOOL) or cap.has(D.UNIVERSITY)):
		return "student"
	var weights: Dictionary = {}
	var total := 0.0
	for occ: String in OCCUPATIONS.keys():
		if occ in ["retiree", "student"]:
			continue
		var at: Array = OCCUPATIONS[occ]["at"]
		var free := 0.0
		for k: Variant in at:
			free += maxf(0.0, float(cap.get(int(k), 0.0)) - float(filled.get(int(k), 0)))
		# Generic shop and factory jobs are split across many occupations; services are specific.
		var w := free / float(at.size())
		if w > 0.0:
			weights[occ] = w
			total += w
	if total <= 0.0:
		return "retiree" if _rng.randf() < 0.3 else ["cashier", "factory worker", "construction worker"][_rng.randi_range(0, 2)]
	var pick := _rng.randf() * total
	for occ: String in weights.keys():
		pick -= float(weights[occ])
		if pick <= 0.0:
			return occ
	return weights.keys()[0]


func _find_job(r: Dictionary) -> void:
	var at: Array = OCCUPATIONS.get(str(r["job_title"]), {}).get("at", [])
	if at.is_empty():
		r["work"] = -1
		return
	var load: Dictionary = {}
	for o in people:
		if o != r and int(o["work"]) >= 0:
			load[int(o["work"])] = int(load.get(int(o["work"]), 0)) + 1
	var home := int(r["home"])
	var best := -1
	var best_score := INF
	# Only workplaces can match (_slots is 0 elsewhere), visited in the same order as `active`.
	for i in _job_tiles():
		if not at.has(sim.kind[i]):
			continue
		var s := _slots(i)
		if s <= 0.0 or sim.burning[i] > 0:
			continue
		var fill := float(load.get(i, 0)) / s
		var dist := float(absi(D.tx(i) - D.tx(home)) + absi(D.ty(i) - D.ty(home)))
		var score := fill * 10.0 + dist * 0.15 + _rng.randf() * 0.5
		if fill >= 1.0:
			score += 50.0
		if score < best_score:
			best_score = score
			best = i
	r["work"] = best


func _slots(i: int) -> float:
	var jobs := float(sim.tile_jobs(i))
	if jobs <= 0.0:
		return 0.0
	var s := jobs / maxf(share, 1.0)
	return maxf(s, 1.0) if not D.is_zone(sim.kind[i]) else maxf(s, 0.5)


func _check_home(r: Dictionary, day: int) -> void:
	var h := int(r["home"])
	if h >= 0 and h < sim.kind.size() and sim.kind[h] == D.ZONE_R and sim.level[h] > 0:
		return
	var nh := _pick_home()
	if nh < 0:
		_depart(r, "lost their home and found nowhere else to live")
		return
	r["home"] = nh
	r["at"] = nh
	r["mood"] = maxf(0.0, float(r["mood"]) - 1.5)
	_remember(r, "my building at (%d,%d) is gone, so I moved to (%d,%d)" % [D.tx(h), D.ty(h), D.tx(nh), D.ty(nh)])


func _check_job(r: Dictionary, _day: int) -> void:
	var w := int(r["work"])
	if w >= 0 and sim.tile_jobs(w) > 0 and (OCCUPATIONS[str(r["job_title"])]["at"] as Array).has(sim.kind[w]):
		return
	var had := w >= 0
	_find_job(r)
	if had and int(r["work"]) < 0:
		_remember(r, "lost my job when my workplace closed")
	elif had:
		_remember(r, "my old workplace closed, started a new job at (%d,%d)" % [D.tx(int(r["work"])), D.ty(int(r["work"]))])
	elif int(r["work"]) >= 0:
		_remember(r, "finally found a job at (%d,%d)" % [D.tx(int(r["work"])), D.ty(int(r["work"]))])


func _depart(r: Dictionary, reason: String) -> void:
	if not people.has(r):
		return
	people.erase(r)
	sim.resident_left(int(r["home"]))
	var rec := r.duplicate(true)
	rec["left_day"] = sim.day
	rec["left_reason"] = reason
	departed.append(rec)
	if departed.size() > 40:
		departed.pop_front()
	sim._log("%s (%s) moved out of GridFall: %s." % [r["name"], r["job_title"], reason], "people")
	_trips_dirty = true
	resident_departed.emit(rec, reason)


# ---------------------------------------------------------------- movement on the road network

func _workplace_open(i: int) -> bool:
	return i >= 0 and sim.tile_jobs(i) > 0 and sim.powered[i] == 1 and sim.burning[i] == 0 and not sim.disabled_until.has(i)


## pc caches tile lookups across calls that see the same kinds and levels ({} for none).
func _shop_for(r: Dictionary, pc: Dictionary) -> int:
	var p: Dictionary = r.get("plan", {})
	var where := str(p.get("spend_where", "local"))
	if where == "downtown":
		if not pc.has("downtown"):
			var best := -1
			var bl := -1
			for i in sim.active:
				if sim.kind[i] == D.ZONE_C and sim.level[i] > bl and sim.district[i] == 2:
					bl = sim.level[i]
					best = i
			sim.note_units(sim.active.size() / CitySim.UNIT_WORK)
			pc["downtown"] = best
		if int(pc["downtown"]) >= 0:
			return int(pc["downtown"])
	if where == "none":
		return -1
	return _nearest_dev(int(r["home"]), D.ZONE_C, 12, pc)


## Tiles of kind k in `active` order (developed ones only when dev), cached in pc.
func _kind_tiles(k: int, dev: bool, pc: Dictionary) -> PackedInt32Array:
	var key := "%s%d" % ["dev" if dev else "kind", k]
	if pc.has(key):
		return pc[key]
	var out := PackedInt32Array()
	for i in sim.active:
		if sim.kind[i] == k and (not dev or sim.level[i] > 0):
			out.append(i)
	sim.note_units(sim.active.size() / CitySim.UNIT_WORK)
	pc[key] = out
	return out


func _nearest_dev(from: int, k: int, max_d: int, pc: Dictionary) -> int:
	var best := -1
	var bd := max_d + 1
	for i in _kind_tiles(k, true, pc):
		var d := absi(D.tx(i) - D.tx(from)) + absi(D.ty(i) - D.ty(from))
		if d < bd:
			bd = d
			best = i
	return best


func _nearest_kind(from: int, k: int, max_d: int, pc: Dictionary) -> int:
	var best := -1
	var bd := max_d + 1
	for i in _kind_tiles(k, false, pc):
		var d := absi(D.tx(i) - D.tx(from)) + absi(D.ty(i) - D.ty(from))
		if d < bd:
			bd = d
			best = i
	return best


func _go_kind(r: Dictionary, k: int, state: String, pc: Dictionary) -> bool:
	var t := _nearest_kind(int(r["home"]), k, 40, pc)
	if t < 0:
		return false
	return _go(r, t, state)


## Sends a resident from where they are to tile `to` along roads; the view animates the route.
func _go(r: Dictionary, to: int, state: String) -> bool:
	var from := int(r["at"])
	var route := route_between(from, to)
	if route.is_empty() and from != to:
		return false
	r["route"] = route
	r["at"] = to
	r["state"] = state
	var p: Dictionary = r.get("plan", {})
	r["mode"] = str(p.get("commute", "car")) if state == "work" else ("walk" if route.size() <= 6 else str(p.get("commute", "car")))
	if from != to:
		trip_started.emit(str(r["id"]), from, to, _trip_mode(str(r["mode"])))
	resident_moved.emit(r)
	return true


## The trip_started mode for a commute value: car, bus, bike or walk (anything else walks).
func _trip_mode(m: String) -> String:
	return m if m in ["car", "bus", "bike", "walk"] else "walk"


func route_between(a: int, b: int) -> Array:
	if a == b:
		return []
	var ra := _near_road(a)
	var rb := _near_road(b)
	if ra < 0 or rb < 0:
		return []
	var parent := _bfs(ra)
	if parent[rb] == -2:
		return []
	var tiles: Array = []
	var c := rb
	var guard := 0
	while c >= 0 and guard < 400:
		tiles.append(Vector2i(D.tx(c), D.ty(c)))
		c = parent[c]
		guard += 1
	tiles.reverse()
	tiles.push_front(Vector2i(D.tx(a), D.ty(a)))
	tiles.append(Vector2i(D.tx(b), D.ty(b)))
	return tiles


func _near_road(i: int) -> int:
	if i < 0:
		return -1
	var x := D.tx(i)
	var y := D.ty(i)
	for d in range(0, 4):
		for dy in range(-d, d + 1):
			for dx in range(-d, d + 1):
				if absi(dx) + absi(dy) != d:
					continue
				var nx := x + dx
				var ny := y + dy
				if D.in_bounds(nx, ny):
					var ni := D.idx(nx, ny)
					if sim.kind[ni] == D.ROAD and not _blocked.has(ni):
						return ni
	return -1


## Road parents from src (-1 at src, -2 unreachable). Cached per origin; callers must not modify it.
func _bfs(src: int) -> PackedInt32Array:
	var sig := Vector2i(sim.road_epoch, _blocked_epoch)
	if sig != _bfs_sig:
		_bfs_cache.clear()
		_bfs_sig = sig
	if _bfs_cache.has(src):
		return _bfs_cache[src]
	var parent := _bfs_search(src)
	if _bfs_cache.size() >= BFS_CACHE_MAX:
		_bfs_cache.erase(_bfs_cache.keys()[0])
	_bfs_cache[src] = parent
	sim.note_units(1)
	return parent


func _bfs_search(src: int) -> PackedInt32Array:
	var parent := PackedInt32Array()
	parent.resize(D.W * D.H)
	parent.fill(-2)
	if src < 0:
		return parent
	parent[src] = -1
	var q := PackedInt32Array([src])
	var head := 0
	while head < q.size():
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
			if parent[ni] != -2 or sim.kind[ni] != D.ROAD or _blocked.has(ni):
				continue
			parent[ni] = c
			q.append(ni)
	return parent


# ---------------------------------------------------------------- what a mind gets to see

func card(r: Dictionary) -> Dictionary:
	var h := int(r["home"])
	var d := sim.district[h]
	var m: Dictionary = sim.mayors[d]
	var near: Array = []
	for pair: Array in [["park", sim.cov_park], ["school", sim.cov_school], ["hospital", sim.cov_health], ["police", sim.cov_police], ["fire station", sim.cov_fire], ["transit", sim.cov_transit], ["stadium/university", sim.cov_leisure]]:
		if (pair[1] as PackedFloat32Array)[h] > 0.2:
			near.append(pair[0])
	var work: Variant = "retired" if str(r["job_title"]) == "retiree" else "unemployed, looking for work"
	var w := int(r["work"])
	if w >= 0:
		var route := route_between(h, w)
		var jam := 0.0
		var jsum := 0.0
		for t: Variant in route:
			var v: Vector2i = t
			jam = maxf(jam, sim.traffic[D.idx(v.x, v.y)])
			jsum += sim.traffic[D.idx(v.x, v.y)]
		var wk := str(D.KIND_NAMES[sim.kind[w]]).replace("_", " ")
		if D.is_zone(sim.kind[w]):
			wk = {D.ZONE_C: "shops/offices", D.ZONE_I: "factory"}.get(sim.kind[w], wk)
		work = {
			"place": "%s at (%d,%d)" % [wk, D.tx(w), D.ty(w)], "tiles_away": absi(D.tx(w) - D.tx(h)) + absi(D.ty(w) - D.ty(h)),
			"open": _workplace_open(w), "worst_traffic_on_route": snappedf(jam, 0.01), "avg_traffic_on_route": snappedf(jsum / float(maxi(route.size(), 1)), 0.01), "reachable_by_road": not route.is_empty(),
		}
	var incidents: Array = []
	for ev in sim.events:
		var dist := absi(int(ev["x"]) - D.tx(h)) + absi(int(ev["y"]) - D.ty(h))
		if dist <= 10:
			incidents.append("%s at (%d,%d), %d tiles from home, %d%% repaired, needs %s" % [ev["label"], int(ev["x"]), int(ev["y"]), dist, int(100.0 * float(ev["progress"]) / maxf(1.0, float(ev["work"]))), ", ".join(PackedStringArray((ev["skills"] as Array).map(func(s: Variant) -> String: return str(D.SKILL_LABELS.get(str(s), s)))))])
	var building: Array = []
	for s: Dictionary in sim.sites.values():
		if str(s["type"]) != "road" and building.size() < 3 and absi(int(s["x"]) - D.tx(h)) + absi(int(s["y"]) - D.ty(h)) <= 8:
			building.append("%s at (%d,%d), %s, %d%% done" % [s["label"], int(s["x"]), int(s["y"]), D.STAGE_LABELS.get(sim.site_stage_name(s), ""), int(round(sim.site_fraction(s) * 100.0))])
	var skills: Array = (r["skills"] as Array).map(func(s: Variant) -> String: return str(D.SKILL_LABELS.get(str(s), s)))
	return {
		"id": r["id"], "name": r["name"], "age": r["age"], "job": r["job_title"], "skills": skills, "traits": r["traits"],
		"household": r["household"], "days_in_city": sim.day - int(r["arrived"]),
		"money": {"savings": int(float(r["savings"])), "daily_wage": int(r["wage"]), "daily_rent": rent_for(r), "income_tax_pct": int(m["tax_r"])},
		"home": {
			"x": D.tx(h), "y": D.ty(h), "mayor": m["name"], "building_density": sim.level[h],
			"power": sim.powered[h] == 1, "water": sim.watered[h] == 1, "pollution": snappedf(sim.pollution[h], 0.01),
			"crime": snappedf(sim.crime[h], 0.01), "land_value": snappedf(sim.land_value[h], 0.01), "nearby": near,
		},
		"work": work,
		"yesterday": {"mood": int(round(float(r["mood"]))), "intent": r["intent"], "evening": (r.get("plan", {}) as Dictionary).get("evening", "home"), "spent": int(r["spent"])},
		"memory": (r["memory"] as Array).slice(-4),
		"incidents_nearby": incidents,
		"construction_nearby": building,
	}


# ---------------------------------------------------------------- save / load

func to_dict() -> Dictionary:
	var out: Array = []
	for r in people:
		var c := r.duplicate(true)
		c.erase("route")
		out.append(c)
	return {"people": out, "seq": _seq, "departed": departed.duplicate(true), "messages": messages.duplicate(true), "enabled": enabled}


func from_dict(d: Dictionary) -> void:
	people.clear()
	for v: Variant in d.get("people", []):
		var r: Dictionary = v
		for k in ["home", "work", "at", "age", "helping", "help_eta", "help_ticks", "broke_days", "arrived", "spent", "plan_day", "wage", "site", "last_site"]:
			r[k] = int(r.get(k, -1 if k in ["work", "helping", "site", "last_site"] else 0))
		if sim != null:
			for k in ["home", "work", "at", "site", "last_site"]:
				r[k] = sim.remap_index(int(r[k]))
		r["route"] = []
		people.append(r)
	departed.clear()
	for v: Variant in d.get("departed", []):
		departed.append(v as Dictionary)
	messages.clear()
	for v: Variant in d.get("messages", []):
		messages.append(v as Dictionary)
	_seq = int(d.get("seq", people.size()))
	enabled = bool(d.get("enabled", true))
	abort_jobs()
	_bfs_cache.clear()
	_trips_dirty = true
	rebuild_maps()


# ---------------------------------------------------------------- helpers

static func _pick(v: String, options: Array, fallback: String) -> String:
	var s := v.strip_edges().to_lower()
	if options.has(s):
		return s
	for o: Variant in options:
		if s.begins_with(str(o)):
			return str(o)
	return fallback


static func _as_bool(v: Variant) -> bool:
	if typeof(v) == TYPE_STRING:
		return str(v).to_lower() in ["true", "yes", "1"]
	return bool(v)
