extends Node3D
## The player's visible body (slice A). Stage A1: the legacy static person (AP.PEOPLE_LEGACY_DIR
## person_a.glb at WS.PEOPLE_SCALE) as a placeholder under a CharacterRoot, turned to face the
## player's -Z forward, with procedural lean about the feet and a damped visual step offset. HC's
## animated hero replaces the placeholder in stage A2. In first person it only casts its shadow;
## in third person it fades out when the camera comes close to the head.

const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const SM := preload("res://scripts/fp/player/spring_math.gd")
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
## The static placeholder has no crouch pose: it squats to this height and tips forward instead
## (HC's hero plays crouch clips in stage A2).
const PLACEHOLDER_CROUCH_Y := 0.7
const PLACEHOLDER_CROUCH_TIP := deg_to_rad(12.0)

## "m" or "f" (settings.hero).
var hero: String = ""
## True when the loaded body is the legacy placeholder (always, until stage A2).
var placeholder: bool = true
var _root: Node3D
var _body: Node3D
var _geoms: Array[GeometryInstance3D] = []
var _roll: Vector2 = Vector2.ZERO        # (angle, velocity)
var _pitch: Vector2 = Vector2.ZERO
var _dy: float = 0.0
var _shadow_only: bool = false
var _alpha: float = 1.0
var _crouch: float = 0.0


## Loads the body for hero ("m" or "f"); a missing file keeps the current body.
func set_hero(h: String) -> void:
	if h == hero and _body != null:
		return
	var file: String = PLACEHOLDERS.get(h, PLACEHOLDERS["m"])
	var ps := AP.load_scene(AP.PEOPLE_LEGACY_DIR + file)
	if ps == null and _body != null:
		return
	hero = h
	if _root == null:
		_root = Node3D.new()
		_root.name = "CharacterRoot"
		add_child(_root)
	if _body != null:
		_body.queue_free()
		_body = null
	_geoms.clear()
	if ps != null:
		_body = ps.instantiate() as Node3D
	if _body == null:
		_body = _stand_in()
	_body.name = "Body"
	# The legacy people face +Z; the player looks along -Z.
	_body.rotation.y = PI
	_root.scale = Vector3.ONE * WS.PEOPLE_SCALE
	_root.add_child(_body)
	for g: Node in _body.find_children("*", "GeometryInstance3D", true, false):
		_geoms.append(g as GeometryInstance3D)
	if _body is GeometryInstance3D:
		_geoms.append(_body as GeometryInstance3D)
	_apply_look()


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
## is 0 standing .. 1 crouched.
func update_motion(dt: float, speed: float, yaw_rate: float, fwd_acc: float, step: float, crouch: float = 0.0) -> void:
	_crouch = clampf(crouch, 0.0, 1.0)
	if _root != null and placeholder:
		_root.scale = Vector3(1.0, lerpf(1.0, PLACEHOLDER_CROUCH_Y, _crouch), 1.0) * WS.PEOPLE_SCALE
		_root.rotation.x = -PLACEHOLDER_CROUCH_TIP * _crouch
	var roll_goal := clampf(LEAN_ROLL_K * atan(speed * yaw_rate / WS.GRAVITY), -LEAN_ROLL_MAX, LEAN_ROLL_MAX)
	var pitch_goal := clampf(LEAN_PITCH_K * atan(fwd_acc / WS.GRAVITY), LEAN_PITCH_MIN, LEAN_PITCH_MAX)
	_roll = SM.spring(_roll.x, _roll.y, roll_goal, HL_LEAN, dt)
	_pitch = SM.spring(_pitch.x, _pitch.y, pitch_goal, HL_LEAN, dt)
	_dy = SM.damp(_dy - step, 0.0, HL_STEP, dt)
	# Roll about the forward axis (-Z), positive leans left; pitch about +X, positive leans forward.
	transform = Transform3D(Basis.from_euler(Vector3(-_pitch.x, 0.0, _roll.x)), Vector3(0.0, _dy, 0.0))


## Clears lean and step offsets (teleport).
func snap() -> void:
	_roll = Vector2.ZERO
	_pitch = Vector2.ZERO
	_dy = 0.0
	transform = Transform3D.IDENTITY


## Current lean (roll, pitch) in radians, for tests.
func lean() -> Vector2:
	return Vector2(_roll.x, _pitch.x)


## True while the body draws (not shadow-only and not faded out).
func is_body_visible() -> bool:
	return visible and not _shadow_only and _alpha > 0.0


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
