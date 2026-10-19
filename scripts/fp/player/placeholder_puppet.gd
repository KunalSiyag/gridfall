extends RefCounted
## The legacy person (models/real/people/person_*.glb) re-rigged as a jointed puppet, so the
## placeholder hero walks, runs, crouches and jumps until HC's animated hero replaces it (stage
## A2). The legacy people are built from separate primitives per segment (thigh, knee ball, shin,
## shoe; shoulder ball, upper arm, elbow ball, forearm, hand), posed mid-stride. build() finds
## those pieces, derives the joints (ball centres and segment end caps), straightens every segment
## about its joint and parents it into a hip -> knee -> ankle and shoulder -> elbow chain, with the
## neck, head and hair on a head joint; the avatar drives the joints with a procedural gait and a
## head look. Model space: +Z forward, +X the figure's left.
## A model whose pieces do not match falls back to the rigid body (build() returns null).

## One analysed model per scene path: the part meshes and the joint layout (or {} when the model
## cannot be split).
static var _cache: Dictionary = {}

const SIDES := 2   # 0 = left (+X), 1 = right (-X)
## Far end of a segment: the vertices beyond this fraction of the farthest distance from a joint.
const CAP_FRAC := 0.8

var root: Node3D
var pelvis: Node3D
var spine: Node3D
## The head joint (neck base), a child of spine; null when the model has no separate neck piece.
var head: Node3D
var hips: Array[Node3D] = []
var knees: Array[Node3D] = []
var ankles: Array[Node3D] = []
var shoulders: Array[Node3D] = []
var elbows: Array[Node3D] = []
## Rest layout (model units): the pelvis origin, the ankle height above the soles and the
## sagittal segment lengths.
var pelvis_rest: Vector3 = Vector3.ZERO
var ankle_y: float = 0.0
var thigh_len: float = 0.0
var shin_len: float = 0.0
var hip_x: float = 0.0


## The puppet for a legacy person scene, or null when the model is not built from the expected
## pieces (the caller keeps the rigid body).
static func build(path: String, ps: PackedScene) -> RefCounted:
	if not _cache.has(path):
		_cache[path] = _analyse(ps)
	var data: Dictionary = _cache[path]
	if data.is_empty():
		return null
	var p: RefCounted = load("res://scripts/fp/player/placeholder_puppet.gd").new()
	p.call("_instance", data)
	return p


## Joint angles in radians for one frame. Each side: hip (forward swing), knee (flexion), ankle
## (relative, toes down positive), shoulder (forward swing), elbow (flexion). pelvis_off is the
## pelvis offset from its rest position (model units), lean the spine's forward lean.
func apply(hip: Array, knee: Array, ankle: Array, shoulder: Array, elbow: Array, pelvis_off: Vector3, lean: float) -> void:
	pelvis.position = pelvis_rest + pelvis_off
	spine.rotation = Vector3(lean, 0.0, 0.0)
	for i in range(SIDES):
		hips[i].rotation = Vector3(-float(hip[i]), 0.0, 0.0)
		knees[i].rotation = Vector3(float(knee[i]), 0.0, 0.0)
		ankles[i].rotation = Vector3(float(ankle[i]), 0.0, 0.0)
		shoulders[i].rotation = Vector3(-float(shoulder[i]), 0.0, 0.0)
		elbows[i].rotation = Vector3(-float(elbow[i]), 0.0, 0.0)


## Head look in the spine's frame (radians): yaw toward the figure's left, pitch up.
func look(yaw: float, pitch: float) -> void:
	if head != null:
		head.rotation = Vector3(-pitch, yaw, 0.0)


## Vertical reach of a leg (hip to ankle, model units) at hip swing h and knee flexion k.
func reach(h: float, k: float) -> float:
	return thigh_len * cos(h) + shin_len * cos(h - k)


## Forward reach of a leg (hip to ankle along +Z, model units).
func forward_reach(h: float, k: float) -> float:
	return thigh_len * sin(h) + shin_len * sin(h - k)


func _instance(data: Dictionary) -> void:
	root = Node3D.new()
	root.name = "Puppet"
	pelvis_rest = data["pelvis"]
	ankle_y = data["ankle_y"]
	thigh_len = data["thigh_len"]
	shin_len = data["shin_len"]
	hip_x = data["hip_x"]
	pelvis = _node(root, "Pelvis", pelvis_rest)
	spine = _node(pelvis, "Spine", Vector3.ZERO)
	_mesh(spine, data["torso"])
	if data.has("head"):
		head = _node(spine, "Head", data["neck"])
		_mesh(head, data["head"])
	for i in range(SIDES):
		var leg: Dictionary = data["legs"][i]
		var arm: Dictionary = data["arms"][i]
		var sfx := "L" if i == 0 else "R"
		var hip := _node(pelvis, "Hip" + sfx, leg["hip"])
		_mesh(hip, leg["thigh"])
		var knee := _node(hip, "Knee" + sfx, leg["knee"])
		_mesh(knee, leg["shin"])
		var ankle := _node(knee, "Ankle" + sfx, leg["ankle"])
		_mesh(ankle, leg["foot"])
		var shoulder := _node(spine, "Shoulder" + sfx, arm["shoulder"])
		_mesh(shoulder, arm["upper"])
		var elbow := _node(shoulder, "Elbow" + sfx, arm["elbow"])
		_mesh(elbow, arm["fore"])
		hips.append(hip)
		knees.append(knee)
		ankles.append(ankle)
		shoulders.append(shoulder)
		elbows.append(elbow)


static func _node(parent: Node3D, n: String, pos: Vector3) -> Node3D:
	var j := Node3D.new()
	j.name = n
	j.position = pos
	parent.add_child(j)
	return j


static func _mesh(parent: Node3D, m: ArrayMesh) -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = m
	parent.add_child(mi)


## Splits the model into its pieces and lays out the joints; {} when it does not fit.
static func _analyse(ps: PackedScene) -> Dictionary:
	if ps == null:
		return {}
	var scene := ps.instantiate() as Node3D
	if scene == null:
		return {}
	var mis := scene.find_children("*", "MeshInstance3D", true, false)
	var out := {}
	if mis.size() == 1:
		var mi := mis[0] as MeshInstance3D
		var xf := Transform3D.IDENTITY
		var n: Node = mi
		while n != scene and n is Node3D:
			xf = (n as Node3D).transform * xf
			n = n.get_parent()
		out = _layout(mi, xf)
	scene.free()
	return out


static func _layout(mi: MeshInstance3D, xf: Transform3D) -> Dictionary:
	var mesh := mi.mesh
	if mesh == null:
		return {}
	var surfs: Array = []
	var comps: Array = []
	var top := 0.0
	var half_w := 0.0
	for s in range(mesh.get_surface_count()):
		if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			return {}
		var a := mesh.surface_get_arrays(s)
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var vx := PackedVector3Array()
		vx.resize(v.size())
		for i in range(v.size()):
			vx[i] = xf * v[i]
			top = maxf(top, vx[i].y)
			half_w = maxf(half_w, absf(vx[i].x))
		a[Mesh.ARRAY_VERTEX] = vx
		var nrm: Variant = a[Mesh.ARRAY_NORMAL]
		if nrm is PackedVector3Array:
			var nx := PackedVector3Array()
			nx.resize((nrm as PackedVector3Array).size())
			for i in range(nx.size()):
				nx[i] = (xf.basis * (nrm as PackedVector3Array)[i]).normalized()
			a[Mesh.ARRAY_NORMAL] = nx
		if a[Mesh.ARRAY_INDEX] == null or (a[Mesh.ARRAY_INDEX] as PackedInt32Array).is_empty():
			var seq := PackedInt32Array()
			seq.resize(vx.size())
			for i in range(vx.size()):
				seq[i] = i
			a[Mesh.ARRAY_INDEX] = seq
		var mat := mi.get_surface_override_material(s) if s < mi.get_surface_override_material_count() else null
		surfs.append({"arrays": a, "material": mat if mat != null else mesh.surface_get_material(s)})
		comps.append_array(_components(s, a))
	if top <= 0.0 or half_w <= 0.0:
		return {}
	# Arms stand out sideways; legs sit under the hips; the rest (torso, pelvis, skirt, neck,
	# head) rides on the spine.
	var torso: Array = []
	var legs: Array = [[], []]
	var arms: Array = [[], []]
	for c: Dictionary in comps:
		var cc: Vector3 = (c["aabb"] as AABB).get_center()
		var side := 0 if cc.x > 0.0 else 1
		if absf(cc.x) > 0.6 * half_w:
			arms[side].append(c)
		elif absf(cc.x) > 0.1 * half_w and cc.y < 0.5 * top:
			legs[side].append(c)
		else:
			torso.append(c)
	var by_y := func(a: Dictionary, b: Dictionary) -> bool: return (a["aabb"] as AABB).get_center().y < (b["aabb"] as AABB).get_center().y
	var data := {"legs": [], "arms": []}
	var hip_pts: Array[Vector3] = []
	var raw_legs: Array = []
	for i in range(SIDES):
		var lg: Array = legs[i]
		var am: Array = arms[i]
		if lg.size() != 4 or am.size() != 5:
			return {}
		lg.sort_custom(by_y)
		am.sort_custom(by_y)
		# Legs (low to high): shoe, shin, knee ball, thigh. Arms: hand, forearm, elbow ball, upper
		# arm, shoulder ball.
		var knee := (lg[2]["aabb"] as AABB).get_center()
		var hip := _far_cap(lg[3], knee)
		var ankle := _far_cap(lg[1], knee)
		hip_pts.append(hip)
		raw_legs.append({"foot": lg[0], "shin": [lg[1], lg[2]], "thigh": lg[3], "hip": hip, "knee": knee, "ankle": ankle})
		var shoulder := (am[4]["aabb"] as AABB).get_center()
		var elbow := (am[2]["aabb"] as AABB).get_center()
		var wrist := (am[0]["aabb"] as AABB).get_center()
		var up_rot := _unpose(elbow - shoulder)
		var fore_rot := _unpose(wrist - elbow)
		(data["arms"] as Array).append({
			"shoulder": shoulder,   # made pelvis-relative below
			"upper": _group(surfs, [am[3], am[4]], Transform3D(up_rot, up_rot * -shoulder)),
			"elbow": up_rot * (elbow - shoulder),
			"fore": _group(surfs, [am[0], am[1], am[2]], Transform3D(fore_rot, fore_rot * -elbow)),
		})
	var pelvis := (hip_pts[0] + hip_pts[1]) * 0.5
	var thigh_len := 0.0
	var shin_len := 0.0
	var ankle_y := 0.0
	for i in range(SIDES):
		var r: Dictionary = raw_legs[i]
		var hip: Vector3 = r["hip"]
		var knee: Vector3 = r["knee"]
		var ankle: Vector3 = r["ankle"]
		var th_rot := _unpose(knee - hip)
		var sh_rot := _unpose(ankle - knee)
		thigh_len += Vector2(knee.y - hip.y, knee.z - hip.z).length() * 0.5
		shin_len += Vector2(ankle.y - knee.y, ankle.z - knee.z).length() * 0.5
		ankle_y += ankle.y * 0.5
		(data["legs"] as Array).append({
			"hip": hip - pelvis,
			"thigh": _group(surfs, [r["thigh"]], Transform3D(th_rot, th_rot * -hip)),
			"knee": th_rot * (knee - hip),
			"shin": _group(surfs, r["shin"], Transform3D(sh_rot, sh_rot * -knee)),
			"ankle": sh_rot * (ankle - knee),
			"foot": _group(surfs, [r["foot"]], Transform3D(Basis.IDENTITY, -ankle)),
		})
		var arm: Dictionary = data["arms"][i]
		arm["shoulder"] = (arm["shoulder"] as Vector3) - pelvis
	# Pieces centred above the shoulder balls (neck, head, nose, hair) turn with the head about
	# the bottom of the lowest of them (the neck).
	var shoulder_y := minf((arms[0][4]["aabb"] as AABB).get_center().y, (arms[1][4]["aabb"] as AABB).get_center().y)
	var head_parts: Array = []
	var body_parts: Array = []
	for c: Dictionary in torso:
		if (c["aabb"] as AABB).get_center().y > shoulder_y:
			head_parts.append(c)
		else:
			body_parts.append(c)
	if not head_parts.is_empty():
		var neck: AABB = head_parts[0]["aabb"]
		for c: Dictionary in head_parts:
			if (c["aabb"] as AABB).position.y < neck.position.y:
				neck = c["aabb"]
		var pivot := Vector3(neck.get_center().x, neck.position.y, neck.get_center().z)
		data["head"] = _group(surfs, head_parts, Transform3D(Basis.IDENTITY, -pivot))
		data["neck"] = pivot - pelvis
	data["torso"] = _group(surfs, body_parts, Transform3D(Basis.IDENTITY, -pelvis))
	data["pelvis"] = pelvis
	data["thigh_len"] = thigh_len
	data["shin_len"] = shin_len
	data["ankle_y"] = ankle_y
	data["hip_x"] = absf(hip_pts[0].x - hip_pts[1].x) * 0.5
	return data


## The rotation about +X that straightens a segment pointing along d (from its joint) to hang
## along -Y; the sideways splay stays.
static func _unpose(d: Vector3) -> Basis:
	return Basis(Vector3.RIGHT, atan2(d.z, -d.y))


## The centre of a segment's far end cap: the mean of its vertices farther than CAP_FRAC of the
## farthest one from the joint.
static func _far_cap(c: Dictionary, joint: Vector3) -> Vector3:
	var pts: Array = c["points"]
	var far := 0.0
	for p: Vector3 in pts:
		far = maxf(far, p.distance_to(joint))
	var sum := Vector3.ZERO
	var n := 0
	for p: Vector3 in pts:
		if p.distance_to(joint) >= far * CAP_FRAC:
			sum += p
			n += 1
	return sum / float(maxi(n, 1))


## Connected pieces of one surface (vertices welded by position): {"surf", "tris" (index offsets
## of each triangle's first corner), "aabb", "points" (welded positions), both plain Arrays}.
static func _components(s: int, a: Array) -> Array:
	var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
	var weld := {}
	var wid := PackedInt32Array()
	wid.resize(v.size())
	var pos := PackedVector3Array()
	for i in range(v.size()):
		var k := Vector3i(roundi(v[i].x * 1e6), roundi(v[i].y * 1e6), roundi(v[i].z * 1e6))
		if not weld.has(k):
			weld[k] = pos.size()
			pos.append(v[i])
		wid[i] = weld[k]
	var parent := PackedInt32Array()
	parent.resize(pos.size())
	for i in range(pos.size()):
		parent[i] = i
	for t in range(0, idx.size() - 2, 3):
		var r0 := _root_of(parent, wid[idx[t]])
		for j in [1, 2]:
			var r := _root_of(parent, wid[idx[t + j]])
			if r != r0:
				parent[r] = r0
	var by_root := {}
	for t in range(0, idx.size() - 2, 3):
		var r := _root_of(parent, wid[idx[t]])
		if not by_root.has(r):
			by_root[r] = {"surf": s, "tris": [], "aabb": AABB(v[idx[t]], Vector3.ZERO), "seen": {}, "points": []}
		var c: Dictionary = by_root[r]
		var tris: Array = c["tris"]
		var pts: Array = c["points"]
		var seen: Dictionary = c["seen"]
		tris.append(t)
		for j in range(3):
			var w := wid[idx[t + j]]
			c["aabb"] = (c["aabb"] as AABB).expand(pos[w])
			if not seen.has(w):
				seen[w] = true
				pts.append(pos[w])
	var out: Array = []
	for r: int in by_root:
		var c: Dictionary = by_root[r]
		c.erase("seen")
		out.append(c)
	return out


static func _root_of(parent: PackedInt32Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i


## One mesh for a set of pieces, moved by xf into their joint's frame (one surface per source
## surface, keeping its material).
static func _group(surfs: Array, parts: Array, xf: Transform3D) -> ArrayMesh:
	var by_surf := {}
	for c: Dictionary in parts:
		if not by_surf.has(c["surf"]):
			by_surf[c["surf"]] = []
		(by_surf[c["surf"]] as Array).append(c)
	var out := ArrayMesh.new()
	var keys := by_surf.keys()
	keys.sort()
	for s: int in keys:
		var src: Array = surfs[s]["arrays"]
		var v: PackedVector3Array = src[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = src[Mesh.ARRAY_INDEX]
		var nrm: Variant = src[Mesh.ARRAY_NORMAL]
		var tan: Variant = src[Mesh.ARRAY_TANGENT]
		var uv: Variant = src[Mesh.ARRAY_TEX_UV]
		var col: Variant = src[Mesh.ARRAY_COLOR]
		var remap := {}
		var nv := PackedVector3Array()
		var nn := PackedVector3Array()
		var nt := PackedFloat32Array()
		var nuv := PackedVector2Array()
		var nc := PackedColorArray()
		var ni := PackedInt32Array()
		for c: Dictionary in by_surf[s]:
			for t: int in c["tris"]:
				for j in range(3):
					var vi := idx[t + j]
					if not remap.has(vi):
						remap[vi] = nv.size()
						nv.append(xf * v[vi])
						if nrm is PackedVector3Array:
							nn.append((xf.basis * (nrm as PackedVector3Array)[vi]).normalized())
						if tan is PackedFloat32Array and (tan as PackedFloat32Array).size() >= (vi + 1) * 4:
							var ta := tan as PackedFloat32Array
							var tv := xf.basis * Vector3(ta[vi * 4], ta[vi * 4 + 1], ta[vi * 4 + 2])
							nt.append_array(PackedFloat32Array([tv.x, tv.y, tv.z, ta[vi * 4 + 3]]))
						if uv is PackedVector2Array:
							nuv.append((uv as PackedVector2Array)[vi])
						if col is PackedColorArray:
							nc.append((col as PackedColorArray)[vi])
					ni.append(remap[vi])
		var arr: Array = []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = nv
		if nn.size() == nv.size():
			arr[Mesh.ARRAY_NORMAL] = nn
		if nt.size() == nv.size() * 4:
			arr[Mesh.ARRAY_TANGENT] = nt
		if nuv.size() == nv.size():
			arr[Mesh.ARRAY_TEX_UV] = nuv
		if nc.size() == nv.size():
			arr[Mesh.ARRAY_COLOR] = nc
		arr[Mesh.ARRAY_INDEX] = ni
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		out.surface_set_material(out.get_surface_count() - 1, surfs[s]["material"])
	return out
