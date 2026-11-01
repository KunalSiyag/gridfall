extends RefCounted
## Where the driver the hero pulls out of a car comes down (the carjack_throw flag; jack_throw.gd
## has the motion, carjack.gd asks for the line): the body leaves the door along a line turned a
## few degrees off straight out, as far as there is room. The turn is the smallest that keeps the
## body's line, and so the arms it flings up as it twists past, DOOR_CLEAR from the open door
## panel (whose free end hangs out beside the line), and the line clear of what else is out there:
## a wall, a post or a prop (the collision world's static boxes and posts, which the flight itself
## meets, probed for the root and for the head the lying body reaches LIE_FAR past it; not the cars
## beside it, which carjack.gd's _fling weighs, nor the one the body comes out of) and anyone
## standing on the pavement. The
## length is the run before the body would meet any of them, down to carjack.gd's MIN_FLING when
## there is no room at all (a wall against the door cannot be thrown past). Pure over what it is
## given, nothing random: the same street gives the same throw.
## Lengths here are world units (WS.M a metre); the lines are in the car's frame (x out of the
## driver's side, z forward) except where a function says it takes the world's.

const WS := preload("res://scripts/fp/world_scale.gd")
const RE := preload("res://scripts/fp/traffic/reactions.gd")
const BS := preload("res://scripts/fp/traffic/body_spheres.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
## The turns tried off straight out, AIM_STEP apart up to AIM_MAX either way: towards the car's rear
## first (the way the driver runs off), the smallest turn that does the job wins.
const AIM_STEP := deg_to_rad(5.0)
const AIM_MAX := deg_to_rad(25.0)
## The open door panel keeps this far from the body's line: the reach of an arm flung up beside it
## (0.55 m measured on the rig) and a hand's breadth.
const DOOR_CLEAR := 0.75 * WS.M
## A turn is kept over a straighter line only when it buys this much more run.
const TURN_WORTH := 0.05 * WS.M
## The lying body reaches this far past where its root rests, away from the car (the head, the hands
## beside it: 0.9 m measured on the rig), is LIE_R wide each side and LIE_H thick.
const LIE_FAR := 0.95 * WS.M
const LIE_R := 0.3 * WS.M
const LIE_H := 0.3 * WS.M
## The flight's root is stopped by what is within BODY_R and DOWN_REACH of it (reactions.gd _slide);
## the head is probed with its own radius and a hand's breadth.
const ROOT_R := RE.BODY_R + RE.DOWN_REACH
const HEAD_R := BS.HEAD_R + 0.1 * WS.M
## Someone standing within this of the lying body's length is in its way (BODY_R, LIE_R, a margin).
const PED_CLEAR := RE.BODY_R + LIE_R + 0.1 * WS.M
## The line is probed this far apart.
const PROBE := 0.1 * WS.M


## The throw from start (in the car's frame, xf its world transform), fling_m long, along the
## line turned off straight out by the smallest turn that clears the door panel (door: the car's
## door_info, {} when its door is shut or it has none) and what stands in the way (collision, null
## for none; walkers: everyone about, skip the victim's id). {"push": the world's level unit
## direction, "fling": metres (the run before the body meets anything, at most fling_m), "angle":
## the turn (rad, + towards the rear)}.
static func throw_line(
	xf: Transform3D,
	start: Vector2,
	fling_m: float,
	door: Dictionary,
	collision: CollisionWorld,
	walkers: Array,
	skip: int
) -> Dictionary:
	var len_u := fling_m * WS.M
	var origin := xf * Vector3(start.x, 0.0, start.y)
	var near := standing(walkers, skip, origin, len_u + LIE_FAR + PED_CLEAR)
	var boxes: Array[AABB] = []
	if collision != null:
		boxes = collision.boxes_near(origin, len_u + LIE_FAR + ROOT_R, 0.0)
	var run_of := func(dir: Vector2) -> float:
		return free_run(xf, start, dir, len_u, collision, boxes, near)
	var pick := choose(start, len_u, panel(door), run_of)
	var d := dir_at(pick.x)
	var push := xf.basis * Vector3(d.x, 0.0, d.y)
	return {"push": push.normalized(), "fling": pick.y / WS.M, "angle": pick.x}


## The turn (rad, + towards the rear) and the run (u) of the line from start for a throw len_u long:
## the first turn, smallest and rearward first, that has the line DOOR_CLEAR from the panel (pan,
## panel()'s) and the whole run clear (run_of: unit direction in the car frame -> free metres in u,
## at most len_u is used); else the clear-of-the-panel line with the most run, else the line with
## the most run. A turn replaces a straighter one only for TURN_WORTH more run.
static func choose(start: Vector2, len_u: float, pan: Array, run_of: Callable) -> Vector2:
	var best := Vector2(0.0, -1.0)
	var best_ok := false
	var steps := roundi(AIM_MAX / AIM_STEP)
	for k in range(2 * steps + 1):
		var a := turn_at(k)
		var dir := dir_at(a)
		var ok := pan.is_empty() or door_gap(start, dir, len_u, pan) >= DOOR_CLEAR
		if best_ok and not ok:
			continue
		var run := minf(float(run_of.call(dir)), len_u)
		if (ok and not best_ok) or run > best.y + TURN_WORTH:
			best = Vector2(a, run)
			best_ok = ok
		if ok and run >= len_u - 1e-6:
			break
	return best


## The k-th turn tried: 0, then one step towards the rear, one towards the front, two towards the
## rear, ... (rad, + towards the rear).
static func turn_at(k: int) -> float:
	if k <= 0:
		return 0.0
	return float(ceili(float(k) / 2.0)) * AIM_STEP * (1.0 if k % 2 == 1 else -1.0)


## The unit direction (car frame: x, z) of a line turned a rad off straight out, + towards the rear.
static func dir_at(a: float) -> Vector2:
	return Vector2(cos(a), -sin(a))


## The open door panel as [hinge, free end] in the car frame (x, z), from door_info's points: the
## door swung wide. [] for no door (or a shut one: the caller gives {}).
static func panel(door: Dictionary) -> Array:
	if not (door.has("hinge") and door.has("open_rear")):
		return []
	var h: Vector3 = door["hinge"]
	var e: Vector3 = door["open_rear"]
	return [Vector2(h.x, h.z), Vector2(e.x, e.z)]


## The least distance (u) between the throw's line, len_u long from start along dir, and panel pan.
static func door_gap(start: Vector2, dir: Vector2, len_u: float, pan: Array) -> float:
	return seg_gap(start, start + dir * len_u, pan[0], pan[1])


## The least distance between segment a-b and segment c-d.
static func seg_gap(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> float:
	if Geometry2D.segment_intersects_segment(a, b, c, d) != null:
		return 0.0
	var g := a.distance_to(Geometry2D.get_closest_point_to_segment(a, c, d))
	g = minf(g, b.distance_to(Geometry2D.get_closest_point_to_segment(b, c, d)))
	g = minf(g, c.distance_to(Geometry2D.get_closest_point_to_segment(c, a, b)))
	return minf(g, d.distance_to(Geometry2D.get_closest_point_to_segment(d, a, b)))


## Where everyone about but the victim (skip) stands within reach of origin (world), as xz points:
## those on the street and not gone.
static func standing(
	walkers: Array, skip: int, origin: Vector3, reach: float
) -> PackedVector2Array:
	var out := PackedVector2Array()
	for w: WK.Walker in walkers:
		if w.id == skip or w.dead or w.state == "hidden":
			continue
		var at := w.pos + w.vis_off
		if Vector2(at.x - origin.x, at.z - origin.z).length() <= reach:
			out.append(Vector2(at.x, at.z))
	return out


## The metres (u) the body's root can run from start along dir (car frame, unit) before the lying
## body would meet something, at most len_u: the root stopped by the world's boxes (boxes: the
## collision world's boxes_near with its posts, the walkable ground under it from collision) as the
## flight is (reactions.gd _slide), the head by what stands LIE_FAR past it, and either by one of
## near (standing()'s) too close to the body's length. No collision world, no static check.
static func free_run(
	xf: Transform3D,
	start: Vector2,
	dir: Vector2,
	len_u: float,
	collision: CollisionWorld,
	boxes: Array[AABB],
	near: PackedVector2Array
) -> float:
	var o := xf * Vector3(start.x, 0.0, start.y)
	var w := xf.basis * Vector3(dir.x, 0.0, dir.y)
	w = Vector3(w.x, 0.0, w.z).normalized()
	var n := maxi(ceili(len_u / PROBE), 1)
	var free := 0.0
	for k in range(n + 1):
		var s := minf(float(k) * len_u / float(n), len_u)
		if _meets(o + w * s, w, collision, boxes, near):
			return free
		free = s
	return free


## True when a body lying with its root at p and its length along w would meet the world (no
## walkable ground, one of boxes) or one of near.
static func _meets(
	p: Vector3, w: Vector3, collision: CollisionWorld, boxes: Array[AABB], near: PackedVector2Array
) -> bool:
	if collision != null:
		var g := collision.ground_height(p)
		if is_nan(g):
			return true
		var root := Vector3(p.x, g, p.z)
		if (
			_in_box(boxes, root, ROOT_R, RE.BODY_H)
			or _in_box(boxes, root + w * LIE_FAR, HEAD_R, LIE_H)
		):
			return true
	var a := Vector2(p.x, p.z)
	var b := a + Vector2(w.x, w.z) * LIE_FAR
	for q: Vector2 in near:
		if q.distance_to(Geometry2D.get_closest_point_to_segment(q, a, b)) < PED_CLEAR:
			return true
	return false


## True when a body of radius and height at p (its feet) is inside one of boxes grown by radius: the
## collision world's own test (a box above the head or below the feet lets it pass).
static func _in_box(boxes: Array[AABB], p: Vector3, radius: float, height: float) -> bool:
	for b: AABB in boxes:
		if p.y >= b.end.y or b.position.y >= p.y + height:
			continue
		if (
			p.x > b.position.x - radius
			and p.x < b.end.x + radius
			and p.z > b.position.z - radius
			and p.z < b.end.z + radius
		):
			return true
	return false
