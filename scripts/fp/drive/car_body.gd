extends RefCounted
## The player's car as a rigid box on the ground plane. Each step it moves by the handling model's
## velocity in short substeps and resolves its contacts, deepest first: walls, posts and water
## edges (body_contacts.gd), other vehicles (traffic's bodies_near, pushed through bump_car) and
## street props (the props feature knocks them over when hit hard enough, else they stand firm).
## People on foot are struck through traffic's hit_walker and barely slow the car.
## A contact pushes the body out and, while closing, gives an impulse at the contact point, so the
## car bounces a little off what it hits head-on, slides along what it hits at a glance and spins
## when it is hit off-centre. Dynamic boxes (stopped cars listed for the walker) are not used: the
## vehicles themselves are.

const WS := preload("res://scripts/fp/world_scale.gd")
const OBB := preload("res://scripts/fp/obb2d.gd")
const BC := preload("res://scripts/fp/body_contacts.gd")
const MODEL := preload("res://scripts/fp/drive/drive_model.gd")

## Share of the closing speed the car bounces back with; contacts closing slower than REST_SPEED
## do not bounce (a car pushed against a wall rests on it).
const RESTITUTION := 0.25
const REST_SPEED := 1.0 * WS.M
## Bounce off a street prop as it is knocked away.
const PROP_BOUNCE := 0.1
## Friction along a contact: a car scraping a wall loses some speed but keeps sliding.
const FRICTION := 0.3
## A substep moves at most this share of the half width, or turns at most TURN_STEP (rad).
const SUBSTEP := 0.5
const TURN_STEP := 0.08
## Contacts resolved per substep.
const ITERATIONS := 4
## The most one contact pushes the body out at once (u, at least a substep's travel): a car that
## starts overlapping something eases out instead of jumping.
const MAX_PUSH := 0.02
## Mass of the player's car; other bodies are given relative to a sedan (1.0).
const MASS := 1.0
## Hits closing faster than this are listed in hits.
const IMPACT_SPEED := 1.5 * WS.M
## People: a body this wide (u) is struck when the car closes on them faster than PERSON_SPEED,
## each at most once per PERSON_COOL seconds, as hard as the closing speed over PERSON_FULL (1
## knocks anyone down). They weigh PERSON_MASS of a sedan, so the car loses little speed.
const PERSON_R := 0.3 * WS.M
const PERSON_SPEED := 0.5 * WS.M
const PERSON_FULL := 12.0 * WS.M
const PERSON_COOL := 1.5
const PERSON_MASS := 0.08

## Half width and half length (u), and height.
var half := Vector2(0.045, 0.12)
var height: float = 0.075
var inertia: float = OBB.box_inertia(Vector2(0.045, 0.12), MASS)
## The last move's hits closing faster than IMPACT_SPEED: [point Vector2, speed (u/s), what],
## what "wall" (anything fixed), "car", "prop" or "person".
var hits: Array = []
var _c := Vector2.ZERO
var _feet: float = 0.0
var _omega: float = 0.0
var _push: float = MAX_PUSH
var _reach: float = 0.0
var _col: CollisionWorld
var _traffic: Object
var _props: Object
var _obs: Dictionary = {}
var _cars: Array = []
var _knock: Array = []
var _people: Array = []
## Walker id -> _clock when the car last struck them.
var _struck: Dictionary = {}
var _clock: float = 0.0


func setup(half_w: float, length: float, p_height: float) -> void:
	half = Vector2(half_w, length * 0.5)
	height = p_height
	inertia = OBB.box_inertia(half, MASS)


## Moves the body from the feet position pos by the model's velocity over dt (the model's yaw has
## already turned from yaw0 this step), resolving contacts on the way; the model's velocity and
## spin take the impulses. traffic and props are those features, or null. Returns the new feet
## position with y unchanged.
func move(
	model: MODEL,
	pos: Vector3,
	yaw0: float,
	dt: float,
	col: CollisionWorld,
	traffic: Object,
	props: Object
) -> Vector3:
	hits.clear()
	_clock += dt
	_col = col
	_traffic = traffic if traffic != null and traffic.has_method("bump_car") else null
	_props = props if props != null and props.has_method("knock") else null
	_c = Vector2(pos.x, pos.z)
	_feet = pos.y
	var turn := angle_difference(yaw0, model.yaw)
	var travel := model.vel.length() * dt
	var n := maxi(1, ceili(maxf(travel / (half.x * SUBSTEP), absf(turn) / TURN_STEP)))
	_push = maxf(MAX_PUSH, travel / float(n) * 1.5)
	_reach = half.length() + travel + 0.05
	_omega = turn / dt
	_gather(pos)
	for k in range(n):
		model.yaw = wrapf(yaw0 + turn * float(k + 1) / float(n), -PI, PI)
		_c += model.vel * (dt / float(n))
		for _it in range(ITERATIONS):
			if not _resolve(model):
				break
		_strike_people(model)
	_col = null
	_traffic = null
	_props = null
	_cars = []
	_knock = []
	_people = []
	return Vector3(_c.x, pos.y, _c.y)


func _gather(pos: Vector3) -> void:
	_obs = BC.gather(_col, _c, _reach, _feet, height)
	_cars = _traffic.call("bodies_near", pos, _reach + 0.2) if _traffic != null else []
	_knock = _props.call("knockables_near", pos, _reach) if _props != null else []
	_people = []
	if _traffic != null and _traffic.has_method("walkers_near"):
		_people = _traffic.call("walkers_near", pos, _reach + PERSON_R)
	for id: int in _struck.keys():
		if _clock - float(_struck[id]) > PERSON_COOL:
			_struck.erase(id)


## Resolves the deepest contact of the body as it stands; false when it touches nothing.
func _resolve(model: MODEL) -> bool:
	var u := OBB.side_axis(model.yaw)
	var v := OBB.heading(model.yaw)
	if _knock_props(model, u, v):
		return true
	var best: Array = []
	var other: Array = []
	for hit: Array in BC.contacts(_col, _obs, _c, model.yaw, half, _feet):
		if best.is_empty() or float(hit[1]) > float(best[1]):
			best = hit
	for car: Array in _cars:
		var hit := _car_contact(car, u, v)
		if not hit.is_empty() and (best.is_empty() or float(hit[1]) > float(best[1])):
			best = hit
			other = car
	if best.is_empty():
		return false
	var nrm: Vector2 = best[0]
	var p: Vector2 = best[2]
	_c += nrm * minf(float(best[1]), _push)
	if other.is_empty():
		_impulse(model, nrm, p, Vector2.ZERO, Vector2.ZERO, 0.0, 0.0, "wall")
		return true
	var mb := float(other[5])
	var ib := 1.0 / OBB.box_inertia(other[3], mb)
	var cb: Vector2 = other[1]
	var j := _impulse(model, nrm, p, other[4], p - cb, 1.0 / mb, ib, "car")
	if j != Vector2.ZERO:
		other[4] = (other[4] as Vector2) - j / mb
		_traffic.call("bump_car", int(other[0]), -j, p)
	return true


## Contact with vehicle `car` ([id, centre, yaw, half extents, velocity, mass]), or [].
func _car_contact(car: Array, u: Vector2, v: Vector2) -> Array:
	var cb: Vector2 = car[1]
	var hb: Vector2 = car[3]
	var reach := half.length() + hb.length()
	if cb.distance_squared_to(_c) > reach * reach:
		return []
	var yb := float(car[2])
	return OBB.box_box(_c, u, v, half, cb, OBB.side_axis(yb), OBB.heading(yb), hb)


## Applies a contact's impulse (normal nrm pushing the car out, at point p) against a body moving
## at vb, p - its centre = rb, with inverse mass im and inverse inertia ii (0, 0: fixed). Returns
## the impulse on the car (the other body takes its opposite); none while they separate.
func _impulse(
	model: MODEL,
	nrm: Vector2,
	p: Vector2,
	vb: Vector2,
	rb: Vector2,
	im: float,
	ii: float,
	what: String
) -> Vector2:
	var r := p - _c
	var rel := model.vel + _perp(r) * _omega - vb
	var vn := rel.dot(nrm)
	if vn >= 0.0:
		return Vector2.ZERO
	var ra := _cross(r, nrm)
	var rbn := _cross(rb, nrm)
	var k := 1.0 / MASS + im + ra * ra / inertia + rbn * rbn * ii
	var e := RESTITUTION if -vn > REST_SPEED else 0.0
	var jn := -(1.0 + e) * vn / k
	var j := nrm * jn
	var vt := rel - nrm * vn
	var st := vt.length()
	if st > 1e-6:
		var t := vt / st
		var rt := _cross(r, t)
		var rbt := _cross(rb, t)
		var kt := 1.0 / MASS + im + rt * rt / inertia + rbt * rbt * ii
		j -= t * minf(st / kt, FRICTION * jn)
	_apply(model, r, j)
	if -vn > IMPACT_SPEED:
		hits.append([p, -vn, what])
	return j


## Knocks over the first street prop the body runs into hard enough (the props feature decides
## from the speed it would fly off at); true when one fell, and the obstacles are gathered again
## without it. Props that hold stay among the obstacles.
func _knock_props(model: MODEL, u: Vector2, v: Vector2) -> bool:
	for kn: Dictionary in _knock:
		var q: Vector2 = kn["c"]
		var reach := half.length() + float(kn["r"])
		if q.distance_squared_to(_c) > reach * reach:
			continue
		var hit: Array = (
			OBB.box_aabb(_c, u, v, half, kn["box"])
			if kn.has("box")
			else OBB.box_circle(_c, u, v, half, q, float(kn["r"]))
		)
		if hit.is_empty():
			continue
		var nrm: Vector2 = hit[0]
		var p: Vector2 = hit[2]
		var r := p - _c
		var va := model.vel + _perp(r) * _omega
		var vn := va.dot(nrm)
		if vn >= 0.0:
			continue
		var m := float(kn["mass"])
		var ra := _cross(r, nrm)
		var jn := -(1.0 + PROP_BOUNCE) * vn / (1.0 / MASS + 1.0 / m + ra * ra / inertia)
		# The prop flies off along the push, dragged a little along the car's slide.
		var fly := -nrm * (jn / m) + (va - nrm * vn) * 0.5
		var at := Vector3(p.x, _feet, p.y)
		if not bool(
			_props.call("knock", int(kn["tile"]), int(kn["slot"]), at, Vector3(fly.x, 0.0, fly.y))
		):
			continue
		_apply(model, r, nrm * jn)
		if -vn > IMPACT_SPEED:
			hits.append([p, -vn, "prop"])
		_knock.erase(kn)
		_obs = BC.gather(_col, _c, _reach, _feet, height)
		return true
	return false


## Strikes the people the body runs into (traffic's hit_walker, cause "car"): those on their feet
## are knocked down, those already down are trampled where they lie. Each is pushed away from the
## car and gives back the little impulse it takes.
func _strike_people(model: MODEL) -> void:
	if _people.is_empty():
		return
	var u := OBB.side_axis(model.yaw)
	var v := OBB.heading(model.yaw)
	for w: Dictionary in _people:
		var id := int(w["id"])
		if _struck.has(id):
			continue
		var q: Vector3 = w["pos"]
		var hit := OBB.box_circle(_c, u, v, half, Vector2(q.x, q.z), PERSON_R)
		if hit.is_empty():
			continue
		var nrm: Vector2 = hit[0]
		var p: Vector2 = hit[2]
		var vn := (model.vel + _perp(p - _c) * _omega).dot(nrm)
		if -vn < PERSON_SPEED:
			continue
		_struck[id] = _clock
		var push := Vector3(-nrm.x, 0.0, -nrm.y)
		var strength := clampf(-vn / PERSON_FULL, 0.0, 1.0)
		_traffic.call("hit_walker", id, Vector3(p.x, _feet, p.y), push, strength, "car")
		_impulse(model, nrm, p, Vector2.ZERO, Vector2.ZERO, 1.0 / PERSON_MASS, 0.0, "person")


func _apply(model: MODEL, r: Vector2, j: Vector2) -> void:
	model.vel += j / MASS
	var dw := _cross(r, j) / inertia
	model.spin += dw
	_omega += dw


## The velocity direction of a point at offset r from the centre while the body's yaw grows.
static func _perp(r: Vector2) -> Vector2:
	return Vector2(r.y, -r.x)


## Yaw rate an impulse j at offset r gives, times the inertia.
static func _cross(r: Vector2, j: Vector2) -> float:
	return r.y * j.x - r.x * j.y
