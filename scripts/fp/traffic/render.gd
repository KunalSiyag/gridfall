extends RefCounted
## Draws E's agents (docs/fp/slices/E-traffic.md §3 Draw calls): the full GLB only within NEAR of
## the camera (pooled per model, capped), beyond that one MultiMeshInstance3D per model built from
## a single-surface, vertex-coloured merge of the GLB (H's <name>_lod1.glb when it exists), with
## shadows to SHADOW_DIST and none beyond. Parked cars go through a static layer rebuilt only when
## the parked set changes or the camera moves. Brake lights, siren flashes and wheel spin on full
## models.

const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const KIT := preload("res://scripts/fp/traffic/mesh_kit.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const NEAR := 2.0
const NEAR_OUT := 2.25
const SHADOW_DIST := 3.0
## Full-detail caps until H's lod1 files and HC's tiers land (contract: 40).
const CAP_VEHICLES := 40
const CAP_PEOPLE := 40
const MAX_INSTANCE_PER_FRAME := 4
const SIREN_COLS := {"firetruck": [Color(1.0, 0.12, 0.08), Color(1.0, 0.7, 0.15)], "ambulance": [Color(1.0, 0.12, 0.08), Color(0.25, 0.45, 1.0)],
	"police": [Color(0.2, 0.4, 1.0), Color(1.0, 0.1, 0.12)]}
## MultiMesh layers per model: moving mid (shadows), moving far, static mid (shadows), static far.
const L_MID := 0
const L_FAR := 1
const L_SMID := 2
const L_SFAR := 3


## One drawable model.
class Model extends RefCounted:
	var key: String = ""
	var path: String = ""
	var scene: PackedScene = null
	var scale: float = 1.0
	var size := Vector3(0.1, 0.1, 0.24)   # world size (x width, y height, z length)
	var center := Vector3.ZERO            # model-space centre of the footprint (scaled), y = 0
	var lod_mesh: Mesh = null
	var mms: Array = [null, null, null, null]
	var lists: Array = [[], [], [], []]   # Transform3D per layer
	var pool: Array[Node3D] = []
	var person: bool = false
	var offset := Transform3D.IDENTITY    # scale and recentring applied after the agent transform


var root: Node3D
var models: Array = []
var _by_key: Dictionary = {}
var _lod_mat: StandardMaterial3D
var _brake_mat: StandardMaterial3D
var _siren_mats: Dictionary = {}
var _made_this_frame: int = 0
var full_vehicles: int = 0
var full_people: int = 0
var full_static: int = 0
var draws_people: int = 0
var draws_vehicles: int = 0
var time: float = 0.0
var _last_lod: int = -1


func setup(p_root: Node3D) -> void:
	root = p_root
	_lod_mat = KIT.vc_material(0.5, 0.15)
	_brake_mat = StandardMaterial3D.new()
	_brake_mat.albedo_color = Color(0.9, 0.05, 0.03)
	_brake_mat.emission_enabled = true
	_brake_mat.emission = Color(1.0, 0.05, 0.02)
	_brake_mat.emission_energy_multiplier = 5.0
	for k: String in SIREN_COLS.keys():
		var mats: Array = []
		for c: Color in SIREN_COLS[k]:
			var m := StandardMaterial3D.new()
			m.albedo_color = c
			m.emission_enabled = true
			m.emission = c
			m.emission_energy_multiplier = 8.0
			mats.append(m)
		_siren_mats[k] = mats


## Index of the model for a GLB path (loaded once), or -1 when it cannot load.
func model_for(path: String, scale: float, person: bool = false) -> int:
	var key := "%s@%.4f" % [path, scale]
	if _by_key.has(key):
		return _by_key[key]
	var ps := AP.load_scene(path)
	if ps == null:
		_by_key[key] = -1
		return -1
	var m := Model.new()
	m.key = key
	m.path = path
	m.scene = ps
	m.scale = scale
	m.person = person
	var inst := ps.instantiate() as Node3D
	var bb := _bounds(inst, Transform3D.IDENTITY)
	m.size = bb.size * scale
	m.center = Vector3(bb.get_center().x, 0, bb.get_center().z) * scale
	m.offset = Transform3D(Basis.from_scale(Vector3.ONE * scale), -m.center)
	# H's single-material far LOD when present, else a merge of the full model.
	var lod_path := path.get_basename() + "_lod1.glb"
	var lod_ps := AP.load_scene(lod_path) if ResourceLoader.exists(lod_path) else null
	var kit: KIT = KIT.new()
	kit.begin()
	if lod_ps != null:
		var li := lod_ps.instantiate() as Node3D
		kit.node(li)
		li.free()
	else:
		kit.node(inst)
	m.lod_mesh = kit.commit()
	inst.free()
	_add_mm(m)
	models.append(m)
	_by_key[key] = models.size() - 1
	return models.size() - 1


## A procedural model (one vertex-coloured mesh, drawn through the MultiMesh layers only).
func model_proc(key: String, mesh: Mesh, size: Vector3) -> int:
	if _by_key.has(key):
		return _by_key[key]
	var m := Model.new()
	m.key = key
	m.lod_mesh = mesh
	m.size = size
	_add_mm(m)
	models.append(m)
	_by_key[key] = models.size() - 1
	return models.size() - 1


func model(i: int) -> Model:
	return models[i] if i >= 0 and i < models.size() else null


func _add_mm(m: Model) -> void:
	if m.lod_mesh == null:
		return
	for k in range(4):
		var mmi := MultiMeshInstance3D.new()
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = m.lod_mesh
		mm.instance_count = 0
		mmi.multimesh = mm
		mmi.material_override = _lod_mat
		var shadows := k == L_MID or k == L_SMID
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.custom_aabb = AABB(Vector3(-200, -10, -200), Vector3(400, 40, 400))
		mmi.name = "LOD%d_%d" % [k, models.size()]
		mmi.visible = false
		root.add_child(mmi)
		m.mms[k] = mmi


func _bounds(n: Node, xf: Transform3D) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array = [[n, xf]]
	while not stack.is_empty():
		var top: Array = stack.pop_back()
		var node: Node = top[0]
		var t: Transform3D = top[1]
		if node is Node3D and node != n:
			t = t * (node as Node3D).transform
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			var b := t * (node as MeshInstance3D).mesh.get_aabb()
			out = b if first else out.merge(b)
			first = false
		for c in node.get_children():
			stack.append([c, t])
	return out


## Starts a frame of moving agents (the static layer keeps its lists).
func begin(dt: float) -> void:
	time += dt
	_made_this_frame = 0
	full_vehicles = 0
	full_people = 0
	for m: Model in models:
		(m.lists[L_MID] as Array).clear()
		(m.lists[L_FAR] as Array).clear()


## Starts a rebuild of the static (parked) layer.
func begin_static() -> void:
	full_static = 0
	for m: Model in models:
		(m.lists[L_SMID] as Array).clear()
		(m.lists[L_SFAR] as Array).clear()


func draw_car(c: VH.Car, xf: Transform3D, d: float, vis_end: float, brake: bool, siren: String, spin: float) -> void:
	c.node = _place(c.model, c.node, c.lod, xf, d, vis_end, false)
	c.lod = _last_lod
	if c.lod == 0:
		_extras(c.node, model(c.model), brake, siren, spin)


## A parked car into the static layer (between begin_static and finish_static).
func draw_parked(c: VH.Car, xf: Transform3D, d: float, vis_end: float) -> void:
	c.node = _place(c.model, c.node, c.lod, xf, d, vis_end, true)
	c.lod = _last_lod
	if c.lod == 0:
		full_static += 1
		_extras(c.node, model(c.model), false, "", 0.0)


func draw_walker(w: WK.Walker, xf: Transform3D, d: float, vis_end: float) -> void:
	w.node = _place(w.model, w.node, w.lod, xf, d, vis_end, false)
	w.lod = _last_lod


## Places one agent; returns its full node (or null) and sets _last_lod (-1 hidden, 0 full, 1 mid,
## 2 far).
func _place(mi: int, node: Node3D, lod: int, xf: Transform3D, d: float, vis_end: float, is_static: bool) -> Node3D:
	var m: Model = model(mi)
	if m == null or d > vis_end:
		_release_node(m, node)
		_last_lod = -1
		return null
	var want_full := m.scene != null and (d < NEAR or (lod == 0 and d < NEAR_OUT))
	if want_full:
		if m.person:
			want_full = full_people < CAP_PEOPLE
		else:
			want_full = full_vehicles + full_static < CAP_VEHICLES
	if want_full:
		var n := node if node != null else _take(m)
		if n != null:
			n.transform = xf * m.offset
			n.visible = true
			if m.person:
				full_people += 1
			elif not is_static:
				full_vehicles += 1
			_last_lod = 0
			return n
	_release_node(m, node)
	var t := xf * m.offset
	if d < SHADOW_DIST:
		(m.lists[L_SMID if is_static else L_MID] as Array).append(t)
		_last_lod = 1
	else:
		(m.lists[L_SFAR if is_static else L_FAR] as Array).append(t)
		_last_lod = 2
	return null


func _release_node(m: Model, node: Node3D) -> void:
	if node == null:
		return
	node.visible = false
	if m != null:
		m.pool.append(node)
	else:
		node.queue_free()


## Returns a vehicle's full node to its pool.
func release_car(c: VH.Car) -> void:
	_release_node(model(c.model), c.node)
	c.node = null
	c.lod = -1


func release_walker(w: WK.Walker) -> void:
	_release_node(model(w.model), w.node)
	w.node = null
	w.lod = -1


func _take(m: Model) -> Node3D:
	if not m.pool.is_empty():
		return m.pool.pop_back()
	if _made_this_frame >= MAX_INSTANCE_PER_FRAME:
		return null
	_made_this_frame += 1
	var n := m.scene.instantiate() as Node3D
	n.set_meta("fp_model", m.key)
	root.add_child(n)
	if not m.person:
		_index_parts(n)
	return n


func _index_parts(n: Node3D) -> void:
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		var mesh := (mi as MeshInstance3D).mesh
		if mesh == null:
			continue
		for s in range(mesh.get_surface_count()):
			var mat := mesh.surface_get_material(s)
			if mat != null and mat.resource_name == "Light_Tail":
				n.set_meta("tail", [mi, s])
	var sirens: Array = []
	for c in n.find_children("Siren*", "MeshInstance3D", true, false):
		sirens.append(c)
	if not sirens.is_empty():
		n.set_meta("sirens", sirens)
	var wheels: Array = []
	for w: String in AP.WHEEL_NODES:
		var wn := n.find_child(w, true, false)
		if wn != null:
			wheels.append(wn)
	if not wheels.is_empty():
		n.set_meta("wheels", wheels)
		var wb := _bounds(wheels[0], Transform3D.IDENTITY)
		n.set_meta("wheel_r", maxf(wb.size.y * 0.5, 0.001))


func _extras(node: Node3D, m: Model, brake: bool, siren: String, spin: float) -> void:
	if node == null or m == null:
		return
	if node.has_meta("tail"):
		var tail: Array = node.get_meta("tail")
		if brake != bool(node.get_meta("brake_on", false)):
			node.set_meta("brake_on", brake)
			(tail[0] as MeshInstance3D).set_surface_override_material(int(tail[1]), _brake_mat if brake else null)
	if node.has_meta("sirens"):
		var on := _siren_mats.has(siren)
		var sirens: Array = node.get_meta("sirens")
		var flash := int(time * 6.0) % 2
		for j in range(sirens.size()):
			var s: MeshInstance3D = sirens[j]
			s.material_override = (_siren_mats[siren][(j + flash) % 2] as Material) if on else null
	if node.has_meta("wheels"):
		var r: float = node.get_meta("wheel_r")
		var ang := spin / (r * m.scale)
		for w: Node3D in node.get_meta("wheels"):
			w.rotation.x = fposmod(ang, TAU)


## Writes the moving MultiMesh layers for this frame.
func finish() -> void:
	for m: Model in models:
		_fill(m.mms[L_MID], m.lists[L_MID])
		_fill(m.mms[L_FAR], m.lists[L_FAR])
	_count_draws()


## Writes the static (parked) layers.
func finish_static() -> void:
	for m: Model in models:
		_fill(m.mms[L_SMID], m.lists[L_SMID])
		_fill(m.mms[L_SFAR], m.lists[L_SFAR])


func _count_draws() -> void:
	draws_people = 0
	draws_vehicles = 0
	for m: Model in models:
		var n := 0
		for k in range(4):
			if not (m.lists[k] as Array).is_empty():
				n += 1
		if m.person:
			draws_people += n
		else:
			draws_vehicles += n
	draws_people += full_people * 5
	draws_vehicles += (full_vehicles + full_static) * 11


func _fill(mmi: Variant, list: Array) -> void:
	if mmi == null:
		return
	var mmn := mmi as MultiMeshInstance3D
	var mm := mmn.multimesh
	if list.is_empty():
		mmn.visible = false
		mm.visible_instance_count = 0
		return
	if mm.instance_count < list.size():
		mm.instance_count = int(max(list.size(), mm.instance_count * 2, 8))
	for k in range(list.size()):
		mm.set_instance_transform(k, list[k])
	mm.visible_instance_count = list.size()
	mmn.visible = true


## Frees every pooled and live node.
func clear() -> void:
	for m: Model in models:
		for n: Node3D in m.pool:
			if is_instance_valid(n):
				n.queue_free()
		m.pool.clear()
		for mmi: Variant in m.mms:
			if mmi != null and is_instance_valid(mmi):
				(mmi as Node).queue_free()
	models.clear()
	_by_key.clear()
	full_static = 0
