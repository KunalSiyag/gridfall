extends RefCounted
## A street prop knocked over (props feature): its bounding box flies off, tips over about one of
## its own level axes, lands, rolls on over its edges while it comes down hard, slides to a stop
## and lies on a face. The props feature draws it from xform() and gives it the ground
## (CollisionWorld.ground_height) and the walls (CollisionWorld.body_blocked).

const WS := preload("res://scripts/fp/world_scale.gd")

const GRAVITY := 9.8 * WS.M
## A knocked prop leaves the ground at LIFT of its speed and tips at TIP rad/s for every m/s of
## speed per metre of its height, at most TIP_MAX; knocked over, at least TIP_MIN (enough to fall
## over any edge).
const LIFT := 0.3
const TIP := 0.6
const TIP_MIN := 4.0
const TIP_MAX := 10.0
## A prop whose footprint is LONG times longer one way than the other falls over a long side,
## whichever way it is pushed: a bench hit end-on does not stand up on its end.
const LONG := 1.5
## Hit off-centre it spins about the vertical at SPIN rad/s per m/s, at most SPIN_MAX.
const SPIN := 0.5
const SPIN_MAX := 6.0
## A landing faster than BOUNCE_MIN bounces back with BOUNCE of its speed; every landing keeps
## LAND_SPIN of the spin.
const BOUNCE := 0.3
const BOUNCE_MIN := 0.8 * WS.M
const LAND_SPIN := 0.6
## Sliding friction on the ground (share of g), the braking of its spin there (rad/s^2) and the
## share of its speed a wall sends back.
const FRICTION := 0.55
const SPIN_BRAKE := 8.0
const WALL_BOUNCE := 0.3
## Slamming onto a face while tipping faster than ROLL_ON (rad/s), it rolls on with ROLL_KEEP of
## that; short of the energy to get over an edge it rocks back at ROCK (rad/s).
const ROLL_ON := 7.0
const ROLL_KEEP := 0.45
const ROCK := 0.5
## Flat on a face, sliding slower than REST_SPEED and turning slower than REST_SPIN it rests;
## after MAX_LIFE (s) it rests anyway.
const REST_SPEED := 0.05 * WS.M
const REST_SPIN := 0.3
const MAX_LIFE := 8.0

## Where the prop stood: its base at the origin, yaw and uniform scale in the basis.
var start: Transform3D
## The centre of its box in its own scaled frame, and the box's half extents.
var centre := Vector3.ZERO
var half := Vector3.ONE * 0.01
## The box's world centre and velocity (u/s).
var pos := Vector3.ZERO
var vel := Vector3.ZERO
var yaw: float = 0.0
var yaw_rate: float = 0.0
## The level axis of its own frame it tips about (+-X or +-Z), the tip angle and its rate.
var axis := Vector3.RIGHT
var angle: float = 0.0
var rate: float = 0.0
## On the ground; lying on a face (angle a multiple of PI/2, no tip); at rest for good.
var grounded: bool = false
var flat: bool = false
var resting: bool = false
var life: float = 0.0
var _scale: float = 1.0
## Half extents across the tip axis: level (a) and up its own frame (b).
var _a: float = 0.01
var _b: float = 0.01


## Knocks over the prop that stands at xf with local bounds bb: pushed at world point `at`, it
## flies off at the level velocity fly (u/s).
func launch(xf: Transform3D, bb: AABB, at: Vector3, fly: Vector3) -> void:
	start = xf
	_scale = xf.basis.get_scale().x
	yaw = atan2(xf.basis.z.x, xf.basis.z.z)
	centre = bb.get_center() * _scale
	half = bb.size * (0.5 * _scale)
	pos = xf * bb.get_center()
	vel = Vector3.ZERO
	yaw_rate = 0.0
	angle = 0.0
	rate = 0.0
	# Its top falls along the push, about the level axis of its own frame most nearly across it;
	# a long prop falls over a long side.
	var f := Basis(Vector3.UP, -yaw) * Vector3(fly.x, 0.0, fly.z)
	var over_z := absf(f.z) >= absf(f.x)
	if half.x > half.z * LONG or half.z > half.x * LONG:
		over_z = half.x > half.z
	if over_z:
		axis = Vector3.RIGHT * (1.0 if f.z >= 0.0 else -1.0)
		_a = half.z
	else:
		axis = Vector3.BACK * (-1.0 if f.x >= 0.0 else 1.0)
		_a = half.x
	_b = half.y
	kick(at, fly)
	rate = maxf(rate, TIP_MIN)


## Hits the prop (again, as it lies or tumbles): pushed at world point `at`, it gets the level
## velocity fly (u/s) on top of its own, leaves the ground, tips on when the push runs along its
## tip and spins when the push is off-centre.
func kick(at: Vector3, fly: Vector3) -> void:
	var level := Vector3(fly.x, 0.0, fly.z)
	var speed := level.length()
	var mps := speed / WS.M
	vel += level + Vector3.UP * (speed * LIFT)
	var along := signf(axis.cross(Vector3.UP).dot(Basis(Vector3.UP, -yaw) * level))
	var tip := minf(TIP * mps / maxf(half.y * 2.0 / WS.M, 0.3), TIP_MAX)
	rate = clampf(rate + along * tip, -TIP_MAX, TIP_MAX)
	var turn := Vector3(at.x - pos.x, 0.0, at.z - pos.z).cross(level).y
	yaw_rate += signf(turn) * minf(SPIN * mps, SPIN_MAX)
	grounded = false
	flat = false
	resting = false
	life = 0.0


## Moves the prop on by dt over the ground floor_at(p: Vector3) -> float (NAN reads as the datum),
## bouncing off what blocked(p: Vector3, radius: float, height: float) -> bool finds in the way
## of its box standing at p. False once it rests.
func step(dt: float, floor_at: Callable, blocked: Callable) -> bool:
	if resting:
		return false
	life += dt
	var was := grounded
	vel.y -= GRAVITY * dt
	_slide(dt, blocked)
	pos.y += vel.y * dt
	yaw = wrapf(yaw + yaw_rate * dt, -PI, PI)
	var d0 := drop()
	_tip(dt)
	var g := float(floor_at.call(pos)) if floor_at.is_valid() else WS.GROUND_Y
	if is_nan(g):
		g = WS.GROUND_Y
	var low := pos.y - drop()
	# On the ground it keeps its edge there as it pivots toward a face, which lowers its centre
	# faster than gravity would; ground that falls away (a curb) drops it. Thrown up, it rises
	# off the edge it tips over.
	var stick := was and vel.y <= 0.0 and low - g <= maxf(d0 - drop(), 0.0) + 1e-5
	if low < g or stick:
		pos.y += g - low
	grounded = (low <= g + 1e-6 or stick) and vel.y <= 0.0
	if grounded:
		if not was:
			_land()
		else:
			vel.y = 0.0
		_rub(dt)
	if life >= MAX_LIFE or (grounded and flat and _slow()):
		_rest(g)
	return not resting


## The prop's frame now (scale included), for drawing.
func xform() -> Transform3D:
	var r := Basis(Vector3.UP, yaw) * Basis(axis, angle)
	return Transform3D(r * Basis.from_scale(Vector3.ONE * _scale), pos - r * centre)


## Height of the box's centre above its lowest point.
func drop() -> float:
	return _drop_at(angle)


func _drop_at(t: float) -> float:
	return _b * absf(cos(t)) + _a * absf(sin(t))


## The level move, along x and then along z: a wall in the way sends that part of the velocity
## back. A box that starts in something moves freely until it is out.
func _slide(dt: float, blocked: Callable) -> void:
	var feet := pos.y - drop()
	var r := maxf(minf(half.x, half.z) * 0.5, 0.002)
	var h := drop() * 2.0
	var check := blocked.is_valid() and not bool(blocked.call(Vector3(pos.x, feet, pos.z), r, h))
	for k in range(2):
		var d := (vel.x if k == 0 else vel.z) * dt
		if d == 0.0:
			continue
		var to := pos + (Vector3(d, 0.0, 0.0) if k == 0 else Vector3(0.0, 0.0, d))
		if check and bool(blocked.call(Vector3(to.x, feet, to.z), r, h)):
			if k == 0:
				vel.x *= -WALL_BOUNCE
			else:
				vel.z *= -WALL_BOUNCE
			yaw_rate *= 0.5
		else:
			pos = to


## The tip: free in the air. On the ground the box pivots on an edge, trading height for tip rate,
## falls toward the next face and slams down on it, lying there or rolling on over it when it
## comes down hard; short of the energy to get over an edge it rocks back.
func _tip(dt: float) -> void:
	if not grounded:
		angle += rate * dt
		return
	if flat:
		return
	var q := PI * 0.5
	if rate == 0.0:
		if absf(angle - roundf(angle / q) * q) < 1e-4:
			flat = true
			return
		rate = ROCK if _past_edge() else -ROCK
	var next := angle + rate * dt
	var w2 := rate * rate - 1.5 * GRAVITY * (_drop_at(next) - drop()) / (_a * _a + _b * _b)
	if w2 <= 0.0:
		rate = -signf(rate) * ROCK
		return
	var dir := signf(rate)
	rate = dir * sqrt(w2)
	# The next face it falls toward, past the one it may lie on now.
	var face := (floorf(angle / q + 1e-6) + 1.0) * q
	if dir < 0.0:
		face = (ceilf(angle / q - 1e-6) - 1.0) * q
	if (next - face) * dir < 0.0:
		angle = next
	elif absf(rate) > ROLL_ON:
		rate *= ROLL_KEEP
		angle = next
	else:
		angle = face
		rate = 0.0
		flat = true


## True when the box's centre has passed the edge it pivots on, toward the next face up.
func _past_edge() -> bool:
	var q := PI * 0.5
	var k := floorf(angle / q)
	var edge := atan2(_a, _b) if posmod(int(k), 2) == 0 else atan2(_b, _a)
	return angle - k * q > edge


## Touching down: a hard landing bounces, and every landing takes some of the spin.
func _land() -> void:
	vel.y = -vel.y * BOUNCE if -vel.y > BOUNCE_MIN else 0.0
	rate *= LAND_SPIN
	yaw_rate *= LAND_SPIN


## Ground friction on its slide and its spin.
func _rub(dt: float) -> void:
	var v := Vector2(vel.x, vel.z).move_toward(Vector2.ZERO, FRICTION * GRAVITY * dt)
	vel.x = v.x
	vel.z = v.y
	yaw_rate = move_toward(yaw_rate, 0.0, SPIN_BRAKE * dt)


func _slow() -> bool:
	return Vector2(vel.x, vel.z).length() < REST_SPEED and absf(yaw_rate) < REST_SPIN


## At rest on the face nearest its tip, on the ground at g.
func _rest(g: float) -> void:
	angle = roundf(angle / (PI * 0.5)) * PI * 0.5
	rate = 0.0
	flat = true
	vel = Vector3.ZERO
	yaw_rate = 0.0
	pos.y = g + drop()
	grounded = true
	resting = true
