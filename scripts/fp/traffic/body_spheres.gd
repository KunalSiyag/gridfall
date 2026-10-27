extends RefCounted
## The posed body's collision points, and the press-out that keeps a knocked-down or thrown
## body out of the geometry its clips sweep it into. of() gives [feet, torso, head] from the
## drawn feet and the head (people.gd head_of -- the posed bone while a body draws it, else the
## standing estimate); a clip that lies the body down puts the head and torso far past whatever
## stopped the feet, so reactions.gd measures all three. press_out() eases the whole drawn body
## along the shallowest way clear whenever a reaction runs.

const WS := preload("res://scripts/fp/world_scale.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const OBB := preload("res://scripts/fp/obb2d.gd")
const BODY_R := 0.25 * WS.M
const HEAD_R := 0.14 * WS.M


## The collision points of the body drawn from feet: [feet, torso, head], the torso between
## them (the last is the head -- whatever rad_of says of it).
static func of(feet: Vector3, head: Vector3) -> Array[Vector3]:
	return [feet, feet.lerp(head, 0.55), head]


## Radius of the k-th sphere of of() (the head and anything past it).
static func rad_of(k: int) -> float:
	return HEAD_R if k >= 2 else BODY_R


## Eases the whole drawn body out of whatever the clips have pressed it into, along the
## shallowest way clear, while a reaction runs. Horizontal only -- the flight keeps its arc.
## However deep, this tick: the sweeps that put the body past its feet (a fall, a get-up fold,
## a flight's tilt) move it faster than any lean could ease, and a capped ease would trail
## 30 cm into a wall by the fold's end. A full correction reads as the body sliding along what
## stopped it; the shallow presses stay as subtle as before. cars holds the moving car bodies
## the static world does not (traffic's near cars as [xz centre, yaw, Vector2(half width, half
## length), y bottom, y top]): a body thrown or slid into a real car comes clear of it the
## same way, or it would lie inside the drawn vehicle with nothing to press it out.
static func press_out(
	w: WK.Walker, extent: Callable, collision: CollisionWorld, cars: Array = []
) -> void:
	if not extent.is_valid() or collision == null:
		return
	var spheres: Array = extent.call(w, w.pos + w.vis_off)
	var depth := 0.0
	var dir := Vector2.ZERO
	for k in range(spheres.size()):
		var q: Vector3 = spheres[k]
		var e := _press_at(q, rad_of(k), spheres[0], collision)
		var c := _press_car(q, rad_of(k), spheres[0], cars)
		if c.x > e.x:
			e = c
		if e.x > depth:
			depth = e.x
			dir = Vector2(e.y, e.z)
	if depth <= 0.0:
		return
	w.vis_off.x += dir.x * depth
	w.vis_off.z += dir.y * depth


## Deepest press of sphere (q, rad) against the movement geometry, and the way clear:
## (depth, dir x, dir z), depth 0 when clear. Boxes first, then the post and trunk cylinders.
## From outside the way clear runs straight back from the shape's closest point; a centre
## inside escapes through the side face its feet came in by (feet are the one part the mover
## keeps outside), never the nearer face -- which would flip to the far one mid-wall and tunnel
## a wall thinner than the sphere. Resting on or hanging under something stays (the way clear
## there is vertical, and the flight's arc never touches y).
static func _press_at(q: Vector3, rad: float, feet: Vector3, collision: CollisionWorld) -> Vector3:
	var best := Vector3.ZERO
	for b: AABB in collision.boxes_near(q, rad + 0.3):
		var c := Vector3(
			clampf(q.x, b.position.x, b.end.x),
			clampf(q.y, b.position.y, b.end.y),
			clampf(q.z, b.position.z, b.end.z)
		)
		var off := q - c
		var e := _press_back(off, rad) if off.length() > 1e-9 else _press_face_box(q, rad, b, feet)
		if e.x > best.x:
			best = e
	var cx := roundi(q.x)
	var cz := roundi(q.z)
	for gz in range(cz - 1, cz + 2):
		for gx in range(cx - 1, cx + 2):
			var cy := collision.cylinders(D.idx(gx, gz))
			for k in range(0, cy.size(), 4):
				var hx := Vector2(q.x - cy[k], q.z - cy[k + 1])
				var l := hx.length()
				var ccx := cy[k] + hx.x / maxf(l, 1e-9) * minf(l, cy[k + 2])
				var ccz := cy[k + 1] + hx.y / maxf(l, 1e-9) * minf(l, cy[k + 2])
				var ccy := clampf(q.y, WS.GROUND_Y, cy[k + 3])
				var off := Vector3(q.x - ccx, q.y - ccy, q.z - ccz)
				var e := (
					_press_back(off, rad)
					if off.length() > 1e-9
					else _press_face_cyl(q, rad, cy[k], cy[k + 1], cy[k + 2], cy[k + 3])
				)
				if e.x > best.x:
					best = e
	return best


## Deepest press of sphere (q, rad) against the moving car bodies, and the way clear:
## (depth, dir x, dir z), depth 0 when clear. A car is its yaw'd rectangle between y bottom and
## y top (its world aabb's span; a body flying over or resting on the roof is clear of it, as
## with the static boxes' faces). A centre inside escapes through the side face its feet came
## in by, never the nearer face, exactly as with the boxes.
static func _press_car(q: Vector3, rad: float, feet: Vector3, cars: Array) -> Vector3:
	var best := Vector3.ZERO
	for b: Array in cars:
		if q.y < float(b[3]) or q.y > float(b[4]):
			continue
		var u := OBB.side_axis(float(b[1]))
		var v := OBB.heading(float(b[1]))
		var h: Vector2 = b[2]
		var d := Vector2(q.x, q.z) - (b[0] as Vector2)
		var lx := d.dot(u)
		var lz := d.dot(v)
		var off := Vector2(lx - clampf(lx, -h.x, h.x), lz - clampf(lz, -h.y, h.y))
		var e := Vector3.ZERO
		if off.length_squared() > 1e-14:
			var dist := off.length()
			if dist < rad:
				var way := (u * off.x + v * off.y) / dist
				e = Vector3(rad - dist, way.x, way.y)
		else:
			e = _press_face_car(feet, rad, b[0], lx, lz, u, v, h)
		if e.x > best.x:
			best = e
	return best


## A centre inside a car's rectangle escapes through the side face its feet came in by, plus the
## radius; the rectangle's own frame (u across, v along, half extents h, centre).
static func _press_face_car(
	feet: Vector3,
	rad: float,
	centre: Vector2,
	lx: float,
	lz: float,
	u: Vector2,
	v: Vector2,
	h: Vector2
) -> Vector3:
	var df := Vector2(feet.x, feet.z) - centre
	var fx := -1.0 if df.dot(u) <= -h.x else (1.0 if df.dot(u) >= h.x else 0.0)
	var fz := -1.0 if df.dot(v) <= -h.y else (1.0 if df.dot(v) >= h.y else 0.0)
	var dx := h.x - absf(lx)
	var dz := h.y - absf(lz)
	if fx == 0.0 and fz == 0.0:
		if dx <= dz:
			fx = -1.0 if lx < 0.0 else 1.0
		else:
			fz = -1.0 if lz < 0.0 else 1.0
	if fx != 0.0 and (fz == 0.0 or dx <= dz):
		return Vector3(dx + rad, u.x * fx, u.y * fx)
	return Vector3(dz + rad, v.x * fz, v.y * fz)


## Back out from a shape's closest point: how deep the sphere reaches past it (0 when clear, and
## when the way clear is straight up or down -- a rest, or hanging under -- which stays).
static func _press_back(off: Vector3, rad: float) -> Vector3:
	var dist := off.length()
	if dist > rad:
		return Vector3.ZERO
	var h := Vector2(off.x, off.z).length()
	if h <= 1e-9:
		return Vector3.ZERO
	return Vector3(rad - dist, off.x / h, off.z / h)


## A centre inside box b escapes through the side face its feet came in by, plus the radius;
## a top or bottom face nearest is a rest, which stays.
static func _press_face_box(q: Vector3, rad: float, b: AABB, feet: Vector3) -> Vector3:
	var dx := minf(q.x - b.position.x, b.end.x - q.x)
	var dy := minf(q.y - b.position.y, b.end.y - q.y)
	var dz := minf(q.z - b.position.z, b.end.z - q.z)
	if dy <= dx and dy <= dz:
		return Vector3.ZERO
	var fx := -1.0 if feet.x <= b.position.x else (1.0 if feet.x >= b.end.x else 0.0)
	var fz := -1.0 if feet.z <= b.position.z else (1.0 if feet.z >= b.end.z else 0.0)
	if fx == 0.0 and fz == 0.0:
		if dx <= dz:
			fx = -1.0 if q.x - b.position.x < b.end.x - q.x else 1.0
		else:
			fz = -1.0 if q.z - b.position.z < b.end.z - q.z else 1.0
	if fx != 0.0 and (fz == 0.0 or dx <= dz):
		return Vector3(dx + rad, fx, 0.0)
	return Vector3(dz + rad, 0.0, fz)


## A centre inside a standing cylinder escapes out radially unless its cap or the ground is the
## nearer way clear (a rest, which stays).
static func _press_face_cyl(
	q: Vector3, rad: float, x: float, z: float, rc: float, top: float
) -> Vector3:
	var hx := Vector2(q.x - x, q.z - z)
	var l := hx.length()
	if l <= 1e-9:
		return Vector3.ZERO
	var out := (rc - l) + rad
	if out > minf(top - q.y, q.y - WS.GROUND_Y):
		return Vector3.ZERO
	return Vector3(out, -hx.x / l, -hx.y / l)
