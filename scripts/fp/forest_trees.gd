extends RefCounted
## The woods' synthetic trees. city_view.gd plants them by exactly this hash (its tree chunks:
## N trees on every in-bounds forest tile), so the animals that climb them — squirrels first,
## cats bolting from a charging dog — find a trunk that is really drawn. The forest tiles carry
## no colliders, so this hash is the only way to know where their trunks stand.

const WS := preload("res://scripts/fp/world_scale.gd")
const D := preload("res://scripts/sim/sim_defs.gd")

## The trees a forest tile keeps, how far (u) off the tile's middle they fall, the size step
## between them, and a street tree's trunk radius (u) they scale from (they draw at 1.0 to 1.6
## times a street tree).
const N := 4
const SPREAD := 0.85
const STEP := 0.1
const TRUNK_R := 0.25 * WS.M


## The t-th tree the view plants on the forest tile (gx, gz): its world xz and trunk radius [x,
## z, r]. The tile's own hash, so the answer never moves.
static func tree(gx: int, gz: int, t: int) -> Array:
	var h := absi(gx * 73856093 ^ gz * 19349663)
	var hh := (h >> (t * 4)) & 0xffff
	var ox := float(hh % 61) / 60.0 - 0.5
	var oz := float((hh >> 6) % 61) / 60.0 - 0.5
	var sc := 1.0 + float(hh % 7) * STEP
	return [gx + ox * SPREAD, gz + oz * SPREAD, TRUNK_R * sc]


## The nearest wood tree to p within r (u), as [x, z, r], or [] for none: the forest tiles of
## the 3x3 neighbourhood of tile i0 are enough for any r up to a tile and a half. kinds is the
## sim's kind array (PackedInt32Array).
static func nearest(p: Vector3, i0: int, r: float, kinds: PackedInt32Array) -> Array:
	var best: Array = []
	if i0 < 0:
		return best
	var bd := r
	for dy: int in [-1, 0, 1]:
		for dx: int in [-1, 0, 1]:
			var x := D.tx(i0) + dx
			var y := D.ty(i0) + dy
			if not D.in_bounds(x, y) or kinds[D.idx(x, y)] != D.FOREST:
				continue
			for t in range(N):
				var tr := tree(x, y, t)
				var d := Vector2(p.x - float(tr[0]), p.z - float(tr[1])).length()
				if d < bd:
					bd = d
					best = tr
	return best
