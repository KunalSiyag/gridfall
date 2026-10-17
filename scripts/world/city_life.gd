class_name CityLife
extends Node3D
## Moving city life layered on top of CityView: buses that stop at bus stops, delivery and
## garbage trucks, emergency crews dispatched to live disasters, boats on the river, and
## planes and helicopters. Every model has a procedural stand-in so the layer works without assets.

const D := preload("res://scripts/sim/sim_defs.gd")
const M := "res://models/"
const ROAD_SCALE := 0.17
const DIRS := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
## Which crews answer each disaster type; the first entry is the station kind they leave from.
const RESPONSE := {
	"fire": [["firetruck", D.FIRE], ["firetruck", D.FIRE], ["ambulance", D.HOSPITAL]],
	"tornado": [["firetruck", D.FIRE], ["ambulance", D.HOSPITAL], ["police", D.POLICE]],
	"earthquake": [["firetruck", D.FIRE], ["ambulance", D.HOSPITAL], ["ambulance", D.HOSPITAL]],
	"flood": [["ambulance", D.HOSPITAL], ["police", D.POLICE]],
	"gridlock": [["police", D.POLICE], ["police", D.POLICE]],
	"blackout": [["police", D.POLICE], ["truck", -1]],
	"sewage_burst": [["truck", -1], ["police", D.POLICE]],
	"smog": [["ambulance", D.HOSPITAL]],
}
const SIREN_COLORS := {
	"firetruck": [Color(1.0, 0.15, 0.1), Color(1.0, 0.75, 0.2)],
	"ambulance": [Color(1.0, 0.15, 0.1), Color(0.3, 0.5, 1.0)],
	"police": [Color(0.2, 0.4, 1.0), Color(1.0, 0.1, 0.15)],
	"truck": [Color(1.0, 0.65, 0.1), Color(1.0, 0.65, 0.1)],
}

var sim: CitySim
var view: Node3D
var _last_real: bool = false
var _road_root: Node3D
var _air_root: Node3D
var _water_root: Node3D
var _buses: Array[Dictionary] = []
var _trucks: Array[Dictionary] = []
var _crews: Array[Dictionary] = []
var _boats: Array[Dictionary] = []
var _flyers: Array[Dictionary] = []
var _water_tiles: Array[Vector2i] = []
var _time: float = 0.0
var _census_t: float = 0.0
var _airport_sig: String = ""


func setup(p_sim: CitySim, p_view: Node3D) -> void:
	sim = p_sim
	view = p_view
	for c in get_children():
		c.queue_free()
	_buses.clear()
	_trucks.clear()
	_crews.clear()
	_boats.clear()
	_flyers.clear()
	_airport_sig = ""
	_road_root = _root("RoadVehicles")
	_water_root = _root("Boats")
	_air_root = _root("Aircraft")
	_water_tiles.clear()
	for i in range(D.W * D.H):
		if sim.terrain[i] == D.WATER:
			_water_tiles.append(Vector2i(D.tx(i), D.ty(i)))
	for _b in range(clampi(_water_tiles.size() / 18, 0, 5)):
		_spawn_boat()
	if not sim.event_started.is_connected(_on_event_started):
		sim.event_started.connect(_on_event_started)
	for ev in sim.events:
		_on_event_started(ev)


func _root(n: String) -> Node3D:
	var r := Node3D.new()
	r.name = n
	add_child(r)
	return r


# ------------------------------------------------------------------ models

## The realistic set in models/real/ is tried first for every file; _last_real records which
## set was used because real road vehicles are modelled at tile scale and Kenney ones are not.
func _first_scene(paths: Array) -> PackedScene:
	for full: String in _candidates(paths):
		if ResourceLoader.exists(full):
			var s: PackedScene = view._scene(full)
			if s != null:
				_last_real = full.begins_with(M + "real/")
				return s
	return null


func _candidates(paths: Array) -> Array:
	var out: Array = []
	for p: String in paths:
		out.append(M + "real/" + p)
	for p: String in paths:
		out.append(M + p)
	return out


## Returns a world-scaled vehicle wrapper.
func _vehicle(kind: String) -> Node3D:
	var wrap := Node3D.new()
	var paths := {
		"bus": ["vehicles/bus.glb"],
		"truck": ["vehicles/truck.glb", "cars/van.glb"],
		"garbage_truck": ["vehicles/garbage_truck.glb", "vehicles/truck.glb", "cars/van.glb"],
		"firetruck": ["vehicles/firetruck.glb"],
		"ambulance": ["vehicles/ambulance.glb", "cars/van.glb"],
		"police": ["vehicles/police.glb", "cars/police.glb"],
	}
	var s := _first_scene(paths.get(kind, []))
	if s != null:
		var m := s.instantiate() as Node3D
		m.scale = Vector3.ONE * (1.0 if _last_real else ROAD_SCALE)
		wrap.add_child(m)
	else:
		_proc_vehicle(wrap, kind)
	_road_root.add_child(wrap)
	return wrap


func _proc_vehicle(wrap: Node3D, kind: String) -> void:
	var cols := {"bus": Color(0.98, 0.78, 0.15), "firetruck": Color(0.85, 0.12, 0.1), "ambulance": Color(0.95, 0.95, 0.95),
		"police": Color(0.15, 0.2, 0.45), "truck": Color(0.85, 0.85, 0.8), "garbage_truck": Color(0.2, 0.55, 0.3)}
	var length := 0.62 if kind == "bus" else 0.46
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.2, 0.17, length)
	body.mesh = bm
	body.position.y = 0.11
	body.material_override = view._mat("veh_" + kind, cols.get(kind, Color.GRAY))
	wrap.add_child(body)
	var glass := MeshInstance3D.new()
	var gm := BoxMesh.new()
	gm.size = Vector3(0.205, 0.06, length * 0.9 if kind == "bus" else 0.12)
	glass.mesh = gm
	glass.position = Vector3(0, 0.16, 0.0 if kind == "bus" else length * 0.36)
	glass.material_override = view._mat("veh_glass", Color(0.35, 0.55, 0.75), 0.3)
	wrap.add_child(glass)
	if kind in ["firetruck", "ambulance", "police"]:
		for sx in [-1, 1]:
			var siren := MeshInstance3D.new()
			var sm := BoxMesh.new()
			sm.size = Vector3(0.07, 0.04, 0.05)
			siren.mesh = sm
			siren.name = "Siren%d" % sx
			siren.position = Vector3(0.05 * sx, 0.215, length * 0.2)
			wrap.add_child(siren)


func _find_prefixed(n: Node, prefix: String, out: Array) -> void:
	for c in n.get_children():
		if c is MeshInstance3D and str(c.name).begins_with(prefix):
			out.append(c)
		_find_prefixed(c, prefix, out)


func _attach_sirens(a: Dictionary, kind: String) -> void:
	var node: Node3D = a["node"]
	var sirens: Array = []
	_find_prefixed(node, "Siren", sirens)
	var light := OmniLight3D.new()
	light.omni_range = 1.4
	light.light_energy = 0.0
	light.position = Vector3(0, 0.35, 0)
	node.add_child(light)
	a["sirens"] = sirens
	a["siren_light"] = light
	a["siren_cols"] = SIREN_COLORS.get(kind, [Color.RED, Color.BLUE])


# ------------------------------------------------------------------ road agents

func _roads_near(kind: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for i in range(D.W * D.H):
		if sim.kind[i] != kind:
			continue
		var p := Vector2i(D.tx(i), D.ty(i))
		for dv: Vector2i in DIRS:
			var n := p + dv
			if D.in_bounds(n.x, n.y) and sim.kind[D.idx(n.x, n.y)] == D.ROAD:
				out.append(n)
				break
	return out


func _new_road_agent(kind: String, start: Vector2i, speed: float) -> Dictionary:
	var nbrs: Array[Vector2i] = view._road_neighbors(start)
	if nbrs.is_empty():
		return {}
	var node := _vehicle(kind)
	var a := {"node": node, "kind": kind, "from": start, "to": nbrs[randi() % nbrs.size()], "t": randf(), "speed": speed, "side": 0.13, "dwell": 0.0, "path": []}
	_place(a, 0.0)
	return a


## Moves an agent one step along roads. With a path it follows it; otherwise it wanders.
func _step(a: Dictionary, delta: float, use_traffic: bool) -> bool:
	var from: Vector2i = a["from"]
	var to: Vector2i = a["to"]
	if sim.kind[D.idx(to.x, to.y)] != D.ROAD or sim.kind[D.idx(from.x, from.y)] != D.ROAD:
		return false
	if float(a["dwell"]) > 0.0:
		a["dwell"] = float(a["dwell"]) - delta
		return true
	var spd: float = a["speed"]
	if use_traffic:
		spd *= 1.0 - 0.75 * sim.traffic[D.idx(to.x, to.y)]
	a["t"] = float(a["t"]) + spd * delta
	if float(a["t"]) >= 1.0:
		a["t"] = 0.0
		var path: Array = a["path"]
		var nxt := D.NO_TILE
		if not path.is_empty():
			nxt = path.pop_front()
		else:
			var nbrs: Array[Vector2i] = view._road_neighbors(to)
			if nbrs.size() > 1:
				nbrs.erase(from)
			if nbrs.is_empty():
				return false
			nxt = nbrs[randi() % nbrs.size()]
		a["from"] = to
		a["to"] = nxt
		if a["kind"] == "bus" and view.bus_stops.has(D.idx(to.x, to.y)):
			a["dwell"] = 1.6
	_place(a, delta)
	return true


func _place(a: Dictionary, delta: float) -> void:
	var from: Vector2i = a["from"]
	var to: Vector2i = a["to"]
	var dir := Vector3(to.x - from.x, 0, to.y - from.y)
	var right := Vector3(-dir.z, 0, dir.x)
	var p := Vector3(from.x, 0, from.y).lerp(Vector3(to.x, 0, to.y), float(a["t"])) + right * float(a["side"])
	var node: Node3D = a["node"]
	node.position = Vector3(p.x, 0.05, p.z)
	if dir.length_squared() > 0.0:
		var yaw := atan2(dir.x, dir.z)
		node.rotation.y = yaw if delta <= 0.0 else lerp_angle(node.rotation.y, yaw, minf(1.0, delta * 10.0))


func _bfs(start: Vector2i, goal: Vector2i) -> Array:
	var prev := {start: start}
	var queue: Array[Vector2i] = [start]
	while not queue.is_empty():
		var c: Vector2i = queue.pop_front()
		if c == goal:
			var out: Array = []
			while c != start:
				out.push_front(c)
				c = prev[c]
			return out
		for n: Vector2i in view._road_neighbors(c):
			if not prev.has(n):
				prev[n] = c
				queue.append(n)
	return []


func _nearest_road(x: int, y: int) -> Vector2i:
	var best := D.NO_TILE
	var bd := 1 << 30
	for i in range(D.W * D.H):
		if sim.kind[i] != D.ROAD:
			continue
		var d := absi(D.tx(i) - x) + absi(D.ty(i) - y)
		if d < bd:
			bd = d
			best = Vector2i(D.tx(i), D.ty(i))
	return best


func _count(kind: int, min_level: int = 0) -> int:
	var n := 0
	for i in range(D.W * D.H):
		if sim.kind[i] == kind and sim.level[i] >= min_level:
			n += 1
	return n


func _maintain_fleet(list: Array[Dictionary], kind: String, want: int, starts: Array[Vector2i], speed: float) -> void:
	if list.size() < want and randf() < 0.25:
		var start: Vector2i = starts[randi() % starts.size()] if not starts.is_empty() else view._random_road(-1)
		if start != D.NO_TILE:
			var a := _new_road_agent(kind, start, speed)
			if not a.is_empty():
				list.append(a)
	while list.size() > want:
		var gone: Dictionary = list.pop_back()
		(gone["node"] as Node3D).queue_free()


func _census() -> void:
	var pop := int(sim.stats.get("population", 0))
	var stops: int = view.bus_stops.size()
	var trains := _count(D.TRAIN)
	var want_bus := clampi(stops / 2 + trains * 2, 0, 10) if pop > 150 else 0
	_maintain_fleet(_buses, "bus", want_bus, _roads_near(D.TRAIN), 1.0)
	var ind := _count(D.ZONE_I, 1) + _count(D.ZONE_C, 2)
	var want_truck := clampi(ind / 5, 0, 12)
	var landfills := _roads_near(D.LANDFILL)
	var want_garbage := clampi(landfills.size() * 2 + (1 if pop > 300 else 0), 0, 8)
	var cur_g: Array[Dictionary] = []
	var cur_t: Array[Dictionary] = []
	for t: Dictionary in _trucks:
		if t["kind"] == "garbage_truck":
			cur_g.append(t)
		else:
			cur_t.append(t)
	_maintain_fleet(cur_t, "truck", want_truck, _roads_near(D.ZONE_I), 1.15)
	_maintain_fleet(cur_g, "garbage_truck", want_garbage, landfills, 0.8)
	_trucks.clear()
	_trucks.append_array(cur_t)
	_trucks.append_array(cur_g)
	_sync_aircraft()


# ------------------------------------------------------------------ emergency crews

func _on_event_started(ev: Dictionary) -> void:
	if sim == null or _road_root == null:
		return
	var target := _nearest_road(int(ev["x"]), int(ev["y"]))
	if target == D.NO_TILE:
		return
	var crew: Array = RESPONSE.get(str(ev["type"]), [])
	for slot: Array in crew:
		if _crews.size() >= 10:
			break
		var kind: String = slot[0]
		var station: int = slot[1]
		var starts: Array[Vector2i] = []
		if station >= 0:
			starts = _roads_near(station)
		var start := D.NO_TILE
		var best := 1 << 30
		for s: Vector2i in starts:
			var d := absi(s.x - target.x) + absi(s.y - target.y)
			if d < best:
				best = d
				start = s
		if start == D.NO_TILE:
			start = view._random_road(-1)
		if start == D.NO_TILE:
			continue
		var a := _new_road_agent(kind, start, 2.6)
		if a.is_empty():
			continue
		a["path"] = _bfs(start, target)
		if not (a["path"] as Array).is_empty():
			a["to"] = (a["path"] as Array).pop_front()
		a["t"] = 0.0
		a["event_id"] = int(ev["id"])
		a["target"] = target
		a["side"] = 0.13 if _crews.size() % 2 == 0 else -0.13
		_attach_sirens(a, kind)
		_crews.append(a)


func _event_live(id: int) -> bool:
	for ev in sim.events:
		if int(ev["id"]) == id:
			return true
	return false


func _update_crews(delta: float) -> void:
	var keep: Array[Dictionary] = []
	for a: Dictionary in _crews:
		var live := _event_live(int(a["event_id"]))
		var arrived: bool = (a["path"] as Array).is_empty() and float(a["t"]) >= 0.55 and a["to"] == a["target"]
		var ok := true
		if not live:
			a["life"] = float(a.get("life", 6.0)) - delta
			a["speed"] = 1.2
			ok = float(a["life"]) > 0.0 and _step(a, delta, true)
		elif arrived:
			a["t"] = 0.55
			_place(a, delta)
		else:
			ok = _step(a, delta, false)
		if not ok:
			(a["node"] as Node3D).queue_free()
			continue
		var flash := live and int(_time * 6.0) % 2 == 0
		var cols: Array = a["siren_cols"]
		var light: OmniLight3D = a["siren_light"]
		light.light_energy = 1.4 if live else 0.0
		light.light_color = cols[0] if flash else cols[1]
		var sirens: Array = a["sirens"]
		for j in range(sirens.size()):
			var idx := (j + (1 if flash else 0)) % 2
			(sirens[j] as MeshInstance3D).material_override = view._mat("siren", cols[idx], 4.0 if live else 0.4)
		keep.append(a)
	_crews = keep


# ------------------------------------------------------------------ boats

func _spawn_boat() -> void:
	if _water_tiles.is_empty():
		return
	var opts := ["vehicles/boat_fishing.glb", "vehicles/boat_tug.glb", "vehicles/boat_speed.glb"]
	var s := _first_scene([opts[_boats.size() % opts.size()]] + opts + ["vehicles/boat.glb"])
	var node: Node3D
	if s != null:
		node = s.instantiate() as Node3D
	else:
		node = Node3D.new()
		var hull := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.22, 0.1, 0.5)
		hull.mesh = bm
		hull.position.y = 0.03
		hull.material_override = view._mat("hull", Color(0.9, 0.9, 0.92))
		node.add_child(hull)
		var cabin := MeshInstance3D.new()
		var cm := BoxMesh.new()
		cm.size = Vector3(0.14, 0.1, 0.16)
		cabin.mesh = cm
		cabin.position = Vector3(0, 0.12, -0.06)
		cabin.material_override = view._mat("cabin", Color(0.85, 0.3, 0.2))
		node.add_child(cabin)
	_water_root.add_child(node)
	var start: Vector2i = _water_tiles[randi() % _water_tiles.size()]
	var b := {"node": node, "from": start, "to": start, "t": 1.0, "speed": randf_range(0.25, 0.45), "phase": randf() * TAU}
	_boats.append(b)


func _water_neighbors(p: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dv: Vector2i in DIRS:
		var n := p + dv
		if D.in_bounds(n.x, n.y) and sim.terrain[D.idx(n.x, n.y)] == D.WATER:
			out.append(n)
	return out


func _update_boats(delta: float) -> void:
	for b: Dictionary in _boats:
		b["t"] = float(b["t"]) + float(b["speed"]) * delta
		if float(b["t"]) >= 1.0:
			b["t"] = 0.0
			var cur: Vector2i = b["to"]
			var nbrs := _water_neighbors(cur)
			if nbrs.size() > 1:
				nbrs.erase(b["from"])
			b["from"] = cur
			b["to"] = nbrs[randi() % nbrs.size()] if not nbrs.is_empty() else cur
		var from: Vector2i = b["from"]
		var to: Vector2i = b["to"]
		var node: Node3D = b["node"]
		var p := Vector3(from.x, 0, from.y).lerp(Vector3(to.x, 0, to.y), float(b["t"]))
		node.position = Vector3(p.x, 0.02 + sin(_time * 2.0 + float(b["phase"])) * 0.012, p.z)
		var dir := Vector3(to.x - from.x, 0, to.y - from.y)
		if dir.length_squared() > 0.0:
			node.rotation.y = lerp_angle(node.rotation.y, atan2(dir.x, dir.z), minf(1.0, delta * 2.5))
		node.rotation.z = sin(_time * 1.6 + float(b["phase"])) * 0.05


# ------------------------------------------------------------------ aircraft

func _sync_aircraft() -> void:
	var airports: Array[Vector2i] = []
	var hospitals: Array[Vector2i] = []
	for i in range(D.W * D.H):
		if sim.kind[i] == D.AIRPORT:
			airports.append(Vector2i(D.tx(i), D.ty(i)))
		elif sim.kind[i] == D.HOSPITAL:
			hospitals.append(Vector2i(D.tx(i), D.ty(i)))
	var sig := "%s|%s" % [str(airports.slice(0, 2)), str(hospitals.slice(0, 1))]
	if sig == _airport_sig:
		return
	_airport_sig = sig
	for f: Dictionary in _flyers:
		(f["node"] as Node3D).queue_free()
	_flyers.clear()
	for k in range(airports.size()):
		if k >= 2:
			break
		_spawn_plane(airports[k], float(k) * 0.5)
	if not hospitals.is_empty() and int(sim.stats.get("population", 0)) > 400:
		_spawn_heli(hospitals[0])


func _spawn_plane(ap: Vector2i, phase: float) -> void:
	var s := _first_scene(["vehicles/plane.glb", "vehicles/airplane.glb"])
	var node: Node3D
	if s != null:
		node = s.instantiate() as Node3D
	else:
		node = Node3D.new()
		var fus := MeshInstance3D.new()
		var cm := CapsuleMesh.new()
		cm.radius = 0.09
		cm.height = 0.8
		fus.mesh = cm
		fus.rotation_degrees.x = 90
		fus.material_override = view._mat("plane", Color(0.95, 0.95, 0.97))
		node.add_child(fus)
		var wing := MeshInstance3D.new()
		var wm := BoxMesh.new()
		wm.size = Vector3(0.9, 0.025, 0.18)
		wing.mesh = wm
		wing.material_override = view._mat("plane_wing", Color(0.3, 0.5, 0.9))
		node.add_child(wing)
		var tail := MeshInstance3D.new()
		var tm := BoxMesh.new()
		tm.size = Vector3(0.025, 0.18, 0.12)
		tail.mesh = tm
		tail.position = Vector3(0, 0.1, -0.34)
		tail.material_override = wing.material_override
		node.add_child(tail)
	var blink := OmniLight3D.new()
	blink.light_color = Color(1.0, 0.2, 0.2)
	blink.omni_range = 1.0
	node.add_child(blink)
	_air_root.add_child(node)
	var a := Vector3(ap.x, 0.12, ap.y)
	var c := Vector3(15.5, 0.0, 15.5)
	var curve := Curve3D.new()
	var pts := [a + Vector3(-0.6, 0, 0), a + Vector3(1.5, 0, 0), a + Vector3(5.0, 1.2, 0),
		Vector3(c.x + 20, 5.5, c.z - 12), Vector3(c.x + 4, 6.5, c.z - 22), Vector3(c.x - 20, 6.0, c.z - 10),
		Vector3(c.x - 22, 5.5, c.z + 12), Vector3(c.x, 5.0, c.z + 22), a + Vector3(-9.0, 2.0, 0), a + Vector3(-3.0, 0.4, 0), a + Vector3(-0.6, 0, 0)]
	for p: Vector3 in pts:
		curve.add_point(p)
	for i in range(1, curve.point_count - 1):
		var tangent: Vector3 = (pts[i + 1] - pts[i - 1]) * 0.25
		curve.set_point_in(i, -tangent)
		curve.set_point_out(i, tangent)
	_flyers.append({"node": node, "curve": curve, "u": phase, "period": 46.0, "blink": blink, "kind": "plane"})


func _spawn_heli(h: Vector2i) -> void:
	var s := _first_scene(["vehicles/helicopter.glb"])
	if s == null:
		return
	var node := s.instantiate() as Node3D
	_air_root.add_child(node)
	var rotors: Array = []
	for c in node.find_children("Rotor*", "", true, false):
		rotors.append(c)
	_flyers.append({"node": node, "center": Vector3(h.x, 2.6, h.y), "u": 0.0, "kind": "heli", "rotors": rotors})


func _update_flyers(delta: float) -> void:
	for f: Dictionary in _flyers:
		var node: Node3D = f["node"]
		if f["kind"] == "plane":
			var curve: Curve3D = f["curve"]
			var length := curve.get_baked_length()
			f["u"] = fmod(float(f["u"]) + delta / float(f["period"]), 1.0)
			var off := float(f["u"]) * length
			var p := curve.sample_baked(off, true)
			var ahead := curve.sample_baked(fmod(off + 0.4, length), true)
			node.position = p
			if ahead.distance_to(p) > 0.01:
				var fwd := (ahead - p).normalized()
				node.basis = Basis.looking_at(-fwd, Vector3.UP).orthonormalized()
			(f["blink"] as OmniLight3D).light_energy = 2.0 if fmod(_time, 1.2) < 0.15 else 0.0
		else:
			f["u"] = float(f["u"]) + delta * 0.35
			var u2: float = f["u"]
			var c: Vector3 = f["center"]
			node.position = c + Vector3(cos(u2) * 2.2, sin(_time * 1.3) * 0.15, sin(u2) * 2.2)
			node.rotation.y = -u2
			for r: Node3D in f["rotors"]:
				r.rotate_object_local(Vector3.RIGHT if str(r.name).begins_with("RotorTail") else Vector3.UP, delta * 30.0)


# ------------------------------------------------------------------ frame loop

func _process(delta: float) -> void:
	if sim == null or _road_root == null:
		return
	_time += delta
	_census_t -= delta
	if _census_t <= 0.0:
		_census_t = 1.0
		_census()
	for list: Array in [_buses, _trucks]:
		var keep: Array[Dictionary] = []
		for a: Dictionary in list:
			if _step(a, delta, true):
				keep.append(a)
			else:
				(a["node"] as Node3D).queue_free()
		list.clear()
		list.append_array(keep)
	_update_crews(delta)
	_update_boats(delta)
	_update_flyers(delta)


func vehicle_counts() -> Dictionary:
	return {"buses": _buses.size(), "trucks": _trucks.size(), "crews": _crews.size(), "boats": _boats.size(), "aircraft": _flyers.size()}
