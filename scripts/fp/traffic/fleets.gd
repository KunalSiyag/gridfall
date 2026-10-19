extends RefCounted
## City fleets on lanes in first person (docs/fp/slices/E-traffic.md §5): buses on 2-4 seeded
## closed lines through the bus stops (they pull in at each shelter, people board and alight),
## delivery and garbage trucks, and emergency crews that run to incidents with sirens (through red
## lights at walking pace once the box is clear), wait at the scene, and drive back to the station.
## CityLife asks for vehicles through spawn_fleet / dispatch_crew; drivers are residents with the
## matching job when one is free, else "city crew".

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const DWELL := 9.0
const MAX_CREWS := 10
const CURB_LAT := 0.055
const JOBS := {"bus": "bus driver", "truck": "truck driver", "garbage_truck": "sanitation worker",
	"firetruck": "firefighter", "ambulance": "paramedic", "police": "police officer"}


## A closed bus line: stops (tiles) in order, the lane beside each shelter and the legs between.
class Line extends RefCounted:
	var id: int = 0
	var stops: Array[int] = []
	var stop_lanes: Array = []
	var stop_s: Array[float] = []
	var legs: Array = []              # legs[k]: lanes after stop k's lane up to stop k+1's lane
	var length: float = 0.0


var f: Object
var sim: CitySim
var lg: LG
var vh: VH
var lines: Array = []
var stop_sides: Dictionary = {}       # tile -> side index of its shelter
## Why the last dispatch_crew call sent nobody ("" when it sent a crew); for tests and logs.
var last_dispatch_fail: String = ""
var _sig: String = ""
var _rng := RandomNumberGenerator.new()


func setup(p_f: Object, p_sim: CitySim, p_lg: LG, p_vh: VH) -> void:
	f = p_f
	sim = p_sim
	lg = p_lg
	vh = p_vh


## Shelter side of every bus stop (G1 may store it as a Vector2i; else inferred like CityView).
func read_stops(view: CityView) -> Dictionary:
	var out := {}
	if view == null:
		return out
	for key: Variant in view.bus_stops.keys():
		var i := int(key)
		if not lg.parkable(i):
			continue
		var v: Variant = view.bus_stops[key]
		var dv := Vector2i.ZERO
		if typeof(v) == TYPE_VECTOR2I:
			dv = v
		else:
			dv = _infer_side(i)
		if dv == Vector2i.ZERO:
			continue
		var rd := lg.run_dir(i)
		out[i] = 0 if Vector2(-rd.y, rd.x).dot(Vector2(dv)) > 0.0 else 1
	return out


func _infer_side(i: int) -> Vector2i:
	var x := D.tx(i)
	var y := D.ty(i)
	var m := RoadTopology.mask(sim, x, y)
	var sides := [Vector2i(1, 0), Vector2i(-1, 0)] if m == RoadTopology.NS else [Vector2i(0, 1), Vector2i(0, -1)]
	for dv: Vector2i in sides:
		if not D.in_bounds(x + dv.x, y + dv.y):
			continue
		var j := D.idx(x + dv.x, y + dv.y)
		if (sim.kind[j] == D.ZONE_R or sim.kind[j] == D.ZONE_C) and sim.level[j] > 0:
			return dv
	return sides[0]


## Signature of the stop set (lines rebuild when it changes).
func stops_signature(view: CityView) -> String:
	if view == null:
		return ""
	var keys: Array = view.bus_stops.keys()
	keys.sort()
	return str(keys)


## Rebuilds the seeded lines from the current stops. Returns the number of lines.
func rebuild_lines(view: CityView) -> int:
	_sig = stops_signature(view)
	stop_sides = read_stops(view)
	lg.stop_sides = stop_sides
	lines.clear()
	var stops: Array[int] = []
	for i: int in stop_sides.keys():
		stops.append(i)
	stops.sort()
	if stops.size() < 2:
		return 0
	_rng.seed = sim.city_seed * 4099 + stops.size()
	var n := clampi(1 + stops.size() / 3, 2, 4)
	for li in range(n):
		var pool := stops.duplicate()
		_shuffle(pool)
		var k := clampi(_rng.randi_range(2, 5), 2, pool.size())
		var pick: Array[int] = []
		for j in range(k):
			pick.append(pool[j])
		var line := _make_line(li, pick, li % 2 == 1)
		if line != null:
			lines.append(line)
	return lines.size()


func _shuffle(a: Array[int]) -> void:
	for k in range(a.size() - 1, 0, -1):
		var j := _rng.randi_range(0, k)
		var t := a[k]
		a[k] = a[j]
		a[j] = t


func _make_line(id: int, pick: Array[int], ccw: bool) -> Line:
	var c := Vector2.ZERO
	for i: int in pick:
		c += Vector2(D.tx(i), D.ty(i))
	c /= float(pick.size())
	pick.sort_custom(func(a: int, b: int) -> bool:
		var aa := (Vector2(D.tx(a), D.ty(a)) - c).angle()
		var bb := (Vector2(D.tx(b), D.ty(b)) - c).angle()
		return aa < bb if not ccw else aa > bb)
	var line := Line.new()
	line.id = id
	for i: int in pick:
		var rd := lg.run_dir(i)
		var side: int = stop_sides.get(i, 0)
		var h := rd if side == 0 else -rd
		var l := vh._lane_heading(i, h)
		if l == null:
			continue
		line.stops.append(i)
		line.stop_lanes.append(l)
		line.stop_s.append(clampf(lg.project(l, Vector2(D.tx(i), D.ty(i))) + 0.3, 0.3, l.length))
	if line.stops.size() < 2:
		return null
	for k in range(line.stops.size()):
		var a: LG.Lane = line.stop_lanes[k]
		var b: LG.Lane = line.stop_lanes[(k + 1) % line.stops.size()]
		var leg := lg.astar(a, {b.id: true}, 6000)
		if leg.is_empty():
			return null
		line.legs.append(leg)
		for l: LG.Lane in leg:
			line.length += l.length
	return line


## [line id, board tile, alight tile] for a trip along road tiles seq to dest, or [].
func bus_choice(seq: Array[int], dest: int) -> Array:
	if lines.is_empty() or dest < 0:
		return []
	for i: int in seq:
		for line: Line in lines:
			if not line.stops.has(i):
				continue
			var best := -1
			var bd := 4
			for s: int in line.stops:
				if s == i:
					continue
				var d := absi(D.tx(s) - D.tx(dest)) + absi(D.ty(s) - D.ty(dest))
				if d < bd:
					bd = d
					best = s
			if best >= 0:
				return [line.id, i, best]
	return []


func line(id: int) -> Line:
	for l: Line in lines:
		if l.id == id:
			return l
	return null


# ------------------------------------------------------------------ requests from CityLife

func count(role: String) -> int:
	var n := 0
	for c: VH.Car in vh.cars:
		if c.role == role:
			n += 1
	return n


## Fleet size for CityLife's census (kind as CityLife names it).
func fleet_size(kind: String) -> int:
	match kind:
		"bus":
			return count("bus")
		"garbage_truck":
			return count("garbage")
		"truck":
			return count("truck")
	return 0


## Adds one vehicle of a fleet (CityLife.external.spawn_fleet).
func spawn_fleet(kind: String, start: Vector2i) -> void:
	if kind == "bus":
		_spawn_bus()
		return
	var role := "garbage" if kind == "garbage_truck" else "truck"
	var m: int = f.vehicle_model(kind)
	if m < 0:
		return
	var l: LG.Lane = null
	var s := 0.0
	var spot: Array = f.spawn_spot_near(start, f.dims(m).z)
	if spot.is_empty():
		return
	l = spot[0]
	s = spot[1]
	var c := vh.make("truck", role, f.dims(m))
	c.model = m
	c.speed_f *= 0.92
	_name_driver(c, kind)
	vh.place(c, l, s)
	c.v = l.limit * 0.6


func _spawn_bus() -> void:
	if lines.is_empty():
		return
	var best: Line = null
	var bn := 99
	for line: Line in lines:
		var n := 0
		for c: VH.Car in vh.cars:
			if c.role == "bus" and c.owner is Dictionary and int((c.owner as Dictionary).get("line", -1)) == line.id:
				n += 1
		var cap := 1 if line.length < 14.0 else 2
		if n < cap and n < bn:
			bn = n
			best = line
	if best == null:
		return
	var m: int = f.vehicle_model("bus")
	if m < 0:
		return
	# Start at the stop farthest from the player's view.
	var order: Array[int] = []
	for k in range(best.stops.size()):
		order.append(k)
	order.sort_custom(func(a: int, b: int) -> bool:
		return f.player_dist(best.stop_lanes[a].pts[0]) > f.player_dist(best.stop_lanes[b].pts[0]))
	for k: int in order:
		var l: LG.Lane = best.stop_lanes[k]
		var s: float = best.stop_s[k]
		var p := lg.pos_at(l, s)
		if f.on_screen(Vector3(p.x, 0.05, p.y)):
			continue
		var c := vh.make("bus", "bus", f.dims(m))
		c.model = m
		c.v0 = WS.BUS_SPEED
		c.speed_f = 1.0
		_name_driver(c, "bus")
		c.owner = {"line": best.id, "stop": k, "dwell": 0.0}
		if f.is_far(Vector3(p.x, 0, p.y)) or not vh.fits(l, s, c.length):
			c.lane = l
			c.s = s
			c.far = true
		else:
			vh.place(c, l, s)
		_next_leg(c, best, k)
		return


func _next_leg(c: VH.Car, line: Line, k: int) -> void:
	var nk := (k + 1) % line.stops.size()
	c.path = (line.legs[k] as Array).duplicate()
	c.goal_lane = line.stop_lanes[nk]
	c.goal_s = line.stop_s[nk]
	c.arrived = false
	c.state = "line %d to %s" % [line.id + 1, f.street_label(line.stops[nk])]
	c.dest_label = f.street_label(line.stops[nk])
	(c.owner as Dictionary)["stop"] = k
	(c.owner as Dictionary)["next"] = nk


## Sends a crew (CityLife.external.dispatch_crew).
func dispatch_crew(kind: String, station: Vector2i, target: Vector2i) -> void:
	last_dispatch_fail = ""
	if count("crew") >= MAX_CREWS:
		last_dispatch_fail = "cap"
		return
	if not D.in_bounds(station.x, station.y) or not D.in_bounds(target.x, target.y):
		last_dispatch_fail = "bounds %s %s" % [str(station), str(target)]
		return
	var m: int = f.vehicle_model(kind)
	if m < 0:
		last_dispatch_fail = "model " + kind
		return
	var start := _lane_on(D.idx(station.x, station.y))
	if start == null:
		last_dispatch_fail = "no lane at station %s" % str(station)
		return
	var goals := _goals_at(D.idx(target.x, target.y))
	if goals.is_empty():
		last_dispatch_fail = "no lane at target %s" % str(target)
		return
	var path := lg.astar(start, goals, 8000, true)
	if path.is_empty() and not goals.has(start.id):
		last_dispatch_fail = "no route %s -> %s (blocked %s)" % [str(station), str(target), str(lg.blocked.keys())]
		return
	var c := vh.make("emergency", "crew", f.dims(m))
	c.model = m
	c.v0 = WS.EMERGENCY_SPEED
	c.speed_f = 1.0
	c.siren = kind != "truck"
	_name_driver(c, kind)
	c.owner = {"kind": kind, "event_id": _event_at(target), "phase": "to_scene", "home": start.id, "t": 0.0}
	var s := clampf(start.length * 0.5 + c.length * 0.5, c.length, start.length)
	if f.is_far(Vector3(D.tx(start.tile), 0, D.ty(start.tile))) or not vh.fits(start, s, c.length):
		c.lane = start
		c.s = s
		c.far = true
	else:
		vh.place(c, start, s)
	c.path = path
	var last: LG.Lane = path[path.size() - 1] if not path.is_empty() else start
	c.goal_lane = last
	c.goal_s = clampf(last.length * 0.5 + c.length * 0.5, c.length * 0.5, last.length)
	c.state = "responding"
	c.dest_label = f.street_label(D.idx(target.x, target.y))


func _event_at(target: Vector2i) -> int:
	var best := -1
	var bd := 1 << 30
	for ev: Dictionary in sim.events:
		var d := absi(int(ev.get("x", 0)) - target.x) + absi(int(ev.get("y", 0)) - target.y)
		if d < bd:
			bd = d
			best = int(ev.get("id", -1))
	return best


## A non-junction lane on road tile i (or a neighbour), or null.
func _lane_on(i: int) -> LG.Lane:
	var ts: Array[int] = [i]
	ts.append_array(lg.neighbours(i))
	for ti: int in ts:
		var t: LG.TileInfo = lg.info(ti)
		if t == null:
			continue
		for l: LG.Lane in t.lanes:
			if l.kind == LG.STRAIGHT or l.kind == LG.CORNER or l.kind == LG.UTURN:
				return l
	return null


func _goals_at(i: int) -> Dictionary:
	var goals := {}
	var ts: Array[int] = [i]
	ts.append_array(lg.neighbours(i))
	for ti: int in ts:
		var t: LG.TileInfo = lg.info(ti)
		if t == null:
			continue
		for l: LG.Lane in t.lanes:
			if l.kind == LG.STRAIGHT or l.kind == LG.CORNER:
				goals[l.id] = true
		if not goals.is_empty():
			break
	return goals


func _name_driver(c: VH.Car, kind: String) -> void:
	var job := str(JOBS.get(kind, ""))
	var rid: String = f.free_worker(job) if not job.is_empty() else ""
	if rid.is_empty():
		c.label = "city crew"
		c.driver_id = ""
		return
	c.driver_id = rid
	var r: Dictionary = f.ctx.residents.find(rid)
	c.label = "%s, %s" % [str(r.get("name", "")), job]


# ------------------------------------------------------------------ stepping

func step(dt: float) -> void:
	var live := {}
	for ev: Dictionary in sim.events:
		live[int(ev.get("id", -1))] = true
	for c: VH.Car in vh.cars.duplicate():
		if c.dead:
			continue
		if c.role == "bus":
			_step_bus(c, dt)
		elif c.role == "crew":
			_step_crew(c, dt, live)
		if c.lat_off != _lat_target(c):
			c.lat_off = move_toward(c.lat_off, _lat_target(c), dt * 0.6 * WS.M)


func _lat_target(c: VH.Car) -> float:
	if c.role == "bus" and c.arrived:
		return CURB_LAT
	if c.role == "crew" and c.owner is Dictionary and str((c.owner as Dictionary).get("phase", "")) == "at_scene":
		return CURB_LAT
	return 0.0


func _step_bus(c: VH.Car, dt: float) -> void:
	var o: Dictionary = c.owner if c.owner is Dictionary else {}
	var line := line(int(o.get("line", -1)))
	if line == null:
		if not f.on_screen(c.pos):
			vh.remove(c)
		return
	if not c.arrived:
		return
	var dw := float(o.get("dwell", 0.0))
	if dw == 0.0:
		f.bus_at(c, line.id, line.stops[int(o.get("next", 0))])
	dw += dt
	o["dwell"] = dw
	if dw >= DWELL:
		o["dwell"] = 0.0
		_next_leg(c, line, int(o.get("next", 0)))


func _step_crew(c: VH.Car, dt: float, live: Dictionary) -> void:
	var o: Dictionary = c.owner if c.owner is Dictionary else {}
	o["t"] = float(o.get("t", 0.0)) + dt
	var phase := str(o.get("phase", ""))
	var ev_live := live.has(int(o.get("event_id", -1)))
	match phase:
		"to_scene":
			if not ev_live and float(o["t"]) > 5.0:
				_go_home(c, o)
			elif c.arrived:
				o["phase"] = "at_scene"
				c.state = "at the scene"
		"at_scene":
			if not ev_live:
				_go_home(c, o)
		"leaving":
			if (c.arrived or float(o["t"]) > 240.0) and not f.on_screen(c.pos):
				vh.remove(c)


func _go_home(c: VH.Car, o: Dictionary) -> void:
	o["phase"] = "leaving"
	o["t"] = 0.0
	c.siren = false
	c.state = "returning to the station"
	var home: LG.Lane = lg.lanes[int(o.get("home", -1))] if int(o.get("home", -1)) >= 0 and int(o.get("home", -1)) < lg.lanes.size() else null
	if c.lane == null or home == null:
		c.goal_lane = null
		c.role = "ambient"
		c.label = "a commuter"
		return
	var path := lg.astar(c.lane, {home.id: true}, 8000, true)
	c.path = path
	c.goal_lane = home if not path.is_empty() else null
	c.goal_s = home.length * 0.5
	c.arrived = false
	if path.is_empty():
		c.role = "ambient"
