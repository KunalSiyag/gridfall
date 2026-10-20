extends RefCounted
## The places a crew can stand and walk on one construction site (feature "crews"). A grid of
## cells CELL apart covers the tile and the scaffold round it. At a cell a worker stands on the
## ground inside the hoarding or on one of the site's decks (ConstructionKit.deck: the slab as
## poured, the frame's floors, the scaffold's boards; on a deck narrower than a cell, on its middle
## line), where the collision boxes that box the deck whole (the slab under it, the frame or the
## scaffold round it) are not in the way. A node is a cell and a height where a worker fits: clear
## of every other box and cylinder near the tile (CollisionWorld), of the deck's posts and of the
## decks over it. Nodes link to their neighbours up to CLIMB higher or lower, and straight across
## up to HOP - 1 cells of something low enough to climb (a berm, the formwork), by points on top
## of it. path() is the way between two nodes.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
## HALF cells either side of the tile centre, CELL apart: out to 0.52, past the scaffold's boards
## round the widest footprint (0.9: out to 0.512). A worker stands on the ground only up to
## GROUND_HALF cells out (0.44), inside the hoarding at 0.47. Neighbouring cells' worker circles
## overlap, so no part of a site fits between them.
const CELL := 0.04
const HALF := 13
const GROUND_HALF := 11
const SIDE := HALF * 2 + 1
## A worker's footprint radius and height.
const RADIUS := 0.35 * WS.M
const HEIGHT := 1.8 * WS.M
## A worker steps or climbs this much up or down (1 m: onto a slab, over a berm or the
## formwork), across at most HOP - 1 cells.
const CLIMB := 1.0 * WS.M
const HOP := 3
const EPS := 0.0005
## Two nodes of one cell are at least this far apart in height.
const LEVEL_GAP := 0.002
## A box this much short of a deck's edges still boxes it whole.
const SLACK := 0.002
## The key of a link's climb points in _via: n * VIA + o.
const VIA := 1 << 16
## The eight steps from a cell, straight ones first.
const STEPS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(-1, 0),
	Vector2i(0, 1),
	Vector2i(0, -1),
	Vector2i(1, 1),
	Vector2i(1, -1),
	Vector2i(-1, 1),
	Vector2i(-1, -1),
]

## The tile centre at the ground datum.
var c: Vector3 = Vector3.ZERO
var boxes: Array[AABB] = []
## Cylinders: (x, z, radius, top).
var cyls: Array[Vector4] = []
## CityView.site_decks(): {"rect", "y", "t", "posts"}.
var decks: Array[Dictionary] = []
## Per deck: {box index: true} for the boxes that box it whole.
var shells: Array[Dictionary] = []
## Per cell (row by row): indices into boxes, cyls and decks near it, and its nodes.
var cell_boxes: Array[Array] = []
var cell_cyls: Array[Array] = []
var cell_decks: Array[Array] = []
var at: Array[Array] = []
## Per node: the feet, the cell, the deck (-1: the ground) and the nodes it links to.
var pos: Array[Vector3] = []
var cell := PackedInt32Array()
var deck := PackedInt32Array()
var links: Array[PackedInt32Array] = []
## n * VIA + o -> the points (Array[Vector3]) to climb over on the way from node n to node o, for
## a link across something.
var _via: Dictionary = {}
## Each box's footprint grown by a worker's radius; each deck's rect, top, thickness and posts
## (grown by a worker's radius).
var _foot: Array[Rect2] = []
var _rect: Array[Rect2] = []
var _top := PackedFloat64Array()
var _thick := PackedFloat64Array()
var _posts: Array[Array] = []
## Node -> the parents of every node reached from it (tree()).
var _trees: Dictionary = {}


## Lays the grid over tile i as drawn now.
func setup(ctx: FpContext, i: int) -> void:
	c = Vector3(D.tx(i), WS.GROUND_Y, D.ty(i))
	if ctx.collision != null:
		_gather(ctx.collision, i)
	if ctx.view != null:
		decks = ctx.view.site_decks(i)
	_prepare()
	_bucket()
	for k in range(SIDE * SIDE):
		_add_nodes(ctx.collision, k)
	for n in range(pos.size()):
		_link(n)


## The node nearest p within two cells and up to dy above or below it (a height nearer p's
## counts for more); -1 when none.
func near(p: Vector3, dy := INF) -> int:
	var gx := roundi((p.x - c.x) / CELL) + HALF
	var gz := roundi((p.z - c.z) / CELL) + HALF
	var best := -1
	var best_d := INF
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			var k := _cell_at(gx + dx, gz + dz)
			if k < 0:
				continue
			for n: int in at[k]:
				var h := absf(pos[n].y - p.y)
				var d := _flat(pos[n], p) + h * 4.0
				if h <= dy and d < best_d:
					best = n
					best_d = d
	return best


## True when p is where a node is: a worker fits there.
func stands(p: Vector3) -> bool:
	var n := near(p)
	return n >= 0 and pos[n].distance_to(p) < LEVEL_GAP


## The nodes ({node: true}) a worker at one of pts, at about its height, would bump into: closer
## than two worker radii across.
func taken_by(pts: Array[Vector3]) -> Dictionary:
	var out := {}
	for p: Vector3 in pts:
		var gx := roundi((p.x - c.x) / CELL) + HALF
		var gz := roundi((p.z - c.z) / CELL) + HALF
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var k := _cell_at(gx + dx, gz + dz)
				if k < 0:
					continue
				for n: int in at[k]:
					if _flat(pos[n], p) < RADIUS * 2.0 and absf(pos[n].y - p.y) < CLIMB:
						out[n] = true
	return out


## The parents of every node reached from node s (s is its own; -1 for one it does not reach),
## not through the nodes in skip ({node: true}).
func tree(s: int, skip: Dictionary = {}) -> PackedInt32Array:
	if skip.is_empty() and _trees.has(s):
		return _trees[s]
	var parent := PackedInt32Array()
	parent.resize(pos.size())
	parent.fill(-1)
	parent[s] = s
	var queue: Array[int] = [s]
	var head := 0
	while head < queue.size():
		var n := queue[head]
		head += 1
		for o: int in links[n]:
			if parent[o] < 0 and not skip.has(o):
				parent[o] = n
				queue.append(o)
	if skip.is_empty():
		_trees[s] = parent
	return parent


## The way from node a to node b, not through the nodes in skip: the points to walk through after
## a, ending at b; [] when b is a or a does not reach it.
func path(a: int, b: int, skip: Dictionary = {}) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if a < 0 or b < 0 or a == b:
		return out
	var parent := tree(a, skip)
	if parent[b] < 0:
		return out
	var chain: Array[int] = []
	var n := b
	while n != a:
		chain.append(n)
		n = parent[n]
	chain.reverse()
	var prev := a
	for m: int in chain:
		out.append_array(_via.get(prev * VIA + m, []))
		out.append(pos[m])
		prev = m
	return _straighten(out, pos[a])


# ------------------------------------------------------------------ building


func _gather(col: CollisionWorld, i: int) -> void:
	var r := (float(HALF) + 0.5) * CELL + RADIUS
	var area := Rect2(c.x - r, c.z - r, r * 2.0, r * 2.0)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if not D.in_bounds(D.tx(i) + dx, D.ty(i) + dz):
				continue
			var j := D.idx(D.tx(i) + dx, D.ty(i) + dz)
			for b: AABB in col.boxes(j):
				if area.intersects(_xz(b)):
					boxes.append(b)
			var cy := col.cylinders(j)
			for k in range(0, cy.size(), 4):
				if area.grow(cy[k + 2]).has_point(Vector2(cy[k], cy[k + 1])):
					cyls.append(Vector4(cy[k], cy[k + 1], cy[k + 2], cy[k + 3]))


## The boxes' footprints grown by a worker's radius, the decks' parts, and per deck the boxes that
## box it whole.
func _prepare() -> void:
	for b: AABB in boxes:
		_foot.append(_xz(b).grow(RADIUS))
	for d: Dictionary in decks:
		var r: Rect2 = d["rect"]
		_rect.append(r)
		_top.append(float(d["y"]))
		_thick.append(float(d["t"]))
		var grown: Array[Rect2] = []
		for p: Rect2 in d["posts"]:
			grown.append(p.grow(RADIUS))
		_posts.append(grown)
		var inner := r.grow(-SLACK)
		var whole := {}
		if inner.size.x > 0.0 and inner.size.y > 0.0:
			for bi in range(boxes.size()):
				if _xz(boxes[bi]).encloses(inner) and boxes[bi].end.y >= float(d["y"]) - EPS:
					whole[bi] = true
		shells.append(whole)


## Sorts the boxes, cylinders and decks into the cells whose nodes they may be in the way of or
## under: a node is up to half a cell off its cell's centre (on a narrow deck).
func _bucket() -> void:
	for k in range(SIDE * SIDE):
		cell_boxes.append([])
		cell_cyls.append([])
		cell_decks.append([])
		at.append([])
	for bi in range(boxes.size()):
		for k: int in _cells(_foot[bi].grow(CELL * 0.5)):
			cell_boxes[k].append(bi)
	for ci in range(cyls.size()):
		var cy := cyls[ci]
		var r := cy.z + RADIUS + CELL * 0.5
		for k: int in _cells(Rect2(cy.x - r, cy.y - r, r * 2.0, r * 2.0)):
			cell_cyls[k].append(ci)
	for d in range(decks.size()):
		for k: int in _cells(_rect[d].grow(CELL * 0.5)):
			cell_decks[k].append(d)


func _add_nodes(col: CollisionWorld, k: int) -> void:
	var xz := _cell_xz(k)
	if _inside(k):
		var g := col.ground_height(Vector3(xz.x, c.y, xz.y)) if col != null else c.y
		if not is_nan(g):
			_try(k, Vector3(xz.x, g, xz.y), -1)
	for d: int in cell_decks[k]:
		var q := Vector2(_along(xz.x, _rect[d].position.x, _rect[d].size.x), NAN)
		q.y = _along(xz.y, _rect[d].position.y, _rect[d].size.y)
		if not is_nan(q.x) and not is_nan(q.y):
			_try(k, Vector3(q.x, _top[d], q.y), d)


## True for the cells GROUND_HALF or fewer out from the middle, inside the hoarding.
func _inside(k: int) -> bool:
	var gz := floori(float(k) / SIDE)
	return absi(k - gz * SIDE - HALF) <= GROUND_HALF and absi(gz - HALF) <= GROUND_HALF


## Where a deck has its node in a cell, on one axis: v, the cell's centre, when it is on the
## deck's span (size long from lo); across a span shorter than a cell, the span's middle when that
## is in v's cell; NAN otherwise.
static func _along(v: float, lo: float, size: float) -> float:
	if size >= CELL:
		return v if v >= lo and v <= lo + size else NAN
	var mid := lo + size * 0.5
	return mid if mid >= v - CELL * 0.5 and mid < v + CELL * 0.5 else NAN


func _try(k: int, p: Vector3, d: int) -> void:
	for n: int in at[k]:
		if absf(pos[n].y - p.y) < LEVEL_GAP:
			return
	if not _clear(k, Vector2(p.x, p.z), p.y, d, -1):
		return
	at[k].append(pos.size())
	pos.append(p)
	cell.append(k)
	deck.append(d)
	links.append(PackedInt32Array())


## True when a worker fits with its feet at xz and height y in cell k. The boxes that box deck a
## or b whole (-1: none) are left out and the posts of both are kept clear.
func _clear(k: int, xz: Vector2, y: float, a: int, b: int) -> bool:
	for bi: int in cell_boxes[k]:
		var bx := boxes[bi]
		var level := bx.end.y > y + EPS and bx.position.y < y + HEIGHT
		if level and _foot[bi].has_point(xz) and not _shell(bi, a, b):
			return false
	for ci: int in cell_cyls[k]:
		var cy := cyls[ci]
		if cy.w > y + EPS and Vector2(cy.x, cy.y).distance_to(xz) < cy.z + RADIUS:
			return false
	if _on_post(a, xz) or _on_post(b, xz):
		return false
	for od: int in cell_decks[k]:
		var over := _top[od] > y + EPS and _top[od] - _thick[od] < y + HEIGHT
		if over and od != a and od != b and _rect[od].has_point(xz):
			return false
	return true


func _shell(bi: int, a: int, b: int) -> bool:
	return (a >= 0 and shells[a].has(bi)) or (b >= 0 and shells[b].has(bi))


func _on_post(d: int, xz: Vector2) -> bool:
	if d < 0:
		return false
	for r: Rect2 in _posts[d]:
		if r.has_point(xz):
			return true
	return false


## Links node n to the nodes of the cells round it it can step to: up to CLIMB up or down, and
## on a diagonal only past two straight neighbours it could step to as well (no cutting a
## corner). Straight on, with nothing to step to, it climbs over what is in between (_hop).
func _link(n: int) -> void:
	var gx := cell[n] % SIDE
	var gz := floori(float(cell[n]) / SIDE)
	var y := pos[n].y
	var out := PackedInt32Array()
	for s: Vector2i in STEPS:
		var m := _cell_at(gx + s.x, gz + s.y)
		var diagonal := s.x != 0 and s.y != 0
		if m < 0 or diagonal and not _corner(gx, gz, s, y):
			continue
		var linked := false
		for o: int in at[m]:
			if absf(pos[o].y - y) <= CLIMB:
				out.append(o)
				linked = true
		if not linked and not diagonal:
			var o := _hop(n, gx, gz, s)
			if o >= 0:
				out.append(o)
	links[n] = out


## True when both straight neighbours on the way along diagonal s have a node a step from y.
func _corner(gx: int, gz: int, s: Vector2i, y: float) -> bool:
	return _steps(_cell_at(gx + s.x, gz), y) and _steps(_cell_at(gx, gz + s.y), y)


## True when cell k has a node a step from height y.
func _steps(k: int, y: float) -> bool:
	if k < 0:
		return false
	for o: int in at[k]:
		if absf(pos[o].y - y) <= CLIMB:
			return true
	return false


## The first node straight along s from n, beyond 1 to HOP - 1 cells it cannot step to, that n
## climbs to over the top of what is in them when that is low enough (-1: none).
func _hop(n: int, gx: int, gz: int, s: Vector2i) -> int:
	var between: Array[int] = []
	for step in range(1, HOP + 1):
		var m := _cell_at(gx + s.x * step, gz + s.y * step)
		if m < 0:
			return -1
		if step > 1:
			var o := _hop_to(n, m, between)
			if o >= 0:
				return o
		between.append(m)
	return -1


func _hop_to(n: int, m: int, between: Array[int]) -> int:
	for o: int in at[m]:
		var h := _over(n, o, between)
		if is_nan(h):
			continue
		var a := _cell_xz(between[0])
		var b := _cell_xz(between[-1])
		var pts: Array[Vector3] = [Vector3(a.x, h, a.y)]
		if between.size() > 1:
			pts.append(Vector3(b.x, h, b.y))
		_via[n * VIA + o] = pts
		return o
	return -1


## The height a worker climbs to on the way from node n to node o across the cells between: the
## top of the highest box in them it can climb; NAN when something there is in the way.
func _over(n: int, o: int, between: Array[int]) -> float:
	if absf(pos[n].y - pos[o].y) > CLIMB:
		return NAN
	var a := deck[n]
	var b := deck[o]
	var lo := maxf(pos[n].y, pos[o].y)
	var h := lo
	for m: int in between:
		var xz := _cell_xz(m)
		for bi: int in cell_boxes[m]:
			var top := boxes[bi].end.y
			if top > h and top <= lo + CLIMB and _foot[bi].has_point(xz) and not _shell(bi, a, b):
				h = top
	for m: int in between:
		if not _clear(m, _cell_xz(m), h, a, b):
			return NAN
	return h


# ------------------------------------------------------------------ cells


func _cell_at(gx: int, gz: int) -> int:
	if gx < 0 or gz < 0 or gx >= SIDE or gz >= SIDE:
		return -1
	return gz * SIDE + gx


func _cell_xz(k: int) -> Vector2:
	var gz := floori(float(k) / SIDE)
	return Vector2(c.x + float(k - gz * SIDE - HALF) * CELL, c.z + float(gz - HALF) * CELL)


## The cells whose centres are in r.
func _cells(r: Rect2) -> Array[int]:
	var out: Array[int] = []
	var x0 := c.x - float(HALF) * CELL
	var z0 := c.z - float(HALF) * CELL
	var ix0 := maxi(ceili((r.position.x - x0) / CELL), 0)
	var ix1 := mini(floori((r.end.x - x0) / CELL), SIDE - 1)
	var iz0 := maxi(ceili((r.position.y - z0) / CELL), 0)
	var iz1 := mini(floori((r.end.y - z0) / CELL), SIDE - 1)
	for iz in range(iz0, iz1 + 1):
		for ix in range(ix0, ix1 + 1):
			out.append(iz * SIDE + ix)
	return out


## pts without the points a straight walk at one height passes through anyway.
static func _straighten(pts: Array[Vector3], from: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var prev := from
	for k in range(pts.size()):
		var p := pts[k]
		if k + 1 < pts.size() and _in_line(prev, p, pts[k + 1]):
			continue
		out.append(p)
		prev = p
	return out


static func _in_line(a: Vector3, b: Vector3, c2: Vector3) -> bool:
	if absf(a.y - b.y) > EPS or absf(b.y - c2.y) > EPS:
		return false
	var u := Vector2(b.x - a.x, b.z - a.z)
	var v := Vector2(c2.x - b.x, c2.z - b.z)
	return absf(u.cross(v)) < 1e-7 and u.dot(v) > 0.0


static func _xz(b: AABB) -> Rect2:
	return Rect2(b.position.x, b.position.z, b.size.x, b.size.z)


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
