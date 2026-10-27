extends RefCounted
## The squirrel every squirrel MultiMesh draws: one ArrayMesh built in code (metres, facing +Z,
## the feet at the origin) and its ShaderMaterial (squirrel.gdshader swings the four legs in a
## gallop, sits the front of the body up, sways the tail and leans the run by each animal's
## INSTANCE_CUSTOM). The vertex colours paint an eastern grey squirrel of about half a kilogram:
## 0.22 m from the nose to the tail's root, 0.09 m at the shoulder, a grizzled grey-brown back
## fading to the cream belly and throat, a blunt muzzle, small tufted ears, dark eyes, slim front
## paws under bigger hind haunches, and the signature: a fluffed tail rising in a gentle S up over
## the back, grey with a pale silver fringe. Each animal's instance colour tints it.

const SHADER := preload("res://scripts/fp/animals/squirrel.gdshader")
const PB := preload("res://scripts/fp/animals/proc_body.gd")
## The pivots the shader moves parts about (m): the hips (the sit-up and the run lean), the
## head's base, the tail's root, the front leg's shoulder, the hind leg's hip and an ear's base.
const HIP := Vector3(0.0, 0.05, -0.012)
const NECK := Vector3(0.0, 0.07, 0.092)
const RUMP := Vector3(0.0, 0.058, -0.064)
const SHOULDER := Vector3(0.009, 0.048, 0.068)
const THIGH := Vector3(0.015, 0.052, -0.016)
const EAR_BASE := Vector3(0.0085, 0.105, 0.101)
## The sit-up's angle at full share (rad), the head's extra pitch with it (rad), how far the ears
## lay back with the run's lean (rad) and the gait's body bob (m).
const SIT_RAD := 1.0
const HEAD_PITCH := 0.45
const EAR_LAY := 0.8
const BOB_M := 0.004
## UV.x: the part the fragment shader colours.
const PLUMAGE := 0.0
const EYE := 1.0
const PAW := 2.0
const TUFT := 3.0
## UV2.x: what the vertex shader moves (its sign is the side).
const TAIL := 1.0
const LEG := 2.0
const HEAD := 3.0
const EAR := 4.0
const SEGS := 12
## The trunk's rings from the tail's root to the shoulders: (z, centre y, half width, half
## height), m; TRUNK_S each ring's share of the sit-up (planted at the hips, lifting with the
## chest).
const TRUNK := [
	Vector4(-0.068, 0.058, 0.011, 0.012),
	Vector4(-0.048, 0.058, 0.024, 0.028),
	Vector4(-0.022, 0.059, 0.03, 0.031),
	Vector4(0.006, 0.06, 0.028, 0.029),
	Vector4(0.03, 0.06, 0.025, 0.026),
	Vector4(0.05, 0.059, 0.021, 0.023),
	Vector4(0.064, 0.057, 0.015, 0.018),
	Vector4(0.074, 0.055, 0.008, 0.01),
]
const TRUNK_S: PackedFloat32Array = [0.0, 0.0, 0.08, 0.32, 0.62, 0.85, 0.95, 1.0]
## The neck's rings into the head, tagged HEAD to take its extra pitch too: the same, with
## NECK_S their shares of the sit-up.
const NECK_RINGS := [
	Vector4(0.072, 0.055, 0.013, 0.014),
	Vector4(0.086, 0.064, 0.011, 0.012),
	Vector4(0.098, 0.075, 0.007, 0.008),
]
const NECK_S: PackedFloat32Array = [0.9, 0.97, 1.0]
## The head: the skull and the blunt pale muzzle over it (m).
const SKULL := Vector3(0.0, 0.088, 0.115)
const SKULL_R := Vector3(0.021, 0.022, 0.028)
const MUZZLE := Vector3(0.0, 0.082, 0.137)
const MUZZLE_R := Vector3(0.012, 0.01, 0.014)
## A front leg's rings from the shoulder down to the paw, and a hind leg's from the haunch down
## to its long foot (the last two rings of each the dark paw): (z, centre y, half width, half
## height), m, set out from the middle at the leg's pivot's x.
const FRONT_LEG_R := [
	Vector4(0.066, 0.049, 0.006, 0.0065),
	Vector4(0.076, 0.031, 0.0062, 0.006),
	Vector4(0.084, 0.014, 0.005, 0.005),
	Vector4(0.089, 0.006, 0.0042, 0.0035),
	Vector4(0.094, 0.003, 0.0028, 0.002),
]
const HIND_LEG_R := [
	Vector4(-0.018, 0.062, 0.016, 0.018),
	Vector4(-0.024, 0.042, 0.012, 0.012),
	Vector4(-0.028, 0.022, 0.008, 0.007),
	Vector4(-0.03, 0.009, 0.0065, 0.0045),
	Vector4(-0.024, 0.004, 0.006, 0.003),
]
## The tail's rings from its root up over the back in a gentle S: (z, centre y, half width, half
## height), m; TAIL_S each ring's share of the sway (the root still, the tip most).
const TAIL_R := [
	Vector4(-0.064, 0.058, 0.012, 0.011),
	Vector4(-0.085, 0.052, 0.02, 0.017),
	Vector4(-0.102, 0.056, 0.025, 0.022),
	Vector4(-0.108, 0.075, 0.027, 0.025),
	Vector4(-0.098, 0.102, 0.028, 0.026),
	Vector4(-0.078, 0.128, 0.028, 0.026),
	Vector4(-0.052, 0.148, 0.026, 0.025),
	Vector4(-0.03, 0.158, 0.017, 0.016),
]
const TAIL_S: PackedFloat32Array = [0.0, 0.1, 0.25, 0.42, 0.6, 0.78, 0.92, 1.0]
## Plumage (sRGB; the vertices carry it linear).
const RUMP_COL := Color(0.52, 0.44, 0.36)
const BACK_COL := Color(0.47, 0.44, 0.39)
const HEAD_COL := Color(0.44, 0.42, 0.39)
const MUZZLE_COL := Color(0.63, 0.59, 0.53)
const BELLY_COL := Color(0.9, 0.86, 0.78)
const TAIL_COL := Color(0.55, 0.53, 0.5)
const FRINGE_COL := Color(0.82, 0.81, 0.79)
const EAR_COL := Color(0.38, 0.35, 0.32)

static var _cache: Array = [null]
static var _mcache: Array = [null]


## The shared squirrel mesh (built once).
static func mesh() -> ArrayMesh:
	return PB.build(_cache, _squirrel_parts)


## The shared material, its pivots and scales set from this file's constants.
static func material() -> ShaderMaterial:
	return (
		PB
		. make_material(
			_mcache,
			SHADER,
			{
				"hip": HIP,
				"neck": NECK,
				"rump": RUMP,
				"shoulder": SHOULDER,
				"thigh": THIGH,
				"ear_base": EAR_BASE,
				"sit_rad": SIT_RAD,
				"head_pitch": HEAD_PITCH,
				"ear_lay": EAR_LAY,
				"bob_m": BOB_M,
			}
		)
	)


static func _squirrel_parts(b: PB.Arrays) -> void:
	_body(b)
	_head(b)
	for sx: float in [1.0, -1.0]:
		_front_leg(b, sx)
		_hind_leg(b, sx)
		_ear(b, sx)
	_tail(b)


# ------------------------------------------------------------------ parts


## The trunk from the tail's root to the shoulders and the neck into the head: the grizzled back
## fading to the cream belly and throat, every ring sitting up by its share, the neck (tagged
## HEAD) taking the head's extra pitch too.
static func _body(b: PB.Arrays) -> void:
	var rg := PB.rings(TRUNK)
	b.part = PLUMAGE
	PB.loft(
		b, rg[0], rg[1], TRUNK_S, SEGS, func(u: float, up: float) -> Color: return _body_col(u, up)
	)
	var nr := PB.rings(NECK_RINGS)
	b.tag = HEAD
	PB.loft(b, nr[0], nr[1], NECK_S, SEGS, func(_u: float, _up: float) -> Color: return BELLY_COL)
	b.tag = 0.0


## The head: the skull and the blunt pale muzzle, the dark eyes on its sides and the nose
## leather, all tagged HEAD at share 1 to ride the sit-up.
static func _head(b: PB.Arrays) -> void:
	b.tag = HEAD
	b.part = PLUMAGE
	PB.ellipsoid(b, SKULL, SKULL_R, SEGS, HEAD_COL)
	PB.ellipsoid(b, MUZZLE, MUZZLE_R, 8, MUZZLE_COL)
	b.part = EYE
	for sx: float in [1.0, -1.0]:
		PB.ellipsoid(b, Vector3(0.0155 * sx, 0.091, 0.129), Vector3.ONE * 0.0045, 6, Color.WHITE)
	b.part = PAW
	PB.ellipsoid(b, Vector3(0.0, 0.0855, 0.15), Vector3.ONE * 0.0035, 6, Color.WHITE)
	b.tag = 0.0


## The sx side's front leg: slim, from the shoulder tucked into the chest down to the little
## dark paw, riding up with the chest when the squirrel sits (share 1).
static func _front_leg(b: PB.Arrays, sx: float) -> void:
	_leg(b, sx, SHOULDER.x, FRONT_LEG_R, BACK_COL, 1.0, 3)


## The sx side's hind leg: the big haunch from the hip down to its long dark foot, staying
## planted when the squirrel sits (share 0).
static func _hind_leg(b: PB.Arrays, sx: float) -> void:
	_leg(b, sx, THIGH.x, HIND_LEG_R, RUMP_COL, 0.0, 3)


## One leg on the sx side: the rings of table (z, centre y, half width, half height) set out
## from the middle at x, its fur the flat col, the rings from paw down the dark PAW part, every
## ring taking sit of the sit-up.
static func _leg(
	b: PB.Arrays, sx: float, x: float, table: Array, col: Color, sit: float, paw: int
) -> void:
	var centres := PackedVector3Array()
	var radii := PackedVector2Array()
	var w := PackedFloat32Array()
	var parts := PackedFloat32Array()
	for k in range(table.size()):
		var r: Vector4 = table[k]
		centres.append(Vector3(x * sx, r.y, r.x))
		radii.append(Vector2(r.z, r.w))
		w.append(sit)
		parts.append(PLUMAGE if k < paw else PAW)
	b.tag = LEG * sx
	PB.loft(b, centres, radii, w, 8, func(_u: float, _up: float) -> Color: return col, 0.0, parts)
	b.tag = 0.0


## The sx side's ear: a small cone off the back of the skull, its tip the pale tuft, tagged EAR
## (the shader lays the ears back with the run's lean) at share 1 of the head's motion.
static func _ear(b: PB.Arrays, sx: float) -> void:
	b.tag = EAR * sx
	var centres := PackedVector3Array(
		[
			Vector3(0.0085 * sx, 0.105, 0.101),
			Vector3(0.0093 * sx, 0.112, 0.0996),
			Vector3(0.0099 * sx, 0.118, 0.0978),
			Vector3(0.0104 * sx, 0.123, 0.0956),
		]
	)
	var radii := PackedVector2Array(
		[
			Vector2(0.0085, 0.0075),
			Vector2(0.0066, 0.006),
			Vector2(0.004, 0.0038),
			Vector2(0.0016, 0.0015),
		]
	)
	var w := PackedFloat32Array([1.0, 1.0, 1.0, 1.0])
	var parts := PackedFloat32Array([PLUMAGE, PLUMAGE, TUFT, TUFT])
	PB.loft(
		b, centres, radii, w, 8, func(_u: float, _up: float) -> Color: return EAR_COL, 0.0, parts
	)
	b.tag = 0.0


## The signature: the fluffed tail, rings rising from the root in a gentle S up over the back,
## grey with the pale silver fringe at its edges, tagged TAIL to sway by its share along it.
static func _tail(b: PB.Arrays) -> void:
	b.tag = TAIL
	b.part = PLUMAGE
	var rg := PB.rings(TAIL_R)
	PB.loft(
		b, rg[0], rg[1], TAIL_S, SEGS, func(u: float, up: float) -> Color: return _tail_col(u, up)
	)
	b.tag = 0.0


# ------------------------------------------------------------------ plumage


## The trunk at u (0 the tail's root, 1 the shoulders) and up (-1 the belly, 1 the back): the
## rusty rump into the grizzled grey-brown back, cream on the belly and climbing the throat.
static func _body_col(u: float, up: float) -> Color:
	var back := RUMP_COL.lerp(BACK_COL, smoothstep(0.12, 0.4, u))
	var col := BELLY_COL.lerp(back, smoothstep(-0.42, 0.22, up))
	var throat := smoothstep(0.62, 0.9, u) * (1.0 - smoothstep(-0.1, 0.5, up))
	return col.lerp(BELLY_COL, throat)


## The tail at u along its length (0 the root, 1 the tip) and up around its ring (-1 below, 1
## above): grey out of the rump, the pale silver fringe at its edges and the tip frosted too.
static func _tail_col(u: float, up: float) -> Color:
	var col := TAIL_COL.lerp(RUMP_COL, 1.0 - smoothstep(0.0, 0.2, u))
	col = col.lerp(FRINGE_COL, smoothstep(0.55, 0.8, absf(up)))
	return col.lerp(FRINGE_COL, smoothstep(0.85, 1.0, u))
