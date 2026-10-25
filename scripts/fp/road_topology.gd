class_name RoadTopology
extends RefCounted
## Static road-tile helpers shared by collision, traffic, the directory, the minimap and the
## streetscape. They mirror CityView._road_mask / _road_piece exactly: mask bits N=1, E=2, S=4,
## W=8 with north at -Z; straight runs N-S, corner joins S+W, tee joins E+S+W, end opens S.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const N := 1
const E := 2
const S := 4
const W := 8
const NS := 5
const EW := 10
const _ARMS := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]


## Neighbour mask of road tile (x, y): ROAD neighbours only, exactly like CityView._road_mask.
static func mask(sim: CitySim, x: int, y: int) -> int:
	var m := 0
	if D.in_bounds(x, y - 1) and sim.kind[D.idx(x, y - 1)] == D.ROAD:
		m |= N
	if D.in_bounds(x + 1, y) and sim.kind[D.idx(x + 1, y)] == D.ROAD:
		m |= E
	if D.in_bounds(x, y + 1) and sim.kind[D.idx(x, y + 1)] == D.ROAD:
		m |= S
	if D.in_bounds(x - 1, y) and sim.kind[D.idx(x - 1, y)] == D.ROAD:
		m |= W
	return m


## [piece: String, yaw_deg: float] for a mask; piece in straight|corner|tee|cross|end. Mirrors _road_piece with real roads present.
static func piece(m: int) -> Array:
	var bits := _bits(m)
	if bits >= 4:
		return ["cross", 0.0]
	var bases := []
	if bits == 3:
		bases = [["tee", 14]]
	elif bits == 2:
		bases = [["straight", 5], ["corner", 12]]
	elif bits == 1:
		bases = [["end", 4]]
	else:
		return ["straight", 0.0]
	for base: Array in bases:
		var b: int = base[1]
		for k in range(4):
			if b == m:
				return [base[0], float(k) * 90.0]
			b = _rot_mask(b)
	return ["straight", 0.0]


## Unit directions (dx, dy) of the open arms, in N, E, S, W order. dy is world +Z.
static func arms(m: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for k in range(4):
		if m & (1 << k):
			out.append(_ARMS[k])
	return out


## True when local point lp = (wx - x, wz - y) of a road tile with mask m is on the carriageway.
static func is_carriageway(m: int, lp: Vector2) -> bool:
	var bits := _bits(m)
	var hw := WS.ROAD_HALF
	if bits == 0 or m == NS:
		return absf(lp.x) < hw
	if m == EW:
		return absf(lp.y) < hw
	if bits == 2:
		var c := Vector2.ZERO
		for a: Vector2i in arms(m):
			c += Vector2(a) * 0.5
		var d := lp.distance_to(c)
		return d >= WS.CORNER_INNER_R and d <= WS.CORNER_OUTER_R
	if bits == 1:
		var arm := Vector2(arms(m)[0])
		var o := -arm * WS.END_CIRCLE_OFFSET
		var dc := lp.distance_to(o)
		if dc < WS.END_ISLAND_R:
			return false
		if dc <= WS.END_CIRCLE_R:
			return true
		return _on_arm_strip(arm, lp)
	# Tee and cross: the central square plus a strip along each open arm (fillets ignored).
	if absf(lp.x) < hw and absf(lp.y) < hw:
		return true
	for a: Vector2i in arms(m):
		if _on_arm_strip(Vector2(a), lp):
			return true
	return false


## Grade of road tile i (D.ROAD_GRADES, kept in its level); paved for bridges and non-roads.
static func grade(sim: CitySim, i: int) -> int:
	if sim.kind[i] != D.ROAD or sim.terrain[i] == D.WATER:
		return D.GRADE_PAVED
	return clampi(sim.level[i], D.GRADE_PAVED, D.GRADE_TRAIL)


## True when road tile i is a paved street (curbs, sidewalks, street furniture).
static func paved(sim: CitySim, i: int) -> bool:
	return grade(sim, i) == D.GRADE_PAVED


## Walkable surface height at lp on road tile i: ASPHALT_TOP on the carriageway, SIDEWALK_TOP on the sidewalk,
## NAN outside the bridge parapet (bridge = ROAD on WATER terrain, straight only). Unpaved grades
## have no curb: the whole tile is ASPHALT_TOP.
static func surface_height(sim: CitySim, i: int, lp: Vector2) -> float:
	if not paved(sim, i):
		return WS.ASPHALT_TOP
	var m := mask(sim, D.tx(i), D.ty(i))
	if is_bridge(sim, i) and str(piece(m)[0]) == "straight":
		var perp := absf(lp.y) if m == EW else absf(lp.x)
		if perp < WS.ROAD_HALF:
			return WS.ASPHALT_TOP
		if perp <= WS.BRIDGE_SIDEWALK_OUT:
			return WS.SIDEWALK_TOP
		return NAN
	return WS.ASPHALT_TOP if is_carriageway(m, lp) else WS.SIDEWALK_TOP


## World point at the centre of the sidewalk on `side` (+1 right, -1 left of the run) of a straight road tile.
## The run points north (-Z) for N-S tiles and east (+X) for E-W tiles, so +1 is east of a N-S run
## and south of an E-W run. y is SIDEWALK_TOP (ASPHALT_TOP on the verge of an unpaved road).
static func sidewalk_point(sim: CitySim, i: int, side: int) -> Vector3:
	var right := run_right(mask(sim, D.tx(i), D.ty(i)))
	var s := 1.0 if side >= 0 else -1.0
	var y := WS.SIDEWALK_TOP if paved(sim, i) else WS.ASPHALT_TOP
	return Vector3(D.tx(i), y, D.ty(i)) + right * (s * WS.SIDEWALK_CENTER)


## Unit run direction of a road tile with mask m: east (+X) when it has only E/W arms, else north (-Z).
static func run_dir(m: int) -> Vector3:
	if (m & EW) != 0 and (m & NS) == 0:
		return Vector3(1, 0, 0)
	return Vector3(0, 0, -1)


## Unit vector to the right of run_dir(m).
static func run_right(m: int) -> Vector3:
	var f := run_dir(m)
	return Vector3(-f.z, 0, f.x)


## True if road tile i is a bridge (ROAD on WATER terrain).
static func is_bridge(sim: CitySim, i: int) -> bool:
	return sim.kind[i] == D.ROAD and sim.terrain[i] == D.WATER


static func _on_arm_strip(arm: Vector2, lp: Vector2) -> bool:
	if arm.x != 0.0:
		return lp.x * arm.x >= 0.0 and absf(lp.y) < WS.ROAD_HALF
	return lp.y * arm.y >= 0.0 and absf(lp.x) < WS.ROAD_HALF


static func _bits(m: int) -> int:
	var n := 0
	for b in [N, E, S, W]:
		if m & b:
			n += 1
	return n


static func _rot_mask(m: int) -> int:
	# Yaw +90 deg maps N->W, E->N, S->E, W->S (CityView._rot_mask).
	var r := 0
	if m & N:
		r |= W
	if m & E:
		r |= N
	if m & S:
		r |= E
	if m & W:
		r |= S
	return r
