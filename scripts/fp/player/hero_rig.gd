extends RefCounted
## HC's animated hero for the player (slice A stage A2; A-player.md 6.9, TPS_PLAN 2.9). A roster
## body (AP.HERO_M / AP.HERO_F) with the gender's shared library as the default library "" and an
## AnimationTree driven from code: MANUAL process, advanced by player_avatar.update_motion with the
## player's own dt, so tests and the game step it the same way. The tree is a StateMachine
## (locomotion, crouch, jump / fall / land, the landing roll, talk, sit) under a OneShot for
## upper-body gestures.
## Locomotion blends idle with a cyclic BlendSpace1D of walk, walk_fast, run and run_fast at their
## measured speeds (SYNC_MODE_CYCLIC_MUTABLE gives the blended loops one shared cycle, so their
## left-heel phases stay locked), then a TimeScale that matches the stride to the ground speed.
## Foot contacts are the locomotion phase crossing 0 (left heel) and one half (right heel).
## The head turns toward a look target (hero_look.gd); on a wall the hands and feet reach for
## holds (hero_limbs.gd).

const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const SM := preload("res://scripts/fp/player/spring_math.gd")
const FK := preload("res://scripts/fp/player/hero_fk.gd")
const HEEL := preload("res://scripts/fp/player/heel_strike.gd")
const LOOK := preload("res://scripts/fp/player/hero_look.gd")
const LIMBS := preload("res://scripts/fp/player/hero_limbs.gd")

## Locomotion loops in blend order; HC starts each on the left-heel strike.
const LOCO := ["walk", "walk_fast", "run", "run_fast"]
## Upper-body one-shots (6.9 OneShot).
const GESTURES := ["interact", "wave", "phone", "door_try"]
## Body actions over the gestures (the actions feature): punches, the shove, emotes and the
## flinch of a blow taken (the health feature) on the upper body with quick fades; the kick and
## the dance on the whole body.
const ACTIONS := [
	"punch_jab", "punch_cross", "punch_hook", "swing_a", "swing_b", "push", "yes", "no", "shout",
	"hit_head", "hit_chest",
]
## Every clip the tree plays.
const CLIPS := [
	"idle", "walk", "walk_fast", "run", "run_fast", "crouch_idle", "crouch_walk", "jump_start",
	"fall", "land", "talk", "sit_down", "sit", "stand_up", "interact", "wave", "phone", "door_try",
	"punch_jab", "punch_cross", "punch_hook", "swing_a", "swing_b", "push", "yes", "no", "shout",
	"dance", "hit_head", "hit_chest", "knockback", "get_up", "climb_1m", "roll", "kick",
]
## Foot-slide correction: TimeScale = clamp(v / v_anim, TS_MIN, TS_MAX).
const TS_MIN := 0.5
const TS_MAX := 1.5
## Cross-fades (s): into the jump, jump to fall, into the landing, landing out, crouch, talk, sit,
## and walking off a ledge into the fall.
const XF_JUMP := 0.1
const XF_FALL := 0.14
const XF_LAND := 0.06
const XF_LAND_OUT := 0.22
const XF_CROUCH := 0.2
const XF_TALK := 0.3
const XF_SIT := 0.3
const XF_LEDGE := 0.2
## jump_start opens on a crouch before take-off, but FpPlayer leaves the ground on the press: the
## clip starts at take-off.
const JUMP_SKIP := 0.05
## A landing roll (play_action "roll") enters the roll clip ROLL_SKIP seconds in, past the dive
## that opens it, as the hands reach the ground, cross-fading over XF_ROLL.
const ROLL_SKIP := 0.4
const XF_ROLL := 0.1
## Rising faster than this fraction of JUMP_SPEED when the feet leave the ground is a jump.
const JUMP_VY := 0.5
## Ungrounded this long without a jump (off a ledge) before the fall pose (s).
const AIR_DELAY := 0.12
## The landing dip: land is blended over idle by the impact speed, LAND_MIN of it for a soft
## landing, all of it from LAND_FULL m/s down (a 0.6 m hop lands at 3.4 m/s: about half).
const LAND_MIN := 0.2
const LAND_FULL := 10.0
## Moving input may leave the landing after this fraction of the clip; otherwise it plays out.
const LAND_INTERRUPT := 0.5
## Faster than this (m/s) the body leaves (or skips) the landing for locomotion at once: the
## landing clip stands still, so its feet would slide under a moving body.
const LAND_MOVING := 0.6
## Below this (m/s) the body stands; talk and gestures need it below TALK_STILL.
const STILL := 0.05
const TALK_STILL := 0.3
## Feet analysis: samples per locomotion cycle and over idle (HEEL finds the strikes in them);
## blends are measured at 1 / BLEND_STEPS steps of weight.
const CONTACT_SAMPLES := 64
const IDLE_SAMPLES := 24
const BLEND_STEPS := 8
## UAL's crouch and landing clips, retargeted onto Rocketbox legs, hold the feet a few centimetres
## above the ground: in those states the body is lowered until both feet rest on it (each foot's
## lowest point; the other may sink at most GROUND_SINK), by at most GROUND_DOWN (GROUND_UP
## upward), with this halflife (s).
const GROUND_STATES := ["crouch", "land"]
const GROUND_DOWN := 0.08
const GROUND_UP := 0.03
const GROUND_SINK := 0.01
const HL_GROUND := 0.08
## Footsteps sound while the walk blend is at least this strong.
const STEP_MIN_MOVE := 0.25
## Gesture one-shot fades (s).
const SHOT_IN := 0.25
const SHOT_OUT := 0.35
## Action one-shot fades (a punch lands at once), the dance's, and the guard's halflife (s).
const ACT_IN := 0.06
const ACT_OUT := 0.2
const DANCE_IN := 0.3
const DANCE_OUT := 0.4
const HL_GUARD := 0.06
## The guard (fists up) is GUARD_CLIP held at GUARD_AT seconds on the upper body.
const GUARD_CLIP := "punch_jab"
const GUARD_AT := 0.0
## strike_time samples this many poses over a clip's opening seconds.
const STRIKE_SAMPLES := 48
const STRIKE_WITHIN := 1.2
## sit_down and stand_up play this much faster than authored (in and out of a car seat).
const SIT_SPEED := 1.5
const SIT_CLIPS := ["sit_down", "stand_up"]
## States the ground does not cut short for locomotion: sitting, the knock-down, the climb,
## holding on to a wall and the roll.
const HELD := ["sit_down", "sit", "stand_up", "knockback", "get_up", "climb", "wall", "roll"]
## On a wall (hold_wall) the body holds WALL_CLIP under the limbs' IK, faded in and out over
## XF_WALL (s).
const WALL_CLIP := "idle"
const XF_WALL := 0.15
## A gesture moves the bones from here up; the legs keep their state.
const UPPER_ROOT := "Spine"
const P_SM := "parameters/sm/playback"
const P_MOVE := "parameters/sm/loco/move/blend_amount"
const P_BS := "parameters/sm/loco/bs/blend_position"
const P_TS := "parameters/sm/loco/ts/scale"
const P_PHASE := "parameters/sm/loco/bs/walk/"
const P_CBS := "parameters/sm/crouch/bs/blend_position"
const P_CTS := "parameters/sm/crouch/ts/scale"
const P_CPHASE := "parameters/sm/crouch/bs/walk/"
const P_LAND := "parameters/sm/land/mix/blend_amount"
const P_GESTURE := "parameters/gesture/transition_request"
const P_SHOT := "parameters/shot/request"
const P_SHOT_ACTIVE := "parameters/shot/active"
const P_ACTION := "parameters/action/transition_request"
const P_ACT := "parameters/act/request"
const P_ACT_ACTIVE := "parameters/act/active"
const P_DANCE := "parameters/dance/request"
const P_DANCE_ACTIVE := "parameters/dance/active"
const P_KICK := "parameters/kick/request"
const P_KICK_ACTIVE := "parameters/kick/active"
const P_GUARD := "parameters/guard/blend_amount"
const P_GUARD_SEEK := "parameters/guard_at/seek_request"
const P_GUARD_HOLD := "parameters/guard_hold/scale"

## The body's scene root (faces +Z, feet at y = 0, metric) and its parts.
var body: Node3D
var skeleton: Skeleton3D
var tree: AnimationTree
var playback: AnimationNodeStateMachinePlayback
## The head look, and the hands and feet on holds.
var look: LOOK
var limbs: LIMBS
var meshes: Array[GeometryInstance3D] = []
## "m" or "f".
var gender: String = "m"
## Clip -> ground speed in m/s on this body at its CharacterRoot scale (speed_mps * hip ratio *
## h_target / rest height), and clip -> length (s).
var speeds: Dictionary = {}
var lengths: Dictionary = {}
## The last foot-slide factor v / v_anim (clamped; 1 while standing) and the locomotion phase
## (cycles, 0..1: the left heel strikes at 0, the right at 0.5; -1 outside locomotion).
var time_scale: float = 1.0
var phase: float = -1.0
## The idle-to-walk weight of the last update.
var move: float = 0.0
## Foot contacts of the last update: [{"left": bool, "pos": Vector3 (world, the foot's ground point)}].
var contacts: Array[Dictionary] = []
## How far the body is lowered to put the soles on the ground (skeleton metres; _update_ground).
var ground_fix: float = 0.0
## How far the guard is up (0..1).
var guard: float = 0.0
var _feet: Array[int] = []
var _feet_rest: Array[float] = []
var _contact: Dictionary = {}
var _chains: Array = []
var _fk: FK
var _lib: AnimationLibrary
var _air_t: float = 0.0
var _land_t: float = 0.0
var _sit: bool = false
var _prev_state: String = ""
var _prev_phase: float = -1.0
var _last_vy: float = 0.0
var _guard_goal: float = 0.0
## Seconds until the playing action (dance) fades out by itself; INF for at its own end.
var _act_left: float = INF
var _dance_left: float = INF
## Seconds until a body knocked down (play_action "knockdown") gets up; INF when it is not down.
var _down_left: float = INF
## Seconds until a roll (play_action "roll") gives way to locomotion; INF when not rolling.
var _roll_left: float = INF
## The climb state's clip (its timeline stretches to each climb's length).
var _climb: AnimationNodeAnimation
var _strike: Dictionary = {}


## Instantiates the body at path with the AnimationLibrary at lib_path; k is the body's speed
## factor (hip_m / speed_ref_hip_m * h_target / rest height). Null when a file is missing or the
## body has no %GeneralSkeleton.
static func build(path: String, lib_path: String, k: float, p_gender: String) -> RefCounted:
	if not ResourceLoader.exists(path) or not ResourceLoader.exists(lib_path):
		return null
	var ps := AP.load_scene(path)
	var lib := load(lib_path) as AnimationLibrary
	if ps == null or lib == null:
		return null
	for c: String in CLIPS:
		if not lib.has_animation(c):
			push_warning("hero_rig: %s lacks clip %s" % [lib_path, c])
			return null
	var b := ps.instantiate() as Node3D
	if b == null:
		return null
	var sk := b.get_node_or_null("%GeneralSkeleton") as Skeleton3D
	if sk == null:
		b.free()
		return null
	var r: RefCounted = (load("res://scripts/fp/player/hero_rig.gd") as GDScript).new()
	r.call("_setup", b, sk, lib, k, p_gender)
	return r


func _setup(b: Node3D, sk: Skeleton3D, lib: AnimationLibrary, k: float, p_gender: String) -> void:
	body = b
	skeleton = sk
	gender = p_gender
	for c: String in CLIPS:
		var a := lib.get_animation(c)
		lengths[c] = a.length
		speeds[c] = float(a.get_meta("speed_mps", 0.0)) * k
	for g: Node in body.find_children("*", "GeometryInstance3D", true, false):
		meshes.append(g as GeometryInstance3D)
	for n: String in ["LeftFoot", "RightFoot", "LeftToes", "RightToes"]:
		_feet.append(skeleton.find_bone(n))
	_lib = lib
	_fk = FK.new(skeleton)
	_analyse_feet()
	tree = AnimationTree.new()
	tree.name = "AnimationTree"
	tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	tree.deterministic = false
	tree.add_animation_library("", lib)
	tree.tree_root = _root_tree()
	body.add_child(tree)
	tree.root_node = NodePath("..")
	tree.root_motion_track = NodePath(AP.CHAR_ROOT_MOTION_TRACK)
	tree.active = true
	playback = tree.get(P_SM)
	look = LOOK.new(skeleton, body)
	limbs = LIMBS.new(skeleton, body)
	_reset_params()


## Per frame: v is the signed forward ground speed (m/s; negative walks backward), vy the vertical
## speed (m/s), crouched and talking the player's states. Advances the tree by dt and fills
## contacts with the heel strikes it crossed.
func update(dt: float, v: float, grounded: bool, vy: float, crouched: bool, talking: bool) -> void:
	contacts.clear()
	var a := absf(v)
	var st := state()
	if _sit and a > TALK_STILL:
		sit(false)
	if _down_left < INF:
		# Knocked down: the fall and the get-up run by themselves (a landing must not cut in).
		_air_t = 0.0 if grounded else _air_t + dt
	elif _roll_left < INF:
		_rolling(dt, a, grounded, crouched, talking)
	elif not grounded:
		_air_t += dt
		if st in ["loco", "crouch", "land", "talk"]:
			if vy > JUMP_VY * WS.JUMP_SPEED / WS.M:
				_go("jump")
			elif _air_t >= AIR_DELAY:
				_go("fall")
	else:
		_air_t = 0.0
		_on_ground(dt, st, a, crouched, talking)
	_last_vy = vy
	_set_locomotion(v, a)
	_update_actions(dt, a)
	tree.advance(dt)
	_update_ground(dt)
	_update_contacts()
	look.update(dt)
	limbs.update(dt)


## On the ground in state st: a jump or a fall lands (by the impact) and the landing gives way to
## the base state, as does anything but sitting and a knock-down.
func _on_ground(dt: float, st: String, a: float, crouched: bool, talking: bool) -> void:
	if (st == "jump" or st == "fall") and a > LAND_MOVING:
		_go(_base(a, crouched, talking))
	elif st == "jump" or st == "fall":
		var impact := maxf(0.0, -_last_vy)
		tree.set(P_LAND, clampf(LAND_MIN + (1.0 - LAND_MIN) * impact / LAND_FULL, LAND_MIN, 1.0))
		_land_t = 0.0
		_go("land")
	elif st == "land":
		_land_t += dt
		var len: float = lengths["land"]
		var t := _land_t
		if crouched or t >= len - XF_LAND_OUT or a > LAND_MOVING or (a > STILL and t >= LAND_INTERRUPT * len):
			_go(_base(a, crouched, talking))
	elif not _sit and st not in HELD:
		_go(_base(a, crouched, talking))


## Rolling: the roll runs by itself (a landing must not cut in), then gives way to the base state,
## or to the fall off a ledge.
func _rolling(dt: float, a: float, grounded: bool, crouched: bool, talking: bool) -> void:
	_air_t = 0.0
	_roll_left -= dt
	if _roll_left > 0.0:
		return
	_roll_left = INF
	_go(_base(a, crouched, talking) if grounded else "fall")


## The state machine's current state ("loco", "crouch", "jump", "fall", "land", "talk",
## "sit_down", "sit", "stand_up", "knockback", "get_up", "climb", "wall", "roll").
func state() -> String:
	return str(playback.get_current_node()) if playback != null else ""


## Sits down (on) or stands up; moving stands up by itself.
func sit(on: bool) -> void:
	if on == _sit:
		return
	_sit = on
	_go("sit_down" if on else "stand_up")


## Plays an upper-body gesture over the current state ("interact", "wave", "phone", "door_try").
func play_gesture(g: String) -> void:
	if g not in GESTURES:
		return
	tree.set(P_GESTURE, g)
	tree.set(P_SHOT, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


func gesture_active() -> bool:
	return bool(tree.get(P_SHOT_ACTIVE))


## Fades the playing gesture out before its end.
func stop_gesture() -> void:
	tree.set(P_SHOT, AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)


## Plays a body action: one of ACTIONS on the upper body over whatever the legs do, "kick" on
## the whole body (on foot and upright only; it plays to its end), "dance" on the whole body
## (standing only; moving ends it), "knockdown" (the body falls onto its back,
## lies there secs and gets up), "climb" (the body pulls itself up over secs, then walks on) or
## "roll" (from a landing the body rolls over a shoulder and comes up, on into locomotion after
## secs).
## secs > 0 fades an action out that long after the start; otherwise a clip plays to its end, a
## loop for one cycle and the dance until stopped.
func play_action(a: String, secs: float = 0.0) -> bool:
	var left := secs if secs > 0.0 else INF
	if a in ["knockdown", "climb", "roll"]:
		stop_gesture()
		stop_action()
		_whole_body(a, secs)
		return true
	if a == "kick":
		return _kick()
	if a == "dance":
		if state() != "loco" or move * float(speeds["walk"]) > TALK_STILL:
			return false
		tree.set(P_DANCE, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
		_dance_left = left
		return true
	if a not in ACTIONS:
		return false
	tree.set(P_ACTION, a)
	tree.set(P_ACT, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	_act_left = left
	return true


func _kick() -> bool:
	if state() not in ["loco", "talk"]:
		return false
	stop_action()
	tree.set(P_KICK, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	return true


func _whole_body(a: String, secs: float) -> void:
	_roll_left = INF
	if a == "knockdown":
		_down_left = float(lengths["knockback"]) + maxf(secs, 0.0)
		_go("knockback")
		return
	if a == "roll":
		_roll_left = secs if secs > 0.0 else float(lengths["roll"]) - ROLL_SKIP
		_restart("roll")
		return
	_climb.timeline_length = secs if secs > 0.0 else float(lengths["climb_1m"])
	_restart("climb")


## Into state s, from its start again when the body is in it already.
func _restart(s: String) -> void:
	if state() == s:
		playback.start(s, true)
	else:
		_go(s)


## Takes hold of a wall (on: the wall pose, the limbs put on holds by reach) or lets go of it: the
## limbs back to the clips and the body into the fall, or standing when grounded, unless another
## state takes over (play_action "climb" right after, over the top).
func hold_wall(on: bool, grounded: bool = false) -> void:
	if on:
		stop_gesture()
		stop_action()
		_go("wall")
		return
	limbs.release()
	if state() == "wall":
		_go("loco" if grounded else "fall")


## Puts limb i (0 left hand, 1 right hand, 2 left foot, 3 right foot) on target (world) with its
## elbow or knee bent toward pole, weight (0..1) of the way.
func reach(i: int, target: Vector3, pole: Vector3, weight: float) -> void:
	limbs.set_goal(i, target, pole, weight)


## True while an action or the dance plays (fading out included).
func action_active() -> bool:
	var on := bool(tree.get(P_ACT_ACTIVE)) or bool(tree.get(P_DANCE_ACTIVE))
	return on or bool(tree.get(P_KICK_ACTIVE))


## Fades the playing action and the dance out.
func stop_action() -> void:
	tree.set(P_ACT, AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
	tree.set(P_DANCE, AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
	tree.set(P_KICK, AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
	_act_left = INF
	_dance_left = INF


## Raises (on) or drops the guard: fists up on the upper body, eased over HL_GUARD.
func set_guard(on: bool) -> void:
	_guard_goal = 1.0 if on else 0.0


## When clip's fists (or palms) are furthest out in front within its first within seconds: where
## a punch or the shove lands (s). Measured once per clip on this body's keys and cached.
func strike_time(clip: String, within: float = STRIKE_WITHIN) -> float:
	var key := "%s|%.3f" % [clip, within]
	if _strike.has(key):
		return _strike[key]
	var a := _clip(clip)
	if a == null:
		return 0.0
	var fwd := _fk.forward_of(body)
	var hands := []
	for h: String in ["LeftHand", "RightHand"]:
		hands.append(_fk.chain_to(skeleton.find_bone(h)))
	var span := minf(a.length, within)
	var best := -INF
	var at := 0.0
	for k in range(STRIKE_SAMPLES + 1):
		var t := span * float(k) / float(STRIKE_SAMPLES)
		for c: Array in hands:
			var reach := _fk.end_pos(a, a, 0.0, c, t / a.length).dot(fwd)
			if reach > best + 1e-5:
				best = reach
				at = t
	_strike[key] = at
	return at


## Times the playing action and the dance out, ends the dance once the body moves or leaves its
## standing locomotion, and eases the guard.
func _update_actions(dt: float, a: float) -> void:
	_act_left -= dt
	if _act_left <= 0.0:
		_act_left = INF
		tree.set(P_ACT, AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
	_down_left -= dt
	if _down_left <= 0.0:
		_down_left = INF
		if state() == "knockback":
			_go("get_up")
	_dance_left -= dt
	var ending := a > TALK_STILL or state() != "loco" or _dance_left <= 0.0
	if ending and bool(tree.get(P_DANCE_ACTIVE)):
		_dance_left = INF
		tree.set(P_DANCE, AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
	guard = _guard_goal if dt <= 0.0 else SM.damp(guard, _guard_goal, HL_GUARD, dt)
	tree.set(P_GUARD, guard)


## How far clip has carried its root t seconds after its state began (0..1 of the whole clip's
## horizontal root travel; sit_down and stand_up play at SIT_SPEED). The tree drops root motion,
## so whoever moves the body through a clip (into a car seat) follows this curve; a clip without
## travel runs linearly.
func travel(clip: String, t: float) -> float:
	var a := _clip(clip)
	var ti := _root_track(a)
	var length := a.length if a != null else 1.0
	var tc := t * (SIT_SPEED if clip in SIT_CLIPS else 1.0)
	if ti < 0:
		return clampf(tc / length, 0.0, 1.0)
	var p0 := a.position_track_interpolate(ti, 0.0)
	var d := a.position_track_interpolate(ti, length) - p0
	d.y = 0.0
	if d.length_squared() < 1e-8:
		return clampf(tc / length, 0.0, 1.0)
	var p := a.position_track_interpolate(ti, clampf(tc, 0.0, length)) - p0
	return clampf(Vector3(p.x, 0.0, p.z).dot(d) / d.length_squared(), 0.0, 1.0)


## How far clip carries the body along the ground over its whole length (world units).
func root_travel(clip: String) -> float:
	var a := _clip(clip)
	var ti := _root_track(a)
	if ti < 0:
		return 0.0
	var d := a.position_track_interpolate(ti, a.length) - a.position_track_interpolate(ti, 0.0)
	var sc := skeleton.global_transform.basis.get_scale().x if skeleton.is_inside_tree() else 1.0
	return Vector2(d.x, d.z).length() * skeleton.motion_scale * sc


func _clip(clip: String) -> Animation:
	return _lib.get_animation(clip) if _lib != null and _lib.has_animation(clip) else null


static func _root_track(a: Animation) -> int:
	if a == null:
		return -1
	return a.find_track(NodePath(AP.CHAR_ROOT_MOTION_TRACK), Animation.TYPE_POSITION_3D)


## The world point the head turns toward; NAN components let the head return to the clip.
func set_look_target(p: Vector3) -> void:
	look.set_target(p)


## Back to standing (or crouched) locomotion at once: no cross-fade, no landing, no gesture.
func snap(crouched: bool) -> void:
	_sit = false
	_air_t = 0.0
	_last_vy = 0.0
	look.reset()
	limbs.release(true)
	_reset_params()
	ground_fix = 0.0
	body.position.y = 0.0
	tree.set("parameters/shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)
	tree.set(P_ACT, AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)
	tree.set(P_DANCE, AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)
	_guard_goal = 0.0
	guard = 0.0
	_act_left = INF
	_dance_left = INF
	_down_left = INF
	_roll_left = INF
	playback.start("crouch" if crouched else "loco", true)
	tree.advance(0.0)
	_prev_state = state()
	_prev_phase = -1.0
	phase = -1.0


## A bone's world position (the animated pose, before the look-at modifiers).
func bone_world(bone: String) -> Vector3:
	var i := skeleton.find_bone(bone)
	if i < 0:
		return Vector3(NAN, NAN, NAN)
	return skeleton.global_transform * skeleton.get_bone_global_pose(i).origin


## How far the lowest part of either sole is above the given world height (world units): per
## foot the lower of the heel (the ankle bone above its standing height) and the toe (the toe
## bone above its standing height), for tests.
func feet_low(ground_y: float) -> float:
	var low := INF
	var sc := skeleton.global_transform.basis.y.length() if skeleton.is_inside_tree() else 1.0
	for k in range(_feet.size()):
		var i: int = _feet[k]
		var y := (skeleton.global_transform * skeleton.get_bone_global_pose(i).origin).y
		low = minf(low, y - ground_y - (float(_feet_rest[k]) if k < _feet_rest.size() else 0.0) * sc)
	return low


## Lowers the body in GROUND_STATES so the lowest sole rests on the ground (skeleton metres).
func _update_ground(dt: float) -> void:
	var goal := 0.0
	var st := state()
	if st in GROUND_STATES and (st != "land" or _land_t > XF_LAND):
		# Per foot (ankle k, toe k + 2) the lower of heel and toe above standing.
		var foot := [INF, INF]
		for k in range(_feet.size()):
			foot[k % 2] = minf(foot[k % 2], skeleton.get_bone_global_pose(_feet[k]).origin.y - float(_feet_rest[k]))
		var lo := minf(foot[0], foot[1])
		goal = clampf(minf(maxf(foot[0], foot[1]), lo + GROUND_SINK), -GROUND_UP, GROUND_DOWN)
	ground_fix = goal if dt <= 0.0 else SM.damp(ground_fix, goal, HL_GROUND, dt)
	body.position.y = -ground_fix


# --- Tree

## sm -> shot (gestures, upper body) -> dance (whole body) -> guard (GUARD_CLIP held, upper
## body) -> act (ACTIONS, upper body) -> output.
func _root_tree() -> AnimationNodeBlendTree:
	var bt := AnimationNodeBlendTree.new()
	bt.add_node("sm", _state_machine())
	_switch(bt, "gesture", GESTURES, "g_")
	bt.add_node("shot", _one_shot(SHOT_IN, SHOT_OUT, true))
	bt.connect_node("shot", 0, "sm")
	bt.connect_node("shot", 1, "gesture")
	bt.add_node("dance", _one_shot(DANCE_IN, DANCE_OUT, false))
	bt.add_node("a_dance", _anim("dance"))
	bt.connect_node("dance", 0, "shot")
	bt.connect_node("dance", 1, "a_dance")
	# The guard pose: GUARD_CLIP sought to GUARD_AT and held there (time scale 0).
	bt.add_node("guard_pose", _anim(GUARD_CLIP))
	bt.add_node("guard_at", AnimationNodeTimeSeek.new())
	bt.add_node("guard_hold", AnimationNodeTimeScale.new())
	bt.connect_node("guard_at", 0, "guard_pose")
	bt.connect_node("guard_hold", 0, "guard_at")
	var guard_mix := AnimationNodeBlend2.new()
	_filter_upper(guard_mix)
	bt.add_node("guard", guard_mix)
	bt.connect_node("guard", 0, "dance")
	bt.connect_node("guard", 1, "guard_hold")
	_switch(bt, "action", ACTIONS, "a_")
	bt.add_node("act", _one_shot(ACT_IN, ACT_OUT, true))
	bt.connect_node("act", 0, "guard")
	bt.connect_node("act", 1, "action")
	# The kick moves the legs too: a whole-body one-shot over everything else.
	bt.add_node("kick", _one_shot(ACT_IN, ACT_OUT, false))
	bt.add_node("a_kick", _anim("kick"))
	bt.connect_node("kick", 0, "act")
	bt.connect_node("kick", 1, "a_kick")
	bt.connect_node("output", 0, "kick")
	return bt


## A Transition n in bt over clips (no cross-fade; each input restarts its clip), the clips as
## Animation nodes named prefix + clip.
static func _switch(bt: AnimationNodeBlendTree, n: String, clips: Array, prefix: String) -> void:
	var tr := AnimationNodeTransition.new()
	tr.input_count = clips.size()
	for i in clips.size():
		tr.set_input_name(i, clips[i])
	tr.xfade_time = 0.0
	tr.allow_transition_to_self = true
	bt.add_node(n, tr)
	for i in clips.size():
		var c := prefix + str(clips[i])
		bt.add_node(c, _anim(clips[i]))
		bt.connect_node(n, i, c)


## A one-shot with these fades; upper filters it to the upper body. A looping clip in it plays one
## cycle, except on the whole body (the dance), which loops until faded out.
func _one_shot(fade_in: float, fade_out: float, upper: bool) -> AnimationNodeOneShot:
	var s := AnimationNodeOneShot.new()
	s.fadein_time = fade_in
	s.fadeout_time = fade_out
	s.break_loop_at_end = upper
	if upper:
		_filter_upper(s)
	return s


func _filter_upper(n: AnimationNode) -> void:
	n.filter_enabled = true
	for b in _upper_bones():
		n.set_filter_path(NodePath("%GeneralSkeleton:" + b), true)


func _state_machine() -> AnimationNodeStateMachine:
	var sm := AnimationNodeStateMachine.new()
	sm.add_node("loco", _locomotion())
	sm.add_node("crouch", _crouch())
	sm.add_node("jump", _skipped("jump_start", JUMP_SKIP))
	sm.add_node("fall", _anim("fall"))
	var land := AnimationNodeBlendTree.new()
	land.add_node("idle", _anim("idle"))
	land.add_node("land", _anim("land"))
	land.add_node("mix", AnimationNodeBlend2.new())
	land.connect_node("mix", 0, "idle")
	land.connect_node("mix", 1, "land")
	land.connect_node("output", 0, "mix")
	sm.add_node("land", land)
	sm.add_node("talk", _anim("talk"))
	sm.add_node("sit", _anim("sit"))
	for s: String in SIT_CLIPS + ["knockback", "get_up"]:
		sm.add_node(s, _once(s, SIT_SPEED if s in SIT_CLIPS else 1.0))
	_climb = _once("climb_1m", 1.0)
	sm.add_node("climb", _climb)
	sm.add_node("wall", _anim(WALL_CLIP))
	sm.add_node("roll", _skipped("roll", ROLL_SKIP))
	_tr(sm, "Start", "loco", 0.0, true)
	for pair: Array in [["loco", "crouch"], ["crouch", "loco"], ["land", "crouch"]]:
		_tr(sm, pair[0], pair[1], XF_CROUCH)
	for from: String in ["loco", "crouch", "land", "talk"]:
		_tr(sm, from, "jump", XF_JUMP)
		_tr(sm, from, "fall", XF_LEDGE)
		_tr(sm, from, "climb", XF_JUMP)
	_tr(sm, "jump", "fall", XF_FALL, true)
	_tr(sm, "jump", "land", XF_LAND)
	_tr(sm, "fall", "land", XF_LAND)
	for from: String in ["jump", "fall"]:
		_tr(sm, from, "loco", XF_LAND_OUT)
		_tr(sm, from, "crouch", XF_LAND_OUT)
		_tr(sm, from, "climb", XF_JUMP)
	_tr(sm, "climb", "loco", XF_LAND_OUT, true)
	for from: String in ["loco", "crouch", "land", "talk", "jump", "fall"]:
		_tr(sm, from, "wall", XF_WALL)
		_tr(sm, from, "roll", XF_ROLL)
	for to: String in ["climb", "fall", "loco"]:
		_tr(sm, "wall", to, XF_WALL)
	for to: String in ["loco", "crouch", "talk", "fall"]:
		_tr(sm, "roll", to, XF_LAND_OUT)
	_tr(sm, "land", "loco", XF_LAND_OUT)
	_tr(sm, "land", "talk", XF_TALK)
	for pair: Array in [["loco", "talk"], ["talk", "loco"], ["crouch", "talk"], ["talk", "crouch"]]:
		_tr(sm, pair[0], pair[1], XF_TALK)
	for from: String in ["loco", "crouch", "talk"]:
		_tr(sm, from, "sit_down", XF_SIT)
	_tr(sm, "sit_down", "sit", XF_SIT, true)
	_tr(sm, "sit_down", "stand_up", XF_SIT)
	_tr(sm, "sit", "stand_up", XF_SIT)
	_tr(sm, "stand_up", "loco", XF_SIT, true)
	_tr(sm, "stand_up", "sit_down", XF_SIT)
	var into_knockback := [
		"loco", "crouch", "land", "talk", "jump", "fall", "get_up", "climb", "wall", "roll"
	]
	for from: String in into_knockback:
		_tr(sm, from, "knockback", XF_FALL)
	_tr(sm, "knockback", "get_up", XF_FALL)
	_tr(sm, "get_up", "loco", XF_LAND_OUT, true)
	return sm


## Idle blended (move) with the cyclic walk-to-run BlendSpace1D behind its TimeScale.
func _locomotion() -> AnimationNodeBlendTree:
	var bs := AnimationNodeBlendSpace1D.new()
	bs.min_space = 0.0
	bs.max_space = ceilf(float(speeds["run_fast"]) + 1.0)
	bs.snap = 0.001
	bs.sync_mode = AnimationNodeBlendSpace1D.SYNC_MODE_CYCLIC_MUTABLE
	for c: String in LOCO:
		bs.add_blend_point(_anim(c), float(speeds[c]), -1, c)
	var bt := AnimationNodeBlendTree.new()
	bt.add_node("idle", _anim("idle"))
	bt.add_node("bs", bs)
	bt.add_node("ts", AnimationNodeTimeScale.new())
	bt.connect_node("ts", 0, "bs")
	bt.add_node("move", AnimationNodeBlend2.new())
	bt.connect_node("move", 0, "idle")
	bt.connect_node("move", 1, "ts")
	bt.connect_node("output", 0, "move")
	return bt


## crouch_idle at 0 and crouch_walk at its measured speed, behind a TimeScale.
func _crouch() -> AnimationNodeBlendTree:
	var bs := AnimationNodeBlendSpace1D.new()
	bs.min_space = 0.0
	bs.max_space = ceilf(float(speeds["crouch_walk"]) + 1.0)
	bs.snap = 0.001
	bs.add_blend_point(_anim("crouch_idle"), 0.0, -1, "idle")
	bs.add_blend_point(_anim("crouch_walk"), float(speeds["crouch_walk"]), -1, "walk")
	var bt := AnimationNodeBlendTree.new()
	bt.add_node("bs", bs)
	bt.add_node("ts", AnimationNodeTimeScale.new())
	bt.connect_node("ts", 0, "bs")
	bt.connect_node("output", 0, "ts")
	return bt


static func _anim(clip: String) -> AnimationNodeAnimation:
	var a := AnimationNodeAnimation.new()
	a.animation = clip
	return a


## clip played once from skip seconds in at its own pace, holding its last frame.
func _skipped(clip: String, skip: float) -> AnimationNodeAnimation:
	var a := _anim(clip)
	a.use_custom_timeline = true
	a.timeline_length = maxf(float(lengths[clip]) - skip, 0.1)
	a.start_offset = skip
	a.stretch_time_scale = false
	a.loop_mode = Animation.LOOP_NONE
	return a


## clip played once at speed times its own pace, holding its last frame.
func _once(clip: String, speed: float) -> AnimationNodeAnimation:
	var a := _anim(clip)
	a.use_custom_timeline = true
	a.timeline_length = float(lengths[clip]) / speed
	a.stretch_time_scale = true
	a.loop_mode = Animation.LOOP_NONE
	return a


static func _tr(sm: AnimationNodeStateMachine, from: String, to: String, xfade: float, at_end: bool = false) -> void:
	var t := AnimationNodeStateMachineTransition.new()
	t.xfade_time = xfade
	if at_end:
		t.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
	t.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO if (at_end or from == "Start") else AnimationNodeStateMachineTransition.ADVANCE_MODE_ENABLED
	sm.add_transition(from, to, t)


## Spine and every bone under it (the arms, the neck, the head and the face).
func _upper_bones() -> Array[String]:
	var out: Array[String] = []
	var root := skeleton.find_bone(UPPER_ROOT)
	if root < 0:
		return out
	var stack: Array[int] = [root]
	while not stack.is_empty():
		var b: int = stack.pop_back()
		out.append(skeleton.get_bone_name(b))
		for c in skeleton.get_bone_children(b):
			stack.append(c)
	return out


func _go(s: String) -> void:
	if state() != s:
		playback.travel(s)


func _base(a: float, crouched: bool, talking: bool) -> String:
	if talking and a < TALK_STILL:
		return "talk"
	return "crouch" if crouched else "loco"


func _reset_params() -> void:
	var walk: float = speeds["walk"]
	tree.set(P_MOVE, 0.0)
	tree.set(P_BS, walk)
	tree.set(P_TS, 1.0)
	tree.set(P_CBS, 0.0)
	tree.set(P_CTS, 1.0)
	tree.set(P_LAND, LAND_MIN)
	tree.set(P_GUARD, guard)
	tree.set(P_GUARD_SEEK, GUARD_AT)
	tree.set(P_GUARD_HOLD, 0.0)
	time_scale = 1.0
	move = 0.0


## Blend positions and the foot-slide TimeScale for ground speed v (signed, m/s).
func _set_locomotion(v: float, a: float) -> void:
	var walk: float = speeds["walk"]
	var fast: float = speeds["run_fast"]
	move = clampf(a / walk, 0.0, 1.0)
	tree.set(P_MOVE, move)
	tree.set(P_BS, clampf(a, walk, fast))
	time_scale = clampf(a / _anim_speed(a), TS_MIN, TS_MAX) if a > STILL else 1.0
	tree.set(P_TS, -time_scale if v < 0.0 else time_scale)
	var cw: float = speeds["crouch_walk"]
	tree.set(P_CBS, minf(a, cw))
	var cts := clampf(a / cw, 1.0, TS_MAX) if a > STILL else 1.0
	tree.set(P_CTS, -cts if v < 0.0 else cts)


## v_anim = sum(w S) / sum(w T) over the two blend points around a (S = speed * T, the stride of
## one cycle); idle counts as a point with no stride on the walk's cycle, so a slow walk keeps
## the walk's cadence with a shorter step.
func _anim_speed(a: float) -> float:
	var g := _gait_at(a)
	return g.x


## The ground one gait cycle (two steps) covers at speed a (m/s), in metres.
func stride(a: float) -> float:
	var g := _gait_at(a)
	return g.x * g.y


## (v_anim, the blended cycle length sum(w T)) at speed a.
func _gait_at(a: float) -> Vector2:
	var walk: float = speeds["walk"]
	if a <= walk:
		return Vector2(maxf(a, 1e-3), float(lengths["walk"]))
	for i in range(LOCO.size() - 1):
		var c0: String = LOCO[i]
		var c1: String = LOCO[i + 1]
		var s0: float = speeds[c0]
		var s1: float = speeds[c1]
		if a <= s1 or i == LOCO.size() - 2:
			var w1 := clampf((a - s0) / maxf(s1 - s0, 1e-4), 0.0, 1.0)
			var t0: float = lengths[c0]
			var t1: float = lengths[c1]
			var t := (1.0 - w1) * t0 + w1 * t1
			return Vector2(((1.0 - w1) * s0 * t0 + w1 * s1 * t1) / t, t)
	return Vector2(walk, float(lengths["walk"]))


## Heel strikes: the locomotion (or crouch-walk) phase crossing each heel's contact phase (HC
## puts them near 0 for the left heel and 0.5 for the right; _contacts_of measures them on the
## blended pose) while the walk blend is on; each contact's pos is that foot's ground point.
func _update_contacts() -> void:
	var st := state()
	var base := P_PHASE if st == "loco" else (P_CPHASE if st == "crouch" else "")
	var ph := -1.0
	if not base.is_empty():
		var len := float(tree.get(base + "current_length"))
		if len > 1e-4:
			ph = fposmod(float(tree.get(base + "current_position")) / len, 1.0)
	var walking := move >= STEP_MIN_MOVE if st == "loco" else float(tree.get(P_CBS)) >= STEP_MIN_MOVE * float(speeds["crouch_walk"])
	if ph >= 0.0 and _prev_phase >= 0.0 and st == _prev_state and walking:
		var d := wrapf(ph - _prev_phase, -0.5, 0.5)
		var cp := _contact_phases(st)
		for f in range(2):
			var c := cp.x if f == 0 else cp.y
			var ahead := fposmod(c - _prev_phase, 1.0) if d > 0.0 else fposmod(_prev_phase - c, 1.0)
			if d != 0.0 and ahead > 0.0 and ahead <= absf(d):
				var foot := bone_world("LeftFoot" if f == 0 else "RightFoot")
				var ground := body.global_position.y if body.is_inside_tree() else 0.0
				contacts.append({"left": f == 0, "pos": Vector3(foot.x, ground, foot.z)})
	phase = ph
	_prev_phase = ph
	_prev_state = st


## The (left, right) heel contact phases of the current blend: "loco" those of the blended pose
## between the two clips around the blend position, "crouch" crouch_walk's.
func _contact_phases(st: String = "loco") -> Vector2:
	if st == "crouch":
		return _contacts_of("crouch_walk", "crouch_walk", 0.0)
	var a := float(tree.get(P_BS))
	for i in range(LOCO.size() - 1):
		var s0: float = speeds[LOCO[i]]
		var s1: float = speeds[LOCO[i + 1]]
		if a <= s1 or i == LOCO.size() - 2:
			return _contacts_of(LOCO[i], LOCO[i + 1], clampf((a - s0) / maxf(s1 - s0, 1e-4), 0.0, 1.0))
	return Vector2(0.0, 0.5)


# --- Feet analysis (forward kinematics over the clips' own keys, once per body and blend)

## The heel contact phases (left, right) of clip c0 blended toward c1 by w (quantised to
## 1 / BLEND_STEPS; both clips on one shared cycle, as the cyclic blend space plays them). Each is
## where that ankle comes down to within HEEL.EPS of its lowest height near HC's nominal phase
## (0 for the left heel, 0.5 for the right). Computed on first use and cached.
func _contacts_of(c0: String, c1: String, w: float) -> Vector2:
	var q := roundi(w * BLEND_STEPS) if c0 != c1 else 0
	var key := "%s|%s|%d" % [c0, c1, q]
	if _contact.has(key):
		return _contact[key]
	var a0 := _lib.get_animation(c0)
	var a1 := _lib.get_animation(c1)
	var wq := float(q) / float(BLEND_STEPS)
	var out := Vector2.ZERO
	for f in range(2):
		var h := PackedFloat32Array()
		for k in range(CONTACT_SAMPLES):
			var ph := float(k) / float(CONTACT_SAMPLES)
			h.append(_fk.end_pos(a0, a1, wq, _chains[f], ph).y)
		out[f] = HEEL.down_phase(h, 0.5 * float(f))
	_contact[key] = out
	return out


## The bone chains from the root to each foot bone, and the standing heights of the ankles and
## toes: their lowest over idle (skeleton metres).
func _analyse_feet() -> void:
	_chains.clear()
	for b: int in _feet:
		_chains.append(_fk.chain_to(b))
	var idle := _lib.get_animation("idle")
	var stand := [INF, INF]
	for k in range(IDLE_SAMPLES):
		var ph := float(k) / float(IDLE_SAMPLES)
		for f in range(4):
			stand[f / 2] = minf(stand[f / 2], _fk.end_pos(idle, idle, 0.0, _chains[f], ph).y)
	_feet_rest.clear()
	for f in range(4):
		_feet_rest.append(stand[f / 2])
