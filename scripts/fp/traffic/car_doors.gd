extends RefCounted
## The driver's door of a full car model (vehicles_v2) as a part of its own that swings open on a
## hinge at its front edge. The generator (tools/blender/realcity/vehicles2.py) builds each body
## as one mesh and draws the doors' shut lines down its sides as thin dark strips from just above
## the sill to under the belt; the driver's door lies between the strips around the driver's seat
## (Seat_Driver, on +X; the models face +Z). The cut takes, between those lines and above the
## strips' foot: the outer skin and what sits on it (handle, trim, the mirror), the door card
## behind it, and above the belt the side glass with its frame. Triangles that cross a shut line
## or the foot are split there, so the shut door shows no seam. Once per model (cached); a drawn
## car gets its door on demand (pose) and keeps it, shut, when its node goes back to the pool.
## Lengths below are model units (the generator's metre is WS.M).

const WS := preload("res://scripts/fp/world_scale.gd")
const SEAT_NODE := "Seat_Driver"
## Fully open, the rear edge has swung out by this angle (radians).
const OPEN_ANGLE := deg_to_rad(68.0)
## A shut-line strip: at most STRIP_W along the car, at least STRIP_SPAN of the body height tall,
## STRIP_TRIS triangles or more, facing out (+X) beyond STRIP_SIDE of the half width.
const STRIP_W := 0.03 * WS.M
const STRIP_JOIN := 0.015 * WS.M
const STRIP_SPAN := 0.35
const STRIP_TRIS := 6
const STRIP_SIDE := 0.6
## The strips stand this far off the skin (side_line's out) and stop this far under the belt.
const STRIP_OFF := 0.0012 * WS.M
const BELT_ABOVE := 0.015 * WS.M
## A door is DOOR_MIN to DOOR_MAX long; vans draw no line behind the front door, which then ends
## DOOR_FALLBACK behind its front line.
const DOOR_MIN := 0.7 * WS.M
const DOOR_MAX := 1.7 * WS.M
const DOOR_FALLBACK := 0.95 * WS.M
## Below the belt the door is the skin and what is on it (within SKIN_IN inside it) and the door
## card (facing in, within CARD_IN); above it the side glass and its frame (facing out, within
## GLASS_IN of the line from the belt to the glass top) and what stands out past the belt line
## (the mirror, within MIRROR_IN).
const SKIN_IN := 0.024 * WS.M
const CARD_IN := 0.12 * WS.M
const GLASS_IN := 0.03 * WS.M
const MIRROR_IN := 0.012 * WS.M
const GLASS_NX := 0.85
const CARD_NX := -0.7
## The side glass reaches at least this far over the belt (a truck's cab corner has none).
const GLASS_MIN := 0.2 * WS.M
## The handle sits this far ahead of the door's rear edge and under the belt (vehicles2 handle).
const HANDLE_BACK := 0.24 * WS.M
const HANDLE_DOWN := 0.075 * WS.M
## Points this close to a cutting plane count as on it.
const ON_PLANE := 1e-7

## Model key -> Door.
static var _cache: Dictionary = {}


## One model's driver's door. Points and planes are in the body mesh's space.
class Door:
	extends RefCounted
	var ok: bool = false
	var why: String = ""
	## Name of the body MeshInstance3D in the model, and its transform in the model's root.
	var body_name: String = ""
	var body_xf := Transform3D.IDENTITY
	## The front (hinge) and rear shut lines (z), the door's foot (y) and the belt at each line.
	var front: float = 0.0
	var rear: float = 0.0
	var bottom: float = 0.0
	var belt_front: float = 0.0
	var belt_rear: float = 0.0
	## The outer skin along each line from the foot up: Vector2(y, x).
	var skin_front := PackedVector2Array()
	var skin_rear := PackedVector2Array()
	## Where the side glass meets the roof: its height and x.
	var top: float = 0.0
	var top_x: float = 0.0
	var hinge := Vector3.ZERO
	var handle := Vector3.ZERO
	var seat := Vector3.ZERO
	## The body without the door (same surfaces, same order) and the door, hinge at its origin.
	var body_mesh: ArrayMesh = null
	var door_mesh: ArrayMesh = null
	var door_tris: int = 0
	var cut_tris: int = 0


## Vertex arrays being cut: the source's attributes plus the points made on the cutting planes.
class Cut:
	extends RefCounted
	var pos: PackedVector3Array
	var nrm: PackedVector3Array
	var tan: PackedFloat32Array
	var col: PackedColorArray
	var uv: PackedVector2Array
	var uv2: PackedVector2Array
	var has_tan: bool = false
	var has_col: bool = false
	var has_uv: bool = false
	var has_uv2: bool = false
	var _made: Dictionary = {}

	func _init(arrays: Array) -> void:
		pos = arrays[Mesh.ARRAY_VERTEX]
		nrm = (
			arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		)
		if nrm.size() != pos.size():
			nrm.resize(pos.size())
		has_tan = arrays[Mesh.ARRAY_TANGENT] != null
		has_col = arrays[Mesh.ARRAY_COLOR] != null
		has_uv = arrays[Mesh.ARRAY_TEX_UV] != null
		has_uv2 = arrays[Mesh.ARRAY_TEX_UV2] != null
		if has_tan:
			tan = arrays[Mesh.ARRAY_TANGENT]
		if has_col:
			col = arrays[Mesh.ARRAY_COLOR]
		if has_uv:
			uv = arrays[Mesh.ARRAY_TEX_UV]
		if has_uv2:
			uv2 = arrays[Mesh.ARRAY_TEX_UV2]

	## The point where edge a-b crosses plane `plane` (axis, value), made once per edge and plane.
	func on_plane(a: int, b: int, plane: int, axis: int, value: float) -> int:
		var lo := mini(a, b)
		var hi := maxi(a, b)
		var key := Vector3i(lo, hi, plane)
		if _made.has(key):
			return _made[key]
		var d0 := pos[lo][axis] - value
		var d1 := pos[hi][axis] - value
		var f := clampf(d0 / (d0 - d1), 0.0, 1.0)
		var i := pos.size()
		pos.append(pos[lo].lerp(pos[hi], f))
		nrm.append(nrm[lo].lerp(nrm[hi], f).normalized())
		if has_tan:
			for k in range(4):
				tan.append(lerpf(tan[lo * 4 + k], tan[hi * 4 + k], f))
		if has_col:
			col.append(col[lo].lerp(col[hi], f))
		if has_uv:
			uv.append(uv[lo].lerp(uv[hi], f))
		if has_uv2:
			uv2.append(uv2[lo].lerp(uv2[hi], f))
		_made[key] = i
		return i

	## Surface arrays holding only the vertices of triangles idx, moved by shift.
	func arrays_for(idx: PackedInt32Array, shift: Vector3) -> Array:
		var remap := PackedInt32Array()
		remap.resize(pos.size())
		remap.fill(-1)
		var out := []
		out.resize(Mesh.ARRAY_MAX)
		var p := PackedVector3Array()
		var n := PackedVector3Array()
		var t := PackedFloat32Array()
		var c := PackedColorArray()
		var u := PackedVector2Array()
		var u2 := PackedVector2Array()
		var ni := PackedInt32Array()
		ni.resize(idx.size())
		for k in range(idx.size()):
			var v := idx[k]
			if remap[v] < 0:
				remap[v] = p.size()
				p.append(pos[v] + shift)
				n.append(nrm[v])
				if has_tan:
					t.append_array(tan.slice(v * 4, v * 4 + 4))
				if has_col:
					c.append(col[v])
				if has_uv:
					u.append(uv[v])
				if has_uv2:
					u2.append(uv2[v])
			ni[k] = remap[v]
		out[Mesh.ARRAY_VERTEX] = p
		out[Mesh.ARRAY_NORMAL] = n
		if has_tan:
			out[Mesh.ARRAY_TANGENT] = t
		if has_col:
			out[Mesh.ARRAY_COLOR] = c
		if has_uv:
			out[Mesh.ARRAY_TEX_UV] = u
		if has_uv2:
			out[Mesh.ARRAY_TEX_UV2] = u2
		out[Mesh.ARRAY_INDEX] = ni
		return out


## The door of the model `scene` (cached under key); check .ok.
static func of(key: String, scene: PackedScene) -> Door:
	if _cache.has(key):
		return _cache[key]
	var d := Door.new()
	_cache[key] = d
	var root := scene.instantiate() as Node3D if scene != null else null
	if root == null:
		d.why = "no model"
		return d
	var body: MeshInstance3D = null
	for n: Node in root.find_children("*", "MeshInstance3D", true, false):
		if str(n.name).ends_with("_body") and (n as MeshInstance3D).mesh is ArrayMesh:
			body = n
	var seat := root.find_child(SEAT_NODE, true, false) as Node3D
	if body == null or seat == null:
		d.why = "no body mesh" if body == null else "no seat"
		root.free()
		return d
	d.body_name = str(body.name)
	d.body_xf = _in_root(body, root)
	_analyse(d, body.mesh, d.body_xf.affine_inverse() * _in_root(seat, root).origin)
	if d.ok:
		_cut(d, body.mesh as ArrayMesh)
	root.free()
	return d


## Shows node's door opened by amount (0 shut .. 1 open), cutting it out of the body the first
## time it opens. Returns false when the model has no door.
static func pose(node: Node3D, d: Door, amount: float) -> bool:
	if node == null or d == null or not d.ok:
		return false
	var pivot := node.get_meta("door") as Node3D if node.has_meta("door") else null
	if pivot == null:
		if amount <= 0.0:
			return true
		pivot = _attach(node, d)
		if pivot == null:
			return false
	pivot.rotation.y = -OPEN_ANGLE * clampf(amount, 0.0, 1.0)
	return true


## The door's key points in the model's own space (its root node's): the hinge, the handle, the
## driver's seat (hip point), the rear edge at the belt and that edge with the door wide open.
static func points(d: Door) -> Dictionary:
	var rear := Vector3(skin_x(d, d.belt_rear, d.rear), d.belt_rear, d.rear)
	var open := d.hinge + Basis(Vector3.UP, -OPEN_ANGLE) * (rear - d.hinge)
	var xf := d.body_xf
	return {
		"hinge": xf * d.hinge,
		"handle": xf * d.handle,
		"seat": xf * d.seat,
		"rear": xf * rear,
		"open_rear": xf * open,
	}


static func _attach(node: Node3D, d: Door) -> Node3D:
	var mi := node.find_child(d.body_name, true, false) as MeshInstance3D
	if mi == null:
		return null
	mi.mesh = d.body_mesh
	var pivot := Node3D.new()
	pivot.name = "DoorFL"
	pivot.position = d.hinge
	var dm := MeshInstance3D.new()
	dm.name = "DoorMesh"
	dm.mesh = d.door_mesh
	dm.cast_shadow = mi.cast_shadow
	dm.layers = mi.layers
	pivot.add_child(dm)
	mi.add_child(pivot)
	node.set_meta("door", pivot)
	# The new mesh drops the lamp overrides: let render's lamp pass set them again.
	if node.has_meta("lamp_key"):
		node.remove_meta("lamp_key")
	return pivot


static func _in_root(n: Node3D, root: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != root:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf


# ------------------------------------------------------------------ finding the door


static func _analyse(d: Door, mesh: Mesh, seat: Vector3) -> void:
	var box := mesh.get_aabb()
	var lines := _strips(mesh, box.end.x * STRIP_SIDE, box.size.y * STRIP_SPAN)
	var front: Array = []
	var rear: Array = []
	for l: Array in lines:
		var z: float = l[0]
		if z > seat.z and (front.is_empty() or z < float(front[0])):
			front = l
		elif z < seat.z and (rear.is_empty() or z > float(rear[0])):
			rear = l
	if front.is_empty():
		d.why = "no shut line ahead of the seat"
		return
	var fz: float = front[0]
	if rear.is_empty() or fz - float(rear[0]) < DOOR_MIN or fz - float(rear[0]) > DOOR_MAX:
		rear = [fz - DOOR_FALLBACK, front[1]]
	d.front = fz
	d.rear = float(rear[0])
	d.skin_front = front[1]
	d.skin_rear = rear[1]
	d.bottom = minf(d.skin_front[0].x, d.skin_rear[0].x)
	d.belt_front = d.skin_front[d.skin_front.size() - 1].x + BELT_ABOVE
	d.belt_rear = d.skin_rear[d.skin_rear.size() - 1].x + BELT_ABOVE
	if not _glass_top(d, mesh):
		d.why = "no side glass over the belt"
		return
	var hx := 0.0
	for p: Vector2 in d.skin_front:
		hx = maxf(hx, p.y)
	d.hinge = Vector3(hx, (d.bottom + d.belt_front) * 0.5, d.front)
	var hz := d.rear + HANDLE_BACK
	var ht := inverse_lerp(d.rear, d.front, hz)
	var hy := lerpf(d.belt_rear, d.belt_front, ht) - HANDLE_DOWN
	d.handle = Vector3(skin_x(d, hy, hz), hy, hz)
	d.seat = seat
	d.ok = true


## The shut lines on the +X side: [z, the skin along it as Vector2(y, x) from the foot up], sorted
## by z. A line is a run of thin, tall, outward-facing triangles of the atlas surfaces.
static func _strips(mesh: Mesh, x_min: float, span: float) -> Array:
	var cands: Array = []
	for s in range(mesh.get_surface_count()):
		var mat := mesh.surface_get_material(s)
		var mname := mat.resource_name if mat != null else ""
		if mname.begins_with("Paint") or mname.contains("Glass") or mname.begins_with("Light"):
			continue
		var sf := _surface(mesh, s)
		var v: PackedVector3Array = sf[0]
		var nn: PackedVector3Array = sf[1]
		var idx: PackedInt32Array = sf[2]
		for t in range(0, idx.size() - 2, 3):
			var a := v[idx[t]]
			var b := v[idx[t + 1]]
			var c := v[idx[t + 2]]
			if a.x + b.x + c.x < 3.0 * x_min:
				continue
			if nn[idx[t]].x + nn[idx[t + 1]].x + nn[idx[t + 2]].x < 2.1:
				continue
			var z0 := minf(a.z, minf(b.z, c.z))
			var z1 := maxf(a.z, maxf(b.z, c.z))
			if z1 - z0 > STRIP_W:
				continue
			cands.append([(z0 + z1) * 0.5, a, b, c])
	cands.sort_custom(func(p: Array, q: Array) -> bool: return float(p[0]) < float(q[0]))
	var out: Array = []
	var k := 0
	while k < cands.size():
		var z0: float = cands[k][0]
		var run: Array = []
		while k < cands.size() and float(cands[k][0]) - z0 <= STRIP_JOIN:
			run.append(cands[k])
			k += 1
		var line := _line(run, span)
		if not line.is_empty():
			out.append(line)
	return out


## [z, skin profile] of a run of strip triangles, or [] when it is not a shut line.
static func _line(run: Array, span: float) -> Array:
	if run.size() < STRIP_TRIS:
		return []
	var zs := 0.0
	var pts: Array = []
	for r: Array in run:
		zs += float(r[0])
		for k in range(1, 4):
			var p: Vector3 = r[k]
			pts.append(Vector2(p.y, p.x - STRIP_OFF))
	pts.sort_custom(func(p: Vector2, q: Vector2) -> bool: return p.x < q.x)
	if (pts[pts.size() - 1] as Vector2).x - (pts[0] as Vector2).x < span:
		return []
	var prof := PackedVector2Array()
	var acc := Vector2.ZERO
	var n := 0
	for p: Vector2 in pts:
		if n > 0 and p.x - acc.x / n > 1e-5:
			prof.append(acc / n)
			acc = Vector2.ZERO
			n = 0
		acc += p
		n += 1
	prof.append(acc / n)
	return [zs / run.size(), prof]


## The top of the side glass between the lines: where it meets the roof (height and x). False
## when there is none, or it stops short of GLASS_MIN over the belt.
static func _glass_top(d: Door, mesh: Mesh) -> bool:
	d.top = -INF
	for s in range(mesh.get_surface_count()):
		var mat := mesh.surface_get_material(s)
		if mat == null or not mat.resource_name.contains("Glass"):
			continue
		var sf := _surface(mesh, s)
		var v: PackedVector3Array = sf[0]
		var nn: PackedVector3Array = sf[1]
		var idx: PackedInt32Array = sf[2]
		for t in range(0, idx.size() - 2, 3):
			var c := (v[idx[t]] + v[idx[t + 1]] + v[idx[t + 2]]) / 3.0
			var nx := (nn[idx[t]] + nn[idx[t + 1]] + nn[idx[t + 2]]).normalized().x
			if c.x <= 0.0 or c.z <= d.rear or c.z >= d.front or nx < GLASS_NX:
				continue
			for k in range(3):
				var p := v[idx[t + k]]
				if p.y > d.top:
					d.top = p.y
					d.top_x = p.x
	return d.top >= maxf(d.belt_front, d.belt_rear) + GLASS_MIN


## Surface s of mesh as [vertices, normals, indices] (no indices: an empty array).
static func _surface(mesh: Mesh, s: int) -> Array:
	var arr := mesh.surface_get_arrays(s)
	var idx: Variant = arr[Mesh.ARRAY_INDEX]
	return [
		arr[Mesh.ARRAY_VERTEX], arr[Mesh.ARRAY_NORMAL], idx if idx != null else PackedInt32Array()
	]


## The outer skin's x at height y (below the belt) at z, from the two lines' profiles.
static func skin_x(d: Door, y: float, z: float) -> float:
	var t := clampf(inverse_lerp(d.rear, d.front, z), 0.0, 1.0) if d.front > d.rear else 1.0
	return lerpf(_profile_x(d.skin_rear, y), _profile_x(d.skin_front, y), t)


static func _profile_x(prof: PackedVector2Array, y: float) -> float:
	if prof.is_empty():
		return 0.0
	if y <= prof[0].x:
		return prof[0].y
	for k in range(1, prof.size()):
		if y <= prof[k].x:
			var a := prof[k - 1]
			var b := prof[k]
			return lerpf(a.y, b.y, (y - a.x) / maxf(b.x - a.x, 1e-9))
	return prof[prof.size() - 1].y


## True when a piece of surface centred at c, facing n, belongs to the door (inside its lines).
static func is_door(d: Door, c: Vector3, n: Vector3) -> bool:
	var t := clampf(inverse_lerp(d.rear, d.front, c.z), 0.0, 1.0)
	var belt := lerpf(d.belt_rear, d.belt_front, t)
	if c.y <= belt:
		var skin := skin_x(d, c.y, c.z)
		if c.x >= skin - SKIN_IN:
			return true
		return n.x < CARD_NX and c.x >= skin - CARD_IN
	var xb := skin_x(d, belt, c.z)
	if c.x >= xb - MIRROR_IN:
		return true
	var k := clampf((c.y - belt) / maxf(d.top - belt, 1e-6), 0.0, 1.0)
	return n.x > GLASS_NX and c.x >= lerpf(xb, d.top_x, k) - GLASS_IN


# ------------------------------------------------------------------ cutting


static func _cut(d: Door, mesh: ArrayMesh) -> void:
	var body := ArrayMesh.new()
	var door := ArrayMesh.new()
	# (axis, value, side): a point is inside the door's slab when side * (p[axis] - value) >= 0.
	var planes := [[2, d.front, -1.0], [2, d.rear, 1.0], [1, d.bottom, 1.0]]
	var x_cut := minf(d.top_x - GLASS_IN, skin_x(d, d.bottom, d.rear) - CARD_IN)
	x_cut = minf(x_cut, skin_x(d, d.bottom, d.front) - CARD_IN)
	for s in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(s)
		var cut := Cut.new(arrays)
		var idx: PackedInt32Array = (
			arrays[Mesh.ARRAY_INDEX]
			if arrays[Mesh.ARRAY_INDEX] != null
			else PackedInt32Array(range(cut.pos.size()))
		)
		var keep := PackedInt32Array()
		var moved := PackedInt32Array()
		for t in range(0, idx.size() - 2, 3):
			var tri := PackedInt32Array([idx[t], idx[t + 1], idx[t + 2]])
			if not _near(cut.pos, tri, d, x_cut):
				keep.append_array(tri)
				continue
			d.cut_tris += 1
			var poly := tri
			for pi in range(planes.size()):
				var pl: Array = planes[pi]
				var halves := _split(cut, poly, pi, int(pl[0]), float(pl[1]), float(pl[2]))
				_fan(halves[1], keep)
				poly = halves[0]
				if poly.size() < 3:
					break
			if poly.size() < 3:
				continue
			var cen := Vector3.ZERO
			var nrm := Vector3.ZERO
			for v in poly:
				cen += cut.pos[v]
				nrm += cut.nrm[v]
			cen /= poly.size()
			if is_door(d, cen, nrm.normalized()):
				_fan(poly, moved)
			else:
				_fan(poly, keep)
		if keep.is_empty():
			keep = PackedInt32Array([0, 0, 0])
		var mat := mesh.surface_get_material(s)
		body.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, cut.arrays_for(keep, Vector3.ZERO))
		body.surface_set_material(s, mat)
		body.surface_set_name(s, mesh.surface_get_name(s))
		if not moved.is_empty():
			door.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, cut.arrays_for(moved, -d.hinge))
			door.surface_set_material(door.get_surface_count() - 1, mat)
			d.door_tris += moved.size() / 3
	d.body_mesh = body
	d.door_mesh = door
	if d.door_tris == 0:
		d.ok = false
		d.why = "nothing between the lines"


## True when triangle tri may reach into the door: past x_cut, across the lines, above the foot.
static func _near(pos: PackedVector3Array, tri: PackedInt32Array, d: Door, x_cut: float) -> bool:
	var a := pos[tri[0]]
	var b := pos[tri[1]]
	var c := pos[tri[2]]
	if maxf(a.x, maxf(b.x, c.x)) < x_cut or maxf(a.y, maxf(b.y, c.y)) <= d.bottom:
		return false
	return maxf(a.z, maxf(b.z, c.z)) > d.rear and minf(a.z, minf(b.z, c.z)) < d.front


## Splits convex polygon poly (vertex indices) by plane `plane`: [inside, outside].
static func _split(
	cut: Cut, poly: PackedInt32Array, plane: int, axis: int, value: float, side: float
) -> Array:
	var inside := PackedInt32Array()
	var outside := PackedInt32Array()
	var n := poly.size()
	for k in range(n):
		var a := poly[k]
		var b := poly[(k + 1) % n]
		var da := side * (cut.pos[a][axis] - value)
		var db := side * (cut.pos[b][axis] - value)
		if da > ON_PLANE:
			inside.append(a)
		elif da < -ON_PLANE:
			outside.append(a)
		else:
			inside.append(a)
			outside.append(a)
		if (da > ON_PLANE and db < -ON_PLANE) or (da < -ON_PLANE and db > ON_PLANE):
			var m := cut.on_plane(a, b, plane, axis, value)
			inside.append(m)
			outside.append(m)
	return [inside, outside]


## Appends convex polygon poly to idx as a fan of triangles (winding kept).
static func _fan(poly: PackedInt32Array, idx: PackedInt32Array) -> void:
	for k in range(1, poly.size() - 1):
		idx.append(poly[0])
		idx.append(poly[k])
		idx.append(poly[k + 1])
