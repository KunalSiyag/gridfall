extends RefCounted
## The hero on a wall (the parkour feature's wall climb; wall.gd finds walls and the spots on
## them): the leap from the ground onto the wall, then up, down and along it at climbing pace,
## never past its ends, over its top or into anything in the way. The hands and feet hold on to
## the wall and move one at a time as the body goes: the one furthest behind its rest swings to a
## hold ahead of it, arcing off the wall. step() tells the feature when the body is at the top
## with up held, at the foot of the wall with down held, or when the wall is gone. Lengths are
## world units.

const WS := preload("res://scripts/fp/world_scale.gd")
const WALL := preload("res://scripts/fp/parkour/wall.gd")

## Climbing pace (u/s): up, down and along the wall; FAST times that with sprint held.
const UP := 0.6 * WS.M
const DOWN := 0.8 * WS.M
const ALONG := 0.6 * WS.M
const FAST := 1.6
## Input under DEAD on an axis counts as none.
const DEAD := 0.25
## The leap onto the wall takes LEAP (s).
const LEAP := 0.3
## A limb moves STRIDE (STRIDE_ALONG along the wall) every four swings, one limb swinging while
## the body moves a quarter of that. It swings once it is SWING_LAG of a stride behind its rest,
## to LEAD of a stride ahead of it, coming ARC off the wall halfway; a swing still going when the
## body stops lands in SETTLE (s).
const STRIDE := 0.56 * WS.M
const STRIDE_ALONG := 0.4 * WS.M
const SWING_LAG := 0.25
const LEAD := 0.625
const ARC := 0.06 * WS.M
const SETTLE := 0.15
## The first holds, in strides above rest: on the way up the right hand swings first, then the
## left foot, the left hand and the right foot.
const FIRST := [0.125, -0.375, -0.125, 0.375]
## Hands hold at most EDGE under the top, feet at least FOOT_MIN over the ground.
const EDGE := 0.03 * WS.M
const FOOT_MIN := 0.1 * WS.M

## The wall (wall.gd's frame) and the body's spot on it: a along it, y the feet.
var wall: Dictionary
var a: float
var y: float
## How high the wall stands where the body is, and the ground under it.
var top: float
var ground: float
## The body's velocity over the last step (u/s).
var velocity: Vector3 = Vector3.ZERO
## Each limb's hold (a, y): left hand, right hand, left foot, right foot.
var holds: Array[Vector2] = []
## The limb swinging (-1 for none) and the swings so far.
var swing: int = -1
var swings: int = 0
var _swing_t: float = 0.0
var _swing_from: Vector2 = Vector2.ZERO
var _swing_to: Vector2 = Vector2.ZERO
var _col: CollisionWorld
var _from: Vector3
var _leap_t: float = 0.0


## On the wall w (wall.grab()'s answer) after a leap from the feet at from.
func _init(col: CollisionWorld, w: Dictionary, from: Vector3) -> void:
	_col = col
	wall = w
	a = float(w["a"])
	y = float(w["y"])
	top = float(w["top"])
	var g := WALL.ground_at(col, w, a, y)
	ground = from.y if is_nan(g) else g
	_from = from
	for i in range(WALL.REST.size()):
		holds.append(_clamp_hold(i, _rest(i) + Vector2(0.0, float(FIRST[i]) * STRIDE)))


## True once the leap is over and the body hangs on the wall.
func on_wall() -> bool:
	return _leap_t >= LEAP


## Where the feet are: on the way up during the leap, then on the wall.
func feet() -> Vector3:
	var at := WALL.point(wall, a, y, WALL.R)
	if on_wall():
		return at
	var k := _leap_t / LEAP
	var p := _from.lerp(at, k)
	p.y = lerpf(_from.y, at.y, 1.0 - (1.0 - k) * (1.0 - k))
	return p


## The body yaw facing the wall (radians).
func yaw() -> float:
	return WALL.yaw(wall)


## One step of dt (s): the leap goes on, or the body climbs along wish (x along the wall to the
## right, y up; each -1..1), faster with fast, and the limbs follow. "" while it hangs on, "top"
## at the top with up held, "foot" at the foot of the wall with down held, "lost" when the wall it
## hangs on is gone.
func step(dt: float, wish: Vector2, fast: bool) -> String:
	var h := maxf(dt, 0.0)
	var before := feet()
	if not on_wall():
		_leap_t = minf(_leap_t + h, LEAP)
		velocity = (feet() - before) / dt if dt > 0.0 else Vector3.ZERO
		return ""
	var boxes := _col.boxes_near(before, WALL.NEAR)
	if not WALL.hang_ok(_col, boxes, wall, a, y):
		return "lost"
	var up := _axis(wish.y)
	var rate := Vector2(_axis(wish.x) * ALONG, up * (UP if up > 0.0 else DOWN))
	var moved := _move(boxes, rate * (FAST if fast else 1.0) * h)
	velocity = (feet() - before) / dt if dt > 0.0 else Vector3.ZERO
	_gait(moved, h)
	if up > 0.0 and y >= top - WALL.GRIP - 1e-6:
		return "top"
	if up < 0.0 and y <= ground + 1e-6:
		return "foot"
	return ""


## Limb i's target and pole (world points) and how much it holds on (0..1; the feet come to the
## wall over the leap): [target, pole, weight]. The swinging limb is on its way, off the wall.
func limb(i: int) -> Array:
	var h := holds[i]
	var off: float = (WALL.REST[i] as Vector3).z
	if i == swing:
		var k := clampf(_swing_t, 0.0, 1.0)
		h = _swing_from.lerp(_swing_to, smoothstep(0.0, 1.0, k))
		off += ARC * sin(PI * k)
	var pole: Vector3 = WALL.POLES[i]
	var w := 1.0 if i < 2 or on_wall() else smoothstep(0.0, 1.0, _leap_t / LEAP)
	return [WALL.point(wall, h.x, h.y, off), WALL.point(wall, a + pole.x, y + pole.y, pole.z), w]


## Moves the body by want (along, up) as far as the wall lets it: all of it, else along or up
## alone, else not at all; it climbs no higher than the top allows and no lower than the ground.
## The move made.
func _move(boxes: Array[AABB], want: Vector2) -> Vector2:
	for m: Vector2 in [want, Vector2(want.x, 0.0), Vector2(0.0, want.y)]:
		if m.length_squared() < 1e-14:
			continue
		var na := a + m.x
		var t := WALL.top_at(boxes, wall, na, y + WALL.LOW)
		var g := WALL.ground_at(_col, wall, na, y)
		if is_nan(t) or is_nan(g):
			continue
		var ny := clampf(y + m.y, g, maxf(t - WALL.GRIP, g))
		# Along into a lower stretch of wall or over higher ground would jerk the body up or down.
		if (ny - y) * signf(m.y) < -1e-9 or (m.y == 0.0 and absf(ny - y) > 1e-9):
			continue
		if WALL.hang_ok(_col, boxes, wall, na, ny):
			var made := Vector2(na - a, ny - y)
			a = na
			y = ny
			top = t
			ground = g
			return made
	return Vector2.ZERO


## The limbs after the body moved by moved (along, up) in dt: the swing under way goes on with the
## distance moved (or settles when the body stopped) and lands; then the limb furthest behind its
## rest along the way the body goes swings to a hold ahead of it.
func _gait(moved: Vector2, dt: float) -> void:
	var dist := moved.length()
	if swing >= 0:
		_swing_t += dist / (_stride(moved) * 0.25) if dist > 1e-9 else dt / SETTLE
		if _swing_t >= 1.0:
			holds[swing] = _swing_to
			swing = -1
	if swing >= 0 or dist <= 1e-9:
		return
	var d := moved / dist
	var stride := _stride(d)
	var best := -1
	var most := SWING_LAG * stride
	for i in range(holds.size()):
		var lag := (_clamp_hold(i, _rest(i)) - holds[i]).dot(d)
		if lag > most:
			most = lag
			best = i
	if best < 0:
		return
	swing = best
	swings += 1
	_swing_t = 0.0
	_swing_from = holds[best]
	_swing_to = _clamp_hold(best, _rest(best) + d * stride * LEAD)


## A limb's stride for a move along d: STRIDE up or down, STRIDE_ALONG along the wall.
func _stride(d: Vector2) -> float:
	return lerpf(STRIDE, STRIDE_ALONG, absf(d.normalized().x))


## Limb i's rest (a, y) with the body where it is.
func _rest(i: int) -> Vector2:
	var r: Vector3 = WALL.REST[i]
	return Vector2(a + r.x, y + r.y)


## Hands under the top, feet over the ground.
func _clamp_hold(i: int, h: Vector2) -> Vector2:
	if i < 2:
		return Vector2(h.x, minf(h.y, top - EDGE))
	return Vector2(h.x, maxf(h.y, ground + FOOT_MIN))


static func _axis(v: float) -> float:
	return 0.0 if absf(v) < DEAD else clampf(v, -1.0, 1.0)
