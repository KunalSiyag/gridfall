extends RefCounted
## Where a crew works on a construction site, from the site's CrewGrid: the door just inside the
## gap ConstructionKit leaves in the hoarding toward the frontage road (a waypoint), the
## foreman's spot to one side of it and a pile to the other, work spots nearest the middle of the
## site (a little toward the gate) that the door reaches, a drop point by the first work spot with
## the hauler's way there and back, and the point outside the gate an arriving crew comes from.
## route() is the way between two places on the site.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const GRID := preload("res://scripts/fp/crews/crew_grid.gd")
## A worker's footprint radius and height for the free test outside the site, and the gap kept
## between two.
const RADIUS := GRID.RADIUS
const HEIGHT := GRID.HEIGHT
const APART := 1.4 * WS.M
## ConstructionKit._fence's sides; without a frontage road the gate is side (CityView's tile
## hash) % 4.
const FENCE_SIDES: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)
]
## The door, DOOR_IN in from the tile centre on the gate side, and the start outside the gate,
## GATE_OUT out (the hoarding stands at 0.47).
const DOOR_IN := 0.4
const GATE_OUT := 0.56
## Across the gate from the door: the foreman to one side, the pile to the other. A drop point is
## at most DROP_REACH from the work.
const FOREMAN_SIDE := 0.08
const PILE_SIDE := 0.12
const DROP_REACH := 0.2
## Work spots are the ones nearest a point WORK_LEAN from the middle toward the gate: of two alike
## (the scaffold's sides), the one in sight of the road.
const WORK_LEAN := 0.06
## Step between the points a straight walk outside the site is tested at.
const SAMPLE := 0.6 * WS.M
const NONE := Vector3(NAN, NAN, NAN)


## True when p is a point (not NONE).
static func found(p: Vector3) -> bool:
	return not is_nan(p.x)


## The hoarding's open side on tile i as ConstructionKit draws it: toward the lot's frontage road,
## else side (CityView's tile hash) % 4 of FENCE_SIDES.
static func gate_side(directory: CityDirectory, i: int) -> Vector2i:
	var f := directory.frontage(i) if directory != null else -1
	if f >= 0:
		return Vector2i(D.tx(f) - D.tx(i), D.ty(f) - D.ty(i))
	return FENCE_SIDES[absi(D.tx(i) * 73856093 ^ D.ty(i) * 19349663) % 4]


## True for sites ConstructionKit hoards in: all but roads, bridges and added storeys.
static func fenced(s: Dictionary) -> bool:
	return str(s.get("type", "")) != "road" and str(s.get("plan", "")) != "zone_up"


## The side a crew comes in from on tile i: the gate of a hoarded site (as drawn, else as it will
## be), else a side with a finished road, else south.
static func entry_side(ctx: FpContext, i: int) -> Vector2i:
	var x := D.tx(i)
	var y := D.ty(i)
	var s: Dictionary = ctx.sim.sites.get(i, {})
	if not s.is_empty() and fenced(s):
		var drawn := ctx.view.site_gate(i) if ctx.view != null else Vector2i.ZERO
		return drawn if drawn != Vector2i.ZERO else gate_side(ctx.directory, i)
	for d: Vector2i in FENCE_SIDES:
		if D.in_bounds(x + d.x, y + d.y) and ctx.sim.kind[D.idx(x + d.x, y + d.y)] == D.ROAD:
			return d
	return Vector2i(0, 1)


## The crew's places on site i as drawn now: {"middle", "door" (a waypoint, shared), "gate" (the
## foreman's spot), "out", "pile", "drop" (Vector3, NONE when there is no room), "work":
## Array[Vector3] (up to n spots, nearest the middle first), "haul" / "back" (Array[Vector3], the
## way from the pile to the drop and back), "side": Vector2i (entry side), "grid": CrewGrid}.
## A spot the door does not reach (a scaffold board) is only taken when nothing else is left;
## without a door on the ground (the finished building fills the hoarding) every spot is reached.
static func layout(ctx: FpContext, i: int, n: int) -> Dictionary:
	var g: GRID = GRID.new()
	g.setup(ctx, i)
	var c := g.c
	var side := entry_side(ctx, i)
	var dv := Vector3(side.x, 0.0, side.y)
	var across := Vector3(-dv.z, 0.0, dv.x)
	var none: Array[Vector3] = []
	var out := {"middle": c, "side": side, "grid": g, "drop": NONE, "haul": none, "back": none}
	var at_door := c + dv * DOOR_IN
	var door := g.near(at_door, GRID.CLIMB)
	var reach := _reached(g, door)
	var used: Array[Vector3] = []
	out["door"] = g.pos[door] if door >= 0 else NONE
	out["gate"] = _take(g, reach, used, at_door - across * FOREMAN_SIDE)
	var work: Array[Vector3] = []
	var lean := c + dv * WORK_LEAN
	for _k in range(maxi(n, 0)):
		var w := _take(g, reach, used, lean)
		w = w if found(w) else _take(g, _reached(g, -1), used, lean)
		if not found(w):
			break
		work.append(w)
	out["work"] = work
	out["pile"] = _take(g, reach, used, at_door + across * PILE_SIDE)
	_haul(g, out, used)
	out["out"] = _outside(ctx.collision, c, dv, out["door"])
	return out


## The way from a to b over lay's site: the points to walk through after a (from the node nearest
## a, a step up or down at most, when a is off it), ending at b's node; [] when there is none.
static func route(lay: Dictionary, a: Vector3, b: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var g: GRID = lay.get("grid")
	if g == null:
		return out
	var na := g.near(a, GRID.CLIMB)
	out = g.path(na, g.near(b))
	if not out.is_empty() and g.pos[na].distance_to(a) > GRID.LEVEL_GAP:
		out.push_front(g.pos[na])
	return out


## True when p is one of the places on lay's site where a worker fits.
static func stands(lay: Dictionary, p: Vector3) -> bool:
	var g: GRID = lay.get("grid")
	return g != null and g.stands(p)


## True when a person can stand at p (x, z) on the walkable ground (CollisionWorld).
static func fits(col: CollisionWorld, p: Vector3) -> bool:
	var g := col.ground_height(p)
	return not is_nan(g) and not col.body_blocked(Vector3(p.x, g, p.z), RADIUS, HEIGHT)


## True when a person walks from a to b in a straight line on the ground without running into
## anything.
static func line_clear(col: CollisionWorld, a: Vector3, b: Vector3) -> bool:
	var n := maxi(ceili(_flat(a, b) / SAMPLE), 1)
	for k in range(1, n):
		if not fits(col, a.lerp(b, float(k) / float(n))):
			return false
	return true


## The nodes the door reaches (every node without a door).
static func _reached(g: GRID, door: int) -> Array[int]:
	var out: Array[int] = []
	var parent := g.tree(door) if door >= 0 else PackedInt32Array()
	for k in range(g.pos.size()):
		if door < 0 or parent[k] >= 0:
			out.append(k)
	return out


## Takes the node of pool nearest target that keeps APART from every used point (and adds it to
## used); NONE when none is left.
static func _take(g: GRID, pool: Array[int], used: Array[Vector3], target: Vector3) -> Vector3:
	var best := NONE
	var best_d := INF
	for k: int in pool:
		var p := g.pos[k]
		var d := _flat(p, target)
		if d < best_d and _clear_of(p, used):
			best = p
			best_d = d
	if found(best):
		used.append(best)
	return best


## The drop point by the first work spot that the pile reaches without the hauler walking into
## the rest of the crew, and the hauler's way there and back.
static func _haul(g: GRID, out: Dictionary, used: Array[Vector3]) -> void:
	var pile: Vector3 = out["pile"]
	var work: Array[Vector3] = out["work"]
	if not found(pile) or work.is_empty():
		return
	var a := g.near(pile)
	var others: Array[Vector3] = []
	for u: Vector3 in used:
		if u != pile:
			others.append(u)
	var skip := g.taken_by(others)
	var parent := g.tree(a, skip)
	var pool: Array[int] = []
	for k in range(g.pos.size()):
		if parent[k] >= 0 and k != a and _flat(g.pos[k], work[0]) <= DROP_REACH:
			pool.append(k)
	var drop := _take(g, pool, used, work[0])
	if not found(drop):
		return
	var b := g.near(drop)
	out["drop"] = drop
	out["haul"] = g.path(a, b, skip)
	out["back"] = g.path(b, a, skip)


## Where an arriving crew starts: just outside the gate when it can walk in to the door from
## there, else the door itself.
static func _outside(col: CollisionWorld, c: Vector3, dv: Vector3, door: Vector3) -> Vector3:
	if col == null:
		return door
	for k: float in [GATE_OUT, GATE_OUT + 0.06, GATE_OUT + 0.12]:
		var p := c + dv * k
		if not fits(col, p):
			continue
		p.y = col.ground_height(p)
		if not found(door) or line_clear(col, p, door):
			return p
	return door


static func _clear_of(p: Vector3, used: Array[Vector3]) -> bool:
	for u: Vector3 in used:
		if _flat(p, u) < APART:
			return false
	return true


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
