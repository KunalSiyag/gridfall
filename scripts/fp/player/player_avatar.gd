extends Node3D
## The player's visible body (slice A). Stage A2: HC's animated hero (hero_rig.gd: AP.HERO_M or
## AP.HERO_F per settings.hero, the gender's shared animation library, an AnimationTree driven
## from code, head look through LookAtModifier3Ds) under a CharacterRoot scaled to the hero's
## height (WS.M * h_target / rest_height_m from HC's roster), turned to face the player's -Z
## forward. When the hero's files are missing it falls back to the stage A1 placeholder: the legacy
## person (AP.PEOPLE_LEGACY_DIR person_a.glb at WS.PEOPLE_SCALE) re-rigged as a jointed puppet
## (placeholder_puppet.gd) that walks, runs, crouches, jumps and lands with a procedural gait.
## Either body's foot contacts drive FpPlayer's footsteps. Procedural lean about the feet and a
## damped visual step offset apply on top. The head turns toward a look target (A 6.9: the
## conversation partner, the focused interactable or where the camera looks). In first person
## the body only casts its shadow; in third person it fades out when the camera comes close to
## the head.

const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const SM := preload("res://scripts/fp/player/spring_math.gd")
const PUPPET := preload("res://scripts/fp/player/placeholder_puppet.gd")
const HERO := preload("res://scripts/fp/player/hero_rig.gd")
## HC's roster defaults (Rocketbox: one skeleton per gender) for a checkout without roster.json.
const ROSTER_DEFAULTS := {"m": {"rest_height_m": 1.7951, "hip_m": 0.8952}, "f": {"rest_height_m": 1.7164, "hip_m": 0.9233}}
## Hero heights (m; HC-characters.md 1.9): the man at WS.PERSON_H, the woman 5 % shorter.
const HERO_H := 1.75
const HERO_F_FACTOR := 0.95
## Placeholder bodies per settings.hero (the legacy people are not gendered; b reads as the
## alternative figure).
const PLACEHOLDERS := {"m": "person_a.glb", "f": "person_b.glb"}
## Procedural lean (A 6.4): roll = clamp(0.35 atan(v w / g), +-8 deg), pitch = clamp(0.5
## atan(a_fwd / g), -5..+7 deg), spring halflife 0.1 s.
const LEAN_ROLL_K := 0.35
const LEAN_ROLL_MAX := deg_to_rad(8.0)
const LEAN_PITCH_K := 0.5
const LEAN_PITCH_MIN := deg_to_rad(-5.0)
const LEAN_PITCH_MAX := deg_to_rad(7.0)
const HL_LEAN := 0.1
## The visual step offset decays with this halflife (A 6.4: avatar y after a curb step).
const HL_STEP := 0.05
## A body that cannot be re-rigged has no crouch pose: it squats to this height and tips forward.
const RIGID_CROUCH_Y := 0.7
const RIGID_CROUCH_TIP := deg_to_rad(12.0)
# --- Procedural gait (degrees; s is the cycle fraction of one leg, 0 = its heel strike)
## Blend weights follow their goals with these halflives (s).
const HL_MOVE := 0.08
const HL_RUN := 0.15
const HL_CROUCH := 0.08
const HL_AIR_IN := 0.06
const HL_AIR_OUT := 0.04
const HL_LAND := 0.12
## The gait is fully on from this fraction of WALK; the run pose from RUN_FROM to RUN_FULL (m/s).
const MOVE_FULL := 0.55
const RUN_FROM := 1.9
const RUN_FULL := 3.8
## Landing harder than this (m/s down) gives the full landing dip.
const LAND_HARD := 3.0
## Crouch base pose and how much of the gait remains while crouched.
const CROUCH_HIP := 80.0
const CROUCH_KNEE := 112.0
const CROUCH_LEAN := 26.0
const CROUCH_ELBOW := 35.0
const CROUCH_GAIT := 0.55
## Running pelvis height below rest (m) at mid-stance and its rise into the flight phase (m);
## pelvis sway while walking (m).
const RUN_LOW := 0.06
const RUN_LIFT := 0.045
const WALK_SWAY := 0.012
# --- Head look (A 6.9): limits, the angle beyond which the head returns to neutral, halflife
const LOOK_YAW_MAX := deg_to_rad(70.0)
const LOOK_PITCH_MAX := deg_to_rad(35.0)
const LOOK_GIVE_UP := deg_to_rad(110.0)
const HL_LOOK := 0.1
## Turning in place at this rate or faster takes full-size shuffle steps (rad/s); their size.
const TURN_SHUFFLE_RATE := deg_to_rad(180.0)
const TURN_SHUFFLE := 0.6
## Idle breathing: spine and shoulder swing (degrees) and rate (Hz).
const BREATH_DEG := 0.7
const BREATH_HZ := 0.23

## "m" or "f" (settings.hero).
var hero: String = ""
## Body and library per hero; a missing file falls back to the placeholder (tests point these at
## missing files to exercise it).
var hero_paths: Dictionary = {"m": [AP.HERO_M, AP.CHAR_LIB_M], "f": [AP.HERO_F, AP.CHAR_LIB_F]}
## True when the loaded body is the legacy placeholder.
var placeholder: bool = true
## HC's animated hero (hero_rig.gd), or null for the placeholder.
var rig: RefCounted = null
## The jointed placeholder (placeholder_puppet.gd), or null for a rigid body.
var puppet: RefCounted = null
var _root: Node3D
var _body: Node3D
var _geoms: Array[GeometryInstance3D] = []
var _roll: Vector2 = Vector2.ZERO        # (angle, velocity)
var _pitch: Vector2 = Vector2.ZERO
var _dy: float = 0.0
var _shadow_only: bool = false
var _alpha: float = 1.0
var _crouch: float = 0.0
var _move_w: float = 0.0
var _run_w: float = 0.0
var _crouch_w: float = 0.0
var _air_w: float = 0.0
var _land_w: float = 0.0
var _was_grounded: bool = true
var _last_vy: float = 0.0
var _phase: float = 0.0
var _breath: float = 0.0
var _look_target: Vector3 = Vector3(NAN, NAN, NAN)
## Current head look (yaw toward the figure's left, pitch up), radians.
var head_look: Vector2 = Vector2.ZERO
## The last pose's joint angles (radians) per side, for tests: {"hip", "knee", "ankle",
## "shoulder", "elbow"} -> [left, right].
var joints: Dictionary = {}


## Loads the body for hero ("m" or "f"): HC's animated hero, else the placeholder; a body that
## cannot load keeps the current one.
func set_hero(h: String) -> void:
	if h != "f":
		h = "m"
	if h == hero and _body != null:
		return
	var new_rig := _build_hero(h)
	var new_puppet: RefCounted = null
	var new_body: Node3D = null
	var scale := WS.PEOPLE_SCALE
	if new_rig != null:
		new_body = new_rig.get("body")
		scale = _hero_scale(h)
	else:
		var path: String = AP.PEOPLE_LEGACY_DIR + str(PLACEHOLDERS.get(h, PLACEHOLDERS["m"]))
		var ps := AP.load_scene(path)
		if ps == null and _body != null:
			return
		new_puppet = PUPPET.build(path, ps) if ps != null else null
		if new_puppet != null:
			new_body = new_puppet.get("root")
		elif ps != null:
			new_body = ps.instantiate() as Node3D
		if new_body == null:
			new_body = _stand_in()
	hero = h
	if _root == null:
		_root = Node3D.new()
		_root.name = "CharacterRoot"
		add_child(_root)
	if _body != null:
		_body.queue_free()
		_body = null
	_geoms.clear()
	rig = new_rig
	puppet = new_puppet
	placeholder = rig == null
	_body = new_body
	_body.name = "Body"
	# Both bodies face +Z; the player looks along -Z.
	_body.rotation.y = PI
	_root.scale = Vector3.ONE * scale
	_root.rotation = Vector3.ZERO
	_root.add_child(_body)
	for g: Node in _body.find_children("*", "GeometryInstance3D", true, false):
		_geoms.append(g as GeometryInstance3D)
	if _body is GeometryInstance3D:
		_geoms.append(_body as GeometryInstance3D)
	_apply_look()
	if rig != null:
		rig.call("snap", _crouch > 0.5)
	else:
		_pose(0.0)


## True while HC's animated hero is the body (its clips then own the gait and the footsteps).
func is_animated() -> bool:
	return rig != null


## The hero's locomotion phase in radians (the left heel strikes at 0, the right at PI), or NAN
## outside locomotion; NAN for the placeholder.
func gait_phase() -> float:
	if rig == null:
		return NAN
	var ph: float = rig.get("phase")
	return ph * TAU if ph >= 0.0 else NAN


## Foot contacts of the last update_motion (hero only): [{"left": bool, "pos": Vector3}].
func contacts() -> Array[Dictionary]:
	if rig == null:
		return []
	return rig.get("contacts")


## Plays an upper-body gesture on the hero ("interact", "wave", "phone", "door_try").
func play_gesture(g: String) -> void:
	if rig != null:
		rig.call("play_gesture", g)


## First person: shadow only (you see your shadow, never your body). alpha 0..1 fades the body in
## third person (0 hides it, so the near plane never cuts through the head).
func set_view_state(shadow_only: bool, alpha: float) -> void:
	alpha = clampf(alpha, 0.0, 1.0)
	if shadow_only == _shadow_only and absf(alpha - _alpha) < 0.01 and not (alpha == 0.0 and _alpha != 0.0) and not (alpha == 1.0 and _alpha != 1.0):
		return
	_shadow_only = shadow_only
	_alpha = alpha
	_apply_look()


## Per frame: lean from the planar velocity (u/s), yaw rate (rad/s) and forward acceleration
## (u/s^2); step is the feet's sudden vertical jump this frame (a curb), absorbed visually; crouch
## is 0 standing .. 1 crouched; phase is FpPlayer's gait phase (radians, the left heel strikes at
## 0 and the right at PI); grounded and vy (u/s) drive the jump and landing poses.
## talking holds the hero in its talk loop; backward plays its walk in reverse (first person).
func update_motion(dt: float, speed: float, yaw_rate: float, fwd_acc: float, step: float, crouch: float = 0.0, phase: float = 0.0, grounded: bool = true, vy: float = 0.0, talking: bool = false, backward: bool = false) -> void:
	_crouch = clampf(crouch, 0.0, 1.0)
	if _root != null and placeholder and puppet == null:
		_root.scale = Vector3(1.0, lerpf(1.0, RIGID_CROUCH_Y, _crouch), 1.0) * WS.PEOPLE_SCALE
		_root.rotation.x = -RIGID_CROUCH_TIP * _crouch
	var roll_goal := clampf(LEAN_ROLL_K * atan(speed * yaw_rate / WS.GRAVITY), -LEAN_ROLL_MAX, LEAN_ROLL_MAX)
	var pitch_goal := clampf(LEAN_PITCH_K * atan(fwd_acc / WS.GRAVITY), LEAN_PITCH_MIN, LEAN_PITCH_MAX)
	_roll = SM.spring(_roll.x, _roll.y, roll_goal, HL_LEAN, dt)
	_pitch = SM.spring(_pitch.x, _pitch.y, pitch_goal, HL_LEAN, dt)
	_dy = SM.damp(_dy - step, 0.0, HL_STEP, dt)
	# Roll about the forward axis (-Z), positive leans left; pitch about +X, positive leans forward.
	transform = Transform3D(Basis.from_euler(Vector3(-_pitch.x, 0.0, _roll.x)), Vector3(0.0, _dy, 0.0))
	if rig != null:
		rig.call("set_look_target", _look_target)
		rig.call("update", dt, (-speed if backward else speed) / WS.M, grounded, vy / WS.M, _crouch > 0.5, talking)
		return
	if puppet == null:
		return
	var mps := speed / WS.M
	_phase = phase
	var move_goal := clampf(mps / (MOVE_FULL * WS.WALK / WS.M), 0.0, 1.0)
	move_goal = maxf(move_goal, TURN_SHUFFLE * clampf(absf(yaw_rate) / TURN_SHUFFLE_RATE, 0.0, 1.0))
	_move_w = SM.damp(_move_w, move_goal if grounded else _move_w, HL_MOVE, dt)
	_breath = fmod(_breath + dt * BREATH_HZ, 1.0)
	_run_w = SM.damp(_run_w, smoothstep(RUN_FROM, RUN_FULL, mps), HL_RUN, dt)
	_crouch_w = SM.damp(_crouch_w, _crouch, HL_CROUCH, dt)
	_air_w = SM.damp(_air_w, 0.0 if grounded else 1.0, HL_AIR_OUT if grounded else HL_AIR_IN, dt)
	if grounded and not _was_grounded:
		_land_w = maxf(_land_w, clampf(-_last_vy / (LAND_HARD * WS.M), 0.25, 1.0))
	_land_w = SM.damp(_land_w, 0.0, HL_LAND, dt)
	_was_grounded = grounded
	_last_vy = vy
	_pose(_phase)
	_head_look(dt)


## The world point the head turns toward (NAN components: look straight ahead).
func set_look_target(p: Vector3) -> void:
	_look_target = p


## Clears lean and step offsets and the gait blends (teleport).
func snap() -> void:
	_roll = Vector2.ZERO
	_pitch = Vector2.ZERO
	_dy = 0.0
	_move_w = 0.0
	_run_w = 0.0
	_crouch_w = _crouch
	_air_w = 0.0
	_land_w = 0.0
	_was_grounded = true
	head_look = Vector2.ZERO
	transform = Transform3D.IDENTITY
	if rig != null:
		rig.call("snap", _crouch > 0.5)
		return
	_pose(_phase)
	_head_look(0.0)


## Current lean (roll, pitch) in radians, for tests.
func lean() -> Vector2:
	return Vector2(_roll.x, _pitch.x)


## True while the body draws (not shadow-only and not faded out).
func is_body_visible() -> bool:
	return visible and not _shadow_only and _alpha > 0.0


## The pelvis offset from its rest position (metres * M) and the lowest ankle above the feet
## (metres * M), for tests; zero for a rigid body.
func pose_metrics() -> Dictionary:
	if puppet == null:
		return {"pelvis": Vector3.ZERO, "ankle_low": 0.0, "ankle_rest": 0.0}
	var pl: Node3D = puppet.get("pelvis")
	var rest: Vector3 = puppet.get("pelvis_rest")
	var ankles: Array[Node3D] = puppet.get("ankles")
	var low := INF
	for a: Node3D in ankles:
		low = minf(low, (to_local(a.global_position) if a.is_inside_tree() else _model_point(a)).y)
	return {"pelvis": (pl.position - rest) * WS.PEOPLE_SCALE, "ankle_low": low, "ankle_rest": float(puppet.get("ankle_y")) * WS.PEOPLE_SCALE}


## The gait, crouch, air and landing poses blended for this frame and written to the puppet.
func _pose(phase: float) -> void:
	if puppet == null:
		return
	var hip := [0.0, 0.0]
	var knee := [0.0, 0.0]
	var ankle := [0.0, 0.0]
	var shoulder := [0.0, 0.0]
	var elbow := [0.0, 0.0]
	var gait := _move_w * (1.0 - CROUCH_GAIT * _crouch_w)
	var c := _crouch_w
	var fwd_sum := 0.0
	var reach_max := 0.0
	for i in range(2):
		var s := fposmod(phase / TAU + (0.0 if i == 0 else 0.5), 1.0)
		var g := _gait(s)
		var h := g.x * gait + CROUCH_HIP * c
		var k := g.y * gait + CROUCH_KNEE * c + 4.0 * (1.0 - c)
		var toe := g.z * gait
		var sh := g.w * gait + 8.0 * c
		var el := maxf(lerpf(10.0, CROUCH_ELBOW, c), _elbow(s) * _move_w)
		# Air: one leg reaching, the other tucked; landing: a quick dip.
		var air_h := 38.0 if i == 0 else -2.0
		var air_k := 78.0 if i == 0 else 42.0
		h = lerpf(h, air_h, _air_w) + 22.0 * _land_w
		k = lerpf(k, air_k, _air_w) + 44.0 * _land_w
		toe = lerpf(toe, 18.0, _air_w)
		sh = lerpf(sh, 25.0 if i == 1 else -15.0, _air_w)
		el = lerpf(el, 45.0, _air_w)
		var hr := deg_to_rad(h)
		var kr := deg_to_rad(maxf(k, 0.0))
		hip[i] = hr
		knee[i] = kr
		ankle[i] = hr - kr + deg_to_rad(toe)
		shoulder[i] = deg_to_rad(sh)
		elbow[i] = deg_to_rad(maxf(el, 0.0))
		reach_max = maxf(reach_max, puppet.call("reach", hr, kr))
		fwd_sum += float(puppet.call("forward_reach", hr, kr))
	var rest: Vector3 = puppet.get("pelvis_rest")
	var s0 := fposmod(phase / TAU, 1.0)
	# Grounded: the longer leg stands on the ground (its ankle at the rest ankle height). Running
	# lifts the pelvis into the flight phase (never lower, so no foot sinks); in the air the legs
	# hang from the rest pelvis height.
	var y := float(puppet.get("ankle_y")) + reach_max
	var y_run := rest.y + (-RUN_LOW + RUN_LIFT * (0.5 - 0.5 * cos(TAU * 2.0 * (s0 - 0.12)))) * WS.M
	y = lerpf(y, maxf(y, y_run), _run_w * gait)
	y = lerpf(y, rest.y, _air_w)
	var sway := WALK_SWAY * WS.M * sin(TAU * s0) * gait * (1.0 - _run_w)
	# Crouched, the pelvis sits back over the feet.
	var z := -fwd_sum * 0.5 * c * (1.0 - _air_w)
	var calm := (1.0 - _move_w) * (1.0 - _air_w)
	var breath := deg_to_rad(BREATH_DEG) * sin(TAU * _breath) * calm
	shoulder[0] += breath
	shoulder[1] += breath
	var lean := deg_to_rad((3.0 + 7.0 * _run_w) * gait + CROUCH_LEAN * c + 6.0 * _land_w) - breath * 0.5
	puppet.call("apply", hip, knee, ankle, shoulder, elbow, Vector3(sway, y - rest.y, z), lean)
	joints = {"hip": hip, "knee": knee, "ankle": ankle, "shoulder": shoulder, "elbow": elbow}


## Turns the head toward the look target within its limits, measured in the spine's frame (so a
## running lean keeps the eyes level); a target behind the figure eases the head back to neutral.
func _head_look(dt: float) -> void:
	if puppet == null:
		return
	var hd: Node3D = puppet.get("head")
	if hd == null:
		return
	var goal := Vector2.ZERO
	var sp: Node3D = puppet.get("spine")
	if not is_nan(_look_target.x) and sp.is_inside_tree():
		var d := sp.global_transform.affine_inverse() * _look_target - hd.position
		var yaw := atan2(d.x, d.z)
		if absf(yaw) < LOOK_GIVE_UP and d.length_squared() > 1e-12:
			goal = Vector2(clampf(yaw, -LOOK_YAW_MAX, LOOK_YAW_MAX), clampf(atan2(d.y, Vector2(d.x, d.z).length()), -LOOK_PITCH_MAX, LOOK_PITCH_MAX))
	if dt <= 0.0:
		head_look = goal
	else:
		head_look = Vector2(SM.damp_angle(head_look.x, goal.x, HL_LOOK, dt), SM.damp(head_look.y, goal.y, HL_LOOK, dt))
	puppet.call("look", head_look.x, head_look.y)


## One leg's gait at cycle fraction s (degrees): x hip swing, y knee flexion, z toe pitch, w the
## same-side arm's swing; walk and run blended by the run weight.
func _gait(s: float) -> Vector4:
	var cs := cos(TAU * s)
	var walk := Vector4(
		5.0 + 21.0 * cs,
		10.0 * _bump(s, 0.12, 0.07) + 55.0 * _bump(s, 0.72, 0.11),
		14.0 * _bump(s, 0.58, 0.06) - 6.0 * _bump(s, 0.98, 0.05),
		-16.0 * cs)
	var run := Vector4(
		8.0 + 32.0 * cos(TAU * (s + 0.05)),
		10.0 + 22.0 * _bump(s, 0.12, 0.08) + 100.0 * _bump(s, 0.66, 0.14),
		22.0 * _bump(s, 0.38, 0.07),
		6.0 - 40.0 * cs)
	return walk.lerp(run, _run_w)


## The same-side elbow flexion at cycle fraction s (degrees): more as the arm swings forward.
func _elbow(s: float) -> float:
	var fwd := maxf(0.0, -cos(TAU * s))
	return lerpf(12.0 + 14.0 * fwd, 82.0 + 14.0 * fwd, _run_w)


## A periodic bump of width w centred on c (cycle fractions).
static func _bump(s: float, c: float, w: float) -> float:
	var d := wrapf(s - c, -0.5, 0.5)
	return exp(-(d * d) / (w * w))


## HC's hero for h, or null when its body or library is missing.
func _build_hero(h: String) -> RefCounted:
	var paths: Array = hero_paths.get(h, [])
	if paths.size() < 2:
		return null
	var info := _roster_body(h, str(paths[0]))
	var lib_path := str(paths[1])
	var lib := load(lib_path) as AnimationLibrary if ResourceLoader.exists(lib_path) else null
	var ref_hip := 0.0
	if lib != null and lib.has_animation("walk"):
		ref_hip = float(lib.get_animation("walk").get_meta("speed_ref_hip_m", 0.0))
	var hip_ratio := float(info["hip_m"]) / ref_hip if ref_hip > 0.0 else 1.0
	var k := hip_ratio * _hero_height(h) / float(info["rest_height_m"])
	return HERO.build(str(paths[0]), lib_path, k, h)


## WS.M * h_target / rest_height_m: the CharacterRoot scale that makes the hero h_target tall.
func _hero_scale(h: String) -> float:
	var paths: Array = hero_paths.get(h, [""])
	return WS.M * _hero_height(h) / float(_roster_body(h, str(paths[0]))["rest_height_m"])


static func _hero_height(h: String) -> float:
	return HERO_H * (HERO_F_FACTOR if h == "f" else 1.0)


static var _roster: Dictionary = {}


## The roster entry (rest_height_m, hip_m) of the body at path, else the gender's defaults.
static func _roster_body(h: String, path: String) -> Dictionary:
	if _roster.is_empty():
		var f := FileAccess.open(AP.CHAR_ROSTER, FileAccess.READ)
		var parsed: Variant = JSON.parse_string(f.get_as_text()) if f != null else null
		_roster = parsed if typeof(parsed) == TYPE_DICTIONARY else {"bodies": {}}
	var bodies: Dictionary = _roster.get("bodies", {})
	var e: Variant = bodies.get(path.get_file().get_basename(), null)
	var d: Dictionary = ROSTER_DEFAULTS["f" if h == "f" else "m"]
	if typeof(e) != TYPE_DICTIONARY:
		return d
	return {"rest_height_m": float((e as Dictionary).get("rest_height_m", d["rest_height_m"])), "hip_m": float((e as Dictionary).get("hip_m", d["hip_m"]))}


func _model_point(n: Node3D) -> Vector3:
	var xf := n.transform
	var p := n.get_parent()
	while p != null and p != self and p is Node3D:
		xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf.origin


func _apply_look() -> void:
	var cast := GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if _shadow_only else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var hidden := not _shadow_only and _alpha <= 0.0
	for g: GeometryInstance3D in _geoms:
		if not is_instance_valid(g):
			continue
		g.cast_shadow = cast
		g.transparency = 0.0 if _shadow_only else 1.0 - _alpha
		g.visible = not hidden


## A capsule figure for a checkout without the legacy people.
func _stand_in() -> Node3D:
	var n := Node3D.new()
	var mi := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.22 * WS.M
	cm.height = 1.75 * WS.M
	mi.mesh = cm
	mi.position.y = 0.875 * WS.M
	n.add_child(mi)
	return n
