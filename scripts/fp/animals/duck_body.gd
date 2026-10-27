extends RefCounted
## The duck every duck MultiMesh draws: one ArrayMesh built in code (metres, facing +Z, the soles
## at the origin) and its ShaderMaterial (duck.gdshader spreads and beats the wings and pitches the
## neck and head down to dabble by each duck's INSTANCE_CUSTOM). A mallard drawn to float low: a
## wide loaf of a body about 0.36 m from the bill tip to the tail tip, the waterline crossing its
## flank about two-thirds up, so a duck whose origin the behaviour puts at the water surface sits
## in the water as one does. One mesh serves both sexes: the vertex colours paint the DRAKE (a grey
## flank, a chestnut breast, a white neck ring, a green head, an olive bill) and duck.gdshader
## mixes them toward the hen's mottled browns by the duck's drake share.

const SHADER := preload("res://scripts/fp/animals/duck.gdshader")
const PB := preload("res://scripts/fp/animals/proc_body.gd")
## The pivots the shader moves parts about (m): the +X wing's shoulder, the hip a dab tips the body
## forward about and the neck's base.
const SHOULDER := Vector3(0.05, 0.012, 0.045)
const HIP := Vector3(0.0, -0.01, 0.0)
const NECK := Vector3(0.0, 0.0, 0.098)
## UV.x: the part the fragment shader colours.
const PLUMAGE := 0.0
const BILL := 1.0
const EYE := 2.0
const SPECULUM := 3.0
const FEET := 4.0
## UV.y: the plumage region a hen's palette is mixed into (part 0 only).
const R_BODY := 0.0
const R_NECK := 1.0
const R_HEAD := 2.0
const R_WING := 3.0
const R_UNDER := 4.0
## UV2.x: what the vertex shader moves (its sign is the side).
const SPREAD := 1.0
const FOLDED := 2.0
const NECK_TAG := 3.0
const FOOT_TAG := 4.0
## The hulls' ring segments and the head's rings; SEGS 10-12 keeps the mesh cheap.
const SEGS := 12
const HEAD_RINGS := 7
const BILL_SEGS := 10
## How much of a ring's height the back is flattened by (see PB.loft()).
const FLAT := 0.25
## The body's rings from the tail tip to the breast: (z, centre y, half width, half height), m.
## The widest ring is 0.13 m across and 0.11 m tall with its belly at -0.073 and its back at 0.037,
## so the waterline at y 0 crosses it two-thirds up.
const BODY := [
	Vector4(-0.15, -0.009, 0.008, 0.008),
	Vector4(-0.132, -0.014, 0.024, 0.018),
	Vector4(-0.104, -0.018, 0.043, 0.034),
	Vector4(-0.064, -0.016, 0.058, 0.051),
	Vector4(-0.02, -0.01, 0.065, 0.063),
	Vector4(0.025, -0.01, 0.064, 0.063),
	Vector4(0.065, -0.008, 0.056, 0.056),
	Vector4(0.095, -0.003, 0.043, 0.045),
	Vector4(0.116, 0.0, 0.028, 0.03),
	Vector4(0.129, 0.007, 0.008, 0.009),
]
## The neck's rings from inside the breast up into the head: (z, y, radius, share of the head's
## motion).
const NECK_RINGS := [
	Vector4(0.098, 0.0, 0.034, 0.0),
	Vector4(0.102, 0.012, 0.032, 0.15),
	Vector4(0.106, 0.026, 0.029, 0.35),
	Vector4(0.11, 0.04, 0.027, 0.55),
	Vector4(0.115, 0.053, 0.025, 0.75),
	Vector4(0.119, 0.063, 0.023, 0.9),
	Vector4(0.122, 0.07, 0.022, 1.0),
]
## The head's centre and radii (m).
const HEAD := Vector3(0.0, 0.082, 0.13)
const HEAD_R := Vector3(0.024, 0.026, 0.032)
## The bill's rings forward from inside the head: (z, y, half width, half height), m; a mallard's
## flat bill, nearly as long as the head.
const BILL_RINGS := [
	Vector4(0.15, 0.079, 0.016, 0.009),
	Vector4(0.167, 0.078, 0.015, 0.0075),
	Vector4(0.184, 0.076, 0.0135, 0.0065),
	Vector4(0.198, 0.074, 0.011, 0.0055),
	Vector4(0.21, 0.073, 0.004, 0.003),
]
## The eye on the +X side (the -X one mirrors it) and its radius, m.
const EYE_AT := Vector3(0.0195, 0.089, 0.143)
const EYE_R := 0.005
## The spread wing (+X): span (m) out from the shoulder and, at each share of it, the leading and
## trailing edges (z, m); the chord is sampled at WING_C and arched by WING_ARCH (m).
const SPAN_M := 0.24
const WING_ARCH := 0.01
const WING_E: PackedFloat32Array = [0.0, 0.15, 0.3, 0.45, 0.6, 0.75, 0.88, 1.0]
const WING_LE: PackedFloat32Array = [0.048, 0.054, 0.058, 0.057, 0.048, 0.032, 0.01, -0.018]
const WING_TE: PackedFloat32Array = [-0.062, -0.068, -0.07, -0.066, -0.058, -0.046, -0.032, -0.012]
const WING_C: PackedFloat32Array = [0.0, 0.2, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
## The folded wing: its rows from the shoulder back over the tail (FOLD_S) and its columns across
## the chord (FOLD_T), its surface _fold_at(s, t, sx, out) from FOLD_Z (z at each end), FOLD_Y (the
## chord's top at each end) and FOLD_CHORD (its depth at each end), m.
const FOLD_S: PackedFloat32Array = [0.0, 0.18, 0.36, 0.5, 0.62, 0.74, 0.86, 1.0]
const FOLD_T: PackedFloat32Array = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
const FOLD_Z := Vector2(0.082, -0.118)
const FOLD_Y := Vector2(0.03, 0.006)
const FOLD_CHORD := Vector2(0.065, 0.35)
## The speculum patches: the folded wing's shares of FOLD_S and FOLD_T, the spread wing's of WING_E
## and WING_C, the patch's grid, and how far it is lifted clear of the wing (m).
const SPEC_FOLD_S := Vector2(0.5, 0.86)
const SPEC_FOLD_T := Vector2(0.35, 0.7)
const SPEC_WING_E := Vector2(0.26, 0.52)
const SPEC_WING_C := Vector2(0.42, 0.72)
const SPEC_ROWS := 4
const SPEC_COLS := 3
const SPEC_OUT := 0.0016
## Plumage (sRGB; the vertices carry it linear), the drake's: his pale grey flank, dark brown back,
## pale belly, chestnut breast and black tail, the white of his undertail coverts, the green of his
## head and neck, the white of his neck ring and his wing's grey-brown feathers.
const FLANK_COL := Color(0.72, 0.73, 0.71)
const BACK_COL := Color(0.33, 0.3, 0.26)
const BELLY_COL := Color(0.78, 0.78, 0.75)
const BREAST_COL := Color(0.45, 0.21, 0.11)
const TAIL_COL := Color(0.2, 0.19, 0.2)
const VENT_COL := Color(0.86, 0.86, 0.84)
const NECK_COL := Color(0.15, 0.42, 0.24)
const HEAD_COL := Color(0.17, 0.46, 0.27)
const CROWN_COL := Color(0.1, 0.28, 0.18)
const RING_COL := Color(0.93, 0.93, 0.9)
const COVERT_COL := Color(0.55, 0.52, 0.46)
const PRIMARY_COL := Color(0.42, 0.4, 0.38)
const TIP_COL := Color(0.26, 0.25, 0.25)
const EDGE_COL := Color(0.68, 0.65, 0.57)
const UNDER_COL := Color(0.8, 0.79, 0.75)
const SPEC_COL := Color(0.16, 0.26, 0.55)

static var _cache: Array = [null]
static var _mcache: Array = [null]


## The shared duck mesh (built once).
static func mesh() -> ArrayMesh:
	return PB.build(_cache, _duck_parts)


## The shared material, its pivots set from this file's constants.
static func material() -> ShaderMaterial:
	return PB.make_material(_mcache, SHADER, {"shoulder": SHOULDER, "hip": HIP, "neck": NECK})


static func _duck_parts(b: PB.Arrays) -> void:
	_body(b)
	_head(b)
	for sx: float in [1.0, -1.0]:
		_folded_wing(b, sx)
		_spread_wing(b, sx)
		_foot(b, sx)


# ------------------------------------------------------------------ parts


static func _body(b: PB.Arrays) -> void:
	var rg := PB.rings(BODY)
	b.part = PLUMAGE
	b.region = R_BODY
	PB.loft(
		b,
		rg[0],
		rg[1],
		PackedFloat32Array(),
		SEGS,
		func(u: float, up: float) -> Color: return _body_col(u, up),
		FLAT
	)
	var nr := PB.neck_rings(NECK_RINGS)
	b.region = R_NECK
	b.tag = NECK_TAG
	PB.loft(b, nr[0], nr[1], nr[2], SEGS, func(u: float, _up: float) -> Color: return _neck_col(u))
	b.tag = 0.0


## The head, its bill and its eyes: all tagged NECK_TAG so the shader pitches them down to dabble,
## the head's share of the motion (UV2.y) the full 1.
static func _head(b: PB.Arrays) -> void:
	b.part = PLUMAGE
	b.region = R_HEAD
	b.tag = NECK_TAG
	var centres := PackedVector3Array()
	var radii := PackedVector2Array()
	var w := PackedFloat32Array()
	for k in range(HEAD_RINGS):
		var phi := PI * float(k) / (HEAD_RINGS - 1)
		centres.append(HEAD + Vector3(0.0, 0.0, -HEAD_R.z * cos(phi)))
		radii.append(Vector2(HEAD_R.x, HEAD_R.y) * maxf(sin(phi), 0.02))
		w.append(1.0)
	PB.loft(b, centres, radii, w, SEGS, func(_u: float, up: float) -> Color: return _head_col(up))
	b.part = EYE
	for sx: float in [1.0, -1.0]:
		PB.ellipsoid(
			b, Vector3(EYE_AT.x * sx, EYE_AT.y, EYE_AT.z), Vector3.ONE * EYE_R, 6, Color.WHITE
		)
	b.part = BILL
	centres.clear()
	radii.clear()
	var bill_w := PackedFloat32Array()
	for r: Vector4 in BILL_RINGS:
		centres.append(Vector3(0.0, r.y, r.x))
		radii.append(Vector2(r.z, r.w))
		bill_w.append(1.0)
	PB.loft(b, centres, radii, bill_w, BILL_SEGS, Callable())
	b.tag = 0.0


## The folded wing on the sx side's flank: a panel from the shoulder back over the tail, with the
## blue speculum patch lying on its trailing half.
static func _folded_wing(b: PB.Arrays, sx: float) -> void:
	b.part = PLUMAGE
	b.region = R_WING
	b.tag = FOLDED * sx
	var grid: Array[PackedVector3Array] = []
	var cols: Array[PackedColorArray] = []
	for s: float in FOLD_S:
		var row := PackedVector3Array()
		var crow := PackedColorArray()
		for t: float in FOLD_T:
			row.append(_fold_at(s, t, sx, 0.0))
			crow.append(_fold_col(s, t))
		grid.append(row)
		cols.append(crow)
	PB.sheet(b, grid, cols, Vector3(sx, 0.25, 0.0))
	_speculum_fold(b, sx)
	b.tag = 0.0


## The wing spread from the sx side's shoulder (the shader grows it out as the duck opens it), with
## the speculum patch on its secondaries.
static func _spread_wing(b: PB.Arrays, sx: float) -> void:
	b.part = PLUMAGE
	b.region = R_UNDER
	b.tag = SPREAD * sx
	var grid: Array[PackedVector3Array] = []
	var cols: Array[PackedColorArray] = []
	for e: float in WING_E:
		var row := PackedVector3Array()
		var crow := PackedColorArray()
		for c: float in WING_C:
			row.append(_wing_at(e, c, sx, 0.0))
			crow.append(_wing_col(e, c))
		grid.append(row)
		cols.append(crow)
	PB.sheet(b, grid, cols, Vector3.UP)
	_speculum_spread(b, sx)
	b.tag = 0.0


## The sx side's webbed foot, tucked under the stern just below the waterline: a shank and a flat
## web. Its FOOT_TAG keeps it still while the body tips forward to dabble.
static func _foot(b: PB.Arrays, sx: float) -> void:
	b.part = FEET
	b.tag = FOOT_TAG
	PB.beam(
		b, Vector3(0.02 * sx, -0.026, -0.072), Vector3(0.026 * sx, -0.046, -0.104), 0.006, 0.006
	)
	var grid: Array[PackedVector3Array] = []
	var cols: Array[PackedColorArray] = []
	for r in range(2):
		var spread := 0.004 + 0.008 * r
		var row := PackedVector3Array()
		var crow := PackedColorArray()
		for k in range(4):
			row.append(
				Vector3((0.026 + (float(k) - 1.5) * spread) * sx, -0.048, lerpf(-0.104, -0.138, r))
			)
			crow.append(Color.WHITE)
		grid.append(row)
		cols.append(crow)
	PB.sheet(b, grid, cols, Vector3.UP)
	b.tag = 0.0


# ------------------------------------------------------------------ wings


## The folded wing's surface at s (0 the shoulder, 1 the tip over the tail) and t (0 the chord's top
## edge, 1 its bottom) on the sx side, lifted out (m) along the flank. The rows slant back as they
## drop, so the wing lies along the flank as a duck holds it.
static func _fold_at(s: float, t: float, sx: float, out: float) -> Vector3:
	var at := clampf(s + 0.06 * (t - 0.5) * sin(PI * s), 0.0, 1.0)
	var z := lerpf(FOLD_Z.x, FOLD_Z.y, at)
	var chord := FOLD_CHORD.x * lerpf(1.0, FOLD_CHORD.y, smoothstep(0.5, 1.0, at))
	var y := lerpf(FOLD_Y.x, FOLD_Y.y, at) - chord * t
	var x := maxf(_body_x(z, y) + 0.0035, lerpf(0.022, 0.009, at)) + out
	return Vector3(x * sx, y, z)


## The spread wing's surface at e along the span and c across the chord on the sx side, lifted by up
## (m): the edges from WING_LE and WING_TE, arched by WING_ARCH.
static func _wing_at(e: float, c: float, sx: float, up: float) -> Vector3:
	var k := 0
	for i in range(WING_E.size() - 1):
		if e > WING_E[i]:
			k = i
	var f := clampf((e - WING_E[k]) / (WING_E[k + 1] - WING_E[k]), 0.0, 1.0)
	var le := lerpf(WING_LE[k], WING_LE[k + 1], f)
	var te := lerpf(WING_TE[k], WING_TE[k + 1], f)
	var y := SHOULDER.y + WING_ARCH * sin(PI * c) * (1.0 - 0.6 * e) + up
	return Vector3((SHOULDER.x + SPAN_M * e) * sx, y, lerpf(le, te, c))


## The blue speculum patch on the sx side's folded wing.
static func _speculum_fold(b: PB.Arrays, sx: float) -> void:
	var grid: Array[PackedVector3Array] = []
	for r in range(SPEC_ROWS):
		var row := PackedVector3Array()
		for k in range(SPEC_COLS):
			var s := lerpf(SPEC_FOLD_S.x, SPEC_FOLD_S.y, float(r) / (SPEC_ROWS - 1))
			var t := lerpf(SPEC_FOLD_T.x, SPEC_FOLD_T.y, float(k) / (SPEC_COLS - 1))
			row.append(_fold_at(s, t, sx, SPEC_OUT))
		grid.append(row)
	_patch(b, FOLDED * sx, Vector3(sx, 0.25, 0.0), grid)


## The blue speculum patch on the sx side's spread wing, over its secondaries.
static func _speculum_spread(b: PB.Arrays, sx: float) -> void:
	var grid: Array[PackedVector3Array] = []
	for r in range(SPEC_ROWS):
		var row := PackedVector3Array()
		for k in range(SPEC_COLS):
			var e := lerpf(SPEC_WING_E.x, SPEC_WING_E.y, float(r) / (SPEC_ROWS - 1))
			var c := lerpf(SPEC_WING_C.x, SPEC_WING_C.y, float(k) / (SPEC_COLS - 1))
			row.append(_wing_at(e, c, sx, SPEC_OUT))
		grid.append(row)
	_patch(b, SPREAD * sx, Vector3.UP, grid)


## The speculum patch: a part-3 sheet through grid (rows of points lying on the wing, lifted just
## clear of it) whose UV.y is _share()'s share across the patch, so the fragment draws its blue
## middle and white edge. It is tagged with its wing so it moves with it.
static func _patch(b: PB.Arrays, tag: float, out: Vector3, grid: Array[PackedVector3Array]) -> void:
	b.part = SPECULUM
	b.tag = tag
	var cols: Array[PackedColorArray] = []
	var regions: Array[PackedFloat32Array] = []
	for r in range(grid.size()):
		var crow := PackedColorArray()
		var rrow := PackedFloat32Array()
		for k in range(grid[r].size()):
			crow.append(SPEC_COL)
			rrow.append(_share(r, k))
		cols.append(crow)
		regions.append(rrow)
	PB.sheet(b, grid, cols, out, regions)
	b.tag = 0.0


## The share across a speculum patch at row r of SPEC_ROWS and column k of SPEC_COLS: 0 on the
## patch's border, 1 in its middle.
static func _share(r: int, k: int) -> float:
	var sr := float(r) / (SPEC_ROWS - 1)
	var tr := float(k) / (SPEC_COLS - 1)
	return minf(minf(sr, 1.0 - sr), minf(tr, 1.0 - tr)) * 2.0


# ------------------------------------------------------------------ plumage


## The ring's vertical share sy (-1..1) whose flattened height sy * (1 - FLAT * sy²) matches d, so
## the hull's width at a height can be read off a ring's radii.
static func _ring_sy(d: float) -> float:
	if d <= 0.0:
		return maxf(d, -1.0)
	var sy := clampf(d, 0.0, 1.0)
	for _i in range(4):
		var f := sy * (1.0 - FLAT * sy * sy) - d
		sy = clampf(sy - f / (1.0 - 3.0 * FLAT * sy * sy), 0.0, 1.0)
	return sy


## Half the body's width at z and height y (0 off the body).
static func _body_x(z: float, y: float) -> float:
	for k in range(BODY.size() - 1):
		var a: Vector4 = BODY[k]
		var c: Vector4 = BODY[k + 1]
		if z < a.x or z > c.x:
			continue
		var r := a.lerp(c, (z - a.x) / (c.x - a.x))
		var sy := _ring_sy((y - r.y) / r.w)
		return r.z * sqrt(maxf(0.0, 1.0 - sy * sy))
	return 0.0


## The body at u (0 the tail tip, 1 the breast) and up (-1 under, 1 on top): the drake's grey flank,
## dark back and pale belly, his chestnut breast, his black tail and the white of his undertail.
static func _body_col(u: float, up: float) -> Color:
	var col := FLANK_COL.lerp(BELLY_COL, smoothstep(0.0, -0.8, up))
	col = col.lerp(BACK_COL, smoothstep(0.1, 0.85, up))
	col = col.lerp(BREAST_COL, smoothstep(0.7, 0.92, u))
	col = col.lerp(TAIL_COL, 1.0 - smoothstep(0.03, 0.2, u))
	return col.lerp(VENT_COL, 0.8 * smoothstep(0.14, 0.04, u) * smoothstep(0.1, -0.6, up))


## The drake's head: green, darker over the crown.
static func _head_col(up: float) -> Color:
	return HEAD_COL.lerp(CROWN_COL, smoothstep(0.25, 0.95, up))


## The drake's neck at u (0 the breast, 1 the head): his chestnut breast colour below the white ring
## and the green of his head above it.
static func _neck_col(u: float) -> Color:
	if u > 0.24 and u < 0.42:
		return RING_COL
	return NECK_COL if u > 0.42 else BREAST_COL


## The folded wing at s along it and t across the chord: the drake's grey-brown feathers, paler
## toward the leading edge and darkening to the tertials over the tail.
static func _fold_col(s: float, t: float) -> Color:
	var col := COVERT_COL.lerp(EDGE_COL, smoothstep(0.4, 0.05, t))
	return col.lerp(TAIL_COL, smoothstep(0.8, 1.0, s))


## The spread wing at e along the span and c across the chord: grey-brown coverts, darker primaries
## toward the tip, a pale leading edge and the pale trailing bar over the speculum.
static func _wing_col(e: float, c: float) -> Color:
	var col := COVERT_COL.lerp(PRIMARY_COL, smoothstep(0.4, 0.62, e))
	col = col.lerp(TIP_COL, smoothstep(0.84, 0.98, e))
	col = col.lerp(EDGE_COL, 0.5 * smoothstep(0.18, 0.0, c))
	return col.lerp(UNDER_COL, 0.5 * smoothstep(0.86, 1.0, c))
