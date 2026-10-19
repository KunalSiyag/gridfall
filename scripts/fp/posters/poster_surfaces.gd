extends RefCounted
## Finds poster carriers on CityView's tile holders and gives each one poster faces (slice D).
## Precedence on a carrier: H's Poster_<n> meshes, then a G1 `poster_slot` meta, then a quad at the
## measured panel of the legacy model. Carriers: billboards, bus shelters (both faces of the gf
## stop's ad panel), wall posters on lots (H's PosterSpot_<n>, else the baked flat-wall and
## storefront-window spots of assets/posters/wall_spots.json, else the wall box face), hoardings on
## construction sites and lease boards. Every node added under a holder carries
## meta fp_owner = "posters" and dies with the holder.
##
## A slot is {"id": "<tile>:<carrier>:<n>", "tile", "carrier", "faces": [face], "size": Vector2
## (world units), "pos", "normal", "lit", "nodes": [Node], "spot": {...} (walls)}; a face is
## {"mesh": MeshInstance3D, "center", "right", "up", "normal", "half": Vector2} in world space.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const OWNER := "posters"
const REAL_BILLBOARD := "res://models/real/props/billboard.glb"
const GF_STOP := "res://models/props/bus_stop.glb"
const REAL_STOP := "res://models/real/props/bus_stop.glb"
const SPOTS_PATH := "res://assets/posters/wall_spots.json"
## The legacy billboard's sign face: 0.34 x 0.15 at y 0.20-0.35, front plane z 0.0045.
const BILLBOARD_SIZE := Vector2(0.34, 0.15)
const BILLBOARD_XF := Transform3D(Basis(), Vector3(0, 0.275, 0.006))
## The gf stop's gf_ad_pink lightbox (x 0.06-0.14, y 0.045-0.135) sits behind its opaque back
## wall (gf_sky_blue, z -0.058 to -0.052) and pokes out of the back to z -0.060: the poster faces
## the road just in front of the wall's inner face and the sidewalk just behind the box.
const GF_STOP_SIZE := Vector2(0.08, 0.09)
const GF_STOP_FRONT := Transform3D(Basis(), Vector3(0.10, 0.09, -0.0515))
const GF_STOP_BACK := Transform3D(Basis(Vector3.UP, PI), Vector3(0.10, 0.09, -0.0605))
## The real stop's lightbox at its west end (x -0.123), facing -X.
const REAL_STOP_SIZE := Vector2(0.063, 0.106)
const REAL_STOP_XF := Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(-0.1245, 0.065, 0.0))
## Wall posters sit this far off the wall (4 cm), window posters off the glass.
const WALL_OFFSET := 0.002
const WINDOW_OFFSET := 0.0012
## The contract's fallback wall poster (1.2 x 1.8 m) centred 0.07 above LOT_TOP.
const WALL_FALLBACK_SIZE := Vector2(0.06, 0.09)
const WALL_FALLBACK_Y := WS.LOT_TOP + 0.07
## The S0 construction kit's fence (construction_kit.gd _fence): 1 m tall at +-0.47, 8 mm thick.
const FENCE_H := 0.05
const FENCE_OUT := 0.47
const FENCE_HALF_T := 0.004
const SIDES := {"+z": Vector3(0, 0, 1), "-z": Vector3(0, 0, -1), "+x": Vector3(1, 0, 0), "-x": Vector3(-1, 0, 0)}
const WALL_PREFIXES := ["Brick", "Siding", "Stone", "Plaster", "Concrete_Wall", "Concrete_Panel", "Panel"]

var sim: CitySim
var view: CityView
var directory: CityDirectory
## Baked wall spots by model path (see wall_spot_baker.gd).
var spots: Dictionary = {}
## Per-tile scans done (tests: none while view.in_setup).
var scans: int = 0
var _quads: Dictionary = {}
var _boxes: Dictionary = {}


func setup(ctx: FpContext) -> void:
	sim = ctx.sim
	view = ctx.view
	directory = ctx.directory
	if FileAccess.file_exists(SPOTS_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SPOTS_PATH))
		if typeof(parsed) == TYPE_DICTIONARY:
			spots = parsed


## Tiles a full pass visits: commercial lots, bus-stop roads, sites, vacant zoned lots (lease boards
## and billboards on foot) and the lots chosen for wall posters; never every tile's subtree.
func candidates() -> Array[int]:
	var out: Array[int] = []
	for i in sim.active:
		var k := sim.kind[i]
		if k == D.ZONE_C or k == D.SITE or view.bus_stops.has(i) or sim.sites.has(i):
			out.append(i)
		elif (k == D.ZONE_R or k == D.ZONE_I) and (sim.level[i] == 0 or wall_lot(i)):
			out.append(i)
	return out


## True when lot i carries a wall poster (deterministic per city seed).
func wall_lot(i: int) -> bool:
	return absi(("%d|%d" % [i, sim.city_seed]).hash()) % 3 == 0


## Discovers the carriers on tile i's holder and builds their faces. Returns the slots.
func scan(i: int, holder: Node3D) -> Array[Dictionary]:
	scans += 1
	var out: Array[Dictionary] = []
	if holder == null or not is_instance_valid(holder):
		return out
	var counts := {}
	for c in holder.get_children():
		if not (c is Node3D) or c.has_meta("fp_owner"):
			continue
		var s := _carrier_slot(i, c as Node3D, counts)
		if not s.is_empty():
			out.append(s)
	var site := holder.get_node_or_null("Site") as Node3D
	if site != null:
		var hs := _hoarding_slot(i, holder, site, counts)
		if not hs.is_empty():
			out.append(hs)
	var k := sim.kind[i]
	if (k == D.ZONE_C or k == D.ZONE_R or k == D.ZONE_I) and sim.level[i] > 0 and wall_lot(i) and not sim.sites.has(i):
		var ws := _wall_slot(i, holder)
		if not ws.is_empty():
			out.append(ws)
	return out


func _carrier_slot(i: int, n: Node3D, counts: Dictionary) -> Dictionary:
	var meta: Variant = n.get_meta("poster_slot") if n.has_meta("poster_slot") else null
	var path := n.scene_file_path
	var carrier := ""
	if typeof(meta) == TYPE_DICTIONARY:
		carrier = _carrier_of(str((meta as Dictionary).get("kind", "")))
	elif path == REAL_BILLBOARD or path == AP.BILLBOARD_POSTER:
		carrier = "billboard"
	elif path == GF_STOP or path == REAL_STOP or path == AP.BUS_SHELTER:
		carrier = "shelter"
	elif path == AP.HOARDING:
		carrier = "hoarding"
	elif path == AP.LEASE_SIGN:
		carrier = "lease"
	if carrier.is_empty():
		return {}
	var faces: Array[Dictionary] = []
	var nodes: Array[Node] = []
	var size := Vector2.ZERO
	for p in n.find_children(AP.POSTER_NODE_PREFIX + "*", "MeshInstance3D", true, false):
		var f := _mesh_face(p as MeshInstance3D)
		faces.append(f)
		size = f["half"] * 2.0
	if faces.is_empty():
		if typeof(meta) == TYPE_DICTIONARY:
			var m: Dictionary = meta
			size = m.get("size", Vector2(0.1, 0.1))
			faces.append(_quad(n, size, m.get("xform", Transform3D()), nodes))
		elif carrier == "billboard":
			size = BILLBOARD_SIZE
			faces.append(_quad(n, size, BILLBOARD_XF, nodes))
		elif carrier == "shelter" and path == GF_STOP:
			size = GF_STOP_SIZE
			faces.append(_quad(n, size, GF_STOP_FRONT, nodes))
			faces.append(_quad(n, size, GF_STOP_BACK, nodes))
		elif carrier == "shelter" and path == REAL_STOP:
			size = REAL_STOP_SIZE
			faces.append(_quad(n, size, REAL_STOP_XF, nodes))
	if faces.is_empty():
		return {}
	return _slot(i, carrier, counts, faces, nodes, size, carrier if carrier == "billboard" or carrier == "shelter" else "")


static func _carrier_of(kind: String) -> String:
	match kind:
		"billboard":
			return "billboard"
		"bus_shelter", "shelter":
			return "shelter"
		"hoarding":
			return "hoarding"
		"lease":
			return "lease"
		"wall":
			return "wall"
	return ""


## lit is "" (unlit), "billboard" (lamp-lit at night) or "shelter" (a lightbox, faint by day).
func _slot(i: int, carrier: String, counts: Dictionary, faces: Array[Dictionary], nodes: Array[Node], size: Vector2, lit: String) -> Dictionary:
	var n := int(counts.get(carrier, 0))
	counts[carrier] = n + 1
	var f0: Dictionary = faces[0]
	return {"id": "%d:%s:%d" % [i, carrier, n], "tile": i, "carrier": carrier, "faces": faces, "size": size,
		"pos": f0["center"], "normal": f0["normal"], "lit": lit, "nodes": nodes}


## A poster quad of size under parent at local transform xf (+Z out, UV 0..1 left to right).
func _quad(parent: Node3D, size: Vector2, xf: Transform3D, nodes: Array[Node]) -> Dictionary:
	var mi := MeshInstance3D.new()
	mi.name = "Poster"
	mi.mesh = _quad_mesh(size)
	mi.transform = xf
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var big := size.x > 0.2
	mi.visibility_range_end = WS.VIS_PROP * (2.5 if big else 1.25)
	mi.visibility_range_end_margin = WS.VIS_PROP * 0.25
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	mi.set_meta("fp_owner", OWNER)
	parent.add_child(mi)
	nodes.append(mi)
	var g := parent.global_transform * xf if parent.is_inside_tree() else _tree_xf(parent) * xf
	return {"mesh": mi, "center": g.origin, "right": g.basis.x.normalized(), "up": g.basis.y.normalized(),
		"normal": g.basis.z.normalized(), "half": size * 0.5}


func _quad_mesh(size: Vector2) -> QuadMesh:
	var k := "%.4f,%.4f" % [size.x, size.y]
	if not _quads.has(k):
		var q := QuadMesh.new()
		q.size = size
		_quads[k] = q
	return _quads[k]


## A face from one of H's Poster_<n> meshes (planar, normal +Z in node space, UV 0..1).
static func _mesh_face(mi: MeshInstance3D) -> Dictionary:
	var aabb := mi.mesh.get_aabb() if mi.mesh != null else AABB(Vector3(-0.05, -0.05, 0), Vector3(0.1, 0.1, 0))
	var g := mi.global_transform if mi.is_inside_tree() else _tree_xf(mi)
	var half := Vector2(aabb.size.x * g.basis.x.length(), aabb.size.y * g.basis.y.length()) * 0.5
	return {"mesh": mi, "center": g * aabb.get_center(), "right": g.basis.x.normalized(), "up": g.basis.y.normalized(),
		"normal": g.basis.z.normalized(), "half": half}


## The global transform of a node outside the tree (product of its ancestors' transforms).
static func _tree_xf(n: Node) -> Transform3D:
	var t := Transform3D()
	var cur: Node = n
	while cur != null:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t


# ------------------------------------------------------------------ hoardings

func _hoarding_slot(i: int, holder: Node3D, site: Node3D, counts: Dictionary) -> Dictionary:
	# G1: a poster_slot on the kit's frontage hoarding segment.
	for c in site.find_children("*", "Node3D", true, false):
		if c.has_meta("fp_owner"):
			continue
		var meta: Variant = c.get_meta("poster_slot") if c.has_meta("poster_slot") else null
		if typeof(meta) == TYPE_DICTIONARY and _carrier_of(str((meta as Dictionary).get("kind", ""))) == "hoarding":
			var nodes: Array[Node] = []
			var m: Dictionary = meta
			var f := _quad(c as Node3D, m.get("size", Vector2(0.15, 0.075)), m.get("xform", Transform3D()), nodes)
			return _slot(i, "hoarding", counts, [f], nodes, m.get("size", Vector2(0.15, 0.075)), "")
	# S0 kit: a banner on the outer face of the frontage fence segment (never a panel at 0.44).
	var fr := directory.frontage(i)
	if fr < 0:
		return {}
	var dv := Vector3(D.tx(fr) - D.tx(i), 0, D.ty(fr) - D.ty(i))
	var along := Vector3(-dv.z, 0, dv.x)
	var seg: MeshInstance3D = null
	var seg_len := 0.0
	for c in site.get_children():
		var mi := c as MeshInstance3D
		if mi == null or not (mi.mesh is BoxMesh):
			continue
		var bs: Vector3 = (mi.mesh as BoxMesh).size
		if absf(bs.y - FENCE_H) > 0.001:
			continue
		var p := mi.position
		if absf(p.dot(dv) - FENCE_OUT) > 0.002:
			continue
		var l := maxf(bs.x, bs.z)
		if l > seg_len + 0.001:
			seg = mi
			seg_len = l
	if seg == null:
		return {}
	var w := minf(seg_len - 0.04, 0.3)
	var size := Vector2(w, FENCE_H * 0.8)
	var pos := Vector3(seg.position.x, FENCE_H * 0.5, seg.position.z) + dv * (FENCE_HALF_T + WALL_OFFSET)
	if seg_len > 0.5:
		pos += along * 0.12
	var xf := Transform3D(Basis(Vector3.UP, atan2(dv.x, dv.z)), pos)
	var nodes: Array[Node] = []
	var f2 := _quad(holder, size, xf, nodes)
	return _slot(i, "hoarding", counts, [f2], nodes, size, "")


# ------------------------------------------------------------------ walls

func _wall_slot(i: int, holder: Node3D) -> Dictionary:
	if not holder.has_meta("building_path"):
		return {}
	var path := str(holder.get_meta("building_path"))
	var bx: Transform3D = holder.get_meta("building_xform", Transform3D())
	var fr := directory.frontage(i)
	if fr < 0 or path.is_empty():
		return {}
	var dv := Vector3(D.tx(fr) - D.tx(i), 0, D.ty(fr) - D.ty(i))
	var spot := _poster_spot_node(holder, path, dv)
	if spot.is_empty():
		spot = _baked_spot(i, path, bx, dv)
	if spot.is_empty() and not spots.has(path):
		spot = _box_spot(path, bx, dv)
	if spot.is_empty():
		return {}
	var nodes: Array[Node] = []
	var size: Vector2 = spot["size"]
	var n: Vector3 = spot["normal"]
	var centre: Vector3 = spot["point"] + n * float(spot["offset"])
	var xf := Transform3D(Basis(Vector3.UP, atan2(n.x, n.z)), centre)
	# The poster must stay on its own lot.
	for sx: float in [-0.5, 0.5]:
		var corner := centre + xf.basis.x * size.x * sx
		if absf(corner.x) > 0.495 or absf(corner.z) > 0.495:
			return {}
	var f := _quad(holder, size, xf, nodes)
	var counts := {}
	var s := _slot(i, "wall", counts, [f], nodes, size, "")
	s["spot"] = {"plane_point": holder.transform * (spot["point"] as Vector3), "normal": n, "source": spot["source"], "window": spot.get("window", false)}
	return s


## H's PosterSpot_<n> empties under the building model: the one facing the street.
func _poster_spot_node(holder: Node3D, path: String, dv: Vector3) -> Dictionary:
	var model: Node3D = null
	for c in holder.get_children():
		if c is Node3D and (c as Node3D).scene_file_path == path:
			model = c
			break
	if model == null:
		return {}
	for e in model.find_children(AP.POSTER_SPOT_PREFIX + "*", "Node3D", true, false):
		var g := holder.transform.affine_inverse() * (_tree_xf(e) if not e.is_inside_tree() else (e as Node3D).global_transform)
		var n := g.basis.z.normalized()
		if n.dot(dv) > 0.7:
			return {"point": g.origin, "normal": n, "size": Vector2(g.basis.x.length(), g.basis.y.length()), "offset": 0.0, "source": "spot_node"}
	return {}


## The baked spot facing the street: storefront windows first on shops, flat wall first elsewhere.
func _baked_spot(i: int, path: String, bx: Transform3D, dv: Vector3) -> Dictionary:
	var e: Variant = spots.get(path, null)
	if typeof(e) != TYPE_DICTIONARY:
		return {}
	var groups := ["windows", "spots"] if sim.kind[i] == D.ZONE_C else ["spots", "windows"]
	for g: String in groups:
		var sides: Variant = (e as Dictionary).get(g, {})
		if typeof(sides) != TYPE_DICTIONARY:
			continue
		for side: String in SIDES.keys():
			if not (sides as Dictionary).has(side):
				continue
			var nw := (bx.basis * (SIDES[side] as Vector3)).normalized()
			if nw.dot(dv) < 0.9:
				continue
			var sp: Dictionary = sides[side]
			var p: Array = sp["p"]
			var sy := bx.basis.y.length()
			var local := Vector3(float(p[0]), float(p[1]) / maxf(sy, 0.001), float(p[2]))
			var sz: Array = sp["size"]
			return {"point": bx * local, "normal": nw, "size": Vector2(float(sz[0]), float(sz[1])),
				"offset": WINDOW_OFFSET if g == "windows" else WALL_OFFSET, "source": "baked", "window": g == "windows"}
	return {}


## Fallback for models the bake does not know: the wall box face toward the street, near a corner.
func _box_spot(path: String, bx: Transform3D, dv: Vector3) -> Dictionary:
	var box := wall_box(path)
	if box.size == Vector3.ZERO:
		return {}
	for side: String in SIDES.keys():
		var nl: Vector3 = SIDES[side]
		var nw := (bx.basis * nl).normalized()
		if nw.dot(dv) < 0.9:
			continue
		var c := box.get_center()
		var face := c + nl * (absf(nl.x) * box.size.x + absf(nl.z) * box.size.z) * 0.5
		var u := Vector3(nl.z, 0, -nl.x)
		var span := absf(u.x) * box.size.x + absf(u.z) * box.size.z
		var local := face + u * maxf(span * 0.5 - WALL_FALLBACK_SIZE.x * 0.75, 0.0)
		var sy := bx.basis.y.length()
		local.y = WALL_FALLBACK_Y / maxf(sy, 0.001)
		return {"point": bx * local, "normal": nw, "size": WALL_FALLBACK_SIZE, "offset": WALL_OFFSET, "source": "box"}
	return {}


## Model-space wall box of a building path: the baked one, else the union of the vertex bounds of
## its wall-material surfaces (cached; foliage, ground and planting materials excluded).
func wall_box(path: String) -> AABB:
	var e: Variant = spots.get(path, null)
	if typeof(e) == TYPE_DICTIONARY and (e as Dictionary).has("box"):
		var b: Array = e["box"]
		return AABB(Vector3(float(b[0]), float(b[1]), float(b[2])), Vector3(float(b[3]), float(b[4]), float(b[5])))
	if _boxes.has(path):
		return _boxes[path]
	var box := AABB()
	var ps := AP.load_scene(path)
	if ps != null:
		var inst := ps.instantiate()
		box = _wall_union(inst, Transform3D(), AABB())
		inst.free()
	_boxes[path] = box
	return box


static func _wall_union(n: Node, xf: Transform3D, acc: AABB) -> AABB:
	var t := xf
	if n is Node3D:
		t = xf * (n as Node3D).transform
	if n is MeshInstance3D and not str(n.name).ends_with("_foliage") and (n as MeshInstance3D).mesh != null:
		var m := (n as MeshInstance3D).mesh
		for s in range(m.get_surface_count()):
			var mat := m.surface_get_material(s)
			var nm := mat.resource_name if mat != null else ""
			var wall := false
			for p: String in WALL_PREFIXES:
				if nm.begins_with(p):
					wall = true
			if not wall:
				continue
			var verts: PackedVector3Array = m.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
			for v in verts:
				var w := t * v
				acc = AABB(w, Vector3.ZERO) if acc.size == Vector3.ZERO and acc.position == Vector3.ZERO else acc.expand(w)
	for c in n.get_children():
		acc = _wall_union(c, t, acc)
	return acc
