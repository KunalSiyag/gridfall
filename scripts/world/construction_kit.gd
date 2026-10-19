class_name ConstructionKit
extends RefCounted
## Procedural construction sites and machines: staged ground works, rising concrete frames,
## scaffolding, and animated excavators, backhoe loaders, dump trucks, cement mixers, tower
## cranes, bulldozers and road rollers. Machines are modelled in metres and scaled by MS.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
## Machines are modelled in metres: true scale is one tile per 20 m.
const MS := WS.MACHINE_SCALE
## Small parts stop drawing beyond this camera distance; the crane's big parts carry further.
const FAR := WS.VIS_SITE_PART
const CRANE_FAR := 30.0
const FLOOR_H := 0.11
## Site hoarding height: 1 m in orbit, 2.2 m of painted plywood on foot.
const HOARDING_H := 0.05
const HOARDING_H_FP := 2.2 * WS.M
## Hoarding paint per site (hash): green, slate, raw plywood.
const HOARDING_TINTS := [Color(0.33, 0.43, 0.34), Color(0.36, 0.4, 0.45), Color(0.86, 0.7, 0.5)]
## Machines keep their footprint inside the hoarding at +-HOARDING_IN.
const HOARDING_IN := 0.46
const GRIME := "res://textures/real/decals/"

var view: Node
var _mats: Dictionary = {}
var _meshes: Dictionary = {}
var _anims: Array[Dictionary] = []
var _site_root: Node3D
## Parts of the site being built that block a walker: {"n": Node3D, "arms": bool, "box": AABB in
## n's frame (optional; else the bounds of n's meshes), "anims": the part's own _anims entries,
## "sweep": Vector3 (shuttle travel, n's parent frame), "kind": machine kind}. build_site bakes
## them into the Site root's `colliders` meta.
var _solids: Array[Dictionary] = []
## Machine kind -> its swept bounds in the machine's frame (machines are built the same every time).
var _machine_bounds: Dictionary = {}
## Machine kind -> its footprint bounds in the machine root's frame (unrotated, arms included).
var _machine_foot: Dictionary = {}
var _grime: Texture2D
var _dust: Texture2D


func _init(p_view: Node) -> void:
	view = p_view


# ---------------------------------------------------------------- materials and primitives

func mat(key: String) -> Material:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.roughness = 0.6
	if key in ["paint", "paint_dark", "white", "orange", "red", "steel", "rubber"]:
		_add_grime(m)
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
		"hoarding_fp_0", "hoarding_fp_1", "hoarding_fp_2":
			# Painted (or raw) plywood, one repeat per 4.8 m, tinted per site.
			m.albedo_color = HOARDING_TINTS[int(key.right(1))]
			m.roughness = 0.82
			var tex := "res://textures/real/decals/hoarding.png"
			if ResourceLoader.exists(tex):
				m.albedo_texture = load(tex)
				m.uv1_triplanar = true
				m.uv1_world_triplanar = true
				m.uv1_scale = Vector3.ONE / (4.8 * WS.M)
				m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
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


## Worn paint and dust on machine materials: a soft noise mask blends in a dusty brown, mapped in the
## machine's own metres so it travels with it.
func _add_grime(m: StandardMaterial3D) -> void:
	if _grime == null:
		if not ResourceLoader.exists(GRIME + "grime_mask.png"):
			return
		_grime = load(GRIME + "grime_mask.png")
		_dust = load(GRIME + "grime_dust.png")
	m.detail_enabled = true
	m.detail_mask = _grime
	m.detail_albedo = _dust
	m.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	m.uv1_triplanar = true
	m.uv1_scale = Vector3.ONE * 0.35


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
	var a0 := _anims.size()
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
	# Keep the machine (arms included) inside the hoarding.
	var foot := _foot_of(kind, b)
	var yb := Basis(Vector3.UP, yaw)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for cx: float in [foot.position.x, foot.end.x]:
		for cz: float in [foot.position.z, foot.end.z]:
			var c := yb * Vector3(cx, 0, cz)
			lo = Vector2(minf(lo.x, c.x), minf(lo.y, c.z))
			hi = Vector2(maxf(hi.x, c.x), maxf(hi.y, c.z))
	if hi.x - lo.x < HOARDING_IN * 2.0:
		root.position.x = clampf(pos.x, -HOARDING_IN - lo.x, HOARDING_IN - hi.x)
	if hi.y - lo.y < HOARDING_IN * 2.0:
		root.position.z = clampf(pos.z, -HOARDING_IN - lo.y, HOARDING_IN - hi.y)
	_solids.append({"n": root, "arms": false, "anims": _anims.slice(a0), "kind": kind})
	return root


## Bounds of a freshly built machine body b in its root's frame (cached per kind).
func _foot_of(kind: String, b: Node3D) -> AABB:
	if _machine_foot.has(kind):
		return _machine_foot[kind]
	var bb := AABB()
	var first := true
	for n in b.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		var xf := Transform3D()
		var q: Node = mi
		while q != b:
			xf = (q as Node3D).transform * xf
			q = q.get_parent()
		var a := (b.transform * xf) * mi.mesh.get_aabb()
		bb = a if first else bb.merge(a)
		first = false
	_machine_foot[kind] = bb
	return bb


## Sends a machine back and forth along dir (holder space) by amp tiles.
func shuttle(m: Node3D, dir: Vector3, amp: float, speed: float, phase := 0.0) -> void:
	_anim(m, "shuttle", m.position, amp, speed, phase, dir.normalized())
	for e: Dictionary in _solids:
		if e["n"] == m:
			e["sweep"] = dir.normalized() * amp
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
	# Only the base and the mast block a walker; the jib slews far overhead.
	solid_box(b, AABB(Vector3(-2.0, 0.0, -2.0), Vector3(4.0, 1.0, 4.0)))
	solid_box(b, AABB(Vector3(-0.9, 0.0, -0.9), Vector3(1.8, h_m + 1.0, 1.8)))
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
	for part in root.find_children("*", "GeometryInstance3D", true, false):
		(part as GeometryInstance3D).visibility_range_end = CRANE_FAR
	return root


# ---------------------------------------------------------------- sites

## Builds one construction site under holder (tile-centred). ctx carries what the view knows:
## h (tile hash), height/foot (finished building size in tiles), target/old (models), axis/water.
func build_site(holder: Node3D, s: Dictionary, stage: String, f: float, ctx: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "Site"
	holder.add_child(root)
	_site_root = root
	_solids.clear()
	var h := int(ctx.get("h", 0))
	var ph := float(h % 628) * 0.01
	if str(s["type"]) == "road":
		_road_site(root, stage, ctx, ph)
		_bake_colliders(root)
		_apply_progress(root, f)
		return root
	var plan := str(s["plan"])
	var overlay := plan == "zone_up"
	var height := float(ctx.get("height", 0.5))
	var foot: Vector2 = ctx.get("foot", Vector2(0.7, 0.7))
	foot = Vector2(clampf(foot.x, 0.3, 0.9), clampf(foot.y, 0.3, 0.9))
	var big := height > 0.55 or str(s["type"]) == "build" and int(s["target_kind"]) in [D.AIRPORT, D.STADIUM, D.UNIVERSITY, D.COAL, D.HOSPITAL, D.TRAIN]
	if not overlay:
		_ground(root, stage)
		_fence(root, h, ctx.get("front", Vector2i.ZERO))
	match stage:
		"clearing":
			# Standing trees come down first, then the stumps get grubbed out.
			var trees := _group(root, "Trees")
			var stumps := _group(root, "Stumps")
			for k in range(4):
				var a := float((h >> k) % 360) * 0.0175
				var p := Vector3(cos(a) * 0.3, 0, sin(a) * 0.3)
				cyl(stumps, 0.018, 0.03, p + Vector3(0, 0.015, 0), "bark")
				var tree := _group(trees, "Tree")
				tree.position = p
				cyl(tree, 0.012, 0.12, Vector3(0, 0.06, 0), "bark")
				mound(tree, 0.06, 0.07, Vector3(0, 0.15, 0), "leaf")
			track(trees, "hide", 0.0, 0.55)
			track(stumps, "hide", 0.45, 1.0)
			solid(track(mound(root, 0.12, 0.05, Vector3(0.22, 0.0, 0.2), "soil"), "sy", 0.0, 1.0, 0.3, 1.4))
			var dz := machine("bulldozer", root, Vector3(-0.1, 0, -0.05), 0.0)
			shuttle(dz, Vector3.RIGHT, 0.18, 0.5, ph)
			machine("dump_truck", root, Vector3(0.18, 0, -0.3), PI, ph)
		"excavation":
			# The pit widens and the spoil heaps grow as the digger works.
			track(box(root, Vector3(foot.x, 0.004, foot.y), Vector3(0, 0.012, 0), "soil_dark", Vector3.ZERO, false), "sxz", 0.0, 1.0, 0.2, 1.0)
			var berms := _group(root, "Berms")
			for side in [-1.0, 1.0]:
				box(berms, Vector3(foot.x + 0.06, 0.035, 0.05), Vector3(0, 0.017, side * (foot.y * 0.5 + 0.02)), "soil")
				box(berms, Vector3(0.05, 0.035, foot.y + 0.06), Vector3(side * (foot.x * 0.5 + 0.02), 0.017, 0), "soil")
			solid(track(berms, "sy", 0.0, 1.0, 0.15, 1.0))
			solid(track(mound(root, 0.13, 0.08, Vector3(0.33, 0.0, 0.33), "soil"), "sy", 0.0, 1.0, 0.25, 1.3))
			machine("excavator", root, Vector3(-0.3, 0.03, -0.18), 0.0, ph)
			machine("dump_truck", root, Vector3(0.3, 0, -0.33), PI * 0.5, ph)
		"foundation":
			# Rebar goes in first, then the slab is poured across the formwork.
			solid(track(box(root, Vector3(foot.x, 0.03, foot.y), Vector3(0, 0.015, 0), "concrete_wet"), "sx", 0.4, 1.0, 0.0, 1.0))
			var bars := _group(root, "Rebar")
			for side in [-1.0, 1.0]:
				solid(box(root, Vector3(foot.x + 0.02, 0.045, 0.012), Vector3(0, 0.022, side * foot.y * 0.5), "timber", Vector3.ZERO, false))
				solid(box(root, Vector3(0.012, 0.045, foot.y + 0.02), Vector3(side * foot.x * 0.5, 0.022, 0), "timber", Vector3.ZERO, false))
			for gx in range(3):
				for gz in range(3):
					var p := Vector3((float(gx) - 1.0) * foot.x * 0.4, 0.06, (float(gz) - 1.0) * foot.y * 0.4)
					for o in [Vector3(-0.008, 0, -0.008), Vector3(0.008, 0, 0.008)]:
						box(bars, Vector3(0.004, 0.07, 0.004), p + o, "rebar", Vector3.ZERO, false)
			track(bars, "reveal", 0.0, 0.45)
			machine("mixer", root, Vector3(0.28, 0, 0.36), PI, ph)
			machine("backhoe", root, Vector3(-0.32, 0, -0.34), 0.4, ph)
		"frame":
			var base_h := float(ctx.get("base_height", 0.0)) if overlay else 0.0
			if not overlay:
				solid(box(root, Vector3(foot.x, 0.03, foot.y), Vector3(0, 0.015, 0), "concrete"))
			_frame(root, foot, base_h, maxf(height, base_h + FLOOR_H), f)
			if overlay:
				_scaffold(root, foot, height, false)
			machine("mixer", root, Vector3(0.3, 0, 0.4), PI, ph)
			if not big:
				machine("backhoe", root, Vector3(-0.34, 0, 0.38), 0.0, ph)
		"finishing":
			var target: Node3D = ctx.get("target", null)
			if target != null:
				root.add_child(target)
				solid(target)
			_scaffold(root, foot, height, true)
			if not overlay:
				machine("dump_truck", root, Vector3(0.32, 0, 0.4), PI, ph + 2.0)
		"landscaping":
			track(box(root, Vector3(0.6, 0.006, 0.4), Vector3(-0.05, 0.012, 0.08), "grass", Vector3.ZERO, false), "sxz", 0.0, 0.7, 0.15, 1.0)
			var planted := _group(root, "Planting")
			for k in range(5):
				var p := Vector3(float((h >> (k * 3)) % 7) * 0.1 - 0.3, 0, float((h >> (k * 2)) % 7) * 0.1 - 0.3)
				var tree := _group(planted, "Tree")
				tree.position = p
				cyl(tree, 0.008, 0.08, Vector3(0, 0.04, 0), "bark")
				mound(tree, 0.035, 0.04, Vector3(0, 0.09, 0), "leaf")
			track(planted, "reveal", 0.2, 1.0)
			machine("backhoe", root, Vector3(0.2, 0, -0.28), PI * 0.8, ph)
		"demolition":
			var old: Node3D = ctx.get("old", null)
			if old != null:
				root.add_child(old)
				old.rotation.z = 0.04
				solid(track(old, "sy", 0.0, 1.0, 1.0, 0.25))
			solid(track(mound(root, 0.22, 0.11, Vector3(0.12, 0, 0.1), "concrete"), "sy", 0.0, 1.0, 0.27, 1.0))
			var ex := machine("excavator", root, Vector3(-0.36, 0, -0.3), 0.6, ph)
			view.call("_add_smoke", ex, Color(0.6, 0.55, 0.48))
			machine("dump_truck", root, Vector3(0.3, 0, -0.38), PI * 0.5, ph)
		"hauling":
			solid(track(mound(root, 0.26, 0.1, Vector3(0.05, 0, 0.05), "concrete"), "sy", 0.0, 1.0, 1.0, 0.15))
			var debris := _group(root, "Debris")
			for k in range(5):
				box(debris, Vector3(0.08, 0.04, 0.06), Vector3(float((h >> k) % 5) * 0.09 - 0.2, 0.03, float((h >> (k + 2)) % 5) * 0.09 - 0.2), "rebar" if k == 0 else "concrete", Vector3(0, float(k), 0.3))
			track(debris, "hide", 0.1, 0.9)
			machine("backhoe", root, Vector3(-0.3, 0, 0.32), -0.6, ph)
			machine("dump_truck", root, Vector3(0.32, 0, -0.32), PI * 0.6, ph)
	if big and stage in ["frame", "finishing"]:
		# An internal climbing crane in the footprint's corner, inside the hoarding (it used to stand
		# 0.1 u outside the footprint, up to 4 m onto the neighbouring sidewalk).
		var cp := Vector3(-clampf(foot.x * 0.5 - 0.1, 0.0, 0.36), 0, -clampf(foot.y * 0.5 - 0.1, 0.0, 0.36))
		tower_crane(root, cp, clampf(height / MS + 9.0, 18.0, 52.0), float(h % 6), ph)
	if not overlay or stage == "frame":
		_floodlight(root, Vector3(foot.x * 0.5 + 0.06, 0, -foot.y * 0.5 - 0.06))
	# Big parts (frame floors, scaffold faces, the hoarding runs) carry as far as the crane.
	for part in root.find_children("*", "MeshInstance3D", true, false):
		var mi := part as MeshInstance3D
		if mi.mesh != null and mi.visibility_range_end == FAR and (mi.mesh.get_aabb().size * mi.scale).length() > 0.25:
			mi.visibility_range_end = CRANE_FAR
	_bake_colliders(root)
	_apply_progress(root, f)
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
	_apply_progress(site, f)


func _group(p: Node3D, n: String) -> Node3D:
	var g := Node3D.new()
	g.name = n
	p.add_child(g)
	return g


## Marks n (all its meshes, at their built size) as a part of the site being built that blocks a
## walker. Without `arms`, subtrees named "Boom" (the swinging digger and backhoe arms) are left
## out. Colliders are baked once per build and do not follow progress, so parts that progress
## hides or reveals one by one (felled trees, stumps, rebar, debris, planting) are not marked; the
## frame is, since its first floor always stands. Every new blocking part must be marked.
func solid(n: Node3D, arms := true) -> Node3D:
	_solids.append({"n": n, "arms": arms})
	return n


## Marks an explicit blocking box, given in n's frame (the crane's base and mast, not its jib).
func solid_box(n: Node3D, local: AABB) -> void:
	_solids.append({"n": n, "box": local})


## Holder-space AABB of one `colliders` entry: the box of its corners, rotated by yaw about +Y
## around `pos`, the centre of its base.
static func collider_aabb(c: Dictionary) -> AABB:
	var size: Vector3 = c["size"]
	var local := AABB(Vector3(-size.x * 0.5, 0.0, -size.z * 0.5), size)
	return Transform3D(Basis(Vector3.UP, float(c.get("yaw", 0.0))), c["pos"] as Vector3) * local


## Writes the marked parts to the Site root's `colliders` meta, in holder space and at their full
## built size (before progress scales them): [{"shape": "box", "pos": Vector3 (centre of the base),
## "size": Vector3, "yaw": float}]. A shuttling machine's box is stretched over its whole run.
func _bake_colliders(root: Node3D) -> void:
	var holder := root.get_parent()
	var out: Array[Dictionary] = []
	for e: Dictionary in _solids:
		var n: Variant = e["n"]
		if not is_instance_valid(n):
			continue
		var node := n as Node3D
		var local: AABB
		if e.has("box"):
			local = e["box"]
		elif e.has("kind") and _machine_bounds.has(e["kind"]):
			local = _machine_bounds[e["kind"]]
		else:
			local = _swept_bounds(node, bool(e.get("arms", true)), e.get("anims", []))
			if e.has("kind"):
				_machine_bounds[e["kind"]] = local
		if local.size == Vector3.ZERO:
			continue
		var t := _to_holder(node, holder)
		# Box the part in a frame turned by its yaw, so any tilt (a toppling building) stays inside.
		var yaw := atan2(-t.basis.x.z, t.basis.x.x)
		var unyaw := Basis(Vector3.UP, -yaw)
		var box_y := (Transform3D(unyaw, Vector3.ZERO) * t) * local
		var sweep: Vector3 = e.get("sweep", Vector3.ZERO)
		if sweep != Vector3.ZERO:
			var w := unyaw * (_to_holder(node.get_parent() as Node3D, holder).basis * sweep)
			var reach := Vector3(absf(w.x), 0.0, absf(w.z))
			box_y = AABB(box_y.position - reach, box_y.size + reach * 2.0)
		var c := Basis(Vector3.UP, yaw) * box_y.get_center()
		out.append({"shape": "box", "pos": Vector3(c.x, box_y.position.y, c.z), "size": box_y.size, "yaw": yaw})
	root.set_meta("colliders", out)
	_solids.clear()


## Transform from n's frame to the holder's (the product of the transforms in between).
static func _to_holder(n: Node3D, holder: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var x: Node = n
	while x != null and x != holder:
		if x is Node3D:
			t = (x as Node3D).transform * t
		x = x.get_parent()
	return t


## Bounds of n's meshes in n's frame over the poses its own animations reach: a spinning part as
## the cylinder it turns through, swinging and tipping parts ("yaw", "pitch", "tip") sampled
## across their range. Transforms are restored afterwards.
static func _swept_bounds(n: Node3D, arms: bool, anims: Array) -> AABB:
	var spin: Array[Node] = []
	var swing: Array[Dictionary] = []
	for a: Dictionary in anims:
		if not is_instance_valid(a["node"]):
			continue
		if str(a["type"]) == "spin":
			spin.append(a["node"])
		elif str(a["type"]) in ["yaw", "pitch", "tip"]:
			swing.append(a)
	var out := _mesh_bounds(n, arms, spin)
	if swing.is_empty() or out.size == Vector3.ZERO:
		return out
	var saved: Array[Transform3D] = []
	for a: Dictionary in swing:
		saved.append((a["node"] as Node3D).transform)
	for k in range(9):
		var s := float(k) / 4.0 - 1.0
		for a: Dictionary in swing:
			var node := a["node"] as Node3D
			var v := float(a["base"]) + float(a["amp"]) * (maxf(0.0, s) if str(a["type"]) == "tip" else s)
			if str(a["type"]) == "yaw":
				node.rotation.y = v
			else:
				node.rotation.z = v
		out = out.merge(_mesh_bounds(n, arms, spin))
	for j in range(swing.size()):
		(swing[j]["node"] as Node3D).transform = saved[j]
	return out


## Bounds of every mesh under n, in n's frame (size zero when none); without `arms`, "Boom"
## subtrees are skipped. A node in `spin` turns about its local Y, so its subtree counts as the
## square around the circle its corners sweep.
static func _mesh_bounds(n: Node3D, arms: bool, spin: Array[Node] = []) -> AABB:
	var out := AABB()
	var mi := n as MeshInstance3D
	if mi != null and mi.mesh != null:
		out = mi.mesh.get_aabb()
	for ch in n.get_children():
		var c3 := ch as Node3D
		if c3 == null or (not arms and ch.name == &"Boom"):
			continue
		var b := _mesh_bounds(c3, arms, spin)
		if b.size == Vector3.ZERO:
			continue
		if spin.has(ch):
			var r := 0.0
			for x: float in [b.position.x, b.end.x]:
				for z: float in [b.position.z, b.end.z]:
					r = maxf(r, Vector2(x, z).length())
			b = AABB(Vector3(-r, b.position.y, -r), Vector3(2.0 * r, b.size.y, 2.0 * r))
		var a := c3.transform * b
		out = a if out.size == Vector3.ZERO else out.merge(a)
	return out


## Ties part of the site being built to stage progress. Between f0 and f1 the node scales
## from a to b times its built size ("sx", "sy", "sxz"), or shows ("reveal") / removes
## ("hide") its children one by one.
func track(n: Node3D, mode: String, f0 := 0.0, f1 := 1.0, a := 0.0, b := 1.0) -> Node3D:
	var list: Array = _site_root.get_meta("progress", [])
	list.append({"n": n, "m": mode, "f0": f0, "f1": f1, "a": a, "b": b, "s0": n.scale})
	_site_root.set_meta("progress", list)
	return n


func _apply_progress(site: Node3D, f: float) -> void:
	for p: Dictionary in site.get_meta("progress", []):
		var n: Variant = p["n"]
		if not is_instance_valid(n):
			continue
		var node := n as Node3D
		var t := clampf((f - float(p["f0"])) / maxf(float(p["f1"]) - float(p["f0"]), 0.001), 0.0, 1.0)
		# Never scale to zero: a degenerate basis upsets culling and transforms.
		var v := maxf(lerpf(float(p["a"]), float(p["b"]), t), 0.02)
		var s0: Vector3 = p["s0"]
		match str(p["m"]):
			"sx":
				node.scale = Vector3(s0.x * v, s0.y, s0.z)
				node.visible = v > 0.03
			"sy":
				node.scale = Vector3(s0.x, s0.y * v, s0.z)
			"sz":
				node.scale = Vector3(s0.x, s0.y, s0.z * v)
			"sxz":
				node.scale = Vector3(s0.x * v, s0.y, s0.z * v)
			"reveal", "hide":
				var c := node.get_child_count()
				var gone := int(floor(float(c) * t))
				var shown := c - gone if str(p["m"]) == "hide" else int(ceil(float(c) * t))
				for k in range(c):
					var child := node.get_child(k) as Node3D
					if child != null:
						child.visible = k >= gone if str(p["m"]) == "hide" else k < shown


func _ground(root: Node3D, stage: String) -> void:
	var g := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(0.98, 0.98)
	g.mesh = pm
	g.position.y = WS.GROUND_Y + 0.0004 if bool(view.get("fp_mode")) else 0.007
	g.material_override = view.call("_pbr", "dirt", Color(0.38, 0.3, 0.22), 1.0) if stage != "landscaping" else mat("soil")
	root.add_child(g)


## Site hoarding with a gate gap on one side: blue boards in orbit; on foot 2.2 m of painted plywood
## whose segment on the frontage side (`front`, toward the lot's frontage road) carries D's
## `poster_slot`.
func _fence(root: Node3D, h: int, front: Vector2i = Vector2i.ZERO) -> void:
	var gate := h % 4
	var fp := bool(view.get("fp_mode"))
	var hh := HOARDING_H_FP if fp else HOARDING_H
	var m := "hoarding_fp_%d" % ((h >> 5) % 3) if fp else "hoarding"
	var sides := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	for k in range(4):
		var along := Vector3(0.94, hh, 0.008) if k % 2 == 0 else Vector3(0.008, hh, 0.94)
		var pos := Vector3(sides[k].x * 0.47, hh * 0.5, sides[k].y * 0.47)
		var seg: MeshInstance3D = null
		if k == gate:
			var half := Vector3(along.x * 0.35, along.y, along.z * 0.35)
			var off := Vector3(0.3, 0, 0) if k % 2 == 0 else Vector3(0, 0, 0.3)
			solid(box(root, half, pos - off, m, Vector3.ZERO, fp))
			seg = solid(box(root, half, pos + off, m, Vector3.ZERO, fp)) as MeshInstance3D
		else:
			seg = solid(box(root, along, pos, m, Vector3.ZERO, fp)) as MeshInstance3D
		if fp and sides[k] == front:
			_poster_slot(seg, Vector2(front), hh)


## D's hoarding poster on segment seg: 3 m x 1.5 m on its outer face, facing out toward dv.
func _poster_slot(seg: MeshInstance3D, dv: Vector2, hh: float) -> void:
	var face := Basis(Vector3.UP, atan2(dv.x, dv.y))
	var out := Vector3(dv.x, 0, dv.y) * (0.004 + 0.0004)
	seg.name = "HoardingFront"
	seg.set_meta("poster_slot", {"kind": "hoarding", "size": Vector2(3.0, 1.5) * WS.M, "xform": Transform3D(face, out + Vector3(0, hh * 0.05, 0))})


func _floodlight(root: Node3D, pos: Vector3) -> void:
	solid(box(root, Vector3(0.012, 0.42, 0.012), pos + Vector3(0, 0.21, 0), "steel", Vector3.ZERO, false))
	var head := box(root, Vector3(0.05, 0.025, 0.03), pos + Vector3(0, 0.43, 0), "paint_dark", Vector3.ZERO, false)
	var bulb := box(root, Vector3(0.045, 0.006, 0.026), pos + Vector3(0, 0.416, 0), "white", Vector3.ZERO, false)
	bulb.name = "Bulb_site"
	head.name = "FloodHead"


## Concrete columns and floor slabs from base_h up to top_h, one child node per floor.
func _frame(root: Node3D, foot: Vector2, base_h: float, top_h: float, f: float) -> void:
	var frame := Node3D.new()
	frame.name = "Frame"
	root.add_child(frame)
	solid(frame)
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
func _scaffold(root: Node3D, foot: Vector2, height: float, roll_net: bool) -> void:
	var sc := Node3D.new()
	sc.name = "Scaffold"
	root.add_child(sc)
	solid(sc)
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
	# Netting hangs from the top lift and is rolled up as the facade is finished.
	var net := _group(sc, "Net")
	net.position.y = top
	box(net, Vector3(hx * 2.0, top, 0.003), Vector3(0, -top * 0.5, hz + 0.004), "net", Vector3.ZERO, false)
	box(net, Vector3(0.003, top, hz * 2.0), Vector3(hx + 0.004, -top * 0.5, 0), "net", Vector3.ZERO, false)
	if roll_net:
		track(net, "sy", 0.0, 1.0, 1.0, 0.15)


## Fresh asphalt laid from one end of the tile to the other as paving progresses.
func _paving(root: Node3D, w: float, t: float, y: float) -> void:
	var lay := _group(root, "Asphalt")
	lay.position = Vector3(0, y, -0.5)
	box(lay, Vector3(w, t, 1.0), Vector3(0, 0, 0.5), "asphalt_fresh", Vector3.ZERO, false)
	track(lay, "sz", 0.0, 1.0, 0.05, 1.0)


func _road_site(root: Node3D, stage: String, ctx: Dictionary, ph: float) -> void:
	# Pieces are laid out running north-south; east-west roads turn the whole site.
	if str(ctx.get("axis", "z")) == "x":
		root.rotation.y = PI * 0.5
	var water := bool(ctx.get("water", false))
	if water:
		for z in [-0.28, 0.28]:
			for x in [-0.22, 0.22]:
				var pier := _group(root, "Pier")
				pier.position = Vector3(x, -0.3, z)
				cyl(pier, 0.035, 0.32, Vector3(0, 0.16, 0), "concrete")
				if stage == "piling":
					track(pier, "sy", 0.0, 1.0, 0.25, 1.0)
		if stage == "piling":
			solid(box(root, Vector3(0.03, 0.55, 0.03), Vector3(0.0, 0.2, 0.0), "paint"))
			box(root, Vector3(0.05, 0.08, 0.05), Vector3(0.0, 0.35, 0.0), "paint_dark")
			machine("backhoe", root, Vector3(0.0, 0.0, -0.42), -PI * 0.5, ph)
		else:
			box(root, Vector3(0.62, 0.05, 1.0), Vector3(0, 0.0, 0), "concrete")
			if stage == "paving":
				_paving(root, 0.5, 0.012, 0.031)
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
			solid(cyl(root, 0.012, 0.035, Vector3(x, 0.018, z), "cone", Vector3.ZERO, 0.002))
	match stage:
		"clearing":
			var dz := machine("bulldozer", root, Vector3(0, 0, 0), -PI * 0.5, ph)
			shuttle(dz, Vector3.BACK, 0.32, 0.45, ph)
		"grading":
			var dz2 := machine("bulldozer", root, Vector3(0.08, 0, 0), -PI * 0.5, ph)
			shuttle(dz2, Vector3.BACK, 0.3, 0.4, ph)
			solid(mound(root, 0.06, 0.03, Vector3(-0.2, 0, 0.3), "gravel"))
		"paving":
			_paving(root, 0.56, 0.008, 0.014)
			var rl2 := machine("roller", root, Vector3(0, 0, -0.1), -PI * 0.5, ph)
			shuttle(rl2, Vector3.BACK, 0.25, 0.7, ph)
