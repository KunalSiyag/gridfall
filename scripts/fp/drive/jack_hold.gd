extends RefCounted
## The hero's part in pulling a driver out of a car, from the first reach to letting go
## (car_entry.gd's jack phase with the carjack_throw flag): one sequence of four beats read from the
## driver, not a clock of fixed times. Reach (REACH_S, at least, then until both hands are on): the
## hero steps in to the grab spot, a little behind the driver's seat and out beside the body's side,
## so that the driver comes out in front of him and not through him, leans in, and his hands go to
## the driver's collar and near upper arm (the points are read per frame off the driver's skeleton:
## carjack.gd grips). Struggle (STRUGGLE_S): he holds on, bracing back, the driver sitting up and
## leaning against the pull (the hero's reach tells the driver to resist: occupants.gd resist). Then
## step returns "pull": the drive feature has the driver pulled out of the seat. Pull (until the
## driver is let go beside the door, PULL_MAX at most): the hands follow the driver's collar and arm
## as the haul draws them out over the sill, the hero bent forward over them, following the collar
## at his stand-off, stepping back with them (FOLLOW_K, X_OUT: the hands do not trail), giving way
## where the body swings through him (KEEP). Release (RELEASE_S): he lets go (the hands ease out),
## straightens, and step returns "done". The hero's hands never rise above REACH_TOP over
## his feet. At a sim speed above 1x the driver is out of the seat and down in a fraction of the
## pull, and the grip lets go as the collar gets away faster than SLIP_V.

const WS := preload("res://scripts/fp/world_scale.gd")

## The beats, in seconds: the reach (waits for the hands, REACH_MAX at the most), the struggle, the
## pull (PULL_MAX at the most) and the release.
const REACH_S := 0.5
const REACH_MAX := 0.7
const STRUGGLE_S := 0.4
const PULL_MAX := 0.8
const RELEASE_S := 0.3
## Where the hero takes hold from: GRAB_BEHIND (0.45 m) behind the driver's seat along the car, the
## side the driver is drawn out and down toward (the open door's panel hangs ahead of the seat and
## the hero keeps off it, PANEL_GAP) and GRAB_OUT out from the door's skin (the handle's side: the
## car's box is wider than its doors, for the mirrors), at least GRAB_OUT_MIN, a little within the
## box itself. Nearer the seat (0.7 of GRAB_BEHIND) when that spot cannot be stood at, then
## GRAB_AHEAD (0.3 m) ahead of it, then level with it: the last resorts, the driver's body then
## swings out nearer him (the hero is kept KEEP off it, below).
const GRAB_AHEAD := 0.3 * WS.M
const GRAB_BEHIND := 0.45 * WS.M
const GRAB_OUT := 0.1 * WS.M
const GRAB_OUT_MIN := 0.06 * WS.M
## The open door's panel is kept off by this much (from the hero's root).
const PANEL_GAP := 0.5 * WS.M
## In the pull he follows the driver's collar at the stand-off he has as it begins (the direction
## from the collar to where he stands, kept), which closes to FOLLOW_K of it as the driver comes
## (1: it does not close, he bends over them instead: the crouch of hero_strike_pose.gd), never more
## than X_OUT out from the car's side (the driver lies beyond him, along the car's side, head to the
## rear: he does not stand in their way, nor walk through them after), with his hands on the driver
## all the way: the body swings out through where he stands and he gives way (KEEP, below).
const FOLLOW_K := 1.0
const X_OUT := 0.5 * WS.M
## The driver is let go OUT_M beyond the car's side (carjack.gd OUT), which is how far their way out
## is.
const OUT_M := 0.55 * WS.M
## A hand within HANDS_ON of its grip is on it. The hands never rise above REACH_TOP over his feet.
const HANDS_ON := 0.1 * WS.M
const REACH_TOP := 1.15 * WS.M
## The grips are never higher than HEAD_GAP under the hero's head (the crouch brings it down).
const HEAD_GAP := 0.12 * WS.M
## The spine's lean (0..1 of the pose layer's back lean, negative forward to reach in) at the beats.
const LEAN_REACH := -1.0
const LEAN_STRUGGLE := -0.8
const LEAN_PULL := -1.0
## The driver's resistance at the struggle: the roll toward the door and the sit-up (rad, a sit-up
## back is negative) and the shake of the roll (rad at SHAKE_HZ).
const RESIST_ROLL := 0.35
const RESIST_SIT := -0.12
const SHAKE := 0.03
const SHAKE_HZ := 4.5
## The pull's progress, which the hero's step back and lean follow, keeps pace with the driver's way
## out at most PROG_RATE (of the whole way per s): at 8x the driver is out in a frame and he does
## not jump half a metre after them.
const PROG_RATE := 3.0
## With no collar to be found (no body drawn) it is this far above the seat marker.
const COLLAR_UP := 0.6 * WS.M
## The grip slips (let go for good) when the collar gets away faster than SLIP_V (u/s), easing out
## over SLIP_EASE s.
const SLIP_V := 10.0 * WS.M
const SLIP_EASE := 0.5
## The hero keeps his root KEEP from every point of the driver's body in plan (the grips' "keep":
## the body swings out through where he stands and he gives way, at most PUSH_V (u/s) more than his
## own step), and in the pull his step moves at most HERO_V (u/s): a stride and a half, not a
## sprint, whatever the sim speed (at 8x the body is out before he has given way: it is not shoved
## off him, his hands do not jump).
const KEEP := 0.36 * WS.M
const HERO_V := 3.4 * WS.M
const PUSH_V := 2.5 * WS.M
const YAW_RATE := 4.0
## The grips the hands follow move at most GRIP_STEP per frame (a collar that is away faster is let
## go by SLIP_V, the hands have not jumped after it by then).
const GRIP_STEP := 0.12 * WS.M
const EASE_OUT := 0.4

## "reach", "struggle", "pull" or "release"; "" when not running.
var beat: String = ""
## Seconds into the beat, and into the whole hold.
var bt: float = 0.0
var t: float = 0.0
## The two grips (world): {"collar", "arm"} as the driver's body gave them last, for a frame with
## none.
var _last := {}
var _ctx: FpContext
var _car := Transform3D.IDENTITY
var _pts: Dictionary = {}
var _side: float = 0.0
## The driver's grips now (Callable(toward, top, arm side) -> {"collar", "arm", "side"}), whether
## the pull has hauled them out and let go (Callable() -> bool), their resistance (Callable(roll:
## float, sit_up: float)) and the rig's and the ground's and the hero's moves.
var grips: Callable = Callable()
var hauled: Callable = Callable()
var resist: Callable = Callable()
var _ride: Callable = Callable()
var _ground: Callable = Callable()
var _blocked: Callable = Callable()
var _from := Vector3.ZERO
var _from_yaw: float = 0.0
var _to := Vector3.ZERO
## The level unit vector from the driver's collar to where he stands, and the distance (the
## stand-off) at the grab.
var _dir := Vector3.ZERO
var _d0: float = 0.0
## 1 when the collar is in his left hand (settled as the hold begins), else 0.
var _left: int = 1
## The arm of the driver held ("Left" or "Right"), settled by the first frame that finds it.
var _arm_side: String = ""
## The hero's skeleton and his head in it as the last update drew it (_watch).
var _sk: Skeleton3D = null
var _head := Vector3(NAN, NAN, NAN)
var _out := Vector3.ZERO
var _travel: float = 1.0
var _pull0 := Vector3.ZERO
var _prog: float = 0.0
var _was := Vector3.ZERO
## The middle of the two grips as the body has them (not as the hands follow them), as last frame
## had it.
var _raw := Vector3.ZERO
var _raw_was := Vector3.ZERO
var _slipped: bool = false
var _lean: float = 0.0
var _cur := Vector3.INF
var _shove := Vector3.ZERO
var _dt: float = 0.0
var _x_min: float = 0.0
var _x_max: float = 0.0
var _hold: float = 0.0
var _yaw: float = 0.0
## This frame's values, as the beat sets them: where the hero stands, the weight of the hold, how
## long it eases out, the lean and the driver's resistance (0..1).
var _f_pos := Vector3.ZERO
var _f_hold: float = 1.0
var _f_ease: float = 0.0
var _f_tilt: float = 0.0
var _f_res: float = 0.0


## Starts the hold on the car at transform car (+Z forward, +X the driver's side) whose door points
## are pts, the body's side `side` out; ride(pos, yaw), ground(p) and blocked(p) are the entry's.
func begin(
	ctx: FpContext,
	car: Transform3D,
	pts: Dictionary,
	side: float,
	ride: Callable,
	ground: Callable,
	blocked: Callable
) -> void:
	_ctx = ctx
	_car = car
	_pts = pts
	_side = side
	_ride = ride
	_ground = ground
	_blocked = blocked
	beat = "reach"
	bt = 0.0
	t = 0.0
	_watch(false)
	_watch(true)
	_slipped = false
	_prog = 0.0
	_last = {}
	_arm_side = ""
	var p := ctx.player
	_from = p.position
	_from_yaw = p.yaw
	var g := _grips_now()
	var at := _mid(g)
	_to = _grab_spot()
	_cur = Vector3.INF
	_shove = Vector3.ZERO
	_x_min = (car.affine_inverse() * _to).x - 0.05 * WS.M
	_x_max = maxf(_side + X_OUT, (car.affine_inverse() * _to).x)
	_out = _flat3(car.basis.x).normalized()
	_dir = _out
	_d0 = 0.5 * WS.M
	var seat: Vector3 = pts["seat"]
	_travel = maxf(side + OUT_M - seat.x, 0.5 * WS.M)
	_was = at
	_raw_was = _raw
	_hold = 0.0
	_lean = 0.0
	var face := _yaw_of(at - _to)
	var hands := _hands(g, Vector3(cos(face), 0.0, -sin(face)))
	_left = 1 if hands[0].is_equal_approx(g["collar"]) else 0


func running() -> bool:
	return not beat.is_empty()


## Moves on by dt: "pull" once (the driver is to be pulled out now), "done" when the hero has let
## go, else "".
func step(dt: float) -> String:
	if beat.is_empty() or dt <= 0.0:
		return ""
	bt += dt
	t += dt
	_dt = dt
	var g := _grips_now()
	var at := _mid(g)
	var said := ""
	_f_pos = _to
	_f_hold = 1.0
	_f_ease = 0.0
	_f_tilt = 0.0
	_f_res = 0.0
	match beat:
		"reach":
			_reach(g)
		"struggle":
			said = _struggle(at)
		"pull":
			_pull(at, dt)
		"release":
			if _release(g):
				return "done"
	_settle(g, at)
	return said


## The reach: he steps in to the grab spot and leans in, the hands go on; on to the struggle once
## both are on (REACH_S at the least, REACH_MAX at the most).
func _reach(g: Dictionary) -> void:
	var k := smoothstep(0.0, REACH_S, bt)
	_f_pos = _from.lerp(_to, k)
	_f_hold = smoothstep(0.0, 0.85 * REACH_S, bt)
	_f_tilt = lerpf(0.0, LEAN_REACH, k)
	_f_res = smoothstep(0.6 * REACH_S, REACH_S, bt) * 0.5
	if bt >= REACH_S and (_on(g) or bt >= REACH_MAX):
		_go("struggle")


## The struggle: he braces, the driver resists; "pull" at its end.
func _struggle(at: Vector3) -> String:
	var k := smoothstep(0.0, 1.0, bt / STRUGGLE_S)
	_f_tilt = lerpf(LEAN_REACH, LEAN_STRUGGLE, k)
	_f_res = lerpf(0.5, 1.0, k)
	if bt < STRUGGLE_S:
		return ""
	_go("pull")
	var off := _flat3(_cur - at) if _cur.is_finite() else _flat3(_to - at)
	_dir = off.normalized() if off.length() > 1e-4 else _out
	_d0 = maxf(off.length(), 0.3 * WS.M)
	_pull0 = at
	_slipped = false
	return "pull"


## The pull: he leans back and steps back as far as the driver has come; let go once they are out.
func _pull(at: Vector3, dt: float) -> void:
	var raw := clampf((at - _pull0).dot(_out) / _travel, 0.0, 1.0)
	var over := bool(hauled.call()) if hauled.is_valid() else bt >= PULL_MAX
	_prog = move_toward(_prog, 1.0 if over else raw, PROG_RATE * dt)
	var d := lerpf(_d0, _d0 * FOLLOW_K, smoothstep(0.0, 0.5, _prog))
	_f_pos = _clamp_x(_flat3(at) + _dir * d)
	_f_tilt = lerpf(LEAN_STRUGGLE, LEAN_PULL, _prog)
	_slipped = _slipped or (_raw - _raw_was).length() > SLIP_V * dt
	if _slipped:
		_f_hold = 0.0
		_f_ease = SLIP_EASE
	if over or bt >= PULL_MAX:
		_go("release")


## p (world) moved out of KEEP of every point of the driver's body (the grips' "keep") in plan, and
## kept out of the car's side.
func _keep_off(p: Vector3, g: Dictionary) -> Vector3:
	var keep: PackedVector3Array = g.get("keep", PackedVector3Array())
	for _pass in range(2):
		for q: Vector3 in keep:
			var d := _flat3(p - q)
			var n := d.length()
			if n < KEEP:
				p += (d / n if n > 1e-4 else _dir) * (KEEP - n)
	var l := _car.affine_inverse() * p
	if l.x < _x_min:
		l.x = _x_min
		p = _car * l
	return p


## p (world) no further out from the car than X_OUT of its side.
func _clamp_x(p: Vector3) -> Vector3:
	var l := _car.affine_inverse() * p
	if l.x > _x_max:
		l.x = _x_max
		p = _car * Vector3(l.x, 0.0, l.z)
	return p


## The release: the hands ease out and he straightens; true once he has (the hold is over).
func _release(g: Dictionary) -> bool:
	_f_pos = _cur if _cur.is_finite() else _to
	_f_hold = 0.0
	_f_ease = EASE_OUT
	_f_tilt = lerpf(_lean, 0.0, smoothstep(0.0, RELEASE_S, bt))
	if bt < RELEASE_S:
		return false
	grip(_ctx, g, 0.0, _yaw, 0.0, EASE_OUT, _left)
	beat = ""
	_watch(false)
	return true


## What every frame of the hold ends with: the hero put where the beat has him facing the grips, the
## hands sent to them, the driver's resistance told.
func _settle(g: Dictionary, at: Vector3) -> void:
	_was = at
	_raw_was = _raw
	_lean = _f_tilt
	_hold = _f_hold
	var face := _yaw_of(at - _f_pos) if _flat3(at - _f_pos).length() > 1e-4 else _yaw
	# He turns to the driver at most YAW_RATE rad/s once the hold is on: a driver slid away fast (at
	# 8x) does not swing his arms round.
	if beat != "reach":
		face = _yaw + clampf(wrapf(face - _yaw, -PI, PI), -YAW_RATE * _dt, YAW_RATE * _dt)
	_yaw = face
	if beat == "reach" and bt < 0.5 * REACH_S:
		_yaw = lerp_angle(_from_yaw, _yaw, smoothstep(0.0, 0.5 * REACH_S, bt))
	if beat in ["pull", "release"]:
		if _cur.is_finite():
			_f_pos = _cur + _flat3(_f_pos - _cur).limit_length(HERO_V * _dt)
		_cur = _f_pos
		var want := _keep_off(_f_pos, g) - _f_pos
		_shove += _flat3(want - _shove).limit_length(PUSH_V * _dt)
		_f_pos += _shove
	else:
		_cur = _f_pos
	_ride.call(_ground.call(_f_pos), _yaw)
	grip(_ctx, g, _f_hold, _yaw, _f_tilt, _f_ease, _left)
	if resist.is_valid():
		var shake := SHAKE * sin(TAU * SHAKE_HZ * t) * _f_res
		resist.call(RESIST_ROLL * _f_res + shake, RESIST_SIT * _f_res)


## Stops where it is: the hands let go, the driver stops resisting.
func cancel() -> void:
	if beat.is_empty():
		return
	grip(_ctx, _last, 0.0, _yaw, 0.0, EASE_OUT, _left)
	if resist.is_valid():
		resist.call(0.0, 0.0)
	beat = ""
	_watch(false)


## The collar of the driver now: the midpoint of the two grips (world) of the last frame.
func at() -> Vector3:
	return _mid(_last) if not _last.is_empty() else Vector3.ZERO


## The grips as the driver's body has them now, else as they last were, else just above the seat.
func _grips_now() -> Dictionary:
	var p := _ctx.player
	var g: Dictionary = {}
	if grips.is_valid():
		g = grips.call(p.position, _top(), _arm_side)
	var c: Vector3 = g.get("collar", Vector3(NAN, NAN, NAN))
	if not c.is_finite():
		g = _last if not _last.is_empty() else _fallback()
	elif not (g["arm"] as Vector3).is_finite():
		g["arm"] = c + _out * 0.15 * WS.M - Vector3.UP * 0.15 * WS.M
	if not str(g.get("side", "")).is_empty():
		_arm_side = str(g["side"])
	_raw = _mid(g)
	if not _last.is_empty():
		g = {
			"collar": _step_to(_last["collar"], g["collar"]),
			"arm": _step_to(_last["arm"], g["arm"]),
			"side": g.get("side", ""),
			"keep": g.get("keep", PackedVector3Array())
		}
	_last = g
	return g


static func _step_to(from: Vector3, to: Vector3) -> Vector3:
	return from + (to - from).limit_length(GRIP_STEP)


## The height the hands may reach to: HEAD_GAP under his head as it is now, REACH_TOP over his feet
## when the rig has no head to read.
func _top() -> float:
	if _head.is_finite():
		return _head.y - HEAD_GAP
	return _ctx.player.position.y + REACH_TOP


## The hero's skeleton has been updated, every modifier run: his head as it is drawn (crouched).
func _on_updated() -> void:
	if _sk != null:
		var i := _sk.find_bone("Head")
		if i >= 0:
			_head = _sk.global_transform * _sk.get_bone_global_pose(i).origin


## Watches the hero's skeleton for his head (begin), or stops (done, cancel).
func _watch(on: bool) -> void:
	if on and _sk == null:
		var rig: Variant = rig_of(_ctx)
		var sk: Variant = (rig as RefCounted).get("skeleton") if rig != null else null
		_sk = sk as Skeleton3D
		if _sk != null:
			_sk.skeleton_updated.connect(_on_updated)
		_head = Vector3(NAN, NAN, NAN)
	elif not on and _sk != null:
		if _sk.skeleton_updated.is_connected(_on_updated):
			_sk.skeleton_updated.disconnect(_on_updated)
		_sk = null


## No body drawn: the two points just above the seat marker.
func _fallback() -> Dictionary:
	var s: Vector3 = _pts["seat"]
	var c := _car * Vector3(s.x, s.y + COLLAR_UP, s.z)
	return {
		"collar": c,
		"arm": c + _flat3(_car.basis.x).normalized() * 0.18 * WS.M - Vector3.UP * 0.18 * WS.M
	}


## The spot he takes hold from: behind the seat along the car and out beside its side, the nearest
## of a few that he can stand at.
func _grab_spot() -> Vector3:
	var seat: Vector3 = _pts["seat"]
	var skin := minf(_side, (_pts["handle"] as Vector3).x)
	var tries := [
		[GRAB_OUT, -GRAB_BEHIND],
		[GRAB_OUT_MIN, -GRAB_BEHIND],
		[GRAB_OUT, -0.7 * GRAB_BEHIND],
		[GRAB_OUT_MIN, -0.7 * GRAB_BEHIND],
		[GRAB_OUT_MIN, GRAB_AHEAD],
		[GRAB_OUT_MIN, 0.0]
	]
	for pair: Array in tries:
		var local := Vector3(skin + float(pair[0]), 0.0, seat.z + float(pair[1]))
		if _standable(local) and _off_panel(local):
			return _ground.call(_car * local)
	return _from


## True when `local` (car frame) is PANEL_GAP clear of the open door's panel (its hinge to its rear
## edge swung wide).
func _off_panel(local: Vector3) -> bool:
	var h: Vector3 = _pts["hinge"]
	var r: Vector3 = _pts["open_rear"]
	var a := Vector2(h.x, h.z)
	var ab := Vector2(r.x, r.z) - a
	var p := Vector2(local.x, local.z)
	var u := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
	return (a + ab * u).distance_to(p) >= PANEL_GAP


## True when the hero can stand at `local` (car frame): the car's own box is no obstacle to lean in
## at (he is placed, not walked, and the doors are narrower than the box); what lies beyond it is.
func _standable(local: Vector3) -> bool:
	var out: Vector3 = _ground.call(_car * Vector3(maxf(local.x, _side + 0.3 * WS.M), 0.0, local.z))
	return not bool(_blocked.call(out))


## True when both hands are on the grips (the rig's bones, within HANDS_ON).
func _on(g: Dictionary) -> bool:
	var rig: Variant = rig_of(_ctx)
	if rig == null:
		return true
	var hands := _hands(g, Vector3(cos(_yaw), 0.0, -sin(_yaw)), _left)
	for i in range(2):
		var h: Vector3 = (rig as RefCounted).call(
			"bone_world", "LeftHand" if i == 0 else "RightHand"
		)
		if not h.is_finite() or h.distance_to(hands[i]) > HANDS_ON:
			return false
	return true


## Both hands of the hero (ctx) to the grips g ({"collar", "arm"}, world) at weight hold, the body
## facing yaw, leaning back by lean (0..1 of the pose layer's lean, negative forward); let go over
## ease s (0: the pose layer's own). The palms face the driver, a little down.
static func grip(
	ctx: FpContext,
	g: Dictionary,
	hold: float,
	yaw: float,
	lean: float,
	ease_s: float,
	collar_left: int = -1
) -> void:
	var rig: Variant = rig_of(ctx)
	var pose: Variant = (rig as RefCounted).get("strike_pose") if rig != null else null
	if pose == null:
		return
	var hands := _hands(g, Vector3(cos(yaw), 0.0, -sin(yaw)), collar_left)
	var into := _flat3(_mid(g) - ctx.player.position)
	var palm := (into.normalized() if into.length() > 1e-5 else Vector3.ZERO) - Vector3.UP * 0.25
	palm = palm.normalized()
	(pose as RefCounted).call(
		"set_pull", hold, hands, lean, ease_s, PackedVector3Array([palm, palm])
	)


## [left hand's grip, right hand's grip]: with collar_left 1 the collar goes to the left hand, with
## 0 to the right; with -1 (not settled) the one that is on the hero's right (a level unit vector)
## goes to his right hand.
static func _hands(g: Dictionary, right: Vector3, collar_left: int = -1) -> PackedVector3Array:
	var a: Vector3 = g["collar"]
	var b: Vector3 = g["arm"]
	var swap := b.dot(right) < a.dot(right) if collar_left < 0 else collar_left == 0
	return PackedVector3Array([b, a]) if swap else PackedVector3Array([a, b])


func _go(b: String) -> void:
	beat = b
	bt = 0.0


## The hero's rig when it can sit and strike (the animated hero; the stand-in figure cannot).
static func rig_of(ctx: FpContext) -> Variant:
	var av: Variant = ctx.player.avatar if ctx != null and ctx.player != null else null
	if av == null or not bool((av as Object).call("is_animated")):
		return null
	var rig: Variant = (av as Object).get("rig")
	return rig if rig is RefCounted else null


static func _mid(g: Dictionary) -> Vector3:
	return (g["collar"] as Vector3).lerp(g["arm"], 0.5)


static func _flat3(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


## The body yaw (FpPlayer: forward is (-sin, 0, -cos)) that faces along d.
static func _yaw_of(d: Vector3) -> float:
	return atan2(-d.x, -d.z)
