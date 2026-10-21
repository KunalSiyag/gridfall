extends RefCounted
## Oriented boxes and circles on the ground plane, as Vector2(x, z): overlap tests, contacts and
## inertia for the player's car body and the street props it knocks over. A box is its centre, its
## unit axes u and v (perpendicular) and its half extents along them, Vector2(along u, along v).
## A contact is [normal, depth, point]: the unit normal that pushes the first shape out of the
## second, how far it has to go, and a point of contact inside the overlap.

## A corner this close outside the other box's faces still counts as inside it (u).
const EPS := 1e-6


## A box's local +X axis at yaw (heading +Z at yaw 0, as for every vehicle).
static func side_axis(yaw: float) -> Vector2:
	return Vector2(cos(yaw), -sin(yaw))


## A box's local +Z axis at yaw: its heading.
static func heading(yaw: float) -> Vector2:
	return Vector2(sin(yaw), cos(yaw))


## Moment of inertia about its centre of a solid box with half extents h and mass m.
static func box_inertia(h: Vector2, m: float) -> float:
	return m * (h.x * h.x + h.y * h.y) / 3.0


## True when the circle round p of radius r reaches into the rectangle lo..hi.
static func near_rect(p: Vector2, r: float, lo: Vector2, hi: Vector2) -> bool:
	return p.clamp(lo, hi).distance_squared_to(p) < r * r


## Contact of box A (centre ca, axes ua va, half extents ha) with box B, or [] when they do not
## overlap. The normal is the separating axis of least overlap; the point is the mean of the
## corners of either box inside the other (the midpoint of the centres when none are).
static func box_box(
	ca: Vector2,
	ua: Vector2,
	va: Vector2,
	ha: Vector2,
	cb: Vector2,
	ub: Vector2,
	vb: Vector2,
	hb: Vector2
) -> Array:
	var d := cb - ca
	var depth := INF
	var n := Vector2.ZERO
	for ax: Vector2 in [ua, va, ub, vb]:
		var reach := (
			ha.x * absf(ua.dot(ax))
			+ ha.y * absf(va.dot(ax))
			+ hb.x * absf(ub.dot(ax))
			+ hb.y * absf(vb.dot(ax))
		)
		var dist := d.dot(ax)
		var o := reach - absf(dist)
		if o <= 0.0:
			return []
		if o < depth:
			depth = o
			n = -ax if dist > 0.0 else ax
	var pts := corners_inside(cb, ub, vb, hb, ca, ua, va, ha)
	pts.append_array(corners_inside(ca, ua, va, ha, cb, ub, vb, hb))
	var point := (ca + cb) * 0.5
	if not pts.is_empty():
		point = Vector2.ZERO
		for q: Vector2 in pts:
			point += q
		point /= float(pts.size())
	return [n, depth, point]


## box_box() with the xz footprint of an axis-aligned world box.
static func box_aabb(ca: Vector2, ua: Vector2, va: Vector2, ha: Vector2, b: AABB) -> Array:
	var c := b.get_center()
	var hb := Vector2(b.size.x, b.size.z) * 0.5
	return box_box(ca, ua, va, ha, Vector2(c.x, c.z), Vector2(1.0, 0.0), Vector2(0.0, 1.0), hb)


## Contact of box A with the circle round c of radius r, or [] when they do not overlap. The
## point is the box's point nearest the circle's centre.
static func box_circle(
	ca: Vector2, ua: Vector2, va: Vector2, ha: Vector2, c: Vector2, r: float
) -> Array:
	var d := c - ca
	var lx := d.dot(ua)
	var lz := d.dot(va)
	var qx := clampf(lx, -ha.x, ha.x)
	var qz := clampf(lz, -ha.y, ha.y)
	var e := Vector2(lx - qx, lz - qz)
	var e2 := e.length_squared()
	if e2 >= r * r:
		return []
	if e2 > 1e-14:
		var dist := sqrt(e2)
		return [-(ua * e.x + va * e.y) / dist, r - dist, ca + ua * qx + va * qz]
	# The centre is inside the box: out through the nearest side.
	var sx := 1.0 if lx >= 0.0 else -1.0
	var sz := 1.0 if lz >= 0.0 else -1.0
	var ox := ha.x - absf(lx)
	var oz := ha.y - absf(lz)
	if ox < oz:
		return [-ua * sx, ox + r, ca + ua * (ha.x * sx) + va * lz]
	return [-va * sz, oz + r, ca + ua * lx + va * (ha.y * sz)]


## The corners of box O (centre oc, axes ou ov, half extents oh) that lie inside box C.
static func corners_inside(
	c: Vector2,
	u: Vector2,
	v: Vector2,
	h: Vector2,
	oc: Vector2,
	ou: Vector2,
	ov: Vector2,
	oh: Vector2
) -> PackedVector2Array:
	var out := PackedVector2Array()
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			var q := oc + ou * (oh.x * sx) + ov * (oh.y * sz)
			var rel := q - c
			if absf(rel.dot(u)) <= h.x + EPS and absf(rel.dot(v)) <= h.y + EPS:
				out.append(q)
	return out
