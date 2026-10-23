extends RefCounted
## Draws E's agents (docs/fp/slices/E-traffic.md §3 Draw calls). Vehicles: the full GLB only
## within NEAR of the camera (pooled per model, capped), beyond that one MultiMeshInstance3D per
## model built from a single-surface, vertex-coloured merge of the GLB (H's <name>_lod1.glb when it
## exists), with shadows to SHADOW_DIST and none beyond. Parked cars go through a static layer
## rebuilt only when the parked set changes or the camera moves. Brake lights, siren flashes and
## wheel spin on full models, and their indicators blink (indicators.gd); after dark their head
## and tail lamps light up, the nearest moving
## vehicles throw headlight beams, and the head and tail lamps of the merged ones glow. Responding
## crews near the camera wash their surroundings in flashing siren light. A car with its driver's
## door open (the player's) swings it out on a hinge cut from its body (car_doors.gd).
## People (the legacy static bodies, until HC's rigged ones): every distance draws the merged body
## through the people shader, which swings the legs and arms from per-instance stride data and
## dithers people in and out (spawned in view, or at the edge of VIS_PERSON). Same geometry and
## colours as the GLB, one draw per body model and layer.

const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const KIT := preload("res://scripts/fp/traffic/mesh_kit.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const DOORS := preload("res://scripts/fp/traffic/car_doors.gd")
const IND := preload("res://scripts/fp/traffic/indicators.gd")
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
## Stride swing of the people shader, radians at full stride (legs; arms swing opposite).
const LEG_SWING := 0.38
const ARM_SWING := 0.3
## People fade out over this last stretch before VIS_PERSON.
const PERSON_FADE := 0.4
## Merged meshes flag lamp vertices (emissive source materials) with this vertex alpha.
const LAMP_ALPHA := 0.5
## Lamps count as on above this darkness (sky night 0..1).
const LAMPS_ON := 0.35
## Headlight beams after dark: spot lights on the moving vehicles nearest the camera (no shadows).
const BEAMS := 8
const BEAM_DIST := 4.0
const BEAM_RANGE := 34.0 * WS.M
const BEAM_ANGLE := 30.0
const BEAM_ENERGY := 2.4
## Distance falloff exponent of a beam: gentler than inverse distance, so someone standing in
## front of a waiting car is lit, not blown out, while the road 10-30 m ahead still gets a pool.
const BEAM_DECAY := 0.5
const BEAM_HEIGHT := 0.65 * WS.M
## Siren light washes: flashing omni lights on responding crews near the camera.
const WASHES := 3
const WASH_DIST := 3.0
const WASH_RANGE := 14.0 * WS.M
## Car paint (the full models' Paint_* materials): a lacquer clear coat over the base, its
## roughness from PAINT_COAT dry to PAINT_COAT_WET soaked; the wet base darkens by PAINT_WET_DARK
## and turns PAINT_WET_GLOSS smoother. The merged bodies' roughness goes to LOD_WET_ROUGH soaked.
const PAINT_COAT := 0.1
const PAINT_COAT_WET := 0.03
const PAINT_WET_DARK := 0.85
const PAINT_WET_GLOSS := 0.6
const LOD_WET_ROUGH := 0.2
const PEOPLE_SHADER := """
shader_type spatial;
render_mode cull_back, depth_draw_opaque;
// INSTANCE_CUSTOM: x stride phase (radians), y stride amount 0..1, z body height (mesh units),
// w opacity 0..1. Legacy bodies face +Z; legs hang below 0.54 h inside |x| < 0.105 h, arms
// outside it from the shoulders (0.8 h) down to the hands.
uniform float leg_swing = 0.38;
uniform float arm_swing = 0.3;
uniform float rough = 0.78;
varying float v_fade;

vec3 rot_x(vec3 v, float pivot, float a) {
	float c = cos(a);
	float s = sin(a);
	float dy = v.y - pivot;
	return vec3(v.x, pivot + dy * c - v.z * s, dy * s + v.z * c);
}

void vertex() {
	float h = max(INSTANCE_CUSTOM.z, 1e-5);
	float sw = sin(INSTANCE_CUSTOM.x) * INSTANCE_CUSTOM.y;
	float hy = VERTEX.y / h;
	float ax = abs(VERTEX.x) / h;
	float side = VERTEX.x >= 0.0 ? 1.0 : -1.0;
	float a = 0.0;
	float pivot = 0.0;
	if (ax < 0.105 && hy < 0.54) {
		a = side * leg_swing * sw * smoothstep(0.54, 0.44, hy);
		pivot = 0.5 * h;
	} else if (ax >= 0.105 && hy > 0.36 && hy < 0.85) {
		a = -side * arm_swing * sw * smoothstep(0.82, 0.72, hy);
		pivot = 0.8 * h;
	}
	VERTEX = rot_x(VERTEX, pivot, a);
	NORMAL = rot_x(NORMAL, 0.0, a);
	v_fade = INSTANCE_CUSTOM.w;
}

void fragment() {
	if (v_fade < 0.999) {
		float n = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
		if (n >= v_fade) {
			discard;
		}
	}
	ALBEDO = pow(COLOR.rgb, vec3(2.2));
	ROUGHNESS = rough;
}
"""
const VEHICLE_SHADER := """
shader_type spatial;
render_mode cull_back;
// Merged vehicle bodies: vertex colour is the source material's albedo (sRGB); alpha < 0.75 marks
// a lamp (head, tail, sign) that glows by `glow` (0 by day, 1 at night).
uniform float glow = 0.0;
uniform float rough = 0.5;
uniform float metal = 0.15;
// How wet the streets are (0..1): the bodies darken a little and turn glossy.
uniform float wet = 0.0;
uniform float wet_rough = 0.2;
uniform float wet_dark = 0.85;

void fragment() {
	vec3 c = pow(COLOR.rgb, vec3(2.2));
	ALBEDO = c * mix(1.0, wet_dark, wet);
	ROUGHNESS = mix(rough, wet_rough, wet);
	METALLIC = metal;
	if (COLOR.a < 0.75) {
		EMISSION = c * glow * 6.0;
	}
}
"""


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
	var custom: Array = [[], [], [], []]  # people: Color per instance (phase, stride, height, opacity)
	var pool: Array[Node3D] = []
	var person: bool = false
	var mesh_h: float = 0.09              # body height in mesh units (people shader)
	var offset := Transform3D.IDENTITY    # scale and recentring applied after the agent transform


var root: Node3D
var models: Array = []
var _by_key: Dictionary = {}
var _lod_mat: ShaderMaterial
## Parked cars: the same shader with the lamps off.
var _lod_static_mat: ShaderMaterial
var _people_mat: ShaderMaterial
var _brake_mat: StandardMaterial3D
## Full models after dark: head lamps and tail lamps lit (per-instance surface overrides).
var _head_mat: StandardMaterial3D
var _tail_mat: StandardMaterial3D
## A blinking indicator's lit lamps (amber).
var _ind_mat: StandardMaterial3D
var _beams: Array[SpotLight3D] = []
var _washes: Array[OmniLight3D] = []
## This frame's candidates: [distance, transform, length] for beams, [distance, transform, siren
## kind, height] for siren washes.
var _beam_cands: Array = []
var _wash_cands: Array = []
var beams_on: int = 0
var washes_on: int = 0
var _siren_mats: Dictionary = {}
var _siren_dark: StandardMaterial3D
var _made_this_frame: int = 0
var full_vehicles: int = 0
var full_people: int = 0
var full_static: int = 0
var draws_people: int = 0
var draws_vehicles: int = 0
var time: float = 0.0
var _last_lod: int = -1
var _glow: float = 0.0
## Paint_* material -> its dry [albedo, roughness]; how wet the cars are now.
var _paints: Dictionary = {}
var _wet: float = 0.0


func setup(p_root: Node3D) -> void:
	root = p_root
	var vs := Shader.new()
	vs.code = VEHICLE_SHADER
	_lod_mat = ShaderMaterial.new()
	_lod_mat.shader = vs
	_lod_static_mat = ShaderMaterial.new()
	_lod_static_mat.shader = vs
	for lm: ShaderMaterial in [_lod_mat, _lod_static_mat]:
		lm.set_shader_parameter("wet_rough", LOD_WET_ROUGH)
		lm.set_shader_parameter("wet_dark", PAINT_WET_DARK)
	var ps := Shader.new()
	ps.code = PEOPLE_SHADER
	_people_mat = ShaderMaterial.new()
	_people_mat.shader = ps
	_people_mat.set_shader_parameter("leg_swing", LEG_SWING)
	_people_mat.set_shader_parameter("arm_swing", ARM_SWING)
	_brake_mat = StandardMaterial3D.new()
	_brake_mat.albedo_color = Color(0.9, 0.05, 0.03)
	_brake_mat.emission_enabled = true
	_brake_mat.emission = Color(1.0, 0.05, 0.02)
	_brake_mat.emission_energy_multiplier = 5.0
	_head_mat = StandardMaterial3D.new()
	_head_mat.albedo_color = Color(1.0, 0.98, 0.92)
	_head_mat.emission_enabled = true
	_head_mat.emission = Color(1.0, 0.94, 0.82)
	_head_mat.emission_energy_multiplier = 10.0
	_tail_mat = StandardMaterial3D.new()
	_tail_mat.albedo_color = Color(0.55, 0.03, 0.02)
	_tail_mat.emission_enabled = true
	_tail_mat.emission = Color(1.0, 0.06, 0.03)
	_tail_mat.emission_energy_multiplier = 2.2
	_ind_mat = StandardMaterial3D.new()
	_ind_mat.albedo_color = Color(1.0, 0.55, 0.08)
	_ind_mat.emission_enabled = true
	_ind_mat.emission = Color(1.0, 0.45, 0.02)
	_ind_mat.emission_energy_multiplier = 6.0
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
	_siren_dark = StandardMaterial3D.new()
	_siren_dark.albedo_color = Color(0.25, 0.22, 0.24)
	_siren_dark.roughness = 0.3


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
	if not person:
		_lacquer(inst)
	var bb := _bounds(inst, Transform3D.IDENTITY)
	m.size = bb.size * scale
	m.mesh_h = bb.size.y
	m.center = Vector3(bb.get_center().x, 0, bb.get_center().z) * scale
	m.offset = Transform3D(Basis.from_scale(Vector3.ONE * scale), -m.center)
	# H's single-material far LOD when present, else a merge of the full model.
	var lod_path := path.get_basename() + "_lod1.glb"
	var lod_ps := AP.load_scene(lod_path) if ResourceLoader.exists(lod_path) else null
	var kit: KIT = KIT.new()
	kit.begin()
	kit.lamp_alpha = LAMP_ALPHA
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
		mm.use_custom_data = m.person
		mm.mesh = m.lod_mesh
		mm.instance_count = 0
		mmi.multimesh = mm
		if m.person:
			mmi.material_override = _people_mat
		else:
			mmi.material_override = _lod_static_mat if (k == L_SMID or k == L_SFAR) else _lod_mat
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
		(m.custom[L_MID] as Array).clear()
		(m.custom[L_FAR] as Array).clear()


## Lamp glow of the merged vehicles (0 by day, 1 at night).
func set_glow(g: float) -> void:
	if _lod_mat != null and absf(g - _glow) > 0.004:
		_glow = g
		_lod_mat.set_shader_parameter("glow", g)


## How wet the streets are (0..1): the paint of every car and the merged bodies follow.
func set_wet(w: float) -> void:
	w = clampf(w, 0.0, 1.0)
	if absf(w - _wet) < 0.004 and (w > 0.0 or _wet == 0.0):
		return
	_wet = w
	for lm: ShaderMaterial in [_lod_mat, _lod_static_mat]:
		if lm != null:
			lm.set_shader_parameter("wet", w)
	for p: StandardMaterial3D in _paints.keys():
		_wet_paint(p)


## The clear coat on every Paint_* surface of a model (the imported materials, shared by every car
## of that model), wet to how wet the streets are now.
func _lacquer(n: Node) -> void:
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		var mesh := (mi as MeshInstance3D).mesh
		for s in range(mesh.get_surface_count() if mesh != null else 0):
			var p := mesh.surface_get_material(s) as StandardMaterial3D
			if p == null or not p.resource_name.begins_with("Paint_") or _paints.has(p):
				continue
			_paints[p] = [p.albedo_color, p.roughness]
			p.clearcoat_enabled = true
			p.clearcoat = 1.0
			_wet_paint(p)


func _wet_paint(p: StandardMaterial3D) -> void:
	var dry: Array = _paints[p]
	var c: Color = dry[0]
	var k := lerpf(1.0, PAINT_WET_DARK, _wet)
	p.albedo_color = Color(c.r * k, c.g * k, c.b * k, c.a)
	p.roughness = lerpf(float(dry[1]), float(dry[1]) * PAINT_WET_GLOSS, _wet)
	p.clearcoat_roughness = lerpf(PAINT_COAT, PAINT_COAT_WET, _wet)


## Starts a rebuild of the static (parked) layer.
func begin_static() -> void:
	full_static = 0
	for m: Model in models:
		(m.lists[L_SMID] as Array).clear()
		(m.lists[L_SFAR] as Array).clear()


## blink: the side its indicators signal (indicators.gd side()).
func draw_car(c: VH.Car, xf: Transform3D, d: float, vis_end: float, brake: bool, siren: String, spin: float, blink: int = 0) -> void:
	c.node = _place(c.model, c.node, c.lod, xf, d, vis_end, false)
	c.lod = _last_lod
	var lit := _glow > LAMPS_ON
	if c.lod == 0:
		# A pooled node keeps its cut door: shut it again for the next car of its model.
		if c.door > 0.0 or c.node.has_meta("door"):
			var m := model(c.model)
			DOORS.pose(c.node, DOORS.of(m.key, m.scene), c.door)
		_extras(c.node, model(c.model), brake, lit, siren, spin)
		_blink(c.node, blink)
	if c.lod >= 0:
		if lit and d < BEAM_DIST and c.kind != "bike":
			_beam_cands.append([d, xf, c.length])
		if _siren_mats.has(siren) and d < WASH_DIST:
			_wash_cands.append([d, xf, siren, c.height])


## A parked car into the static layer (between begin_static and finish_static).
func draw_parked(c: VH.Car, xf: Transform3D, d: float, vis_end: float) -> void:
	c.node = _place(c.model, c.node, c.lod, xf, d, vis_end, true)
	c.lod = _last_lod
	if c.lod == 0:
		full_static += 1
		_extras(c.node, model(c.model), false, false, "", 0.0)
		_blink(c.node, IND.NONE)


## A person: always the merged body through the people shader (stride and opacity per instance).
func draw_walker(w: WK.Walker, xf: Transform3D, d: float, vis_end: float, phase: float = 0.0) -> void:
	var m: Model = model(w.model)
	if m == null or not m.person:
		w.node = _place(w.model, w.node, w.lod, xf, d, vis_end, false)
		w.lod = _last_lod
		return
	if w.node != null:
		_release_node(m, w.node)
		w.node = null
	var op := minf(w.fade, clampf((vis_end - d) / PERSON_FADE, 0.0, 1.0))
	if op <= 0.0 or m.lod_mesh == null:
		w.lod = -1
		return
	var layer := L_MID if d < SHADOW_DIST else L_FAR
	(m.lists[layer] as Array).append(xf * m.offset)
	(m.custom[layer] as Array).append(Color(fposmod(phase, TAU), w.gait, m.mesh_h, op))
	w.lod = 1 if layer == L_MID else 2


## Places one agent; returns its full node (or null) and sets _last_lod (-1 hidden, 0 full, 1 mid,
## 2 far).
func _place(mi: int, node: Node3D, lod: int, xf: Transform3D, d: float, vis_end: float, is_static: bool) -> Node3D:
	var m: Model = model(mi)
	if m == null or d > vis_end:
		_release_node(m, node)
		_last_lod = -1
		return null
	var want_full := m.scene != null and not m.person and (d < NEAR or (lod == 0 and d < NEAR_OUT))
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
			if mat != null and mat.resource_name == "Light_Head":
				n.set_meta("head", [mi, s])
			if mat != null and mat.resource_name in ["Light_Indicator_L", "Light_Indicator_R"]:
				n.set_meta("ind_" + mat.resource_name.right(1).to_lower(), [mi, s])
			if mat != null and mat.resource_name.begins_with("Siren"):
				if not n.has_meta("siren_surf"):
					n.set_meta("siren_surf", [])
				(n.get_meta("siren_surf") as Array).append([mi, s])
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


func _extras(node: Node3D, m: Model, brake: bool, lit: bool, siren: String, spin: float) -> void:
	if node == null or m == null:
		return
	# Lamps: brake lights, and head and tail lamps after dark (0 is the imported state).
	var key := (1 if brake else 0) + (2 if lit else 0)
	if int(node.get_meta("lamp_key", 0)) != key:
		node.set_meta("lamp_key", key)
		if node.has_meta("tail"):
			var tail: Array = node.get_meta("tail")
			var tm: Material = _brake_mat if brake else (_tail_mat if lit else null)
			(tail[0] as MeshInstance3D).set_surface_override_material(int(tail[1]), tm)
		if node.has_meta("head"):
			var head: Array = node.get_meta("head")
			(head[0] as MeshInstance3D).set_surface_override_material(int(head[1]), _head_mat if lit else null)
	if node.has_meta("sirens"):
		var on := _siren_mats.has(siren)
		var sirens: Array = node.get_meta("sirens")
		var flash := int(time * 6.0) % 2
		for j in range(sirens.size()):
			var s: MeshInstance3D = sirens[j]
			s.material_override = (_siren_mats[siren][(j + flash) % 2] as Material) if on else null
	if node.has_meta("siren_surf"):
		# Legacy models: siren lamps are surfaces; they flash in two alternating banks while the
		# crew responds and stay dark otherwise.
		var on := _siren_mats.has(siren)
		var flash := int(time * 6.0) % 2
		var skey := (flash + 1) if on else 0
		if int(node.get_meta("siren_key", -1)) != skey:
			node.set_meta("siren_key", skey)
			var list: Array = node.get_meta("siren_surf")
			for j in range(list.size()):
				var e: Array = list[j]
				var bank := on and (j + flash) % 2 == 0
				var mat: Material = (_siren_mats[siren][j % 2] as Material) if bank else _siren_dark
				(e[0] as MeshInstance3D).set_surface_override_material(int(e[1]), mat)
	if node.has_meta("wheels"):
		var r: float = node.get_meta("wheel_r")
		var ang := spin / (r * m.scale)
		for w: Node3D in node.get_meta("wheels"):
			w.rotation.x = fposmod(ang, TAU)


## Indicators: the left and right lamps lit or dark for a car signalling side now.
func _blink(node: Node3D, side: int) -> void:
	if node == null:
		return
	var l := IND.on(side, IND.LEFT, time)
	var r := IND.on(side, IND.RIGHT, time)
	var key := (1 if l else 0) + (2 if r else 0)
	if int(node.get_meta("ind_key", 0)) == key:
		return
	node.set_meta("ind_key", key)
	for e: Array in [["ind_l", l], ["ind_r", r]]:
		if node.has_meta(e[0]):
			var surf: Array = node.get_meta(e[0])
			var mat: Material = _ind_mat if e[1] else null
			(surf[0] as MeshInstance3D).set_surface_override_material(int(surf[1]), mat)


## Writes the moving MultiMesh layers for this frame, and aims the headlight beams and siren
## washes at the nearest candidates.
func finish() -> void:
	for m: Model in models:
		_fill(m.mms[L_MID], m.lists[L_MID], m.custom[L_MID])
		_fill(m.mms[L_FAR], m.lists[L_FAR], m.custom[L_FAR])
	_count_draws()
	_place_beams()
	_place_washes()


## Headlight beams: one spot per vehicle (both lamps), low and tipped a little down, lighting the
## road ahead of the nearest moving vehicles after dark.
func _place_beams() -> void:
	var n := 0
	if _glow > LAMPS_ON and root != null and root.is_inside_tree():
		_beam_cands.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
		var e := BEAM_ENERGY * clampf((_glow - LAMPS_ON) / 0.3, 0.0, 1.0)
		for cand: Array in _beam_cands:
			if n >= BEAMS:
				break
			var xf: Transform3D = cand[1]
			var fwd := xf.basis.z.normalized()
			var l := _beam(n)
			var p := xf.origin + fwd * (float(cand[2]) * 0.5) + Vector3(0, BEAM_HEIGHT, 0)
			l.transform = Transform3D(Basis.looking_at((fwd + Vector3(0, -0.09, 0)).normalized(), Vector3.UP), p)
			l.light_energy = e
			l.visible = true
			n += 1
	for k in range(n, _beams.size()):
		_beams[k].visible = false
	beams_on = n
	_beam_cands.clear()


func _beam(k: int) -> SpotLight3D:
	while _beams.size() <= k:
		var l := SpotLight3D.new()
		l.name = "Beam%d" % _beams.size()
		l.light_color = Color(1.0, 0.93, 0.8)
		l.spot_range = BEAM_RANGE
		l.spot_angle = BEAM_ANGLE
		l.spot_angle_attenuation = 0.6
		l.spot_attenuation = BEAM_DECAY
		l.light_specular = 0.6
		l.shadow_enabled = false
		l.visible = false
		root.add_child(l)
		_beams.append(l)
	return _beams[k]


## Siren washes: a flashing omni light over each responding crew near the camera, alternating
## the two siren colours with the lamps.
func _place_washes() -> void:
	var n := 0
	if not _wash_cands.is_empty() and root != null and root.is_inside_tree():
		_wash_cands.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
		var flash := int(time * 6.0) % 2
		for cand: Array in _wash_cands:
			if n >= WASHES:
				break
			var xf: Transform3D = cand[1]
			var l := _wash(n)
			l.transform = Transform3D(Basis(), xf.origin + Vector3(0, float(cand[3]) + 0.4 * WS.M, 0))
			l.light_color = (SIREN_COLS[str(cand[2])] as Array)[(flash + n) % 2]
			l.light_energy = 0.5 + 0.9 * _glow
			l.visible = true
			n += 1
	for k in range(n, _washes.size()):
		_washes[k].visible = false
	washes_on = n
	_wash_cands.clear()


func _wash(k: int) -> OmniLight3D:
	while _washes.size() <= k:
		var l := OmniLight3D.new()
		l.name = "Siren%d" % _washes.size()
		l.omni_range = WASH_RANGE
		l.omni_attenuation = 1.0
		l.shadow_enabled = false
		l.visible = false
		root.add_child(l)
		_washes.append(l)
	return _washes[k]


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
	draws_vehicles += (full_vehicles + full_static) * 11


func _fill(mmi: Variant, list: Array, custom: Array = []) -> void:
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
	if mm.use_custom_data:
		for k in range(mini(custom.size(), list.size())):
			mm.set_instance_custom_data(k, custom[k])
	mm.visible_instance_count = list.size()
	mmn.visible = true


## Frees every pooled and live node; the paint dries.
func clear() -> void:
	set_wet(0.0)
	_paints.clear()
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
	for l: Node in _beams:
		if is_instance_valid(l):
			l.queue_free()
	for l: Node in _washes:
		if is_instance_valid(l):
			l.queue_free()
	_beams.clear()
	_washes.clear()
	_beam_cands.clear()
	_wash_cands.clear()
