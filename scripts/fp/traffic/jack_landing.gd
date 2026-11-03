extends RefCounted
## Where the driver the hero pulls out of a car comes down, and what they are kept clear of on the
## way (the carjack_throw flag; jack_pull.gd has the motion, carjack.gd asks for the numbers): they
## come out of the door straight out from the seat and sit down a short way beyond the sill, lying
## along the car's side as they sat (head to the rear, feet toward the front: the feet, which the
## hero steps in beside, are not at the sill as they would be lying across the car, head to the
## road). The open door (the real panel with its thickness, glass and frame: car_doors.gd outline,
## in plan, as far open as it hangs) is what the body keeps off: its feet, up to FEET_REACH ahead of
## the root (fp_jack_doors_test: the skinned body of 38 avatars against the door's own triangles, no
## vertex through any model's door). Where the straight line leaves less than SHIFT_MARGIN clear of
## the door (every door hangs close enough to the feet's reach) the point the body is let go at is
## moved down the car's side, away from the door, as far as the door needs (SHIFT_STEP at a time, at
## most SHIFT_MAX: exit_shift).
## The line is also kept clear of what else is out there: a wall, a post or a prop (the collision
## world's static boxes and posts, probed for the root and for the head the lying body reaches
## LIE_FAR past it, toward the car's rear; not the cars beside it, which carjack.gd's _drop weighs,
## nor the one the body comes out of) and anyone standing on the pavement. The distance is the run
## before the body would meet any of them, down to carjack.gd's MIN_DROP when there is no room at
## all (a wall against the door cannot be dropped past). Pure over what it is given, nothing
## random: the same street gives the same drop.
## Lengths here are world units (WS.M a metre); the lines are in the car's frame (x out of the
## driver's side, z forward) except where a function says it takes the world's.

const WS := preload("res://scripts/fp/world_scale.gd")
const RE := preload("res://scripts/fp/traffic/reactions.gd")
const BS := preload("res://scripts/fp/traffic/body_spheres.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
## The point the body is let go at moves down the car's side (the way the hero's pull takes them,
## toward his hip), SHIFT_STEP at a time up to SHIFT_MAX, until the line leaves SHIFT_MARGIN of
## clearance, and no further: the further down it is, the longer a limb is through the car's own
## rear side behind the door (the vans' doors hang across the feet's reach and take the most,
## SHIFT_MAX).
const SHIFT_MARGIN := 0.02 * WS.M
const SHIFT_STEP := 0.05 * WS.M
const SHIFT_MAX := 0.9 * WS.M
## The feet reach up to FEET_REACH ahead of the root, toward the door (the lying pose's toes are
## 0.7 m ahead of its hips, the crossfade into it reaches 0.88 m and the boots are thick), and a
## limb is LIMB thick.
const FEET_REACH := 0.9 * WS.M
const LIMB := 0.1 * WS.M
## The lying body reaches this far past where its root rests, toward the car's rear (the head, the
## hands beside it: measured on the rig), LIE_NEAR the other way (the feet), is LIE_R wide each side
## and LIE_H thick.
const LIE_FAR := 0.95 * WS.M
const LIE_NEAR := 0.65 * WS.M
const LIE_R := 0.3 * WS.M
const LIE_H := 0.3 * WS.M
## The root is stopped by what is within BODY_R and DOWN_REACH of it (reactions.gd _slide); the head
## and the feet are probed with their own radius and a hand's breadth.
const ROOT_R := RE.BODY_R + RE.DOWN_REACH
const HEAD_R := BS.HEAD_R + 0.1 * WS.M
## Someone standing within this of the lying body's length is in its way (BODY_R, LIE_R, a margin).
const PED_CLEAR := RE.BODY_R + LIE_R + 0.1 * WS.M
## The line is probed this far apart.
const PROBE := 0.1 * WS.M
## The line out of the door: straight out in the car's frame.
const OUT_DIR := Vector2(1.0, 0.0)


## The metres the body can be dropped from start (in the car's frame, xf its world transform), at
## most drop_m: the run straight out before it would meet what stands in the way (collision, null
## for none; walkers: everyone about, skip the victim's id).
static func drop_run(
	xf: Transform3D,
	start: Vector2,
	drop_m: float,
	collision: CollisionWorld,
	walkers: Array,
	skip: int
) -> float:
	var len_u := drop_m * WS.M
	var origin := xf * Vector3(start.x, 0.0, start.y)
	var near := standing(walkers, skip, origin, len_u + LIE_FAR + PED_CLEAR)
	var boxes: Array[AABB] = []
	if collision != null:
		boxes = collision.boxes_near(origin, len_u + LIE_FAR + ROOT_R, 0.0)
	return free_run(xf, start, len_u, collision, boxes, near) / WS.M


## How far (u) down the car's side, towards its rear, the body is let go from start (its place at
## the door) so that the line straight out, len_u long, is SHIFT_MARGIN clear of the open door's
## outline pan (door_gap): none when it is already (or there is no door), by SHIFT_STEPs, at most
## SHIFT_MAX. The door hangs ahead of the seat for every door there is, so away from it is the rear.
static func exit_shift(start: Vector2, len_u: float, pan: PackedVector2Array) -> float:
	if pan.is_empty():
		return 0.0
	for i in range(roundi(SHIFT_MAX / SHIFT_STEP) + 1):
		var sh := minf(float(i) * SHIFT_STEP, SHIFT_MAX)
		if door_gap(Vector2(start.x, start.y - sh), len_u, pan) >= SHIFT_MARGIN:
			return sh
	return SHIFT_MAX


## What the line straight out from start (car frame), len_u long, leaves clear of the door's outline
## pan (a convex polygon in plan) once the feet's reach is allowed for: the least, over points PROBE
## apart along it and over the feet's reach, up to FEET_REACH ahead of each point, of the distance
## from the point to the outline less LIMB (negative when the body meets the door).
static func door_gap(start: Vector2, len_u: float, pan: PackedVector2Array) -> float:
	var n := maxi(ceili(len_u / PROBE), 1)
	var feet := maxi(ceili(FEET_REACH / PROBE), 1)
	var g := INF
	for k in range(n + 1):
		var at := start + OUT_DIR * minf(float(k) * len_u / float(n), len_u)
		# The whole of the feet's reach, not its end alone: a door that hangs between the root and
		# the feet's end would let the end through beyond it.
		for j in range(feet + 1):
			var f := minf(float(j) * FEET_REACH / float(feet), FEET_REACH)
			g = minf(g, outline_dist(at + Vector2(0.0, f), pan) - LIMB)
	return g


## The distance (u) from point p to the outline pan (a convex polygon): negative inside it.
static func outline_dist(p: Vector2, pan: PackedVector2Array) -> float:
	var d := INF
	for i in range(pan.size()):
		var q := Geometry2D.get_closest_point_to_segment(p, pan[i], pan[(i + 1) % pan.size()])
		d = minf(d, p.distance_to(q))
	return -d if Geometry2D.is_point_in_polygon(p, pan) else d


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


## The metres (u) the body's root can run from start straight out of the car's side (xf: the car's
## world transform; start in its frame) before the lying body would meet something, at most len_u:
## the root stopped by the world's boxes (boxes: the collision world's boxes_near with its posts,
## the walkable ground under it from collision) as the slide is (reactions.gd _slide), the head by
## what stands LIE_FAR past it, and either by one of near (standing()'s) too close to the body's
## length. No collision world, no static check.
static func free_run(
	xf: Transform3D,
	start: Vector2,
	len_u: float,
	collision: CollisionWorld,
	boxes: Array[AABB],
	near: PackedVector2Array
) -> float:
	var o := xf * Vector3(start.x, 0.0, start.y)
	var out := _level(xf.basis * Vector3(OUT_DIR.x, 0.0, OUT_DIR.y))
	# The head lies toward the car's rear.
	var head := -_level(xf.basis * Vector3(0.0, 0.0, 1.0))
	var n := maxi(ceili(len_u / PROBE), 1)
	var free := 0.0
	for k in range(n + 1):
		var s := minf(float(k) * len_u / float(n), len_u)
		if _meets(o + out * s, head, collision, boxes, near):
			return free
		free = s
	return free


## True when a body lying with its root at p and its head the way w (level unit) would meet the
## world (no walkable ground, one of boxes) or one of near.
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
	var a := Vector2(p.x - w.x * LIE_NEAR, p.z - w.z * LIE_NEAR)
	var b := Vector2(p.x + w.x * LIE_FAR, p.z + w.z * LIE_FAR)
	for q: Vector2 in near:
		if q.distance_to(Geometry2D.get_closest_point_to_segment(q, a, b)) < PED_CLEAR:
			return true
	return false


static func _level(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z).normalized()


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
