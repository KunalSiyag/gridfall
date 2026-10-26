class_name CollisionWorld
extends Node
## Analytic on-foot collision (slice A; no physics engine, D2): walkable ground height per point,
## blocking boxes and prop cylinders per tile, water. Buildings block with bodies made from the
## model's own geometry (body_shapes.gd, baked into body_table.gd), not the whole-lot AABB, so
## yards, lots and parks are walkable; construction-site parts, street props (lamp poles, bus
## shelters, benches, hydrants, trunks) and test boxes block too. Picking uses the full
## view.building_aabb(i). Every query looks at the 3x3 tiles around the point. Deterministic and
## headless-safe.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const BS := preload("res://scripts/fp/player/body_shapes.gd")
const TABLE := preload("res://scripts/fp/player/body_table.gd")
## Interim soft step (A deliverable 1; remove once G1 raises WS.GROUND_Y): next to a tile whose
## surface is at GROUND_Y, a higher tile at most SOFT_STEP above it ramps down over its outer
## SOFT_BAND, so the 42 cm grass ledge does not trap a player who drops onto grass.
const SOFT_STEP := 0.03
const SOFT_BAND := 0.05
## Lit straights bake their lamps into the road model (roads.py:138-139, 166-169): each pole stands
## LAMP_OUT outside its Bulb_* (the arm reaches toward the road), plus two small posts.
const LAMP_POLE_R := 0.008
const LAMP_OUT := 0.08
const LAMP_POST_R := 0.0035
const LAMP_POSTS := [Vector2(-0.4, -0.2), Vector2(0.4, 0.2)]
const BUS_STOP_PATHS := [
	"res://models/props/bus_stop.glb", "res://models/real/props/bus_stop.glb", AP.BUS_SHELTER
]
## CityView's procedural shelter (no model file) stands 0.43 from the road centre.
const PROC_STOP_OFFSET := 0.43
const PROC_STOP_SIZE := Vector3(0.34, 0.21, 0.20)
const PROP_DIRS := ["res://models/real/props/", "res://models/props/"]
## Street props by file name: trunks and lamp poles are thin cylinders, these are boxes, foliage
## does not block, anything else is a cylinder of its footprint within PROP_R_MIN..PROP_R_MAX.
const BOX_PROPS := [
	"bench",
	"picnic",
	"planter_box",
	"planter_long",
	"barrier",
	"utility_box",
	"aircon",
	"fountain",
	"hedge",
	"mailbox"
]
const SOFT_PROPS := ["tree_bush", "tree_fern"]
const LAMP_R := 0.15 * WS.M
const TRUNK_R := 0.25 * WS.M
## Camera arms treat cylinders this thick or more (trunks, not lamp poles) as solid.
const CAM_CYL_MIN := 0.2 * WS.M
const PROP_R_MIN := 0.1 * WS.M
const PROP_R_MAX := 0.5 * WS.M
## Walking head-on into a pole keeps this fraction of the speed, sliding round it.
const ROUND_SLIDE := 0.45
## Cylinders from a G1 `colliders` meta carry no height: they block up to this.
const META_CYL_TOP := 3.0 * WS.M
## A person on foot is a soft circle this wide (half a shoulder): the hero cannot walk through
## them, but they are not a wall either (soft_people_move; walkers.gd gives way in turn).
const PERSON_R := 0.22 * WS.M
## How much of a person overlap the hero eases out per collision sub-step: gentle, so a sidewalk
## still flows; the into-person speed is damped player-side, so the overlap never persists.
const SOFT_RATE := 0.35
## A person's circle only presses the hero when their feet are within this height (a walker under
## a ledge the hero stands on is not in the way).
const SOFT_Y := 1.2 * WS.M
## resolve_out() moves at most this far per pass and makes at most this many passes, deepest face
## first: a teleport left inside a building steps straight out, a spawn deep inside never flings
## through walls.
const RESOLVE_STEP := 2.0 * WS.M
const RESOLVE_PASSES := 6
## surface_at() on the carriageway of each road grade (D.ROAD_GRADES order).
const GRADE_SURFACES := ["asphalt", "gravel", "dirt", "trail"]

var ctx: FpContext
## Tile index -> {"boxes": Array[AABB], "bodies": Array[AABB], "cyls": PackedFloat32Array of
## (x, z, r, top) in world space, "bound": AABB of everything (xz, for a quick reject)}.
var _tiles: Dictionary = {}
## Tile index -> merged bound of boxes(i).
var _bounds: Dictionary = {}
## Model path -> BS.analyse() result for a model with no (or a stale) baked entry.
var _runtime_shapes: Dictionary = {}
## Prop model path -> local AABB of its meshes.
var _prop_bounds: Dictionary = {}
var _test_boxes: Array[AABB] = []
var _test_cyls := PackedFloat32Array()
## Boxes that move with the traffic (stopped cars from E's blockers_near), refreshed by the
## player a few times a second; they block like walls while listed.
var dynamic_boxes: Array[AABB] = []
## People on foot near the hero, as soft circles the player refreshes every frame from traffic's
## walkers_near: (x, y, z, r) quadruples in world units. They are not walls (soft_people_move),
## but the hero cannot pass through them either.
var people_circles := PackedFloat32Array()
var _esc_from: Vector3 = Vector3(NAN, NAN, NAN)
var _esc_point: Vector3 = Vector3(NAN, NAN, NAN)
var _esc_r: float = 0.0
var _warned: Dictionary = {}


## Stores the context; colliders are computed lazily from ctx.view.
func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx


## Drops every cached collider (after view.setup).
func rebuild_all() -> void:
	_tiles.clear()
	_bounds.clear()
	_esc_from = Vector3(NAN, NAN, NAN)


## Invalidates tile i's colliders: its holder changed (a street prop knocked down or put back).
func invalidate(i: int) -> void:
	_tiles.erase(i)
	_bounds.erase(i)
	_esc_from = Vector3(NAN, NAN, NAN)


## Invalidates tile i's colliders.
func on_tile_built(i: int, _holder: Node3D) -> void:
	invalidate(i)


## Invalidates tile i's colliders.
func on_tile_cleared(i: int) -> void:
	invalidate(i)


## Test hook: a world box that blocks like any other (a ledge, a ceiling), listed in boxes() of
## every tile it overlaps.
func add_test_box(b: AABB) -> void:
	_test_boxes.append(b)
	rebuild_all()


## Test hook: a world cylinder (a trunk) at x, z of radius r up to top, listed in cylinders() of
## every tile it overlaps.
func add_test_cylinder(x: float, z: float, r: float, top: float) -> void:
	_test_cyls.append_array([x, z, r, top])
	rebuild_all()


## Removes every add_test_box() box and add_test_cylinder() cylinder.
func clear_test_boxes() -> void:
	_test_boxes.clear()
	_test_cyls.clear()
	rebuild_all()


## Tile index at a world point (round x/z, D.idx) or -1 outside the world.
func tile_at(p: Vector3) -> int:
	var x := roundi(p.x)
	var y := roundi(p.z)
	return D.idx(x, y) if D.in_bounds(x, y) else -1


## World y of the walkable surface at p.x/p.z; NAN when not walkable (water, bridge parapet).
func ground_height(p: Vector3) -> float:
	var i := tile_at(p)
	if i < 0:
		return WS.GROUND_Y
	var sim := ctx.sim
	var k := sim.kind[i]
	if k == D.ROAD:
		return RoadTopology.surface_height(sim, i, Vector2(p.x - D.tx(i), p.z - D.ty(i)))
	if sim.terrain[i] == D.WATER:
		return NAN
	if D.is_zone(k):
		if sim.level[i] <= 0:
			return WS.GROUND_Y
		return WS.LOT_TOP if k == D.ZONE_R else WS.PAD_TOP
	if k == D.RUBBLE:
		return WS.PAD_TOP
	if k == D.EMPTY or k == D.FOREST or k == D.SITE:
		return WS.GROUND_Y
	return WS.LOT_TOP


## The height the feet stand at: ground_height() with the interim soft step (SOFT_STEP ramps
## over SOFT_BAND toward a GROUND_Y neighbour). NAN where ground_height is NAN.
func walk_height(p: Vector3) -> float:
	var g := ground_height(p)
	if is_nan(g) or g <= WS.GROUND_Y + 1e-6 or g > WS.GROUND_Y + SOFT_STEP + 1e-6:
		return g
	var cx := float(roundi(p.x))
	var cz := float(roundi(p.z))
	var lx := p.x - cx
	var lz := p.z - cz
	var out := g
	for axis in range(2):
		var l := lx if axis == 0 else lz
		var d := 0.5 - absf(l)
		if d >= SOFT_BAND:
			continue
		var q := p
		if axis == 0:
			q.x = cx + signf(l) * (0.5 + 1e-4)
		else:
			q.z = cz + signf(l) * (0.5 + 1e-4)
		var ng := ground_height(q)
		if not is_nan(ng) and absf(ng - WS.GROUND_Y) < 1e-6:
			out = minf(out, lerpf(WS.GROUND_Y, g, clampf(d / SOFT_BAND, 0.0, 1.0)))
	return out


## What the feet of a walker at feet_y stand on at p: walk_height(), or the top of a box under
## the circle that is at most max_rise above the feet (a low wall it stepped or jumped onto).
## NAN over water.
func support_height(p: Vector3, radius: float, feet_y: float, max_rise: float) -> float:
	var g := walk_height(p)
	if is_nan(g):
		return g
	var limit := feet_y + max_rise + 1e-6
	for e: Dictionary in _bound_entries(p, radius):
		for b: AABB in e["boxes"]:
			if b.end.y <= g or b.end.y > limit:
				continue
			if (
				p.x > b.position.x - radius
				and p.x < b.end.x + radius
				and p.z > b.position.z - radius
				and p.z < b.end.z + radius
			):
				g = b.end.y
	return g


## The tile entries of the 3x3 tiles around p whose bound overlaps a circle of `radius` at p
## (a quick reject before scanning their boxes and cylinders).
func _bound_entries(p: Vector3, radius: float) -> Array:
	var out: Array = []
	var cx := roundi(p.x)
	var cz := roundi(p.z)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if not D.in_bounds(cx + dx, cz + dz):
				continue
			var e := _entry(D.idx(cx + dx, cz + dz))
			var bd: AABB = e["bound"]
			if (
				bd.size.x <= 0.0
				or p.x <= bd.position.x - radius
				or p.x >= bd.end.x + radius
				or p.z <= bd.position.z - radius
				or p.z >= bd.end.z + radius
			):
				continue
			out.append(e)
	return out


## Surface name for footsteps and audio: "asphalt"|"sidewalk"|"lot"|"grass"|"dirt"|"water"|"bridge",
## or on the carriageway of an unpaved road "gravel"|"dirt"|"trail" (its verges are "grass").
func surface_at(p: Vector3) -> String:
	var i := tile_at(p)
	if i < 0:
		return "grass"
	var sim := ctx.sim
	var k := sim.kind[i]
	if k == D.ROAD:
		if RoadTopology.is_bridge(sim, i):
			return "bridge"
		var m := RoadTopology.mask(sim, D.tx(i), D.ty(i))
		var on := RoadTopology.is_carriageway(m, Vector2(p.x - D.tx(i), p.z - D.ty(i)))
		var g := RoadTopology.grade(sim, i)
		if g != D.GRADE_PAVED:
			return str(GRADE_SURFACES[g]) if on else "grass"
		return "asphalt" if on else "sidewalk"
	if sim.terrain[i] == D.WATER:
		return "water"
	if k == D.EMPTY or k == D.FOREST or k == D.PARK or (D.is_zone(k) and sim.level[i] <= 0):
		return "grass"
	if k == D.SITE or k == D.RUBBLE:
		return "dirt"
	return "lot"


## True if a circle of `radius` at p (feet) is blocked: unwalkable ground under p, or a box or a
## prop cylinder of the 3x3 tiles around p whose top is above p.y. Boxes are grown by radius in
## xz (a square, so it agrees with tests that grow AABBs).
func is_blocked(p: Vector3, radius: float) -> bool:
	if is_nan(ground_height(p)):
		return true
	return _hits(p, radius, INF)


## is_blocked() for a body `height` tall: boxes and cylinders entirely above p.y + height (an
## awning, a ceiling) let it pass.
func body_blocked(p: Vector3, radius: float, height: float) -> bool:
	if is_nan(ground_height(p)):
		return true
	return _hits(p, radius, height)


## Moves from `from` by `motion` (y ignored), sliding along blockers. S0 rules: try the full move,
## else x only, else z only, else stay; a player who already overlaps a box may take any of them
## that enters nothing new and goes no deeper. Returns the new feet position (y unchanged).
func move_and_slide(from: Vector3, motion: Vector3, radius: float) -> Vector3:
	return move_body(from, motion, radius, INF, INF)


## The walker's move: like move_and_slide() for a body `height` tall that can rise at most
## max_rise onto higher walkable ground (STEP_HEIGHT on foot, 0 in the air). A blocked move first
## slides along the contact (a pole's tangent, a wall's face), then along x or z alone. Returns
## the new feet position with y unchanged (the caller follows walk_height()).
func move_body(
	from: Vector3, motion: Vector3, radius: float, height: float, max_rise: float
) -> Vector3:
	var full := Vector3(from.x + motion.x, from.y, from.z + motion.z)
	if _can_stand(from, full, radius, height, max_rise):
		return full
	var m := Vector2(motion.x, motion.z)
	var contact := _push_normal(full, radius, height)
	var n: Vector2 = contact[0]
	var dn := m.dot(n)
	if n != Vector2.ZERO and dn < 0.0:
		var t := m - n * dn
		# Nearly head-on into a pole: keep some speed around it instead of stopping dead (toward
		# the side the walker is already off-centre, else to its right).
		if bool(contact[1]) and t.length() < ROUND_SLIDE * m.length():
			var side := (
				t.normalized() if t.length_squared() > 1e-16 else Vector2(-m.y, m.x).normalized()
			)
			t = side * ROUND_SLIDE * m.length()
		var slid := Vector3(from.x + t.x, from.y, from.z + t.y)
		if t.length_squared() > 1e-14 and _can_stand(from, slid, radius, height, max_rise):
			return slid
	var xo := Vector3(from.x + motion.x, from.y, from.z)
	var zo := Vector3(from.x, from.y, from.z + motion.z)
	var first := xo if absf(motion.x) >= absf(motion.z) else zo
	var second := zo if absf(motion.x) >= absf(motion.z) else xo
	for c: Vector3 in [first, second]:
		if c != from and _can_stand(from, c, radius, height, max_rise):
			return c
	# Walk-out: from already overlaps something (a building or a site appeared underfoot). A move
	# is allowed when it goes no deeper into what it overlaps and enters nothing new (S0), or when
	# it heads for the nearest free point and enters nothing outside the obstacle it is in (the
	# boxes and posts touching each other), so a building made of several boxes lets go.
	var d0 := _overlaps(from, radius, height)
	if d0.is_empty():
		return from
	var cl := _cluster(from, radius, height, d0)
	var keys: Dictionary = cl["keys"]
	var esc := _escape_point(from, radius)
	for c: Vector3 in [full, first, second]:
		if c == from:
			continue
		var g := walk_height(c)
		if is_nan(g) or g - from.y > max_rise + 1e-6:
			continue
		var d1 := _overlaps(Vector3(c.x, maxf(from.y, g), c.z), radius, height)
		var shallower := true
		var known := true
		for key: Vector2i in d1.keys():
			if not d0.has(key) or float(d1[key]) > float(d0[key]) + 1e-9:
				shallower = false
			if not keys.has(key):
				known = false
		var outward := (
			not is_nan(esc.x)
			and (
				Vector2(c.x - from.x, c.z - from.z).dot(Vector2(esc.x - from.x, esc.z - from.z))
				> 0.0
			)
		)
		if shallower or (known and outward):
			return c
	return from


## The hero's soft push out of the people circles at p, one nudge per collision sub-step
## (SOFT_RATE of each overlap): the point eased clear of everyone standing near, never through a
## hard blocker and never onto ground it could not stand on. Returns p unchanged when nobody
## overlaps. The walkers give way as well (walkers.gd), so a sidewalk keeps flowing.
func soft_people_move(p: Vector3, radius: float, height: float) -> Vector3:
	var out := p
	for k in range(0, people_circles.size(), 4):
		if absf(p.y - people_circles[k + 1]) > SOFT_Y:
			continue
		var off := Vector2(p.x - people_circles[k], p.z - people_circles[k + 2])
		var dist := off.length()
		var want := people_circles[k + 3] + radius
		if dist >= want:
			continue
		var n := off / dist if dist > 1e-9 else Vector2(1.0, 0.0)
		var q := Vector3(
			out.x + n.x * ((want - dist) * SOFT_RATE),
			p.y,
			out.z + n.y * ((want - dist) * SOFT_RATE)
		)
		if _can_stand(p, q, radius, height, WS.STEP_HEIGHT):
			out = q
	return out


## Pushes a body (radius, height) that sits inside blockers out to the nearest free side: a
## teleport or a load may leave it half inside a building or a car box, and the walk-out rule of
## move_body only helps once it moves. Deepest face first, at most RESOLVE_STEP a pass and
## RESOLVE_PASSES passes, and it stops the moment a pass makes things no shallower, so a body
## deep inside works its way out over a few steps instead of being flung through walls. Returns
## the pushed point (y unchanged); p itself when nothing overlaps or there was no way out.
func resolve_out(p: Vector3, radius: float, height: float) -> Vector3:
	var out := p
	for _pass in RESOLVE_PASSES:
		var contact := _push_normal(out, radius, height)
		var n: Vector2 = contact[0]
		if n == Vector2.ZERO:
			return out
		var overlaps := _overlaps(out, radius, height)
		var depth := 0.0
		for v: float in overlaps.values():
			depth = maxf(depth, v)
		if depth <= 0.0:
			return out
		var q := Vector3(
			out.x + n.x * minf(depth + 1e-4, RESOLVE_STEP),
			out.y,
			out.z + n.y * minf(depth + 1e-4, RESOLVE_STEP)
		)
		if is_nan(walk_height(q)):
			return out
		var after := _overlaps(q, radius, height)
		var depth1 := 0.0
		for v: float in after.values():
			depth1 = maxf(depth1, v)
		if depth1 >= depth:
			return out
		out = q
	return out


## The closest point to p (xz, y on the ground) where a circle of `radius` is not blocked, searched
## on rings 1 m apart out to max_dist; Vector3(NAN, NAN, NAN) when there is none.
func nearest_free(p: Vector3, radius: float, max_dist: float) -> Vector3:
	if not is_blocked(p, radius):
		return p
	var step := 1.0 * WS.M
	var rings := ceili(max_dist / step)
	for k in range(1, rings + 1):
		var r := step * float(k)
		var n := maxi(8, ceili(TAU * r / step))
		for j in range(n):
			var a := TAU * float(j) / float(n)
			var q := Vector3(p.x + cos(a) * r, p.y, p.z + sin(a) * r)
			var g := ground_height(q)
			if is_nan(g):
				continue
			q.y = g
			if not is_blocked(q, radius):
				return q
	return Vector3(NAN, NAN, NAN)


## Ray against each tile's pickable bounds (tile DDA, <= max_dist) and the ground: a building's
## full view.building_aabb(i) (kind "building", so a set-back house is still picked from the
## sidewalk), a site's parts (kind "building", the site tile), street props (kind "prop", when
## include_props) and the ground (kind "ground").
## {"hit": bool, "pos": Vector3, "normal": Vector3, "tile": int, "kind": String, "dist": float}
func raycast(
	origin: Vector3, dir: Vector3, max_dist: float, include_props: bool = true
) -> Dictionary:
	var miss := {
		"hit": false,
		"pos": Vector3.ZERO,
		"normal": Vector3.ZERO,
		"tile": -1,
		"kind": "",
		"dist": max_dist
	}
	if dir.length_squared() < 1e-12 or max_dist <= 0.0:
		return miss
	var d := dir.normalized()
	var ox := origin.x + 0.5
	var oz := origin.z + 0.5
	var gx := floori(ox)
	var gz := floori(oz)
	var step_x := 1 if d.x > 0.0 else -1
	var step_z := 1 if d.z > 0.0 else -1
	var t_max_x := INF
	var t_max_z := INF
	var t_dx := INF
	var t_dz := INF
	if absf(d.x) > 1e-9:
		t_dx = 1.0 / absf(d.x)
		t_max_x = ((gx + 1 - ox) if d.x > 0.0 else (ox - gx)) * t_dx
	if absf(d.z) > 1e-9:
		t_dz = 1.0 / absf(d.z)
		t_max_z = ((gz + 1 - oz) if d.z > 0.0 else (oz - gz)) * t_dz
	var best := miss
	var best_t := INF
	var t := 0.0
	var guard := 0
	while t <= max_dist and guard < 4096:
		guard += 1
		var seg_end := minf(minf(t_max_x, t_max_z), max_dist)
		# Neighbours too: site parts and props reach past their tile.
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				if not D.in_bounds(gx + dx, gz + dz):
					continue
				var j := D.idx(gx + dx, gz + dz)
				var e := _entry(j)
				var pick: AABB = e["pick"]
				var cands: Array[AABB] = []
				if pick.size.x > 0.0:
					cands.append(pick)
				cands.append_array(e["sites"])
				for b: AABB in cands:
					var hit := _ray_box(origin, d, b)
					if (
						not hit.is_empty()
						and float(hit["t"]) < best_t
						and float(hit["t"]) <= max_dist
					):
						best_t = float(hit["t"])
						best = {
							"hit": true,
							"pos": origin + d * best_t,
							"normal": hit["normal"],
							"tile": j,
							"kind": "building",
							"dist": best_t
						}
				if include_props:
					for b: AABB in e["props"]:
						var hit := _ray_box(origin, d, b)
						if (
							not hit.is_empty()
							and float(hit["t"]) < best_t
							and float(hit["t"]) <= max_dist
						):
							best_t = float(hit["t"])
							best = {
								"hit": true,
								"pos": origin + d * best_t,
								"normal": hit["normal"],
								"tile": j,
								"kind": "prop",
								"dist": best_t
							}
					var cy: PackedFloat32Array = e["cyls"]
					for k in range(0, cy.size(), 4):
						var tc := _ray_cyl(
							origin, d, Vector2(cy[k], cy[k + 1]), cy[k + 2], cy[k + 3]
						)
						if tc >= 0.0 and tc < best_t and tc <= max_dist:
							best_t = tc
							var hp := origin + d * tc
							var nn := Vector3(hp.x - cy[k], 0.0, hp.z - cy[k + 1]).normalized()
							best = {
								"hit": true,
								"pos": hp,
								"normal": nn,
								"tile": j,
								"kind": "prop",
								"dist": tc
							}
		# Ground: the walkable height at the segment middle (water and parapets use the water surface).
		var i := D.idx(gx, gz) if D.in_bounds(gx, gz) else -1
		var mid := origin + d * ((t + seg_end) * 0.5)
		var g := ground_height(mid)
		if is_nan(g):
			g = WS.WATER_Y
		var ya := origin.y + d.y * t
		var yb := origin.y + d.y * seg_end
		if ya >= g and yb <= g and d.y < 0.0:
			var tg := (g - origin.y) / d.y
			if tg < best_t:
				best_t = tg
				best = {
					"hit": true,
					"pos": origin + d * tg,
					"normal": Vector3.UP,
					"tile": i,
					"kind": "ground",
					"dist": tg
				}
		if best_t <= seg_end or seg_end >= max_dist:
			break
		t = seg_end
		if t_max_x < t_max_z:
			gx += step_x
			t_max_x += t_dx
		else:
			gz += step_z
			t_max_z += t_dz
	return best


## True when the segment a -> b clears every movement box (bodies, walls, site parts, prop boxes)
## of the tiles it crosses; thin cylinders (poles, trunks) never hide anyone.
func line_of_sight(a: Vector3, b: Vector3) -> bool:
	var d := b - a
	var len := d.length()
	if len < 1e-9:
		return true
	var dir := d / len
	var n := maxi(1, ceili(len / 0.5))
	var seen := {}
	for s in range(n + 1):
		var p := a.lerp(b, float(s) / float(n))
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var x := roundi(p.x) + dx
				var y := roundi(p.z) + dz
				if not D.in_bounds(x, y):
					continue
				var j := D.idx(x, y)
				if seen.has(j):
					continue
				seen[j] = true
				for bx: AABB in boxes(j):
					var hit: Variant = bx.intersects_segment(a, b)
					if hit != null and not bx.has_point(a) and not bx.has_point(b):
						return false
	return true


## Free distance along unit dir from origin (<= max_dist) for a sphere of `radius`: a ray against
## the camera boxes near origin (camera_boxes_near) grown by radius (a Minkowski sum), skipping
## boxes that already contain origin. The camera arms (A 6.6, the drive and door cameras).
func sweep_sphere(origin: Vector3, dir: Vector3, max_dist: float, radius: float) -> float:
	return sweep_boxes(origin, dir, max_dist, radius, camera_boxes_near(origin, max_dist + radius))


## boxes_near() plus every cylinder of CAM_CYL_MIN or more (tree trunks) as its square column: a
## camera must not end up inside a trunk, while lamp poles are thin enough to flash past.
## Parkour keeps boxes_near(), so trees are never vaulted.
func camera_boxes_near(p: Vector3, reach: float) -> Array[AABB]:
	return boxes_near(p, reach, CAM_CYL_MIN)


## Movement boxes of the tiles around p within `reach` of it (the camera rig gathers them once
## per frame and sweeps the list several times), with the cylinders of radius cyl_min or more as
## square columns (none by default).
func boxes_near(p: Vector3, reach: float, cyl_min: float = INF) -> Array[AABB]:
	var out: Array[AABB] = []
	var n := maxi(1, ceili(reach))
	var cx := roundi(p.x)
	var cz := roundi(p.z)
	var reach2 := reach * reach
	for dz in range(-n, n + 1):
		for dx in range(-n, n + 1):
			if not D.in_bounds(cx + dx, cz + dz):
				continue
			var i := D.idx(cx + dx, cz + dz)
			var list := boxes(i)
			if cyl_min < INF:
				list = list.duplicate()
				_cyl_columns(cylinders(i), cyl_min, list)
			for b: AABB in list:
				var q := Vector3(
					clampf(p.x, b.position.x, b.end.x),
					clampf(p.y, b.position.y, b.end.y),
					clampf(p.z, b.position.z, b.end.z)
				)
				if q.distance_squared_to(p) <= reach2:
					out.append(b)
	return out


## Appends the cylinders (x, z, r, top) of radius r_min or more to out as square columns.
static func _cyl_columns(cy: PackedFloat32Array, r_min: float, out: Array[AABB]) -> void:
	for k in range(0, cy.size(), 4):
		var r := cy[k + 2]
		if r >= r_min:
			out.append(
				AABB(
					Vector3(cy[k] - r, WS.GROUND_Y, cy[k + 1] - r),
					Vector3(r * 2.0, maxf(cy[k + 3] - WS.GROUND_Y, 1e-4), r * 2.0)
				)
			)


## sweep_sphere() over a given box list.
static func sweep_boxes(
	origin: Vector3, dir: Vector3, max_dist: float, radius: float, list: Array[AABB]
) -> float:
	var best := max_dist
	for b: AABB in list:
		var g := b.grow(radius)
		if g.has_point(origin):
			continue
		var t := ray_box_t(origin, dir, g)
		if t >= 0.0 and t < best:
			best = t
	return best


## Entry distance of a ray (unit dir) into box b, or -1 on a miss (or when origin is inside).
static func ray_box_t(origin: Vector3, dir: Vector3, b: AABB) -> float:
	var hit: Variant = b.intersects_ray(origin, dir)
	if hit == null:
		return -1.0
	return ((hit as Vector3) - origin).dot(dir)


## Blocking boxes of tile i for movement, world space, cached until the tile is rebuilt (the
## cached array itself is returned: read it, never modify it): the building's bodies and walls
## (body_shapes.gd), every view.site_boxes(i) part (which can reach into neighbouring tiles), prop
## boxes (bus shelters, benches) and add_test_box() boxes overlapping the tile.
func boxes(i: int) -> Array[AABB]:
	if i < 0:
		var none: Array[AABB] = []
		return none
	return _entry(i)["boxes"]


## The building bodies of tile i (at most body_shapes.MAX_BODIES, inside view.building_aabb(i)).
func body_boxes(i: int) -> Array[AABB]:
	if i < 0:
		var none: Array[AABB] = []
		return none
	return _entry(i)["bodies"]


## Prop and post cylinders of tile i as (x, z, r, top) quadruples in world space: lamp poles,
## trunks, hydrants, bins, the building's own posts.
func cylinders(i: int) -> PackedFloat32Array:
	if i < 0:
		return PackedFloat32Array()
	return _entry(i)["cyls"]


## Merged bound of boxes(i) (AABB() when none). Movement and tests use boxes(); interaction
## raycasts use the full view.building_aabb(i).
func box(i: int) -> AABB:
	if i < 0:
		return AABB()
	var cached: Variant = _bounds.get(i)
	if cached != null:
		return cached
	var b := AABB()
	for a: AABB in boxes(i):
		b = a if b.size.x <= 0.0 else b.merge(a)
	_bounds[i] = b
	return b


func _hits(p: Vector3, radius: float, height: float) -> bool:
	var head := p.y + height
	for e: Dictionary in _bound_entries(p, radius):
		for b: AABB in e["boxes"]:
			if p.y >= b.end.y or b.position.y >= head:
				continue
			if (
				p.x > b.position.x - radius
				and p.x < b.end.x + radius
				and p.z > b.position.z - radius
				and p.z < b.end.z + radius
			):
				return true
		var cy: PackedFloat32Array = e["cyls"]
		for k in range(0, cy.size(), 4):
			if p.y >= cy[k + 3]:
				continue
			var rr := cy[k + 2] + radius
			var ddx := p.x - cy[k]
			var ddz := p.z - cy[k + 1]
			if ddx * ddx + ddz * ddz < rr * rr:
				return true
	for b: AABB in dynamic_boxes:
		if p.y >= b.end.y or b.position.y >= head:
			continue
		if (
			p.x > b.position.x - radius
			and p.x < b.end.x + radius
			and p.z > b.position.z - radius
			and p.z < b.end.z + radius
		):
			return true
	return false


func _can_stand(from: Vector3, c: Vector3, radius: float, height: float, max_rise: float) -> bool:
	var g := support_height(c, radius, from.y, max_rise)
	if is_nan(g) or g - from.y > max_rise + 1e-6:
		return false
	return not _hits(Vector3(c.x, maxf(from.y, g), c.z), radius, height)


## [push-out direction (xz, unit), is_cylinder] of the deepest blocker at p: a box's nearest face,
## a cylinder's radius. [ZERO, false] when nothing overlaps.
func _push_normal(p: Vector3, radius: float, height: float) -> Array:
	var best := 0.0
	var n := Vector2.ZERO
	var cyl := false
	var cx := roundi(p.x)
	var cz := roundi(p.z)
	var head := p.y + height
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if not D.in_bounds(cx + dx, cz + dz):
				continue
			var e := _entry(D.idx(cx + dx, cz + dz))
			for b: AABB in e["boxes"]:
				var d := _box_face(p, head, b, radius)
				if d[0] > best:
					best = d[0]
					n = d[1]
					cyl = false
			var cy: PackedFloat32Array = e["cyls"]
			for k in range(0, cy.size(), 4):
				if p.y >= cy[k + 3]:
					continue
				var off := Vector2(p.x - cy[k], p.z - cy[k + 1])
				var depth := cy[k + 2] + radius - off.length()
				if depth > best:
					best = depth
					cyl = true
					n = off.normalized() if off.length_squared() > 1e-14 else Vector2(1, 0)
	for b: AABB in dynamic_boxes:
		var d := _box_face(p, head, b, radius)
		if d[0] > best:
			best = d[0]
			n = d[1]
			cyl = false
	return [n, cyl]


## [depth, push-out direction (xz, unit)] of box b against a circle of `radius` at p (a body whose
## head is at head): how far p sits inside b grown by radius, out through its nearest face.
## [0, ZERO] when b does not overlap.
func _box_face(p: Vector3, head: float, b: AABB, radius: float) -> Array:
	if p.y >= b.end.y or b.position.y >= head:
		return [0.0, Vector2.ZERO]
	var px := p.x - (b.position.x - radius)
	var nx := b.end.x + radius - p.x
	var pz := p.z - (b.position.z - radius)
	var nz := b.end.z + radius - p.z
	var depth := minf(minf(px, nx), minf(pz, nz))
	if depth <= 0.0:
		return [0.0, Vector2.ZERO]
	if depth == px:
		return [depth, Vector2(-1, 0)]
	if depth == nx:
		return [depth, Vector2(1, 0)]
	if depth == pz:
		return [depth, Vector2(0, -1)]
	return [depth, Vector2(0, 1)]


## Vector2i(tile, index) -> how far p sits inside each box (grown by radius, distance to its
## nearest side in xz) or cylinder (index 100000 + k) that a circle of `radius` at p overlaps.
func _overlaps(p: Vector3, radius: float, height: float) -> Dictionary:
	var out := {}
	var cx := roundi(p.x)
	var cz := roundi(p.z)
	var head := p.y + height
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if not D.in_bounds(cx + dx, cz + dz):
				continue
			var i := D.idx(cx + dx, cz + dz)
			var e := _entry(i)
			var list: Array[AABB] = e["boxes"]
			for k in range(list.size()):
				var b := list[k]
				if p.y >= b.end.y or b.position.y >= head:
					continue
				var depth := minf(
					minf(p.x - (b.position.x - radius), b.end.x + radius - p.x),
					minf(p.z - (b.position.z - radius), b.end.z + radius - p.z)
				)
				if depth > 0.0:
					out[Vector2i(i, k)] = depth
			var cy: PackedFloat32Array = e["cyls"]
			for k in range(0, cy.size(), 4):
				if p.y >= cy[k + 3]:
					continue
				var depth := cy[k + 2] + radius - Vector2(p.x - cy[k], p.z - cy[k + 1]).length()
				if depth > 0.0:
					out[Vector2i(i, 100000 + k)] = depth
	for k in range(dynamic_boxes.size()):
		var b := dynamic_boxes[k]
		if p.y >= b.end.y or b.position.y >= head:
			continue
		var depth := minf(
			minf(p.x - (b.position.x - radius), b.end.x + radius - p.x),
			minf(p.z - (b.position.z - radius), b.end.z + radius - p.z)
		)
		if depth > 0.0:
			out[Vector2i(-1, k)] = depth
	return out


## The nearest free point for a stuck walker at p (nearest_free within 2 u), cached while the
## walker stays within 1 m of the last query.
func _escape_point(p: Vector3, radius: float) -> Vector3:
	if (
		not is_nan(_esc_from.x)
		and Vector2(p.x - _esc_from.x, p.z - _esc_from.z).length() < 1.0 * WS.M
		and is_equal_approx(_esc_r, radius)
	):
		return _esc_point
	_esc_from = p
	_esc_r = radius
	_esc_point = nearest_free(p, radius, 2.0)
	return _esc_point


## The obstacle a stuck walker is in: the boxes and cylinders overlapping p and, repeatedly,
## every one touching their merged bound (grown by radius). {"bound": AABB, "keys": {key: true}}
## with the _overlaps() keys.
func _cluster(p: Vector3, radius: float, height: float, start: Dictionary) -> Dictionary:
	var keys := {}
	var bound := AABB()
	for key: Vector2i in start.keys():
		keys[key] = true
		var kb := _key_box(key).grow(radius)
		bound = kb if bound.size.x <= 0.0 else bound.merge(kb)
	var cx := roundi(p.x)
	var cz := roundi(p.z)
	var head := p.y + height
	for _pass in range(3):
		var grew := false
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				if not D.in_bounds(cx + dx, cz + dz):
					continue
				var i := D.idx(cx + dx, cz + dz)
				var e := _entry(i)
				var list: Array[AABB] = e["boxes"]
				for k in range(list.size()):
					var key := Vector2i(i, k)
					var b := list[k]
					if keys.has(key) or p.y >= b.end.y or b.position.y >= head:
						continue
					var gb := b.grow(radius)
					if (
						gb.position.x < bound.end.x
						and gb.end.x > bound.position.x
						and gb.position.z < bound.end.z
						and gb.end.z > bound.position.z
					):
						keys[key] = true
						bound = bound.merge(gb)
						grew = true
				var cy: PackedFloat32Array = e["cyls"]
				for k in range(0, cy.size(), 4):
					var key := Vector2i(i, 100000 + k)
					if keys.has(key) or p.y >= cy[k + 3]:
						continue
					var rr := cy[k + 2] + radius
					if (
						cy[k] + rr > bound.position.x
						and cy[k] - rr < bound.end.x
						and cy[k + 1] + rr > bound.position.z
						and cy[k + 1] - rr < bound.end.z
					):
						keys[key] = true
						bound = bound.merge(
							AABB(
								Vector3(cy[k] - rr, bound.position.y, cy[k + 1] - rr),
								Vector3(rr * 2.0, 0.0, rr * 2.0)
							)
						)
						grew = true
		if not grew:
			break
	return {"bound": bound, "keys": keys}


## The world box of an _overlaps() key (a cylinder's square bound).
func _key_box(key: Vector2i) -> AABB:
	if key.x < 0:
		return dynamic_boxes[key.y] if key.y < dynamic_boxes.size() else AABB()
	var e := _entry(key.x)
	if key.y < 100000:
		return (e["boxes"] as Array[AABB])[key.y]
	var cy: PackedFloat32Array = e["cyls"]
	var k := key.y - 100000
	return AABB(
		Vector3(cy[k] - cy[k + 2], WS.GROUND_Y, cy[k + 1] - cy[k + 2]),
		Vector3(cy[k + 2] * 2.0, cy[k + 3] - WS.GROUND_Y, cy[k + 2] * 2.0)
	)


## Builds (once) tile i's colliders.
## The add_test_cylinder() cylinders overlapping tile i, appended to cyls.
func _add_test_cyls(i: int, cyls: PackedFloat32Array) -> void:
	for k in range(0, _test_cyls.size(), 4):
		var r := _test_cyls[k + 2]
		if (
			i >= 0
			and absf(_test_cyls[k] - D.tx(i)) < 0.5 + r
			and absf(_test_cyls[k + 1] - D.ty(i)) < 0.5 + r
		):
			cyls.append_array(_test_cyls.slice(k, k + 4))


func _entry(i: int) -> Dictionary:
	var cached: Variant = _tiles.get(i)
	if cached != null:
		return cached
	var bodies: Array[AABB] = []
	var walls: Array[AABB] = []
	var sites: Array[AABB] = []
	var props: Array[AABB] = []
	var cyls := PackedFloat32Array()
	var pick := AABB()
	if ctx != null and ctx.view != null and i >= 0:
		var view := ctx.view
		var holder := view.tile_holder(i)
		if holder != null and is_instance_valid(holder):
			pick = view.building_aabb(i)
			if pick.size.x > 0.0:
				_building_shapes(i, holder, pick, bodies, walls, cyls)
			_prop_shapes(i, holder, props, cyls)
		for s: AABB in view.site_boxes(i):
			if s.size.x > 0.0 and s.size.z > 0.0:
				sites.append(s)
	_add_test_cyls(i, cyls)
	var all: Array[AABB] = []
	all.append_array(bodies)
	all.append_array(walls)
	all.append_array(sites)
	all.append_array(props)
	if not _test_boxes.is_empty() and i >= 0:
		var tile := AABB(Vector3(D.tx(i) - 0.5, -INF, D.ty(i) - 0.5), Vector3(1.0, INF, 1.0))
		for b: AABB in _test_boxes:
			if (
				b.position.x < tile.end.x
				and b.end.x > tile.position.x
				and b.position.z < tile.end.z
				and b.end.z > tile.position.z
			):
				all.append(b)
	var bound := AABB()
	for b: AABB in all:
		bound = b if bound.size.x <= 0.0 else bound.merge(b)
	for k in range(0, cyls.size(), 4):
		var cb := AABB(
			Vector3(cyls[k] - cyls[k + 2], WS.GROUND_Y, cyls[k + 1] - cyls[k + 2]),
			Vector3(cyls[k + 2] * 2.0, maxf(cyls[k + 3] - WS.GROUND_Y, 1e-4), cyls[k + 2] * 2.0)
		)
		bound = cb if bound.size.x <= 0.0 else bound.merge(cb)
	var e := {
		"boxes": all,
		"bodies": bodies,
		"sites": sites,
		"props": props,
		"cyls": cyls,
		"bound": bound,
		"pick": pick
	}
	_tiles[i] = e
	return e


## Bodies, walls and posts of the building on tile i, from body_table.gd (or a runtime analysis
## when the model is new or its bounds changed since the bake).
func _building_shapes(
	_i: int,
	holder: Node3D,
	pick: AABB,
	bodies: Array[AABB],
	walls: Array[AABB],
	cyls: PackedFloat32Array
) -> void:
	var path := str(holder.get_meta("building_path", ""))
	var bx: Variant = holder.get_meta("building_xform", null)
	if path.is_empty() or typeof(bx) != TYPE_TRANSFORM3D:
		bodies.append(pick)
		return
	var xf: Transform3D = holder.transform * (bx as Transform3D)
	var local := xf.affine_inverse() * pick
	var shapes := _model_shapes(path, local)
	if shapes.is_empty():
		bodies.append(pick)
		return
	for b: AABB in shapes["bodies"]:
		bodies.append((xf * b).intersection(pick))
	for b: AABB in shapes["walls"]:
		walls.append((xf * b).intersection(pick))
	var sc := xf.basis.get_scale().x
	var cy: PackedFloat32Array = shapes["cyls"]
	for k in range(0, cy.size(), 4):
		var c := xf * Vector3(cy[k], cy[k + 3], cy[k + 1])
		cyls.append_array([c.x, c.z, cy[k + 2] * sc, c.y])


## The model-space shapes of a building model: the baked entry when its bounds match `local`,
## else one runtime analysis per file.
func _model_shapes(path: String, local: AABB) -> Dictionary:
	var row: Variant = TABLE.BODIES.get(path)
	if row != null:
		var r: Array = row
		var bb: AABB = r[0]
		if (
			(bb.position - local.position).length() < 2e-3
			and (bb.size - local.size).length() < 2e-3
		):
			var cy := PackedFloat32Array(r[3])
			var bl: Array[AABB] = []
			bl.assign(r[1])
			var wl: Array[AABB] = []
			wl.assign(r[2])
			return {"bodies": bl, "walls": wl, "cyls": cy}
	if _runtime_shapes.has(path):
		return _runtime_shapes[path]
	if not _warned.has(path):
		_warned[path] = true
		push_warning(
			(
				"CollisionWorld: %s has no current body_table entry; analysing it at runtime (re-run scripts/fp/player/body_bake.gd)"
				% path
			)
		)
	var ps := AP.load_scene(path)
	var out := {}
	if ps != null:
		var n := ps.instantiate() as Node3D
		if n != null:
			out = BS.analyse(n)
			n.free()
	_runtime_shapes[path] = out
	return out


## Street props on tile i: G1's `colliders` meta when the holder has one (then nothing else),
## else the lamps baked into lit roads, bus shelters, prop models and the cul-de-sac tree.
func _prop_shapes(i: int, holder: Node3D, props: Array[AABB], cyls: PackedFloat32Array) -> void:
	var hx := holder.transform
	if holder.has_meta("colliders"):
		_meta_shapes(holder, props, cyls)
		return
	var sim := ctx.sim
	var is_road := sim.kind[i] == D.ROAD
	for ch: Node in holder.get_children():
		if not (ch is Node3D):
			continue
		var n := ch as Node3D
		var path := n.scene_file_path
		var xf := hx * n.transform
		if is_road:
			if path.is_empty():
				var off := Vector2(n.position.x, n.position.z).length()
				if not (n is MeshInstance3D) and absf(off - PROC_STOP_OFFSET) < 0.01:
					var half := PROC_STOP_SIZE * 0.5
					props.append(xf * AABB(Vector3(-half.x, 0.0, -half.z), PROC_STOP_SIZE))
				continue
			if path in BUS_STOP_PATHS:
				props.append(xf * _model_bounds(path))
				continue
			var lit := false
			for b: Node in n.get_children():
				if b is Node3D and str(b.name).begins_with("Bulb_"):
					lit = true
					var bp := (b as Node3D).position
					var pole := Vector3(bp.x + signf(bp.x) * LAMP_OUT, 0.0, bp.z)
					var w := xf * pole
					cyls.append_array([w.x, w.z, LAMP_POLE_R, (xf * Vector3(bp.x, bp.y, bp.z)).y])
			if lit and path.ends_with("road_straight_lights.glb"):
				for pp: Vector2 in LAMP_POSTS:
					var w := xf * Vector3(pp.x, 0.0, pp.y)
					cyls.append_array([w.x, w.z, LAMP_POST_R, w.y + 1.2 * WS.M])
			continue
		var prop_dir := false
		for d: String in PROP_DIRS:
			prop_dir = prop_dir or path.begins_with(d)
		if not prop_dir:
			continue
		_prop(path, xf, props, cyls)
	if is_road:
		var m := RoadTopology.mask(sim, D.tx(i), D.ty(i))
		var arms := RoadTopology.arms(m)
		if arms.size() == 1 and sim.terrain[i] != D.WATER and RoadTopology.paved(sim, i):
			var arm := Vector2(arms[0])
			var c := (
				Vector3(D.tx(i), 0.0, D.ty(i)) - Vector3(arm.x, 0.0, arm.y) * WS.END_CIRCLE_OFFSET
			)
			cyls.append_array([c.x, c.z, TRUNK_R, WS.SIDEWALK_TOP + 6.0 * WS.M])


## The holder's `colliders` meta in world space; entries marked "down" (street props knocked
## over) do not block.
func _meta_shapes(holder: Node3D, props: Array[AABB], cyls: PackedFloat32Array) -> void:
	var hx := holder.transform
	for c: Variant in holder.get_meta("colliders", []):
		if typeof(c) != TYPE_DICTIONARY or bool((c as Dictionary).get("down", false)):
			continue
		var d: Dictionary = c
		if str(d.get("shape", "box")) == "cyl":
			var p := hx * (d.get("pos", Vector3.ZERO) as Vector3)
			var top := p.y + float(d.get("h", META_CYL_TOP))
			cyls.append_array([p.x, p.z, float(d.get("r", LAMP_R)), top])
		elif d.has("size"):
			props.append(hx * ConstructionKit.collider_aabb(d))


## One prop model by file name: lamp pole, trunk, box or a footprint cylinder.
func _prop(path: String, xf: Transform3D, props: Array[AABB], cyls: PackedFloat32Array) -> void:
	var f := path.get_file()
	for s: String in SOFT_PROPS:
		if f.begins_with(s):
			return
	var lb := _model_bounds(path)
	var wb := xf * lb
	if path in BUS_STOP_PATHS:
		props.append(wb)
		return
	for s: String in BOX_PROPS:
		if f.contains(s):
			props.append(wb)
			return
	var o := xf * Vector3.ZERO
	if f.begins_with("tree_"):
		cyls.append_array([o.x, o.z, TRUNK_R, wb.end.y])
	elif f.begins_with("lamp"):
		cyls.append_array([o.x, o.z, LAMP_R, wb.end.y])
	else:
		var c := wb.get_center()
		cyls.append_array(
			[c.x, c.z, clampf(maxf(wb.size.x, wb.size.z) * 0.5, PROP_R_MIN, PROP_R_MAX), wb.end.y]
		)


## Local AABB of a prop model's meshes, cached per file.
func _model_bounds(path: String) -> AABB:
	if _prop_bounds.has(path):
		return _prop_bounds[path]
	var b := AABB(Vector3(-0.01, 0.0, -0.01), Vector3(0.02, 0.05, 0.02))
	var ps := AP.load_scene(path)
	if ps != null:
		var n := ps.instantiate() as Node3D
		if n != null:
			var parts: Array = []
			BS._collect(n, Transform3D.IDENTITY, parts, false)
			var first := true
			for e: Dictionary in parts:
				var a: AABB = (
					(e["xform"] as Transform3D) * ((e["node"] as MeshInstance3D).mesh.get_aabb())
				)
				b = a if first else b.merge(a)
				first = false
			n.free()
	_prop_bounds[path] = b
	return b


## Slab test; {"t": float, "normal": Vector3} for the entry point, {} on a miss or when the origin is inside.
static func _ray_box(o: Vector3, d: Vector3, b: AABB) -> Dictionary:
	var t0 := -INF
	var t1 := INF
	var n := Vector3.ZERO
	for axis in range(3):
		var lo := b.position[axis]
		var hi := b.end[axis]
		if absf(d[axis]) < 1e-12:
			if o[axis] < lo or o[axis] > hi:
				return {}
			continue
		var a := (lo - o[axis]) / d[axis]
		var c := (hi - o[axis]) / d[axis]
		var nsign := -1.0
		if a > c:
			var tmp := a
			a = c
			c = tmp
			nsign = 1.0
		if a > t0:
			t0 = a
			n = Vector3.ZERO
			n[axis] = nsign
		t1 = minf(t1, c)
		if t0 > t1:
			return {}
	if t0 < 0.0:
		return {}
	return {"t": t0, "normal": n}


## Entry distance of a ray (unit d) into a vertical cylinder standing on the ground, or -1.
static func _ray_cyl(o: Vector3, d: Vector3, c: Vector2, r: float, top: float) -> float:
	var ox := o.x - c.x
	var oz := o.z - c.y
	var a := d.x * d.x + d.z * d.z
	if a < 1e-12:
		return -1.0
	var b := ox * d.x + oz * d.z
	var cc := ox * ox + oz * oz - r * r
	if cc <= 0.0:
		return -1.0
	var disc := b * b - a * cc
	if disc < 0.0:
		return -1.0
	var t := (-b - sqrt(disc)) / a
	if t < 0.0:
		return -1.0
	var y := o.y + d.y * t
	if y > top or y < WS.GROUND_Y:
		return -1.0
	return t
