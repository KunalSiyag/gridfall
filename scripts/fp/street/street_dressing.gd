extends RefCounted
## Street-level dressing that CityView adds to its tile holders in fp_mode (slice G1): furniture and
## street trees on road sidewalks, street-name signs at junctions, road wear and puddle decals,
## crosswalk ramps, sidewalk aprons in front of lots, vacant lots with lease boards and billboards,
## the bus shelter, and the street-level glass and leaf materials.
##
## Every blocking item is listed in its holder's `colliders` meta (holder-local, `pos` = centre of the
## base) before tile_built fires, and every prop root carries `prop` meta. Frequent small items are
## batched per CHUNK x CHUNK tiles into MultiMeshes under CityView's StreetProps root; flush() rebuilds
## the chunks whose tiles changed.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const PROPS := "res://models/real/props/"
const DECALS := "res://textures/real/decals/"
const CHUNK := 8
## Band centres, from the road centreline (WS.CURB_FURNITURE and WS.FRONT_FURNITURE).
const CURB := 0.325
const FRONT := 0.4525
## Along-run slots on a straight sidewalk, 5 m and 6 m apart.
const CURB_SLOTS := [-0.375, -0.125, 0.125, 0.375]
const FRONT_SLOTS := [-0.3, 0.0, 0.3]
## Lit straights: the baked lamp poles, (across, along) in the piece frame (roads.py:166-167).
const LAMP_POLES := [Vector2(-0.34, 0.25), Vector2(0.34, -0.25)]
## Batched kinds: model path (or "" for a procedural kit) and the collider override
## (r > 0: a cylinder of that radius; r == 0: the kit's bounding box; r < 0: walkable, none).
const KITS := {
	"tree": [PROPS + "tree_small.glb", 0.009],
	"pit": ["", -1.0],
	"bench": [PROPS + "bench_modern.glb", 0.0],
	"bench_park": [PROPS + "bench_park.glb", 0.0],
	"bin": [PROPS + "trash_bin.glb", 0.0],
	"bollard": [PROPS + "bollard.glb", 0.0062],
	"hydrant": [PROPS + "hydrant.glb", 0.0075],
	"mailbox": [PROPS + "mailbox.glb", 0.0],
	"planter": [PROPS + "planter_round.glb", 0.0],
	"utility": [PROPS + "utility_box.glb", 0.0],
	"rack": [AP.BIKE_RACK, 0.0],
	"meter": [AP.PARKING_METER, 0.004],
	"ramp": [AP.CROSSWALK_RAMP, -1.0],
}
## Kinds that stay visible out to the fog (street trees); the rest end at WS.VIS_PROP.
const FAR_KINDS := ["tree", "pit"]
const SIGN_GREEN := Color(0.02, 0.36, 0.2)

var view: CityView
var root: Node3D
## Tile -> Array of [kind: String, world xform: Transform3D] for the batched items on it.
var _placed: Dictionary = {}
## Chunk Vector2i -> Array[MultiMeshInstance3D]; dirty chunks rebuild on flush().
var _chunks: Dictionary = {}
var _dirty: Dictionary = {}
## Kind -> {"parts": Array, "aabb": AABB}.
var _kits: Dictionary = {}
var _mats: Dictionary = {}
var _decal_tex: Dictionary = {}
## Live puddle decals (they follow the wetness); pruned when their holder goes.
var _puddles: Array[Decal] = []
var wetness: float = 0.0


func _init(p_view: CityView) -> void:
	view = p_view
	root = Node3D.new()
	root.name = "StreetProps"
	view.add_child(root)


# ------------------------------------------------------------------ batching

## Drops the batched items of tile i (its holder is being rebuilt or cleared).
func forget(i: int) -> void:
	if _placed.has(i):
		_placed.erase(i)
		_dirty[_chunk_key(D.tx(i), D.ty(i))] = true


## Rebuilds the MultiMeshes of every chunk whose tiles changed since the last flush.
func flush() -> void:
	if _dirty.is_empty():
		return
	for c: Vector2i in _dirty.keys():
		_build_chunk(c)
	_dirty.clear()
	var live: Array[Decal] = []
	for d in _puddles:
		if is_instance_valid(d) and not d.is_queued_for_deletion():
			live.append(d)
	_puddles = live


## Number of batched items placed on tile i (tests).
func placed_count(i: int) -> int:
	return (_placed.get(i, []) as Array).size()


## The batched placements on tile i: Array of [kind, world Transform3D] (tests, A's debugging).
func placements(i: int) -> Array:
	return _placed.get(i, [])


func _chunk_key(x: int, y: int) -> Vector2i:
	return Vector2i(floori(float(x) / CHUNK), floori(float(y) / CHUNK))


func _build_chunk(c: Vector2i) -> void:
	for n: Node in _chunks.get(c, []):
		if is_instance_valid(n):
			n.queue_free()
	_chunks.erase(c)
	var by_kind: Dictionary = {}
	for ty in range(c.y * CHUNK, c.y * CHUNK + CHUNK):
		for tx in range(c.x * CHUNK, c.x * CHUNK + CHUNK):
			if not D.in_bounds(tx, ty):
				continue
			for e: Array in _placed.get(D.idx(tx, ty), []):
				if not by_kind.has(e[0]):
					by_kind[e[0]] = []
				(by_kind[e[0]] as Array).append(e[1])
	var made: Array = []
	var centre := Vector3((c.x + 0.5) * CHUNK, 0.0, (c.y + 0.5) * CHUNK)
	for kind: String in by_kind.keys():
		var kit: Dictionary = _kit(kind)
		var spots: Array = by_kind[kind]
		for part: Dictionary in kit["parts"]:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = part["mesh"]
			mm.instance_count = spots.size()
			var pxf: Transform3D = part["xform"]
			for k in range(spots.size()):
				var t: Transform3D = spots[k]
				mm.set_instance_transform(k, Transform3D(t.basis, t.origin - centre) * pxf)
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.position = centre
			if part.get("mat") != null:
				mmi.material_override = part["mat"]
			var far := kind in FAR_KINDS
			mmi.visibility_range_end = (WS.FOG_DEPTH_BEGIN if far else WS.VIS_PROP) * view.vis_mult + CHUNK * 0.7
			mmi.visibility_range_end_margin = 1.0
			mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if kind == "tree" else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mmi.set_meta("street_kind", kind)
			root.add_child(mmi)
			made.append(mmi)
	if not made.is_empty():
		_chunks[c] = made


## Adds one batched item of `kind` on tile i at holder-local `pos`, facing `face` (unit xz direction
## its front +Z turns to), and appends its collider to `cols`.
func _put(i: int, kind: String, pos: Vector3, face: Vector2, cols: Array, scale: float = 1.0) -> void:
	var kit: Dictionary = _kit(kind)
	if (kit["parts"] as Array).is_empty():
		return
	var yaw := atan2(face.x, face.y)
	var basis := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale)
	var world := Transform3D(basis, pos + Vector3(D.tx(i), 0.0, D.ty(i)))
	if not _placed.has(i):
		_placed[i] = []
	(_placed[i] as Array).append([kind, world])
	_dirty[_chunk_key(D.tx(i), D.ty(i))] = true
	var r: float = KITS[kind][1]
	if r < 0.0:
		return
	var bb: AABB = kit["aabb"]
	if r > 0.0:
		cols.append({"shape": "cyl", "pos": pos, "r": r * scale, "h": bb.end.y * scale, "yaw": yaw, "kind": kind})
	else:
		var c := Basis(Vector3.UP, yaw) * (Vector3(bb.get_center().x, 0.0, bb.get_center().z) * scale)
		cols.append({"shape": "box", "pos": pos + c, "size": bb.size * scale, "yaw": yaw, "kind": kind})


func _kit(kind: String) -> Dictionary:
	if _kits.has(kind):
		return _kits[kind]
	var parts: Array = []
	var path: String = KITS[kind][0]
	var ps: PackedScene = null
	if path.begins_with(AP.STREET_DIR):
		ps = AP.load_scene(path)
	elif not path.is_empty():
		ps = view._scene(path)
	if ps != null:
		var inst := ps.instantiate() as Node3D
		view._collect_meshes(inst, Transform3D(), parts)
		inst.free()
		if kind == "tree":
			parts = fp_tree_parts(parts)
	if parts.is_empty():
		parts = _procedural_kit(kind)
	var bb := AABB()
	for p: Dictionary in parts:
		var a: AABB = (p["xform"] as Transform3D) * (p["mesh"] as Mesh).get_aabb()
		bb = a if bb.size == Vector3.ZERO else bb.merge(a)
	_kits[kind] = {"parts": parts, "aabb": bb}
	return _kits[kind]


# ------------------------------------------------------------------ roads

## Furniture, signs, ramps and decals for road tile i (holder-local). kind_name is CityView's piece
## name (straight, lights, corner, tee, cross, end, bridge); model is the road GLB instance.
func dress_road(i: int, holder: Node3D, mask: int, kind_name: String, _model: Node3D) -> void:
	var cols: Array = holder.get_meta("colliders", [])
	var rng := _rng(i, 11)
	match kind_name:
		"straight", "lights":
			_dress_straight(i, holder, mask, kind_name == "lights", rng, cols)
		"corner":
			_dress_corner(i, mask, rng, cols)
		"tee", "cross":
			_dress_junction(i, holder, mask, kind_name, rng, cols)
	if kind_name != "bridge":
		_add_decals(i, holder, mask, kind_name, rng)
	holder.set_meta("colliders", cols)


func _dress_straight(i: int, _holder: Node3D, mask: int, lit: bool, rng: RandomNumberGenerator, cols: Array) -> void:
	# Piece frame: the run is along z, across is x; EW runs turn it by +90 degrees.
	var ew := (mask & RoadTopology.NS) == 0 and mask != 0
	var rot := Basis(Vector3.UP, PI * 0.5) if ew else Basis()
	var x := D.tx(i)
	var y := D.ty(i)
	var stop_side := 0
	if view.bus_stops.has(i):
		var dv: Vector2i = view.bus_stops[i]
		stop_side = 1 if (rot.inverse() * Vector3(dv.x, 0, dv.y)).x > 0.0 else -1
	if lit:
		for lp: Vector2 in LAMP_POLES:
			cols.append({"shape": "cyl", "pos": rot * Vector3(lp.x, WS.SIDEWALK_TOP, lp.y), "r": 0.009, "h": WS.LAMP_HEIGHT, "yaw": 0.0, "kind": "lamp"})
	for side: int in [1, -1]:
		var out := rot * Vector3(side, 0, 0)
		var ctx := _lot_context(x + roundi(out.x), y + roundi(out.z))
		var face := Vector2(-out.x, -out.z)   # toward the road
		var blocked: Array[float] = []
		if lit:
			for lp: Vector2 in LAMP_POLES:
				if signf(lp.x) == float(side):
					blocked.append(lp.y)
		if stop_side == side:
			blocked.append(0.0)
		var curb := _curb_recipe(ctx, rng)
		var slots := CURB_SLOTS.duplicate()
		_shuffle(slots, rng)
		for kind: String in curb:
			var along := _free_slot(slots, blocked, 0.12)
			if is_nan(along):
				break
			blocked.append(along)
			_put_curb(i, kind, rot * Vector3(side * CURB, WS.SIDEWALK_TOP, along), face, rot * Vector3(0, 0, 1), cols, rng)
		if stop_side == side:
			continue
		var front := _front_recipe(ctx, rng)
		if not front.is_empty():
			var fslots := FRONT_SLOTS.duplicate()
			_shuffle(fslots, rng)
			var along := _free_slot(fslots, [], 0.0)
			_put(i, front, rot * Vector3(side * FRONT, WS.SIDEWALK_TOP, along), face, cols)


## A curb-band item: street trees stand in a grate, bollards come in pairs along the curb.
func _put_curb(i: int, kind: String, pos: Vector3, face: Vector2, along_dir: Vector3, cols: Array, rng: RandomNumberGenerator) -> void:
	match kind:
		"tree":
			_put(i, "pit", pos, face, cols)
			_put(i, "tree", pos, Vector2.from_angle(rng.randf() * TAU), cols, rng.randf_range(0.85, 1.2))
		"bollard":
			for s: float in [-1.0, 1.0]:
				_put(i, "bollard", pos + along_dir * (0.03 * s), face, cols)
		_:
			_put(i, kind, pos, face, cols)


func _curb_recipe(ctx: String, rng: RandomNumberGenerator) -> Array[String]:
	var out: Array[String] = []
	match ctx:
		"shop":
			out = ["tree", "tree", "bin"]
		"home":
			out = ["tree"]
			if rng.randf() < 0.5:
				out.append("tree")
			if rng.randf() < 0.25:
				out.append("hydrant")
		"work":
			out = ["bollard"]
			if rng.randf() < 0.35:
				out.append("hydrant")
		"civic":
			out = ["tree", "bin"]
		"park":
			out = ["tree", "tree"]
		_:
			if rng.randf() < 0.3:
				out.append("tree")
			elif rng.randf() < 0.2:
				out.append("bollard")
	return out


func _front_recipe(ctx: String, rng: RandomNumberGenerator) -> String:
	var r := rng.randf()
	match ctx:
		"shop":
			if r < 0.75:
				return ["bench", "planter", "rack", "meter", "bench"][rng.randi() % 5]
		"home":
			if r < 0.2:
				return "mailbox"
		"work":
			if r < 0.3:
				return "utility"
		"civic":
			if r < 0.5:
				return "bench"
			if r < 0.75:
				return "rack"
		"park":
			if r < 0.6:
				return "bench_park"
	return ""


## What the lot at (x, y) is, for picking street furniture: shop, home, work, civic, park, vacant.
func _lot_context(x: int, y: int) -> String:
	if not D.in_bounds(x, y):
		return "vacant"
	var j := D.idx(x, y)
	var k := view.sim.kind[j]
	var lv := view.sim.level[j]
	if k == D.ZONE_C and lv > 0:
		return "shop"
	if k == D.ZONE_R and lv > 0:
		return "home"
	if k == D.ZONE_I and lv > 0:
		return "work"
	if k == D.PARK:
		return "park"
	if D.is_service(k):
		return "civic"
	return "vacant"


## The first slot at least `gap` from every blocked along-position, or NAN.
func _free_slot(slots: Array, blocked: Array, gap: float) -> float:
	for s: float in slots:
		var ok := true
		for b: float in blocked:
			if absf(s - b) < gap + 0.001:
				ok = false
				break
		if ok:
			slots.erase(s)
			return s
	return NAN


func _dress_corner(i: int, mask: int, rng: RandomNumberGenerator, cols: Array) -> void:
	# The outer corner of the bend is a wide plaza of pavement: one tree or a bench there.
	var c := Vector2.ZERO
	for a: Vector2i in RoadTopology.arms(mask):
		c += Vector2(a) * 0.5
	var out := -c.normalized()
	var p := c + out * 1.12
	var r := rng.randf()
	if r < 0.55:
		_put_curb(i, "tree", Vector3(p.x, WS.SIDEWALK_TOP, p.y), -out, Vector3.ZERO, cols, rng)
	elif r < 0.75:
		_put(i, "bin", Vector3(p.x, WS.SIDEWALK_TOP, p.y), -out, cols)


func _dress_junction(i: int, holder: Node3D, mask: int, kind_name: String, rng: RandomNumberGenerator, cols: Array) -> void:
	var arms := RoadTopology.arms(mask)
	# Kerb ramps and tactile pads where the zebras meet the curbs.
	var mid := (WS.ZEBRA_NEAR + WS.ZEBRA_FAR) * 0.5
	for a: Vector2i in arms:
		var perp := Vector2(-a.y, a.x)
		for s: float in [-1.0, 1.0]:
			var p := Vector2(a) * mid + perp * s * (WS.ROAD_HALF + 0.001)
			_put(i, "ramp", Vector3(p.x, 0.0, p.y), perp * s, cols)
	var names := view.directory.intersection_name(i).split(" & ")
	if kind_name == "tee":
		# One pole on the far side, opposite the stem, at the curb past the stem's mouth.
		var stem := Vector2i.ZERO
		for k in range(4):
			if (mask & (1 << k)) == 0:
				stem = -[Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)][k]
		var far := -Vector2(stem)
		var side := Vector2(-far.y, far.x)
		var p := far * CURB + side * 0.33
		_street_sign(holder, Vector3(p.x, WS.SIDEWALK_TOP, p.y), names, cols, true)
		_corner_bin(i, Vector2(stem) * 0.345 - side * 0.345, cols, rng)
	else:
		var pole: Node3D = null
		if view.light_pole_source != null and view.light_pole_source.has_method("light_pole"):
			pole = view.light_pole_source.call("light_pole", i, 0) as Node3D
		if pole != null and pole.is_inside_tree():
			var at := holder.to_local(pole.global_position)
			var blades := _blades(names)
			blades.position = Vector3(at.x, at.y + 0.15, at.z)
			holder.add_child(blades)
		else:
			_street_sign(holder, Vector3(0.345, WS.SIDEWALK_TOP, -0.345), names, cols, true)
		_corner_bin(i, Vector2(-0.345, 0.345) if rng.randf() < 0.5 else Vector2(0.345, 0.345), cols, rng)


func _corner_bin(i: int, p: Vector2, cols: Array, rng: RandomNumberGenerator) -> void:
	if rng.randf() < 0.6:
		_put(i, "bin", Vector3(p.x, WS.SIDEWALK_TOP, p.y), -p.normalized(), cols)


## A street-name sign: a galvanised pole with one blade per street, the E-W name along x.
func _street_sign(holder: Node3D, pos: Vector3, names: PackedStringArray, cols: Array, with_pole: bool) -> Node3D:
	var sign := Node3D.new()
	sign.name = "StreetSign"
	sign.position = pos
	sign.set_meta("prop", true)
	sign.set_meta("street_sign", true)
	if with_pole:
		var pole := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.03 * WS.M
		cm.bottom_radius = 0.035 * WS.M
		cm.height = 3.1 * WS.M
		cm.radial_segments = 8
		cm.rings = 1
		pole.mesh = cm
		pole.position.y = cm.height * 0.5
		pole.material_override = _metal_mat()
		sign.add_child(pole)
		var cap := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.04 * WS.M
		sm.height = 0.05 * WS.M
		sm.radial_segments = 8
		sm.rings = 3
		cap.mesh = sm
		cap.position.y = cm.height
		cap.material_override = pole.material_override
		sign.add_child(cap)
		cols.append({"shape": "cyl", "pos": pos, "r": 0.004, "h": cm.height, "yaw": 0.0, "kind": "sign"})
	var blades := _blades(names)
	blades.position.y = 2.75 * WS.M
	sign.add_child(blades)
	holder.add_child(sign)
	return sign


## Crossed name blades: white text on green, both faces, depth-tested. The E-W street's blade lies
## along x; the N-S street's blade, 25 cm higher, along z.
func _blades(names: PackedStringArray) -> Node3D:
	var root_n := Node3D.new()
	root_n.name = "Blades"
	var k := 0
	for n: String in names:
		var along_x := n.ends_with("Street")
		var blade := _blade(n)
		blade.position.y = 0.25 * WS.M * k
		if not along_x:
			blade.rotation.y = PI * 0.5
		root_n.add_child(blade)
		k += 1
	return root_n


func _blade(text: String) -> Node3D:
	var b := Node3D.new()
	b.name = "Blade"
	var font: Font = ThemeDB.fallback_font
	var fs := 28
	var px := 0.00035
	var w := maxf(0.9 * WS.M, font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x * px + 0.24 * WS.M)
	var plate := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(w, 0.24 * WS.M, 0.02 * WS.M)
	plate.mesh = bm
	plate.material_override = _sign_mat()
	b.add_child(plate)
	for s: float in [1.0, -1.0]:
		var lbl := Label3D.new()
		lbl.text = text
		lbl.font_size = fs
		lbl.pixel_size = px
		lbl.outline_size = 0
		lbl.no_depth_test = false
		lbl.double_sided = false
		lbl.modulate = Color(0.96, 0.97, 0.96)
		lbl.position.z = s * 0.012 * WS.M
		lbl.rotation.y = 0.0 if s > 0.0 else PI
		lbl.set_meta("sign_text", true)
		b.add_child(lbl)
	return b


# ------------------------------------------------------------------ decals

func _add_decals(i: int, holder: Node3D, mask: int, kind_name: String, rng: RandomNumberGenerator) -> void:
	if _decal_texture("crack_0") == null:
		return
	var straight := kind_name == "straight" or kind_name == "lights" or kind_name == "bridge"
	var ew := (mask & RoadTopology.NS) == 0 and mask != 0
	var rot := Basis(Vector3.UP, PI * 0.5) if ew else Basis()
	var n := rng.randi_range(0, 2)
	for _k in range(n):
		var what := rng.randi() % 6
		var p := Vector3.ZERO
		var yaw := rng.randf() * TAU
		if straight:
			var across := rng.randf_range(0.04, 0.25) * (1.0 if rng.randf() < 0.5 else -1.0)
			p = rot * Vector3(across, 0, rng.randf_range(-0.42, 0.42))
		elif kind_name == "corner":
			var c := Vector2.ZERO
			for a: Vector2i in RoadTopology.arms(mask):
				c += Vector2(a) * 0.5
			var ang := atan2(-c.y, -c.x) + rng.randf_range(-0.6, 0.6)
			var q := c + Vector2.from_angle(ang) * rng.randf_range(0.32, 0.68)
			p = Vector3(q.x, 0, q.y)
		else:
			p = Vector3(rng.randf_range(-0.22, 0.22), 0, rng.randf_range(-0.22, 0.22))
		match what:
			0, 1:
				_decal(holder, "crack_%d" % (rng.randi() % 2), p, WS.ASPHALT_TOP, Vector2(rng.randf_range(3.0, 5.5), rng.randf_range(3.0, 5.5)) * WS.M, yaw, Color(1, 1, 1, 0.9))
			2:
				_decal(holder, "patch_0", p, WS.ASPHALT_TOP, Vector2(rng.randf_range(1.6, 3.2), rng.randf_range(1.2, 2.4)) * WS.M, rot.get_euler().y + (PI * 0.5 if rng.randf() < 0.5 else 0.0), Color(1, 1, 1, 0.95))
			3:
				var pl := rot.inverse() * p
				var lane := rot * Vector3(signf(pl.x) * WS.LANE_OFFSET, 0, pl.z) if straight else p
				_decal(holder, "oil_%d" % (rng.randi() % 2), lane, WS.ASPHALT_TOP, Vector2.ONE * rng.randf_range(0.9, 1.8) * WS.M, yaw, Color(1, 1, 1, 0.8))
			4:
				if straight:
					var s := 1.0 if rng.randf() < 0.5 else -1.0
					var q := rot * Vector3(s * (WS.ROAD_HALF - 0.012), 0, rng.randf_range(-0.4, 0.4))
					_decal(holder, "drain_0", q, WS.ASPHALT_TOP, Vector2(0.45, 0.9) * WS.M, rot.get_euler().y, Color.WHITE)
			_:
				if straight:
					var s2 := 1.0 if rng.randf() < 0.5 else -1.0
					var q2 := rot * Vector3(s2 * rng.randf_range(0.36, 0.47), 0, rng.randf_range(-0.42, 0.42))
					_decal(holder, "stain_0", q2, WS.SIDEWALK_TOP, Vector2.ONE * rng.randf_range(1.5, 2.6) * WS.M, yaw, Color(1, 1, 1, 0.75))
	# One puddle where water collects by the curb; it only shows while the street is wet.
	if straight and rng.randf() < 0.6 and _decal_texture("puddle_0") != null:
		var s3 := 1.0 if rng.randf() < 0.5 else -1.0
		var q3 := rot * Vector3(s3 * rng.randf_range(0.2, 0.26), 0, rng.randf_range(-0.38, 0.38))
		var pd := _decal(holder, "puddle_0", q3, WS.ASPHALT_TOP, Vector2(rng.randf_range(2.0, 3.6), rng.randf_range(1.4, 2.4)) * WS.M, rng.randf() * TAU, Color(1, 1, 1, wetness))
		pd.texture_orm = _decal_texture("puddle_orm")
		pd.texture_normal = null
		pd.visible = wetness > 0.02
		pd.set_meta("puddle", true)
		_puddles.append(pd)


func _decal(holder: Node3D, tex: String, p: Vector3, top: float, size: Vector2, yaw: float, mod: Color) -> Decal:
	var dc := Decal.new()
	dc.size = Vector3(size.x, 0.006, size.y)
	dc.position = Vector3(p.x, top, p.z)
	dc.rotation.y = yaw
	dc.texture_albedo = _decal_texture(tex)
	dc.modulate = mod
	dc.upper_fade = 0.3
	dc.lower_fade = 0.3
	dc.normal_fade = 0.5
	dc.distance_fade_enabled = true
	dc.distance_fade_begin = 2.5 * view.vis_mult
	dc.distance_fade_length = 0.5
	dc.set_meta("road_decal", true)
	holder.add_child(dc)
	return dc


func _decal_texture(n: String) -> Texture2D:
	if not _decal_tex.has(n):
		var p := DECALS + n + ".png"
		_decal_tex[n] = load(p) if ResourceLoader.exists(p) else null
	return _decal_tex[n]


## Shows the puddles in proportion to w (0 dry .. 1 soaked).
func set_wetness(w: float) -> void:
	wetness = w
	var live: Array[Decal] = []
	for d in _puddles:
		if is_instance_valid(d):
			d.modulate.a = smoothstep(0.15, 0.9, w)
			d.visible = w > 0.15
			live.append(d)
	_puddles = live


# ------------------------------------------------------------------ lots

## A vacant zoned lot on foot: rough ground, a lease board at the frontage and, on some commercial
## and industrial lots, a billboard at the back facing the street. No zoning glow.
func empty_lot(i: int, holder: Node3D, k: int, h: int) -> void:
	var patch := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(0.94, 0.94)
	patch.mesh = pm
	patch.position.y = WS.GROUND_Y + 0.0003
	patch.material_override = view.lot_ground_material()
	patch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	patch.name = "VacantLot"
	holder.add_child(patch)
	var f := view.directory.frontage(i)
	if f < 0:
		return
	var dv := Vector2(D.tx(f) - D.tx(i), D.ty(f) - D.ty(i))
	var side := Vector2(-dv.y, dv.x)
	var cols: Array = holder.get_meta("colliders", [])
	var off := 0.18 if (h >> 4) % 2 == 0 else -0.18
	_lease_board(holder, dv * 0.41 + side * off, dv, cols)
	if k != D.ZONE_R and (h >> 6) % 3 == 0:
		_billboard(holder, Vector3(dv.x * -0.2, WS.GROUND_Y, dv.y * -0.2), dv, cols)
	holder.set_meta("colliders", cols)


## A built zone lot on foot: sidewalk aprons from the lot slab to the road sidewalks.
func dress_lot(i: int, holder: Node3D, k: int, _lv: int, _h: int) -> void:
	_aprons(i, holder, k != D.ZONE_R)


## A service lot on foot: aprons on every road side.
func dress_service(i: int, holder: Node3D, _k: int, _model: Node3D) -> void:
	_aprons(i, holder, true)


## Sloped paving between the lot slab (LOT_TOP, 0.47) and the road sidewalk (SIDEWALK_TOP, 0.5), on
## the frontage side, or on every road side when all_roads.
func _aprons(i: int, holder: Node3D, all_roads: bool) -> void:
	var x := D.tx(i)
	var y := D.ty(i)
	var f := view.directory.frontage(i)
	for dv: Vector2i in [Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, -1), Vector2i(-1, 0)]:
		var nx := x + dv.x
		var ny := y + dv.y
		if not D.in_bounds(nx, ny) or view.sim.kind[D.idx(nx, ny)] != D.ROAD:
			continue
		if not all_roads and D.idx(nx, ny) != f:
			continue
		var ap := MeshInstance3D.new()
		ap.name = "Apron"
		ap.mesh = _apron_mesh()
		ap.rotation.y = atan2(float(dv.x), float(dv.y))
		ap.material_override = view.apron_material()
		holder.add_child(ap)


func _apron_mesh() -> ArrayMesh:
	if _mats.has("apron_mesh"):
		return _mats["apron_mesh"]
	# Local frame: +z toward the road; the strip runs from z 0.47 (lot) to 0.5 (tile edge), x +-0.5.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var z0 := 0.47
	var z1 := 0.5
	var lo := WS.GROUND_Y
	var a := Vector3(-0.5, WS.LOT_TOP, z0)
	var b := Vector3(0.5, WS.LOT_TOP, z0)
	var c := Vector3(0.5, WS.SIDEWALK_TOP, z1)
	var d := Vector3(-0.5, WS.SIDEWALK_TOP, z1)
	var n := (b - a).cross(d - a).normalized() * -1.0
	if n.y < 0.0:
		n = -n
	_quad(st, a, b, c, d, n)
	# Lot-side face down to the ground and the two ends, so no gap shows at the verge.
	_quad(st, Vector3(0.5, lo, z0), Vector3(-0.5, lo, z0), a, b, Vector3(0, 0, -1))
	_quad(st, Vector3(-0.5, lo, z1), Vector3(-0.5, lo, z0), a, d, Vector3(-1, 0, 0))
	_quad(st, Vector3(0.5, lo, z0), Vector3(0.5, lo, z1), c, b, Vector3(1, 0, 0))
	st.generate_tangents()
	var m := st.commit()
	_mats["apron_mesh"] = m
	return m


## Quad a-b-c-d (counter-clockwise seen from n) with world-ish UVs.
func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	var verts := [a, b, c, a, c, d]
	# Godot's front faces are clockwise; flip when the winding faces away from n.
	if (b - a).cross(c - a).dot(n) > 0.0:
		verts = [a, c, b, a, d, c]
	for v: Vector3 in verts:
		st.set_normal(n)
		st.set_uv(Vector2(v.x + v.y, v.z + v.y))
		st.add_vertex(v)


## A "For lease" board on two posts at holder-local p (xz), facing the street direction dv.
func _lease_board(holder: Node3D, p: Vector2, dv: Vector2, cols: Array) -> Node3D:
	var board: Node3D = null
	var ps := AP.load_scene(AP.LEASE_SIGN)
	if ps != null:
		board = ps.instantiate() as Node3D
	else:
		board = Node3D.new()
		var w := 1.4 * WS.M
		var hgt := 0.9 * WS.M
		var top := 2.2 * WS.M
		for s: float in [-1.0, 1.0]:
			var post := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(0.08, 0.0, 0.08) * WS.M + Vector3(0, top, 0)
			post.mesh = bm
			post.position = Vector3(s * w * 0.4, top * 0.5, -0.03 * WS.M)
			post.material_override = _wood_mat()
			board.add_child(post)
		var panel := MeshInstance3D.new()
		var pm := BoxMesh.new()
		pm.size = Vector3(w, hgt, 0.03 * WS.M)
		panel.mesh = pm
		panel.position.y = top - hgt * 0.5 - 0.05 * WS.M
		panel.material_override = _board_mat()
		board.add_child(panel)
		var band := MeshInstance3D.new()
		var bb := BoxMesh.new()
		bb.size = Vector3(w, hgt * 0.3, 0.032 * WS.M)
		band.mesh = bb
		band.position.y = top - hgt * 0.15 - 0.05 * WS.M
		band.material_override = _paint_mat(Color(0.72, 0.1, 0.08))
		board.add_child(band)
		var title := Label3D.new()
		title.text = "FOR LEASE"
		title.font_size = 64
		title.pixel_size = 0.00012
		title.outline_size = 0
		title.modulate = Color(0.98, 0.97, 0.94)
		title.position = Vector3(0, band.position.y, 0.017 * WS.M)
		title.no_depth_test = false
		board.add_child(title)
		var sub := Label3D.new()
		sub.text = "Commercial / residential lot\n555-0142"
		sub.font_size = 40
		sub.pixel_size = 0.0001
		sub.outline_size = 0
		sub.modulate = Color(0.12, 0.12, 0.13)
		sub.position = Vector3(0, top - hgt * 0.62 - 0.05 * WS.M, 0.017 * WS.M)
		sub.no_depth_test = false
		board.add_child(sub)
	board.name = "LeaseBoard"
	board.position = Vector3(p.x, WS.GROUND_Y, p.y)
	board.rotation.y = atan2(dv.x, dv.y)
	board.set_meta("prop", true)
	var hgt2 := 0.9 * WS.M
	board.set_meta("poster_slot", {"kind": "lease", "size": Vector2(1.4 * WS.M, hgt2 * 0.7), "xform": Transform3D(Basis(), Vector3(0, 2.2 * WS.M - hgt2 * 0.62 - 0.05 * WS.M, 0.018 * WS.M))})
	holder.add_child(board)
	cols.append({"shape": "box", "pos": board.position, "size": Vector3(1.4 * WS.M, 2.2 * WS.M, 0.1 * WS.M), "yaw": board.rotation.y, "kind": "lease"})
	return board


## A billboard (H's poster billboard when present) at holder-local pos, facing dv.
func _billboard(holder: Node3D, pos: Vector3, dv: Vector2, cols: Array) -> Node3D:
	var path := AP.first_existing([AP.BILLBOARD_POSTER])
	var b: Node3D = AP.load_scene(path).instantiate() as Node3D if not path.is_empty() else view._inst(CityView.R + "props/billboard.glb")
	if b == null:
		return null
	b.name = "Billboard"
	b.position = pos
	b.rotation.y = atan2(dv.x, dv.y)
	b.set_meta("prop", true)
	b.set_meta("poster_slot", billboard_slot())
	holder.add_child(b)
	view._register_animated(b)
	for s: float in [-1.0, 1.0]:
		var leg := Basis(Vector3.UP, b.rotation.y) * Vector3(s * 0.09, 0, 0)
		cols.append({"shape": "cyl", "pos": pos + leg, "r": 0.008, "h": 0.2, "yaw": 0.0, "kind": "billboard"})
	return b


## The poster rectangle of the legacy billboard model (its Sign_Blue panel).
static func billboard_slot() -> Dictionary:
	return {"kind": "billboard", "size": Vector2(0.34, 0.15), "xform": Transform3D(Basis(), Vector3(0, 0.275, 0.006))}


## The FP bus shelter on side dv of a straight road: H's shelter (1.5 m deep) at FRONT, else the real
## shelter (2 m deep) set 0.01 further back, open side to the road. Adds its colliders; null when
## neither model loads.
func shelter(holder: Node3D, dv: Vector2i) -> Node3D:
	var ps := AP.load_scene(AP.BUS_SHELTER)
	var across := FRONT
	var stop: Node3D = null
	if ps != null:
		stop = ps.instantiate() as Node3D
	else:
		stop = view._inst(CityView.R + "props/bus_stop.glb")
		across = FRONT + 0.01
	if stop == null:
		return null
	stop.name = "BusShelter"
	stop.position = Vector3(dv.x * across, WS.SIDEWALK_TOP, dv.y * across)
	stop.rotation.y = atan2(-float(dv.x), -float(dv.y))
	stop.set_meta("prop", true)
	# The real shelter's lit ad panel is its west end (x -0.123), facing -x.
	stop.set_meta("poster_slot", {"kind": "bus_shelter", "size": Vector2(0.063, 0.106), "xform": Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(-0.1245, 0.065, 0.0))})
	holder.add_child(stop)
	var cols: Array = holder.get_meta("colliders", [])
	var yb := Basis(Vector3.UP, stop.rotation.y)
	cols.append({"shape": "box", "pos": stop.position + yb * Vector3(0.0, 0, -0.035), "size": Vector3(0.26, 0.13, 0.012), "yaw": stop.rotation.y, "kind": "shelter"})
	for s: float in [-1.0, 1.0]:
		cols.append({"shape": "cyl", "pos": stop.position + yb * Vector3(s * 0.125, 0, 0.045), "r": 0.004, "h": 0.13, "yaw": 0.0, "kind": "shelter"})
	holder.set_meta("colliders", cols)
	return stop


# ------------------------------------------------------------------ materials

## Swaps see-through glass on a building for opaque, sky-reflecting curtain wall on foot.
func dress_model(model: Node3D) -> void:
	for n in model.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in range(mi.mesh.get_surface_count()):
			var m := mi.mesh.surface_get_material(s)
			if m == null:
				continue
			var nm := m.resource_name
			if nm == "Glass" or nm.begins_with("Glass_Curtain") or nm.begins_with("Glass_Shop"):
				mi.set_surface_override_material(s, _glass_mat(nm))


func _glass_mat(nm: String) -> StandardMaterial3D:
	var key := "glass_" + nm
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.resource_name = nm + "_FP"
		var shop := nm.begins_with("Glass_Shop")
		m.albedo_color = Color(0.1, 0.12, 0.13) if shop else Color(0.05, 0.075, 0.095)
		m.metallic = 0.15
		m.metallic_specular = 0.75
		m.roughness = 0.05
		_mats[key] = m
	return _mats[key]


## Tree kit parts for street level: leaf cards get normals bent out from the crown centre (soft,
## volumetric shading instead of dark card undersides) and the hashed-alpha foliage shader.
func fp_tree_parts(parts: Array) -> Array:
	var out: Array = []
	for p: Dictionary in parts:
		var mesh := p["mesh"] as Mesh
		var mat := mesh.surface_get_material(0) if mesh.get_surface_count() > 0 else null
		if mat == null or not mat.resource_name.begins_with("Leaves") or not (mesh is ArrayMesh):
			out.append(p)
			continue
		var q := p.duplicate()
		q["mesh"] = _bent_mesh(mesh as ArrayMesh)
		q["mat"] = _foliage_mat(mat as BaseMaterial3D)
		out.append(q)
	return out


func _bent_mesh(src: ArrayMesh) -> ArrayMesh:
	var key := "bent_%d" % src.get_instance_id()
	if _mats.has(key):
		return _mats[key]
	var out := ArrayMesh.new()
	var bb := src.get_aabb()
	var c := bb.get_center() - Vector3(0, bb.size.y * 0.15, 0)
	for s in range(src.get_surface_count()):
		var arr := src.surface_get_arrays(s)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		if nrm.size() == v.size():
			for k in range(v.size()):
				var radial := (v[k] - c)
				radial.y *= 1.4
				nrm[k] = nrm[k].lerp(radial.normalized(), 0.8).normalized()
			arr[Mesh.ARRAY_NORMAL] = nrm
		arr[Mesh.ARRAY_TANGENT] = null
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_mats[key] = out
	return out


func _foliage_mat(src: BaseMaterial3D) -> Material:
	var key := "foliage_%d" % src.get_instance_id()
	if _mats.has(key):
		return _mats[key]
	var m: Material = null
	if ResourceLoader.exists("res://shaders/foliage.gdshader"):
		var sm := ShaderMaterial.new()
		sm.shader = load("res://shaders/foliage.gdshader")
		sm.set_shader_parameter("albedo_tex", src.albedo_texture)
		sm.set_shader_parameter("tint", src.albedo_color)
		m = sm
	else:
		var d := src.duplicate() as BaseMaterial3D
		d.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
		d.cull_mode = BaseMaterial3D.CULL_DISABLED
		m = d
	_mats[key] = m
	return m


func _metal_mat() -> StandardMaterial3D:
	return _std("metal", Color(0.56, 0.58, 0.6), 0.7, 0.42)


func _wood_mat() -> StandardMaterial3D:
	return _std("wood", Color(0.42, 0.31, 0.2), 0.0, 0.85)


func _board_mat() -> StandardMaterial3D:
	return _std("board", Color(0.93, 0.92, 0.88), 0.0, 0.6)


func _sign_mat() -> StandardMaterial3D:
	return _std("sign", SIGN_GREEN, 0.0, 0.45)


func _paint_mat(c: Color) -> StandardMaterial3D:
	return _std("paint_" + c.to_html(), c, 0.0, 0.55)


func _std(key: String, c: Color, metal: float, rough: float) -> StandardMaterial3D:
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.metallic = metal
		m.roughness = rough
		_mats[key] = m
	return _mats[key]


# ------------------------------------------------------------------ procedural kits

func _procedural_kit(kind: String) -> Array:
	match kind:
		"pit":
			# A cast-iron tree grate, 1.3 m square, with a soil disc round the trunk.
			var plate := BoxMesh.new()
			plate.size = Vector3(1.3, 0.02, 1.3) * WS.M
			var soil := CylinderMesh.new()
			soil.top_radius = 0.38 * WS.M
			soil.bottom_radius = 0.38 * WS.M
			soil.height = 0.025 * WS.M
			soil.radial_segments = 12
			soil.rings = 1
			return [
				{"mesh": plate, "xform": Transform3D(Basis(), Vector3(0, 0.01 * WS.M, 0)), "mat": _std("grate", Color(0.13, 0.12, 0.11), 0.6, 0.55)},
				{"mesh": soil, "xform": Transform3D(Basis(), Vector3(0, 0.0125 * WS.M, 0)), "mat": _std("soil", Color(0.2, 0.15, 0.11), 0.0, 0.95)},
			]
		"rack":
			# Three steel hoops, 0.85 m tall, 0.7 m wide, side by side along x.
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			var tube := 0.05 * WS.M
			var hh := 0.85 * WS.M
			var w := 0.7 * WS.M
			for k in range(3):
				var x0 := (float(k) - 1.0) * 0.6 * WS.M
				for s: float in [-1.0, 1.0]:
					_box(st, Vector3(x0 + s * w * 0.5, hh * 0.5, 0), Vector3(tube, hh, tube))
				_box(st, Vector3(x0, hh, 0), Vector3(w + tube, tube, tube))
			return [{"mesh": st.commit(), "xform": Transform3D(), "mat": _metal_mat()}]
		"meter":
			var post := CylinderMesh.new()
			post.top_radius = 0.035 * WS.M
			post.bottom_radius = 0.04 * WS.M
			post.height = 1.1 * WS.M
			post.radial_segments = 8
			post.rings = 1
			var head := BoxMesh.new()
			head.size = Vector3(0.22, 0.34, 0.16) * WS.M
			return [
				{"mesh": post, "xform": Transform3D(Basis(), Vector3(0, 0.55 * WS.M, 0)), "mat": _std("meter_post", Color(0.2, 0.22, 0.24), 0.5, 0.5)},
				{"mesh": head, "xform": Transform3D(Basis(), Vector3(0, 1.27 * WS.M, 0)), "mat": _std("meter_head", Color(0.62, 0.64, 0.66), 0.6, 0.4)},
			]
		"ramp":
			# Local: +z away from the road (sidewalk), x along the curb. A wedge in the gutter from the
			# asphalt up to the curb top, and a buff tactile pad on the sidewalk behind it.
			var st2 := SurfaceTool.new()
			st2.begin(Mesh.PRIMITIVE_TRIANGLES)
			var hw := (WS.ZEBRA_FAR - WS.ZEBRA_NEAR) * 0.5
			var g0 := Vector3(-hw, WS.ASPHALT_TOP, -0.03)
			var g1 := Vector3(hw, WS.ASPHALT_TOP, -0.03)
			var g2 := Vector3(hw, WS.SIDEWALK_TOP, 0.0)
			var g3 := Vector3(-hw, WS.SIDEWALK_TOP, 0.0)
			_quad(st2, g0, g1, g2, g3, Vector3(0, 0.98, -0.2).normalized())
			_quad(st2, Vector3(-hw, WS.ASPHALT_TOP, 0.0), Vector3(-hw, WS.ASPHALT_TOP, -0.03), g0, g3, Vector3(-1, 0, 0))
			_quad(st2, Vector3(hw, WS.ASPHALT_TOP, -0.03), Vector3(hw, WS.ASPHALT_TOP, 0.0), g2, g1, Vector3(1, 0, 0))
			var wedge := st2.commit()
			var pad := BoxMesh.new()
			pad.size = Vector3(hw * 2.0, 0.0004, 0.03)
			return [
				{"mesh": wedge, "xform": Transform3D(), "mat": _std("ramp", Color(0.62, 0.61, 0.58), 0.0, 0.85)},
				{"mesh": pad, "xform": Transform3D(Basis(), Vector3(0, WS.SIDEWALK_TOP + 0.0002, 0.016)), "mat": _std("tactile", Color(0.78, 0.62, 0.32), 0.0, 0.7)},
			]
	return []


func _box(st: SurfaceTool, c: Vector3, s: Vector3) -> void:
	var h := s * 0.5
	var k := [
		c + Vector3(-h.x, -h.y, -h.z), c + Vector3(h.x, -h.y, -h.z), c + Vector3(h.x, h.y, -h.z), c + Vector3(-h.x, h.y, -h.z),
		c + Vector3(-h.x, -h.y, h.z), c + Vector3(h.x, -h.y, h.z), c + Vector3(h.x, h.y, h.z), c + Vector3(-h.x, h.y, h.z),
	]
	var faces := [[0, 3, 2, 1, Vector3.BACK * -1.0], [4, 5, 6, 7, Vector3.BACK], [0, 4, 7, 3, Vector3.LEFT], [1, 2, 6, 5, Vector3.RIGHT], [3, 7, 6, 2, Vector3.UP], [0, 1, 5, 4, Vector3.DOWN]]
	for f: Array in faces:
		_quad(st, k[f[0]], k[f[1]], k[f[2]], k[f[3]], f[4])


# ------------------------------------------------------------------ helpers

func _rng(i: int, salt: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = hash([view.sim.city_seed, i, salt])
	return r


func _shuffle(a: Array, rng: RandomNumberGenerator) -> void:
	for k in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, k)
		var t: Variant = a[k]
		a[k] = a[j]
		a[j] = t
