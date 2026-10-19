extends RefCounted
## HC's animated hero for the player (slice A stage A2; A-player.md 6.9, TPS_PLAN 2.9). A roster
## body (AP.HERO_M / AP.HERO_F) with the gender's shared library as the default library "" and an
## AnimationTree driven from code: MANUAL process, advanced by player_avatar.update_motion with the
## player's own dt, so tests and the game step it the same way. The tree is a StateMachine
## (locomotion, crouch, jump / fall / land, talk, sit) under a OneShot for upper-body gestures.
## Locomotion blends idle with a cyclic BlendSpace1D of walk, walk_fast, run and run_fast at their
## measured speeds (SYNC_MODE_CYCLIC_MUTABLE gives the blended loops one shared cycle, so their
## left-heel phases stay locked), then a TimeScale that matches the stride to the ground speed.
## Foot contacts are the locomotion phase crossing 0 (left heel) and one half (right heel).
## LookAtModifier3Ds on Neck and Head turn the head toward a look target.

const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const SM := preload("res://scripts/fp/player/spring_math.gd")

## Locomotion loops in blend order; HC starts each on the left-heel strike.
const LOCO := ["walk", "walk_fast", "run", "run_fast"]
## Upper-body one-shots (6.9 OneShot).
const GESTURES := ["interact", "wave", "phone", "door_try"]
## Every clip the tree plays.
const CLIPS := ["idle", "walk", "walk_fast", "run", "run_fast", "crouch_idle", "crouch_walk", "jump_start", "fall", "land", "talk", "sit_down", "sit", "stand_up", "interact", "wave", "phone", "door_try"]
## Foot-slide correction: TimeScale = clamp(v / v_anim, TS_MIN, TS_MAX).
const TS_MIN := 0.5
const TS_MAX := 1.5
## Cross-fades (s): into the jump, jump to fall, into the landing, landing out, crouch, talk, sit,
## and walking off a ledge into the fall.
const XF_JUMP := 0.08
const XF_FALL := 0.1
const XF_LAND := 0.06
const XF_LAND_OUT := 0.15
const XF_CROUCH := 0.2
const XF_TALK := 0.3
const XF_SIT := 0.3
const XF_LEDGE := 0.2
## jump_start opens on a crouch before take-off, but FpPlayer leaves the ground on the press: the
## clip starts at take-off.
const JUMP_SKIP := 0.05
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
## Feet analysis: samples per locomotion cycle and over idle, and how close (m) to its lowest
## point near the nominal strike a heel counts as down.
const CONTACT_SAMPLES := 64
const IDLE_SAMPLES := 24
const CONTACT_EPS := 0.005
## The window, in cycles around the nominal heel strike, that the contact search covers; blends
## are measured at 1 / BLEND_STEPS steps of weight.
const CONTACT_BEFORE := 0.2
const CONTACT_AFTER := 0.15
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
## Head look (6.9): Head limits (yaw, pitch), the Neck's share and limit, the modifier's own
## interpolation, the influence fade when the target leaves the limits, and the halflife that
## smooths a jumping target.
const LOOK_YAW := deg_to_rad(70.0)
const LOOK_PITCH := deg_to_rad(35.0)
const NECK_INFLUENCE := 0.35
const NECK_LIMIT := deg_to_rad(45.0)
const LOOK_DURATION := 0.35
const LOOK_FADE := 0.3
const HL_LOOK := 0.12
## A faded-out look comes back once the target is this far inside the limits (no flicker at the edge).
const LOOK_REARM := deg_to_rad(8.0)
## Skeleton-local (metres): closer targets interpolate (LookAtModifier3D.origin_safe_margin).
const LOOK_SAFE_MARGIN := 0.5
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

## The body's scene root (faces +Z, feet at y = 0, metric) and its parts.
var body: Node3D
var skeleton: Skeleton3D
var tree: AnimationTree
var playback: AnimationNodeStateMachinePlayback
var head_look: LookAtModifier3D
var neck_look: LookAtModifier3D
var look_marker: Marker3D
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
## Head-look influence (0..1) and whether the modifier last found its target within its limits.
var look_weight: float = 0.0
var look_within: bool = false
## The head's forward (world) as the look-at modifiers left it, from the last frame they ran.
var head_forward: Vector3 = Vector3.ZERO
var _head_bone: int = -1
var _feet: Array[int] = []
var _feet_rest: Array[float] = []
var _contact: Dictionary = {}
var _tracks: Dictionary = {}
var _chains: Array = []
var _lib: AnimationLibrary
var _look_goal: Vector3 = Vector3(NAN, NAN, NAN)
var _look_dir: Vector3 = Vector3.ZERO
var _look_dist: float = 0.0
var _air_t: float = 0.0
var _land_t: float = 0.0
var _sit: bool = false
var _prev_state: String = ""
var _prev_phase: float = -1.0
var _last_vy: float = 0.0


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
	_head_bone = skeleton.find_bone("Head")
	for n: String in ["LeftFoot", "RightFoot", "LeftToes", "RightToes"]:
		_feet.append(skeleton.find_bone(n))
	_lib = lib
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
	# Look-at modifiers run in the skeleton's own update, after the tree has posed it; the Neck
	# goes first so the Head resolves what remains.
	neck_look = _look_modifier("NeckLook", "Neck", NECK_LIMIT, NECK_LIMIT)
	head_look = _look_modifier("HeadLook", "Head", LOOK_YAW, LOOK_PITCH)
	look_marker = Marker3D.new()
	look_marker.name = "LookTarget"
	look_marker.top_level = true
	body.add_child(look_marker)
	neck_look.target_node = neck_look.get_path_to(look_marker)
	head_look.target_node = head_look.get_path_to(look_marker)
	head_look.modification_processed.connect(_on_look_processed)
	_set_look_weight(0.0)
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
	if not grounded:
		_air_t += dt
		if st in ["loco", "crouch", "land", "talk"]:
			if vy > JUMP_VY * WS.JUMP_SPEED / WS.M:
				_go("jump")
			elif _air_t >= AIR_DELAY:
				_go("fall")
	else:
		_air_t = 0.0
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
		elif not _sit and st not in ["sit_down", "sit", "stand_up"]:
			_go(_base(a, crouched, talking))
	_last_vy = vy
	_set_locomotion(v, a)
	tree.advance(dt)
	_update_ground(dt)
	_update_contacts()
	_update_look(dt)


## The state machine's current state ("loco", "crouch", "jump", "fall", "land", "talk",
## "sit_down", "sit", "stand_up").
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


## The world point the head turns toward; NAN components let the head return to the clip.
func set_look_target(p: Vector3) -> void:
	_look_goal = p


## Back to standing (or crouched) locomotion at once: no cross-fade, no landing, no gesture.
func snap(crouched: bool) -> void:
	_sit = false
	_air_t = 0.0
	_last_vy = 0.0
	_look_dir = Vector3.ZERO
	_reset_params()
	ground_fix = 0.0
	body.position.y = 0.0
	tree.set("parameters/shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)
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

func _root_tree() -> AnimationNodeBlendTree:
	var bt := AnimationNodeBlendTree.new()
	bt.add_node("sm", _state_machine())
	var tr := AnimationNodeTransition.new()
	tr.input_count = GESTURES.size()
	for i in GESTURES.size():
		tr.set_input_name(i, GESTURES[i])
	tr.xfade_time = 0.0
	bt.add_node("gesture", tr)
	for i in GESTURES.size():
		var n := "g_" + str(GESTURES[i])
		bt.add_node(n, _anim(GESTURES[i]))
		bt.connect_node("gesture", i, n)
	var shot := AnimationNodeOneShot.new()
	shot.fadein_time = SHOT_IN
	shot.fadeout_time = SHOT_OUT
	shot.break_loop_at_end = true
	shot.filter_enabled = true
	for b in _upper_bones():
		shot.set_filter_path(NodePath("%GeneralSkeleton:" + b), true)
	bt.add_node("shot", shot)
	bt.connect_node("shot", 0, "sm")
	bt.connect_node("shot", 1, "gesture")
	bt.connect_node("output", 0, "shot")
	return bt


func _state_machine() -> AnimationNodeStateMachine:
	var sm := AnimationNodeStateMachine.new()
	sm.add_node("loco", _locomotion())
	sm.add_node("crouch", _crouch())
	var jump := _anim("jump_start")
	jump.use_custom_timeline = true
	jump.timeline_length = maxf(float(lengths["jump_start"]) - JUMP_SKIP, 0.1)
	jump.start_offset = JUMP_SKIP
	jump.stretch_time_scale = false
	jump.loop_mode = Animation.LOOP_NONE
	sm.add_node("jump", jump)
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
	for s: String in ["sit_down", "sit", "stand_up"]:
		sm.add_node(s, _anim(s))
	_tr(sm, "Start", "loco", 0.0, true)
	for pair: Array in [["loco", "crouch"], ["crouch", "loco"], ["land", "crouch"]]:
		_tr(sm, pair[0], pair[1], XF_CROUCH)
	for from: String in ["loco", "crouch", "land", "talk"]:
		_tr(sm, from, "jump", XF_JUMP)
		_tr(sm, from, "fall", XF_LEDGE)
	_tr(sm, "jump", "fall", XF_FALL, true)
	_tr(sm, "jump", "land", XF_LAND)
	_tr(sm, "fall", "land", XF_LAND)
	for from: String in ["jump", "fall"]:
		_tr(sm, from, "loco", XF_LAND_OUT)
		_tr(sm, from, "crouch", XF_LAND_OUT)
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
		var cp := contact_phases(st)
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
func contact_phases(st: String = "loco") -> Vector2:
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
## where that ankle comes down to within CONTACT_EPS of its lowest height near HC's nominal phase
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
			h.append(_fk_y(a0, a1, wq, _chains[f], ph))
		out[f] = _down_phase(h, 0.5 * float(f))
	_contact[key] = out
	return out


## The bone chains from the root to each foot bone, and the standing heights of the ankles and
## toes: their lowest over idle (skeleton metres).
func _analyse_feet() -> void:
	_chains.clear()
	for b: int in _feet:
		var chain: Array[int] = []
		var i := b
		while i >= 0:
			chain.push_front(i)
			i = skeleton.get_bone_parent(i)
		_chains.append(chain)
	var idle := _lib.get_animation("idle")
	var stand := [INF, INF]
	for k in range(IDLE_SAMPLES):
		var ph := float(k) / float(IDLE_SAMPLES)
		for f in range(4):
			stand[f / 2] = minf(stand[f / 2], _fk_y(idle, idle, 0.0, _chains[f], ph))
	_feet_rest.clear()
	for f in range(4):
		_feet_rest.append(stand[f / 2])


## The y (skeleton metres) of the chain's last bone at phase ph of clip a0 blended toward a1 by w
## (rotations slerped, positions lerped). Root stays at rest (its motion is extracted); position
## keys scale by the skeleton's motion_scale, as the mixer applies them.
func _fk_y(a0: Animation, a1: Animation, w: float, chain: Array, ph: float) -> float:
	var t0 := ph * a0.length
	var t1 := ph * a1.length
	var xf := Transform3D.IDENTITY
	for b: int in chain:
		var rest := skeleton.get_bone_rest(b)
		var pos := rest.origin
		var rot := rest.basis.get_rotation_quaternion()
		if b != chain[0]:
			var k0 := _track(a0, b)
			var k1 := _track(a1, b) if w > 0.0 else k0
			var r0 := a0.rotation_track_interpolate(k0.x, t0) if k0.x >= 0 else rot
			var r1 := a1.rotation_track_interpolate(k1.x, t1) if k1.x >= 0 else rot
			rot = r0.slerp(r1, w) if w > 0.0 else r0
			var p0 := a0.position_track_interpolate(k0.y, t0) * skeleton.motion_scale if k0.y >= 0 else pos
			var p1 := a1.position_track_interpolate(k1.y, t1) * skeleton.motion_scale if k1.y >= 0 else pos
			pos = p0.lerp(p1, w)
		xf = xf * Transform3D(Basis(rot).scaled(rest.basis.get_scale()), pos)
	return xf.origin.y


## (rotation track, position track) of bone b in clip a; -1 where it has none. Cached per clip.
func _track(a: Animation, b: int) -> Vector2i:
	var key := "%d|%d" % [a.get_instance_id(), b]
	if _tracks.has(key):
		return _tracks[key]
	var path := NodePath("%GeneralSkeleton:" + skeleton.get_bone_name(b))
	var r := Vector2i(a.find_track(path, Animation.TYPE_ROTATION_3D), a.find_track(path, Animation.TYPE_POSITION_3D))
	_tracks[key] = r
	return r


## Where samples h (one cycle) come down to within CONTACT_EPS of their lowest value inside the
## window around nominal (the heel strike after the swing), interpolated between samples.
static func _down_phase(h: PackedFloat32Array, nominal: float) -> float:
	var n := h.size()
	var i0 := roundi((nominal - CONTACT_BEFORE) * n)
	var i1 := roundi((nominal + CONTACT_AFTER) * n)
	var lo := INF
	for i in range(i0, i1 + 1):
		lo = minf(lo, h[posmod(i, n)])
	var thr := lo + CONTACT_EPS
	for i in range(i0 + 1, i1 + 1):
		var prev := h[posmod(i - 1, n)]
		var cur := h[posmod(i, n)]
		if prev > thr and cur <= thr:
			var f := clampf((prev - thr) / maxf(prev - cur, 1e-6), 0.0, 1.0)
			return fposmod((float(i) - 1.0 + f) / float(n), 1.0)
	return fposmod(nominal, 1.0)


# --- Head look

func _look_modifier(n: String, bone: String, yaw_lim: float, pitch_lim: float) -> LookAtModifier3D:
	var m := LookAtModifier3D.new()
	m.name = n
	m.bone_name = bone
	m.forward_axis = AP.CHAR_LOOK_AXIS
	m.primary_rotation_axis = Vector3.AXIS_Y
	m.use_secondary_rotation = true
	m.use_angle_limitation = true
	m.symmetry_limitation = true
	# The limit angles span both sides.
	m.primary_limit_angle = yaw_lim * 2.0
	m.secondary_limit_angle = pitch_lim * 2.0
	m.duration = LOOK_DURATION
	m.transition_type = Tween.TRANS_SINE
	m.ease_type = Tween.EASE_IN_OUT
	m.origin_safe_margin = LOOK_SAFE_MARGIN
	skeleton.add_child(m)
	return m


func _on_look_processed() -> void:
	look_within = head_look.is_target_within_limitation()
	head_forward = (skeleton.global_transform.basis * skeleton.get_bone_global_pose(_head_bone).basis.z).normalized()


## Smooths the target's direction from the head (a jump between targets turns the head rather
## than snapping it) and fades the influence out while the target is outside the limits.
func _update_look(dt: float) -> void:
	var head := skeleton.global_transform * skeleton.get_bone_global_pose(_head_bone).origin
	var want := 0.0
	if not is_nan(_look_goal.x):
		var d := _look_goal - head
		var dist := d.length()
		if dist > 1e-6:
			var dir := d / dist
			if _look_dir == Vector3.ZERO or dt <= 0.0:
				_look_dir = dir
				_look_dist = dist
			else:
				var s := 1.0 - pow(0.5, dt / HL_LOOK)
				_look_dir = _look_dir.slerp(dir, s).normalized()
				_look_dist = lerpf(_look_dist, dist, s)
			if look_marker.is_inside_tree():
				look_marker.global_position = head + _look_dir * _look_dist
			else:
				look_marker.position = head + _look_dir * _look_dist
			want = 1.0 if look_within or look_weight <= 0.0 else 0.0
	if look_weight <= 0.0 and want > 0.0 and not _within_limits(head, LOOK_REARM):
		want = 0.0
	var w := want if dt <= 0.0 else move_toward(look_weight, want, dt / LOOK_FADE)
	_set_look_weight(w)


## The analytic limit test, used while the modifier is faded out (its flag is then stale): the
## target's yaw and pitch from the chest's forward.
func _within_limits(head: Vector3, margin: float) -> bool:
	var chest := skeleton.find_bone("UpperChest")
	if chest < 0:
		return true
	var xf := skeleton.global_transform * skeleton.get_bone_global_pose(chest)
	var local := xf.basis.inverse() * (look_marker.global_position - head)
	var yaw := atan2(local.x, local.z)
	var pitch := atan2(local.y, Vector2(local.x, local.z).length())
	return absf(yaw) <= LOOK_YAW - margin and absf(pitch) <= LOOK_PITCH - margin


func _set_look_weight(w: float) -> void:
	look_weight = w
	head_look.influence = w
	neck_look.influence = NECK_INFLUENCE * w
	head_look.active = w > 0.0
	neck_look.active = w > 0.0
