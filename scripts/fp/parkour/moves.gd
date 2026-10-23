extends RefCounted
## Plans what a jump press in front of an obstacle becomes (the parkour feature): a vault over a
## low, thin obstacle with room to land beyond it, a hop up onto a low ledge, or a climb up onto a
## higher one with room to stand on top. Obstacles are CollisionWorld boxes a walker cannot step
## over; a move runs straight across the face it meets (the boxes are axis-aligned) along two
## tracks of keys, the distance travelled and the height of the feet, that point() reads. Heights
## are above the feet; lengths are world units, times seconds.

const WS := preload("res://scripts/fp/world_scale.gd")

const R := WS.PLAYER_RADIUS
## A press finds an obstacle when the gap to its face is at most REACH plus REACH_T seconds of the
## body's speed and the approach is within acos(APPROACH_COS) of head-on.
const REACH := 0.6 * WS.M
const REACH_T := 0.2
const APPROACH_COS := 0.6
## Vaults: obstacles up to VAULT_MAX tall and VAULT_DEPTH deep, landing at most VAULT_DROP below
## the feet. The feet clear a top by CLEAR, and a body going over is TUCK tall and TUCK_R round.
const VAULT_MAX := 1.1 * WS.M
const VAULT_DEPTH := 0.9 * WS.M
const VAULT_DROP := 0.6 * WS.M
const CLEAR := 0.12 * WS.M
const TUCK := 0.9 * WS.M
const TUCK_R := 0.4 * R
## Hops go up to HOP_MAX and climbs up to CLIMB_MAX. The body ends STAND_IN beyond touching the
## edge (on the middle of a narrower top).
const HOP_MAX := 0.7 * WS.M
const CLIMB_MAX := 2.1 * WS.M
const STAND_IN := 0.1 * WS.M
## Speeds (u/s): a vault or a hop goes between VAULT_SPEED and a run; a climb walks up to the face
## at APPROACH at least.
const VAULT_SPEED := 2.5 * WS.M
const APPROACH := 1.5 * WS.M
## Shortest phases: the rise to the top, the pass over it and the way down.
const RISE_MIN := 0.2
const OVER_MIN := 0.1
const DROP_MIN := 0.15
## A climb takes CLIMB_T plus CLIMB_PER_M a metre of height, the rig's climb clip (played in
## place) stretched over it. The body rises from CLIMB_RISE of the clip on, once the hands are on
## the edge, and steps forward onto the top from CLIMB_STEP on, as a foot comes up onto it (shares
## of the clip, measured on it).
const CLIMB_T := 0.45
const CLIMB_PER_M := 0.25
const CLIMB_RISE := 0.1
const CLIMB_STEP := 0.35
## A vault lands as far past the obstacle as the speed carries it (the first fraction) or nearer,
## down to LAND_GAP past its far side. A landing comes down at LAND_V (u/s) at most.
const LAND_FRACTIONS := [1.0, 0.7, 0.4, 0.0]
const LAND_GAP := 0.08 * WS.M
const LAND_V := 3.5 * WS.M
## The path is checked for room every PATH_STEP seconds of the move.
const PATH_STEP := 0.04
## How a track eases into a key: linearly, fast then slow, slow then fast, or smoothstep.
const LIN := 0
const EASE_OUT := 1
const EASE_IN := 2
const SMOOTH := 3


## The move a jump press with the feet at pos becomes, heading along dir (xz) at speed (u/s), or {}
## for an ordinary jump: {"move": "vault", "hop" or "climb", "from" (feet), "dir" (unit, across the
## face), "top" (its height), "s" and "y" (the tracks), "length", "anim_at" (when the climb clip
## starts; -1 for none) and "anim_len", "grounded" (the body counts as on the ground: the climb),
## "exit" (the velocity handed back at the end, u/s)}.
static func find(col: CollisionWorld, pos: Vector3, dir: Vector3, speed: float) -> Dictionary:
	var d := Vector2(dir.x, dir.z)
	if col == null or d.length_squared() < 1e-12:
		return {}
	var face := find_face(col, pos, d.normalized(), REACH + REACH_T * speed)
	if face.is_empty():
		return {}
	var u: Vector2 = face["u"]
	var near: float = face["face"]
	var depth := float(face["far"]) - near
	var stand := near + minf(R + STAND_IN, depth * 0.5)
	face["stand"] = stand
	var top := col.support_height(_at(pos, u, stand, pos.y), R * 0.5, pos.y, CLIMB_MAX)
	var h := top - pos.y
	if is_nan(top) or h <= WS.STEP_HEIGHT:
		return {}
	var plan := {}
	if h <= VAULT_MAX and depth <= VAULT_DEPTH:
		plan = _vault(col, pos, u, face, top, speed)
	if not plan.is_empty() or not fits(col, _at(pos, u, stand, top)):
		return plan
	if h <= HOP_MAX:
		return _hop(col, pos, u, face, top, speed)
	return _climb(col, pos, u, face, top, speed)


## The feet t seconds into plan.
static func point(plan: Dictionary, t: float) -> Vector3:
	var from: Vector3 = plan["from"]
	var dir: Vector3 = plan["dir"]
	var s := sample(plan["s"], t)
	return Vector3(from.x + dir.x * s, sample(plan["y"], t), from.z + dir.z * s)


## A track's value at time t: keys are [time (rising from 0), value, how it eases into the key].
static func sample(keys: Array, t: float) -> float:
	var prev: Array = keys[0]
	for k: Array in keys:
		if t <= float(k[0]):
			var span := float(k[0]) - float(prev[0])
			var w := clampf((t - float(prev[0])) / span, 0.0, 1.0) if span > 1e-6 else 1.0
			return lerpf(float(prev[1]), float(k[1]), _ease(w, int(k[2])))
		prev = k
	return float(prev[1])


## Where a move cut short t seconds in leaves the feet: the latest point of plan up to t where a
## standing body fits (half over a ledge it does not, so it goes back to the face), the start at
## worst.
static func clear_point(col: CollisionWorld, plan: Dictionary, t: float) -> Vector3:
	var k := t
	while k > 0.0:
		var p := point(plan, k)
		if fits(col, p):
			return p
		k -= PATH_STEP
	return point(plan, 0.0)


static func _ease(w: float, how: int) -> float:
	match how:
		EASE_OUT:
			return 1.0 - (1.0 - w) * (1.0 - w)
		EASE_IN:
			return w * w
		SMOOTH:
			return w * w * (3.0 - 2.0 * w)
	return w


## The nearest obstacle the body meets moving along d (unit) from pos with a gap of at most reach
## to its face: {"u": the unit axis into its face, "face" and "far": the distances along u from pos
## to its face and to its far side}, or {} (nothing there, or met at a glance).
static func find_face(col: CollisionWorld, pos: Vector3, d: Vector2, reach: float) -> Dictionary:
	var o := Vector2(pos.x, pos.z)
	var grow := Vector2(R, R)
	var best := INF
	var box := AABB()
	var axis := -1
	for b: AABB in col.boxes_near(pos, reach + 2.0 * R):
		if b.end.y <= pos.y + WS.STEP_HEIGHT + 1e-6 or b.position.y >= pos.y + WS.PLAYER_HEIGHT:
			continue
		var lo := Vector2(b.position.x, b.position.z)
		var hit := _enter(o, d, lo - grow, Vector2(b.end.x, b.end.z) + grow)
		if hit.x < best and hit.x <= reach and hit.x >= -0.5 * R:
			best = hit.x
			box = b
			axis = int(hit.y)
	if axis < 0 or absf(d[axis]) < APPROACH_COS:
		return {}
	var u := Vector2.ZERO
	u[axis] = signf(d[axis])
	var lo := Vector2(box.position.x, box.position.z)
	var hi := Vector2(box.end.x, box.end.z)
	if u[axis] > 0.0:
		return {"u": u, "face": lo[axis] - o[axis], "far": hi[axis] - o[axis]}
	return {"u": u, "face": o[axis] - hi[axis], "far": o[axis] - lo[axis]}


## Where a ray from o along d enters the rectangle lo..hi: (distance, the axis it enters across:
## 0 x, 1 z), negative from inside; (INF, -1) when it misses.
static func _enter(o: Vector2, d: Vector2, lo: Vector2, hi: Vector2) -> Vector2:
	var t0 := -INF
	var t1 := INF
	var axis := -1
	for a in range(2):
		if absf(d[a]) < 1e-9:
			if o[a] <= lo[a] or o[a] >= hi[a]:
				return Vector2(INF, -1)
			continue
		var ta := (lo[a] - o[a]) / d[a]
		var tb := (hi[a] - o[a]) / d[a]
		if minf(ta, tb) > t0:
			t0 = minf(ta, tb)
			axis = a
		t1 = minf(t1, maxf(ta, tb))
	if axis < 0 or t0 > t1 or t1 <= 0.0:
		return Vector2(INF, -1)
	return Vector2(t0, axis)


## Over a low, thin obstacle: up to CLEAR above its top by its face, across, and down beyond it as
## far as the speed carries (nearer when that spot is taken). face is find_face()'s answer. {}
## with nowhere to land or no room on the way.
static func _vault(
	col: CollisionWorld, pos: Vector3, u: Vector2, face: Dictionary, top: float, speed: float
) -> Dictionary:
	var v := clampf(speed, VAULT_SPEED, WS.RUN)
	var peak := top + CLEAR
	var far: float = face["far"]
	var s_rise := maxf(float(face["face"]) - 0.5 * R, 0.0)
	var s_over := far + 0.5 * R
	var t_rise := maxf(s_rise / v, RISE_MIN)
	var t_over := t_rise + maxf((s_over - s_rise) / v, OVER_MIN)
	var fall := sqrt(2.0 * (peak - pos.y) / WS.GRAVITY)
	for f: float in LAND_FRACTIONS:
		var s_land := maxf(s_over + f * v * fall, far + R + LAND_GAP)
		var land := _at(pos, u, s_land, pos.y)
		var g := col.support_height(land, R, pos.y, WS.STEP_HEIGHT)
		if is_nan(g) or g < pos.y - VAULT_DROP or not fits(col, _at(pos, u, s_land, g)):
			continue
		var t_drop := maxf(sqrt(2.0 * (peak - g) / WS.GRAVITY), DROP_MIN)
		var t_end := t_over + t_drop
		var s := [
			[0.0, 0.0, LIN], [t_rise, s_rise, LIN], [t_over, s_over, LIN], [t_end, s_land, LIN]
		]
		var y := [
			[0.0, pos.y, LIN], [t_rise, peak, EASE_OUT], [t_over, peak, LIN], [t_end, g, EASE_IN]
		]
		var plan := make_plan("vault", pos, u, top, s, y)
		plan["exit"] = _exit(u, (s_land - s_over) / t_drop, 2.0 * (peak - g) / t_drop)
		if _clear(col, plan, face):
			return plan
	return {}


## Up onto a low ledge: up to CLEAR above it by its face, then forward and down onto it, where
## face["stand"] says. {} without room on the way.
static func _hop(
	col: CollisionWorld, pos: Vector3, u: Vector2, face: Dictionary, top: float, speed: float
) -> Dictionary:
	var v := clampf(speed, VAULT_SPEED, WS.RUN)
	var stand: float = face["stand"]
	var s_rise := maxf(float(face["face"]) - 0.5 * R, 0.0)
	var t_rise := maxf(s_rise / v, RISE_MIN)
	var t_down := maxf((stand - s_rise) / v, DROP_MIN)
	var s := [[0.0, 0.0, LIN], [t_rise, s_rise, LIN], [t_rise + t_down, stand, LIN]]
	var y := [[0.0, pos.y, LIN], [t_rise, top + CLEAR, EASE_OUT], [t_rise + t_down, top, EASE_IN]]
	var plan := make_plan("hop", pos, u, top, s, y)
	plan["exit"] = _exit(u, (stand - s_rise) / t_down, 2.0 * CLEAR / t_down)
	return plan if _clear(col, plan, face) else {}


## Up onto a ledge too high to hop: to the face at the body's pace, then the climb clip while the
## body rises to the top and steps forward onto it, where face["stand"] says. {} without room to
## pull up.
static func _climb(
	col: CollisionWorld, pos: Vector3, u: Vector2, face: Dictionary, top: float, speed: float
) -> Dictionary:
	var stand: float = face["stand"]
	var s_touch := maxf(float(face["face"]) - R, 0.0)
	var t0 := s_touch / maxf(speed, APPROACH)
	var tc := CLIMB_T + CLIMB_PER_M * (top - pos.y) / WS.M
	if col.body_blocked(_at(pos, u, s_touch, top + 1e-4), R * 0.9, WS.PLAYER_HEIGHT):
		return {}
	var t_step := t0 + CLIMB_STEP * tc
	var s := [[0.0, 0.0, LIN], [t0, s_touch, LIN], [t_step, s_touch, LIN], [t0 + tc, stand, SMOOTH]]
	var y := [[0.0, pos.y, LIN], [t0 + CLIMB_RISE * tc, pos.y, LIN], [t0 + tc, top, SMOOTH]]
	var plan := make_plan("climb", pos, u, top, s, y)
	plan["anim_at"] = t0
	plan["anim_len"] = tc
	plan["grounded"] = true
	return plan if _clear(col, plan, face) else {}


## A plan (find() lists its keys) of move from the feet at pos across u, over or onto top, along
## the tracks s and y.
static func make_plan(
	move: String, pos: Vector3, u: Vector2, top: float, s: Array, y: Array
) -> Dictionary:
	return {
		"move": move,
		"from": pos,
		"dir": Vector3(u.x, 0.0, u.y),
		"top": top,
		"s": s,
		"y": y,
		"length": float(s[s.size() - 1][0]),
		"anim_at": -1.0,
		"anim_len": 0.0,
		"grounded": false,
		"exit": Vector3.ZERO,
	}


## Forward along u at speed and down at sink (u/s), the sink capped at LAND_V.
static func _exit(u: Vector2, speed: float, sink: float) -> Vector3:
	return Vector3(u.x * speed, -minf(sink, LAND_V), u.y * speed)


## True when the tucked body has room all along plan. Over the obstacle (face: find_face()'s
## answer) it counts from the obstacle's top up: a climb comes over the edge from below it, and a
## vault or a hop is above it there anyway.
static func _clear(col: CollisionWorld, plan: Dictionary, face: Dictionary) -> bool:
	var length: float = plan["length"]
	var top: float = plan["top"]
	var near := float(face["face"]) - TUCK_R
	var far := float(face["far"]) + TUCK_R
	var n := maxi(1, ceili(length / PATH_STEP))
	for k in range(1, n + 1):
		var t := length * float(k) / float(n)
		var p := point(plan, t)
		var s := sample(plan["s"], t)
		if s > near and s < far:
			p.y = maxf(p.y, top + 1e-4)
		if col.body_blocked(p, TUCK_R, TUCK):
			return false
	return true


## True when a whole standing body fits with the feet at p.
static func fits(col: CollisionWorld, p: Vector3) -> bool:
	return not col.body_blocked(p, R * 0.99, WS.PLAYER_HEIGHT)


static func _at(pos: Vector3, u: Vector2, s: float, y: float) -> Vector3:
	return Vector3(pos.x + u.x * s, y, pos.z + u.y * s)
