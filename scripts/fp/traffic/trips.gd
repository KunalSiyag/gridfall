extends RefCounted
## Resident trips (docs/fp/slices/E-traffic.md §4): the AI link. Residents.trip_started arrives
## when a mind's plan sends someone somewhere; the sim counts them there at once, and this plays
## the trip out at real speed behind it. car: walk from the door to their own parked car, drive the
## sim's route lane by lane, pull into a curb slot at the destination, walk to the door. walk:
## sidewalks and zebras door to door. bus: walk to a stop on the route, wait for a line that serves
## the destination, ride, walk. bike: a cyclist at the carriageway edge. Residents outdoors at
## their destination stand there in small groups. Beyond the traffic radius a trip is data only.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const SW := preload("res://scripts/fp/traffic/sidewalks.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const INSIDE := ["home", "work", "shopping", "working late"]
const BUS_WAIT := 90.0
const JITTER := 6.0
const BIKE_SPEED := 4.0 * WS.M
const HEAD := 1.62 * WS.M
const SEATED_HEAD := 1.2 * WS.M


## One trip in flight.
class Trip extends RefCounted:
	var rid: String = ""
	var mode: String = "walk"
	var from_i: int = -1
	var to_i: int = -1
	var state: String = ""           # the resident's state on arrival (r.state)
	var phase: String = "delay"      # delay | to_car | pullout | drive | parking | to_door | walk | to_stop | wait_bus | ride | done
	var delay: float = 0.0
	var t: float = 0.0
	var seq: Array[int] = []         # road tiles of the sim route
	var dest_tile: int = -1          # road tile the destination lot fronts
	var car: VH.Car = null
	var walker: WK.Walker = null
	var bus: VH.Car = null
	var line: int = -1
	var board_tile: int = -1
	var alight_tile: int = -1
	var slot := Vector2i(-1, -1)


var f: Object                        # the traffic feature (helpers: models, doors, visibility)
var sim: CitySim
var people: Residents
var lg: LG
var sw: SW
var vh: VH
var wk: WK
var trips: Dictionary = {}           # rid -> Trip
var cars: Dictionary = {}            # rid -> Car (their own; parked between trips)
var standing: Dictionary = {}        # rid -> Walker standing outdoors
var held: Dictionary = {}            # rid -> true while in a conversation
var jitter_enabled: bool = true


func setup(p_f: Object, p_sim: CitySim, p_people: Residents, p_lg: LG, p_sw: SW, p_vh: VH, p_wk: WK) -> void:
	f = p_f
	sim = p_sim
	people = p_people
	lg = p_lg
	sw = p_sw
	vh = p_vh
	wk = p_wk


## Drops every trip, walker and car (a new world); parked positions come back from `parked`.
func reset() -> void:
	trips.clear()
	cars.clear()
	standing.clear()
	held.clear()


static func inside_state(state: String) -> bool:
	return state in INSIDE or state.begins_with("visiting")


func _short_day() -> bool:
	return sim.day_seconds < WS.FP_DAY_SECONDS


## Departure delay, real seconds at 1x, seeded by (id, day).
func jitter(rid: String) -> float:
	if not jitter_enabled:
		return 0.0
	return float(absi(hash("%s:%d" % [rid, sim.day])) % 6000) / 1000.0 * (JITTER / 6.0)


# ------------------------------------------------------------------ signals

func on_trip_started(rid: String, from_i: int, to_i: int, mode: String) -> void:
	if _short_day():
		_move_car_data(rid, to_i, mode)
		return
	if trips.has(rid):
		complete_now(trips[rid])
	var tr := Trip.new()
	tr.rid = rid
	tr.mode = mode
	tr.from_i = from_i
	tr.to_i = to_i
	var r := people.find(rid)
	tr.state = str(r.get("state", "")) if not r.is_empty() else ""
	tr.delay = jitter(rid)
	trips[rid] = tr
	if tr.delay <= 0.0:
		_begin(tr)


## A resident moved without a trip (state only): keeps standing residents in sync.
func on_moved(r: Dictionary) -> void:
	var rid := str(r.get("id", ""))
	if trips.has(rid):
		(trips[rid] as Trip).state = str(r.get("state", ""))
		return
	if inside_state(str(r.get("state", ""))):
		_unstand(rid)


func on_departed(r: Dictionary) -> void:
	var rid := str(r.get("id", ""))
	if trips.has(rid):
		complete_now(trips[rid])
	_unstand(rid)
	var c: VH.Car = cars.get(rid, null)
	if c != null:
		cars.erase(rid)
		vh.remove(c)


## Reconciles parked cars with where their owners now live and work (sim.day_started).
func on_day_started() -> void:
	for rid: String in cars.keys():
		var c: VH.Car = cars[rid]
		var r := people.find(rid)
		if r.is_empty():
			if not f.on_screen(c.pos):
				cars.erase(rid)
				vh.remove(c)
			continue
		if not c.parked or trips.has(rid):
			continue
		var ok := false
		for lot: int in [int(r["home"]), int(r.get("work", -1)), int(r["at"])]:
			if lot < 0:
				continue
			var fr: int = f.ctx.directory.frontage(lot)
			if fr >= 0 and c.slot_tile >= 0 and absi(D.tx(fr) - D.tx(c.slot_tile)) + absi(D.ty(fr) - D.ty(c.slot_tile)) <= 2:
				ok = true
		if ok or f.on_screen(c.pos):
			continue
		var at := int(r["at"])
		if not _park_near(c, at, -1):
			cars.erase(rid)
			vh.remove(c)


# ------------------------------------------------------------------ helpers

## The resident's own car, creating it (parked near lot, facing road tile `toward` when given) the
## first time.
func car_of(rid: String, lot: int, toward: int = -1) -> VH.Car:
	var c: VH.Car = cars.get(rid, null)
	if c != null and not c.dead:
		return c
	var m: int = f.car_model_for(rid)
	if m < 0:
		return null
	c = vh.make("car", "resident", f.dims(m))
	c.model = m
	c.driver_id = rid
	cars[rid] = c
	if not _park_near(c, lot, -1, toward):
		c.parked = true
		c.slot_tile = -1
		c.pos = f.door_point(lot)
	return c


## Parks c in a free slot near lot's frontage (facing road tile `toward` first, then the lot's
## side), or near tile `road`. With `toward`, the tiles further along that way are tried before
## the wrong side, and an out-of-sight decor car may give up its slot.
func _park_near(c: VH.Car, lot: int, road: int, toward: int = -1) -> bool:
	var fr: int = road if road >= 0 else (f.ctx.directory.frontage(lot) if lot >= 0 else -1)
	if fr < 0:
		return false
	var cand: Array[int] = [fr]
	if toward >= 0:
		var step := Vector2i(D.tx(toward) - D.tx(fr), D.ty(toward) - D.ty(fr))
		if step != Vector2i.ZERO and absi(step.x) + absi(step.y) == 1:
			for k in range(1, 3):
				var x := D.tx(fr) + step.x * k
				var y := D.ty(fr) + step.y * k
				if D.in_bounds(x, y) and lg.tiles.has(D.idx(x, y)):
					cand.append(D.idx(x, y))
		elif toward != fr:
			cand.append(toward)
	for n: int in lg.neighbours(fr):
		if not cand.has(n):
			cand.append(n)
	var own := "car:%d" % c.id
	for pass_i in range(2 if toward >= 0 else 1):
		for i: int in cand:
			if not lg.parkable(i):
				continue
			var rd := lg.run_dir(i)
			var ks: Array[int] = [0, 1, 2, 3]
			if toward >= 0:
				var go := Vector2(D.tx(toward) - D.tx(i), D.ty(toward) - D.ty(i))
				if go == Vector2.ZERO:
					go = Vector2(D.tx(toward) - D.tx(fr), D.ty(toward) - D.ty(fr))
				var side := 0 if rd.dot(go) >= 0.0 else 1
				# First pass: only the side facing the route; second pass: the other side.
				var sd := side if pass_i == 0 else 1 - side
				ks = [sd * 2, sd * 2 + 1]
			elif lot >= 0:
				var to_lot := Vector2(D.tx(lot) - D.tx(i), D.ty(lot) - D.ty(i))
				var lot_side := 0 if Vector2(-rd.y, rd.x).dot(to_lot) > 0.0 else 1
				ks = [lot_side * 2, lot_side * 2 + 1, (1 - lot_side) * 2, (1 - lot_side) * 2 + 1]
			for k: int in ks:
				if not lg.slot_valid(i, k):
					continue
				var owner := lg.slot_owner(i, k)
				if owner.is_empty() or owner == own or (pass_i == 0 and toward >= 0 and _evict_decor(i, k)):
					vh.park_at(c, i, k)
					return true
	return false


## Removes the decor car in slot (i, k) when it is out of sight. True when the slot is now free.
func _evict_decor(i: int, k: int) -> bool:
	for d: VH.Car in vh.cars:
		if d.parked and d.role == "decor" and d.slot_tile == i and d.slot_k == k:
			if f.on_screen(d.pos):
				return false
			vh.remove(d)
			return lg.slot_free(i, k)
	return false


func _move_car_data(rid: String, to_i: int, mode: String) -> void:
	if mode != "car":
		return
	var c := car_of(rid, to_i)
	if c != null and c.parked:
		if c.slot_tile >= 0:
			lg.set_slot(c.slot_tile, c.slot_k, "")
			c.slot_tile = -1
		if not _park_near(c, to_i, -1):
			c.pos = f.door_point(to_i)


func _person(rid: String, at: Vector3) -> WK.Walker:
	var w: WK.Walker = standing.get(rid, null)
	if w != null and not w.dead:
		standing.erase(rid)
	else:
		w = wk.make("resident")
		w.model = f.person_model_for(rid)
	w.resident_id = rid
	w.role = "resident"
	w.owner = null
	w.pos = at
	w.hold = held.has(rid)
	w.face_player = w.hold
	w.far = f.is_far(at)
	return w


func _unstand(rid: String) -> void:
	var w: WK.Walker = standing.get(rid, null)
	if w != null:
		standing.erase(rid)
		wk.remove(w)


func _road_seq(rid: String) -> Array[int]:
	var out: Array[int] = []
	var r := people.find(rid)
	var route: Array = r.get("route", []) if not r.is_empty() else []
	for k in range(1, route.size() - 1):
		var v: Vector2i = route[k]
		if D.in_bounds(v.x, v.y):
			var i := D.idx(v.x, v.y)
			if lg.tiles.has(i) and (out.is_empty() or out[out.size() - 1] != i):
				out.append(i)
	return out


## Walking plan from world point a (near road tile ta) to b (near tb): a free leg onto the nearest
## sidewalk, the network (zebras included), and a free leg off it. [] when unreachable.
func walk_plan(a: Vector3, ta: int, b: Vector3, tb: int) -> Array:
	var na: Array = sw.nearest_on_tile(Vector2(a.x, a.z), ta)
	var nb: Array = sw.nearest_on_tile(Vector2(b.x, b.z), tb)
	if na.is_empty() or nb.is_empty():
		return []
	var ea: SW.PedEdge = na[0]
	var eb: SW.PedEdge = nb[0]
	var tsa: float = na[1]
	var tsb: float = nb[1]
	var pa := sw.pos_at(ea, tsa)
	var pb := sw.pos_at(eb, tsb)
	var plan: Array = [{"pt": pa}]
	if ea == eb:
		if tsb >= tsa:
			plan.append({"edge": ea.id, "dir": 1, "t0": tsa, "t1": tsb})
		else:
			plan.append({"edge": ea.id, "dir": -1, "t0": ea.length - tsa, "t1": ea.length - tsb})
	else:
		var best: Array = []
		var best_len := INF
		for sa: int in [ea.a, ea.b]:
			for sb: int in [eb.a, eb.b]:
				var r := sw.route(sa, sb)
				if r.is_empty() and sa != sb:
					continue
				var l := _plan_len(r) + (tsa if sa == ea.a else ea.length - tsa) + (tsb if sb == eb.a else eb.length - tsb)
				if l < best_len:
					best_len = l
					best = [sa, sb, r]
		if best.is_empty():
			return []
		var sa2: int = best[0]
		var sb2: int = best[1]
		if sa2 == ea.b:
			plan.append({"edge": ea.id, "dir": 1, "t0": tsa, "t1": -1.0})
		else:
			plan.append({"edge": ea.id, "dir": -1, "t0": ea.length - tsa, "t1": -1.0})
		for st: Array in best[2]:
			plan.append({"edge": int(st[0]), "dir": int(st[1])})
		if sb2 == eb.a:
			plan.append({"edge": eb.id, "dir": 1, "t0": 0.0, "t1": tsb})
		else:
			plan.append({"edge": eb.id, "dir": -1, "t0": 0.0, "t1": eb.length - tsb})
	plan.append({"pt": b})
	return plan


func _plan_len(r: Array) -> float:
	var l := 0.0
	for st: Array in r:
		var e := sw.edge(int(st[0]))
		if e != null:
			l += e.length * (1.6 if e.zebra else 1.0)
	return l


# ------------------------------------------------------------------ trip phases

func _begin(tr: Trip) -> void:
	tr.seq = _road_seq(tr.rid)
	var fr: int = f.ctx.directory.frontage(tr.to_i)
	tr.dest_tile = fr if fr >= 0 and lg.tiles.has(fr) else (tr.seq[tr.seq.size() - 1] if not tr.seq.is_empty() else -1)
	match tr.mode:
		"car":
			_begin_car(tr)
		"bus":
			_begin_bus(tr)
		"bike":
			_begin_bike(tr)
		_:
			_begin_walk(tr)


func _begin_walk(tr: Trip) -> void:
	tr.mode = "walk"
	var a: Vector3 = f.door_point(tr.from_i)
	var b: Vector3 = f.door_point(tr.to_i)
	var ta: int = _front_or_seq(tr.from_i, tr, true)
	var w := _person(tr.rid, a)
	tr.walker = w
	w.owner = tr
	var plan := walk_plan(a, ta, b, tr.dest_tile) if ta >= 0 and tr.dest_tile >= 0 else []
	if plan.is_empty():
		plan = [{"pt": b}]
	tr.phase = "walk"
	wk.start_plan(w, plan)


func _front_or_seq(lot: int, tr: Trip, first: bool) -> int:
	var fr: int = f.ctx.directory.frontage(lot)
	if fr >= 0 and lg.tiles.has(fr):
		return fr
	if tr.seq.is_empty():
		return -1
	return tr.seq[0] if first else tr.seq[tr.seq.size() - 1]


func _begin_car(tr: Trip) -> void:
	var toward := -1
	var fr: int = f.ctx.directory.frontage(tr.from_i)
	var k := tr.seq.find(fr)
	if k >= 0 and k + 1 < tr.seq.size():
		toward = tr.seq[k + 1]
	elif tr.seq.size() >= 1 and fr >= 0 and tr.seq[0] != fr:
		toward = tr.seq[0]
	var c := car_of(tr.rid, tr.from_i, toward)
	if c == null:
		_begin_walk(tr)
		return
	tr.car = c
	c.owner = tr
	c.driver_id = tr.rid
	c.state = "leaving"
	c.dest_label = f.place_label(tr.to_i)
	var door: Vector3 = f.door_point(tr.from_i)
	if f.is_far(door) or f.is_far(c.pos):
		tr.phase = "pullout"
		return
	var w := _person(tr.rid, door)
	tr.walker = w
	w.owner = tr
	tr.phase = "to_car"
	var curb := _curb_beside(c)
	var plan: Array = []
	var ta: int = _front_or_seq(tr.from_i, tr, true)
	if c.slot_tile >= 0 and ta >= 0 and not _same_side(tr.from_i, c):
		plan = walk_plan(door, ta, curb, c.slot_tile)
	if plan.is_empty():
		plan = [{"pt": curb}]
	wk.start_plan(w, plan)


## Sidewalk point at the car's curb side.
func _curb_beside(c: VH.Car) -> Vector3:
	var right := Vector3(-cos(c.yaw), 0, sin(c.yaw))
	var p := c.pos + right * (c.half_w + 0.75 * WS.M)
	p.y = WS.SIDEWALK_TOP
	return p


## True when lot is on the car's curb side of the street.
func _same_side(lot: int, c: VH.Car) -> bool:
	var right := Vector3(-cos(c.yaw), 0, sin(c.yaw))
	var d := Vector3(D.tx(lot), 0, D.ty(lot)) - c.pos
	return right.dot(d) > 0.0


func _begin_bike(tr: Trip) -> void:
	tr.phase = "pullout"
	var m: int = f.bike_model()
	var c := vh.make("bike", "resident", Vector3(0.6 * WS.M, 1.8 * WS.M, 1.8 * WS.M))
	c.model = m
	c.v0 = BIKE_SPEED
	c.driver_id = tr.rid
	c.owner = tr
	c.dest_label = f.place_label(tr.to_i)
	c.state = "cycling"
	c.parked = true
	c.pos = f.door_point(tr.from_i)
	tr.car = c


func _begin_bus(tr: Trip) -> void:
	var pick: Array = f.bus_choice(tr.seq, tr.dest_tile)
	if pick.is_empty():
		_begin_walk(tr)
		return
	tr.line = pick[0]
	tr.board_tile = pick[1]
	tr.alight_tile = pick[2]
	var a: Vector3 = f.door_point(tr.from_i)
	var stop: Vector3 = f.stop_point(tr.board_tile)
	var w := _person(tr.rid, a)
	tr.walker = w
	w.owner = tr
	var ta: int = _front_or_seq(tr.from_i, tr, true)
	var plan := walk_plan(a, ta, stop, tr.board_tile) if ta >= 0 else []
	if plan.is_empty():
		plan = [{"pt": stop}]
	tr.phase = "to_stop"
	wk.start_plan(w, plan)


## Per-step trip logic (dt: game-scaled seconds).
func step(dt: float) -> void:
	for tr: Trip in trips.values():
		tr.t += dt
		match tr.phase:
			"delay":
				tr.delay -= dt
				if tr.delay <= 0.0:
					_begin(tr)
			"to_car", "walk", "to_door", "to_stop":
				if tr.walker != null and (tr.walker.done or tr.walker.dead):
					_walker_done(tr)
			"pullout":
				_try_pullout(tr)
			"parking":
				if tr.car != null and tr.car.parked:
					_after_park(tr)
			"wait_bus":
				if tr.t > BUS_WAIT:
					_walk_rest(tr, tr.walker.pos if tr.walker != null else f.stop_point(tr.board_tile), tr.board_tile)
			"garage":
				if tr.car != null and not f.on_screen(tr.car.pos):
					_garage(tr)
	for rid: String in trips.keys():
		if (trips[rid] as Trip).phase == "done":
			trips.erase(rid)


func _walker_done(tr: Trip) -> void:
	var w := tr.walker
	match tr.phase:
		"to_car":
			if w != null:
				wk.remove(w)
			tr.walker = null
			tr.phase = "pullout"
			_try_pullout(tr)
		"to_stop":
			tr.phase = "wait_bus"
			tr.t = 0.0
			if w != null:
				w.done = false
				wk.stand(w, w.pos, w.yaw)
		_:
			_arrive_on_foot(tr)


func _try_pullout(tr: Trip) -> void:
	var c := tr.car
	if c == null or c.dead:
		_finish(tr)
		return
	var left := false
	if c.parked and f.is_far(c.pos):
		left = vh.unpark_far(c, _front_or_seq(tr.from_i, tr, true))
	elif c.parked and c.slot_tile >= 0:
		left = vh.unpark(c)
	elif c.parked:
		left = _enter_road(c, _front_or_seq(tr.from_i, tr, true), tr.to_i)
	else:
		left = true
	if not left:
		if tr.t > 25.0 and f.is_far(c.pos):
			complete_now(tr)
		return
	c.state = "driving to %s" % _purpose(tr)
	if not _plan_drive(tr):
		complete_now(tr)
		return
	tr.phase = "drive"
	if f.is_far(c.pos):
		vh.make_far(c)


## Places a car or bike without a slot (garage, driveway) on the lane at road tile `road`.
func _enter_road(c: VH.Car, road: int, toward_lot: int) -> bool:
	var t: LG.TileInfo = lg.info(road) if road >= 0 else null
	if t == null:
		return false
	for l: LG.Lane in t.lanes:
		if l.kind == LG.MOVE:
			continue
		var s := clampf(l.length * 0.5 + c.length * 0.5, c.length, l.length)
		if vh.fits(l, s, c.length):
			vh.place(c, l, s)
			return true
	return false


func _purpose(tr: Trip) -> String:
	var st := tr.state
	if st == "work":
		return "work"
	if st == "home":
		return "home"
	if st == "shopping":
		return "the shops"
	if st.begins_with("at the "):
		return st.substr(7)
	if st.begins_with("visiting "):
		return "visit " + st.substr(9)
	if st.begins_with("protesting"):
		return "city hall"
	if st.begins_with("helping"):
		return "help"
	return f.place_label(tr.to_i)


## Sets the car's lane path from its lane along the sim route to a curb slot at the destination.
func _plan_drive(tr: Trip) -> bool:
	var c := tr.car
	var l0 := c.lane
	if l0 == null:
		return false
	var dest := tr.dest_tile
	if dest < 0:
		return false
	var seq := tr.seq.duplicate()
	if seq.is_empty() or seq[seq.size() - 1] != dest:
		if seq.has(dest):
			seq.resize(seq.find(dest) + 1)
		else:
			seq.append(dest)
	var R := lg.lanes_along(seq)
	var path: Array = []
	var k0 := R.find(l0)
	if k0 >= 0:
		path = R.slice(k0 + 1)
	else:
		var goals := {}
		for k in range(mini(R.size(), 8)):
			goals[(R[k] as LG.Lane).id] = true
		var p := lg.astar(l0, goals, 2500) if not goals.is_empty() else []
		if not p.is_empty():
			var last: LG.Lane = p[p.size() - 1]
			path = p + R.slice(R.find(last) + 1)
	# The goal: a free slot on the right of the arriving lane, at the destination or just before.
	var goal_lane: LG.Lane = null
	var goal_s := -1.0
	tr.slot = Vector2i(-1, -1)
	var lanes_all: Array = [l0]
	lanes_all.append_array(path)
	var cands := _goal_candidates(lanes_all, dest)
	if cands.is_empty():
		# The route never reached the destination tile: go there by A*.
		var goals := {}
		var t: LG.TileInfo = lg.info(dest)
		var tiles: Array[int] = [dest]
		if t != null and t.piece != "straight" and t.piece != "corner" and t.piece != "end":
			tiles.append_array(lg.neighbours(dest))
		for ti: int in tiles:
			var tt: LG.TileInfo = lg.info(ti)
			if tt == null:
				continue
			for l: LG.Lane in tt.lanes:
				if l.kind != LG.MOVE and l.kind != LG.APPROACH:
					goals[l.id] = true
		var p := lg.astar(l0, goals, 3000) if not goals.is_empty() else []
		if p.is_empty():
			return false
		path = p
		lanes_all = [l0]
		lanes_all.append_array(path)
		cands = [lanes_all.size() - 1]
	if c.kind != "bike":
		for idx: int in cands:
			var l: LG.Lane = lanes_all[idx]
			if not lg.parkable(l.tile):
				continue
			var h := lg.tan_at(l, l.length * 0.5)
			for k: int in lg.slots_on_heading(l.tile, h):
				if lg.slot_valid(l.tile, k) and lg.slot_free(l.tile, k):
					tr.slot = Vector2i(l.tile, k)
					var pose := lg.slot_pose(l.tile, k)
					goal_lane = l
					goal_s = clampf(lg.project(l, pose[0]) + c.length * 0.5 + 0.004, c.length, l.length)
					break
			if goal_lane != null:
				break
	if goal_lane == null:
		goal_lane = lanes_all[cands[0]]
		goal_s = clampf(goal_lane.length * 0.5 + c.length * 0.5, c.length * 0.5, goal_lane.length)
	if tr.slot.x >= 0:
		lg.set_slot(tr.slot.x, tr.slot.y, "car:%d" % c.id)
	var gi := lanes_all.find(goal_lane)
	path = lanes_all.slice(1, gi + 1)
	c.path = path
	c.goal_lane = goal_lane
	c.goal_s = goal_s
	c.arrived = false
	return true


## Indices in lanes of the last non-junction lane of the destination tile's visit and of the two
## tiles before it (nearest the destination first); [] when the lanes never reach dest.
func _goal_candidates(lanes: Array, dest: int) -> Array[int]:
	var visits: Array = []
	for k in range(lanes.size()):
		var l: LG.Lane = lanes[k]
		if visits.is_empty() or int((visits[visits.size() - 1] as Array)[0]) != l.tile:
			visits.append([l.tile, -1])
		if l.kind != LG.MOVE and l.kind != LG.APPROACH:
			(visits[visits.size() - 1] as Array)[1] = k
	var di := -1
	for v in range(visits.size() - 1, -1, -1):
		if int((visits[v] as Array)[0]) == dest:
			di = v
			break
	var out: Array[int] = []
	if di < 0:
		return out
	for b in range(3):
		if di - b >= 0 and int((visits[di - b] as Array)[1]) >= 0:
			out.append(int((visits[di - b] as Array)[1]))
	return out


## A vehicle reached its goal (vehicles.on_arrive).
func on_car_arrived(c: VH.Car) -> void:
	var tr: Trip = c.owner if c.owner is Trip else null
	if tr == null or tr.car != c:
		return
	if c.kind == "bike":
		var p := c.pos
		vh.remove(c)
		tr.car = null
		_out_of_car(tr, p, null)
		return
	if c.far:
		# Data only: park straight away.
		if tr.slot.x >= 0:
			vh.park_at(c, tr.slot.x, tr.slot.y)
		else:
			vh.remove(c)
			cars.erase(tr.rid)
		_arrive_far(tr)
		return
	if tr.slot.x >= 0:
		vh.begin_pull_in(c, tr.slot.x, tr.slot.y)
		tr.phase = "parking"
	else:
		c.state = "stopped"
		tr.phase = "garage"
		_out_of_car(tr, c.pos, c)


func _after_park(tr: Trip) -> void:
	var c := tr.car
	c.state = "parked"
	c.owner = null
	_out_of_car(tr, c.pos, c)


## The person steps out beside the car (or bike) and walks to the destination door.
func _out_of_car(tr: Trip, at: Vector3, c: VH.Car) -> void:
	var start := _curb_beside(c) if c != null else Vector3(at.x, WS.SIDEWALK_TOP, at.z)
	var door: Vector3 = f.door_point(tr.to_i)
	var w := _person(tr.rid, start)
	tr.walker = w
	w.owner = tr
	var plan: Array = []
	if c != null and not _same_side(tr.to_i, c) and tr.dest_tile >= 0:
		plan = walk_plan(start, c.lane.tile if c.lane != null else tr.dest_tile, door, tr.dest_tile)
	if plan.is_empty():
		var ft: int = tr.dest_tile
		var band := door
		if ft >= 0:
			var near: Array = sw.nearest_on_tile(Vector2(door.x, door.z), ft)
			if not near.is_empty():
				band = sw.pos_at(near[0], near[1])
		plan = [{"pt": band}, {"pt": door}]
	tr.phase = "to_door"
	wk.start_plan(w, plan)


func _garage(tr: Trip) -> void:
	var c := tr.car
	if c != null:
		vh.remove(c)
		cars.erase(tr.rid)
		tr.car = null
	if tr.walker == null or tr.walker.done:
		_finish(tr)


func _arrive_on_foot(tr: Trip) -> void:
	var w := tr.walker
	tr.walker = null
	if w != null:
		w.owner = null
		if inside_state(tr.state) or w.dead:
			wk.remove(w)
		else:
			w.done = false
			_stand_outdoors(tr.rid, tr.to_i, w)
	if tr.car != null and tr.phase == "garage":
		return
	_finish(tr)


func _arrive_far(tr: Trip) -> void:
	if tr.walker != null:
		wk.remove(tr.walker)
		tr.walker = null
	if not inside_state(tr.state):
		_stand_outdoors(tr.rid, tr.to_i, null)
	_finish(tr)


func _finish(tr: Trip) -> void:
	tr.phase = "done"
	if tr.car != null:
		tr.car.owner = null
		if tr.car.parked:
			tr.car.state = "parked"


## tr goes on on foot from `from` (near road tile `tile`) to its destination, by way of the points
## in via first when there are any.
func _walk_rest(tr: Trip, from: Vector3, tile: int, via: Array = []) -> void:
	tr.mode = "walk"
	var b: Vector3 = f.door_point(tr.to_i)
	var w := tr.walker
	if w == null:
		w = _person(tr.rid, from)
		tr.walker = w
	w.owner = tr
	var a: Vector3 = via.back() if not via.is_empty() else from
	var plan := walk_plan(a, tile, b, tr.dest_tile) if tile >= 0 and tr.dest_tile >= 0 else []
	if plan.is_empty():
		plan = [{"pt": b}]
	var lead: Array = []
	for p: Vector3 in via:
		lead.append({"pt": p})
	tr.phase = "walk"
	wk.start_plan(w, lead + plan)


## The player took tr's car with the resident at the wheel (carjack.gd): it is theirs no more and
## they go on on foot from at by way of via, near road tile `tile`. Returns their walker.
func on_carjacked(tr: Trip, at: Vector3, via: Vector3, tile: int) -> WK.Walker:
	if tr.slot.x >= 0:
		lg.set_slot(tr.slot.x, tr.slot.y, "")
		tr.slot = Vector2i(-1, -1)
	tr.car = null
	cars.erase(tr.rid)
	_walk_rest(tr, at, tile, [via])
	return tr.walker


## Bus hooks (fleets): a bus of `line` stands at stop `tile`.
func on_bus_at(bus: VH.Car, line: int, tile: int) -> void:
	for tr: Trip in trips.values():
		if tr.line != line:
			continue
		if tr.phase == "wait_bus" and tr.board_tile == tile:
			if tr.walker != null:
				wk.remove(tr.walker)
				tr.walker = null
			tr.bus = bus
			tr.phase = "ride"
		elif tr.phase == "ride" and tr.bus == bus and tr.alight_tile == tile:
			tr.bus = null
			_walk_rest(tr, f.stop_point(tile), tile)


## Finishes a trip at once: everyone jumps to the destination (a new trip, a load, a lost road).
func complete_now(tr: Trip) -> void:
	if tr.walker != null:
		wk.remove(tr.walker)
		tr.walker = null
	var c := tr.car
	if c != null and not c.dead:
		if c.kind == "bike":
			vh.remove(c)
		elif not c.parked or c.park_t >= 0.0:
			if tr.slot.x >= 0:
				vh.park_at(c, tr.slot.x, tr.slot.y)
			elif not _park_near(c, tr.to_i, -1):
				vh.remove(c)
				cars.erase(tr.rid)
		elif tr.phase == "delay" or tr.phase == "to_car" or tr.phase == "pullout":
			if c.slot_tile >= 0:
				lg.set_slot(c.slot_tile, c.slot_k, "")
				c.slot_tile = -1
			if not _park_near(c, tr.to_i, -1):
				c.pos = f.door_point(tr.to_i)
		if not c.dead:
			c.owner = null
			c.state = "parked"
	tr.car = null
	if not inside_state(tr.state):
		_stand_outdoors(tr.rid, tr.to_i, null)
	tr.phase = "done"
	trips.erase(tr.rid)


## Puts a resident outdoors at lot (a park, the stadium, city hall, an incident) in a small group.
func _stand_outdoors(rid: String, lot: int, w: WK.Walker) -> void:
	if lot < 0:
		if w != null:
			wk.remove(w)
		return
	var spot: Array = f.outdoor_spot(lot, rid)
	if spot.is_empty():
		if w != null:
			wk.remove(w)
		return
	if w == null:
		w = _person(rid, spot[0])
	w.resident_id = rid
	w.owner = null
	wk.stand(w, spot[0], spot[1])
	standing[rid] = w


## Standing residents for everyone outdoors without a trip (after a rebuild or load).
func seed_standing() -> void:
	for r: Dictionary in people.people:
		var rid := str(r["id"])
		if trips.has(rid) or standing.has(rid):
			continue
		if inside_state(str(r.get("state", "home"))):
			continue
		_stand_outdoors(rid, int(r["at"]), null)


## Conversation: stop the resident's agent and turn it to the player.
func hold(rid: String, on: bool) -> void:
	if on:
		held[rid] = true
	else:
		held.erase(rid)
	var w := walker_of(rid)
	if w != null:
		w.hold = on
		w.face_player = on
	var tr: Trip = trips.get(rid, null)
	if tr != null and tr.car != null and not tr.car.parked:
		tr.car.hold = on


## The walker currently drawing resident rid, or null.
func walker_of(rid: String) -> WK.Walker:
	var tr: Trip = trips.get(rid, null)
	if tr != null and tr.walker != null and not tr.walker.dead:
		return tr.walker
	var w: WK.Walker = standing.get(rid, null)
	return w if w != null and not w.dead else null


## The vehicle resident rid is driving or riding right now, or null.
func vehicle_of(rid: String) -> VH.Car:
	var tr: Trip = trips.get(rid, null)
	if tr == null:
		return null
	if tr.car != null and not tr.car.parked and not tr.car.dead and tr.phase in ["drive", "parking"]:
		return tr.car
	if tr.bus != null and not tr.bus.dead:
		return tr.bus
	return null


## Live position of rid (walker, vehicle), or NAN when not drawn.
func live_position(rid: String) -> Vector3:
	var w := walker_of(rid)
	if w != null:
		return w.pos + w.vis_off
	var c := vehicle_of(rid)
	if c != null:
		return c.pos + c.vis_off
	return Vector3(NAN, NAN, NAN)


## Head anchor of rid while drawn (speech bubble, conversation two-shot), or NAN.
func anchor(rid: String) -> Vector3:
	var w := walker_of(rid)
	if w != null:
		return w.pos + w.vis_off + Vector3(0, HEAD, 0)
	var c := vehicle_of(rid)
	if c != null:
		return c.pos + c.vis_off + Vector3(0, SEATED_HEAD, 0)
	return Vector3(NAN, NAN, NAN)


## Saved parked table: {rid: [tile, slot]}.
func parked_table() -> Dictionary:
	var out := {}
	for rid: String in cars.keys():
		var c: VH.Car = cars[rid]
		if c.parked and c.slot_tile >= 0 and not c.dead:
			out[rid] = [c.slot_tile, c.slot_k]
	return out


## Restores parked cars from a saved table (only for residents who still exist).
func restore_parked(d: Dictionary) -> void:
	for key: Variant in d.keys():
		var rid := str(key)
		var v: Variant = d[key]
		if typeof(v) != TYPE_ARRAY or (v as Array).size() < 2 or people.find(rid).is_empty():
			continue
		var i := int(v[0])
		var k := int(v[1])
		var m: int = f.car_model_for(rid)
		if m < 0:
			continue
		var c: VH.Car = cars.get(rid, null)
		if c == null:
			c = vh.make("car", "resident", f.dims(m))
			c.model = m
			c.driver_id = rid
			cars[rid] = c
		# The saved car's own slot back: the decor car that took it gives way (owned cars keep it).
		if lg.slot_valid(i, k) and (
			lg.slot_free(i, k) or lg.slot_owner(i, k) == "car:%d" % c.id or _evict_decor(i, k)
		):
			vh.park_at(c, i, k)
		else:
			_park_near(c, -1, i)
		c.state = "parked"
