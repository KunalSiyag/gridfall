extends RefCounted
## The hero's strike pose layer (hero_rig.gd, like hero_look.gd and hero_limbs.gd): what makes a
## strike read as the whole body's work. On top of each strike clip's own upper-body keys (the
## tree plays them SPEED times as fast as authored) the spine and chest coil back through the
## windup, then turn and lean into the blow, peaking as the fist (or the foot) arrives and easing
## back over the recovery. A SkeletonModifier3D applies it after the tree and the other
## modifiers; it runs only while a strike clip plays, so it never touches the body seated, in the
## car, on a wall or climbing. The rig owns the clock (tick) and the tree the clock gates on; the
## measurement (measure) is the same one the actions feature lands its blows at.

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
	"push": [0.0, 12.0, 0.15],
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
var _lib: AnimationLibrary
var _tree: AnimationTree
var _fwd := Vector3.ZERO


## Measures over the skeleton sk's own clip keys (fk: hero_fk.gd over the same skeleton, lib the
## hero's animation library, root the body's scene root the forward is taken from, tree the rig's).
func _init(
	p_sk: Skeleton3D, p_fk: RefCounted, p_lib: AnimationLibrary, root: Node3D, p_tree: AnimationTree
) -> void:
	_sk = p_sk
	_fk = p_fk
	_lib = p_lib
	_tree = p_tree
	_fwd = p_fk.call("forward_of", root)
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


## Ends the layer (the strike over, faded out or stopped).
func end() -> void:
	clip = ""
	if _mod != null:
		_mod.active = false


## Runs the layer's clock on by dt, ending it once its strike is no longer the one playing (a
## start waits a frame or two for the tree to take its request; stop_action ends it at once).
func tick(dt: float) -> void:
	if clip.is_empty():
		return
	_t += dt
	if _wait > 0:
		_wait -= 1
		return
	var on := (
		bool(_tree.get(P_KICK)) if clip == "kick" else _asked == clip and bool(_tree.get(P_ACT))
	)
	if not on:
		end()


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
	if sk == null or clip.is_empty():
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
