class_name FpPlayer
extends Node3D
## First-person walker: feet at `position`, camera at eye height. Kinematic only (no physics
## bodies); collides through ctx.collision. S0 version: walk, run, mouse look, ground snap,
## building and water blocking.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
## Rate (1/s) at which the feet follow the ground height; gaps above GROUND_SNAP snap at once.
const GROUND_FOLLOW := 20.0
const GROUND_SNAP := 0.05

var ctx: FpContext
var camera: Camera3D
var yaw: float = 0.0        # radians; rotation.y of the body. Forward = (-sin(yaw), 0, -cos(yaw)).
var pitch: float = 0.0      # radians, clamped to ±PITCH_LIMIT_DEG; rotation.x of the camera
var velocity: Vector3 = Vector3.ZERO
var input_enabled: bool = true   # false for tests and scripted tours
var photo_mode: bool = false     # A's free-fly photo mode; FpMode ignores hud_toggle and C ignores chat_open while true
var _sensitivity: float = WS.MOUSE_SENSITIVITY
var _invert_y: bool = false
var _last_tile: int = -2


## Builds the eye camera (sharing ctx.env, so SkyDirector's sky applies) and makes it current.
func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.position = Vector3(0.0, WS.EYE, 0.0)
	camera.near = WS.CAMERA_NEAR
	camera.far = WS.CAMERA_FAR
	camera.fov = float(ctx.settings.get("fov", WS.FOV))
	camera.environment = ctx.env
	add_child(camera)
	if camera.is_inside_tree():
		camera.make_current()
	_apply_settings(ctx.settings)
	if ctx.bus != null:
		ctx.bus.settings_changed.connect(_apply_settings)
	_apply_rotation()


## Places the feet at pos (y snapped to the ground when snap is true) and faces yaw/pitch (degrees).
func teleport(pos: Vector3, yaw_deg: float, pitch_deg: float = 0.0, snap: bool = true) -> void:
	position = pos
	if snap:
		snap_to_ground()
	yaw = deg_to_rad(yaw_deg)
	pitch = clampf(deg_to_rad(pitch_deg), -deg_to_rad(WS.PITCH_LIMIT_DEG), deg_to_rad(WS.PITCH_LIMIT_DEG))
	velocity = Vector3.ZERO
	_apply_rotation()
	_update_tile()


## Faces a world point (yaw and pitch).
func look_toward(target: Vector3) -> void:
	var d := target - eye_position()
	if d.length_squared() < 1e-12:
		return
	yaw = atan2(-d.x, -d.z)
	pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -deg_to_rad(WS.PITCH_LIMIT_DEG), deg_to_rad(WS.PITCH_LIMIT_DEG))
	_apply_rotation()


## World position of the eye (camera origin).
func eye_position() -> Vector3:
	if camera != null and camera.is_inside_tree():
		return camera.global_position
	return position + Vector3(0.0, WS.EYE, 0.0)


## Unit look direction, including pitch.
func forward() -> Vector3:
	return Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))


## Tile index under the feet or -1.
func tile() -> int:
	var x := roundi(position.x)
	var y := roundi(position.z)
	return D.idx(x, y) if D.in_bounds(x, y) else -1


## Puts the feet on the walkable ground under them (no change over unwalkable ground).
func snap_to_ground() -> void:
	if ctx == null or ctx.collision == null:
		return
	var g := ctx.collision.ground_height(position)
	if not is_nan(g):
		position.y = g


## One deterministic movement step; _process calls it with the input state, tests call it directly.
## wish: x = strafe right, y = forward, each -1..1. While ctx.is_modal(), simulate itself zeroes
## wish and jump (gravity and ground snap still run), so tests and _process behave the same.
## S0 ignores crouch and jump; A implements them without changing the signature.
func simulate(wish: Vector2, sprint: bool, delta: float, _crouch: bool = false, _jump: bool = false) -> void:
	if ctx == null or ctx.collision == null or delta <= 0.0:
		return
	if ctx.is_modal():
		wish = Vector2.ZERO
	if wish.length_squared() > 1.0:
		wish = wish.normalized()
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var target := (right * wish.x + fwd * wish.y) * (WS.RUN if sprint else WS.WALK)
	var flat := Vector3(velocity.x, 0.0, velocity.z).move_toward(target, WS.ACCEL * delta)
	velocity = Vector3(flat.x, 0.0, flat.z)
	var p := ctx.collision.move_and_slide(position, velocity * delta, WS.PLAYER_RADIUS)
	var r := WS.PLAYER_RADIUS
	p.x = clampf(p.x, D.X0 - 0.5 + r, D.X0 + D.W - 0.5 - r)
	p.z = clampf(p.z, D.Y0 - 0.5 + r, D.Y0 + D.H - 0.5 - r)
	var g := ctx.collision.ground_height(p)
	if not is_nan(g):
		if absf(g - p.y) > GROUND_SNAP:
			p.y = g
		else:
			p.y = lerpf(p.y, g, minf(1.0, GROUND_FOLLOW * delta))
	position = p
	_update_tile()


## Save section: {"pos": [x, y, z], "yaw": deg, "pitch": deg}.
func to_dict() -> Dictionary:
	return {"pos": [position.x, position.y, position.z], "yaw": rad_to_deg(yaw), "pitch": rad_to_deg(pitch)}


## Restores to_dict(); {} (or no "pos") spawns at ctx.mode.spawn_point().
func from_dict(d: Dictionary) -> void:
	var pos: Variant = d.get("pos")
	if typeof(pos) == TYPE_ARRAY and (pos as Array).size() >= 3:
		var a: Array = pos
		teleport(Vector3(float(a[0]), float(a[1]), float(a[2])), float(d.get("yaw", 0.0)), float(d.get("pitch", 0.0)), false)
		var g := ctx.collision.ground_height(position) if ctx != null and ctx.collision != null else NAN
		if not is_nan(g) and absf(g - position.y) > GROUND_SNAP:
			position.y = g
		return
	var sp: Dictionary = ctx.mode.spawn_point() if ctx != null and ctx.mode != null else {"pos": Vector3.ZERO, "yaw": 0.0}
	teleport(sp["pos"], float(sp["yaw"]), 0.0, true)


func _process(delta: float) -> void:
	if not input_enabled or ctx == null:
		return
	var wish := Input.get_vector("move_left", "move_right", "move_back", "move_forward")
	simulate(wish, Input.is_action_pressed("sprint"), delta, Input.is_action_pressed("crouch"), Input.is_action_pressed("jump"))


func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled or ctx == null or ctx.is_modal():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		mouse_look(event as InputEventMouseMotion)


## Turns the view by a mouse motion at mouse_sensitivity radians per screen pixel. Reads
## screen_relative: `relative` is scaled by the window's content-scale stretch (canvas_items,
## 1600x900 base), so look speed would change with the window size.
func mouse_look(event: InputEventMouseMotion) -> void:
	var rel := event.screen_relative
	yaw = wrapf(yaw - rel.x * _sensitivity, -PI, PI)
	var limit := deg_to_rad(WS.PITCH_LIMIT_DEG)
	pitch = clampf(pitch - rel.y * _sensitivity * (-1.0 if _invert_y else 1.0), -limit, limit)
	_apply_rotation()


func _apply_settings(s: Dictionary) -> void:
	_sensitivity = float(s.get("mouse_sensitivity", WS.MOUSE_SENSITIVITY))
	_invert_y = bool(s.get("invert_y", false))
	if camera != null:
		camera.fov = float(s.get("fov", WS.FOV))


func _apply_rotation() -> void:
	rotation = Vector3(0.0, yaw, 0.0)
	if camera != null:
		camera.rotation = Vector3(pitch, 0.0, 0.0)


func _update_tile() -> void:
	var t := tile()
	if t == _last_tile:
		return
	_last_tile = t
	if t >= 0 and ctx != null and ctx.bus != null:
		ctx.bus.player_tile_changed.emit(D.tx(t), D.ty(t))
