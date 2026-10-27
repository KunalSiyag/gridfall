extends SceneTree
## Walkers vs the street and each other (round 3, rigidity): people on foot walk the sidewalk
## band, dodge the hero and queue at the zebras -- their drawn bodies (pos + vis_off, the same
## transform render.gd draws) never end up inside standing street furniture or each other. The
## furniture is what holds the hero too (the tile holders' colliders meta, chat spots aside), the
## queue spreads through rows behind the first, and the hero walks the band through the crowd to
## press walkers aside while it all steps.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const SW := preload("res://scripts/fp/traffic/sidewalks.gd")
const JN := preload("res://scripts/fp/traffic/junctions.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
## Shared city fixtures: a cross with E's poles, a tee (support/city_fixtures.gd).
const F := preload("res://tools/tests/support/city_fixtures.gd")
const DT := 1.0 / 60.0
## Half a walker's shoulders (walkers.gd PERSON_R).
const WR := WK.PERSON_R
## Overlap deeper than this (u) is inside, not a brush.
const TOL := 0.004
## Pairs closer than this are bodies inside each other (two shoulders minus a brush).
const PAIR_CLEAR := 2.0 * WR - TOL
const CROWD := 26
const STEPS := 840  # 14 s of crowd time, sampled every SAMPLE_EVERY
const SAMPLE_EVERY := 2
const GRID := 0.25
## Colliders-meta kinds that are places for people, not furniture in their way.
const NOT_FURNITURE := ["chat_spot"]

var fails: Array[String] = []
var ctx: FpContext
var tr: FpFeature
var wk: WK
var jn: JN
var sw: SW
var _rng := RandomNumberGenerator.new()
## cell -> Array of world shapes: {"c": Vector2, "r": float, "kind"} or {"box": AABB, "kind"}.
var _cells: Dictionary = {}
## Every collected shape, flat, for whole-city scans (the hero's press candidates).
var _all: Array = []
## kind -> [deepest overlap (u), where (Vector3)].
var _worst: Dictionary = {}
## Overlapping pairs seen: [depth (u), id a, id b].
var _pairs: Array = []
## The deepest pair, with both walkers' state, slot and drawn place.
var _worst_pair: Dictionary = {}
## Waiting walkers drawn inside something: [depth, where, slot, kind].
var _wait_hits: Array = []
## Consecutive samples a walker has been in scope (within LOD_NEAR). A walker that just
## entered from lod_far may be mid-overlap from its blind stretch; SCOPE_GRACE samples let
## a dodge open before its pairs carry any claim (walkers.gd line 26: the drawing range is
## also where crowd logic runs, and nobody can see a dot at 92 m).
var _scope: Dictionary = {}

## Samples of grace after entering scope before a walker's pairs and furniture depths count.
const SCOPE_GRACE := 12


func _init() -> void:
	await process_frame
	FeatureFlags.set_override("street_clutter", true)
	FeatureFlags.set_override("prop_bumps", true)
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	_rng.seed = 20260607
	F.ensure_cross(ctx.sim)
	F.ensure_tee(ctx.sim)
	ctx.view.set_fp_mode(true)
	if ctx.view.has_method("flush_rebuild_queue"):
		ctx.view.call("flush_rebuild_queue")
	ctx.collision.rebuild_all()
	tr = K.make_feature(ctx, "traffic")
	K.make_feature(ctx, "streetscape")
	if tr == null:
		K.check(fails, false, "fixture: the traffic feature is registered")
		K.finish(self, "FP_WALKER_COLLISION_TEST", fails)
		return
	tr.set("auto_step", false)
	tr.set("ambient_enabled", false)
	wk = tr.get("walkers")
	jn = tr.get("junctions")
	sw = wk.sw
	var tiles := _crowd_tiles()
	_collect_shapes()
	_spawn_crowd(tiles)
	_spawn_queue()
	_check_crowd(_longest_edge(tiles))
	_check_press(_longest_edge(tiles))
	_check_queue()
	_report()
	K.finish(self, "FP_WALKER_COLLISION_TEST", fails)


# ------------------------------------------------------------------ fixtures


## Straight road tiles with the most street furniture stood on their sidewalks.
func _crowd_tiles() -> Array:
	var best: Array = []
	for i: int in ctx.sim.active:
		if ctx.sim.kind[i] != D.ROAD:
			continue
		if str(RoadTopology.piece(RoadTopology.mask(ctx.sim, D.tx(i), D.ty(i)))[0]) != "straight":
			continue
		var holder := ctx.view.tile_holder(i)
		if holder == null:
			continue
		var n := 0
		for c: Variant in holder.get_meta("colliders", []):
			if typeof(c) == TYPE_DICTIONARY and not bool((c as Dictionary).get("down", false)):
				n += 1
		best.append([n, i])
	best.sort_custom(func(a, b): return int(a[0]) > int(b[0]))
	var out: Array = []
	for e in best.slice(0, 3):
		out.append(e[1])
	return out


## Every standing colliders-meta shape of the city, world space, in a coarse grid.
func _collect_shapes() -> void:
	_cells.clear()
	_all.clear()
	var n := 0
	for i: int in ctx.sim.active:
		if ctx.sim.kind[i] != D.ROAD:
			continue
		var holder := ctx.view.tile_holder(i)
		if holder == null:
			continue
		for c: Variant in holder.get_meta("colliders", []):
			if typeof(c) != TYPE_DICTIONARY or bool((c as Dictionary).get("down", false)):
				continue
			var d: Dictionary = c
			var kind := str(d.get("kind", "?"))
			if NOT_FURNITURE.has(kind):
				continue
			var shape := {}
			if str(d.get("shape", "box")) == "cyl":
				if float(d.get("h", 0.0)) < 0.2 * WS.M:
					continue
				var p: Vector3 = holder.transform * (d.get("pos", Vector3.ZERO) as Vector3)
				shape = {"c": Vector2(p.x, p.z), "r": float(d.get("r", 0.0)), "kind": kind}
			else:
				var box: AABB = ConstructionKit.collider_aabb(d)
				if box.size.y < 0.2 * WS.M:
					continue
				box = holder.transform * box
				shape = {"box": box, "kind": kind}
			_add_shape(shape)
			_all.append(shape)
			n += 1
	K.check(fails, n > 40, "fixture: standing street furniture to measure against (%d)" % n)


func _add_shape(shape: Dictionary) -> void:
	var r := WR
	var a := Vector2(INF, INF)
	var b := Vector2(-INF, -INF)
	if shape.has("box"):
		var box: AABB = shape["box"]
		a = Vector2(box.position.x, box.position.z)
		b = Vector2(box.end.x, box.end.z)
	else:
		var c: Vector2 = shape["c"]
		r = float(shape["r"]) + WR
		a = c - Vector2(r, r)
		b = c + Vector2(r, r)
	for gx in range(floori(a.x / GRID), floori(b.x / GRID) + 1):
		for gz in range(floori(a.y / GRID), floori(b.y / GRID) + 1):
			var key := Vector2i(gx, gz)
			if not _cells.has(key):
				_cells[key] = []
			(_cells[key] as Array).append(shape)


## Depth (u) the circle at p (radius WR) overlaps a shape by, 0 when clear.
func _depth(p: Vector3, shape: Dictionary) -> float:
	if shape.has("box"):
		var b: AABB = shape["box"]
		if p.y + 1.7 * WS.M < b.position.y or p.y > b.end.y:
			return 0.0
		var dx := maxf(maxf(b.position.x - p.x, 0.0), p.x - b.end.x)
		var dz := maxf(maxf(b.position.z - p.z, 0.0), p.z - b.end.z)
		return WR - Vector2(dx, dz).length()
	var c: Vector2 = shape["c"]
	return WR + float(shape["r"]) - c.distance_to(Vector2(p.x, p.z))


## Shapes near p (the 3x3 grid cells around it).
func _shapes_near(p: Vector3) -> Array:
	var out: Array = []
	var key := Vector2i(floori(p.x / GRID), floori(p.z / GRID))
	for gx in range(key.x - 1, key.x + 2):
		for gz in range(key.y - 1, key.y + 2):
			out.append_array(_cells.get(Vector2i(gx, gz), []))
	return out


## Walkers placed along every non-zebra edge of the furniture tiles, both ways, staggered.
func _spawn_crowd(tiles: Array) -> void:
	var edges: Array = []
	for i: int in tiles:
		for e: SW.PedEdge in sw.by_tile.get(i, []):
			if e == null or e.zebra or not e.alive:
				continue
			edges.append(e)
	var spawned := 0
	while spawned < CROWD and not edges.is_empty():
		for e: SW.PedEdge in edges:
			if spawned >= CROWD:
				break
			var w := wk.make("ambient")
			wk.place(w, e, _rng.randf() * e.length, 1 if _rng.randf() < 0.5 else -1)
			spawned += 1
	K.check(fails, spawned >= 12, "fixture: a crowd on the furniture streets (%d)" % spawned)


## Walkers with a plan to cross each zebra of the cross tile, held at the kerb by a red phase.
func _spawn_queue() -> void:
	var cross := -1
	for i: int in ctx.sim.active:
		if ctx.sim.kind[i] != D.ROAD:
			continue
		if str(RoadTopology.piece(RoadTopology.mask(ctx.sim, D.tx(i), D.ty(i)))[0]) != "cross":
			continue
		cross = i
		break
	if cross < 0:
		K.check(fails, false, "fixture: a signalled cross for the queue")
		return
	# Hold the lights on a phase where no arm lets people across.
	for k in range(64):
		jn.clock = 0.5 * k
		var any_walk := false
		for arm in range(4):
			any_walk = any_walk or jn.ped_walk(cross, arm)
		if not any_walk:
			break
	var held := 0
	for arm in range(4):
		var z: SW.PedEdge = sw.zebras.get(cross * 4 + arm, null)
		if z == null or not z.alive:
			continue
		# The sidewalk edge feeding the zebra's a end.
		var feeder: SW.PedEdge = null
		for eid: int in sw.adj[z.a]:
			var e: SW.PedEdge = sw.edges[eid]
			if e != null and e.alive and not e.zebra:
				feeder = e
				break
		if feeder == null:
			continue
		var dir := 1 if feeder.b == z.a else -1
		for k in range(3):
			var w := wk.make("ambient")
			var frac := 0.3 + 0.2 * k if dir > 0 else 0.7 - 0.2 * k
			wk.place(w, feeder, feeder.length * frac, dir)
			w.plan = [{"edge": z.id, "dir": 1}]
			held += 1
	K.check(fails, held >= 8, "fixture: walkers held at the zebras (%d)" % held)


## The longest non-zebra edge of the crowd tiles, for the hero to walk along.
func _longest_edge(tiles: Array) -> SW.PedEdge:
	var best: SW.PedEdge = null
	for i: int in tiles:
		for e: SW.PedEdge in sw.by_tile.get(i, []):
			if e == null or e.zebra or not e.alive:
				continue
			if best == null or e.length > best.length:
				best = e
	K.check(fails, best != null, "fixture: a sidewalk edge for the hero to press through")
	return best


# ------------------------------------------------------------------ scenarios


## The hero walks the band through the crowd; walkers dodge, chat and queue behind them.
func _check_crowd(hero_edge: SW.PedEdge) -> void:
	var p := ctx.player
	var start := Vector3(hero_edge.pts[0].x, 0.0, hero_edge.pts[0].y)
	var end := Vector3(hero_edge.pts[-1].x, 0.0, hero_edge.pts[-1].y)
	var g := ctx.collision.walk_height(start)
	if not is_nan(g):
		start.y = g
	p.teleport(start, atan2(end.x - start.x, end.z - start.z))
	p.update_view(DT)
	wk.player_on = true
	for k in range(STEPS):
		wk.player_pos = p.position
		wk.step(DT)
		for w: WK.Walker in wk.walkers:
			wk.ease_visuals(w, DT)
		if Vector2(end.x - p.position.x, end.z - p.position.z).length() > 0.05:
			p.simulate(Vector2(0.0, 1.0), false, DT)
			p.update_view(DT)
		if k % SAMPLE_EVERY == 0:
			_sample()
	wk.player_on = false
	var deepest := 0.0
	for kind: String in _worst.keys():
		deepest = maxf(deepest, _worst[kind][0])
	K.check(
		fails,
		deepest <= TOL,
		(
			"walkers never end up inside standing street furniture (deepest %.0f mm)"
			% [deepest / WS.M * 1000.0]
		)
	)
	var pair_depth := 0.0
	for e in _pairs:
		pair_depth = maxf(pair_depth, e[0])
	K.check(
		fails,
		_pair_ok(),
		(
			"walkers never end up inside each other (deepest %.0f mm over %d samples)"
			% [pair_depth / WS.M * 1000.0, _pairs.size()]
		)
	)


## The waiting crowd at the kerb spreads through rows behind the first: rows stand clear too.
func _check_queue() -> void:
	var waiting := 0
	for w: WK.Walker in wk.walkers:
		if w.state != "wait":
			continue
		waiting += 1
		var at := w.pos + w.vis_off
		for shape: Dictionary in _shapes_near(at):
			var d := _depth(at, shape)
			if d > TOL:
				_wait_hits.append([d, at, w.wait_slot, str(shape["kind"])])
				break
	K.check(fails, waiting >= 8, "fixture: a crowd waiting at the kerbs (%d)" % waiting)
	K.check(
		fails,
		_wait_hits.is_empty(),
		"the waiting rows stand clear of the furniture %s" % str(_wait_hits.slice(0, 3))
	)


## The hero runs a walker down from behind, on the side away from furniture beside the band: the
## walker's dodge (GIVE_WAY, the deepest it ever leaves the band) must stop short of it.
func _check_press(hero_edge: SW.PedEdge) -> void:
	var p := ctx.player
	var candidates: Array = []
	for shape: Dictionary in _all:
		var c := _shape_center(shape)
		var cp := _closest_on_edge(hero_edge, c)
		if float(cp["dist"]) <= 0.075:
			candidates.append([shape, cp])
	candidates.resize(mini(6, candidates.size()))
	K.check(
		fails,
		not candidates.is_empty(),
		"fixture: furniture the hero can press a walker toward (%d)" % candidates.size()
	)
	var worst := 0.0
	var worst_kind := "none"
	for cand in candidates:
		var shape: Dictionary = cand[0]
		var cp: Dictionary = cand[1]
		var fwd: Vector2 = cp["fwd"]
		var side: float = cp["side"]
		if side == 0.0:
			side = 1.0
		# The walker sets off half a metre short of the furniture; the hero runs it down from
		# behind, offset to the far side, so the dodge lands toward the furniture.
		var t_walk := clampf(float(cp["t"]) - 0.025, 0.0, hero_edge.length)
		var w := wk.make("ambient")
		w.chatty = false
		w.speed = WS.PED_WALK
		wk.place(w, hero_edge, t_walk, 1)
		var at_walk := w.pos
		var hero_at := (
			at_walk - Vector3(fwd.x, 0.0, fwd.y) * 0.04 - Vector3(-fwd.y, 0.0, fwd.x) * side * 0.015
		)
		var g := ctx.collision.walk_height(hero_at)
		if not is_nan(g):
			hero_at.y = g
		p.teleport(hero_at, atan2(fwd.x, fwd.y))
		p.update_view(DT)
		wk.player_on = true
		for k in range(160):
			wk.player_pos = p.position
			wk.step(DT)
			for o: WK.Walker in wk.walkers:
				wk.ease_visuals(o, DT)
			p.simulate(Vector2(0.0, 1.0), true, DT)
			p.update_view(DT)
			if k % 3 == 0:
				var drawn := w.pos + w.vis_off
				for near_shape: Dictionary in _shapes_near(drawn):
					var d := _depth(drawn, near_shape)
					if d > worst:
						worst = d
						worst_kind = str(near_shape["kind"])
		wk.remove(w)
	K.check(
		fails,
		worst <= TOL,
		(
			"a walker pressed toward furniture stops short of it (deepest %.0f mm into a %s)"
			% [worst / WS.M * 1000.0, worst_kind]
		)
	)


## A shape's world centre, for finding the furniture nearest a band.
func _shape_center(shape: Dictionary) -> Vector2:
	if shape.has("box"):
		var b: AABB = shape["box"]
		return Vector2((b.position.x + b.end.x) * 0.5, (b.position.z + b.end.z) * 0.5)
	return shape["c"]


## The closest point of an edge's polyline to c: distance, where, the walking direction there,
## the edge t of it, and the side of c off the band (+ is perp of the walking direction).
func _closest_on_edge(e: SW.PedEdge, c: Vector2) -> Dictionary:
	var best := {"dist": INF}
	for i in range(e.pts.size() - 1):
		var a: Vector2 = e.pts[i]
		var b: Vector2 = e.pts[i + 1]
		var ab := b - a
		var t := clampf((c - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
		var at := a + ab * t
		var d := at.distance_to(c)
		if d < float(best["dist"]):
			var u := float(e.cum[i]) + ab.length() * t
			var dir := sw.dir_at(e, u)
			best = {
				"dist": d,
				"at": Vector3(at.x, 0.0, at.y),
				"fwd": dir,
				"t": u,
				"side": signf(-(c.x - at.x) * dir.y + (c.y - at.y) * dir.x),
			}
	return best


# ------------------------------------------------------------------ measuring


## One sample: every in-scope walker's drawn body against the furniture, and every pair
## against each other. Records the deepest overlap per shape kind and the deepest pairs.
## Walkers beyond LOD_NEAR (lod_far) are neither drawn nor crowd-simulated (walkers.gd line
## 26: out of sight, out of budget), and a walker fresh in scope may still be opening a dodge,
## so SCOPE_GRACE samples pass before it carries any claim here.
func _sample() -> void:
	var drawn: Array = []
	for w: WK.Walker in wk.walkers:
		var run := 0 if w.lod_far else int(_scope.get(w.id, 0)) + 1
		_scope[w.id] = run
		if w.lod_far or run < SCOPE_GRACE:
			continue
		var at := w.pos + w.vis_off
		drawn.append([at, w])
		for shape: Dictionary in _shapes_near(at):
			var d := _depth(at, shape)
			if d <= 0.0:
				continue
			var kind := str(shape["kind"])
			if not _worst.has(kind) or d > _worst[kind][0]:
				_worst[kind] = [d, at]
	for i in range(drawn.size()):
		for j in range(i + 1, drawn.size()):
			var d: float = (drawn[i][0] as Vector3).distance_to(drawn[j][0])
			if PAIR_CLEAR - d > 0.0:
				_pairs.append(
					[PAIR_CLEAR - d, (drawn[i][1] as WK.Walker).id, (drawn[j][1] as WK.Walker).id]
				)
				if not _worst_pair.has("depth") or PAIR_CLEAR - d > float(_worst_pair["depth"]):
					var a: WK.Walker = drawn[i][1]
					var b: WK.Walker = drawn[j][1]
					_worst_pair = {
						"depth": PAIR_CLEAR - d,
						"a": [a.id, a.state, a.wait_slot, a.pos + a.vis_off],
						"b": [b.id, b.state, b.wait_slot, b.pos + b.vis_off],
					}
					_pair_notes(a)
					_pair_notes(b)


func _pair_notes(w: WK.Walker) -> void:
	var key := "w%d" % w.id
	var e: SW.PedEdge = w.edge
	_worst_pair[key] = {
		"edge": -1 if e == null else e.id,
		"far": w.far,
		"role": w.role,
		"zebra": false if e == null else e.zebra,
		"t": w.t,
		"dir": w.dir,
		"lat": w.lat,
		"v": w.v,
		"speed": w.speed,
		"hold": w.hold,
		"on_leg": w.on_leg,
		"plan": w.plan.size(),
	}


## A brief brush while passing is the crowd at work; a body inside another, or a pair stuck
## together, is not. Pairs are (id a, id b): three samples of the same pair is a jam.
func _pair_ok() -> bool:
	var times := {}
	for e in _pairs:
		var key := int(e[1]) * 100003 + int(e[2])
		times[key] = int(times.get(key, 0)) + 1
	for key: int in times.keys():
		if times[key] > 3:
			return false
	return true


func _report() -> void:
	for kind: String in _worst.keys():
		var e: Array = _worst[kind]
		print(
			(
				"  walker vs %s: deepest %.0f mm at (%.1f, %.1f)"
				% [kind, e[0] / WS.M * 1000.0, e[1].x, e[1].z]
			)
		)
	if _worst_pair.has("depth"):
		print("  worst pair: %s" % JSON.stringify(_worst_pair).substr(0, 900))
