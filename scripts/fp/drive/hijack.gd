extends RefCounted
## The action hijack's moves (the drive feature's action_hijack flag): the hero, at the wheel of a
## car moving alongside another with someone at its wheel, climbs out through the window onto the
## roof on that car's side ("out"), leaps across onto the other car's roof ("leap") and swings down
## to its driver's window ("jack"), where he hangs on, a hand on the driver, while the driver stands
## on the brakes and the car pulls up ("hold"). Once it stands still he drops to the road beside it
## ("drop") and the rest is the stopped car's grab and pull (drive_feature.gd _jack_in,
## car_entry.gd, jack_hold.gd): no one is hauled out of a moving car, and the hero never takes the
## wheel without the pull. The hero rides each car's frame (+Z forward, +X its left and the driver's
## side, y up from the road; world units) while on it, and the leap blends from one moving car to
## the other, so both keep their own speed and line throughout.

const WS := preload("res://scripts/fp/world_scale.gd")

## Seconds for each move: out of the window onto the roof, across, and down to the window (SWING_S,
## the swing down); then at the window at least HOLD_MIN s and until the car stands still, which it
## is brought to at most STOP_MAX s after the landing (the driver stands on the brakes; later it is
## stopped on the spot), and the car he left, still rolling by it, has gone on past (at most
## CLEAR_MAX s: the walk to the door needs the ground beside it); then DROP_S down to the road
## beside the door.
const OUT_S := 0.6
const LEAP_S := 0.55
const SWING_S := 0.5
const HOLD_MIN := 0.3
const STOP_MAX := 2.5
const CLEAR_MAX := 3.5
## At the window no longer than this (HOLD_MAX s): a car that is no longer to be taken (it pulled in
## to park, its role changed) lets the hero go ("fail") rather than leaving him hanging for ever.
const HOLD_MAX := STOP_MAX + CLEAR_MAX + 1.0
const DROP_S := 0.4
## The car left is clear of the door once it is this far along from the seat (its half length on
## top), or this far off the side.
const PAST := 2.0 * WS.M
const OFF_SIDE := 2.0 * WS.M
## Feet on a roof stand this far in from its edge.
const ROOF_IN := 0.3 * WS.M
## At the driver's window the hero hangs this far out from the body (his torso clear of the door and
## its window frame, a hand reaching in), feet this far below the roof.
const HANG_OUT := 0.12 * WS.M
const HANG_DOWN := 1.25 * WS.M
## On the road he stands this far out from the body side and this far behind the seat (the door's
## walk starts from there: car_entry.gd).
const LAND_OUT := 0.45 * WS.M
const LAND_BACK := 0.4 * WS.M
## The leap rises this high above the straight line between the roofs.
const ARC := 0.6 * WS.M

## "out", "leap", "jack", "hold", "drop", or "" when no hijack runs.
var phase: String = ""
## Seconds into the phase.
var t: float = 0.0
## The car the hero leaves (rolling on with nobody at the wheel) and the one it takes.
var from_id: int = -1
var to_id: int = -1
## 1 when the car to take is on the left of the one left, -1 on its right.
var side: float = 0.0
## The hero's feet as it set off, in the frame of the car it leaves.
var _start := Vector3.ZERO
## The car was stopped on the spot (said once).
var _halted: bool = false
## Along the car to take, its driver's seat (u).
var _seat_z: float = 0.0


## Starts a hijack from car p_from (feet at start in its frame) to car p_to on side p_side, whose
## driver's seat is seat_z along it.
func begin(p_from: int, p_to: int, p_side: float, start: Vector3, seat_z: float) -> void:
	from_id = p_from
	to_id = p_to
	side = signf(p_side) if p_side != 0.0 else 1.0
	_start = start
	_seat_z = seat_z
	phase = "out"
	t = 0.0
	_halted = false


func running() -> bool:
	return not phase.is_empty()


func cancel() -> void:
	phase = ""
	t = 0.0


## Moves on by dt: "leap" once as the hero jumps, "brake" once as he lands on the other car's roof
## (its driver is to stand on the brakes), "halt" once if the car is still moving STOP_MAX s after
## that (it is to be stopped on the spot), "fail" once if it still cannot be taken HOLD_MAX s after
## (the hijack is over: he drops to the road) and "land" once as he is down on the road beside it
## (the hijack is over: the rest is the stopped car's), else "". stopped: the car to take stands
## still; clear: the car left is not by its door (left_clear).
func step(dt: float, stopped: bool = true, clear: bool = true) -> String:
	if phase.is_empty():
		return ""
	t += dt
	var said := ""
	if phase == "out" and t >= OUT_S:
		phase = "leap"
		t -= OUT_S
		said = "leap"
	elif phase == "leap" and t >= LEAP_S:
		phase = "jack"
		t -= LEAP_S
		said = "brake"
	elif phase == "jack" and t >= SWING_S:
		phase = "hold"
		t = 0.0
	elif phase == "hold":
		if stopped and t >= HOLD_MIN and (clear or t >= CLEAR_MAX):
			phase = "drop"
			t = 0.0
		elif t >= HOLD_MAX:
			cancel()
			said = "fail"
		elif t >= STOP_MAX and not _halted:
			_halted = true
			said = "halt"
	elif phase == "drop" and t >= DROP_S:
		cancel()
		said = "land"
	return said


## True when the car left (a: its car_info, {} when it is gone) is no longer by the driver's door of
## the car taken (b: its car_info): on its other side, well off its driver's side, or well along
## from the seat.
func left_clear(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty():
		return true
	var q := _xf(b).affine_inverse() * (a["pos"] as Vector3)
	var gap := q.x - float(a["half_w"]) - float(b["half_w"])
	if q.x < 0.0 or gap > OFF_SIDE:
		return true
	return absf(q.z - _seat_z) > 0.5 * float(a["length"]) + PAST


## The car whose frame the hero rides now: the one it leaves until the leap is half way.
func riding() -> int:
	return from_id if phase == "out" or (phase == "leap" and t < LEAP_S * 0.5) else to_id


## The hero's feet now, the cars' car_info()s given ({"pos", "yaw", "half_w", "height"}): a needs
## to be there until the leap ends, b from the leap on.
func feet(a: Dictionary, b: Dictionary) -> Vector3:
	match phase:
		"out":
			var k := smoothstep(0.0, 1.0, t / OUT_S)
			return _xf(a) * _start.lerp(_roof_a(a), k)
		"leap":
			var k := clampf(t / LEAP_S, 0.0, 1.0)
			var from := _xf(a) * _roof_a(a)
			var to := _xf(b) * _roof_b(b)
			return from.lerp(to, smoothstep(0.0, 1.0, k)) + Vector3.UP * ARC * sin(PI * k)
		"jack":
			var k := smoothstep(0.0, 1.0, t / SWING_S)
			return _xf(b) * _roof_b(b).lerp(_window(b), k)
		"hold":
			return _xf(b) * _window(b)
		"drop":
			var k := smoothstep(0.0, 1.0, t / DROP_S)
			return _xf(b) * _window(b).lerp(_road(b), k)
	return Vector3(NAN, NAN, NAN)


## True while the hero is in the air (the leap).
func airborne() -> bool:
	return phase == "leap"


## The roof edge of the car left, on the side of the car to take, level with the hero.
func _roof_a(a: Dictionary) -> Vector3:
	return Vector3(side * (float(a["half_w"]) - ROOF_IN), float(a["height"]), _start.z)


## The roof edge of the car to take facing the car left, level with its driver's seat.
func _roof_b(b: Dictionary) -> Vector3:
	return Vector3(-side * (float(b["half_w"]) - ROOF_IN), float(b["height"]), _seat_z)


## Standing on the road beside the driver's door of the car to take, a little behind its seat.
func _road(b: Dictionary) -> Vector3:
	return Vector3(float(b["half_w"]) + LAND_OUT, 0.0, _seat_z - LAND_BACK)


## Hanging outside the driver's window of the car to take.
func _window(b: Dictionary) -> Vector3:
	var h := float(b["height"])
	return Vector3(float(b["half_w"]) + HANG_OUT, maxf(h - HANG_DOWN, 0.0), _seat_z)


static func _xf(info: Dictionary) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, float(info["yaw"])), info["pos"])
