extends RefCounted
## Contacts of a box body on the ground plane (a car) with the walker's world: CollisionWorld's
## boxes and cylinders that reach above the body's step and start below its roof, and ground it
## cannot drive onto (water and the bridge parapets, where walk_height is NAN, or a rise above
## WS.STEP_HEIGHT). Shared by the player's car (drive) and the cars it shoves (traffic). Points are
## Vector2(x, z); contacts are OBB2D's [normal, depth, point], the normal pushing the body out.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const OBB := preload("res://scripts/fp/obb2d.gd")

## A blocked outline sample looks for drivable ground this far out along an axis (u), then
## bisects between the last blocked and the first free probe.
const PROBES: Array[float] = [0.004, 0.012, 0.025, 0.045, 0.07]
const BISECT := 4
const AXES: Array[Vector2] = [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]


## The obstacles a body with its feet at `feet`, `height` tall, can meet within `reach` of c:
## {"boxes": Array[AABB], "cyls": PackedFloat32Array of (x, z, r), "ground": true when the tiles
## around c hold ground it cannot drive onto (outline samples are tested only then)}.
static func gather(
	col: CollisionWorld, c: Vector2, reach: float, feet: float, height: float
) -> Dictionary:
	var boxes: Array[AABB] = []
	var cyls := PackedFloat32Array()
	var seen := {}
	var top := feet + WS.STEP_HEIGHT
	var head := feet + height
	var rough := false
	var cx := roundi(c.x)
	var cz := roundi(c.y)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if not D.in_bounds(cx + dx, cz + dz):
				continue
			var i := D.idx(cx + dx, cz + dz)
			rough = rough or _rough(col, i, feet)
			for b: AABB in col.boxes(i):
				if b.end.y <= top or b.position.y >= head or seen.has(b):
					continue
				var lo := Vector2(b.position.x, b.position.z)
				if OBB.near_rect(c, reach, lo, Vector2(b.end.x, b.end.z)):
					seen[b] = true
					boxes.append(b)
			var cy := col.cylinders(i)
			for k in range(0, cy.size(), 4):
				var q := Vector2(cy[k], cy[k + 1])
				if cy[k + 3] > top and q.distance_to(c) < reach + cy[k + 2]:
					cyls.append_array([q.x, q.y, cy[k + 2]])
	return {"boxes": boxes, "cyls": cyls, "ground": rough}


## Contacts of the box (centre c, yaw, half extents h = (half width, half length)) with the
## gathered obstacles, and with undrivable ground when the gather found some, in no order.
static func contacts(
	col: CollisionWorld, obs: Dictionary, c: Vector2, yaw: float, h: Vector2, feet: float
) -> Array:
	var u := OBB.side_axis(yaw)
	var v := OBB.heading(yaw)
	var reach := h.length()
	var out: Array = []
	for b: AABB in obs["boxes"]:
		if OBB.near_rect(c, reach, Vector2(b.position.x, b.position.z), Vector2(b.end.x, b.end.z)):
			var hit := OBB.box_aabb(c, u, v, h, b)
			if not hit.is_empty():
				out.append(hit)
	var cy: PackedFloat32Array = obs["cyls"]
	for k in range(0, cy.size(), 3):
		var q := Vector2(cy[k], cy[k + 1])
		if q.distance_to(c) < reach + cy[k + 2]:
			var hit := OBB.box_circle(c, u, v, h, q, cy[k + 2])
			if not hit.is_empty():
				out.append(hit)
	if bool(obs["ground"]):
		out.append_array(ground(col, c, u, v, h, feet))
	return out


## Contacts with ground the box cannot drive onto, from samples round its outline: a blocked
## sample is pushed back along the axis (every such edge in the city runs along x or z), toward
## the box's middle, where drivable ground is nearest.
static func ground(
	col: CollisionWorld, c: Vector2, u: Vector2, v: Vector2, h: Vector2, feet: float
) -> Array:
	var out: Array = []
	for s: Vector2 in outline(c, u, v, h):
		if drivable(col, s, feet):
			continue
		var best := INF
		var n := Vector2.ZERO
		for ax: Vector2 in AXES:
			if ax.dot(c - s) < -1e-6:
				continue
			var d := _free_along(col, s, ax, feet, best)
			if d < best:
				best = d
				n = ax
		if n != Vector2.ZERO:
			out.append([n, best, s])
	return out


## Twelve points round the box: its corners, the middles of its ends and three more along each
## side.
static func outline(c: Vector2, u: Vector2, v: Vector2, h: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for sx: float in [-1.0, 1.0]:
		for f: float in [-1.0, -0.5, 0.0, 0.5, 1.0]:
			out.append(c + u * (h.x * sx) + v * (h.y * f))
	for f: float in [-1.0, 1.0]:
		out.append(c + v * (h.y * f))
	return out


## True when a body with its feet at `feet` can drive onto the ground at p.
static func drivable(col: CollisionWorld, p: Vector2, feet: float) -> bool:
	var g := col.walk_height(Vector3(p.x, feet, p.y))
	return not is_nan(g) and g - feet <= WS.STEP_HEIGHT + 1e-6


## Distance along ax from s to drivable ground (bisected), INF past the last probe or `limit`.
static func _free_along(
	col: CollisionWorld, s: Vector2, ax: Vector2, feet: float, limit: float
) -> float:
	var lo := 0.0
	for d: float in PROBES:
		if d >= limit:
			return INF
		if drivable(col, s + ax * d, feet):
			var hi := d
			for _k in range(BISECT):
				var mid := (lo + hi) * 0.5
				if drivable(col, s + ax * mid, feet):
					hi = mid
				else:
					lo = mid
			return hi
		lo = d
	return INF


## True when tile i may hold ground a body at `feet` cannot drive onto: water (bridges included)
## or a surface above its step.
static func _rough(col: CollisionWorld, i: int, feet: float) -> bool:
	var sim := col.ctx.sim if col.ctx != null else null
	if sim != null and sim.terrain[i] == D.WATER:
		return true
	return not drivable(col, Vector2(D.tx(i), D.ty(i)), feet)
