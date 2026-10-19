class_name SpringMath
extends RefCounted
## Frame-rate independent dampers and springs for the player and the third-person camera.
## After D. Holden, "Spring-It-On" (theorangeduck.com/page/spring-roll-call), MIT. Every function
## is exact for any dt, so the same input at 30 fps and at 144 fps lands in the same place.

const LN2 := 0.69314718056


## Exponential damper: moves x toward goal; half the gap closes every `halflife` seconds.
static func damp(x: float, goal: float, halflife: float, dt: float) -> float:
	return lerpf(x, goal, 1.0 - pow(2.0, -dt / maxf(halflife, 1e-5)))


## The fraction of the gap damp() closes in dt.
static func damp_factor(halflife: float, dt: float) -> float:
	return 1.0 - pow(2.0, -dt / maxf(halflife, 1e-5))


## damp() for a Vector3.
static func damp_v3(x: Vector3, goal: Vector3, halflife: float, dt: float) -> Vector3:
	return x.lerp(goal, 1.0 - pow(2.0, -dt / maxf(halflife, 1e-5)))


## damp() for an angle in radians, the shortest way round; the result is wrapped to [-PI, PI].
static func damp_angle(a: float, goal: float, halflife: float, dt: float) -> float:
	return wrapf(a + wrapf(goal - a, -PI, PI) * (1.0 - pow(2.0, -dt / maxf(halflife, 1e-5))), -PI, PI)


## Critically damped spring: returns Vector2(x, v) after dt. Never overshoots a static goal from
## rest; halflife is roughly the time for the error to halve.
static func spring(x: float, v: float, goal: float, halflife: float, dt: float) -> Vector2:
	var y := 2.0 * LN2 / maxf(halflife, 1e-5)
	var j0 := x - goal
	var j1 := v + j0 * y
	var e := exp(-y * dt)
	return Vector2(e * (j0 + j1 * dt) + goal, e * (v - j1 * y * dt))


## spring() for an angle in radians (shortest way round); x is wrapped to [-PI, PI].
static func spring_angle(a: float, v: float, goal: float, halflife: float, dt: float) -> Vector2:
	var r := spring(a, v, a + wrapf(goal - a, -PI, PI), halflife, dt)
	return Vector2(wrapf(r.x, -PI, PI), r.y)


## The critically damped spring applied to a planar velocity (x = velocity, v = acceleration):
## returns [velocity, acceleration, displacement] after dt, the displacement being the exact
## integral of the velocity over the step (so the walked distance is frame-rate independent).
static func velocity_spring(vel: Vector2, acc: Vector2, goal: Vector2, halflife: float, dt: float) -> Array:
	var y := 2.0 * LN2 / maxf(halflife, 1e-5)
	var j0 := vel - goal
	var j1 := acc + j0 * y
	var e := exp(-y * dt)
	var nv := (j0 + j1 * dt) * e + goal
	var na := (acc - j1 * (y * dt)) * e
	# Integral of e^(-y t) (j0 + j1 t) over [0, dt], plus the goal times dt.
	var i0 := (1.0 - e) / y
	var i1 := (1.0 - e * (1.0 + y * dt)) / (y * y)
	var disp := j0 * i0 + j1 * i1 + goal * dt
	return [nv, na, disp]


## Distance a velocity spring (goal 0) still travels when released at speed v0.
static func stop_distance(v0: float, halflife: float) -> float:
	return v0 * halflife / LN2


## smoothstep on [0, 1].
static func smooth01(t: float) -> float:
	var c := clampf(t, 0.0, 1.0)
	return c * c * (3.0 - 2.0 * c)


## Camera blend: position lerp and basis slerp (both orthonormalised first).
static func blend_xform(a: Transform3D, b: Transform3D, t: float) -> Transform3D:
	var qa := a.basis.orthonormalized().get_rotation_quaternion()
	var qb := b.basis.orthonormalized().get_rotation_quaternion()
	return Transform3D(Basis(qa.slerp(qb, t)), a.origin.lerp(b.origin, t))


## Vector2(yaw, pitch) of a camera basis looking along -Z (yaw = rotation.y, pitch = rotation.x).
static func yaw_pitch_of(b: Basis) -> Vector2:
	var f := -b.z.normalized()
	return Vector2(atan2(-f.x, -f.z), asin(clampf(f.y, -1.0, 1.0)))


## The camera basis for yaw and pitch (YXZ Euler, no roll).
static func look_basis(yaw: float, pitch: float) -> Basis:
	return Basis.from_euler(Vector3(pitch, yaw, 0.0), EULER_ORDER_YXZ)
