extends RefCounted
## Where the driver the hero pulls out of a car comes down (the carjack_throw flag; jack_throw.gd
## has the motion, carjack.gd asks for the line): the body leaves the door along a line turned a
## few degrees off straight out, as far as there is room. The open door (the real panel with its
## thickness, glass and frame: car_doors.gd outline, in plan, as far open as it hangs) is what the
## line keeps off, with the reach of the arms and legs flung about allowed for (REACH_0 at the
## release, REACH_K more for each unit flown, fitted to the real rig: fp_jack_doors_test, the
## skinned body of 38 avatars against the door's own triangles, no vertex through any model's
## door). The turn is the smallest that leaves DOOR_MARGIN clear of that. Where no turn does (the
## doors of the SUVs and vans hang close to the seat) it is the turn that keeps furthest from the
## door, with the point the body is let go at moved down the car's side, away from the door, as far
## as the door needs (SHIFT_MARGIN, at most SHIFT_MAX: exit_shift; the hatchbacks, sedans and taxi
## need none) and the twist turned the way that sweeps the trailing legs off it (spin_away). The
## body keeps facing the car's side whatever the turn
## (carjack.gd sets the facing): turned with the line its flung arm swings up into the door's
## rear corner. The line is also kept clear of what else is out there: a wall, a post or a prop (the
## collision world's static boxes and posts, which the flight itself meets, probed for the root and
## for the head the lying body reaches LIE_FAR past it; not the cars beside it, which carjack.gd's
## _fling weighs, nor the one the body comes out of) and anyone standing on the pavement. The length
## is the run before the body would meet any of them, down to carjack.gd's MIN_FLING when there is
## no room at all (a wall against the door cannot be thrown past). Pure over what it is given,
## nothing random: the same street gives the same throw.
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
## The arms and legs flung about reach this far from the root: REACH_0 at the release and REACH_K
## more for each unit flown along the line (the twist swings them out). Fitted to the real rig
## (fp_jack_doors_test): the least distance from the roots of the throws of every car model, with
## the tallest avatars of the roster, to the door's outline at many places along the line and
## shifts, less than any distance the skinned body came to the door's triangles. What a line
## leaves clear is its distance from the outline less that reach (door_gap); DOOR_MARGIN is the
## least it may leave. The point the body is let go at moves down the car's side, SHIFT_STEP at a
## time up to SHIFT_MAX, until the best turn leaves SHIFT_MARGIN of it, and no further: the further
## down it is, the longer a limb is through the car's own rear side behind the door (a hatchback's,
## 0.18 s with no shift, 0.31 s with 0.05 m), and the reach is the least over the whole roster, so
## the doors that clear it anyway (the hatchbacks' 0.043 m, the sedans' 0.018 m) need no shift. With
## 0.015 m (between the sedans' 0.018 and the vans' 0.009 m at a shift of 0.25 m) the skinned body
## of every model kept 0.073 m or more off its door; with none, a van's, shifted 0.25 m and not
## 0.30, came within 0.037 m.
const REACH_0 := 0.41 * WS.M
const REACH_K := 0.40
const DOOR_MARGIN := 0.05 * WS.M
const SHIFT_MARGIN := 0.015 * WS.M
const SHIFT_STEP := 0.05 * WS.M
const SHIFT_MAX := 0.35 * WS.M
## Lines this much alike in their gap from the door are alike: the one with more run wins.
const GAP_TIE := 0.02 * WS.M
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
## line turned off straight out by the smallest turn that clears the door (pan: its outline in the
## car's frame, empty when it is shut or there is none) and what stands in the way (collision, null
## for none; walkers: everyone about, skip the victim's id). {"push": the world's level unit
## direction, "fling": metres (the run before the body meets anything, at most fling_m), "angle":
## the turn (rad, + towards the rear), "gap": metres the line passes the door at, INF for none}.
static func throw_line(
	xf: Transform3D,
	start: Vector2,
	fling_m: float,
	pan: PackedVector2Array,
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
	var pick := choose(start, len_u, pan, run_of)
	var d := dir_at(pick.x)
	var push := xf.basis * Vector3(d.x, 0.0, d.y)
	return {
		"push": push.normalized(), "fling": pick.y / WS.M, "angle": pick.x, "gap": pick.z / WS.M
	}


## The turn (rad, + towards the rear), the run (u) and the gap from the door (u, INF with none) of
## the line from start for a throw len_u long. Of the lines tried those DOOR_MARGIN clear of the
## door's outline (pan) once the reach of the flung arms is allowed for (door_gap) are the choice,
## or, when none is, those within GAP_TIE of the furthest from it (the doors of the SUVs and vans
## hang too close to the seat for any turn to reach it: the turn that gets furthest is the best
## there is, not the one with the most run). Of those the first in the order tried, smallest and
## rearward first, with the whole run (run_of: unit direction in the car frame -> free metres in u,
## at most len_u is used), else the most; a turn replaces a straighter one only for TURN_WORTH more
## run.
static func choose(
	start: Vector2, len_u: float, pan: PackedVector2Array, run_of: Callable
) -> Vector3:
	var n := 2 * roundi(AIM_MAX / AIM_STEP) + 1
	var gaps: Array[float] = []
	var top := -INF
	for k in range(n):
		var g := door_gap(start, dir_at(turn_at(k)), len_u, pan) if not pan.is_empty() else INF
		gaps.append(g)
		top = maxf(top, g)
	var floor_g := DOOR_MARGIN if top >= DOOR_MARGIN else top - GAP_TIE
	var best := Vector3(0.0, -1.0, 0.0)
	for k in range(n):
		if gaps[k] < floor_g:
			continue
		var a := turn_at(k)
		var run := minf(float(run_of.call(dir_at(a))), len_u)
		if best.y < 0.0 or run > best.y + TURN_WORTH:
			best = Vector3(a, run, gaps[k])
		if run >= len_u - 1e-6:
			break
	return best


## The most (u: door_gap's) that any turn tried keeps the line from start, len_u long, clear of the
## door's outline pan.
static func best_gap(start: Vector2, len_u: float, pan: PackedVector2Array) -> float:
	var top := -INF
	for k in range(2 * roundi(AIM_MAX / AIM_STEP) + 1):
		top = maxf(top, door_gap(start, dir_at(turn_at(k)), len_u, pan))
	return top


## How far (u) down the car's side, towards its rear, the body is let go from start (its place at
## the door) so that the best turn has the line SHIFT_MARGIN clear of the open door's outline pan
## (door_gap): none when it has it already (or there is no door), by SHIFT_STEPs, at most
## SHIFT_MAX. The door hangs ahead of the seat for every door there is, so away from it is the rear.
static func exit_shift(start: Vector2, len_u: float, pan: PackedVector2Array) -> float:
	if pan.is_empty():
		return 0.0
	for i in range(roundi(SHIFT_MAX / SHIFT_STEP) + 1):
		var sh := minf(float(i) * SHIFT_STEP, SHIFT_MAX)
		if best_gap(Vector2(start.x, start.y - sh), len_u, pan) >= SHIFT_MARGIN:
			return sh
	return SHIFT_MAX


## The direction (+1 or -1: the sign of jack_throw.gd's twist) the body flung from start along
## dir (car frame, unit) twists so that its trailing legs sweep away from the open door pan (the
## door on the side of the line the cross product reads: the legs swing the other way), 0 for no
## door. Measured on the rig: twisted towards the door the toes go through it for half of the
## throws.
static func spin_away(start: Vector2, dir: Vector2, pan: PackedVector2Array) -> float:
	if pan.is_empty():
		return 0.0
	var mid := Vector2.ZERO
	for p: Vector2 in pan:
		mid += p
	mid /= float(pan.size())
	return -1.0 if dir.cross(mid - start) > 0.0 else 1.0


## The k-th turn tried: 0, then one step towards the rear, one towards the front, two towards the
## rear, ... (rad, + towards the rear).
static func turn_at(k: int) -> float:
	if k <= 0:
		return 0.0
	return float(ceili(float(k) / 2.0)) * AIM_STEP * (1.0 if k % 2 == 1 else -1.0)


## The unit direction (car frame: x, z) of a line turned a rad off straight out, + towards the rear.
static func dir_at(a: float) -> Vector2:
	return Vector2(cos(a), -sin(a))


## What the throw's line, len_u long from start along dir, leaves clear of the door's outline pan (a
## convex polygon in plan) once the reach of the flung arms is allowed for: the least, over points
## PROBE apart along it, of the distance from the point to the outline less REACH_0 + REACH_K for
## each unit flown (negative when that reach meets the door).
static func door_gap(start: Vector2, dir: Vector2, len_u: float, pan: PackedVector2Array) -> float:
	var n := maxi(ceili(len_u / PROBE), 1)
	var g := INF
	for k in range(n + 1):
		var u := minf(float(k) * len_u / float(n), len_u)
		g = minf(g, outline_dist(start + dir * u, pan) - (REACH_0 + REACH_K * u))
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
