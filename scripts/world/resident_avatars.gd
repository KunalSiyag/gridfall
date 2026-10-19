class_name ResidentAvatars
extends Node3D
## Draws every AI resident as the person (or car) actually making their trip: they walk or drive
## the road route their mind chose, go inside at home/work/shops, gather around incidents they are
## fixing, and speak their lines. Clicking one selects them so the HUD can show their mind.
## In first person the traffic feature sets `external` and draws every resident itself; this node
## then only forwards and keeps the speech bubbles (docs/fp/slices/E-traffic.md §7).

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
## Street-level speech bubbles (first person): depth-tested, small, shown within this distance.
const FP_BUBBLE_RANGE := 1.5
const FP_BUBBLE_PIXEL := 0.0006
const FP_BUBBLE_ABOVE := 0.12
const REAL_PEOPLE := "res://models/real/people/"
const REAL_CARS := "res://models/real/vehicles/"
const KENNEY_CARS := ["res://models/cars/sedan.glb", "res://models/cars/hatchback-sports.glb", "res://models/cars/suv.glb", "res://models/cars/van.glb", "res://models/cars/taxi.glb"]
const SHIRTS := [Color(0.85, 0.25, 0.22), Color(0.22, 0.45, 0.85), Color(0.25, 0.65, 0.35), Color(0.92, 0.75, 0.2), Color(0.55, 0.35, 0.75), Color(0.9, 0.5, 0.2), Color(0.2, 0.7, 0.75), Color(0.85, 0.85, 0.85), Color(0.2, 0.2, 0.25)]
const SKINS := [Color(0.96, 0.8, 0.66), Color(0.86, 0.66, 0.5), Color(0.66, 0.46, 0.32), Color(0.45, 0.3, 0.2), Color(0.98, 0.86, 0.74)]
const INSIDE := ["home", "work", "shopping", "working late"]
const MAX_BUBBLES := 6

var sim: CitySim
var people: Residents
var camera: Camera3D
var selected: String = ""
## Set by CityView in first person (S0 seam): speech bubbles stay hidden while it is true.
var fp_hidden: bool = false
## The first-person traffic feature (or null): it draws residents, answers pick, visible_count and
## position_of, and gets resident_moved forwarded. Set and cleared by the feature.
var external: Object = null:
	set(v):
		external = v
		_apply_external()
var _bubble_root: Node3D
var _avatars: Dictionary = {}
var _people_scenes: Array = []
var _car_scenes: Array = []
var _car_scale: float = 1.0
var _mats: Dictionary = {}
var _ring: MeshInstance3D
var _name_tag: Label3D
var _time: float = 0.0
var _bubbles: int = 0


func setup(p_sim: CitySim, p_people: Residents, p_camera: Camera3D) -> void:
	sim = p_sim
	people = p_people
	camera = p_camera
	for a: Dictionary in _avatars.values():
		(a["root"] as Node3D).queue_free()
	_avatars.clear()
	_load_scenes()
	if _ring == null:
		_build_selection()
	if not people.resident_moved.is_connected(_on_moved):
		people.resident_moved.connect(_on_moved)
		people.resident_departed.connect(_on_departed)
	for r in people.people:
		_avatar(r)


func _load_scenes() -> void:
	_people_scenes.clear()
	_car_scenes.clear()
	for path: String in _list(REAL_PEOPLE, "person"):
		var ps := load(path) as PackedScene
		if ps != null:
			_people_scenes.append(ps)
	for path: String in _list(REAL_CARS, ""):
		var f := path.get_file()
		if f.begins_with("sedan") or f.begins_with("hatch") or f.begins_with("suv") or f.begins_with("taxi") or f.begins_with("van") or f.begins_with("pickup") or f.begins_with("coupe"):
			var cs := load(path) as PackedScene
			if cs != null:
				_car_scenes.append(cs)
	# Real vehicles are modelled at tile scale; the Kenney fallbacks are car-sized and need shrinking.
	_car_scale = 1.0
	if _car_scenes.is_empty():
		_car_scale = 0.17
		for path: String in KENNEY_CARS:
			if ResourceLoader.exists(path):
				_car_scenes.append(load(path))


func _list(dir_path: String, prefix: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for f in dir.get_files():
		var name := f.trim_suffix(".import").trim_suffix(".remap")
		if name.ends_with(".glb") and name.begins_with(prefix) and not out.has(dir_path + name):
			out.append(dir_path + name)
	out.sort()
	return out


func _mat(key: String, col: Color, emissive: float = 0.0) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 0.8
	if emissive > 0.0:
		m.emission_enabled = true
		m.emission = col
		m.emission_energy_multiplier = emissive
	_mats[key] = m
	return m


func _build_selection() -> void:
	_ring = MeshInstance3D.new()
	var t := TorusMesh.new()
	t.inner_radius = 0.13
	t.outer_radius = 0.17
	_ring.mesh = t
	_ring.material_override = _mat("ring", Color(0.0, 0.9, 1.0), 2.5)
	_ring.visible = false
	add_child(_ring)
	_name_tag = Label3D.new()
	_name_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_name_tag.font_size = 30
	_name_tag.pixel_size = 0.004
	_name_tag.outline_size = 8
	_name_tag.no_depth_test = true
	_name_tag.modulate = Color(0.75, 0.95, 1.0)
	_name_tag.visible = false
	add_child(_name_tag)


func _hash(s: String) -> int:
	return absi(hash(s))


func _avatar(r: Dictionary) -> Dictionary:
	var id := str(r["id"])
	if _avatars.has(id):
		return _avatars[id]
	var h := _hash(id)
	var root := Node3D.new()
	root.name = id
	add_child(root)
	var person := _make_person(h)
	root.add_child(person)
	var car: Node3D = null
	if not _car_scenes.is_empty():
		car = (_car_scenes[h % _car_scenes.size()] as PackedScene).instantiate() as Node3D
		car.scale = Vector3.ONE * _car_scale
		car.visible = false
		root.add_child(car)
	var bubble := Label3D.new()
	bubble.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	bubble.font_size = 26
	bubble.pixel_size = 0.0035
	bubble.outline_size = 7
	bubble.width = 420.0
	bubble.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bubble.position.y = 0.42
	bubble.visible = false
	root.add_child(bubble)
	var home := int(r["home"])
	root.position = Vector3(D.tx(home), 0, D.ty(home))
	root.visible = false
	var a := {"root": root, "person": person, "car": car, "bubble": bubble, "bubble_t": 0.0, "route": [], "t": 0.0, "speed": 1.0, "last_say": str(r.get("say", "")), "slot": h % 8}
	_avatars[id] = a
	return a


func _make_person(h: int) -> Node3D:
	if not _people_scenes.is_empty():
		var p := (_people_scenes[h % _people_scenes.size()] as PackedScene).instantiate() as Node3D
		p.scale = Vector3.ONE * (WS.PEOPLE_SCALE if _fp() else 1.5)
		return p
	var node := Node3D.new()
	var shirt: Color = SHIRTS[h % SHIRTS.size()]
	var legs := MeshInstance3D.new()
	var lm := CapsuleMesh.new()
	lm.radius = 0.022
	lm.height = 0.075
	legs.mesh = lm
	legs.position.y = 0.038
	legs.material_override = _mat("pants%d" % (h % 3), [Color(0.15, 0.18, 0.3), Color(0.25, 0.22, 0.2), Color(0.1, 0.1, 0.12)][h % 3])
	node.add_child(legs)
	var body := MeshInstance3D.new()
	var bm := CapsuleMesh.new()
	bm.radius = 0.028
	bm.height = 0.075
	body.mesh = bm
	body.position.y = 0.095
	body.material_override = _mat("shirt%d" % (h % SHIRTS.size()), shirt)
	node.add_child(body)
	var head := MeshInstance3D.new()
	var hm := SphereMesh.new()
	hm.radius = 0.02
	hm.height = 0.04
	head.mesh = hm
	head.position.y = 0.15
	head.material_override = _mat("skin%d" % (h % SKINS.size()), SKINS[h % SKINS.size()])
	node.add_child(head)
	return node


func _on_moved(r: Dictionary) -> void:
	if external != null:
		external.call("on_resident_moved", r)
		return
	var a := _avatar(r)
	var route: Array = r.get("route", [])
	a["route"] = route.duplicate()
	a["t"] = 0.0
	var tick_len := sim.tick_seconds() / float(maxi(sim.speed, 1))
	var duration := clampf(tick_len * 0.85, 0.6, 2.8)
	a["speed"] = maxf(1.0, float(route.size() - 1)) / duration
	var driving := str(r.get("mode", "walk")) in ["car", "bus"] and route.size() > 6 and a["car"] != null
	(a["person"] as Node3D).visible = not driving
	if a["car"] != null:
		(a["car"] as Node3D).visible = driving
	(a["root"] as Node3D).visible = route.size() > 1 or not _inside(str(r["state"]))


func _inside(state: String) -> bool:
	return state in INSIDE or state.begins_with("visiting")


func _on_departed(r: Dictionary, _reason: String) -> void:
	var id := str(r["id"])
	if _avatars.has(id):
		(_avatars[id]["root"] as Node3D).queue_free()
		_avatars.erase(id)
	if selected == id:
		selected = ""


func _process(delta: float) -> void:
	if people == null:
		return
	_time += delta
	_bubbles = 0
	if external != null:
		_process_external(delta)
		return
	for r in people.people:
		var a := _avatar(r)
		var root: Node3D = a["root"]
		var route: Array = a["route"]
		var say := str(r.get("say", ""))
		if say != str(a["last_say"]):
			a["last_say"] = say
			if not say.is_empty():
				(a["bubble"] as Label3D).text = "%s: \"%s\"" % [str(r["name"]).split(" ")[0], say]
				a["bubble_t"] = 7.0
		if float(a["bubble_t"]) > 0.0:
			a["bubble_t"] = float(a["bubble_t"]) - delta
		var show_bubble := float(a["bubble_t"]) > 0.0 and root.visible and _bubbles < MAX_BUBBLES and not fp_hidden
		(a["bubble"] as Label3D).visible = show_bubble
		if show_bubble:
			_bubbles += 1
			(a["bubble"] as Label3D).modulate.a = clampf(float(a["bubble_t"]), 0.0, 1.0)
		if route.size() > 1:
			_advance(a, r, delta)
		else:
			_idle(a, r, delta)
	_update_selection()


func _advance(a: Dictionary, r: Dictionary, delta: float) -> void:
	var route: Array = a["route"]
	var root: Node3D = a["root"]
	a["t"] = float(a["t"]) + float(a["speed"]) * delta
	var seg := int(floor(float(a["t"])))
	if seg >= route.size() - 1:
		var last: Vector2i = route[route.size() - 1]
		root.position = Vector3(last.x, 0, last.y)
		a["route"] = []
		(a["person"] as Node3D).visible = true
		if a["car"] != null:
			(a["car"] as Node3D).visible = false
		root.visible = not _inside(str(r["state"]))
		return
	var from: Vector2i = route[seg]
	var to: Vector2i = route[seg + 1]
	var f := float(a["t"]) - float(seg)
	var dir := Vector3(to.x - from.x, 0, to.y - from.y)
	var driving: bool = a["car"] != null and (a["car"] as Node3D).visible
	var side := 0.13 if driving else 0.36
	var right := Vector3(-dir.z, 0, dir.x)
	var p := Vector3(from.x, 0, from.y).lerp(Vector3(to.x, 0, to.y), f) + right * side
	var bob := 0.0 if driving else absf(sin(_time * 10.0 + float(a["slot"]))) * 0.008
	root.position = Vector3(p.x, _float_y() + bob, p.z)
	if dir.length_squared() > 0.0:
		root.rotation.y = lerp_angle(root.rotation.y, atan2(dir.x, dir.z), minf(1.0, delta * 12.0))


func _idle(a: Dictionary, r: Dictionary, delta: float) -> void:
	var root: Node3D = a["root"]
	var state := str(r["state"])
	root.visible = not _inside(state)
	if not root.visible:
		return
	var at := int(r["at"])
	var center := Vector3(D.tx(at), _float_y(), D.ty(at))
	var slot := int(a["slot"])
	var ang := float(slot) / 8.0 * TAU + _time * (0.15 if state.begins_with("at the") else 0.0)
	var radius := 0.42 if state.begins_with("helping") else 0.3
	var target := center + Vector3(cos(ang), 0, sin(ang)) * radius
	root.position = root.position.lerp(target, minf(1.0, delta * 3.0))
	var face := center - root.position
	if face.length_squared() > 0.0001:
		root.rotation.y = lerp_angle(root.rotation.y, atan2(face.x, face.z), minf(1.0, delta * 6.0))
	if state.begins_with("helping") or state.begins_with("protesting"):
		root.position.y = _float_y() + absf(sin(_time * 6.0 + float(slot))) * 0.02


func _update_selection() -> void:
	if _fp():
		_ring.visible = false
		_name_tag.visible = false
		return
	if selected.is_empty() or not _avatars.has(selected):
		_ring.visible = false
		_name_tag.visible = false
		return
	var r := people.find(selected)
	if r.is_empty():
		selected = ""
		return
	var p := position_of(selected)
	_ring.visible = true
	_ring.position = Vector3(p.x, 0.07, p.z)
	_ring.rotation.y = _time
	_name_tag.visible = true
	_name_tag.position = p + Vector3(0, 0.62, 0)
	var inside := "" if (_avatars[selected]["root"] as Node3D).visible else " (inside)"
	_name_tag.text = "%s · %s%s\nmood %.0f/10 · %s" % [r["name"], r["job_title"], inside, float(r["mood"]), r["state"]]


func position_of(id: String) -> Vector3:
	if external != null:
		return external.call("position_of", id)
	if not _avatars.has(id):
		return Vector3(15.5, 0, 15.5)
	var root: Node3D = _avatars[id]["root"]
	if root.visible:
		return root.position
	var r := people.find(id)
	if r.is_empty():
		return root.position
	var at := int(r["at"])
	return Vector3(D.tx(at), 0, D.ty(at))


## Returns the id of the visible resident drawn closest to screen_pos, or "".
func pick(screen_pos: Vector2) -> String:
	if external != null:
		return str(external.call("avatar_pick", screen_pos, camera))
	if camera == null:
		return ""
	var best := ""
	var best_d := 26.0
	for id: String in _avatars.keys():
		var root: Node3D = _avatars[id]["root"]
		if not root.visible:
			continue
		var wp := root.global_position + Vector3(0, 0.08, 0)
		if camera.is_position_behind(wp):
			continue
		var d := camera.unproject_position(wp).distance_to(screen_pos)
		if d < best_d:
			best_d = d
			best = id
	return best


func select(id: String) -> void:
	selected = id


func visible_count() -> Dictionary:
	if external != null:
		return external.call("avatar_counts")
	var walking := 0
	var driving := 0
	var standing := 0
	for a: Dictionary in _avatars.values():
		var root: Node3D = a["root"]
		if not root.visible:
			continue
		if (a["route"] as Array).size() > 1:
			if a["car"] != null and (a["car"] as Node3D).visible:
				driving += 1
			else:
				walking += 1
		else:
			standing += 1
	return {"walking": walking, "driving": driving, "standing": standing, "total": _avatars.size()}


## True in first person (CityView.fp_mode): avatars stand on the ground at true scale.
func _fp() -> bool:
	if fp_hidden:
		return true
	var v := get_parent()
	return v != null and v.get("fp_mode") == true


## Legacy orbit height of avatar roots; first person stands them on the sidewalk.
func _float_y() -> float:
	return WS.SIDEWALK_TOP if _fp() else 0.05


## Hides every legacy avatar (the traffic feature draws residents) and moves the speech bubbles
## to a separate root that follows the feature's head anchors.
func _apply_external() -> void:
	if _ring != null:
		_ring.visible = false
		_name_tag.visible = false
	for a: Dictionary in _avatars.values():
		var root: Node3D = a["root"]
		if not is_instance_valid(root):
			continue
		root.visible = external == null and root.visible
		var bubble: Label3D = a["bubble"]
		if external != null:
			if bubble.get_parent() != _bubble_parent():
				bubble.reparent(_bubble_parent(), false)
			_style_bubble(bubble, true)
		elif bubble.get_parent() != root:
			bubble.reparent(root, false)
			bubble.position = Vector3(0, 0.42, 0)
			_style_bubble(bubble, false)


func _bubble_parent() -> Node3D:
	if _bubble_root == null or not is_instance_valid(_bubble_root):
		_bubble_root = Node3D.new()
		_bubble_root.name = "Bubbles"
		add_child(_bubble_root)
	return _bubble_root


func _style_bubble(b: Label3D, street: bool) -> void:
	b.pixel_size = FP_BUBBLE_PIXEL if street else 0.0035
	b.no_depth_test = false
	b.fixed_size = false


## First person with the traffic feature: no legacy movement, every avatar root hidden; bubbles
## (depth-tested, near the player only, never while fp_hidden) ride the feature's head anchors.
func _process_external(delta: float) -> void:
	var cam := camera.global_position if camera != null and camera.is_inside_tree() else Vector3(INF, INF, INF)
	for r in people.people:
		var a := _avatar(r)
		var root: Node3D = a["root"]
		root.visible = false
		var bubble: Label3D = a["bubble"]
		if bubble.get_parent() != _bubble_parent():
			bubble.reparent(_bubble_parent(), false)
			_style_bubble(bubble, true)
		var say := str(r.get("say", ""))
		if say != str(a["last_say"]):
			a["last_say"] = say
			if not say.is_empty():
				bubble.text = "%s: \"%s\"" % [str(r["name"]).split(" ")[0], say]
				a["bubble_t"] = 7.0
		if float(a["bubble_t"]) > 0.0:
			a["bubble_t"] = float(a["bubble_t"]) - delta
		var show := false
		if float(a["bubble_t"]) > 0.0 and not fp_hidden and _bubbles < MAX_BUBBLES:
			var id := str(r["id"])
			if bool(external.call("is_resident_visible", id)):
				var head: Vector3 = external.call("anchor_of", id)
				if head.distance_to(cam) <= FP_BUBBLE_RANGE:
					bubble.position = head + Vector3(0, FP_BUBBLE_ABOVE, 0)
					show = true
		bubble.visible = show
		if show:
			_bubbles += 1
			bubble.modulate.a = clampf(float(a["bubble_t"]), 0.0, 1.0)
	_ring.visible = false
	_name_tag.visible = false
