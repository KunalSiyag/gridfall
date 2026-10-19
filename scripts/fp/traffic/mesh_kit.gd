extends RefCounted
## Builds merged, vertex-coloured meshes for E's procedural stand-ins (traffic lights, signs, the
## far LOD of every vehicle and person model). One surface per mesh, so a whole junction's poles
## or a whole car costs one draw.

const WS := preload("res://scripts/fp/world_scale.gd")

var st := SurfaceTool.new()
var _open := false


func begin() -> void:
	st.clear()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_open = true


## Axis-aligned box of size sz (units) centred at the origin of xf, coloured c.
func box(xf: Transform3D, sz: Vector3, c: Color) -> void:
	var h := sz * 0.5
	var faces := [
		[Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)],
		[Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, -1)],
		[Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(1, 0, 0)],
		[Vector3(0, -1, 0), Vector3(0, 0, -1), Vector3(1, 0, 0)],
		[Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)],
		[Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0)],
	]
	for f: Array in faces:
		var n: Vector3 = f[0]
		var u: Vector3 = f[1]
		var v: Vector3 = f[2]
		var cn := n * h
		var cu := u * h
		var cv := v * h
		var p := [cn - cu - cv, cn + cu - cv, cn + cu + cv, cn - cu + cv]
		_quad(xf, p[0], p[1], p[2], p[3], n, c)


## Cylinder along +Y from the origin of xf: radius r0 at the bottom, r1 at the top, height h.
func cyl(xf: Transform3D, r0: float, r1: float, h: float, c: Color, sides: int = 10, caps: bool = true) -> void:
	for k in range(sides):
		var a0 := TAU * float(k) / float(sides)
		var a1 := TAU * float(k + 1) / float(sides)
		var d0 := Vector3(cos(a0), 0, sin(a0))
		var d1 := Vector3(cos(a1), 0, sin(a1))
		var p0 := d0 * r0
		var p1 := d1 * r0
		var p2 := d1 * r1 + Vector3(0, h, 0)
		var p3 := d0 * r1 + Vector3(0, h, 0)
		var n := ((d0 + d1) * 0.5).normalized()
		_quad(xf, p0, p3, p2, p1, n, c)
		if caps:
			_tri(xf, Vector3(0, h, 0), p3, p2, Vector3.UP, c)
			_tri(xf, Vector3.ZERO, p1, p0, Vector3.DOWN, c)


## Flat regular polygon (disc with `sides` corners) of radius r in the xf's XY plane, facing +Z.
func disc(xf: Transform3D, r: float, c: Color, sides: int = 12, rot: float = 0.0) -> void:
	for k in range(sides):
		var a0 := rot + TAU * float(k) / float(sides)
		var a1 := rot + TAU * float(k + 1) / float(sides)
		_tri(xf, Vector3.ZERO, Vector3(cos(a0), sin(a0), 0) * r, Vector3(cos(a1), sin(a1), 0) * r, Vector3(0, 0, 1), c)


## Flat triangle facing +Z in xf's XY plane.
func tri_plate(xf: Transform3D, a: Vector3, b: Vector3, c3: Vector3, c: Color) -> void:
	_tri(xf, a, b, c3, Vector3(0, 0, 1), c)


## Appends every surface of a mesh, coloured by its material albedo (emission adds a glow tint).
func mesh(xf: Transform3D, m: Mesh, overrides: Array = []) -> void:
	if m == null:
		return
	for s in range(m.get_surface_count()):
		var arr := m.surface_get_arrays(s)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var mat: Material = overrides[s] if s < overrides.size() and overrides[s] != null else m.surface_get_material(s)
		var c := Color(0.6, 0.6, 0.6)
		if mat is BaseMaterial3D:
			var bm := mat as BaseMaterial3D
			c = bm.albedo_color
			if bm.emission_enabled:
				c = c.lerp(bm.emission, 0.5)
		var nb := xf.basis.inverse().transposed()
		var count := idx.size() if not idx.is_empty() else verts.size()
		for k in range(count):
			var vi := idx[k] if not idx.is_empty() else k
			st.set_color(c)
			st.set_normal((nb * norms[vi]).normalized() if not norms.is_empty() else Vector3.UP)
			st.add_vertex(xf * verts[vi])


## Merges every MeshInstance3D under root (in root space) into one vertex-coloured mesh.
func node(root: Node3D) -> void:
	_walk(root, Transform3D.IDENTITY, true)


func _walk(n: Node, xf: Transform3D, is_root: bool) -> void:
	var t := xf
	if n is Node3D and not is_root:
		t = xf * (n as Node3D).transform
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var ov: Array = []
		if mi.mesh != null:
			for s in range(mi.mesh.get_surface_count()):
				ov.append(mi.get_surface_override_material(s))
			mesh(t, mi.mesh, ov)
	for c in n.get_children():
		_walk(c, t, false)


## The merged mesh (null when nothing was added).
func commit() -> ArrayMesh:
	if not _open:
		return null
	_open = false
	st.index()
	var m := st.commit()
	return m if m.get_surface_count() > 0 else null


func _quad(xf: Transform3D, a: Vector3, b: Vector3, c3: Vector3, d: Vector3, n: Vector3, c: Color) -> void:
	_tri(xf, a, b, c3, n, c)
	_tri(xf, a, c3, d, n, c)


func _tri(xf: Transform3D, a: Vector3, b: Vector3, c3: Vector3, n: Vector3, c: Color) -> void:
	var wn := (xf.basis * n).normalized()
	# Godot's front faces wind clockwise; emit so the face looks along n.
	var fa := xf * a
	var fb := xf * b
	var fc := xf * c3
	if (fb - fa).cross(fc - fa).dot(wn) > 0.0:
		var t := fb
		fb = fc
		fc = t
	for p: Vector3 in [fa, fb, fc]:
		st.set_color(c)
		st.set_normal(wn)
		st.add_vertex(p)


## Shared opaque material for vertex-coloured meshes.
static func vc_material(rough: float = 0.6, metal: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = rough
	m.metallic = metal
	return m
