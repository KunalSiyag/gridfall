extends RefCounted
## Getting into the player's car and out of it on foot, for drive_feature.gd (car_doors flag).
## In: the hero walks round the car to the driver's door (jogging while it is far), reaches for
## the handle (door_try), pulls the door open and swings it wide, steps into the opening, turns
## its back to the seat and sits down onto the sill (sit_down; its root travel is walked back so
## the feet stay planted), swings round into the seat and the door shuts. Out: the door opens,
## the hero swings round onto the sill, stands up (stand_up, walked forward), steps clear of the
## door and it shuts. From the reach on, a camera beside the door watches and blends to and from
## the drive camera. The points come from the traffic feature's door_info, in the car's frame
## (+Z forward, +X the driver's side); the car stands still throughout. The hero's rig is reached
## by duck typing (the player folder is another slice): travel, root_travel, sit, play_gesture,
## stop_gesture, state and bone_world.

const WS := preload("res://scripts/fp/world_scale.gd")

## The reach: the hero stands STAND_OUT out from the body side with the handle REACH_FWD ahead
## and REACH_SIDE to its right (door_try's hand at the grip), and clears the swinging door's edge
## by BODY_R.
const STAND_OUT := 0.28 * WS.M
const REACH_FWD := 0.44 * WS.M
const REACH_SIDE := 0.26 * WS.M
const BODY_R := 0.22 * WS.M
## The walk keeps ROUTE_GAP off the car's body and comes in along its side from LEAD_IN behind
## the stand spot when it comes from behind; a corner counts as passed WP_REACH from it and a
## goal as reached ARRIVE from it. It slows down within SLOW_R and jogs while more than JOG_FROM
## is left. A way is checked for room every ROUTE_STEP.
const ROUTE_GAP := 0.45 * WS.M
const LEAD_IN := 0.45 * WS.M
const WP_REACH := 0.3 * WS.M
const ARRIVE := 0.08 * WS.M
const SLOW_R := 0.6 * WS.M
const JOG_FROM := 3.0 * WS.M
const ROUTE_STEP := 0.25 * WS.M
## How far round the car other cars can block the walk (drive_feature asks traffic for them).
const ROUTE_REACH := 3.0 * WS.M
## The walk gives up after WALK_MAX s, or STUCK_T s without getting STUCK_GAIN closer; the step
## into the opening (at STEP_PACE of a walk) after STEP_MAX s.
const WALK_MAX := 8.0
const STUCK_T := 1.0
const STUCK_GAIN := 0.05 * WS.M
const STEP_PACE := 0.55
const STEP_MAX := 1.5
## Lining up on a spot: turning at TURN_RATE (rad/s), sliding at ALIGN_SPEED, for at least
## ALIGN_MIN s.
const TURN_RATE := 5.0
const ALIGN_SPEED := 0.6 * WS.M
const ALIGN_MIN := 0.2
## door_try: the hand is on the handle REACH_AT s in and the pull ends at PULL_END with the door
## PULL_OPEN open; it then swings wide over DOOR_WIDE s.
const REACH_AT := 0.75
const PULL_END := 1.2
const PULL_OPEN := 0.3
const DOOR_WIDE := 0.45
## Sat down, the hips are SILL_IN inside the body side. Sitting takes at most SIT_MAX s, the swing
## into or out of the seat SWING_T s and the door's shutting CLOSE_T s.
const SILL_IN := 0.06 * WS.M
const SIT_MAX := 1.3
const SWING_T := 0.7
const CLOSE_T := 0.35
## Out: the door opens over OPEN_T s, standing up takes at most STAND_MAX s, then the hero steps
## AWAY out and AWAY_BACK toward the rear (for at most AWAY_MAX s).
const OPEN_T := 0.45
const STAND_MAX := 1.7
const AWAY := 0.55 * WS.M
const AWAY_BACK := 0.25 * WS.M
const AWAY_MAX := 1.2
## Nothing fixed may stand within DOOR_R of the wide-open door's middle and edge.
const DOOR_R := 0.08 * WS.M
## The door camera looks along CAM_DIR (car frame: from behind the door, mirrored ahead of it when
## that has more room) at a point just outside the door from CAM_DIST (CAM_MIN at least, after the
## pull-in in front of walls). The view eases onto it over FRAME_BLEND s and between it and the
## drive camera over CAM_BLEND s.
const CAM_DIR := Vector3(0.72, 0.3, -0.62)
const CAM_DIST := 3.2 * WS.M
const CAM_MIN := 1.6 * WS.M
const CAM_RADIUS := 0.25 * WS.M
const FRAME_BLEND := 0.6
const CAM_BLEND := 1.0
## Getting out waits for the car to stop: below STOP_V (u/s), or after BRAKE_MAX s of braking.
const STOP_V := 0.15 * WS.M
const BRAKE_MAX := 2.5

## "" (idle), "in" or "out".
var kind: String = ""
## In: "walk", "align", "open", "step", "turn", "sit", "swing", "close". Out: "open", "swing",
## "stand", "away", "close".
var phase: String = ""
## Seconds into the phase.
var t: float = 0.0
## The driver's door: 0 shut .. 1 open.
var door: float = 0.0
## A phase to wait at (the photo tour holds the climb in at "swing"); "" for none.
var hold: String = ""
var _ctx: FpContext
var _car := Transform3D.IDENTITY
var _pts: Dictionary = {}
## Other cars' boxes round the car (world AABBs) that the walk must not run into.
var _boxes: Array = []
var _side: float = 0.0
var _half_len: float = 0.0
var _height: float = 0.0
## The stand spot for the reach and the spot the feet sit down from (or stand up to), car frame.
var _stand := Vector3.ZERO
var _sill := Vector3.ZERO
var _route := PackedVector3Array()
var _wp: int = 0
var _yaw_reach: float = 0.0
var _yaw_out: float = 0.0
var _yaw_seat: float = 0.0
var _from := Vector3.ZERO
var _from_yaw: float = 0.0
var _to := Vector3.ZERO
var _to_yaw: float = 0.0
var _hips := Vector3.ZERO
var _len: float = 0.0
var _dt: float = 0.0
var _fresh: bool = false
var _best: float = INF
var _stuck: float = 0.0
var _walked: float = 0.0
## The door's ramp (from, to, elapsed, length) and its curve: "smooth", "out" or "in".
var _ramp_v := Vector4.ZERO
var _curve: String = "smooth"
var _cam := Transform3D.IDENTITY
## The drive camera's share of the view (0 the door camera .. 1) and where it is heading.
var _cam_w: float = 0.0
var _cam_goal: float = 0.0


## Starts getting into the claimed car `car` ({"pos", "yaw", "half_w", "length", "height"})
## through its driver's door pts (door_info); boxes are the other cars round it. False when the
## hero cannot sit, the door or the ground beside it is blocked, or no way round the car is clear.
func begin_in(ctx: FpContext, car: Dictionary, pts: Dictionary, boxes: Array = []) -> bool:
	_boxes = boxes
	if not _setup(ctx, car, pts, "sit_down") or _blocked(_car * _stand):
		return false
	_route = _plan(_flat(_car.affine_inverse() * ctx.player.position))
	if _route.is_empty():
		return false
	_start_walk()
	_cam_w = 0.0
	_cam_goal = 0.0
	door = 0.0
	_ramp_v = Vector4.ZERO
	kind = "in"
	_go("walk")
	ctx.player.avatar.visible = true
	return true


## Starts getting out of the stopped car (same arguments). False when there is no room for the
## door or for the hero beside it.
func begin_out(ctx: FpContext, car: Dictionary, pts: Dictionary, boxes: Array = []) -> bool:
	_boxes = boxes
	if not _setup(ctx, car, pts, "stand_up") or _blocked(_away()):
		return false
	_cam_w = 1.0
	_cam_goal = 0.0
	door = 0.0
	kind = "out"
	_ramp(1.0, OPEN_T, "out")
	_sound(true)
	_go("open")
	ctx.player.avatar.visible = true
	return true


## Advances by dt s. Returns "" while under way, then "seated" (in), "out" (out) or "fail" (the
## walk could not reach the door; the hero is still on foot).
func step(dt: float) -> String:
	if kind.is_empty() or dt <= 0.0 or (not hold.is_empty() and phase == hold):
		return ""
	_dt = dt
	t += dt
	_step_door(dt)
	_cam_w = move_toward(_cam_w, _cam_goal, dt / CAM_BLEND)
	var was := phase
	var done := _step_in() if kind == "in" else _step_out()
	if phase == was:
		_fresh = false
	if not done.is_empty():
		kind = ""
		phase = ""
	return done


## Stops where it is: the door is shut and a gesture fades out.
func cancel() -> void:
	if kind.is_empty():
		return
	if kind == "in" and phase == "open":
		_rig_call("stop_gesture", [])
	door = 0.0
	_ramp_v = Vector4.ZERO
	kind = ""
	phase = ""
	hold = ""


## True once the door camera has the view: from the reach on the way in, at once on the way out
## (the walk to the door keeps the hero's own camera).
func framing() -> bool:
	return kind == "out" or (kind == "in" and phase != "walk")


## True while the hero is in the seat or half way through the door, where stopping leaves it
## inside the car (in: from the turn into the opening on; out: until it stands).
func aboard() -> bool:
	if kind == "in":
		return phase in ["turn", "sit", "swing", "close"]
	return kind == "out" and phase in ["open", "swing", "stand"]


## The camera now: the door camera, blended toward drive (the drive camera).
func camera(drive: Transform3D) -> Transform3D:
	return _cam.interpolate_with(drive, smoothstep(0.0, 1.0, _cam_w))


## The world points the walk to the door passes through (tests).
func route() -> PackedVector3Array:
	return _route


# ------------------------------------------------------------------ the plan


## Works out the spots and headings in the car's frame; clip sits down or stands up (its root
## travel sets how far out from the sill the feet are). False when the hero has no rig that sits,
## or the door or the spot beside it is blocked.
func _setup(ctx: FpContext, car: Dictionary, pts: Dictionary, clip: String) -> bool:
	var rig := _rig_of(ctx)
	if rig == null or pts.is_empty():
		return false
	_ctx = ctx
	_pts = pts
	var yaw := float(car["yaw"])
	_car = Transform3D(Basis(Vector3.UP, yaw), car["pos"])
	_half_len = float(car["length"]) * 0.5
	_height = float(car["height"])
	var handle: Vector3 = pts["handle"]
	_side = maxf(float(car["half_w"]), handle.x)
	_stand = _stand_spot(handle, pts["hinge"])
	var out := float(rig.call("root_travel", clip))
	_sill = Vector3(_side - SILL_IN + out, 0.0, (pts["seat"] as Vector3).z)
	_yaw_seat = wrapf(yaw + PI, -PI, PI)
	_yaw_out = _yaw_of(_car.basis.x)
	var grip := atan2(REACH_SIDE, REACH_FWD)
	_yaw_reach = wrapf(_yaw_of(_car * handle - _car * _stand) + grip, -PI, PI)
	_cam = _door_camera()
	return not _blocked(_car * _sill) and not _door_blocked()


## Where the hero stands for the reach: STAND_OUT out from the side, back along it until the
## handle is at door_try's grip and the swinging door clears the body.
func _stand_spot(handle: Vector3, hinge: Vector3) -> Vector3:
	var x := _side + STAND_OUT
	var reach := Vector2(REACH_SIDE, REACH_FWD).length()
	var z := handle.z - sqrt(maxf(reach * reach - pow(x - handle.x, 2.0), 0.0))
	var swing := _door_len() + BODY_R
	var hx := x - hinge.x
	if hx < swing:
		z = minf(z, hinge.z - sqrt(swing * swing - hx * hx))
	return Vector3(x, 0.0, z)


## The walk from `from` (car frame xz) to the stand spot: out of the car's footprint grown by
## ROUTE_GAP, round its front or its rear (the shorter way that is clear) and along the driver's
## side, in from LEAD_IN behind the spot when it comes from behind. World points; empty when no
## way is clear.
func _plan(from: Vector2) -> PackedVector3Array:
	var s := Vector2(_stand.x, _stand.z)
	var ex := _side + ROUTE_GAP
	var ez := _half_len + ROUTE_GAP
	var ways: Array = []
	if from.x > _side and from.distance_to(s) <= LEAD_IN * 1.5:
		ways.append([from, s])
	else:
		var p := _out_of(from, ex, ez)
		for corners: Array in _corners(p, ex, ez):
			var w: Array = [from]
			if p != from:
				w.append(p)
			w.append_array(corners)
			if (w.back() as Vector2).y < s.y - LEAD_IN * 0.5:
				w.append(Vector2(ex, s.y - LEAD_IN))
			w.append(s)
			ways.append(w)
		ways.sort_custom(func(a: Array, b: Array) -> bool: return _poly_len(a) < _poly_len(b))
	for w: Array in ways:
		if _clear(w):
			var out := PackedVector3Array()
			for k in range(1, w.size()):
				var q: Vector2 = w[k]
				out.append(_ground(_car * Vector3(q.x, 0.0, q.y)))
			return out
	return PackedVector3Array()


## The ways round the grown footprint from p (outside it) to the driver's side, as lists of the
## corners to pass: none on the driver's side, else round the front or round the rear.
static func _corners(p: Vector2, ex: float, ez: float) -> Array:
	var fl := Vector2(ex, ez)
	var rl := Vector2(ex, -ez)
	var fr := Vector2(-ex, ez)
	var rr := Vector2(-ex, -ez)
	if p.x >= ex - 1e-6:
		return [[]]
	if p.y >= ez - 1e-6:
		return [[fl], [fr, rr, rl]]
	if p.y <= -ez + 1e-6:
		return [[rl], [rr, fr, fl]]
	return [[fr, fl], [rr, rl]]


## True when the hero has room all along way w (car frame xz; its first point is where it stands).
func _clear(w: Array) -> bool:
	for k in range(w.size() - 1):
		var a: Vector2 = w[k]
		var b: Vector2 = w[k + 1]
		var n := maxi(1, ceili(a.distance_to(b) / ROUTE_STEP))
		for i in range(1 if k == 0 else 0, n + 1):
			var q := a.lerp(b, float(i) / n)
			if q.distance_to(w[0]) > WP_REACH and _blocked(_car * Vector3(q.x, 0.0, q.y)):
				return false
	return true


static func _poly_len(w: Array) -> float:
	var d := 0.0
	for k in range(w.size() - 1):
		d += (w[k] as Vector2).distance_to(w[k + 1])
	return d


## p pushed out of the box of half extents (ex, ez) across its nearest edge.
static func _out_of(p: Vector2, ex: float, ez: float) -> Vector2:
	var dx := ex - absf(p.x)
	var dz := ez - absf(p.y)
	if dx <= 0.0 or dz <= 0.0:
		return p
	if dx < dz:
		return Vector2(ex if p.x >= 0.0 else -ex, p.y)
	return Vector2(p.x, ez if p.y >= 0.0 else -ez)


## A camera beside the door looking at a point just outside it: from behind it, or from ahead of
## it when that has more room; pulled in front of walls.
func _door_camera() -> Transform3D:
	var hinge: Vector3 = _pts["hinge"]
	var rear: Vector3 = _pts["rear"]
	var mid := (hinge.z + rear.z) * 0.5 - 0.2 * WS.M
	var focus := _car * Vector3(_side + 0.35 * WS.M, _height * 0.6, mid)
	var best := Transform3D.IDENTITY
	var bd := -INF
	for s: float in [1.0, -1.0]:
		var dir := (_car.basis * Vector3(CAM_DIR.x, CAM_DIR.y, CAM_DIR.z * s)).normalized()
		var dist := CAM_DIST
		if _ctx.collision != null:
			var hit := _ctx.collision.sweep_sphere(focus, dir, CAM_DIST, CAM_RADIUS)
			dist = minf(CAM_DIST, hit - CAM_RADIUS)
		if dist > bd + 0.05 * WS.M:
			bd = dist
			var eye := focus + dir * maxf(dist, 0.3 * WS.M)
			best = Transform3D(Basis.looking_at(focus - eye, Vector3.UP), eye)
		if bd >= CAM_MIN:
			break
	return best


# ------------------------------------------------------------------ getting in


func _step_in() -> String:
	match phase:
		"walk", "step":
			return _walk()
		"align", "turn":
			_align()
		"open":
			_open_in()
		"sit":
			_sit_down()
		"swing":
			_swing_in()
		"close":
			_place_hips(_seat_world(), _yaw_seat)
			return _shut("seated")
	return ""


func _start_walk() -> void:
	_wp = 0
	_best = INF
	_stuck = 0.0
	_walked = 0.0


## Follows the route on foot (FpPlayer.simulate, so the walk animates and collides): to the stand
## spot ("walk"; "fail" when it stops getting closer), or into the door's opening ("step"; lined
## up from wherever it stops).
func _walk() -> String:
	var p := _ctx.player
	var stepping := phase == "step"
	_walked += _dt
	while _wp < _route.size() - 1 and _flat(_route[_wp] - p.position).length() < WP_REACH:
		_wp += 1
	var d := _flat(_route[_wp] - p.position)
	var last := _wp == _route.size() - 1
	if last and (d.length() < ARRIVE or (d.length() < WP_REACH and _passed(p.position))):
		_line_up()
		return ""
	var left := d.length() + _route_left()
	if left < _best - STUCK_GAIN:
		_best = left
		_stuck = 0.0
	else:
		_stuck += _dt
	if _stuck > STUCK_T or _walked > (STEP_MAX if stepping else WALK_MAX):
		if not stepping:
			return "fail"
		_line_up()
		return ""
	var k := clampf(d.length() / SLOW_R, 0.3, 1.0) if last else 1.0
	if stepping:
		k = minf(k, STEP_PACE)
	p.simulate(_wish(d.normalized() * k, p.cam_yaw), left > JOG_FROM and not stepping, _dt)
	return ""


## The last few centimetres onto the walk's goal and the turn: to the handle after the walk, the
## back to the seat after the step.
func _line_up() -> void:
	var p := _ctx.player
	_from = p.position
	_from_yaw = p.yaw
	_to = _route[_route.size() - 1]
	_to_yaw = _yaw_reach if phase == "walk" else _yaw_out
	var turn := absf(wrapf(_to_yaw - p.yaw, -PI, PI)) / TURN_RATE
	_len = maxf(ALIGN_MIN, maxf(turn, _flat(_to - _from).length() / ALIGN_SPEED))
	p.simulate(Vector2.ZERO, false, _dt)
	_go("align" if phase == "walk" else "turn")


func _align() -> void:
	var k := smoothstep(0.0, 1.0, t / _len)
	_ride(_ground(_from.lerp(_to, k)), lerp_angle(_from_yaw, _to_yaw, k))
	if t >= _len:
		_go("open" if phase == "align" else "sit")


## door_try: the hand meets the handle, the pull opens the door a little, then it swings wide and
## the hero steps into the opening.
func _open_in() -> void:
	if _fresh:
		_rig_call("play_gesture", ["door_try"])
	if t - _dt < REACH_AT and t >= REACH_AT:
		_ramp(PULL_OPEN, PULL_END - REACH_AT, "smooth")
		_sound(true)
	if t >= PULL_END:
		_rig_call("stop_gesture", [])
		_ramp(1.0, DOOR_WIDE, "out")
		_route = PackedVector3Array([_ground(_car * _sill)])
		_start_walk()
		_go("step")


## sit_down onto the sill: the clip's root travel walks the feet back toward the car.
func _sit_down() -> void:
	var rig := _rig()
	if _fresh:
		rig.call("sit", true)
		_from = _ctx.player.position
		_len = t
	var k := float(rig.call("travel", "sit_down", t - _len))
	var back := float(rig.call("root_travel", "sit_down"))
	_ride(_ground(_from - _car.basis.x * back * k), _yaw_out)
	if (k >= 0.995 and t - _len > 0.3) or t >= SIT_MAX:
		_hips = rig.call("bone_world", "Hips")
		_cam_goal = 1.0
		_go("swing")


## From the sill round into the seat, facing forward.
func _swing_in() -> void:
	var k := smoothstep(0.0, 1.0, t / SWING_T)
	_place_hips(_hips.lerp(_seat_world(), k), lerp_angle(_yaw_out, _yaw_seat, k))
	if t >= SWING_T:
		_ramp(0.0, CLOSE_T, "in")
		_go("close")


# ------------------------------------------------------------------ getting out


func _step_out() -> String:
	match phase:
		"open":
			_open_out()
		"swing":
			_swing_out()
		"stand":
			_stand_up()
		"away":
			_walk_away()
		"close":
			_ctx.player.simulate(Vector2.ZERO, false, _dt)
			return _shut("out")
	return ""


## Seated while the door opens; then the swing out onto the sill, the feet on the ground below it.
func _open_out() -> void:
	_place_hips(_seat_world(), _yaw_seat)
	if t < OPEN_T:
		return
	var p := _ctx.player
	var rig := _rig()
	var hw: Vector3 = rig.call("bone_world", "Hips") if rig != null else p.position
	_hips = _seat_world()
	_to = _car * Vector3(_side - SILL_IN, 0.0, _sill.z)
	_to.y = _ground(_car * _sill).y + (hw.y - p.position.y)
	_go("swing")


func _swing_out() -> void:
	var k := smoothstep(0.0, 1.0, t / SWING_T)
	_place_hips(_hips.lerp(_to, k), lerp_angle(_yaw_seat, _yaw_out, k))
	if t >= SWING_T:
		_from = _ctx.player.position
		_go("stand")


## stand_up off the sill: the clip's root travel walks the feet out from the car.
func _stand_up() -> void:
	var rig := _rig()
	if _fresh:
		rig.call("sit", false)
		_len = t
	var k := float(rig.call("travel", "stand_up", t - _len))
	var fwd := float(rig.call("root_travel", "stand_up"))
	_ride(_ground(_from + _car.basis.x * fwd * k), _yaw_out)
	var standing := t - _len > 0.5 and str(rig.call("state")) == "loco"
	if standing or t >= STAND_MAX:
		_go("away")


## A step clear of the door's swing, then it shuts.
func _walk_away() -> void:
	var p := _ctx.player
	var d := _flat(_away() - p.position)
	var hinge := _car * (_pts["hinge"] as Vector3)
	var clear := _flat(p.position - hinge).length() > _door_len() + BODY_R
	if d.length() < ARRIVE or (clear and t > 0.4) or t >= AWAY_MAX:
		_ramp(0.0, CLOSE_T, "in")
		_go("close")
		return
	var k := clampf(d.length() / SLOW_R, 0.4, 1.0)
	p.simulate(_wish(d.normalized() * k, p.cam_yaw), false, _dt)


## Where the hero ends up: out from the stand-up spot and a little toward the rear (world).
func _away() -> Vector3:
	return _ground(_car * Vector3(_sill.x + AWAY, 0.0, _sill.z - AWAY_BACK))


# ------------------------------------------------------------------ helpers


func _go(p: String) -> void:
	phase = p
	t = 0.0
	_fresh = true


## The door shutting (and on the way in the camera settling behind the car); done once it has,
## with the slam.
func _shut(done: String) -> String:
	if _ramp_v.z < _ramp_v.w or _cam_w < _cam_goal:
		return ""
	_sound(false)
	return done


func _ramp(to: float, secs: float, curve: String) -> void:
	_ramp_v = Vector4(door, to, 0.0, maxf(secs, 1e-3))
	_curve = curve


func _step_door(dt: float) -> void:
	if _ramp_v.w <= 0.0:
		return
	_ramp_v.z = minf(_ramp_v.z + dt, _ramp_v.w)
	var x := _ramp_v.z / _ramp_v.w
	if _curve == "in":
		x = x * x
	elif _curve == "out":
		x = 1.0 - (1.0 - x) * (1.0 - x)
	else:
		x = smoothstep(0.0, 1.0, x)
	door = lerpf(_ramp_v.x, _ramp_v.y, x)


func _sound(open: bool) -> void:
	if _ctx.bus != null:
		_ctx.bus.car_door.emit(_car * (_pts["handle"] as Vector3), open)


## Puts the hero so that its hips are at world point `at`, the body turned to yaw.
func _place_hips(at: Vector3, yaw: float) -> void:
	var p := _ctx.player
	var rig := _rig()
	var hw: Vector3 = rig.call("bone_world", "Hips") if rig != null else Vector3(NAN, NAN, NAN)
	if is_nan(hw.x):
		return
	p.ride(at - Basis(Vector3.UP, yaw) * p.to_local(hw), yaw, yaw)


func _ride(pos: Vector3, yaw: float) -> void:
	_ctx.player.ride(pos, yaw, yaw)


func _seat_world() -> Vector3:
	return _car * (_pts["seat"] as Vector3)


func _door_len() -> float:
	return _flat((_pts["rear"] as Vector3) - (_pts["hinge"] as Vector3)).length()


## The route's length beyond the current waypoint.
func _route_left() -> float:
	var d := 0.0
	for k in range(_wp, _route.size() - 1):
		d += _flat(_route[k + 1] - _route[k]).length()
	return d


## True when p is past the goal along the last leg (the spring overshot it).
func _passed(p: Vector3) -> bool:
	var n := _route.size()
	if n < 2:
		return false
	return _flat(p - _route[n - 1]).dot(_flat(_route[n - 1] - _route[n - 2])) > 0.0


## p on the walkable ground under it (unchanged over unwalkable ground).
func _ground(p: Vector3) -> Vector3:
	var g := _ctx.collision.walk_height(p) if _ctx.collision != null else NAN
	if not is_nan(g):
		p.y = g
	return p


## True when the hero cannot stand at p: no ground, something fixed, or another car's box.
func _blocked(p: Vector3) -> bool:
	var col := _ctx.collision
	if col == null:
		return false
	var g := col.walk_height(p)
	var r := WS.PLAYER_RADIUS * 0.8
	if is_nan(g) or col.is_blocked(Vector3(p.x, g, p.z), r):
		return true
	for b: AABB in _boxes:
		if p.x > b.position.x - r and p.x < b.end.x + r and p.z > b.position.z - r:
			if p.z < b.end.z + r:
				return true
	return false


## True when something stands where the door swings (its middle and its edge, wide open).
func _door_blocked() -> bool:
	var col := _ctx.collision
	if col == null:
		return false
	var h: Vector3 = _pts["hinge"]
	var o: Vector3 = _pts["open_rear"]
	for f: float in [0.5, 1.0]:
		var q := _car * h.lerp(o, f)
		var g := col.walk_height(q)
		if not is_nan(g) and col.is_blocked(Vector3(q.x, g, q.z), DOOR_R):
			return true
	return false


func _rig() -> RefCounted:
	return _rig_of(_ctx)


func _rig_call(method: String, args: Array) -> void:
	var rig := _rig()
	if rig != null:
		rig.callv(method, args)


## The hero's rig when it can sit (HC's animated hero; the stand-in figure cannot).
static func _rig_of(ctx: FpContext) -> RefCounted:
	var av := ctx.player.avatar if ctx != null and ctx.player != null else null
	if av == null or not bool(av.call("is_animated")):
		return null
	var rig: Variant = av.get("rig")
	if rig is RefCounted and (rig as RefCounted).has_method("travel"):
		return rig
	return null


## The view-relative wish (FpPlayer.simulate) that walks along world direction d (xz).
static func _wish(d: Vector2, cam_yaw: float) -> Vector2:
	var right := Vector2(cos(cam_yaw), -sin(cam_yaw))
	var fwd := Vector2(-sin(cam_yaw), -cos(cam_yaw))
	return Vector2(d.dot(right), d.dot(fwd))


## The body yaw (FpPlayer: forward is (-sin, 0, -cos)) that faces along d.
static func _yaw_of(d: Vector3) -> float:
	return atan2(-d.x, -d.z)


static func _flat(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)
