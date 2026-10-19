extends RefCounted
## Right-hand lane graph over the road tiles (docs/fp/slices/E-traffic.md §1). Pure data: every
## lane is a polyline sampled every STEP units with cumulative lengths, keyed by (tile, entry edge,
## exit edge) so a rebuild keeps lane identity (agents hold Lane references). Geometry mirrors
## RoadTopology and the road GLBs: lane centres LANE_OFFSET right of travel (PASS_OFFSET beside
## parked cars), corner arcs about the shared tile corner, junction moves from the stop line to the
## exit edge, a U-turn loop on ends. Also owns the curb parking slots and the blocked-tile set.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const HEAP := preload("res://scripts/fp/traffic/heap.gd")
const STEP := 0.02
## Arm directions in N, E, S, W order (RoadTopology bit order); y is world +Z.
const DIRS: Array[Vector2] = [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)]
const OPP: Array[int] = [2, 3, 0, 1]
## Lane kinds.
const STRAIGHT := 0
const CORNER := 1
const APPROACH := 2
const MOVE := 3
const UTURN := 4
## Car fronts stop here, measured from the junction centre: just outside the zebra. The painted
## stop line (WS.STOP_LINE, roads.py) lies on the junction side of the zebra, so a car held on it
## would stand on the crossing while people walk it (request to G1: docs/fp/requests/E-needs.md).
const STOP_FRONT := WS.ZEBRA_FAR + 0.4 * WS.M
const ZEBRA_MID := (WS.ZEBRA_NEAR + WS.ZEBRA_FAR) * 0.5
## Curb parking: two slots per side of a straight tile, centres 3 m either side of the middle
## (6 m spacing); slot k: side k / 2 (0 = right of the run direction), along -/+ for k % 2.
const SLOT_ALONG := 3.0 * WS.M
const SLOTS := 4
## Length of the lateral shift between LANE_OFFSET and PASS_OFFSET at a tile end.
const SHIFT_LEN := 0.2
## A slot is unusable when a fixed-offset edge (no compatible straight beyond it) is closer than
## this along the run: the shift zone plus half the longest moving vehicle (bus) plus half the
## longest parked one, so no moving AABB ever overlaps a parked AABB.
const SLOT_EDGE_CLEAR := SHIFT_LEN + 0.31 + 0.14
## Lateral acceleration used for curve speed limits (2.2 m/s²).
const A_LAT := 2.2 * WS.M
## Loop radius of the cul-de-sac U-turn about the turning circle centre.
const UTURN_R := 0.235
## Two move lanes whose centrelines come closer than this conflict (a car is 2.1 m wide).
const CONFLICT_DIST := 0.11
## Route cost factor through a blocked tile for the vehicles that may cross one.
const BLOCKED_COST := 12.0


## One lane: a directed polyline on one road tile.
class Lane extends RefCounted:
	var id: int = -1
	var key: int = -1
	var tile: int = -1
	var from_e: int = -1          # entry edge 0..3 (N, E, S, W)
	var to_e: int = -1            # exit edge 0..3; -1 for an approach (ends at the stop line)
	var kind: int = 0
	var turn: int = 0             # 0 straight, 1 right, -1 left, 2 u-turn
	var pts := PackedVector2Array()
	var cum := PackedFloat32Array()
	var length: float = 0.0
	var limit: float = 0.0        # u/s, street limit capped by the curve
	var base_limit: float = 0.0   # street limit before the curve cap
	var cars: Array = []          # vehicles whose front is on the lane, ascending s (agents keep it)
	var tails: Array = []         # vehicles whose body still covers the lane, front further on
	var conflicts := PackedInt32Array()   # move: conflicting move lane ids in the same junction
	var conflict_clear := PackedFloat32Array()   # per conflict: s on that lane past which it is clear
	var yield_to := PackedInt32Array()    # move: entry edges whose crossing traffic has priority
	var gap_s: float = 0.0        # move: seconds of gap it needs from those
	var zebra_s0: float = -1.0    # approach: entry zebra; move: exit zebra (front s range)
	var zebra_s1: float = -1.0
	var zebra_arm: int = -1       # arm of that zebra on this tile
	var stop_s: float = -1.0      # approach: s at which a held front stops
	var side: int = -1            # straight: side index of the run (0 right of run_dir, 1 left)
	var shifted: bool = false     # straight: some part of it runs at PASS_OFFSET
	var alive: bool = true


## Per road tile: its mask, piece and lanes.
class TileInfo extends RefCounted:
	var tile: int = -1
	var mask: int = 0
	var piece: String = ""
	var bridge: bool = false
	var lanes: Array = []                 # every Lane on the tile
	var entry: Array = [[], [], [], []]   # lanes that start at edge e
	var approach: Array = [null, null, null, null]
	var moves: Array = [[], [], [], []]   # junction moves by entry edge
	var lights: bool = false              # cross: traffic lights
	var stem: int = -1                    # tee: the arm that yields
	var stem_residential: bool = false
	var residential: bool = false


var sim: CitySim
var lanes: Array = []                     # id -> Lane or null
var tiles: Dictionary = {}                # tile -> TileInfo
var blocked: Dictionary = {}              # tile -> true (broken road, crash or downed line)
## Occupied curb slots: (tile * SLOTS + k) -> owner key (String).
var slots: Dictionary = {}
## Occupied slots per side: (tile * 2 + side) -> count.
var parked_sides: Dictionary = {}
## Bus-stop sides: tile -> side index whose curb is kept free for the bus.
var stop_sides: Dictionary = {}
var builds: int = 0                       # tile rebuilds since setup (tests)
## While true, slot changes skip the lane rebuild (the caller rebuilds once afterwards).
var bulk: bool = false
## Tiles whose lanes were rebuilt since the last take_dirty() (agents re-place their nodes).
var dirty: Dictionary = {}
var _free: Array[int] = []
var _by_key: Dictionary = {}
var _conflict_cache: Dictionary = {}      # mask -> Dictionary
var _geom_cache: Dictionary = {}          # shape key -> [local pts, cum, length, kmax(, zebra s0, s1)]


func setup(p_sim: CitySim) -> void:
	sim = p_sim
	slots.clear()
	parked_sides.clear()
	clear()


func clear() -> void:
	for l: Variant in lanes:
		if l != null:
			(l as Lane).alive = false
	lanes.clear()
	tiles.clear()
	_free.clear()
	_by_key.clear()


## Rebuilds every road tile in sim.active.
func rebuild_all() -> void:
	clear()
	refresh_blocked()
	for i in sim.active:
		if sim.kind[i] == D.ROAD:
			rebuild_tile(i)


## Rebuilds tile i and its four neighbours (a road tile was built or cleared).
func rebuild_around(i: int) -> void:
	rebuild_tile(i)
	for n: int in neighbours(i):
		rebuild_tile(n)


## In-bounds 4-neighbour tile indices of i.
func neighbours(i: int) -> Array[int]:
	var out: Array[int] = []
	var x := D.tx(i)
	var y := D.ty(i)
	for d: Vector2 in DIRS:
		if D.in_bounds(x + int(d.x), y + int(d.y)):
			out.append(D.idx(x + int(d.x), y + int(d.y)))
	return out


func is_empty() -> bool:
	return lane_count() == 0


func lane_count() -> int:
	return lanes.size() - _free.size()


func info(i: int) -> TileInfo:
	return tiles.get(i, null)


## Tile across edge e of tile i, or -1.
func across(i: int, e: int) -> int:
	var x := D.tx(i) + int(DIRS[e].x)
	var y := D.ty(i) + int(DIRS[e].y)
	return D.idx(x, y) if D.in_bounds(x, y) else -1


## Lanes that begin at edge e of tile i (a junction's approach, else the through lane).
func entry(i: int, e: int) -> Array:
	var t: TileInfo = tiles.get(i, null)
	return t.entry[e] if t != null else []


## Lanes an agent can take after reaching the end of l.
func next_lanes(l: Lane) -> Array:
	if l.kind == APPROACH:
		var t: TileInfo = tiles.get(l.tile, null)
		return t.moves[l.from_e] if t != null else []
	var n := across(l.tile, l.to_e)
	return entry(n, OPP[l.to_e]) if n >= 0 else []


## Lanes that end where l begins (upstream), for gap checks.
func prev_lanes(l: Lane) -> Array:
	if l.kind == MOVE:
		var t: TileInfo = tiles.get(l.tile, null)
		return [t.approach[l.from_e]] if t != null and t.approach[l.from_e] != null else []
	var out: Array = []
	var n := across(l.tile, l.from_e)
	if n < 0:
		return out
	var t: TileInfo = tiles.get(n, null)
	if t == null:
		return out
	for o: Lane in t.lanes:
		if o.to_e == OPP[l.from_e]:
			out.append(o)
	return out


## The lane on tile i from entry edge fe to exit edge te (a move for junctions), or null.
func lane_between(i: int, fe: int, te: int) -> Lane:
	return _by_key.get(_key(i, fe, te), null)


## World xz of the point at distance s along l (clamped to the lane).
func pos_at(l: Lane, s: float) -> Vector2:
	var n := l.pts.size()
	if n < 2:
		return l.pts[0] if n == 1 else Vector2.ZERO
	if s <= 0.0:
		return l.pts[0]
	if s >= l.length:
		return l.pts[n - 1]
	var k := _seg(l, s)
	var a := l.cum[k]
	var b := l.cum[k + 1]
	return l.pts[k].lerp(l.pts[k + 1], clampf((s - a) / maxf(b - a, 1e-6), 0.0, 1.0))


## Unit tangent of l at distance s.
func tan_at(l: Lane, s: float) -> Vector2:
	var n := l.pts.size()
	if n < 2:
		return Vector2(0, -1)
	var k := _seg(l, clampf(s, 0.0, l.length))
	var d := l.pts[k + 1] - l.pts[k]
	return d.normalized() if d.length_squared() > 0.0 else Vector2(0, -1)


func _seg(l: Lane, s: float) -> int:
	var n := l.pts.size()
	var k := clampi(int(s / STEP), 0, n - 2)
	while k > 0 and l.cum[k] > s:
		k -= 1
	while k < n - 2 and l.cum[k + 1] < s:
		k += 1
	return k


## Distance along l of the point closest to p (xz).
func project(l: Lane, p: Vector2) -> float:
	var best := INF
	var best_s := 0.0
	for k in range(l.pts.size() - 1):
		var a := l.pts[k]
		var ab := l.pts[k + 1] - a
		var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
		var d := (a + ab * t).distance_squared_to(p)
		if d < best:
			best = d
			best_s = l.cum[k] + t * (l.cum[k + 1] - l.cum[k])
	return best_s


## How far a straight lane is pulled in toward PASS_OFFSET at s (0 = LANE_OFFSET, 1 = PASS_OFFSET).
func pass_factor(l: Lane, s: float) -> float:
	if not l.shifted:
		return 0.0
	var p := pos_at(l, s)
	var c := Vector2(D.tx(l.tile), D.ty(l.tile))
	var off := (p - c).dot(_right(-DIRS[l.from_e]))
	return clampf((WS.LANE_OFFSET - off) / (WS.LANE_OFFSET - WS.PASS_OFFSET), 0.0, 1.0)


# ------------------------------------------------------------------ blocking and parking

## Re-reads broken roads and road-blocking events (car_crash, power_line). Returns true on change.
func refresh_blocked() -> bool:
	var nb := {}
	for k: Variant in sim.broken_roads.keys():
		nb[int(k)] = true
	for ev: Dictionary in sim.events:
		var t := str(ev.get("type", ""))
		if t == "car_crash" or t == "power_line":
			var x := int(ev.get("x", 0))
			var y := int(ev.get("y", 0))
			if D.in_bounds(x, y) and sim.kind[D.idx(x, y)] == D.ROAD:
				nb[D.idx(x, y)] = true
	var changed := nb.size() != blocked.size()
	if not changed:
		for k: int in nb.keys():
			if not blocked.has(k):
				changed = true
				break
	blocked = nb
	return changed


func is_blocked(i: int) -> bool:
	return blocked.has(i)


## True when straight tile i can take curb parking at all (not a bridge, not a junction).
func parkable(i: int) -> bool:
	var t: TileInfo = tiles.get(i, null)
	return t != null and t.piece == "straight" and not t.bridge and t.mask != 0


## Run direction (xz) of straight tile i.
func run_dir(i: int) -> Vector2:
	var t: TileInfo = tiles.get(i, null)
	var m := t.mask if t != null else RoadTopology.mask(sim, D.tx(i), D.ty(i))
	var f3 := RoadTopology.run_dir(m)
	return Vector2(f3.x, f3.z)


## Side index (0 right of run_dir, 1 left) of straight tile i that a vehicle heading h drives on.
func side_of_heading(i: int, h: Vector2) -> int:
	return 0 if run_dir(i).dot(h) > 0.0 else 1


## [pos: Vector2 (world xz), heading: Vector2] of curb slot k of straight tile i. The car faces
## the traffic on its side (right-hand).
func slot_pose(i: int, k: int) -> Array:
	var f := run_dir(i)
	var r := _right(f)
	var side := 1.0 if k < 2 else -1.0
	var along := (-SLOT_ALONG if k % 2 == 0 else SLOT_ALONG) * side
	var c := Vector2(D.tx(i), D.ty(i))
	return [c + f * along + r * (side * WS.PARK_OFFSET), f * side]


## True when slot k of tile i is usable: a parkable straight, clear of fixed-offset edges (where
## the moving lane cannot shift outside the tile) and of a bus-stop curb.
func slot_valid(i: int, k: int) -> bool:
	if not parkable(i):
		return false
	var sidx := k / 2
	if int(stop_sides.get(i, -1)) == sidx:
		return false
	var along := (-SLOT_ALONG if k % 2 == 0 else SLOT_ALONG) * (1.0 if sidx == 0 else -1.0)
	var f := run_dir(i)
	for e in range(4):
		if absf(DIRS[e].dot(f)) < 0.5:
			continue
		if _compat(i, e):
			continue
		var edge_along := 0.5 * DIRS[e].dot(f)
		if absf(edge_along - along) < SLOT_EDGE_CLEAR:
			return false
	return true


func slot_free(i: int, k: int) -> bool:
	return not slots.has(i * SLOTS + k)


func slot_owner(i: int, k: int) -> String:
	return str(slots.get(i * SLOTS + k, ""))


## Marks curb slot k of tile i as taken by owner (or freed with ""), rebuilding the lanes beside
## it when its side changes between empty and occupied.
func set_slot(i: int, k: int, owner: String) -> void:
	var key := i * SLOTS + k
	var had := slots.has(key)
	if owner.is_empty():
		if not had:
			return
		slots.erase(key)
		_side_count(i, k / 2, -1)
	else:
		slots[key] = owner
		if not had:
			_side_count(i, k / 2, 1)


func _side_count(i: int, sidx: int, d: int) -> void:
	var key := i * 2 + sidx
	var was := parked_sides.has(key)
	var n := int(parked_sides.get(key, 0)) + d
	if n <= 0:
		parked_sides.erase(key)
	else:
		parked_sides[key] = n
	if not bulk and was != parked_sides.has(key) and tiles.has(i):
		rebuild_around(i)


func side_parked(i: int, sidx: int) -> bool:
	return parked_sides.has(i * 2 + sidx)


## Slot indices on the curb a vehicle heading h on straight tile i would pull into.
func slots_on_heading(i: int, h: Vector2) -> Array[int]:
	var sidx := side_of_heading(i, h)
	return [sidx * 2, sidx * 2 + 1]


# ------------------------------------------------------------------ building

func _key(i: int, fe: int, te: int) -> int:
	return i * 25 + (fe + 1) * 5 + (te + 1)


func _lane(i: int, fe: int, te: int, kind: int, keep: Dictionary) -> Lane:
	var k := _key(i, fe, te)
	var l: Lane = _by_key.get(k, null)
	if l == null:
		l = Lane.new()
		if _free.is_empty():
			l.id = lanes.size()
			lanes.append(l)
		else:
			l.id = _free.pop_back()
			lanes[l.id] = l
		l.key = k
		_by_key[k] = l
	l.tile = i
	l.from_e = fe
	l.to_e = te
	l.kind = kind
	l.alive = true
	l.conflicts = PackedInt32Array()
	l.conflict_clear = PackedFloat32Array()
	l.yield_to = PackedInt32Array()
	l.gap_s = 0.0
	l.zebra_s0 = -1.0
	l.zebra_s1 = -1.0
	l.zebra_arm = -1
	l.stop_s = -1.0
	l.side = -1
	l.shifted = false
	keep[k] = true
	return l


func _drop(l: Lane) -> void:
	l.alive = false
	_by_key.erase(l.key)
	lanes[l.id] = null
	_free.append(l.id)


## Rebuilds the lanes of tile i from sim.kind and RoadTopology (removes them when it is no road).
func rebuild_tile(i: int) -> void:
	var old: TileInfo = tiles.get(i, null)
	if sim.kind[i] != D.ROAD:
		if old != null:
			for l: Lane in old.lanes:
				_drop(l)
			tiles.erase(i)
			dirty[i] = true
		_free_tile_slots(i)
		return
	builds += 1
	dirty[i] = true
	var x := D.tx(i)
	var y := D.ty(i)
	var m := RoadTopology.mask(sim, x, y)
	var t := TileInfo.new()
	t.tile = i
	t.mask = m
	t.piece = str(RoadTopology.piece(m)[0])
	t.bridge = RoadTopology.is_bridge(sim, i)
	t.residential = _residential(x, y)
	tiles[i] = t
	var keep := {}
	var arms: Array[int] = []
	for e in range(4):
		if m & (1 << e):
			arms.append(e)
	var c := Vector2(x, y)
	var limit := WS.CAR_RESIDENTIAL if t.residential else WS.CAR_CITY
	if arms.size() == 1:
		var l := _lane(i, arms[0], arms[0], UTURN, keep)
		var ue: int = arms[0]
		_set_geom(l, _geom(Vector4(64 + ue, 0, 0, 0), func() -> PackedVector2Array: return _uturn_pts(ue)), c, limit)
		l.turn = 2
		t.lanes.append(l)
		t.entry[arms[0]].append(l)
	elif arms.size() == 2 and arms[1] == OPP[arms[0]]:
		for e: int in arms:
			var l := _lane(i, e, OPP[e], STRAIGHT, keep)
			var sh := _straight_shape(i, e, l)
			var se := e
			_set_geom(l, _geom(Vector4(se, sh.x, sh.y, sh.z), func() -> PackedVector2Array: return _straight_pts(se, sh)), c, limit)
			l.turn = 0
			t.lanes.append(l)
			t.entry[e].append(l)
	elif arms.size() == 2:
		for k in range(2):
			var e: int = arms[k]
			var xo: int = arms[1 - k]
			var l := _lane(i, e, xo, CORNER, keep)
			_set_geom(l, _geom(Vector4(16 + e * 4 + xo, 0, 0, 0), func() -> PackedVector2Array: return _corner_pts(e, xo)), c, limit)
			l.turn = _turn(e, xo)
			t.lanes.append(l)
			t.entry[e].append(l)
	elif arms.size() >= 3:
		t.lights = arms.size() == 4
		if arms.size() == 3:
			for e in range(4):
				if not (m & (1 << e)):
					t.stem = OPP[e]
			var sx := x + int(DIRS[t.stem].x)
			var sy := y + int(DIRS[t.stem].y)
			t.stem_residential = _residential(sx, sy)
		for e: int in arms:
			var a := _lane(i, e, -1, APPROACH, keep)
			var ae := e
			_set_geom(a, _geom(Vector4(32 + ae, 0, 0, 0), func() -> PackedVector2Array: return _approach_pts(ae)), c, limit)
			a.turn = 0
			a.stop_s = clampf(0.5 - STOP_FRONT, 0.0, a.length)
			a.zebra_arm = e
			a.zebra_s0 = 0.5 - WS.ZEBRA_FAR
			a.zebra_s1 = 0.5 - WS.ZEBRA_NEAR
			t.lanes.append(a)
			t.entry[e].append(a)
			t.approach[e] = a
			for xo: int in arms:
				if xo == e:
					continue
				var mv := _lane(i, e, xo, MOVE, keep)
				var me := e
				var mx := xo
				var g := _geom(Vector4(48 + me * 4 + mx, 0, 0, 0), func() -> PackedVector2Array: return _move_pts(me, mx))
				_set_geom(mv, g, c, limit)
				mv.turn = _turn(e, xo)
				mv.zebra_arm = xo
				if g.size() < 6:
					g.append(_zebra_s(g[0], g[1], xo, WS.ZEBRA_NEAR))
					g.append(_zebra_s(g[0], g[1], xo, WS.ZEBRA_FAR))
				mv.zebra_s0 = g[4]
				mv.zebra_s1 = g[5]
				t.lanes.append(mv)
				t.moves[e].append(mv)
		_junction_rules(t)
	if old != null:
		for l: Lane in old.lanes:
			if not keep.has(l.key):
				_drop(l)
	if not parkable(i):
		_free_tile_slots(i)


func _free_tile_slots(i: int) -> void:
	for k in range(SLOTS):
		slots.erase(i * SLOTS + k)
	parked_sides.erase(i * 2)
	parked_sides.erase(i * 2 + 1)


## Tiles rebuilt since the last call (and clears the set).
func take_dirty() -> Dictionary:
	var d := dirty
	dirty = {}
	return d


func _residential(x: int, y: int) -> bool:
	var r := 0
	var other := 0
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if not D.in_bounds(x + dx, y + dy):
				continue
			var k := sim.kind[D.idx(x + dx, y + dy)]
			if k == D.ZONE_R:
				r += 1
			elif D.is_zone(k):
				other += 1
	return r > other


func _turn(fe: int, te: int) -> int:
	var hi := -DIRS[fe]
	var ho := DIRS[te]
	var cr := hi.x * ho.y - hi.y * ho.x
	if absf(cr) < 0.5:
		return 0
	return 1 if cr > 0.0 else -1


static func _right(h: Vector2) -> Vector2:
	return Vector2(-h.y, h.x)


## Tile-local entry point on edge e for traffic heading into the tile at lateral offset off.
static func entry_pt(e: int, off: float) -> Vector2:
	var a := DIRS[e]
	return a * 0.5 + _right(-a) * off


## Tile-local exit point on edge e for traffic leaving the tile at lateral offset off.
static func exit_pt(e: int, off: float) -> Vector2:
	var a := DIRS[e]
	return a * 0.5 + _right(a) * off


## True when the tile across edge e of straight tile i is a straight of the same orientation and
## neither is a bridge, so the moving lane may stay shifted across that edge.
func _compat(i: int, e: int) -> bool:
	var n := across(i, e)
	if n < 0 or sim.kind[n] != D.ROAD:
		return false
	var mi := RoadTopology.mask(sim, D.tx(i), D.ty(i))
	var mn := RoadTopology.mask(sim, D.tx(n), D.ty(n))
	return mn == mi and (mi == RoadTopology.NS or mi == RoadTopology.EW) and not RoadTopology.is_bridge(sim, i) and not RoadTopology.is_bridge(sim, n)


## [off_in, mid, off_out] of the straight lane on tile i entering at fe (and sets its side and
## shifted flags): PASS_OFFSET beside parked cars, easing to LANE_OFFSET where the run ends.
func _straight_shape(i: int, fe: int, l: Lane) -> Vector3:
	var h := -DIRS[fe]
	var te: int = OPP[fe]
	var sidx := side_of_heading(i, h)
	l.side = sidx
	var here := side_parked(i, sidx) and not RoadTopology.is_bridge(sim, i)
	var mid := WS.PASS_OFFSET if here else WS.LANE_OFFSET
	var off_in := _edge_off(i, fe, sidx, here)
	var off_out := _edge_off(i, te, sidx, here)
	l.shifted = here or off_in < WS.LANE_OFFSET or off_out < WS.LANE_OFFSET
	return Vector3(off_in, mid, off_out)


func _straight_pts(fe: int, sh: Vector3) -> PackedVector2Array:
	var h := -DIRS[fe]
	var r := _right(h)
	var n := int(ceil(1.0 / STEP))
	var out := PackedVector2Array()
	out.resize(n + 1)
	for k in range(n + 1):
		var u := float(k) / float(n)
		var off := sh.y
		if u < SHIFT_LEN:
			off = lerpf(sh.x, sh.y, smoothstep(0.0, SHIFT_LEN, u))
		elif u > 1.0 - SHIFT_LEN:
			off = lerpf(sh.y, sh.z, smoothstep(1.0 - SHIFT_LEN, 1.0, u))
		out[k] = -h * 0.5 + h * u + r * off
	return out


## Lateral offset at edge e of straight tile i on side sidx: PASS_OFFSET when the straight across
## that edge is compatible and either tile has cars parked on that side, so lanes meet at every
## edge and the shift happens on the tile without parked cars where it can.
func _edge_off(i: int, e: int, sidx: int, here: bool) -> float:
	if not _compat(i, e):
		return WS.LANE_OFFSET
	return WS.PASS_OFFSET if here or side_parked(across(i, e), sidx) else WS.LANE_OFFSET


func _corner_pts(fe: int, te: int) -> PackedVector2Array:
	var cc := (DIRS[fe] + DIRS[te]) * 0.5
	var p := entry_pt(fe, WS.LANE_OFFSET)
	var q := exit_pt(te, WS.LANE_OFFSET)
	var r := p.distance_to(cc)
	var a0 := (p - cc).angle()
	var a1 := (q - cc).angle()
	var da := wrapf(a1 - a0, -PI, PI)
	var n := maxi(2, int(ceil(absf(da) * r / STEP)))
	var out := PackedVector2Array()
	out.resize(n + 1)
	for k in range(n + 1):
		var a := a0 + da * float(k) / float(n)
		out[k] = cc + Vector2(cos(a), sin(a)) * r
	out[0] = p
	out[n] = q
	return out


func _approach_pts(e: int) -> PackedVector2Array:
	var a := DIRS[e]
	var p := entry_pt(e, WS.LANE_OFFSET)
	var q := a * WS.STOP_LINE + _right(-a) * WS.LANE_OFFSET
	return _line(p, q)


func _move_pts(fe: int, te: int) -> PackedVector2Array:
	var a := DIRS[fe]
	var b := DIRS[te]
	var s := a * WS.STOP_LINE + _right(-a) * WS.LANE_OFFSET
	var t := exit_pt(te, WS.LANE_OFFSET)
	if fe == OPP[te]:
		return _line(s, t)
	var dv := t - s
	var k_in := absf(dv.dot(-a)) * 0.55
	var k_out := absf(dv.dot(b)) * 0.55
	return _bezier(s, s - a * k_in, t - b * k_out, t)


func _uturn_pts(e: int) -> PackedVector2Array:
	var f := -DIRS[e]
	var r := _right(f)
	var o := f * WS.END_CIRCLE_OFFSET
	var way: Array[Vector2] = [r * WS.LANE_OFFSET - f * 0.5, r * WS.LANE_OFFSET - f * 0.25]
	for deg: float in [-35.0, 0.0, 45.0, 90.0, 135.0, 180.0, 215.0]:
		var a := deg_to_rad(deg)
		way.append(o + r * (cos(a) * UTURN_R) + f * (sin(a) * UTURN_R))
	way.append(-r * WS.LANE_OFFSET - f * 0.25)
	way.append(-r * WS.LANE_OFFSET - f * 0.5)
	return _catmull(way)


func _line(p: Vector2, q: Vector2) -> PackedVector2Array:
	var n := maxi(1, int(ceil(p.distance_to(q) / STEP)))
	var out := PackedVector2Array()
	out.resize(n + 1)
	for k in range(n + 1):
		out[k] = p.lerp(q, float(k) / float(n))
	return out


func _bezier(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2) -> PackedVector2Array:
	var dense := PackedVector2Array()
	var n := 96
	for k in range(n + 1):
		var t := float(k) / float(n)
		var u := 1.0 - t
		dense.append(p0 * (u * u * u) + p1 * (3.0 * u * u * t) + p2 * (3.0 * u * t * t) + p3 * (t * t * t))
	return _resample(dense)


func _catmull(way: Array[Vector2]) -> PackedVector2Array:
	var pts: Array[Vector2] = [way[0] * 2.0 - way[1]]
	pts.append_array(way)
	pts.append(way[way.size() - 1] * 2.0 - way[way.size() - 2])
	var dense := PackedVector2Array()
	for k in range(1, pts.size() - 2):
		var p0 := pts[k - 1]
		var p1 := pts[k]
		var p2 := pts[k + 1]
		var p3 := pts[k + 2]
		var n := 24
		for j in range(n):
			var t := float(j) / float(n)
			var t2 := t * t
			var t3 := t2 * t
			dense.append(0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3))
	dense.append(way[way.size() - 1])
	return _resample(dense)


## Resamples a dense polyline at STEP arc-length spacing (the last piece may be shorter).
func _resample(dense: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array([dense[0]])
	var acc := 0.0
	var next := STEP
	for k in range(dense.size() - 1):
		var a := dense[k]
		var b := dense[k + 1]
		var seg := a.distance_to(b)
		while acc + seg >= next and seg > 0.0:
			out.append(a.lerp(b, (next - acc) / seg))
			next += STEP
		acc += seg
	var last := dense[dense.size() - 1]
	if out[out.size() - 1].distance_to(last) > STEP * 0.25:
		out.append(last)
	else:
		out[out.size() - 1] = last
	return out


## Tile-local geometry of a lane shape, built once per key: [local points, cumulative lengths,
## length, max curvature] (moves add their zebra distances). Translation-invariant, so a tile
## rebuild only offsets cached points.
func _geom(key: Vector4, build: Callable) -> Array:
	var g: Array = _geom_cache.get(key, [])
	if not g.is_empty():
		return g
	var local: PackedVector2Array = build.call()
	var n := local.size()
	var cum := PackedFloat32Array()
	cum.resize(n)
	var acc := 0.0
	for k in range(n):
		if k > 0:
			acc += local[k].distance_to(local[k - 1])
		cum[k] = acc
	g = [local, cum, acc, _kmax(local, cum)]
	_geom_cache[key] = g
	return g


## Puts cached geometry g on lane l at tile centre c, with the speed limit: the street's limit
## capped by the tightest curvature (v = sqrt(a_lat * r)). The gentle lateral shift of a straight
## beside parked cars is no curve to slow down for.
func _set_geom(l: Lane, g: Array, c: Vector2, limit: float) -> void:
	# The tile-local shape offset to the tile centre in one native call.
	l.pts = Transform2D(0.0, c) * (g[0] as PackedVector2Array)
	l.cum = g[1]
	l.length = g[2]
	l.base_limit = limit
	var kmax: float = g[3]
	l.limit = limit if l.kind == STRAIGHT or kmax < 1e-4 else minf(limit, sqrt(A_LAT / kmax))


static func _kmax(pts: PackedVector2Array, cum: PackedFloat32Array) -> float:
	var kmax := 0.0
	var n := pts.size()
	var w := 3
	for k in range(w, n - w):
		var d1 := (pts[k] - pts[k - w]).normalized()
		var d2 := (pts[k + w] - pts[k]).normalized()
		var ds := cum[k + w] - cum[k - w]
		if ds > 0.0:
			kmax = maxf(kmax, absf(d1.angle_to(d2)) / (ds * 0.5))
	return kmax


## s at which a move's tile-local centreline crosses `along` from the centre on exit arm te.
static func _zebra_s(pts: PackedVector2Array, cum: PackedFloat32Array, te: int, along: float) -> float:
	var b := DIRS[te]
	for k in range(pts.size()):
		if pts[k].dot(b) >= along:
			return cum[k]
	return cum[cum.size() - 1]


# ------------------------------------------------------------------ junction rules

## Conflicts (same exit or crossing paths, cached per mask) and yield priorities for a junction.
func _junction_rules(t: TileInfo) -> void:
	var table := _conflicts_for(t.mask)
	var all: Array = []
	for e in range(4):
		all.append_array(t.moves[e])
	for mv: Lane in all:
		var ids := PackedInt32Array()
		var clear := PackedFloat32Array()
		for o: Lane in all:
			if o == mv:
				continue
			var c: float = table.get(_pair(mv.from_e, mv.to_e, o.from_e, o.to_e), -1.0)
			if c >= 0.0:
				ids.append(o.id)
				clear.append(c)
		mv.conflicts = ids
		mv.conflict_clear = clear
		var y := PackedInt32Array()
		var gap := 0.0
		if t.lights:
			if mv.turn == -1:
				y.append(OPP[mv.from_e])
				gap = 2.5
		elif t.stem >= 0:
			if mv.from_e == t.stem:
				for e in range(4):
					if e != t.stem and (t.mask & (1 << e)):
						y.append(e)
				gap = 3.0
			elif mv.turn == -1:
				y.append(OPP[mv.from_e])
				gap = 2.5
		mv.yield_to = y
		mv.gap_s = gap


func _pair(e1: int, x1: int, e2: int, x2: int) -> int:
	return ((e1 * 4 + x1) * 4 + e2) * 4 + x2


## Per mask: for every ordered pair of conflicting moves, the distance along the second move
## past which a vehicle's rear has cleared the first (its whole length when both share an exit);
## pairs that never come within CONFLICT_DIST are absent.
func _conflicts_for(m: int) -> Dictionary:
	if _conflict_cache.has(m):
		return _conflict_cache[m]
	var table := {}
	var arms: Array[int] = []
	for e in range(4):
		if m & (1 << e):
			arms.append(e)
	var geo := {}
	for e: int in arms:
		for xo: int in arms:
			if xo != e:
				var me := e
				var mx := xo
				geo[e * 4 + xo] = _geom(Vector4(48 + me * 4 + mx, 0, 0, 0), func() -> PackedVector2Array: return _move_pts(me, mx))
	for k1: int in geo.keys():
		for k2: int in geo.keys():
			if k1 >= k2:
				continue
			var e1 := k1 / 4
			var x1 := k1 % 4
			var e2 := k2 / 4
			var x2 := k2 % 4
			if e1 == e2:
				continue
			var g1: Array = geo[k1]
			var g2: Array = geo[k2]
			if x1 == x2:
				table[_pair(e1, x1, e2, x2)] = float(g2[2]) + 1.0
				table[_pair(e2, x2, e1, x1)] = float(g1[2]) + 1.0
				continue
			var end2 := _near_end(g1[0], g2[0], g2[1])
			if end2 < 0.0:
				continue
			table[_pair(e1, x1, e2, x2)] = end2
			table[_pair(e2, x2, e1, x1)] = _near_end(g2[0], g1[0], g1[1])
	_conflict_cache[m] = table
	return table


## Largest distance along b (cumulative cb) of a point of b within CONFLICT_DIST of a, or -1.
func _near_end(a: PackedVector2Array, b: PackedVector2Array, cb: PackedFloat32Array) -> float:
	var lim := CONFLICT_DIST * CONFLICT_DIST
	var best := -1.0
	for j in range(b.size()):
		for i in range(0, a.size(), 2):
			if a[i].distance_squared_to(b[j]) < lim:
				best = cb[j]
				break
	return best


# ------------------------------------------------------------------ routing

## Lane path along a sequence of road tiles: for each tile the lane from the edge it is entered by
## to the edge toward the next tile, with junction approaches before their moves. fe0 is the entry
## edge of the first tile (-1: any), te_last the exit edge of the last (-1: any). O(tiles).
## Returns [] when a step has no lane.
func lanes_along(seq: Array[int], fe0: int = -1, te_last: int = -1) -> Array:
	var out: Array = []
	var n := seq.size()
	for k in range(n):
		var i: int = seq[k]
		if not tiles.has(i):
			return []
		var fe := fe0 if k == 0 else edge_between(i, seq[k - 1])
		var te := te_last if k == n - 1 else edge_between(i, seq[k + 1])
		if (k > 0 and fe < 0) or (k < n - 1 and te < 0):
			return []
		var ls := lanes_through(i, fe, te)
		if ls.is_empty():
			return []
		out.append_array(ls)
	return out


## Edge of tile a that faces adjacent tile b, or -1.
func edge_between(a: int, b: int) -> int:
	var d := Vector2(D.tx(b) - D.tx(a), D.ty(b) - D.ty(a))
	for e in range(4):
		if DIRS[e] == d:
			return e
	return -1


## Lanes crossing tile i entering at fe and leaving at te (either may be -1 for "any").
func lanes_through(i: int, fe: int, te: int) -> Array:
	var t: TileInfo = tiles[i]
	if t.approach[0] != null or t.approach[1] != null or t.approach[2] != null or t.approach[3] != null:
		for e in range(4):
			if t.approach[e] == null or (fe >= 0 and e != fe):
				continue
			for mv: Lane in t.moves[e]:
				if te < 0 or mv.to_e == te:
					return [t.approach[e], mv]
		return []
	for l: Lane in t.lanes:
		if (fe < 0 or l.from_e == fe) and (te < 0 or l.to_e == te):
			return [l]
	return []


## A* over lanes from the end of `from` to the end of any lane in `goals` (lane id -> true),
## costing length / limit * (1 + 2 * traffic) and avoiding blocked tiles (through_blocked: crews
## and bus lines may cross them, at BLOCKED_COST times the cost, when there is no way round).
## At most max_nodes expansions. Returns the lanes after `from` up to and including the goal
## lane, or [].
func astar(from: Lane, goals: Dictionary, max_nodes: int = 3000, through_blocked: bool = false) -> Array:
	if from == null or goals.is_empty():
		return []
	var gpos := Vector2.ZERO
	for gid: int in goals.keys():
		var gl: Lane = lanes[gid] if gid < lanes.size() else null
		if gl != null:
			gpos = gl.pts[gl.pts.size() - 1]
			break
	var heap: HEAP = HEAP.new()
	heap.push(0.0, from.id)
	var g := {from.id: 0.0}
	var prev := {}
	var expanded := 0
	var vmax := WS.CAR_CITY
	while not heap.is_empty() and expanded < max_nodes:
		var cur_id: int = heap.pop()
		expanded += 1
		var cur: Lane = lanes[cur_id] if cur_id < lanes.size() else null
		if cur == null:
			continue
		if cur_id != from.id and goals.has(cur_id):
			var path: Array = []
			var c := cur_id
			while c != from.id:
				path.push_front(lanes[c])
				c = prev[c]
			return path
		for nl: Lane in next_lanes(cur):
			var penalty := 1.0
			if blocked.has(nl.tile) and not goals.has(nl.id):
				if not through_blocked:
					continue
				penalty = BLOCKED_COST
			var tr := 0.0
			if nl.tile < sim.traffic.size():
				tr = sim.traffic[nl.tile]
			var ng := float(g[cur_id]) + nl.length / maxf(nl.limit, 0.05) * (1.0 + 2.0 * tr) * penalty
			if nl.turn == 2:
				ng += 6.0
			if ng < float(g.get(nl.id, INF)):
				g[nl.id] = ng
				prev[nl.id] = cur_id
				heap.push(ng + nl.pts[nl.pts.size() - 1].distance_to(gpos) / vmax, nl.id)
	return []
