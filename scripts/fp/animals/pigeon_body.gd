extends RefCounted
## The pigeon every pigeon MultiMesh draws: one ArrayMesh built in code (metres, facing +Z, the
## feet at the origin) and its ShaderMaterial (pigeon.gdshader spreads and beats the wings, strides
## the legs, fans the tail and bobs and dips the head by each bird's INSTANCE_CUSTOM). The vertex
## colours paint a blue-bar rock dove: a slate head, the iridescent neck, pale grey wings with two
## black bars, a white rump and a dark band at the end of the tail; each bird's instance colour
## tints it to its morph.

const SHADER := preload("res://scripts/fp/animals/pigeon.gdshader")
## The pivots the shader moves parts about (m): the +X wing's shoulder, the hip and the neck's base.
const SHOULDER := Vector3(0.03, 0.134, 0.035)
const HIP := Vector3(0.0, 0.067, 0.0)
const NECK := Vector3(0.0, 0.124, 0.06)
## UV.x: the part the fragment shader colours.
const PLUMAGE := 0.0
const BEAK := 1.0
const CERE := 2.0
const EYE := 3.0
const FEET := 4.0
const SHEEN := 5.0
## UV2.x: what the vertex shader moves (its sign is the side).
const SPREAD := 1.0
const FOLDED := 2.0
const LEG := 3.0
const TAIL := 4.0
const SEGS := 12
## The body's rings from the vent to the breast: (z, centre y, half width, half height), m.
const BODY := [
	Vector4(-0.1, 0.08, 0.006, 0.006),
	Vector4(-0.088, 0.081, 0.018, 0.016),
	Vector4(-0.068, 0.083, 0.03, 0.028),
	Vector4(-0.04, 0.087, 0.041, 0.038),
	Vector4(-0.01, 0.092, 0.046, 0.045),
	Vector4(0.018, 0.097, 0.047, 0.048),
	Vector4(0.042, 0.103, 0.043, 0.046),
	Vector4(0.06, 0.11, 0.034, 0.038),
	Vector4(0.072, 0.116, 0.02, 0.024),
	Vector4(0.078, 0.12, 0.004, 0.005),
]
## The neck's rings from inside the breast up into the head: (z, y, radius, share of the head's
## motion).
const NECK_RINGS := [
	Vector4(0.05, 0.114, 0.032, 0.0),
	Vector4(0.064, 0.137, 0.028, 0.3),
	Vector4(0.074, 0.157, 0.023, 0.65),
	Vector4(0.081, 0.172, 0.019, 0.9),
	Vector4(0.085, 0.183, 0.016, 1.0),
]
const HEAD := Vector3(0.0, 0.191, 0.088)
const HEAD_R := Vector3(0.0165, 0.019, 0.023)
## The spread wing (+X): span (m) out from the shoulder, and at each share of it the leading and
## trailing edges (z, m); the chord is sampled at WING_C (rows at the bars' edges).
const SPAN_M := 0.31
const WING_E: PackedFloat32Array = [0.0, 0.15, 0.3, 0.45, 0.6, 0.75, 0.88, 1.0]
const WING_LE: PackedFloat32Array = [0.045, 0.052, 0.056, 0.058, 0.05, 0.035, 0.015, -0.015]
const WING_TE: PackedFloat32Array = [-0.085, -0.088, -0.09, -0.085, -0.075, -0.06, -0.045, -0.025]
const WING_C: PackedFloat32Array = [
	0.0, 0.25, 0.48, 0.5, 0.58, 0.6, 0.68, 0.7, 0.78, 0.8, 0.92, 1.0
]
## The folded wing from the shoulder to the tip over the tail, sampled at FOLD_S (rows at the bars'
## edges).
const FOLD_S: PackedFloat32Array = [
	0.0, 0.2, 0.42, 0.48, 0.5, 0.56, 0.58, 0.62, 0.64, 0.7, 0.72, 0.8, 0.9, 1.0
]
const TAIL_L: PackedFloat32Array = [0.0, 0.5, 0.78, 0.8, 1.0]
## Plumage (sRGB; the vertices carry it linear).
const HEAD_COL := Color(0.42, 0.44, 0.5)
const NECK_COL := Color(0.36, 0.38, 0.42)
const BACK_COL := Color(0.62, 0.64, 0.7)
const WING_COL := Color(0.68, 0.7, 0.75)
const BAR_COL := Color(0.12, 0.12, 0.13)
const PRIMARY_COL := Color(0.48, 0.5, 0.55)
const TIP_COL := Color(0.26, 0.27, 0.3)
const RUMP_COL := Color(0.85, 0.86, 0.88)
const BELLY_COL := Color(0.55, 0.57, 0.63)
const VENT_COL := Color(0.48, 0.5, 0.55)
const BREAST_COL := Color(0.5, 0.48, 0.56)
const TAIL_COL := Color(0.5, 0.52, 0.58)

static var _mesh: ArrayMesh = null
static var _mat: ShaderMaterial = null


## The arrays the mesh is built into; part, under and tag go on the vertices added next.
class Arrays:
	extends RefCounted
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var ix := PackedInt32Array()
	var part: float = 0.0
	var under: float = 0.0
	var tag: float = 0.0

	func add(p: Vector3, nrm: Vector3, col: Color, w: float) -> int:
		v.append(p)
		n.append(nrm)
		c.append(col.srgb_to_linear())
		uv.append(Vector2(part, under))
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


## The shared pigeon mesh (built once).
static func mesh() -> ArrayMesh:
	if _mesh == null:
		var b := Arrays.new()
		_body(b)
		_head(b)
		for sx: float in [1.0, -1.0]:
			_folded_wing(b, sx)
			_spread_wing(b, sx)
			_leg(b, sx)
		_tail(b)
		_mesh = b.mesh()
	return _mesh


## The shared material, its pivots set from this file's constants.
static func material() -> ShaderMaterial:
	if _mat == null:
		_mat = ShaderMaterial.new()
		_mat.shader = SHADER
		_mat.set_shader_parameter("shoulder", SHOULDER)
		_mat.set_shader_parameter("hip", HIP)
		_mat.set_shader_parameter("neck", NECK)
	return _mat


# ------------------------------------------------------------------ parts


static func _body(b: Arrays) -> void:
	var centres := PackedVector3Array()
	var radii := PackedVector2Array()
	for r: Vector4 in BODY:
		centres.append(Vector3(0.0, r.y, r.x))
		radii.append(Vector2(r.z, r.w))
	b.part = PLUMAGE
	_loft(
		b,
		centres,
		radii,
		PackedFloat32Array(),
		SEGS,
		func(u: float, up: float) -> Color: return _body_col(u, up)
	)
	centres.clear()
	radii.clear()
	var w := PackedFloat32Array()
	for r: Vector4 in NECK_RINGS:
		centres.append(Vector3(0.0, r.y, r.x))
		radii.append(Vector2(r.z, r.z))
		w.append(r.w)
	b.part = SHEEN
	_loft(b, centres, radii, w, SEGS, func(_u: float, _up: float) -> Color: return NECK_COL)


static func _head(b: Arrays) -> void:
	b.part = PLUMAGE
	_ellipsoid(b, HEAD, HEAD_R, SEGS, HEAD_COL)
	b.part = CERE
	_ellipsoid(b, Vector3(0.0, 0.1915, 0.1065), Vector3(0.0055, 0.0032, 0.006), 8, Color.WHITE)
	b.part = EYE
	for sx: float in [1.0, -1.0]:
		_ellipsoid(b, Vector3(0.0128 * sx, 0.1945, 0.0955), Vector3.ONE * 0.0042, 8, Color.WHITE)
	b.part = BEAK
	var base := Vector3(0.0, 0.187, 0.105)
	var tip := Vector3(0.0, 0.181, 0.125)
	var centres := PackedVector3Array([base, base.lerp(tip, 0.5), tip])
	var radii := PackedVector2Array([Vector2(0.005, 0.004), Vector2(0.0032, 0.0026), Vector2.ZERO])
	_loft(b, centres, radii, PackedFloat32Array([1.0, 1.0, 1.0]), 8, Callable())


## The wing folded on the sx side's flank, from the shoulder back over the tail.
static func _folded_wing(b: Arrays, sx: float) -> void:
	b.part = PLUMAGE
	b.tag = FOLDED * sx
	var grid: Array[PackedVector3Array] = []
	var cols: Array[PackedColorArray] = []
	for s: float in FOLD_S:
		var row := PackedVector3Array()
		var crow := PackedColorArray()
		for t: float in [0.0, 0.33, 0.66, 1.0]:
			# The rows slant (lower down, further back) so the bars cross the wing as they do.
			var at := clampf(s + 0.07 * (t - 0.5) * sin(PI * s), 0.0, 1.0)
			var z := lerpf(0.045, -0.175, at)
			var chord := 0.055 * lerpf(1.0, 0.18, smoothstep(0.5, 1.0, at))
			var y := lerpf(0.14, 0.096, at) - chord * t
			var x := maxf(_body_x(z, y) + 0.0035, lerpf(0.016, 0.006, at))
			row.append(Vector3(x * sx, y, z))
			crow.append(_fold_col(s))
		grid.append(row)
		cols.append(crow)
	_sheet(b, grid, cols, Vector3(sx, 0.3, 0.0))
	b.tag = 0.0


## The wing spread from the sx side's shoulder (the shader grows it out as the bird opens it).
static func _spread_wing(b: Arrays, sx: float) -> void:
	b.part = PLUMAGE
	b.under = 1.0
	b.tag = SPREAD * sx
	var grid: Array[PackedVector3Array] = []
	var cols: Array[PackedColorArray] = []
	for k in range(WING_E.size()):
		var e := WING_E[k]
		var row := PackedVector3Array()
		var crow := PackedColorArray()
		for c: float in WING_C:
			var y := SHOULDER.y + 0.012 * sin(PI * c) * (1.0 - 0.6 * e)
			var z := lerpf(WING_LE[k], WING_TE[k], c)
			row.append(Vector3((SHOULDER.x + SPAN_M * e) * sx, y, z))
			crow.append(_wing_col(e, c))
		grid.append(row)
		cols.append(crow)
	_sheet(b, grid, cols, Vector3.UP)
	b.under = 0.0
	b.tag = 0.0


static func _tail(b: Arrays) -> void:
	b.part = PLUMAGE
	b.tag = TAIL
	var grid: Array[PackedVector3Array] = []
	var cols: Array[PackedColorArray] = []
	for l: float in TAIL_L:
		var half := lerpf(0.013, 0.031, l)
		var mid := lerpf(0.083, 0.071, l)
		var row := PackedVector3Array()
		var crow := PackedColorArray()
		for k: float in [-1.0, -0.5, 0.0, 0.5, 1.0]:
			row.append(Vector3(k * half, mid - 0.008 * k * k, lerpf(-0.082, -0.205, l)))
			crow.append(TAIL_COL if l < 0.79 else BAR_COL)
		grid.append(row)
		cols.append(crow)
	_sheet(b, grid, cols, Vector3.UP)
	b.tag = 0.0


## The sx side's leg: the bare shank and four toes (three forward, one back).
static func _leg(b: Arrays, sx: float) -> void:
	b.part = FEET
	b.tag = LEG * sx
	_beam(b, Vector3(0.011 * sx, 0.058, 0.002), Vector3(0.013 * sx, 0.006, 0.01), 0.0045, 0.0045)
	var foot := Vector3(0.013 * sx, 0.0016, 0.01)
	for toe: Vector2 in [Vector2(-0.35, 0.026), Vector2(0.0, 0.031), Vector2(0.4, 0.024)]:
		var dir := Vector3(sin(toe.x) * sx, 0.0, cos(toe.x))
		_beam(b, foot, foot + dir * toe.y, 0.0035, 0.0028)
	_beam(b, foot, foot + Vector3(0.0, 0.0, -0.017), 0.0035, 0.0028)
	b.tag = 0.0


# ------------------------------------------------------------------ shapes


## A tube through centres with elliptic rings (radii: half width, half height), closed at both
## ends; w is each ring's share of the head's motion (empty: none), colour(u along, up -1..1) its
## vertex colour (an invalid Callable: white).
static func _loft(
	b: Arrays,
	centres: PackedVector3Array,
	radii: PackedVector2Array,
	w: PackedFloat32Array,
	segs: int,
	colour: Callable
) -> void:
	var n := centres.size()
	var first := b.v.size()
	for k in range(n):
		var t := (centres[mini(k + 1, n - 1)] - centres[maxi(k - 1, 0)]).normalized()
		var up := t.cross(Vector3.RIGHT).normalized()
		var r := radii[k]
		for j in range(segs):
			var a := TAU * j / segs
			var p := centres[k] + Vector3.RIGHT * r.x * cos(a) + up * r.y * sin(a)
			var nrm := Vector3.RIGHT * cos(a) / maxf(r.x, 1e-4) + up * sin(a) / maxf(r.y, 1e-4)
			var col := Color.WHITE
			if colour.is_valid():
				col = colour.call(float(k) / (n - 1), sin(a))
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
		var mid := b.add(centres[end], out, col, w[end] if not w.is_empty() else 0.0)
		for j in range(segs):
			b.tri(mid, ring + j, ring + (j + 1) % segs)


static func _ellipsoid(b: Arrays, c: Vector3, r: Vector3, segs: int, col: Color) -> void:
	var rings := 7
	var centres := PackedVector3Array()
	var radii := PackedVector2Array()
	var w := PackedFloat32Array()
	for k in range(rings):
		var phi := PI * float(k) / (rings - 1)
		centres.append(c + Vector3(0.0, 0.0, -r.z * cos(phi)))
		radii.append(Vector2(r.x, r.y) * maxf(sin(phi), 0.02))
		w.append(1.0)
	_loft(b, centres, radii, w, segs, func(_u: float, _up: float) -> Color: return col)


## A sheet through grid (rows of points) with a colour per point, its normals turned toward out.
static func _sheet(
	b: Arrays, grid: Array[PackedVector3Array], cols: Array[PackedColorArray], out: Vector3
) -> void:
	var rows := grid.size()
	var per := grid[0].size()
	var first := b.v.size()
	for r in range(rows):
		for k in range(per):
			var along := grid[mini(r + 1, rows - 1)][k] - grid[maxi(r - 1, 0)][k]
			var across := grid[r][mini(k + 1, per - 1)] - grid[r][maxi(k - 1, 0)]
			var nrm := along.cross(across).normalized()
			if nrm.dot(out) < 0.0:
				nrm = -nrm
			b.add(grid[r][k], nrm, cols[r][k], 0.0)
	for r in range(rows - 1):
		for k in range(per - 1):
			var a := first + r * per + k
			b.quad(a, a + 1, a + per + 1, a + per)


## A thin box from a to b, w wide and h deep, flat-shaded (no end caps).
static func _beam(b: Arrays, from: Vector3, to: Vector3, w: float, h: float) -> void:
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


# ------------------------------------------------------------------ plumage


## Half the body's width at z and height y (0 off the body).
static func _body_x(z: float, y: float) -> float:
	for k in range(BODY.size() - 1):
		var a: Vector4 = BODY[k]
		var c: Vector4 = BODY[k + 1]
		if z < a.x or z > c.x:
			continue
		var r := a.lerp(c, (z - a.x) / (c.x - a.x))
		var dy := (y - r.y) / r.w
		return r.z * sqrt(maxf(0.0, 1.0 - dy * dy))
	return 0.0


## The body at u (0 the vent, 1 the breast) and up (-1 under, 1 on top): a white rump, a pale back,
## grey underneath and a slate breast.
static func _body_col(u: float, up: float) -> Color:
	var back := RUMP_COL.lerp(BACK_COL, smoothstep(0.18, 0.34, u))
	var under := VENT_COL.lerp(BELLY_COL, smoothstep(0.1, 0.3, u))
	under = under.lerp(BREAST_COL, smoothstep(0.55, 0.85, u))
	var col := under.lerp(back, smoothstep(-0.35, 0.45, up))
	return col.lerp(BREAST_COL, 0.6 * smoothstep(0.78, 0.95, u))


static func _fold_col(s: float) -> Color:
	if (s >= 0.5 and s <= 0.56) or (s >= 0.64 and s <= 0.7):
		return BAR_COL
	if s < 0.42:
		return BACK_COL.lerp(WING_COL, s / 0.42)
	if s <= 0.72:
		return WING_COL
	return PRIMARY_COL.lerp(TIP_COL, (s - 0.72) / 0.28)


## The spread wing's top at e along the span and c across the chord: two black bars on the arm,
## grey primaries darkening to the tip, a dark trailing edge.
static func _wing_col(e: float, c: float) -> Color:
	var col := WING_COL.lerp(PRIMARY_COL, smoothstep(0.42, 0.62, e))
	col = col.lerp(TIP_COL, smoothstep(0.8, 0.97, e))
	var on_bar := (c >= 0.5 and c <= 0.58) or (c >= 0.7 and c <= 0.78)
	if on_bar:
		col = col.lerp(BAR_COL, 1.0 - smoothstep(0.3, 0.45, e))
	if c > 0.9:
		col = col.lerp(TIP_COL, 0.6)
	return col
