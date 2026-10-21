extends FpFeature
## Getting into cars and driving them. Near a parked or stopped car, F (Y on a pad) gets in: the
## hero sits in the driver's seat and the camera chases the car. W / S or the triggers drive and
## brake (S reverses once stopped), A / D or the left stick steer, Space (A) is the handbrake, the
## mouse or right stick look around, V switches to the driver's view, and F again gets out beside
## the driver's door. The car belongs to the traffic feature (lane traffic stops for it and it
## stays where it is left). It is a rigid box (car_body.gd): it bounces off walls, slides along
## them at a glance, spins when hit off-centre, shoves the cars it hits and knocks street props
## over; car_impact on the bus reports the hard hits.

const WS := preload("res://scripts/fp/world_scale.gd")
const MODEL := preload("res://scripts/fp/drive/drive_model.gd")
const HUD := preload("res://scripts/fp/drive/drive_hud.gd")
const BODY := preload("res://scripts/fp/drive/car_body.gd")

## Reach from the hero to a car's body for the get-in prompt.
const ENTER_REACH := 2.0 * WS.M
## Faster than this the hero stays in (about 30 km/h).
const EXIT_SPEED := 8.5 * WS.M
## How far beside the body the hero steps out.
const EXIT_GAP := 0.7 * WS.M
const ENTER_BLEND := 0.45
const EXIT_BLEND := 0.35
const CHASE_DIST := 7.0 * WS.M
const CHASE_PITCH := deg_to_rad(12.0)
const LOOK_UP := 1.3 * WS.M
const LOOK_AHEAD := 3.0 * WS.M
const CAM_RADIUS := 0.25 * WS.M
const CAM_MIN := 1.5 * WS.M
## The chase camera swings in behind the car at this rate (1/s), faster with speed.
const CHASE_FOLLOW := 2.5
const ORBIT_HOLD := 1.5
const ORBIT_RETURN := 2.5
const STICK_ORBIT := deg_to_rad(200.0)
const PITCH_MIN := deg_to_rad(-25.0)
const PITCH_MAX := deg_to_rad(40.0)
const FOV_FAST := 10.0
const EYE_ABOVE_HIP := 0.7 * WS.M
## The driver view sits a little toward the middle so the door pillar does not fill the left side.
const EYE_INBOARD := 0.6
## Ground following: the body rises onto a curb at once and settles down at this rate (u/s).
const SETTLE := 0.3
const PROMPT_TICK := 0.15
## car_impact goes out at most this often (s), for the hardest hit.
const IMPACT_GAP := 0.25

var active: bool = false
var car_id: int = -1
var model := MODEL.new()
var body := BODY.new()
## "chase" or "driver".
var view: String = "chase"
var hud: HUD
## Car half width, height and length (u).
var _dims := Vector3(0.045, 0.075, 0.24)
var _pos := Vector3.ZERO
var _seat: Variant = null
var _hero_off := Vector3.ZERO
var _cam_yaw: float = 0.0
var _orbit: float = 0.0
var _orbit_pitch: float = 0.0
var _orbit_t: float = 0.0
var _prev_mode: String = "first"
var _target: Dictionary = {}
var _t: float = 0.0
var _impact_t: float = 0.0


func feature_id() -> String:
	return "drive"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	if ctx.hud != null:
		hud = HUD.new()
		hud.setup()
		ctx.hud.slot("overlay").add_child(hud)


func teardown() -> void:
	exit(true)
	if hud != null and is_instance_valid(hud):
		hud.queue_free()
	hud = null


func on_world_rebuilt() -> void:
	exit(true)


func from_dict(_d: Dictionary) -> void:
	exit(true)


func self_test() -> Dictionary:
	var m := MODEL.new()
	m.reset(0.0, 0.24)
	for _k in range(120):
		m.step(1.0, 0.0, 0.0, 0.0, "asphalt", 1.0 / 60.0)
	var kmh := m.speed() / WS.M * 3.6
	return {"ok": kmh > 25.0 and kmh < 80.0, "detail": "2 s of full throttle: %.0f km/h" % kmh}


# ------------------------------------------------------------------ getting in and out


## The car the hero could get into now ({} when none or while driving).
func enter_target() -> Dictionary:
	var p := ctx.player if ctx != null else null
	var tr := _traffic()
	if active or p == null or tr == null or ctx.is_modal() or p.photo_mode or p.in_conversation():
		return {}
	return tr.call("enter_target", p.position, ENTER_REACH)


## Gets into the nearest car in reach. Returns true when the hero is now driving.
func enter() -> bool:
	var t := enter_target()
	if t.is_empty():
		return false
	var info: Dictionary = _traffic().call("claim_car", int(t["id"]))
	if info.is_empty():
		return false
	var p := ctx.player
	active = true
	car_id = int(info["id"])
	_pos = info["pos"]
	_dims = Vector3(float(info["half_w"]), float(info["height"]), float(info["length"]))
	model.reset(float(info["yaw"]), _dims.z)
	body.setup(_dims.x, _dims.z, _dims.y)
	_seat = null
	_hero_off = Vector3.ZERO
	_cam_yaw = model.yaw
	_orbit = 0.0
	_orbit_pitch = 0.0
	_prev_mode = p.camera_mode
	p.input_enabled = false
	ctx.collision.dynamic_boxes = []
	p.set_view_override(camera_xform(), _fov(), ENTER_BLEND)
	p.set_camera_mode("third", false)
	_ride()
	_sit(true)
	if ctx.bus != null:
		ctx.bus.drive_changed.emit(true)
	return true


## Gets out beside the driver's door (force: at any speed, wherever there is room or on the spot).
## Returns true when the hero is on foot again.
func exit(force: bool = false) -> bool:
	if not active:
		return false
	if not force and absf(model.speed()) > EXIT_SPEED:
		_toast("Slow down to get out")
		return false
	var spot := _exit_spot()
	if is_nan(spot.x):
		if not force:
			_toast("No room to get out here")
			return false
		spot = _pos
	var tr := _traffic()
	if tr != null:
		tr.call("leave_car")
	active = false
	car_id = -1
	if hud != null:
		hud.set_prompt("")
		hud.set_speed(false, 0.0)
	var p := ctx.player
	if p != null and is_instance_valid(p):
		_sit(false)
		if p.avatar != null:
			p.avatar.visible = true
		p.input_enabled = true
		p.teleport(spot, rad_to_deg(model.yaw + PI), 0.0, true)
		p.set_camera_mode(_prev_mode, false)
		p.clear_view_override(0.0 if force else EXIT_BLEND)
	if ctx.bus != null:
		ctx.bus.drive_changed.emit(false)
	return true


## Free ground beside the driver's door, then the other door, behind and in front; NAN when none.
func _exit_spot() -> Vector3:
	var h := model.heading()
	var left := Vector3(h.y, 0.0, -h.x)
	var fwd := Vector3(h.x, 0.0, h.y)
	var side := _dims.x + EXIT_GAP
	var ends := _dims.z * 0.5 + EXIT_GAP
	for off: Vector3 in [left * side, -left * side, -fwd * ends, fwd * ends]:
		var c := _pos + off
		var g := ctx.collision.walk_height(c)
		if is_nan(g):
			continue
		c.y = g
		if not ctx.collision.is_blocked(c, WS.PLAYER_RADIUS):
			return c
	return Vector3(NAN, NAN, NAN)


# ------------------------------------------------------------------ driving


func _process(delta: float) -> void:
	if ctx == null or ctx.player == null:
		return
	if not active:
		_t -= delta
		if _t <= 0.0:
			_t = PROMPT_TICK
			_target = enter_target()
			if hud != null:
				hud.set_prompt(
					"Get in %s" % str(_target["label"]) if not _target.is_empty() else ""
				)
		return
	var tr := _traffic()
	if tr == null or int(tr.call("driven_id")) != car_id:
		exit(true)
		return
	var dt := minf(delta, 0.1)
	var free := not ctx.is_modal()
	var throttle := maxf(
		Input.get_action_strength("move_forward"), Input.get_action_strength("drive_throttle")
	)
	var brake := maxf(
		Input.get_action_strength("move_back"), Input.get_action_strength("drive_brake")
	)
	var steer := Input.get_axis("move_left", "move_right")
	var hand := Input.get_action_strength("jump")
	if free:
		drive_step(throttle, brake, steer, hand, dt)
		_look(dt)
		ctx.player.set_view_override(camera_xform(), _fov())
	else:
		drive_step(0.0, 1.0, 0.0, 1.0, dt)
	if hud != null:
		hud.set_prompt("Get out" if absf(model.speed()) <= EXIT_SPEED and free else "")
		hud.set_speed(free, model.speed())


## One driving step with the given controls (throttle, brake, handbrake 0..1, steer -1..1).
func drive_step(throttle: float, brake: float, steer: float, hand: float, dt: float) -> void:
	if not active or dt <= 0.0:
		return
	var col := ctx.collision
	var yaw0 := model.yaw
	model.step(throttle, brake, steer, hand, col.surface_at(_pos), dt)
	var to := body.move(model, _pos, yaw0, dt, col, _traffic(), _props())
	var g := col.walk_height(to)
	if not is_nan(g):
		to.y = g if g > _pos.y else move_toward(_pos.y, g, SETTLE * dt)
	_pos = to
	_traffic().call("drive_car", _pos, model.yaw, model.speed(), model.accel)
	_ride()
	_impact_t -= dt
	_report()


## Puts the last step's hardest hit on the bus (props report their own fall), at most once per
## IMPACT_GAP.
func _report() -> void:
	if body.hits.is_empty() or ctx.bus == null or _impact_t > 0.0:
		return
	var best: Array = []
	for h: Array in body.hits:
		if str(h[2]) != "prop" and (best.is_empty() or float(h[1]) > float(best[1])):
			best = h
	if best.is_empty():
		return
	_impact_t = IMPACT_GAP
	var p: Vector2 = best[0]
	ctx.bus.car_impact.emit(Vector3(p.x, _pos.y + _dims.y * 0.5, p.y), float(best[1]), str(best[2]))


## The hero rides along, body turned to the car's heading, placed so that the seated hips are on
## the driver's seat (the avatar's own transform belongs to its lean and step springs, so the
## player's feet move instead: _hero_off from the car's centre, in the player's frame).
func _ride() -> void:
	var p := ctx.player
	_place_hero()
	var yaw := model.yaw + PI
	p.ride(_pos + Basis(Vector3.UP, yaw) * _hero_off, yaw, _cam_yaw + _orbit + PI)


## Measures the sit pose against the seat (the hero is hidden until the car's full model is drawn,
## and for the stand-in figure, which cannot sit).
func _place_hero() -> void:
	var av := ctx.player.avatar
	if av == null:
		return
	if _seat == null:
		_seat = _traffic().call("seat_offset")
	var rig: Variant = av.get("rig")
	var seated: bool = _seat != null and rig != null and bool(av.call("is_animated"))
	# The driver's eye is inside the hero's head, so the body is hidden in driver view.
	av.visible = seated and view != "driver"
	if not seated:
		return
	var s: Vector3 = _seat
	# The player's body faces -Z, the car +Z: the seat in the player's frame is turned half a turn.
	var want := Vector3(-s.x, s.y, -s.z)
	var hw: Vector3 = (rig as RefCounted).call("bone_world", "Hips")
	if not is_nan(hw.x):
		_hero_off = want - ctx.player.to_local(hw)


func _sit(on: bool) -> void:
	var av := ctx.player.avatar if ctx.player != null else null
	var rig: Variant = av.get("rig") if av != null else null
	if rig != null and (rig as RefCounted).has_method("sit"):
		(rig as RefCounted).call("sit", on)


# ------------------------------------------------------------------ camera


func _input(event: InputEvent) -> void:
	if ctx == null or ctx.player == null or ctx.is_modal() or event.is_echo():
		return
	var handled := false
	if event.is_action_pressed("vehicle_enter"):
		# Driving, the key is always taken (a refusal toasts why); on foot only with a car near.
		if active:
			exit()
			handled = true
		else:
			handled = enter()
	elif active and event.is_action_pressed("view_toggle"):
		view = "driver" if view == "chase" else "chase"
		handled = true
	elif (
		active and event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	):
		var rel := (event as InputEventMouseMotion).relative
		var sens := float(ctx.settings.get("mouse_sensitivity", WS.MOUSE_SENSITIVITY))
		_orbit_by(-rel.x * sens, rel.y * sens)
		handled = true
	if handled and is_inside_tree():
		get_viewport().set_input_as_handled()


func _orbit_by(d_yaw: float, d_pitch: float) -> void:
	_orbit = wrapf(_orbit + d_yaw, -PI, PI)
	_orbit_pitch = clampf(_orbit_pitch + d_pitch, PITCH_MIN, PITCH_MAX)
	_orbit_t = ORBIT_HOLD


## Swings the chase camera in behind the car and lets a held look return to centre.
func _look(dt: float) -> void:
	var stick := Input.get_vector("look_left", "look_right", "look_up", "look_down")
	if stick.length() > 0.05:
		_orbit_by(-stick.x * STICK_ORBIT * dt, stick.y * STICK_ORBIT * 0.5 * dt)
	var v := model.speed()
	if v > -1.0 * WS.M:
		var k := CHASE_FOLLOW * (1.0 + absf(v) / MODEL.TOP)
		_cam_yaw = lerp_angle(_cam_yaw, model.yaw, 1.0 - exp(-k * dt))
	_orbit_t -= dt
	if _orbit_t <= 0.0:
		_orbit = move_toward(_orbit, 0.0, ORBIT_RETURN * dt)
		_orbit_pitch = move_toward(_orbit_pitch, 0.0, ORBIT_RETURN * 0.5 * dt)


## The camera now: behind and above the car (pulled in front of walls), or at the driver's eyes.
func camera_xform() -> Transform3D:
	if view == "driver" and _seat != null:
		var car := Transform3D(Basis(Vector3.UP, model.yaw), _pos)
		var s: Vector3 = _seat
		var eye := car * Vector3(s.x * EYE_INBOARD, s.y + EYE_ABOVE_HIP, s.z)
		var a := model.yaw + _orbit
		var look := Vector3(sin(a), -0.06 - _orbit_pitch, cos(a))
		return Transform3D(Basis.looking_at(look, Vector3.UP), eye)
	var y := _cam_yaw + _orbit
	var pitch := clampf(CHASE_PITCH + _orbit_pitch, PITCH_MIN, PITCH_MAX)
	var dir := Vector3(-sin(y) * cos(pitch), sin(pitch), -cos(y) * cos(pitch))
	var target := _pos + Vector3(0.0, LOOK_UP, 0.0)
	var dist := CHASE_DIST
	if ctx.collision != null:
		dist = clampf(
			ctx.collision.sweep_sphere(target, dir, CHASE_DIST, CAM_RADIUS) - CAM_RADIUS,
			CAM_MIN,
			CHASE_DIST
		)
	var eye := target + dir * dist
	var aim := target + Vector3(sin(y), 0.0, cos(y)) * LOOK_AHEAD
	return Transform3D(Basis.looking_at(aim - eye, Vector3.UP), eye)


func _fov() -> float:
	var base := float(ctx.settings.get("fov", WS.FOV))
	return base + FOV_FAST * clampf(absf(model.speed()) / MODEL.TOP, 0.0, 1.0)


# ------------------------------------------------------------------ helpers


func _traffic() -> FpFeature:
	var tr := ctx.feature("traffic") if ctx != null else null
	if tr == null or not tr.has_method("claim_car"):
		return null
	return tr


func _props() -> FpFeature:
	var f := ctx.feature("props") if ctx != null else null
	return f if f != null and f.has_method("knock") else null


func _toast(text: String) -> void:
	if ctx.bus != null:
		ctx.bus.toast.emit(text, "info")
