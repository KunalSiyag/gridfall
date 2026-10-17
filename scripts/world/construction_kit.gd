class_name ConstructionKit
extends RefCounted
## Procedural construction sites and machines: staged ground works, rising concrete frames,
## scaffolding, and animated excavators, backhoe loaders, dump trucks, cement mixers, tower
## cranes, bulldozers and road rollers. Machines are modelled in metres and scaled by MS.

const D := preload("res://scripts/sim/sim_defs.gd")
## One tile is roughly 16 m across next to the realistic cars (a 4.7 m sedan is 0.285 tiles).
const MS := 1.0 / 16.0
## Small parts stop drawing beyond this camera distance.
const FAR := 70.0
const FLOOR_H := 0.11

var view: Node
var _mats: Dictionary = {}
var _meshes: Dictionary = {}
var _anims: Array[Dictionary] = []


func _init(p_view: Node) -> void:
	view = p_view


# ---------------------------------------------------------------- materials and primitives

func mat(key: String) -> Material:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.roughness = 0.6
	match key:
		"paint":
			m.albedo_color = Color(0.93, 0.64, 0.06)
			m.metallic = 0.25
			m.roughness = 0.4
		"paint_dark":
			m.albedo_color = Color(0.17, 0.17, 0.19)
			m.metallic = 0.3
		"steel":
			m.albedo_color = Color(0.56, 0.57, 0.6)
			m.metallic = 0.85
			m.roughness = 0.35
		"rubber":
			m.albedo_color = Color(0.05, 0.05, 0.05)
			m.roughness = 0.95
		"glass":
			m.albedo_color = Color(0.1, 0.15, 0.2)
			m.metallic = 0.6
			m.roughness = 0.05
		"white":
			m.albedo_color = Color(0.9, 0.9, 0.87)
			m.metallic = 0.2
			m.roughness = 0.35
		"orange":
			m.albedo_color = Color(0.95, 0.42, 0.08)
			m.roughness = 0.45
		"red":
			m.albedo_color = Color(0.72, 0.1, 0.08)
			m.roughness = 0.45
		"concrete":
			m.albedo_color = Color(0.67, 0.66, 0.63)
			m.roughness = 0.92
		"concrete_wet":
			m.albedo_color = Color(0.45, 0.45, 0.44)
			m.roughness = 0.35
		"rebar":
			m.albedo_color = Color(0.42, 0.24, 0.14)
			m.metallic = 0.5
			m.roughness = 0.75
		"timber":
			m.albedo_color = Color(0.64, 0.47, 0.28)
			m.roughness = 0.85
		"net":
			m.albedo_color = Color(0.16, 0.4, 0.27, 0.62)
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			m.roughness = 0.9
		"hoarding":
			m.albedo_color = Color(0.15, 0.3, 0.5)
			m.roughness = 0.7
		"gravel":
			m.albedo_color = Color(0.52, 0.5, 0.47)
			m.roughness = 1.0
		"soil":
			m.albedo_color = Color(0.37, 0.28, 0.19)
			m.roughness = 1.0
		"soil_dark":
			m.albedo_color = Color(0.22, 0.17, 0.12)
			m.roughness = 1.0
		"asphalt_fresh":
			m.albedo_color = Color(0.08, 0.08, 0.09)
			m.roughness = 0.55
		"cone":
			m.albedo_color = Color(1.0, 0.38, 0.04)
			m.emission_enabled = true
			m.emission = Color(1.0, 0.35, 0.05)
			m.emission_energy_multiplier = 0.25
		"bark":
			m.albedo_color = Color(0.3, 0.22, 0.15)
		"leaf":
			m.albedo_color = Color(0.25, 0.5, 0.22)
			m.roughness = 0.8
		"grass":
			m.albedo_color = Color(0.32, 0.52, 0.24)
			m.roughness = 0.95
		_:
			m.albedo_color = Color.MAGENTA
	_mats[key] = m
	return m


func _material(m: Variant) -> Material:
	return m as Material if m is Material else mat(str(m))


func box(p: Node3D, size: Vector3, pos: Vector3, m: Variant, rot := Vector3.ZERO, shadow := true) -> MeshInstance3D:
	var key := "b%.3f,%.3f,%.3f" % [size.x, size.y, size.z]
	if not _meshes.has(key):
		var bm := BoxMesh.new()
		bm.size = size
		_meshes[key] = bm
	var mi := MeshInstance3D.new()
	mi.mesh = _meshes[key]
	mi.position = pos
	mi.rotation = rot
	mi.material_override = _material(m)
	mi.visibility_range_end = FAR
	if not shadow:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.add_child(mi)
	return mi


## Cylinder with its axis on local Y (rotate it to lay it down).
func cyl(p: Node3D, r: float, h: float, pos: Vector3, m: Variant, rot := Vector3.ZERO, r_top := -1.0) -> MeshInstance3D:
	var rt := r if r_top < 0.0 else r_top
	var key := "c%.3f,%.3f,%.3f" % [r, rt, h]
	if not _meshes.has(key):
		var cm := CylinderMesh.new()
		cm.bottom_radius = r
		cm.top_radius = rt
		cm.height = h
		cm.radial_segments = 14
		cm.rings = 1
		_meshes[key] = cm
	var mi := MeshInstance3D.new()
	mi.mesh = _meshes[key]
	mi.position = pos
	mi.rotation = rot
	mi.material_override = _material(m)
	mi.visibility_range_end = FAR
	p.add_child(mi)
	return mi


func mound(p: Node3D, r: float, h: float, pos: Vector3, m: Variant) -> MeshInstance3D:
	var key := "s%.3f" % r
	if not _meshes.has(key):
		var sm := SphereMesh.new()
		sm.radius = r
		sm.height = r * 2.0
		sm.radial_segments = 16
		sm.rings = 8
		_meshes[key] = sm
	var mi := MeshInstance3D.new()
	mi.mesh = _meshes[key]
	mi.position = pos
	mi.scale = Vector3(1.0, h / r, 1.0)
	mi.material_override = _material(m)
	mi.visibility_range_end = FAR
	p.add_child(mi)
	return mi


## A thin bar from a to b.
func strut(p: Node3D, a: Vector3, b: Vector3, t: float, m: Variant) -> MeshInstance3D:
	var mi := box(p, Vector3(t, a.distance_to(b), t), (a + b) * 0.5, m, Vector3.ZERO, false)
	var dir := (b - a).normalized()
	var side := Vector3.FORWARD if absf(dir.dot(Vector3.FORWARD)) < 0.99 else Vector3.RIGHT
	var x := dir.cross(side).normalized()
	mi.basis = Basis(x, dir, x.cross(dir).normalized())
	return mi


func wheel(p: Node3D, r: float, w: float, pos: Vector3) -> void:
	cyl(p, r, w, pos, "rubber", Vector3(PI / 2.0, 0, 0))
	cyl(p, r * 0.55, w + 0.04, pos, "steel", Vector3(PI / 2.0, 0, 0))


# ---------------------------------------------------------------- animation

func _anim(node: Node3D, type: String, base: Variant, amp: float, speed: float, phase := 0.0, extra: Variant = null) -> void:
	_anims.append({"node": node, "type": type, "base": base, "amp": amp, "speed": speed, "phase": phase, "extra": extra})


func animate(delta: float, t: float) -> void:
	var keep: Array[Dictionary] = []
	for a in _anims:
		var n: Variant = a["node"]
		if not is_instance_valid(n):
			continue
		keep.append(a)
		var node := n as Node3D
		if not node.is_visible_in_tree():
			continue
		var s := sin(t * float(a["speed"]) + float(a["phase"]))
		match str(a["type"]):
			"yaw":
				node.rotation.y = float(a["base"]) + float(a["amp"]) * s
			"pitch":
				node.rotation.z = float(a["base"]) + float(a["amp"]) * s
			"tip":
				node.rotation.z = float(a["base"]) + float(a["amp"]) * maxf(0.0, s)
			"spin":
				node.rotate_object_local(Vector3.UP, delta * float(a["speed"]))
			"slide":
				node.position.x = float(a["base"]) + float(a["amp"]) * s
			"shuttle":
				node.position = (a["base"] as Vector3) + (a["extra"] as Vector3) * (float(a["amp"]) * s)
			"roll":
				# Drum turns with the distance its shuttling machine has covered.
				node.rotation.z = -float(a["amp"]) * s / MS / float(a["base"])
	_anims = keep


# ---------------------------------------------------------------- machines (forward is +X)

func machine(kind: String, parent: Node3D, pos: Vector3, yaw: float, phase := 0.0) -> Node3D:
	var root := Node3D.new()
	root.name = kind.capitalize().replace(" ", "")
	root.position = pos
	root.rotation.y = yaw
	parent.add_child(root)
	var b := Node3D.new()
	b.scale = Vector3.ONE * MS
	root.add_child(b)
	match kind:
		"excavator":
			_excavator(b, phase)
		"backhoe":
			_backhoe(b, phase)
		"dump_truck":
			_dump_truck(b, phase)
		"mixer":
			_mixer(b, phase)
		"bulldozer":
			_bulldozer(b)
		"roller":
			_roller(b)
	return root


## Sends a machine back and forth along dir (holder space) by amp tiles.
func shuttle(m: Node3D, dir: Vector3, amp: float, speed: float, phase := 0.0) -> void:
	_anim(m, "shuttle", m.position, amp, speed, phase, dir.normalized())
	var drum := m.find_child("Drum", true, false) as Node3D
	if drum != null:
		_anim(drum, "roll", 0.75, amp, speed, phase)


func _excavator(b: Node3D, phase: float) -> void:
	for z in [-1.15, 1.15]:
		box(b, Vector3(4.6, 0.95, 0.75), Vector3(0, 0.48, z), "rubber")
		box(b, Vector3(3.6, 0.3, 0.8), Vector3(0, 0.62, z), "paint_dark", Vector3.ZERO, false)
	box(b, Vector3(2.4, 0.5, 1.6), Vector3(0, 0.95, 0), "paint_dark")
	var house := Node3D.new()
	house.position = Vector3(0, 1.2, 0)
	b.add_child(house)
	box(house, Vector3(3.4, 1.2, 2.6), Vector3(-0.5, 0.6, 0), "paint")
	box(house, Vector3(1.0, 1.15, 2.5), Vector3(-2.3, 0.62, 0), "paint_dark")
	box(house, Vector3(1.4, 1.5, 1.0), Vector3(0.6, 1.95, 0.75), "glass")
	box(house, Vector3(1.55, 0.12, 1.1), Vector3(0.6, 2.75, 0.75), "paint")
	cyl(house, 0.12, 0.9, Vector3(-1.4, 1.6, -0.8), "steel")
	var boom := Node3D.new()
	boom.name = "Boom"
	boom.position = Vector3(1.0, 1.0, -0.3)
	house.add_child(boom)
	box(boom, Vector3(5.2, 0.6, 0.55), Vector3(2.6, 0, 0), "paint")
	box(boom, Vector3(3.0, 0.18, 0.18), Vector3(1.6, -0.45, 0), "steel", Vector3.ZERO, false)
	var stick := Node3D.new()
	stick.position = Vector3(5.2, 0, 0)
	boom.add_child(stick)
	box(stick, Vector3(3.0, 0.45, 0.45), Vector3(1.5, 0, 0), "paint")
	box(stick, Vector3(0.9, 0.85, 1.1), Vector3(3.2, -0.25, 0), "paint_dark")
	_anim(house, "yaw", 0.0, 1.1, 0.45, phase)
	_anim(boom, "pitch", 0.5, 0.22, 0.9, phase)
	_anim(stick, "pitch", -2.05, 0.35, 0.9, phase + 1.3)


func _backhoe(b: Node3D, phase: float) -> void:
	box(b, Vector3(5.0, 0.9, 2.0), Vector3(0, 1.2, 0), "paint")
	box(b, Vector3(1.8, 0.7, 1.8), Vector3(1.5, 1.95, 0), "paint")
	box(b, Vector3(1.7, 1.6, 1.9), Vector3(-0.6, 2.45, 0), "glass")
	box(b, Vector3(1.95, 0.12, 2.1), Vector3(-0.6, 3.3, 0), "paint")
	cyl(b, 0.1, 0.8, Vector3(1.9, 2.6, -0.6), "steel")
	for z in [-1.05, 1.05]:
		wheel(b, 0.8, 0.6, Vector3(-1.2, 0.8, z))
		wheel(b, 0.55, 0.45, Vector3(1.6, 0.55, z))
		strut(b, Vector3(0.8, 1.7, z * 0.85), Vector3(3.0, 0.9, z * 0.85), 0.22, "paint")
	box(b, Vector3(0.9, 0.9, 2.3), Vector3(3.2, 0.55, 0), "paint_dark")
	box(b, Vector3(0.3, 0.8, 2.6), Vector3(-2.5, 0.45, 0), "paint_dark")
	var boom := Node3D.new()
	boom.name = "Boom"
	boom.position = Vector3(-2.7, 1.5, 0)
	b.add_child(boom)
	box(boom, Vector3(2.8, 0.4, 0.35), Vector3(1.4, 0, 0), "paint")
	var dip := Node3D.new()
	dip.position = Vector3(2.8, 0, 0)
	boom.add_child(dip)
	box(dip, Vector3(2.0, 0.3, 0.3), Vector3(1.0, 0, 0), "paint")
	box(dip, Vector3(0.6, 0.6, 0.6), Vector3(2.1, 0, 0), "paint_dark")
	_anim(boom, "pitch", PI - 0.85, 0.18, 0.8, phase)
	_anim(dip, "pitch", 2.3, 0.35, 0.8, phase + 1.0)


func _truck_base(b: Node3D, cab: String) -> void:
	box(b, Vector3(7.0, 0.5, 1.2), Vector3(0, 1.0, 0), "paint_dark")
	box(b, Vector3(1.8, 1.9, 2.4), Vector3(2.6, 2.0, 0), cab)
	box(b, Vector3(0.1, 0.9, 2.1), Vector3(3.52, 2.35, 0), "glass", Vector3.ZERO, false)
	box(b, Vector3(0.4, 0.5, 2.5), Vector3(3.5, 1.05, 0), "paint_dark", Vector3.ZERO, false)
	for x in [2.6, -1.0, -2.4]:
		for z in [-1.05, 1.05]:
			wheel(b, 0.55, 0.45, Vector3(x, 0.55, z))


func _dump_truck(b: Node3D, phase: float) -> void:
	_truck_base(b, "white")
	var bed := Node3D.new()
	bed.position = Vector3(-3.3, 1.35, 0)
	b.add_child(bed)
	box(bed, Vector3(4.9, 0.2, 2.4), Vector3(2.45, 0.1, 0), "orange")
	for z in [-1.15, 1.15]:
		box(bed, Vector3(4.9, 1.3, 0.12), Vector3(2.45, 0.75, z), "orange")
	box(bed, Vector3(0.12, 1.5, 2.4), Vector3(4.85, 0.85, 0), "orange")
	box(bed, Vector3(4.5, 0.55, 2.1), Vector3(2.3, 0.6, 0), "soil", Vector3.ZERO, false)
	_anim(bed, "tip", 0.0, 0.55, 0.35, phase)


func _mixer(b: Node3D, _phase: float) -> void:
	_truck_base(b, "white")
	var drum := Node3D.new()
	drum.position = Vector3(-0.9, 2.45, 0)
	drum.rotation.z = PI / 2.0 - 0.22
	b.add_child(drum)
	var spin := Node3D.new()
	drum.add_child(spin)
	cyl(spin, 1.25, 4.0, Vector3.ZERO, "white", Vector3.ZERO, 0.7)
	for k in range(3):
		var a := float(k) * TAU / 3.0
		box(spin, Vector3(0.22, 3.6, 0.3), Vector3(cos(a) * 1.02, 0, sin(a) * 1.02), "orange", Vector3(0, -a, 0.13), false)
	box(b, Vector3(0.9, 0.25, 0.5), Vector3(-3.6, 1.7, 0), "steel", Vector3(0, 0, -0.4), false)
	_anim(spin, "spin", 0.0, 0.0, 2.2)


func _tracks(b: Node3D, length: float) -> void:
	for z in [-1.1, 1.1]:
		box(b, Vector3(length, 1.0, 0.7), Vector3(0, 0.5, z), "rubber")
		box(b, Vector3(length - 0.6, 0.3, 0.75), Vector3(0, 0.65, z), "paint_dark", Vector3.ZERO, false)


func _bulldozer(b: Node3D) -> void:
	_tracks(b, 3.8)
	box(b, Vector3(3.0, 1.1, 1.9), Vector3(-0.2, 1.4, 0), "paint")
	box(b, Vector3(1.8, 0.7, 1.6), Vector3(0.9, 2.25, 0), "paint")
	box(b, Vector3(1.3, 1.4, 1.5), Vector3(-0.8, 2.65, 0), "glass")
	box(b, Vector3(1.5, 0.12, 1.7), Vector3(-0.8, 3.4, 0), "paint")
	cyl(b, 0.1, 0.9, Vector3(1.2, 3.0, -0.5), "steel")
	box(b, Vector3(0.35, 1.3, 3.6), Vector3(2.5, 0.72, 0), "paint_dark")
	for z in [-1.0, 1.0]:
		strut(b, Vector3(1.0, 1.1, z), Vector3(2.35, 0.8, z), 0.22, "paint")
	box(b, Vector3(0.25, 1.1, 0.25), Vector3(-2.3, 0.6, 0), "steel")


func _roller(b: Node3D) -> void:
	var drum := Node3D.new()
	drum.name = "Drum"
	drum.position = Vector3(1.8, 0.75, 0)
	b.add_child(drum)
	cyl(drum, 0.75, 2.1, Vector3.ZERO, "steel", Vector3(PI / 2.0, 0, 0))
	box(drum, Vector3(0.12, 1.3, 0.1), Vector3(0, 0, 1.06), "paint_dark", Vector3.ZERO, false)
	for z in [-1.15, 1.15]:
		box(b, Vector3(1.8, 0.9, 0.12), Vector3(1.8, 1.0, z), "paint")
	box(b, Vector3(2.8, 1.1, 1.8), Vector3(-0.6, 1.2, 0), "paint")
	for z in [-0.85, 0.85]:
		wheel(b, 0.65, 0.5, Vector3(-1.5, 0.65, z))
	for x in [-1.6, 0.3]:
		for z in [-0.75, 0.75]:
			box(b, Vector3(0.1, 1.4, 0.1), Vector3(x, 2.45, z), "paint_dark", Vector3.ZERO, false)
	box(b, Vector3(2.2, 0.1, 1.8), Vector3(-0.65, 3.2, 0), "paint")
	box(b, Vector3(0.6, 0.6, 0.6), Vector3(-0.8, 2.05, 0), "paint_dark", Vector3.ZERO, false)


## Tower crane in metres; the jib slews slowly and the trolley runs in and out.
func tower_crane(parent: Node3D, pos: Vector3, h_m: float, yaw: float, phase := 0.0) -> Node3D:
	var root := Node3D.new()
	root.name = "TowerCrane"
	root.position = pos
	root.rotation.y = yaw
	parent.add_child(root)
	var b := Node3D.new()
	b.scale = Vector3.ONE * MS
	root.add_child(b)
	box(b, Vector3(4.0, 1.0, 4.0), Vector3(0, 0.5, 0), "concrete")
	for cx in [-0.8, 0.8]:
		for cz in [-0.8, 0.8]:
			box(b, Vector3(0.18, h_m, 0.18), Vector3(cx, h_m * 0.5, cz), "paint")
	var seg := 2.4
	var n := int(h_m / seg)
	for k in range(n):
		var y0 := float(k) * seg
		var s := 1.0 if k % 2 == 0 else -1.0
		strut(b, Vector3(-0.8 * s, y0, 0.8), Vector3(0.8 * s, y0 + seg, 0.8), 0.09, "paint")
		strut(b, Vector3(-0.8 * s, y0, -0.8), Vector3(0.8 * s, y0 + seg, -0.8), 0.09, "paint")
		strut(b, Vector3(0.8, y0, -0.8 * s), Vector3(0.8, y0 + seg, 0.8 * s), 0.09, "paint")
		strut(b, Vector3(-0.8, y0, -0.8 * s), Vector3(-0.8, y0 + seg, 0.8 * s), 0.09, "paint")
	var slew := Node3D.new()
	slew.position.y = h_m
	b.add_child(slew)
	box(slew, Vector3(2.2, 1.0, 2.2), Vector3(0, 0.5, 0), "paint_dark")
	box(slew, Vector3(1.6, 1.7, 1.4), Vector3(1.4, 0.9, 1.5), "glass")
	box(slew, Vector3(1.7, 0.12, 1.5), Vector3(1.4, 1.8, 1.5), "paint")
	var jib := 20.0
	for z in [-0.6, 0.6]:
		box(slew, Vector3(jib, 0.16, 0.16), Vector3(jib * 0.5 + 0.8, 1.1, z), "paint")
		box(slew, Vector3(7.5, 0.16, 0.16), Vector3(-3.9, 1.1, z), "paint")
	box(slew, Vector3(jib, 0.16, 0.16), Vector3(jib * 0.5 + 0.8, 2.2, 0), "paint")
	for k in range(int(jib / 2.0)):
		var x0 := 0.8 + float(k) * 2.0
		strut(slew, Vector3(x0, 1.1, 0.6 if k % 2 == 0 else -0.6), Vector3(x0 + 2.0, 2.2, 0), 0.08, "paint")
	box(slew, Vector3(2.2, 1.8, 1.6), Vector3(-6.5, 0.4, 0), "concrete")
	box(slew, Vector3(0.35, 5.5, 0.35), Vector3(0, 3.75, 0), "paint")
	strut(slew, Vector3(0, 6.4, 0), Vector3(14.0, 2.2, 0), 0.07, "steel")
	strut(slew, Vector3(0, 6.4, 0), Vector3(-7.0, 1.2, 0), 0.07, "steel")
	var trolley := Node3D.new()
	trolley.position = Vector3(11.0, 1.0, 0)
	slew.add_child(trolley)
	box(trolley, Vector3(1.0, 0.3, 1.3), Vector3.ZERO, "paint_dark", Vector3.ZERO, false)
	var drop := h_m * 0.55
	box(trolley, Vector3(0.05, drop, 0.05), Vector3(0, -drop * 0.5, 0), "steel", Vector3.ZERO, false)
	box(trolley, Vector3(0.5, 0.6, 0.4), Vector3(0, -drop, 0), "red", Vector3.ZERO, false)
	box(trolley, Vector3(4.0, 0.45, 0.9), Vector3(0, -drop - 0.8, 0), "rebar", Vector3(0, 0.4, 0), false)
	_anim(slew, "yaw", 0.0, 0.9, 0.12, phase)
	_anim(trolley, "slide", 11.0, 6.0, 0.3, phase)
	return root


# ---------------------------------------------------------------- sites

## Builds one construction site under holder (tile-centred). ctx carries what the view knows:
## h (tile hash), height/foot (finished building size in tiles), target/old (models), axis/water.
func build_site(holder: Node3D, s: Dictionary, stage: String, f: float, ctx: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "Site"
	holder.add_child(root)
	var h := int(ctx.get("h", 0))
	var ph := float(h % 628) * 0.01
	if str(s["type"]) == "road":
		_road_site(root, stage, f, ctx, ph)
		return root
	var plan := str(s["plan"])
	var overlay := plan == "zone_up"
	var height := float(ctx.get("height", 0.5))
	var foot: Vector2 = ctx.get("foot", Vector2(0.7, 0.7))
	foot = Vector2(clampf(foot.x, 0.3, 0.9), clampf(foot.y, 0.3, 0.9))
	var big := height > 0.55 or str(s["type"]) == "build" and int(s["target_kind"]) in [D.AIRPORT, D.STADIUM, D.UNIVERSITY, D.COAL, D.HOSPITAL, D.TRAIN]
	if not overlay:
		_ground(root, stage)
		_fence(root, h)
	match stage:
		"clearing":
			for k in range(4):
				var a := float((h >> k) % 360) * 0.0175
				cyl(root, 0.018, 0.03, Vector3(cos(a) * 0.3, 0.015, sin(a) * 0.3), "bark")
			mound(root, 0.12, 0.05, Vector3(0.22, 0.0, 0.2), "soil")
			var dz := machine("bulldozer", root, Vector3(-0.1, 0, -0.05), 0.0)
			shuttle(dz, Vector3.RIGHT, 0.18, 0.5, ph)
			machine("dump_truck", root, Vector3(0.18, 0, -0.3), PI, ph)
		"excavation":
			box(root, Vector3(foot.x, 0.004, foot.y), Vector3(0, 0.012, 0), "soil_dark", Vector3.ZERO, false)
			for side in [-1.0, 1.0]:
				box(root, Vector3(foot.x + 0.06, 0.035, 0.05), Vector3(0, 0.017, side * (foot.y * 0.5 + 0.02)), "soil")
				box(root, Vector3(0.05, 0.035, foot.y + 0.06), Vector3(side * (foot.x * 0.5 + 0.02), 0.017, 0), "soil")
			mound(root, 0.13, 0.08, Vector3(0.33, 0.0, 0.33), "soil")
			machine("excavator", root, Vector3(-0.3, 0.03, -0.18), 0.0, ph)
			machine("dump_truck", root, Vector3(0.3, 0, -0.33), PI * 0.5, ph)
		"foundation":
			box(root, Vector3(foot.x, 0.03, foot.y), Vector3(0, 0.015, 0), "concrete_wet")
			for side in [-1.0, 1.0]:
				box(root, Vector3(foot.x + 0.02, 0.045, 0.012), Vector3(0, 0.022, side * foot.y * 0.5), "timber", Vector3.ZERO, false)
				box(root, Vector3(0.012, 0.045, foot.y + 0.02), Vector3(side * foot.x * 0.5, 0.022, 0), "timber", Vector3.ZERO, false)
			for gx in range(3):
				for gz in range(3):
					var p := Vector3((float(gx) - 1.0) * foot.x * 0.4, 0.06, (float(gz) - 1.0) * foot.y * 0.4)
					for o in [Vector3(-0.008, 0, -0.008), Vector3(0.008, 0, 0.008)]:
						box(root, Vector3(0.004, 0.07, 0.004), p + o, "rebar", Vector3.ZERO, false)
			machine("mixer", root, Vector3(0.28, 0, 0.36), PI, ph)
			machine("backhoe", root, Vector3(-0.32, 0, -0.34), 0.4, ph)
		"frame":
			var base_h := float(ctx.get("base_height", 0.0)) if overlay else 0.0
			if not overlay:
				box(root, Vector3(foot.x, 0.03, foot.y), Vector3(0, 0.015, 0), "concrete")
			_frame(root, foot, base_h, maxf(height, base_h + FLOOR_H), f)
			if overlay:
				_scaffold(root, foot, height, 0.0)
			machine("mixer", root, Vector3(0.3, 0, 0.4), PI, ph)
			if not big:
				machine("backhoe", root, Vector3(-0.34, 0, 0.38), 0.0, ph)
		"finishing":
			var target: Node3D = ctx.get("target", null)
			if target != null:
				root.add_child(target)
			_scaffold(root, foot, height, f)
			if not overlay:
				machine("dump_truck", root, Vector3(0.32, 0, 0.4), PI, ph + 2.0)
		"landscaping":
			box(root, Vector3(0.6, 0.006, 0.4), Vector3(-0.05, 0.012, 0.08), "grass", Vector3.ZERO, false)
			for k in range(5):
				var p := Vector3(float((h >> (k * 3)) % 7) * 0.1 - 0.3, 0, float((h >> (k * 2)) % 7) * 0.1 - 0.3)
				cyl(root, 0.008, 0.08, p + Vector3(0, 0.04, 0), "bark")
				mound(root, 0.035, 0.04, p + Vector3(0, 0.09, 0), "leaf")
			machine("backhoe", root, Vector3(0.2, 0, -0.28), PI * 0.8, ph)
		"demolition":
			var old: Node3D = ctx.get("old", null)
			if old != null:
				root.add_child(old)
				old.scale = Vector3(old.scale.x, old.scale.y * (1.0 - 0.75 * f), old.scale.z)
				old.rotation.z = 0.04
			mound(root, 0.22, 0.03 + 0.08 * f, Vector3(0.12, 0, 0.1), "concrete")
			var ex := machine("excavator", root, Vector3(-0.36, 0, -0.3), 0.6, ph)
			view.call("_add_smoke", ex, Color(0.6, 0.55, 0.48))
			machine("dump_truck", root, Vector3(0.3, 0, -0.38), PI * 0.5, ph)
		"hauling":
			var left := maxf(0.15, 1.0 - f)
			var pile := mound(root, 0.26, 0.1 * left, Vector3(0.05, 0, 0.05), "concrete")
			pile.name = "Pile"
			for k in range(5):
				box(root, Vector3(0.08, 0.04, 0.06), Vector3(float((h >> k) % 5) * 0.09 - 0.2, 0.03, float((h >> (k + 2)) % 5) * 0.09 - 0.2), "rebar" if k == 0 else "concrete", Vector3(0, float(k), 0.3))
			machine("backhoe", root, Vector3(-0.3, 0, 0.32), -0.6, ph)
			machine("dump_truck", root, Vector3(0.32, 0, -0.32), PI * 0.6, ph)
	if big and stage in ["frame", "finishing"]:
		tower_crane(root, Vector3(-foot.x * 0.5 - 0.1, 0, -foot.y * 0.5 - 0.1), clampf(height / MS + 9.0, 18.0, 40.0), float(h % 6), ph)
	if not overlay or stage == "frame":
		_floodlight(root, Vector3(foot.x * 0.5 + 0.06, 0, -foot.y * 0.5 - 0.06))
	return root


## Grows a rising frame's floors with stage progress (called a few times a second).
func update_site(holder: Node3D, f: float) -> void:
	var site := holder.get_node_or_null("Site") as Node3D
	if site == null:
		return
	var frame := site.get_node_or_null("Frame") as Node3D
	if frame != null:
		var n := frame.get_child_count()
		var show := clampi(int(ceil(float(n) * maxf(f, 0.05))), 1, n)
		for k in range(n):
			(frame.get_child(k) as Node3D).visible = k < show
	var pile := site.get_node_or_null("Pile") as Node3D
	if pile != null:
		pile.scale.y = maxf(0.15, 1.0 - f) * 0.1 / 0.26


func _ground(root: Node3D, stage: String) -> void:
	var g := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(0.98, 0.98)
	g.mesh = pm
	g.position.y = 0.007
	g.material_override = view.call("_pbr", "dirt", Color(0.38, 0.3, 0.22), 1.0) if stage != "landscaping" else mat("soil")
	root.add_child(g)


## Blue site hoarding with a gate gap on one side.
func _fence(root: Node3D, h: int) -> void:
	var gate := h % 4
	for k in range(4):
		var along := Vector3(0.94, 0.05, 0.008) if k % 2 == 0 else Vector3(0.008, 0.05, 0.94)
		var pos := [Vector3(0, 0.025, -0.47), Vector3(0.47, 0.025, 0), Vector3(0, 0.025, 0.47), Vector3(-0.47, 0.025, 0)][k] as Vector3
		if k == gate:
			var half := Vector3(along.x * 0.35, along.y, along.z * 0.35)
			var off := Vector3(0.3, 0, 0) if k % 2 == 0 else Vector3(0, 0, 0.3)
			box(root, half, pos - off, "hoarding", Vector3.ZERO, false)
			box(root, half, pos + off, "hoarding", Vector3.ZERO, false)
		else:
			box(root, along, pos, "hoarding", Vector3.ZERO, false)


func _floodlight(root: Node3D, pos: Vector3) -> void:
	box(root, Vector3(0.012, 0.42, 0.012), pos + Vector3(0, 0.21, 0), "steel", Vector3.ZERO, false)
	var head := box(root, Vector3(0.05, 0.025, 0.03), pos + Vector3(0, 0.43, 0), "paint_dark", Vector3.ZERO, false)
	var bulb := box(root, Vector3(0.045, 0.006, 0.026), pos + Vector3(0, 0.416, 0), "white", Vector3.ZERO, false)
	bulb.name = "Bulb_site"
	head.name = "FloodHead"


## Concrete columns and floor slabs from base_h up to top_h, one child node per floor.
func _frame(root: Node3D, foot: Vector2, base_h: float, top_h: float, f: float) -> void:
	var frame := Node3D.new()
	frame.name = "Frame"
	root.add_child(frame)
	var floors := maxi(1, int(round((top_h - base_h) / FLOOR_H)))
	var fh := (top_h - base_h) / float(floors)
	var g := 3 if foot.x > 0.55 else 2
	for k in range(floors):
		var fl := Node3D.new()
		fl.position.y = base_h + float(k) * fh
		frame.add_child(fl)
		for gx in range(g):
			for gz in range(g):
				var px := (float(gx) / float(g - 1) - 0.5) * foot.x * 0.92
				var pz := (float(gz) / float(g - 1) - 0.5) * foot.y * 0.92
				box(fl, Vector3(0.025, fh, 0.025), Vector3(px, fh * 0.5, pz), "concrete", Vector3.ZERO, false)
		box(fl, Vector3(foot.x, 0.012, foot.y), Vector3(0, fh, 0), "concrete")
		box(fl, Vector3(foot.x * 0.22, fh, foot.y * 0.22), Vector3(foot.x * 0.12, fh * 0.5, 0), "concrete_wet", Vector3.ZERO, false)
	for k in range(floors):
		var show := clampi(int(ceil(float(floors) * maxf(f, 0.05))), 1, floors)
		(frame.get_child(k) as Node3D).visible = k < show
	# Starter bars stick up out of the top slab.
	for gx in range(2):
		for gz in range(2):
			var p := Vector3((float(gx) - 0.5) * foot.x * 0.92, top_h + 0.03, (float(gz) - 0.5) * foot.y * 0.92)
			box(frame.get_child(floors - 1) as Node3D, Vector3(0.004, 0.06, 0.004), p - Vector3(0, base_h + float(floors - 1) * fh, 0), "rebar", Vector3.ZERO, false)


## Steel tube scaffold round the footprint; green netting drops away as finishing progresses.
func _scaffold(root: Node3D, foot: Vector2, height: float, f: float) -> void:
	var sc := Node3D.new()
	sc.name = "Scaffold"
	root.add_child(sc)
	var hx := foot.x * 0.5 + 0.035
	var hz := foot.y * 0.5 + 0.035
	var top := height + 0.04
	for px in [-hx, 0.0, hx]:
		for pz in [-hz, 0.0, hz]:
			if px == 0.0 and pz == 0.0:
				continue
			box(sc, Vector3(0.007, top, 0.007), Vector3(px, top * 0.5, pz), "steel", Vector3.ZERO, false)
	var lifts := maxi(1, int(top / 0.1))
	for k in range(1, lifts + 1):
		var y := minf(float(k) * 0.1, top)
		for side in [-1.0, 1.0]:
			box(sc, Vector3(hx * 2.0, 0.006, 0.006), Vector3(0, y, side * hz), "steel", Vector3.ZERO, false)
			box(sc, Vector3(0.006, 0.006, hz * 2.0), Vector3(side * hx, y, 0), "steel", Vector3.ZERO, false)
			box(sc, Vector3(hx * 2.0, 0.004, 0.03), Vector3(0, y - 0.003, side * (hz + 0.012)), "timber", Vector3.ZERO, false)
	var net_h := top * (1.0 - f * 0.85)
	if net_h > 0.02:
		box(sc, Vector3(hx * 2.0, net_h, 0.003), Vector3(0, top - net_h * 0.5, hz + 0.004), "net", Vector3.ZERO, false)
		box(sc, Vector3(0.003, net_h, hz * 2.0), Vector3(hx + 0.004, top - net_h * 0.5, 0), "net", Vector3.ZERO, false)


func _road_site(root: Node3D, stage: String, f: float, ctx: Dictionary, ph: float) -> void:
	# Pieces are laid out running north-south; east-west roads turn the whole site.
	if str(ctx.get("axis", "z")) == "x":
		root.rotation.y = PI * 0.5
	var water := bool(ctx.get("water", false))
	if water:
		var piers := 1.0 if stage != "piling" else maxf(0.25, f)
		for z in [-0.28, 0.28]:
			for x in [-0.22, 0.22]:
				var ph_h := 0.32 * piers
				cyl(root, 0.035, ph_h, Vector3(x, -0.3 + ph_h * 0.5, z), "concrete")
		if stage == "piling":
			box(root, Vector3(0.03, 0.55, 0.03), Vector3(0.0, 0.2, 0.0), "paint")
			box(root, Vector3(0.05, 0.08, 0.05), Vector3(0.0, 0.35, 0.0), "paint_dark")
			machine("backhoe", root, Vector3(0.0, 0.0, -0.42), -PI * 0.5, ph)
		else:
			box(root, Vector3(0.62, 0.05, 1.0), Vector3(0, 0.0, 0), "concrete")
			if stage == "paving":
				box(root, Vector3(0.5, 0.012, f), Vector3(0, 0.031, -0.5 + f * 0.5), "asphalt_fresh", Vector3.ZERO, false)
				var rl := machine("roller", root, Vector3(0, 0.025, 0), -PI * 0.5, ph)
				shuttle(rl, Vector3.BACK, 0.3, 0.6, ph)
			else:
				for x in [-0.27, 0.27]:
					box(root, Vector3(0.012, 0.05, 1.0), Vector3(x, 0.05, 0), "rebar", Vector3.ZERO, false)
				machine("mixer", root, Vector3(0.0, 0.025, 0.1), -PI * 0.5, ph)
		return
	var strip := box(root, Vector3(0.62, 0.006, 1.0), Vector3(0, 0.009, 0), "soil" if stage == "clearing" else "gravel", Vector3.ZERO, false)
	strip.material_override = view.call("_pbr", "dirt", Color(0.38, 0.3, 0.22), 1.0) if stage == "clearing" else mat("gravel")
	for z in [-0.46, 0.46]:
		for x in [-0.36, 0.36]:
			cyl(root, 0.012, 0.035, Vector3(x, 0.018, z), "cone", Vector3.ZERO, 0.002)
	match stage:
		"clearing":
			var dz := machine("bulldozer", root, Vector3(0, 0, 0), -PI * 0.5, ph)
			shuttle(dz, Vector3.BACK, 0.32, 0.45, ph)
		"grading":
			var dz2 := machine("bulldozer", root, Vector3(0.08, 0, 0), -PI * 0.5, ph)
			shuttle(dz2, Vector3.BACK, 0.3, 0.4, ph)
			mound(root, 0.06, 0.03, Vector3(-0.2, 0, 0.3), "gravel")
		"paving":
			box(root, Vector3(0.56, 0.008, maxf(0.05, f)), Vector3(0, 0.014, -0.5 + maxf(0.05, f) * 0.5), "asphalt_fresh", Vector3.ZERO, false)
			var rl2 := machine("roller", root, Vector3(0, 0, -0.1), -PI * 0.5, ph)
			shuttle(rl2, Vector3.BACK, 0.25, 0.7, ph)
