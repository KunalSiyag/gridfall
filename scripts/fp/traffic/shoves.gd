extends RefCounted
## Cars the player's car knocks (slice E): a hit car slides off with the momentum it was given and
## spins, braking on its tyres, and stops against walls and other cars. A lane car brakes hard on
## its lane (stunned, brake lights on) while its body slides off it as a drawn offset; after a
## pause, longer the harder it was hit, its driver steers the body back onto the lane and drives
## on. Parked cars and the cars the player left move for good, riding up onto a curb they are
## knocked over. While a knocked car stands off its lane or its parking slot it is a block for lane
## traffic, like the player's car; a parked car left in the way is put back in its slot (towed)
## once it has stood out of sight for a while. A car the player lets go of while it moves (an action
## hijack) rolls on (coast), slowing as a car in neutral does, until it stops or hits something.

const WS := preload("res://scripts/fp/world_scale.gd")
const OBB := preload("res://scripts/fp/obb2d.gd")
const BC := preload("res://scripts/fp/body_contacts.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")

## Sliding tyres brake a knocked body at this rate (about 0.7 g) and its spin at SPIN_BRAKE (1/s);
## a spin below MIN_SPIN (rad/s) stops.
const SLIDE_BRAKE := 6.9 * WS.M
const SPIN_BRAKE := 4.0
const MIN_SPIN := 0.02
## A coasting car rolls on its tyres instead, slowing by ROLL_BRAKE plus ROLL_DRAG per u/s of speed
## (the player's car coasting, drive_model.gd).
const ROLL_BRAKE := 0.6 * WS.M
const ROLL_DRAG := 0.12
## A knocked lane car waits this long once its body stops, plus HOLD_PER_MPS for every m/s the hit
## gave it, at most HOLD_MAX (s).
const HOLD := 2.5
const HOLD_PER_MPS := 0.5
const HOLD_MAX := 12.0
## Then its body steers back onto the lane at this speed (u/s) and turn rate (rad/s), the car
## staying stunned at least STUN_MIN (s) at a time until it is back.
const RETURN_SPEED := 1.2 * WS.M
const RETURN_TURN := 0.6
const STUN_MIN := 0.1
## Masses relative to a sedan (the player's car is 1), by kind; a car pulling into a slot does not
## give way (FIXED_MASS).
const MASS := {
	"car": 1.0,
	"bus": 6.0,
	"truck": 4.0,
	"garbage_truck": 5.0,
	"emergency": 1.6,
	"bike": 0.12,
}
const SEDAN_LENGTH := 0.24
const FIXED_MASS := 50.0
## A body off its lane or slot by more than this (u), or turned by more than OFF_TURN (rad),
## blocks lane traffic.
const OFF_BLOCK := 0.3 * WS.M
const OFF_TURN := 0.2
## A move into an overlap deeper than this (u) is refused and the slide stops.
const TOUCH := 0.001
## A parked car knocked into the way is towed back to its slot after standing this long (s) out of
## sight.
const TOW_AFTER := 30.0


class Shove:
	extends RefCounted
	var car: VH.Car
	var vel := Vector2.ZERO  # slide (u/s)
	var spin: float = 0.0  # rad/s
	var off := Vector2.ZERO  # a lane car's drawn offset from its lane pose
	var turn: float = 0.0  # and its drawn yaw offset
	var hold: float = 0.0  # s a lane car waits once stopped
	var lane: bool = false
	var roll: bool = false  # coasting on its tyres (coast), not sliding


var vehicles: VH
var collision: CollisionWorld
## (p: Vector3) -> bool, true when p could be on screen (no towing in sight); unset: never.
var visible: Callable
## Car id -> Shove while a knocked car slides or finds its way back to its lane.
var _shoves: Dictionary = {}
## Car id -> Car for parked cars knocked out of their slot, and id -> seconds each has stood still.
var _moved: Dictionary = {}
var _still_t: Dictionary = {}


func setup(p_vehicles: VH, p_collision: CollisionWorld) -> void:
	vehicles = p_vehicles
	collision = p_collision
	clear()


func clear() -> void:
	for s: Shove in _shoves.values():
		s.car.stun_t = 0.0
	_shoves.clear()
	_moved.clear()
	_still_t.clear()


## Mass of c relative to a sedan.
static func mass_of(c: VH.Car) -> float:
	if c.mass > 0.0:
		return c.mass
	var m := float(MASS.get(c.kind, 1.0))
	return m * c.length / SEDAN_LENGTH if c.kind == "car" else m


## The velocity of c's body now (u/s, xz): its lane motion plus its slide.
func body_vel(c: VH.Car) -> Vector2:
	var v := Vector2(c.vel.x, c.vel.z)
	var s: Shove = _shoves.get(c.id)
	return v + s.vel if s != null else v


## True while c slides or makes its way back to its lane.
func is_shoved(c: VH.Car) -> bool:
	return _shoves.has(c.id)


## The player's car hit c with impulse j (u/s times a sedan's mass) at xz point `at`: c's body
## takes the change in velocity and spin. A lane car keeps what it can of the part along its
## heading as lane speed (it never rolls back along its lane) and slides off with the rest.
func bump(c: VH.Car, j: Vector2, at: Vector2) -> void:
	if c.dead or c.driven or c.far or c.park_t >= 0.0:
		return
	var m := mass_of(c)
	var ctr := Vector2(c.pos.x + c.vis_off.x, c.pos.z + c.vis_off.z)
	var dv := j / m
	var s: Shove = _shoves.get(c.id)
	if s == null:
		s = Shove.new()
		s.car = c
		s.lane = not c.parked and c.role != VH.PLAYER and c.lane != null
		s.off = Vector2(c.vis_off.x, c.vis_off.z)
		s.turn = c.vis_yaw
		_shoves[c.id] = s
	if s.lane:
		var h := OBB.heading(c.yaw)
		var v1 := maxf(0.0, c.v + dv.dot(h))
		dv -= h * (v1 - c.v)
		c.v = v1
		c.vel = Vector3(h.x, 0.0, h.y) * v1
		var hard := HOLD + HOLD_PER_MPS * (j.length() / m) / WS.M
		s.hold = clampf(maxf(s.hold, hard), HOLD, HOLD_MAX)
		c.stun_t = maxf(c.stun_t, s.hold)
	s.vel += dv
	s.spin += _cross(at - ctr, j) / OBB.box_inertia(Vector2(c.half_w, c.length * 0.5), m)


## Car c, let go of at velocity vel (u/s, xz) with nobody at the wheel, rolls on along it, slowing
## as a coasting car does, until it stops or runs into a wall or another car.
func coast(c: VH.Car, vel: Vector2) -> void:
	if c.dead or c.driven or c.far or c.park_t >= 0.0:
		return
	var s := Shove.new()
	s.car = c
	s.vel = vel
	s.roll = true
	_shoves[c.id] = s


## Moves every knocked body on by dt: slides, stops, waits and steers back; tows parked cars
## left in the way out of sight.
func step(dt: float) -> void:
	for id: int in _shoves.keys():
		var s: Shove = _shoves[id]
		var c := s.car
		if c.dead or c.far or c.driven or c.park_t >= 0.0 or (not s.lane and c.lane != null):
			c.stun_t = 0.0
			_shoves.erase(id)
			continue
		_slide(s, dt)
		if s.lane:
			if _back(s, dt):
				_shoves.erase(id)
		elif s.vel == Vector2.ZERO and s.spin == 0.0:
			_shoves.erase(id)
	for id: int in _moved.keys():
		var c: VH.Car = _moved[id]
		if c.dead or not c.parked or c.slot_tile < 0:
			_moved.erase(id)
			_still_t.erase(id)
		elif not _shoves.has(id):
			_still_t[id] = float(_still_t.get(id, 0.0)) + dt
			if float(_still_t[id]) > TOW_AFTER and _off_slot(c) and not _seen(c):
				vehicles.park_at(c, c.slot_tile, c.slot_k)
				_moved.erase(id)
				_still_t.erase(id)


## Tows every parked car standing off its slot back to its slot now: the save path settles the
## parked table (S0 §6.4) and cannot wait the TOW_AFTER standstill step() needs, so it tows in
## sight too — the live world and the saved slot table must agree at the instant of the save.
func settle_parked() -> void:
	for id: int in _moved.keys():
		var c: VH.Car = _moved[id]
		_shoves.erase(id)
		_moved.erase(id)
		_still_t.erase(id)
		if c.dead or not c.parked or c.slot_tile < 0:
			continue
		c.stun_t = 0.0
		if _off_slot(c):
			vehicles.park_at(c, c.slot_tile, c.slot_k)


## Lane blocks for vehicles.gd (_gather_blocks): [xz centre, heading, half length, half width, xz
## velocity, car id] of every knocked lane car off its lane and every parked car knocked out of
## its slot (the player's own cars are blocks already).
func blocks() -> Array:
	var out: Array = []
	for s: Shove in _shoves.values():
		if s.lane and (s.off.length() > OFF_BLOCK or absf(s.turn) > OFF_TURN):
			out.append(_block(s.car))
	for c: VH.Car in _moved.values():
		if _off_slot(c):
			out.append(_block(c))
	return out


func _block(c: VH.Car) -> Array:
	var q := c.pos + c.vis_off
	return [
		Vector2(q.x, q.z),
		OBB.heading(c.yaw + c.vis_yaw),
		c.length * 0.5,
		c.half_w,
		body_vel(c),
		c.id,
	]


## True when parked car c stands off its slot's pose.
func _off_slot(c: VH.Car) -> bool:
	if c.slot_tile < 0:
		return false
	var pose: Array = vehicles.lg.slot_pose(c.slot_tile, c.slot_k)
	var h: Vector2 = pose[1]
	var off := Vector2(c.pos.x, c.pos.z).distance_to(pose[0])
	return off > OFF_BLOCK or absf(angle_difference(c.yaw, atan2(h.x, h.y))) > OFF_TURN


func _seen(c: VH.Car) -> bool:
	return visible.is_valid() and bool(visible.call(c.pos))


## One step of s's slide, unless it would run into a wall or another car (then it stops there).
func _slide(s: Shove, dt: float) -> void:
	if s.vel == Vector2.ZERO and s.spin == 0.0:
		return
	var c := s.car
	var d := s.vel * dt
	var dy := s.spin * dt
	if not _free(c, d, dy):
		s.vel = Vector2.ZERO
		s.spin = 0.0
		return
	if s.lane:
		s.off += d
		s.turn = wrapf(s.turn + dy, -PI, PI)
		_pose_lane(s)
	else:
		var q := Vector2(c.pos.x, c.pos.z) + d
		c.pos = Vector3(q.x, _ground(c, q), q.y)
		c.yaw = wrapf(c.yaw + dy, -PI, PI)
		if s.roll:
			c.wheel_spin += d.dot(OBB.heading(c.yaw))
		if c.parked:
			_moved[c.id] = c
			_still_t[c.id] = 0.0
			vehicles.parked_version += 1
	var brake := ROLL_BRAKE + ROLL_DRAG * s.vel.length() if s.roll else SLIDE_BRAKE
	s.vel = s.vel.move_toward(Vector2.ZERO, brake * dt)
	s.spin *= exp(-SPIN_BRAKE * dt)
	if absf(s.spin) < MIN_SPIN:
		s.spin = 0.0


## A lane car once its body stopped: waits, then steers its body back onto the lane. True when it
## is back and drives on.
func _back(s: Shove, dt: float) -> bool:
	var c := s.car
	if s.vel != Vector2.ZERO or s.spin != 0.0:
		c.stun_t = maxf(c.stun_t, s.hold)
		return false
	if s.hold > 0.0:
		s.hold = maxf(0.0, s.hold - dt)
	else:
		var to := s.off.move_toward(Vector2.ZERO, RETURN_SPEED * dt)
		var tt := move_toward(s.turn, 0.0, RETURN_TURN * dt)
		if _free(c, to - s.off, tt - s.turn):
			s.off = to
			s.turn = tt
	_pose_lane(s)
	if s.hold <= 0.0 and s.off == Vector2.ZERO and s.turn == 0.0:
		c.stun_t = 0.0
		return true
	c.stun_t = maxf(s.hold, STUN_MIN)
	return false


## Draws a lane car's body at its offset from its lane pose.
func _pose_lane(s: Shove) -> void:
	var c := s.car
	var q := Vector2(c.pos.x, c.pos.z) + s.off
	c.vis_off = Vector3(s.off.x, _ground(c, q) - c.pos.y, s.off.y)
	c.vis_yaw = s.turn


## The ground height under xz point q for c's body: walk_height() within a step of the road it
## stands on, else that road.
func _ground(c: VH.Car, q: Vector2) -> float:
	var base := c.pos.y
	if collision == null:
		return base
	var g := collision.walk_height(Vector3(q.x, base, q.y))
	return base if is_nan(g) or absf(g - base) > WS.STEP_HEIGHT else g


## True when c's body, moved by d and turned by dy, goes no deeper into walls, posts, water or
## other vehicles than it already is.
func _free(c: VH.Car, d: Vector2, dy: float) -> bool:
	var q := c.pos + c.vis_off
	var c0 := Vector2(q.x, q.z)
	var y0 := c.yaw + c.vis_yaw
	var h := Vector2(c.half_w, c.length * 0.5)
	return _depth(c, c0 + d, y0 + dy, h) <= maxf(_depth(c, c0, y0, h), TOUCH)


## The deepest overlap of c's body at centre p, yaw y, with the world and the other vehicles.
func _depth(c: VH.Car, p: Vector2, y: float, h: Vector2) -> float:
	var deep := 0.0
	var feet := c.pos.y + c.vis_off.y
	if collision != null:
		var obs := BC.gather(collision, p, h.length() + 0.02, feet, c.height)
		for k: Array in BC.contacts(collision, obs, p, y, h, feet):
			deep = maxf(deep, float(k[1]))
	var u := OBB.side_axis(y)
	var v := OBB.heading(y)
	for o: VH.Car in vehicles.cars:
		if o == c or o.dead or o.far or (o.parked and o.slot_tile < 0):
			continue
		var oq := o.pos + o.vis_off
		var oc := Vector2(oq.x, oq.z)
		var ho := Vector2(o.half_w, o.length * 0.5)
		if oc.distance_to(p) > h.length() + ho.length():
			continue
		var oy := o.yaw + o.vis_yaw
		var k := OBB.box_box(p, u, v, h, oc, OBB.side_axis(oy), OBB.heading(oy), ho)
		if not k.is_empty():
			deep = maxf(deep, float(k[1]))
	return deep


## Yaw an impulse j at offset r gives a body, times its inertia (car_body.gd's convention).
static func _cross(r: Vector2, j: Vector2) -> float:
	return r.y * j.x - r.x * j.y
