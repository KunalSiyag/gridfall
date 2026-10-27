extends RefCounted
## The procedural animals' shared half (used by pigeon_body.gd, duck_body.gd and
## squirrel_body.gd): the arrays a body's mesh is built into and the shape builders that loft
## them — a tube of elliptic rings, an ellipsoid, a sheet through a grid of points and a thin
## beam. A body file sets the arrays' part, region and tag for the vertices it adds next, calls
## these builders with its own tables and colour callables, and ends with the ArrayMesh; its
## shader reads the UVs these leave (UV.x the part, UV.y the region, UV2.x the motion tag, UV2.y
## the vertex's share of that motion).


## The arrays the mesh is built into; part, region and tag go on the vertices added next.
class Arrays:
	extends RefCounted
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var ix := PackedInt32Array()
	var part: float = 0.0
	var region: float = 0.0
	var tag: float = 0.0

	func add(p: Vector3, nrm: Vector3, col: Color, w: float) -> int:
		v.append(p)
		n.append(nrm)
		c.append(col.srgb_to_linear())
		uv.append(Vector2(part, region))
		uv2.append(Vector2(tag, w))
		return v.size() - 1

	## Triangle a b d, wound clockwise seen from the side its normals face (Godot's front).
	func tri(a: int, b: int, d: int) -> void:
		var g := (v[b] - v[a]).cross(v[d] - v[a])
		if g.dot(n[a] + n[b] + n[d]) > 0.0:
			ix.append_array(PackedInt32Array([a, d, b]))
		else:
			ix.append_array(PackedInt32Array([a, b, d]))

	func quad(a: int, b: int, d: int, e: int) -> void:
		tri(a, b, d)
		tri(a, d, e)

	func mesh() -> ArrayMesh:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = v
		arrays[Mesh.ARRAY_NORMAL] = n
		arrays[Mesh.ARRAY_COLOR] = c
		arrays[Mesh.ARRAY_TEX_UV] = uv
		arrays[Mesh.ARRAY_TEX_UV2] = uv2
		arrays[Mesh.ARRAY_INDEX] = ix
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		return m


## A tube through centres with elliptic rings (radii: half width, half height), closed at both
## ends; w each ring's share of the motion its tag moves (empty: none), parts each ring's part
## the fragment colours (empty: the arrays' own), colour(u along, up -1..1) its vertex colour (an
## invalid Callable: white). flat squashes the ring's top so a back can be flatter than a belly.
static func loft(
	b: Arrays,
	centres: PackedVector3Array,
	radii: PackedVector2Array,
	w: PackedFloat32Array,
	segs: int,
	colour: Callable,
	flat: float = 0.0,
	parts: PackedFloat32Array = PackedFloat32Array()
) -> void:
	var n := centres.size()
	var first := b.v.size()
	for k in range(n):
		var t := (centres[mini(k + 1, n - 1)] - centres[maxi(k - 1, 0)]).normalized()
		var up := t.cross(Vector3.RIGHT).normalized()
		var r := radii[k]
		if not parts.is_empty():
			b.part = parts[k]
		for j in range(segs):
			var a := TAU * j / segs
			var sy := sin(a)
			var ry := r.y * (1.0 - flat * maxf(sy, 0.0) * maxf(sy, 0.0))
			var p := centres[k] + Vector3.RIGHT * r.x * cos(a) + up * ry * sy
			var nrm := Vector3.RIGHT * cos(a) / maxf(r.x, 1e-4) + up * sy / maxf(ry, 1e-4)
			var col := Color.WHITE
			if colour.is_valid():
				col = colour.call(float(k) / (n - 1), sy)
			b.add(p, nrm.normalized(), col, w[k] if not w.is_empty() else 0.0)
	for k in range(n - 1):
		for j in range(segs):
			var a0 := first + k * segs + j
			var a1 := first + k * segs + (j + 1) % segs
			b.quad(a0, a1, a1 + segs, a0 + segs)
	for end: int in [0, n - 1]:
		var t := (centres[mini(end + 1, n - 1)] - centres[maxi(end - 1, 0)]).normalized()
		var out := -t if end == 0 else t
		var ring := first + end * segs
		var col := b.c[ring]
		if not parts.is_empty():
			b.part = parts[end]
		var mid := b.add(centres[end], out, col, w[end] if not w.is_empty() else 0.0)
		for j in range(segs):
			b.tri(mid, ring + j, ring + (j + 1) % segs)


## An ellipsoid at c of half-axes r (segs around), every vertex at share 1 of the motion.
static func ellipsoid(b: Arrays, c: Vector3, r: Vector3, segs: int, col: Color) -> void:
	var rings := 7
	var centres := PackedVector3Array()
	var radii := PackedVector2Array()
	var w := PackedFloat32Array()
	for k in range(rings):
		var phi := PI * float(k) / (rings - 1)
		centres.append(c + Vector3(0.0, 0.0, -r.z * cos(phi)))
		radii.append(Vector2(r.x, r.y) * maxf(sin(phi), 0.02))
		w.append(1.0)
	loft(b, centres, radii, w, segs, func(_u: float, _up: float) -> Color: return col)


## A sheet through grid (rows of points) with a colour per point, its normals turned toward out.
## regions, when given, is a UV.y per point (a patch's share across it); otherwise every point
## carries the region the caller set.
static func sheet(
	b: Arrays,
	grid: Array[PackedVector3Array],
	cols: Array[PackedColorArray],
	out: Vector3,
	regions: Array[PackedFloat32Array] = []
) -> void:
	var rows := grid.size()
	var per := grid[0].size()
	var first := b.v.size()
	var region := b.region
	for r in range(rows):
		for k in range(per):
			var along := grid[mini(r + 1, rows - 1)][k] - grid[maxi(r - 1, 0)][k]
			var across := grid[r][mini(k + 1, per - 1)] - grid[r][maxi(k - 1, 0)]
			var nrm := along.cross(across).normalized()
			if nrm.dot(out) < 0.0:
				nrm = -nrm
			b.region = region if regions.is_empty() else regions[r][k]
			b.add(grid[r][k], nrm, cols[r][k], 0.0)
	for r in range(rows - 1):
		for k in range(per - 1):
			var a := first + r * per + k
			b.quad(a, a + 1, a + per + 1, a + per)
	b.region = region


## A thin box from a to b, w wide and h deep, flat-shaded (no end caps).
static func beam(b: Arrays, from: Vector3, to: Vector3, w: float, h: float) -> void:
	var d := (to - from).normalized()
	var ref := Vector3.UP if absf(d.y) < 0.9 else Vector3.BACK
	var s1 := d.cross(ref).normalized()
	var s2 := d.cross(s1).normalized()
	for face: Array in [[s1, s2], [s2, -s1], [-s1, -s2], [-s2, s1]]:
		var nrm: Vector3 = face[0]
		var edge: Vector3 = face[1]
		var off := nrm * (0.5 * (w if absf(nrm.dot(s1)) > 0.5 else h))
		var half := edge * (0.5 * (w if absf(edge.dot(s1)) > 0.5 else h))
		var k := b.add(from + off - half, nrm, Color.WHITE, 0.0)
		b.add(from + off + half, nrm, Color.WHITE, 0.0)
		b.add(to + off + half, nrm, Color.WHITE, 0.0)
		b.add(to + off - half, nrm, Color.WHITE, 0.0)
		b.quad(k, k + 1, k + 2, k + 3)


## The centres and elliptic radii of a ring table (z, centre y, half width, half height).
static func rings(table: Array) -> Array:
	var centres := PackedVector3Array()
	var radii := PackedVector2Array()
	for r: Vector4 in table:
		centres.append(Vector3(0.0, r.y, r.x))
		radii.append(Vector2(r.z, r.w))
	return [centres, radii]


## The rings of a neck table (z, y, radius, share of the head's motion): centres, circular radii
## and the shares.
static func neck_rings(table: Array) -> Array:
	var centres := PackedVector3Array()
	var radii := PackedVector2Array()
	var w := PackedFloat32Array()
	for r: Vector4 in table:
		centres.append(Vector3(0.0, r.y, r.x))
		radii.append(Vector2(r.z, r.z))
		w.append(r.w)
	return [centres, radii, w]


## The material for a body's shader with every parameter of params set.
static func material(shader: Shader, params: Dictionary) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	for k: String in params:
		m.set_shader_parameter(k, params[k])
	return m


## A body's mesh, built once by its own parts (a static func of its arrays) and cached.
static func build(cache: Array, parts: Callable) -> ArrayMesh:
	if cache[0] == null:
		var b := Arrays.new()
		parts.call(b)
		cache[0] = b.mesh()
	return cache[0]


## A body's material, built once (its shader with params set) and cached.
static func make_material(cache: Array, shader: Shader, params: Dictionary) -> ShaderMaterial:
	if cache[0] == null:
		cache[0] = material(shader, params)
	return cache[0]
