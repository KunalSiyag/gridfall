extends RefCounted
## The flat-world helpers the animals modules work in (u, y up): a tile's ground position, flat
## distance, the strike cone's gap and the pick ray's ball hit. animals_feature.gd's copies moved
## here for the 1000-line cap; the other modules' own copies may follow.

const D := preload("res://scripts/sim/sim_defs.gd")


static func tile_pos(i: int) -> Vector3:
	return Vector3(D.tx(i), 0.0, D.ty(i))


static func flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## How far the side of something r (u) round at pos is from the feet (flat), INF outside the cone
## round aim (the cosine).
static func gap(feet: Vector3, aim: Vector3, pos: Vector3, r: float, cone: float) -> float:
	var d := Vector3(pos.x - feet.x, 0.0, pos.z - feet.z)
	var dist := d.length()
	if dist > 1e-5 and d.dot(aim) / dist < cone:
		return INF
	return maxf(dist - r, 0.0)


## Distance along the ray (o, unit d) to the ball (c, r), or -1 when it misses.
static func ray_ball(o: Vector3, d: Vector3, c: Vector3, r: float) -> float:
	var oc := c - o
	var t := oc.dot(d)
	var miss := oc.length_squared() - t * t
	if miss > r * r:
		return -1.0
	var half := sqrt(r * r - miss)
	return maxf(t - half, 0.0) if t + half >= 0.0 else -1.0
