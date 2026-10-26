extends RefCounted
## The hero's strike pose layer (hero_rig.gd, like hero_look.gd and hero_limbs.gd): what makes a
## strike read as the whole body's work. On top of each strike clip's own upper-body keys (the
## tree plays them SPEED times as fast as authored) the spine and chest coil back through the
## windup, then turn and lean into the blow, peaking as the fist (or the foot) arrives and easing
## back over the recovery. A SkeletonModifier3D applies it after the tree and the other
## modifiers. It also supplies a planted fighting guard and guides both hands forward as a shove
## lands; the rig owns the clock (tick) and the tree the clock gates on.

const SM := preload("res://scripts/fp/player/spring_math.gd")

## Strike clips play this much faster than authored: the windup snaps and the fist is out sooner.
const SPEED := {
	"punch_jab": 1.25,
	"punch_cross": 1.2,
	"punch_hook": 1.2,
	"swing_a": 1.15,
	"swing_b": 1.15,
	"push": 1.15,
	"throw": 1.1,
	"kick": 1.1,
}
## Per clip: [chest yaw (deg, toward the punching side), lean (deg, forward), when the blow lands
## (s; -1 for the measurement's own contact)]. The push clip holds its palms out from near its
## start, so its contact stands as authored.
const POSE := {
	"punch_jab": [6.0, 5.0, -1.0],
	"punch_cross": [14.0, 7.0, -1.0],
	"punch_hook": [20.0, 6.0, -1.0],
	"swing_a": [12.0, 10.0, -1.0],
	"swing_b": [12.0, 10.0, -1.0],
	"push": [0.0, 15.0, 0.15],
	"throw": [0.0, 10.0, -1.0],
	"kick": [0.0, 5.0, 0.24],
}
## The envelope: the spine bone's share of the turn (the chest takes the rest), the windup's coil
## back as a share of the strike turn (none for a contact too soon to read), how far into the
## windup the coil is at its deepest (of the contact), and the ease back to nothing once the blow
## has landed (s).
const SPINE_SHARE := 0.45
const COIL := 0.35
const COIL_SNAP := 0.12
const COIL_AT := 0.55
const RECOVER := 0.3
## The shove's hand IK takes the arms over PUSH_IN from the start (the clip's own windup never
## shows), pulls the hands to the chest, drives both palms out from PUSH_OUT of the way to the
## contact, holds through impact, then lets go.
const PUSH_IN := 0.05
const PUSH_OUT := 0.35
const PUSH_HOLD := 0.08
const PUSH_RELEASE := 0.16
## The fighting guard eases its weight by half over this many seconds.
const GUARD_HALFLIFE := 0.07
const GUARD_MOVE_MAX := 0.12
## Distances in the procedural guard and push poses (skeleton metres).
## The guard's fists sit at the chin and cheeks with the elbows tucked in under them.
const GUARD_HAND_HEIGHT := 1.42
const GUARD_HAND_FORWARD := 0.24
const GUARD_HAND_SPREAD := 0.1
const GUARD_ELBOW_HEIGHT := 0.98
const GUARD_ELBOW_FORWARD := 0.12
const GUARD_ELBOW_SPREAD := 0.2
## The shove: hands drawn to the chest, then both palms out at chest height, elbows down.
const PULL_HAND_FORWARD := 0.2
const PULL_HAND_HEIGHT := 1.16
## The lean into the shove turns after the hand IK and carries the palms down; the height
## allows for it.
const PUSH_HAND_HEIGHT := 1.4
const PUSH_HAND_FORWARD := 0.58
const PUSH_HAND_SPREAD := 0.16
const PUSH_ELBOW_HEIGHT := 0.98
const PUSH_ELBOW_FORWARD := 0.2
const PUSH_ELBOW_SPREAD := 0.36
## Holding someone: both hands on their upper arms, GRIP_HEIGHT up and GRIP_BACK short of their
## feet, GRIP_SPREAD to each side.
const GRIP_HEIGHT := 1.28
const GRIP_BACK := 0.12
const GRIP_SPREAD := 0.19
const GRIP_ELBOW_HEIGHT := 1.0
const GRIP_ELBOW_SPREAD := 0.34
## A fist: the bend (rad) at each finger's three joints, all four fingers, about the knuckle line.
const FINGERS := ["Index", "Middle", "Ring", "Little"]
const KNUCKLES := ["Proximal", "Intermediate", "Distal"]
const FIST_BEND := [1.35, 1.5, 1.0]
const GUARD_FOOT_SPREAD := 0.15
const GUARD_FOOT_LEAD := 0.07
const P_MOVE := "parameters/sm/loco/move/blend_amount"
## The bones the turn spreads over.
const BONES := [["Spine", SPINE_SHARE], ["UpperChest", 1.0 - SPINE_SHARE]]
## The measurement: this many poses sampled over a clip's opening WITHIN seconds; a fist counts
## as out once it comes within ARRIVE (skeleton metres) of its furthest reach, so a blow lands as
## the fist arrives, not wherever a held extension creeps to.
const SAMPLES := 48
const WITHIN := 1.2
const ARRIVE := 0.03
## The rig's tree: the action and kick one-shots' active flags, which tell the layer its strike is
## still the one playing.
const P_ACT := "parameters/act/active"
const P_KICK := "parameters/kick/active"

## The strike under way: its clip ("" for none), which hand it drives (1 the left, -1 the right),
## its seconds, when its blow lands, and the frames its start still has to show up in the tree.
var clip: String = ""
var side: float = 1.0
var _t: float = 0.0
var _c: float = 0.0
var _wait: int = 0
## The action clip the rig was last asked for (strike clips included), for the same end.
var _asked: String = ""
var _mod: Mod = null
## "clip|within" -> contact (s, as the clip plays) and clip -> the hand it drives, measured once.
var _times: Dictionary = {}
var _hands: Dictionary = {}
var _sk: Skeleton3D
var _fk: RefCounted
var _limbs: RefCounted
var _lib: AnimationLibrary
var _tree: AnimationTree
var _body: Node3D
var _fwd := Vector3.ZERO
var _guard_goal: float = 0.0
var _guard: float = 0.0
var _hold := false
var _hold_at := Vector3.ZERO
## [bone, axis in the bone's own frame, bend] for each finger joint a fist closes.
var _curl: Array = []
var _hands_claimed: bool = false
var _feet_claimed: bool = false
## The last target and pole each limb was sent (hands 0-1, feet 2-3): a release re-sends them at
## weight 0, so the limb layer eases the hold out from where it lies rather than yanking the
## limb somewhere new.
var _last_t: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var _last_p: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]


## Measures over the skeleton sk's own clip keys (fk: hero_fk.gd over the same skeleton, lib the
## hero's animation library, root the body's scene root the forward is taken from, tree the rig's).
func _init(
	p_sk: Skeleton3D,
	p_fk: RefCounted,
	p_lib: AnimationLibrary,
	root: Node3D,
	p_tree: AnimationTree,
	p_limbs: RefCounted
) -> void:
	_sk = p_sk
	_fk = p_fk
	_limbs = p_limbs
	_lib = p_lib
	_tree = p_tree
	_body = root
	_fwd = p_fk.call("forward_of", root)
	for s: String in ["Left", "Right"]:
		_curl.append_array(fist_joints(p_sk, s))
	_mod = Mod.new(self)
	_mod.name = "StrikePose"
	p_sk.add_child(_mod)
	_mod.active = false


## When clip's fists (or palms) first reach furthest out in front within its first WITHIN seconds:
## where a punch or the shove lands (s), as the clip plays (SPEED). Measured once per clip on the
## body's own keys and cached.
func measure(clip: String, within: float = WITHIN) -> float:
	var key := "%s|%.3f" % [clip, within]
	if _times.has(key) and _hands.has(clip):
		return _times[key]
	var a := _lib.get_animation(clip) if _lib != null and _lib.has_animation(clip) else null
	if a == null:
		return 0.0
	var hands := []
	for h: String in ["LeftHand", "RightHand"]:
		hands.append(_fk.call("chain_to", _sk.find_bone(h)))
	var span := minf(a.length, within)
	var best := -INF
	for k in range(SAMPLES + 1):
		var t := span * float(k) / float(SAMPLES)
		for c: Array in hands:
			best = maxf(best, _fk.call("end_pos", a, a, 0.0, c, t / a.length).dot(_fwd))
	var at := span
	var which := 1.0
	var found := false
	for k in range(1, SAMPLES + 1):
		if found:
			break
		var t := span * float(k) / float(SAMPLES)
		for i in hands.size():
			if _fk.call("end_pos", a, a, 0.0, hands[i], t / a.length).dot(_fwd) >= best - ARRIVE:
				at = t
				which = 1.0 if i == 0 else -1.0
				found = true
				break
	_times[key] = at / float(SPEED.get(clip, 1.0))
	_hands[clip] = which
	return _times[key]


## Which hand clip strikes with (1 the left, -1 the right), measured once with its contact.
func hand(clip: String) -> float:
	measure(clip)
	return float(_hands.get(clip, 1.0))


## Notes the action clip the rig's tree was asked for: a strike clip starts the layer on it,
## anything else ends it (the tree resets its transition request, so the layer keeps the record).
func note(a: String) -> void:
	_asked = a
	if a in POSE:
		start(a)
	else:
		end()


## Starts the layer on strike clip a.
func start(a: String) -> void:
	clip = a
	_t = 0.0
	_wait = 2
	side = hand(a)
	var spec: Array = POSE[a]
	_c = measure(a) if float(spec[2]) < 0.0 else float(spec[2])
	if _mod != null:
		_mod.active = true


## Requests the procedural fighting guard; a playing action takes precedence over its pose.
func set_guard(on: bool) -> void:
	_guard_goal = 1.0 if on else 0.0
	if _mod != null:
		_mod.active = on or not clip.is_empty() or _guard > 0.001


## Holding someone (on) whose feet stand at at (world): while the guard is up the hands grip
## them there instead of rising to the chin.
func set_hold(on: bool, at: Vector3 = Vector3.ZERO) -> void:
	_hold = on
	_hold_at = at


## The eased guard weight, for the rig's tests.
func guard_weight() -> float:
	return _guard


## The forward-hand weight at the shove's contact, for the rig's tests.
func push_weight() -> float:
	return push_envelope(_t, _c) if clip == "push" else 0.0


## Ends the layer (the strike over, faded out or stopped).
func end() -> void:
	clip = ""
	if _mod != null:
		_mod.active = _guard > 0.001 or _guard_goal > 0.0


## Runs the layer's clock on by dt, ending it once its strike is no longer the one playing (a
## start waits a frame or two for the tree to take its request; stop_action ends it at once).
func tick(dt: float) -> void:
	if not clip.is_empty():
		_t += dt
		if _wait > 0:
			_wait -= 1
		else:
			var on := (
				bool(_tree.get(P_KICK))
				if clip == "kick"
				else _asked == clip and bool(_tree.get(P_ACT))
			)
			if not on:
				end()
	var goal := _guard_goal if clip.is_empty() else 0.0
	_guard = goal if dt <= 0.0 else SM.damp(_guard, goal, GUARD_HALFLIFE, dt)
	if _guard < 0.001 and goal <= 0.0:
		_guard = 0.0
	if _mod != null:
		_mod.active = not clip.is_empty() or _guard > 0.0 or goal > 0.0
	_update_hand_goals()


## Clip's AnimationNode played at its SPEED (a clip SPEED does not name unchanged), through a
## time scale, so the tree and measure() agree on when its blow lands.
static func paced(a: AnimationNodeAnimation, clip: String) -> AnimationNode:
	var speed := float(SPEED.get(clip, 1.0))
	if speed == 1.0:
		return a
	var bt := AnimationNodeBlendTree.new()
	bt.add_node("clip", a)
	bt.add_node("pace", AnimationNodeTimeScale.new())
	bt.connect_node("pace", 0, "clip")
	bt.connect_node("output", 0, "pace")
	return bt


## The layer's envelope now (0 with no strike under way), for tests.
func weight() -> float:
	return 0.0 if clip.is_empty() else envelope(_t, _c)


## Applies the layer to sk (the modifier's callback): the spine and chest turned and leaned into
## the blow by the envelope, on top of the tree's own pose.
func apply(sk: Skeleton3D) -> void:
	if sk == null:
		return
	if _guard > 0.0:
		_apply_guard(sk, _guard)
		_close_fists(sk, _guard)
	if clip.is_empty():
		return
	var w := envelope(_t, _c)
	if absf(w) < 1e-3:
		return
	var spec: Array = POSE[clip]
	var yaw := deg_to_rad(float(spec[0])) * w * side
	var lean := deg_to_rad(float(spec[1])) * w
	for pair: Array in BONES:
		var b := sk.find_bone(str(pair[0]))
		if b < 0:
			continue
		var pose := sk.get_bone_pose(b)
		var share := float(pair[1])
		var q := Quaternion(Vector3.UP, yaw * share) * Quaternion(Vector3.RIGHT, lean * share)
		pose.basis = Basis(q) * pose.basis
		sk.set_bone_pose(b, pose)


## Guides both palms through the shove (drawn to the chest, then out through impact); otherwise
## the fists rise to the chin (or, with someone held, grip them) and the feet set into a
## staggered stance while the hero is still.
func _update_hand_goals() -> void:
	if _limbs == null or _body == null:
		return
	var push := push_weight()
	var guard := _guard if clip.is_empty() and _guard_goal > 0.0 else 0.0
	# A hold grips at once, straight on from the reach that took hold, never sagging between.
	if _hold and guard > 0.0:
		guard = 1.0
	if push <= 0.0 and guard <= 0.0 and not _hands_claimed and not _feet_claimed:
		return
	var xf := _body.global_transform
	if push > guard and push > 0.0:
		_push_goals(xf, push)
	elif guard > 0.0:
		_guard_goals(xf, guard)
	else:
		_release_hands()
		_release_feet()


## The shove's hand goals at weight push on the body at xf.
func _push_goals(xf: Transform3D, push: float) -> void:
	var fwd := xf.basis.z.normalized()
	# The body faces +Z, so its own right is -X.
	var right := -xf.basis.x.normalized()
	var scale := maxf(xf.basis.x.length(), 1e-4)
	var out := smoothstep(_c * PUSH_OUT, _c, _t)
	var reach := lerpf(PULL_HAND_FORWARD, PUSH_HAND_FORWARD, out)
	var high := lerpf(PULL_HAND_HEIGHT, PUSH_HAND_HEIGHT, out)
	for i in 2:
		var s := -1.0 if i == 0 else 1.0
		var target := _at(xf.origin, fwd, right, scale, reach, high, s * PUSH_HAND_SPREAD)
		var pole := _at(
			xf.origin,
			fwd,
			right,
			scale,
			PUSH_ELBOW_FORWARD,
			PUSH_ELBOW_HEIGHT,
			s * PUSH_ELBOW_SPREAD
		)
		_set_goal(i, target, pole, push)
	_take_arms(push)
	_release_feet()


## The guard's (or, with someone held, the grip's) hand goals and the stance at weight guard on
## the body at xf.
func _guard_goals(xf: Transform3D, guard: float) -> void:
	var fwd := xf.basis.z.normalized()
	var right := -xf.basis.x.normalized()
	var scale := maxf(xf.basis.x.length(), 1e-4)
	var origin := xf.origin
	for i in 2:
		var s := -1.0 if i == 0 else 1.0
		var target: Vector3
		var pole: Vector3
		if _hold:
			target = (
				_hold_at
				- fwd * GRIP_BACK * scale
				+ Vector3.UP * GRIP_HEIGHT * scale
				+ right * s * GRIP_SPREAD * scale
			)
			pole = _at(origin, fwd, right, scale, 0.0, GRIP_ELBOW_HEIGHT, s * GRIP_ELBOW_SPREAD)
		else:
			target = _at(
				origin,
				fwd,
				right,
				scale,
				GUARD_HAND_FORWARD,
				GUARD_HAND_HEIGHT,
				s * GUARD_HAND_SPREAD
			)
			pole = _at(
				origin,
				fwd,
				right,
				scale,
				GUARD_ELBOW_FORWARD,
				GUARD_ELBOW_HEIGHT,
				s * GUARD_ELBOW_SPREAD
			)
		_set_goal(i, target, pole, guard)
	_hands_claimed = true
	if _hold:
		_take_arms(guard)
	if float(_tree.get(P_MOVE)) < GUARD_MOVE_MAX:
		_set_stance_feet(origin, fwd, right, scale, guard)
		_feet_claimed = true
	else:
		_release_feet()


## A point forward, up and to the side (skeleton metres) of the body at origin.
static func _at(
	origin: Vector3, fwd: Vector3, right: Vector3, scale: float, f: float, up: float, side: float
) -> Vector3:
	return origin + (fwd * f + Vector3.UP * up + right * side) * scale


## The shove owns the arms at once: the hands' IK influence is lifted to w rather than easing in
## behind the clip, whose own keys swing the arms up overhead first.
func _take_arms(w: float) -> void:
	_hands_claimed = true
	var weights: PackedFloat32Array = _limbs.get("weights")
	for i in 2:
		weights[i] = maxf(weights[i], w)
	_limbs.set("weights", weights)


func _set_goal(i: int, target: Vector3, pole: Vector3, weight: float) -> void:
	_last_t[i] = target
	_last_p[i] = pole
	_limbs.call("set_goal", i, target, pole, weight)


func _set_stance_feet(
	origin: Vector3, fwd: Vector3, right: Vector3, scale: float, weight: float
) -> void:
	var left := origin + fwd * GUARD_FOOT_LEAD * scale - right * GUARD_FOOT_SPREAD * scale
	var right_foot := origin - fwd * GUARD_FOOT_LEAD * scale + right * GUARD_FOOT_SPREAD * scale
	var pole_l := left + fwd * 0.18 * scale + Vector3.UP * 0.45 * scale
	var pole_r := right_foot + fwd * 0.18 * scale + Vector3.UP * 0.45 * scale
	_set_goal(2, left, pole_l, weight)
	_set_goal(3, right_foot, pole_r, weight)


## Gives the claimed hands back at weight 0, their targets left where the guard or the shove
## held them, so the hold eases out instead of snapping somewhere new.
func _release_hands() -> void:
	if not _hands_claimed:
		return
	for i in 2:
		_set_goal(i, _last_t[i], _last_p[i], 0.0)
	_hands_claimed = false


## The feet of the stance, given back the same way.
func _release_feet() -> void:
	if not _feet_claimed:
		return
	_set_goal(2, _last_t[2], _last_p[2], 0.0)
	_set_goal(3, _last_t[3], _last_p[3], 0.0)
	_feet_claimed = false


## The joints sk's side ("Left" or "Right") hand closes into a fist: [bone, axis, bend] each, the
## axis the knuckle line in the bone's own frame turned so the fingers fold toward the palm (the
## side the thumb's base sits on). Empty when the hand has no finger bones.
static func fist_joints(sk: Skeleton3D, side: String) -> Array:
	var names := [
		"IndexProximal", "LittleProximal", "MiddleProximal", "MiddleDistal", "ThumbProximal"
	]
	var at := {}
	for n: String in names:
		var b := sk.find_bone(side + n)
		if b < 0:
			return []
		at[n] = sk.get_bone_global_rest(b).origin
	var along: Vector3 = (at["MiddleDistal"] - at["MiddleProximal"]).normalized()
	var across: Vector3 = (at["IndexProximal"] - at["LittleProximal"]).normalized()
	var palm := across.cross(along)
	var axis := across if (at["ThumbProximal"] - at["MiddleProximal"]).dot(palm) >= 0.0 else -across
	var out := []
	for finger: String in FINGERS:
		for k in KNUCKLES.size():
			var b := sk.find_bone(side + finger + str(KNUCKLES[k]))
			if b < 0:
				continue
			var local := (sk.get_bone_global_rest(b).basis.inverse() * axis).normalized()
			out.append([b, local, float(FIST_BEND[k])])
	return out


func _close_fists(sk: Skeleton3D, weight: float) -> void:
	for j: Array in _curl:
		var b := int(j[0])
		var pose := sk.get_bone_pose(b)
		pose.basis = pose.basis * Basis(j[1] as Vector3, float(j[2]) * weight)
		sk.set_bone_pose(b, pose)


func _apply_guard(sk: Skeleton3D, weight: float) -> void:
	# A small forward brace through the pelvis makes the raised hands read as a stance.
	var hips := sk.find_bone("Hips")
	if hips >= 0:
		var pose := sk.get_bone_pose(hips)
		pose.basis = Basis(Quaternion(Vector3.RIGHT, deg_to_rad(3.0) * weight)) * pose.basis
		sk.set_bone_pose(hips, pose)


## The envelope t seconds into a strike whose blow lands at c: a coil back through the windup
## (none once the windup is too short to read), the full turn into the blow at the contact, eased
## back to nothing RECOVER after it.
static func envelope(t: float, c: float) -> float:
	if c <= 0.0:
		return 0.0
	if t >= c:
		return 1.0 - smoothstep(0.0, RECOVER, t - c)
	var coil := -COIL * clampf(c / COIL_SNAP, 0.0, 1.0)
	var k := t / c
	if k <= COIL_AT:
		return coil * sin(PI * k / (2.0 * COIL_AT))
	return lerpf(coil, 1.0, smoothstep(COIL_AT, 1.0, k))


## Shove hand IK: in over PUSH_IN from the start, held through the contact, then released.
static func push_envelope(t: float, c: float) -> float:
	if t <= c + PUSH_HOLD:
		return smoothstep(0.0, PUSH_IN, t)
	return 1.0 - smoothstep(c + PUSH_HOLD, c + PUSH_HOLD + PUSH_RELEASE, t)


## The layer's modifier: runs after the tree and the other modifiers (it is added last) and hands
## the skeleton to the layer.
class Mod:
	extends SkeletonModifier3D

	## The layer whose strike is playing.
	var layer: RefCounted

	func _init(p_layer: RefCounted) -> void:
		layer = p_layer

	func _process_modification() -> void:
		(layer as RefCounted).call("apply", get_skeleton())
