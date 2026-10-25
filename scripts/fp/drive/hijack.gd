extends RefCounted
## The action hijack's moves (the drive feature's action_hijack flag): the hero, at the wheel of a
## car moving alongside another with someone at its wheel, climbs out through the window onto the
## roof on that car's side ("out"), leaps across onto the other car's roof ("leap") and swings
## down to its driver's window ("jack"), where the driver is dragged out and the hero takes the
## wheel (drive_feature.gd). The hero rides each car's frame (+Z forward, +X its left and the
## driver's side, y up from the road; world units) while on it, and the leap blends from one
## moving car to the other, so both keep their own speed and line throughout.

const WS := preload("res://scripts/fp/world_scale.gd")

## Seconds for each move: out of the window onto the roof, across, and down to the window.
const OUT_S := 0.6
const LEAP_S := 0.55
const JACK_S := 0.6
## The leap rises this high above the straight line between the roofs.
const ARC := 0.6 * WS.M
## Feet on a roof stand this far in from its edge.
const ROOF_IN := 0.3 * WS.M
## At the driver's window the hero hangs this far out from the body, feet this far below the roof.
const HANG_OUT := 0.3 * WS.M
const HANG_DOWN := 1.0 * WS.M

## "out", "leap", "jack", or "" when no hijack runs.
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


func running() -> bool:
	return not phase.is_empty()


func cancel() -> void:
	phase = ""
	t = 0.0


## Moves on by dt: "pull" once, as the hero reaches the driver's window (the hijack is over), else
## "" (and "leap" once as the hero jumps).
func step(dt: float) -> String:
	if phase.is_empty():
		return ""
	t += dt
	if phase == "out" and t >= OUT_S:
		phase = "leap"
		t -= OUT_S
		return "leap"
	if phase == "leap" and t >= LEAP_S:
		phase = "jack"
		t -= LEAP_S
	elif phase == "jack" and t >= JACK_S:
		cancel()
		return "pull"
	return ""


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
			var k := smoothstep(0.0, 1.0, t / JACK_S)
			return _xf(b) * _roof_b(b).lerp(_window(b), k)
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


## Hanging outside the driver's window of the car to take.
func _window(b: Dictionary) -> Vector3:
	var h := float(b["height"])
	return Vector3(float(b["half_w"]) + HANG_OUT, maxf(h - HANG_DOWN, 0.0), _seat_z)


static func _xf(info: Dictionary) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, float(info["yaw"])), info["pos"])
