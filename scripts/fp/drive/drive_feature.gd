extends FpFeature
## Getting into cars and driving them. Near a parked or stopped car, F (Y on a pad) gets in: the
## hero walks round to the driver's door, opens it, climbs in and shuts it (car_entry.gd, the
## car_doors flag; at once without it), and the camera chases the car. Someone at the wheel of a
## car stopped in traffic is dragged out first (the carjack flag): the car waits while the hero
## walks to its door, opens it and pulls them out. W / S or the triggers drive and brake (S
## reverses once stopped), A / D or the left stick steer, Space (A) is the handbrake, the mouse or
## right stick look around, V switches to the driver's view, and F again stops the car and gets
## out through the driver's door (or at once beside it). In the backhoe loader, Y / U raise and
## lower the loader arm and I / O curl and tip its bucket (backhoe.gd, the backhoe_arm flag), and
## a bucket tipped out with O then curled back in with I, the arm low over a construction site,
## digs a growing dirt pile. The car belongs to the traffic feature
## (lane traffic stops for it and it stays where it is left). It is a rigid box (car_body.gd): it
## bounces off walls, slides along them at a glance, spins when hit off-centre, shoves the cars it
## hits and knocks street props over; car_impact on the bus reports the hard hits and car_door the
## door opening and shutting. Alongside a moving car with someone at its wheel, F jumps across
## (the action_hijack flag, hijack.gd): the hero lets go of the wheel, climbs out onto the roof,
## leaps onto the other car and drags its driver out through the window, its own car rolling on
## with nobody at the wheel. After dark (the night_driving flag) the car the hero drives always
## throws its own headlight beam (a bicycle a small dim lamp at its handlebar), and H at the
## wheel sounds the horn (a bicycle's bell) on the bus, which the street hears through its own
## horn source.

const WS := preload("res://scripts/fp/world_scale.gd")
const MODEL := preload("res://scripts/fp/drive/drive_model.gd")
const HUD := preload("res://scripts/fp/drive/drive_hud.gd")
const BODY := preload("res://scripts/fp/drive/car_body.gd")
const ENTRY := preload("res://scripts/fp/drive/car_entry.gd")
const HIJACK := preload("res://scripts/fp/drive/hijack.gd")
const SEAT := preload("res://scripts/fp/drive/seat_pose.gd")
const ARM := preload("res://scripts/fp/drive/backhoe.gd")
const INPUT := preload("res://scripts/fp/drive/drive_input.gd")

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
## The horn's carry into the street (horn_sounded), aliased for the street's listeners; the
## horn and its keys live in drive_input.gd.
const HORN_STREET_R := INPUT.HORN_STREET_R
## Stopped cars this close to the hero block it on foot (as FpPlayer polls them).
const BLOCKER_REACH := 2.0 * WS.M
## The photo shot's car is the nearest one to get into this close to the spawn point, picked
## PHOTO_FRAMES frames after the tour puts the hero there (traffic fills the street round it).
const PHOTO_REACH := 30.0 * WS.M
const PHOTO_FRAMES := 3
const PHOTO_DT := 1.0 / 60.0
## The photo holds the climb in this many seconds into it (one leg in, ducking under the roof).
const PHOTO_CLIMB := 0.8
## An action hijack takes a car at most HIJACK_GAP off the side of the player's car, its middle
## within HIJACK_ALONG of the player's car's, heading the same way within HIJACK_TURN at most
## HIJACK_REL faster or slower, the player's car going forward at least HIJACK_MIN.
const HIJACK_GAP := 2.5 * WS.M
const HIJACK_ALONG := 2.5 * WS.M
const HIJACK_REL := 4.0 * WS.M
const HIJACK_TURN := deg_to_rad(20.0)
const HIJACK_MIN := 4.0 * WS.M

var active: bool = false
var car_id: int = -1
var model := MODEL.new()
var body := BODY.new()
## True while the hero is on a bicycle (no door to open: on and off it at once).
var bike: bool = false
## "chase" or "driver".
var view: String = "chase"
var hud: HUD
## Car half width, height and length (u).
var _dims := Vector3(0.045, 0.075, 0.24)
## Its handling profile (drive_model.gd reset): a slower, heavier body, else a car's.
var _profile := {}
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
## The walk to the door and the climb in, or the climb out (car_entry.gd).
var entry := ENTRY.new()
## Seconds spent braking to a stop before the climb out, or -1.
var _stop_t: float = -1.0
## The hero's input before the photo shot.
var _photo_input: bool = true
## The car being taken from its driver (carjack) until they are dragged out, else -1.
var _jack_id: int = -1
## The leap across to a moving car (action hijack).
var hijack := HIJACK.new()
## The car alongside to jump to, as the prompt last looked (hijack_target).
var _across: Dictionary = {}
## The hero's seated pose against the cabin (seat_pose.gd).
var pose := SEAT.new()
## The backhoe's arm and bucket rig (backhoe.gd, the backhoe_arm flag).
var arm := ARM.new()
## The keys and the horn (drive_input.gd).
var input := INPUT.new(self)


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
	arm.clear()
	if hud != null and is_instance_valid(hud):
		hud.queue_free()
	hud = null


func on_world_rebuilt() -> void:
	exit(true)
	arm.clear()


## Save: the backhoe rigs the hero has posed and the pile it dug, put back on the load.
func to_dict() -> Dictionary:
	return arm.save_dict(_traffic())


func from_dict(d: Dictionary) -> void:
	exit(true)
	arm.from_dict(d.get("backhoe", {}))


func self_test() -> Dictionary:
	var m := MODEL.new()
	m.reset(0.0, 0.24)
	for _k in range(120):
		m.step(1.0, 0.0, 0.0, 0.0, "asphalt", 1.0 / 60.0)
	var kmh := m.speed() / WS.M * 3.6
	return {"ok": kmh > 25.0 and kmh < 80.0, "detail": "2 s of full throttle: %.0f km/h" % kmh}


# ------------------------------------------------------------------ getting in and out


## The car the hero could get into now ({} when none, while driving or climbing in or out, or while
## a parkour move carries the hero).
func enter_target() -> Dictionary:
	var p := ctx.player if ctx != null else null
	var traffic := _traffic()
	if active or _climbing() or p == null or traffic == null or ctx.is_modal():
		return {}
	if p.photo_mode or p.in_conversation() or p.carried:
		return {}
	return traffic.call("enter_target", p.position, ENTER_REACH)


## Gets into the nearest car in reach at once. Returns true when the hero is now driving.
func enter() -> bool:
	if _claim().is_empty():
		return false
	_take_wheel()
	return true


## Gets into the nearest car in reach the long way (car_doors): the hero walks round to its
## driver's door, opens it, climbs in and shuts it, then drives (climb_step runs it); someone at
## the wheel (carjack) is dragged out once the door is open, the car waiting till then. At once
## (enter) without the flag, for a bicycle (there is no door: the hero gets on), or when the door
## cannot open (a model without one, the stand-in figure, no room beside it or no clear way round).
## Returns true when it started.
func board() -> bool:
	if not FeatureFlags.enabled("car_doors"):
		return enter()
	var t := enter_target()
	if bool(t.get("jack", false)):
		return _jack_in(int(t["id"]))
	if not t.is_empty() and bool(_traffic().call("is_bicycle", int(t["id"]))):
		return enter()
	var info := _claim()
	if info.is_empty():
		return false
	if not _climb_in(info):
		_take_wheel()
	return true


## Gets out the long way (car_doors): the car brakes to a stop, the door opens and the hero
## climbs out and shuts it (climb_step runs it). At once (exit) without the flag, and off a
## bicycle (there is no door to open). False when the car is too fast (it says so).
func leave() -> bool:
	if not active or _climbing():
		return false
	if not FeatureFlags.enabled("car_doors") or bike:
		return exit()
	if absf(model.speed()) > EXIT_SPEED:
		_toast("Slow down to get out")
		return false
	_stop_t = 0.0
	if hud != null:
		hud.set_prompt("")
	return true


## Gets out at once beside the driver's door (force: at any speed, wherever there is room or on
## the spot); also ends a climb in or out half way (a hero still outside the car stays where it
## stands). Returns true when the hero is on foot again.
func exit(force: bool = false) -> bool:
	if hijack.running():
		_fall_off()
		return true
	var climbing := not entry.kind.is_empty()
	if not active and not climbing:
		return false
	if not force and not climbing and absf(model.speed()) > EXIT_SPEED:
		_toast("Slow down to get out")
		return false
	var spot := Vector3(NAN, NAN, NAN)
	if not climbing or entry.aboard():
		spot = _exit_spot()
		if is_nan(spot.x):
			if not force:
				_toast("No room to get out here")
				return false
			spot = _pos
	entry.cancel()
	_on_foot(spot, 0.0 if force else EXIT_BLEND)
	return true


## One step of the climb in or out, or of braking to a stop for the climb out; _process runs it,
## tests call it with their own dt.
func climb_step(dt: float) -> void:
	var traffic := _traffic()
	if traffic == null or not _still_there(traffic):
		exit(true)
		return
	if _stop_t >= 0.0:
		_stop_for_exit(dt)
		return
	# Once the climb out is under way (past the door opening, while the hero still sits) the limbs
	# let go of the pedals and the wheel and go with the clip.
	if entry.kind == "out" and entry.phase != "open":
		_limbs_off()
	var done := entry.step(dt)
	# A walk to someone else's car that cannot reach its door takes it at once.
	var pull := done == "pull" or (done == "fail" and _jack_id >= 0)
	if pull and not _pull_out():
		return
	traffic.call("set_door", entry.door, _jack_id)
	if done == "seated" or done == "fail":
		_take_wheel()
		return
	if entry.framing() or done == "out":
		ctx.player.set_view_override(entry.camera(camera_xform()), _fov(), ENTRY.FRAME_BLEND)
	if done == "out":
		_stood_out()


## Takes the car in reach from traffic and sets the drive state up on it (the hero is not at the
## wheel yet): its claim_car info, or {} when there is none.
func _claim() -> Dictionary:
	var t := enter_target()
	if t.is_empty():
		return {}
	var info: Dictionary = _traffic().call("claim_car", int(t["id"]), ctx.player.position)
	if not info.is_empty():
		_adopt(info)
	return info


## Sets the drive state up on car info (claim_car's, or car_info's for a car still to be taken);
## the hero is not at the wheel yet.
func _adopt(info: Dictionary) -> void:
	var p := ctx.player
	car_id = int(info["id"])
	_pos = info["pos"]
	_dims = Vector3(float(info["half_w"]), float(info["height"]), float(info["length"]))
	_profile = {}
	var traffic := _traffic()
	if traffic != null and traffic.has_method("drive_profile"):
		_profile = traffic.call("drive_profile", car_id)
	bike = traffic != null and bool(traffic.call("is_bicycle", car_id))
	model.reset(float(info["yaw"]), _dims.z, _profile)
	body.setup(_dims.x, _dims.z, _dims.y, float(_profile.get("mass", 1.0)))
	_seat = null
	pose.reset()
	arm.reset()
	input.reset()
	_hero_off = Vector3.ZERO
	_cam_yaw = model.yaw
	_orbit = 0.0
	_orbit_pitch = 0.0
	_stop_t = -1.0
	_prev_mode = p.camera_mode
	p.input_enabled = false
	if hud != null:
		hud.set_prompt("")
	if ctx.bus != null:
		ctx.bus.drive_changed.emit(true)


## Starts the walk to the door of the claimed car, or of car id with its driver still at the wheel
## (carjack); false when it cannot (see board).
func _climb_in(info: Dictionary, id: int = -1) -> bool:
	var traffic := _traffic()
	# The car to get into is no obstacle any more; the others near the hero still are.
	_block_others(id)
	var boxes: Array = traffic.call("blockers_near", _pos, _dims.z + ENTRY.ROUTE_REACH, id)
	entry.clearance = _door_clearance(id)
	if not entry.begin_in(ctx, info, traffic.call("door_info", id), boxes, id >= 0):
		return false
	ctx.player.set_camera_mode("third", true)
	return true


## The door of car id (the driven car's when -1) swings only as far as the people round it let
## it (traffic's door_clear_of_people), so it comes to rest against someone in its way.
func _door_clearance(id: int) -> Callable:
	var traffic := _traffic()
	if traffic == null or not traffic.has_method("door_clear_of_people"):
		return Callable()
	return func(from: float, to: float) -> float:
		return float(traffic.call("door_clear_of_people", id, to, from))


## Starts taking car id from its driver: it waits while the hero walks round to its door and opens
## it, then the driver is dragged out (climb_step's "pull") and the hero climbs in. With no way to
## the door the driver is pulled out at once and the hero takes the wheel. False when it is gone.
func _jack_in(id: int) -> bool:
	var traffic := _traffic()
	var info: Dictionary = traffic.call("car_info", id) if traffic != null else {}
	if info.is_empty():
		return false
	_adopt(info)
	_jack_id = id
	if _climb_in(info, id):
		traffic.call("hold_car", id, true)
		return true
	if not _pull_out():
		return false
	_take_wheel()
	return true


## The pull: traffic drags the driver out (knocked down beside the door) and hands the car over.
## False, the hero back on foot, when it is no longer there to take.
func _pull_out() -> bool:
	var traffic := _traffic()
	var info: Dictionary = traffic.call("claim_car", _jack_id, ctx.player.position)
	if info.is_empty():
		entry.cancel()
		_on_foot(Vector3(NAN, NAN, NAN), EXIT_BLEND)
		return false
	_jack_id = -1
	car_id = int(info["id"])
	_pos = info["pos"]
	model.reset(float(info["yaw"]), _dims.z, _profile)
	_block_others()
	return true


## Stopped cars near the hero block it on foot, all but car skip (the one it is getting into; the
## car it drives is never one).
func _block_others(skip: int = -1) -> void:
	var near: Array[AABB] = []
	near.assign(_traffic().call("blockers_near", ctx.player.position, BLOCKER_REACH, skip))
	ctx.collision.dynamic_boxes = near


## True while the car being got into is still there: the one the hero has, or the one it is taking
## from its driver.
func _still_there(traffic: FpFeature) -> bool:
	if _jack_id >= 0:
		return bool(traffic.call("jackable", _jack_id))
	return int(traffic.call("driven_id")) == car_id


## Behind the wheel: the drive camera takes the view and the hero sits in the driver's seat.
func _take_wheel() -> void:
	var p := ctx.player
	active = true
	p.input_enabled = false
	ctx.collision.dynamic_boxes = []
	p.set_view_override(camera_xform(), _fov(), ENTER_BLEND)
	p.set_camera_mode("third", false)
	_ride()
	_sit(true)
	if FeatureFlags.enabled("backhoe_arm") and arm.at_wheel(_traffic(), car_id):
		_toast("Backhoe: Y U raise and lower the arm, I O curl and tip the bucket")


## Brakes to a stop for the climb out; stopped, the door opens (or, with no room for the door or
## for the hero beside it, the hero gets out at once).
func _stop_for_exit(dt: float) -> void:
	drive_step(0.0, 1.0, 0.0, 1.0, dt)
	_look(dt)
	_stop_t += dt
	ctx.player.set_view_override(camera_xform(), _fov())
	if absf(model.speed()) > ENTRY.STOP_V and _stop_t < ENTRY.BRAKE_MAX:
		return
	_stop_t = -1.0
	model.reset(model.yaw, _dims.z, _profile)
	var traffic := _traffic()
	traffic.call("drive_car", _pos, model.yaw, 0.0, 0.0)
	if hud != null:
		hud.set_speed(false, 0.0)
	var boxes: Array = traffic.call("blockers_near", _pos, _dims.z + ENTRY.ROUTE_REACH)
	entry.seat_drop = pose.sink
	entry.clearance = _door_clearance(-1)
	if not entry.begin_out(ctx, _car_info(), traffic.call("door_info", -1), boxes):
		exit()


## Out and the door shut: the hero walks on from where it stands, the view along the car.
func _stood_out() -> void:
	var p := ctx.player
	p.cam_yaw = wrapf(model.yaw + PI, -PI, PI)
	p.cam_pitch = 0.0
	p.pitch = 0.0
	_on_foot(Vector3(NAN, NAN, NAN), EXIT_BLEND)


## Back on foot (moved to spot unless it is NAN, facing along the car): the car goes back to
## traffic, and walking input and the hero's own camera return, easing over blend s.
func _on_foot(spot: Vector3, blend: float) -> void:
	var traffic := _traffic()
	if traffic != null:
		traffic.call("leave_car")
		if _jack_id >= 0:
			# Turned back before the pull: the door shuts and the car drives on.
			traffic.call("set_door", 0.0, _jack_id)
			traffic.call("hold_car", _jack_id, false)
	_jack_id = -1
	active = false
	car_id = -1
	bike = false
	_stop_t = -1.0
	_limbs_off()
	pose.reset()
	arm.reset()
	if hud != null:
		hud.set_prompt("")
		hud.set_speed(false, 0.0)
		hud.set_rig(false)
	var p := ctx.player
	if p != null and is_instance_valid(p):
		_sit(false)
		if p.avatar != null:
			p.avatar.visible = true
		p.input_enabled = true
		if not is_nan(spot.x):
			p.teleport(spot, rad_to_deg(model.yaw + PI), 0.0, true)
		p.set_camera_mode(_prev_mode, blend > 0.0 and not p.view_override)
		p.clear_view_override(blend)
	if ctx.bus != null:
		ctx.bus.drive_changed.emit(false)


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


func _car_info() -> Dictionary:
	return {"pos": _pos, "yaw": model.yaw, "half_w": _dims.x, "length": _dims.z, "height": _dims.y}


## True while climbing in or out, braking to a stop for it, or jumping across (action hijack).
func _climbing() -> bool:
	return not entry.kind.is_empty() or _stop_t >= 0.0 or hijack.running()


# ------------------------------------------------------------------ driving


func _process(delta: float) -> void:
	if ctx == null or ctx.player == null:
		return
	arm.apply_saved(_traffic())
	var dt := minf(delta, 0.1)
	if hijack.running():
		if not ctx.is_modal():
			_hijack_step(dt)
		return
	if _climbing():
		if not ctx.is_modal():
			climb_step(dt)
		return
	if not active:
		_poll_prompt(delta)
		return
	var traffic := _traffic()
	if traffic == null or int(traffic.call("driven_id")) != car_id:
		exit(true)
		return
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
		hud.set_prompt(_drive_prompt(free, delta))
		hud.set_speed(free, model.speed())
		hud.set_rig(free and FeatureFlags.enabled("backhoe_arm") and arm.rigged())


## The get-in prompt, a few times a second while on foot.
func _poll_prompt(delta: float) -> void:
	_t -= delta
	if _t > 0.0:
		return
	_t = PROMPT_TICK
	_target = enter_target()
	if hud != null:
		hud.set_prompt(_prompt_for(_target))


## The prompt for enter_target t: "Get in the car", or with someone at the wheel "Pull the driver
## out"; "" with no car in reach.
static func _prompt_for(t: Dictionary) -> String:
	if t.is_empty():
		return ""
	if bool(t.get("jack", false)):
		return "Pull the driver out"
	return "Get in %s" % str(t["label"])


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
	_ride(dt)
	if FeatureFlags.enabled("backhoe_arm"):
		arm.step(ctx, _traffic(), car_id, _pos, model.heading(), dt)
	_impact_t -= dt
	input.step(dt)
	_report()


## Puts the last step's hardest hit on the bus (props report their own fall), at most once per
## IMPACT_GAP.
func _report() -> void:
	if body.hits.is_empty() or ctx.bus == null or _impact_t > 0.0:
		return
	var best: Array = []
	for h: Array in body.hits:
		# Props and people report themselves (prop_knocked, person_hit).
		var own := str(h[2]) in ["prop", "person"]
		if not own and (best.is_empty() or float(h[1]) > float(best[1])):
			best = h
	if best.is_empty():
		return
	_impact_t = IMPACT_GAP
	var p: Vector2 = best[0]
	ctx.bus.car_impact.emit(Vector3(p.x, _pos.y + _dims.y * 0.5, p.y), float(best[1]), str(best[2]))


## The hero rides along, body turned to the car's heading, placed so that the seated hips are on
## the driver's seat (the avatar's own transform belongs to its lean and step springs, so the
## player's feet move instead: _hero_off from the car's centre, in the player's frame).
func _ride(dt: float = 0.0) -> void:
	var p := ctx.player
	_place_hero(dt)
	var yaw := model.yaw + PI
	p.ride(_pos + Basis(Vector3.UP, yaw) * _hero_off, yaw, _cam_yaw + _orbit + PI)


## Measures the sit pose against the seat (the hero is hidden until the car's full model is drawn,
## and for the stand-in figure, which cannot sit). The hips go on the seat marker sunk by the
## pose's sink (seat_pose.gd, so the head clears the roof) and the feet and hands reach the car's
## own pedal and wheel markers.
func _place_hero(dt: float = 0.0) -> void:
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
	var want := Vector3(-s.x, s.y - pose.sink, -s.z)
	var hw: Vector3 = (rig as RefCounted).call("bone_world", "Hips")
	if not is_nan(hw.x):
		_hero_off = want - ctx.player.to_local(hw)
	pose.step(rig as RefCounted, _traffic(), car_id, _pos, model.yaw, s, dt)


## Lets the hero's limbs go back to their clips from the last seat pose (seat_pose.gd).
func _limbs_off() -> void:
	var av := ctx.player.avatar if ctx != null and ctx.player != null else null
	pose.off(av.get("rig") if av != null else null)


func _sit(on: bool) -> void:
	var av := ctx.player.avatar if ctx.player != null else null
	var rig: Variant = av.get("rig") if av != null else null
	if rig != null and (rig as RefCounted).has_method("sit"):
		(rig as RefCounted).call("sit", on, true, true)


# ------------------------------------------------------------------ action hijack


## The car alongside that F would jump across to now (traffic's hijack_target: {"id", "side",
## "gap", "along"}); {} when none, the flag off, too slow, or not at the wheel.
func hijack_target() -> Dictionary:
	var traffic := _traffic()
	if not active or _climbing() or traffic == null or not FeatureFlags.enabled("action_hijack"):
		return {}
	if model.speed() < HIJACK_MIN:
		return {}
	return traffic.call("hijack_target", HIJACK_GAP, HIJACK_ALONG, HIJACK_REL, HIJACK_TURN)


## F alongside a car with someone at its wheel (action hijack): the hero lets go of the wheel (the
## car rolls on with nobody at it, slowing), climbs out onto the roof, leaps across onto the other
## car and drags its driver out through the window (_hijack_step runs it). False when there is no
## car to jump to.
func jump_across() -> bool:
	var t := hijack_target()
	var traffic := _traffic()
	var to: Dictionary = traffic.call("car_info", int(t["id"])) if not t.is_empty() else {}
	if to.is_empty():
		return false
	var door: Dictionary = traffic.call("door_info", int(t["id"]))
	var seat: Vector3 = door.get("seat", Vector3.ZERO)
	var p := ctx.player
	var here := Transform3D(Basis(Vector3.UP, model.yaw), _pos)
	hijack.begin(car_id, int(t["id"]), float(t["side"]), here.affine_inverse() * p.position, seat.z)
	traffic.call("release_car", model.vel)
	traffic.call("set_hero_aboard", true)
	active = false
	car_id = -1
	_across = {}
	_sit(false)
	_limbs_off()
	if p.avatar != null:
		p.avatar.visible = true
	if hud != null:
		hud.set_prompt("")
		hud.set_speed(false, 0.0)
		hud.set_rig(false)
	return true


## One step of the hijack, the hero carried on the cars' frames and the camera chasing it; tests
## call it with their own dt. Either car gone, or the one to take no longer there to take at the
## window, and the hero drops to the road.
func _hijack_step(dt: float) -> void:
	var traffic := _traffic()
	var a: Dictionary = traffic.call("car_info", hijack.from_id) if traffic != null else {}
	var b: Dictionary = traffic.call("car_info", hijack.to_id) if traffic != null else {}
	if b.is_empty() or (a.is_empty() and hijack.phase != "jack"):
		_fall_off()
		return
	var was := ctx.player.position
	var said := hijack.step(dt)
	if said == "pull":
		_hijack_in(traffic, was)
		return
	var feet := hijack.feet(a, b)
	if said == "leap" and ctx.bus != null:
		ctx.bus.hero_action.emit("hijack", was)
	var ride: Dictionary = a if hijack.riding() == hijack.from_id else b
	model.yaw = float(ride["yaw"])
	# The body faces along the car it rides, moving with it (no walk or run clip from its speed).
	var rise := (feet.y - was.y) / dt if hijack.airborne() else 0.0
	ctx.player.carry(feet, model.yaw + PI, Vector3(0.0, rise, 0.0), not hijack.airborne())
	_pos = feet
	_look(dt)
	ctx.player.set_view_override(camera_xform(true), _fov())


## At the window: traffic drags the driver out and hands the car over at its speed, the hero at
## its wheel.
func _hijack_in(traffic: FpFeature, src: Vector3) -> void:
	traffic.call("set_hero_aboard", false)
	var info: Dictionary = traffic.call("claim_car", hijack.to_id, src, true)
	if info.is_empty():
		_fall_off()
		return
	var mode := _prev_mode
	ctx.player.release(true)
	_adopt(info)
	_prev_mode = mode
	model.vel = model.heading() * float(info.get("v", 0.0))
	_take_wheel()


## The hijack ends half way: the hero drops from where it is to the road, on foot.
func _fall_off() -> void:
	hijack.cancel()
	_limbs_off()
	var traffic := _traffic()
	if traffic != null:
		traffic.call("set_hero_aboard", false)
	var p := ctx.player
	if p != null and is_instance_valid(p) and p.carried:
		p.release(false)
	_on_foot(Vector3(NAN, NAN, NAN), EXIT_BLEND)


## The driving prompt, the car alongside to jump to looked for a few times a second: "Jump across"
## to one, "Get out" slow enough to stop, else none.
func _drive_prompt(free: bool, delta: float) -> String:
	_t -= delta
	if _t <= 0.0:
		_t = PROMPT_TICK
		_across = hijack_target()
	if not free:
		return ""
	if not _across.is_empty():
		return "Jump across"
	return "Get out" if absf(model.speed()) <= EXIT_SPEED else ""


# ------------------------------------------------------------------ camera


func _input(event: InputEvent) -> void:
	input.input(event)


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


## The camera now: behind and above the car (pulled in front of walls, lifted off the ground when
## it looks up from low down), or at the driver's eyes (not when chase is true).
func camera_xform(chase: bool = false) -> Transform3D:
	if view == "driver" and _seat != null and not chase:
		var car := Transform3D(Basis(Vector3.UP, model.yaw), _pos)
		var s: Vector3 = _seat
		var eye := car * Vector3(s.x * EYE_INBOARD, s.y + EYE_ABOVE_HIP - pose.sink, s.z)
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
	eye.y = maxf(eye.y, _ground_below(eye) + CAM_RADIUS)
	var aim := target + Vector3(sin(y), 0.0, cos(y)) * LOOK_AHEAD
	return Transform3D(Basis.looking_at(aim - eye, Vector3.UP), eye)


## The ground under p (the water surface off the land and beside a bridge deck).
func _ground_below(p: Vector3) -> float:
	var g := ctx.collision.ground_height(p) if ctx.collision != null else WS.GROUND_Y
	return WS.WATER_Y if is_nan(g) else g


func _fov() -> float:
	var base := float(ctx.settings.get("fov", WS.FOV))
	return base + FOV_FAST * clampf(absf(model.speed()) / MODEL.TOP, 0.0, 1.0)


# ------------------------------------------------------------------ photo tour


## The photo shot: the hero half way into the car nearest the spawn point, one leg in and ducking
## under the roof with the door wide open, seen from the door camera (car_doors).
func photo_shots() -> Array:
	if _traffic() == null or ctx.mode == null or not FeatureFlags.enabled("car_doors"):
		return []
	var sp: Dictionary = ctx.mode.spawn_point()
	var shot := {"name": "car_door", "pos": sp["pos"], "yaw": float(sp["yaw"]), "pitch": 0.0}
	shot.merge({"hour": 10.5, "prepare": "photo_prepare", "restore": "photo_restore"})
	return [shot]


## Photo tour: the tour puts the hero at the spawn point after this, so the climb is staged once
## traffic has filled the street round it.
func photo_prepare() -> void:
	_photo_input = ctx.player.input_enabled
	_photo_stage.call_deferred()


func photo_restore() -> void:
	exit(true)
	ctx.player.input_enabled = _photo_input


## Claims the car nearest the hero that nobody sits in (no carjack for a photo), walks it in from
## beside the driver's door and holds the climb in half way.
func _photo_stage() -> void:
	for _k in range(PHOTO_FRAMES):
		await get_tree().process_frame
	var p := ctx.player
	var traffic := _traffic()
	if traffic == null or active or _climbing():
		return
	var near: Dictionary = traffic.call("enter_target", p.position, PHOTO_REACH, false)
	if near.is_empty():
		return
	p.teleport(near["pos"], rad_to_deg(p.yaw))
	var info := _claim()
	if info.is_empty():
		return
	var car := Transform3D(Basis(Vector3.UP, model.yaw), _pos)
	p.teleport(car * Vector3(_dims.x + 0.9 * WS.M, 0.0, -0.4 * _dims.z), rad_to_deg(model.yaw))
	if not _climb_in(info):
		exit(true)
		return
	entry.hold = "climb"
	entry.hold_at = PHOTO_CLIMB
	for _k in range(roundi(20.0 / PHOTO_DT)):
		climb_step(PHOTO_DT)
		p.update_view(PHOTO_DT)
		if (entry.phase == "climb" and entry.t >= PHOTO_CLIMB) or entry.kind.is_empty():
			break


# ------------------------------------------------------------------ helpers


func _traffic() -> FpFeature:
	var traffic := ctx.feature("traffic") if ctx != null else null
	if traffic == null or not traffic.has_method("claim_car"):
		return null
	return traffic


func _props() -> FpFeature:
	var f := ctx.feature("props") if ctx != null else null
	return f if f != null and f.has_method("knock") else null


func _toast(text: String) -> void:
	if ctx.bus != null:
		ctx.bus.toast.emit(text, "info")
