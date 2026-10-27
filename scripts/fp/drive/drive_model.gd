extends RefCounted
## Arcade handling for the player's car. Throttle and brake set the speed along the heading
## (brake reverses once stopped), the steering angle turns the car through a bicycle model, and
## the tyres bleed off sideways speed at a rate set by the surface, so a handbrake turn slides.
## Knocks (car_body.gd) add to the velocity and to a spin the tyres damp out. World units (WS.M
## per metre) and seconds; the heading at yaw 0 is +Z, as for every vehicle.

const WS := preload("res://scripts/fp/world_scale.gd")

const TOP := 30.0 * WS.M  # 108 km/h on asphalt
const REVERSE_TOP := 7.0 * WS.M
const ACCEL := 7.0 * WS.M  # m/s^2 from rest, falling off toward TOP
const BRAKE := 14.0 * WS.M
const ROLL := 0.6 * WS.M  # coasting: rolling loss plus DRAG per m/s
const DRAG := 0.12
const HANDBRAKE := 6.0 * WS.M
const STEER_MAX := deg_to_rad(34.0)
## The steering lock halves by this speed (a light touch on the motorway, full lock in a car park).
const STEER_HALF_AT := 13.0 * WS.M
const STEER_RATE := 3.2  # rad/s toward the wanted angle
const STEER_RETURN := 5.0
## Wheelbase as a share of body length.
const WHEELBASE := 0.6
## Sideways speed lost per second (1/s): tyres on asphalt, and on the handbrake.
const GRIP := 9.0
const GRIP_HANDBRAKE := 1.4
## Grip and top-speed factors off the carriageway.
const SURFACES := {
	"asphalt": [1.0, 1.0],
	"bridge": [1.0, 1.0],
	"sidewalk": [0.9, 0.8],
	"lot": [0.85, 0.7],
	"gravel": [0.75, 0.75],
	"dirt": [0.6, 0.5],
	"trail": [0.6, 0.55],
	"grass": [0.55, 0.45],
}
## Spin from knocks lost per second (1/s): tyres gripping, and on the handbrake.
const SPIN_GRIP := 3.0
const SPIN_GRIP_HANDBRAKE := 0.8

var yaw: float = 0.0
var vel := Vector2.ZERO
var steer: float = 0.0
var length: float = 0.24
## This body's handling profile: a slower, heavier machine (a backhoe) tops out below TOP and
## gets up to speed at a share of a car's rate, and a long working body (a bus, a truck) also
## steers on a shorter lock and pulls up at a share of a car's braking (a car: {top: TOP, gain:
## 1, steer: 1, brake: 1}).
var top := TOP
var gain := 1.0
## The body's own steering lock and braking, as shares of a car's.
var steer_lock := 1.0
var brake_f := 1.0
## Signed acceleration along the heading over the last step (brake lights).
var accel: float = 0.0
## Yaw rate from knocks (rad/s, positive turns the heading toward +X at yaw 0), on top of the
## steering.
var spin: float = 0.0


## p_profile: {"top": u/s, "gain": share of ACCEL, "steer": share of STEER_MAX, "brake": share of
## BRAKE} of the body being driven ({}: a car's).
func reset(p_yaw: float, p_length: float, p_profile: Dictionary = {}) -> void:
	yaw = p_yaw
	length = p_length
	vel = Vector2.ZERO
	steer = 0.0
	accel = 0.0
	spin = 0.0
	top = float(p_profile.get("top", TOP))
	gain = float(p_profile.get("gain", 1.0))
	steer_lock = float(p_profile.get("steer", 1.0))
	brake_f = float(p_profile.get("brake", 1.0))


func heading() -> Vector2:
	return Vector2(sin(yaw), cos(yaw))


## Signed speed along the heading (u/s, negative in reverse).
func speed() -> float:
	return vel.dot(heading())


## One step: throttle, brake and handbrake 0..1, steer -1 (left) .. 1 (right). Returns the xz
## displacement; yaw and vel move on.
func step(
	throttle: float, brake: float, steer_in: float, handbrake: float, surface: String, dt: float
) -> Vector2:
	if dt <= 0.0:
		return Vector2.ZERO
	var surf: Array = SURFACES.get(surface, [0.8, 0.7])
	var vf := speed()
	var lock := STEER_MAX * steer_lock / (1.0 + absf(vf) / STEER_HALF_AT)
	var want := clampf(steer_in, -1.0, 1.0) * lock
	var rate := (
		STEER_RATE if absf(want) > absf(steer) or signf(want) != signf(steer) else STEER_RETURN
	)
	steer = move_toward(steer, want, rate * dt)
	# Steering right turns the heading toward -X (the car's right when it faces +Z).
	var turn := vf * tan(steer) / maxf(length * WHEELBASE, 1e-4)
	if handbrake > 0.0:
		turn *= 1.0 + 0.4 * handbrake
	yaw = wrapf(yaw - turn * dt + spin * dt, -PI, PI)
	var hb := clampf(handbrake, 0.0, 1.0)
	spin *= exp(-lerpf(SPIN_GRIP, SPIN_GRIP_HANDBRAKE, hb) * dt)
	var h := heading()
	var side := Vector2(-h.y, h.x)
	vf = vel.dot(h)
	var vs := vel.dot(side)
	var before := vf
	vf = _drive(
		vf, throttle, brake, handbrake, top * float(surf[1]), ACCEL * gain, BRAKE * brake_f, dt
	)
	accel = (vf - before) / dt
	var grip := lerpf(GRIP * float(surf[0]), GRIP_HANDBRAKE, hb)
	vs *= exp(-grip * dt)
	vel = h * vf + side * vs
	return vel * dt


## Speed along the heading after throttle, brake (reverse once stopped), handbrake and coasting.
## acc: the body's acceleration (u/s^2, a car's ACCEL scaled by its profile gain); bk: its braking
## (u/s^2, a car's BRAKE scaled by its profile brake share).
static func _drive(
	vf: float,
	throttle: float,
	brake: float,
	handbrake: float,
	top: float,
	acc: float,
	bk: float,
	dt: float
) -> float:
	var stopped := 0.5 * WS.M
	if throttle > 0.0:
		if vf < -stopped:
			vf = minf(vf + bk * throttle * dt, 0.0)
		else:
			vf += acc * throttle * maxf(0.0, 1.0 - vf / top) * dt
	if brake > 0.0:
		if vf > stopped:
			vf = maxf(vf - bk * brake * dt, 0.0)
		else:
			vf -= acc * 0.7 * brake * maxf(0.0, 1.0 + vf / REVERSE_TOP) * dt
	if throttle <= 0.0 and brake <= 0.0:
		vf = move_toward(vf, 0.0, (ROLL + DRAG * absf(vf)) * dt)
	if handbrake > 0.0:
		vf = move_toward(vf, 0.0, HANDBRAKE * handbrake * dt)
	if vf > top:
		vf = move_toward(vf, top, bk * 0.4 * dt)
	return vf
