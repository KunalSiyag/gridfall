extends RefCounted
## The hero's feet on the ground they stand on (flag ground_foot_fit). The animation clips are
## authored on a flat floor and FpPlayer gives the body ONE height (the ground under its centre),
## so on a kerb, a lot slab's edge, an apron, a slope or a low wall one foot sank into the concrete
## and the other hung over it. After the animation tree has posed the skeleton this lowers the
## pelvis to the lower foot and runs a two-bone leg solve (hip, knee, ankle) per foot, so each sole
## rests ON the surface under it and no leg goes through it.
##
## Per foot two points of the sole, its two ends (the heel and the tip), are tested against the
## ground.
## All of it is relative to the flat floor the clip assumes (the avatar's origin), so the clips' own
## few centimetres of contact stay as authored and flat ground changes nothing. A foot the clip has
## planted follows the offset of the highest ground under it from that floor: up onto a kerb, down
## off it. No foot is ever lower than the ground under it (a hard floor on the shift, instant, so
## the smoothing never sinks a sole), and a swing foot is only lifted as far as it must be to clear
## what it passes over. A step of the ground (kerb, slab edge, apron) wider than a shoe is under one
## end of the sole or both, so a foot that straddles it stands on the high side: the heel is
## sampled as well as the tip, or a heel on the lip would sink into it while the tip is over the
## low ground. The pelvis drops to the lowest planted foot (never higher than the lowest
## foot's shift, so every leg can reach), and the other leg bends to reach what is left. The follow
## is smoothed (HL_FEET, HL_PELVIS). Nothing happens (and nothing is allocated) while all shifts are
## zero, as on flat ground. Off by the owner of the call (driving, climbing, ragdoll, wading, photo
## mode) and by the rig's state: only the locomotion, crouch and talk states fit.
##
## The ground comes from a Callable (world point -> ground height, NAN unknown): FpPlayer gives it
## CollisionWorld.walk_height (support_height while the hero stands on a box), so the feet agree
## with the profile the meshes were built from (GroundProfile) and with a low wall.

const WS := preload("res://scripts/fp/world_scale.gd")
const SM := preload("res://scripts/fp/player/spring_math.gd")

## Left and right leg: upper leg, lower leg, foot (ankle), toes.
const LEGS := [
	["LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "LeftToes"],
	["RightUpperLeg", "RightLowerLeg", "RightFoot", "RightToes"],
]
const HIPS := "Hips"
## The rig states the fit runs in.
const STATES := ["loco", "crouch", "talk"]
## Sole points, world units: the heel (this far behind the ankle) and the tip (this far beyond the
## toe bone); the absolute gap (tests, probes) also reads the toe bone itself (the ball).
const HEEL_BACK := 0.05 * WS.M
const TIP_AHEAD := 0.07 * WS.M
## The most a foot is raised or lowered, and the most the pelvis drops, world units.
const MAX_UP := 0.3 * WS.M
const MAX_DROP := 0.3 * WS.M
const MAX_PELVIS := 0.22 * WS.M
## A foot the clip holds this high above the flat floor (world units: the clips' own contact is up
## to about this) or less is planted and follows the ground; from PLANT_NONE up it is in swing.
const LIFT_TOL := 0.03 * WS.M
const PLANT_NONE := 0.08 * WS.M
## Below this a shift is nothing (world units): no pose is written, nothing is solved.
const EPS := 0.0006 * WS.M
## A sole sunk into the ground by less than UP_LO is left alone (the ground's noise); a planted
## foot follows an offset of the ground from the flat floor from D_LO (nothing below), fully from
## D_HI.
const UP_LO := 0.006 * WS.M
const D_LO := 0.004 * WS.M
const D_HI := 0.015 * WS.M
## Smoothing halflives (s) of a foot's shift and of the pelvis's: the fit fades in and out by these
## (every shift and the pelvis ease to zero when it goes off).
const HL_FEET := 0.04
const HL_PELVIS := 0.06
## Feet claimed by the limb IK (a kick, a guard stance, a wall hold) are not the fit's.
const CLAIMED := 0.01

## The pelvis's drop (world units, <= 0) and each foot's shift (left, right; the last frame's, for
## tests and the web probe).
var pelvis: float = 0.0
var shifts: Vector2 = Vector2.ZERO
## Frames in which a pose was written.
var solves: int = 0
var _rig: RefCounted
var _sk: Skeleton3D
var _hips: int = -1
var _bones: PackedInt32Array = PackedInt32Array()
var _rest_ankle: float = 0.0
var _rest_toe: float = 0.0
var _hips_base: Vector3 = Vector3.ZERO
var _hips_written: Vector3 = Vector3(NAN, NAN, NAN)
var _shift_s: Vector2 = Vector2.ZERO
var _pelvis_s: float = 0.0


## The fit of rig (a HeroRig: its skeleton, standing foot heights and state()); null-safe: a rig
## without the leg bones makes an inert fit (usable() is false).
func _init(rig: RefCounted) -> void:
	_rig = rig
	_sk = rig.get("skeleton") if rig != null else null
	if _sk == null:
		return
	_hips = _sk.find_bone(HIPS)
	for leg: Array in LEGS:
		for n: String in leg:
			_bones.append(_sk.find_bone(n))
	var rest: Array = rig.get("_feet_rest")
	if rest.size() >= 4:
		_rest_ankle = float(rest[0])
		_rest_toe = float(rest[2])


## True when the skeleton has the hips and every leg bone.
func usable() -> bool:
	return _sk != null and _hips >= 0 and not _bones.has(-1) and _bones.size() == 8


## Forgets the smoothed shifts (a teleport: the ground under the feet is another one).
func reset() -> void:
	_shift_s = Vector2.ZERO
	_pelvis_s = 0.0
	shifts = Vector2.ZERO
	pelvis = 0.0


## Per frame, after the rig's update has posed the skeleton. on: the owner wants the fit (grounded,
## visible, not driving, climbing or wading); ground: world point -> ground height (NAN: unknown);
## floor_y: the world height of the flat floor the clips assume (the avatar's origin).
func update(dt: float, on: bool, ground: Callable, floor_y: float) -> void:
	if not usable() or not _sk.is_inside_tree():
		return
	var live := on and ground.is_valid() and _live_state()
	var follow := Vector2.ZERO
	var floors := Vector2(-INF, -INF)
	if live:
		var l := _foot(0, ground, floor_y)
		var r := _foot(1, ground, floor_y)
		var pl := plan(l.x, l.y)
		var pr := plan(r.x, r.y)
		follow = Vector2(pl.x, pr.x)
		floors = Vector2(pl.y, pr.y)
	var drop_raw := clampf(minf(0.0, minf(follow.x, follow.y)), -MAX_PELVIS, 0.0)
	if dt <= 0.0:
		_shift_s = follow
		_pelvis_s = drop_raw
	else:
		_shift_s = Vector2(
			SM.damp(_shift_s.x, follow.x, HL_FEET, dt), SM.damp(_shift_s.y, follow.y, HL_FEET, dt)
		)
		_pelvis_s = SM.damp(_pelvis_s, drop_raw, HL_PELVIS, dt)
	# The smoothed follow may lag, the ground's floor may not: smoothing never sinks a sole.
	shifts = Vector2(maxf(_shift_s.x, floors.x), maxf(_shift_s.y, floors.y))
	pelvis = minf(_pelvis_s, minf(minf(shifts.x, shifts.y), 0.0))
	var idle := absf(pelvis) < EPS and absf(shifts.x) < EPS and absf(shifts.y) < EPS
	if idle:
		if not live:
			shifts = Vector2.ZERO
			pelvis = 0.0
		return
	_write(shifts, pelvis)


## How high each sole is above the ground under it right now (world units, negative: sunk into
## it), as Vector2(left, right): the lowest of the heel, ball and tip of each foot, from the bones'
## standing heights (the clips' own contact is a few centimetres off these, so a flat floor reads
## up to about 3 cm either way). For tests and probes.
func sole_gaps(ground: Callable, floor_y: float) -> Vector2:
	if not usable() or not _sk.is_inside_tree():
		return Vector2.ZERO
	return Vector2(_gap(0, ground, floor_y), _gap(1, ground, floor_y))


func _gap(leg: int, ground: Callable, floor_y: float) -> float:
	var gx := _sk.global_transform
	var k := gx.basis.y.length()
	var a := gx * _sk.get_bone_global_pose(_bones[leg * 4 + 2]).origin
	var t := gx * _sk.get_bone_global_pose(_bones[leg * 4 + 3]).origin
	var fwd := Vector3(t.x - a.x, 0.0, t.z - a.z)
	fwd = fwd.normalized() if fwd.length_squared() > 1e-12 else Vector3.ZERO
	var ra := _rest_ankle * k
	var rt := _rest_toe * k
	var heel := a - fwd * HEEL_BACK
	var tip := t + fwd * TIP_AHEAD
	return minf(
		heel.y - ra - _ground(ground, floor_y, heel),
		minf(t.y - rt - _ground(ground, floor_y, t), tip.y - rt - _ground(ground, floor_y, tip))
	)


## Foot `leg` (0 left, 1 right) as Vector2(offset, lift), world units: how far the highest ground
## under its heel and tip is above the flat floor, and how far the clip holds the foot above
## the floor (negative: below its standing height).
func _foot(leg: int, ground: Callable, floor_y: float) -> Vector2:
	var gx := _sk.global_transform
	var k := gx.basis.y.length()
	var a := gx * _sk.get_bone_global_pose(_bones[leg * 4 + 2]).origin
	var t := gx * _sk.get_bone_global_pose(_bones[leg * 4 + 3]).origin
	var fwd := Vector3(t.x - a.x, 0.0, t.z - a.z)
	fwd = fwd.normalized() if fwd.length_squared() > 1e-12 else Vector3.ZERO
	var lift := minf(a.y - _rest_ankle * k - floor_y, t.y - _rest_toe * k - floor_y)
	# Two samples a foot (the heel, the tip): the sole is a straight line between them, and a step
	# of the ground is wider than a shoe, so what is under any part of the sole is under one of
	# the two ends.
	var back := _ground(ground, floor_y, a - fwd * HEEL_BACK)
	var tip := _ground(ground, floor_y, t + fwd * TIP_AHEAD)
	return Vector2(maxf(back, tip) - floor_y, lift)


## The ground height under the world point p (floor_y where unknown), kept within the fit's range.
func _ground(ground: Callable, floor_y: float, p: Vector3) -> float:
	var g: float = ground.call(p)
	if is_nan(g):
		g = floor_y
	return clampf(g, floor_y - MAX_DROP, floor_y + MAX_UP)


## 1 for a foot the clip holds at or below LIFT_TOL above the flat floor, 0 from PLANT_NONE up.
static func plant_weight(lift: float) -> float:
	return 1.0 - smoothstep(LIFT_TOL, PLANT_NONE, lift)


## What a foot does about the ground under it, as Vector2(follow, floor), world units (+ up): its
## highest ground is `offset` above the flat floor and the clip holds the foot `lift` above it.
## follow is how far a planted foot goes with the ground (the offset, up or down, nothing for noise
## and for a swing foot); floor is the least the foot may be shifted without a sole under the
## ground (the offset less the clip's own lift beyond its contact tolerance; a sink under UP_LO is
## ignored): the shift is at least this, always.
static func plan(offset: float, lift: float) -> Vector2:
	var follow := offset * plant_weight(lift) * smoothstep(D_LO, D_HI, absf(offset))
	var floor_s := offset - maxf(0.0, lift - LIFT_TOL)
	if floor_s > 0.0 and floor_s < UP_LO:
		floor_s = 0.0
	return Vector2(follow, floor_s)


## True while the rig is in a state the fit runs in and no limb IK holds a foot.
func _live_state() -> bool:
	if not (str(_rig.call("state")) in STATES):
		return false
	var limbs: RefCounted = _rig.get("limbs")
	if limbs != null:
		var w: PackedFloat32Array = limbs.get("weights")
		if w.size() >= 4 and (w[2] > CLAIMED or w[3] > CLAIMED):
			return false
	return true


## Writes the pelvis's drop and both legs' solves into the skeleton's pose.
func _write(feet: Vector2, drop: float) -> void:
	var gx := _sk.global_transform
	var inv := gx.affine_inverse()
	var anchors := [Vector3.ZERO, Vector3.ZERO]
	for leg in range(2):
		anchors[leg] = gx * _sk.get_bone_global_pose(_bones[leg * 4 + 2]).origin
	var cur := _sk.get_bone_pose_position(_hips)
	if not cur.is_equal_approx(_hips_written):
		_hips_base = cur
	_hips_written = _hips_base + gx.basis.inverse() * Vector3(0.0, drop, 0.0)
	_sk.set_bone_pose_position(_hips, _hips_written)
	solves += 1
	for leg in range(2):
		var s := feet.x if leg == 0 else feet.y
		if absf(s - drop) < EPS:
			continue
		var target: Vector3 = inv * (anchors[leg] + Vector3(0.0, s, 0.0))
		solve_leg(_sk, _bones[leg * 4], _bones[leg * 4 + 1], _bones[leg * 4 + 2], target)


## The knee of a two-bone leg: hip h, bone lengths l1 (hip to knee) and l2 (knee to ankle), the
## ankle wanted at t, the knee bent toward pole (a direction). Returns [knee, ankle]: the ankle is
## t when it is within reach, else the nearest point of the fully stretched (or fully folded) leg.
static func two_bone(h: Vector3, l1: float, l2: float, t: Vector3, pole: Vector3) -> Array:
	var to_t := t - h
	var dist := to_t.length()
	if dist < 1e-9:
		return [h + pole.normalized() * l1, h]
	var d := clampf(dist, absf(l1 - l2) + 1e-6, l1 + l2 - 1e-6)
	var e := to_t / dist
	var q := pole - e * pole.dot(e)
	q = q.normalized() if q.length_squared() > 1e-12 else e.cross(Vector3.RIGHT).normalized()
	var a := (l1 * l1 - l2 * l2 + d * d) / (2.0 * d)
	var hgt := sqrt(maxf(l1 * l1 - a * a, 0.0))
	return [h + e * a + q * hgt, h + e * d]


## Poses the leg u (upper), l (lower), f (foot) of sk so that the ankle is at t (skeleton space):
## the knee keeps the side it bent to, the foot keeps its global orientation.
static func solve_leg(sk: Skeleton3D, u: int, l: int, f: int, t: Vector3) -> void:
	var gu := sk.get_bone_global_pose(u)
	var gl := sk.get_bone_global_pose(l)
	var gf := sk.get_bone_global_pose(f)
	var h := gu.origin
	var knee := gl.origin
	var ankle := gf.origin
	var l1 := h.distance_to(knee)
	var l2 := knee.distance_to(ankle)
	if l1 < 1e-6 or l2 < 1e-6 or h.distance_to(t) < 1e-6:
		return
	var along := (ankle - h).normalized()
	var bend := (knee - h) - along * (knee - h).dot(along)
	if bend.length_squared() < 1e-12:
		bend = Vector3.BACK
	var sol := two_bone(h, l1, l2, t, bend)
	var knee2: Vector3 = sol[0]
	var ankle2: Vector3 = sol[1]
	var r1 := Quaternion((knee - h).normalized(), (knee2 - h).normalized())
	var qu := r1 * gu.basis.orthonormalized().get_rotation_quaternion()
	var ankle1 := knee2 + r1 * (ankle - knee)
	var r2 := Quaternion((ankle1 - knee2).normalized(), (ankle2 - knee2).normalized())
	var ql := r2 * r1 * gl.basis.orthonormalized().get_rotation_quaternion()
	var qf := gf.basis.orthonormalized().get_rotation_quaternion()
	var parent := sk.get_bone_global_pose(sk.get_bone_parent(u)).basis.orthonormalized()
	sk.set_bone_pose_rotation(u, parent.get_rotation_quaternion().inverse() * qu)
	sk.set_bone_pose_rotation(l, qu.inverse() * ql)
	sk.set_bone_pose_rotation(f, ql.inverse() * qf)
