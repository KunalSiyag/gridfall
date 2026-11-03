extends SceneTree
## Water (unit A3): the river-bed height shared by the bed mesh and the collision, the hero's
## wading (flag hero_wade: walks in to WADE_MAX, slower when deeper, stops there, walks back out;
## unstick leaves a wader in place; flag off = the old wall), and everyone else's water staying a
## wall (NPCs, cars, animals and thrown bodies call the CollisionWorld with default arguments). The
## water material is told the renderer, and the shader's current and ripples reach the surface.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const RB := preload("res://scripts/fp/world/riverbed.gd")
const WADE := preload("res://scripts/fp/player/wade.gd")
const WATER := preload("res://scripts/world/water_surface.gd")
const SHORE := preload("res://scripts/world/shore.gd")
const WADE_FEATURE := preload("res://scripts/fp/water/wade_feature.gd")
const DT := 1.0 / 60.0
const M := WS.M
const R := WS.PLAYER_RADIUS
const DIRS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]

var fails: Array[String] = []


## A stand-in for the traffic feature with no cars: the player's poll then runs its blocker
## handling, where the boats' hull boxes are added.
class FakeTraffic:
	extends FpFeature

	func feature_id() -> String:
		return "traffic"

	func blockers_near(_p: Vector3, _reach: float) -> Array:
		return []


func _init() -> void:
	await process_frame
	var ctx := K.make_ctx(get_root(), {"view": true, "grow": true})
	ctx.player.set_process(false)
	var bank := _find_bank(ctx)
	K.check(fails, not bank.is_empty(), "fixture: a straight river bank in the city")
	if not bank.is_empty():
		_check_bed(ctx, bank)
		_check_mesh_agrees(ctx)
		_check_wade(ctx, bank)
		_check_speed(ctx, bank)
		_check_sprint(ctx, bank)
		_check_others(ctx, bank)
		_check_unstick(ctx, bank)
		_check_flag_off(ctx, bank)
		_check_toast(ctx, bank)
		_check_boats(ctx, bank)
		_check_boat_poll(ctx, bank)
		_check_eye(ctx, bank)
	_check_surface(ctx)
	_check_view(ctx)
	_check_shore(ctx)
	if not bank.is_empty():
		_check_feature(ctx, bank)
	K.finish(self, "FP_WATER_TEST", fails)


## A straight bank: an open-water tile whose only land neighbours are the three on one side, with a
## bare land tile on that side. {"land": Vector2i, "dir": Vector2i (towards the water), "water":
## Vector2i, "start": Vector3 (feet at the land tile's near-the-water side), "yaw": degrees}.
func _find_bank(ctx: FpContext) -> Dictionary:
	var sim := ctx.sim
	for i in sim.active:
		if sim.terrain[i] != D.WATER or sim.kind[i] == D.ROAD:
			continue
		var x := D.tx(i)
		var y := D.ty(i)
		var land := RB.land_flags(sim, x, y)
		if land.count(true) != 3:
			continue
		for k in range(4):
			if not land[k] or land[(k + 1) % 4] or land[(k + 3) % 4]:
				continue
			var back := DIRS[k]
			var lt := Vector2i(x + back.x, y + back.y)
			var j := D.idx(lt.x, lt.y)
			if sim.kind[j] == D.ROAD or not ctx.collision.boxes(j).is_empty():
				continue
			if sim.kind[j] not in [D.EMPTY, D.PARK, D.FOREST]:
				continue
			var dir := -back
			# The walk crosses the water tile along its centre line.
			var start := Vector3(lt.x + 0.2 * dir.x, 0.0, lt.y + 0.2 * dir.y)
			var yaw := rad_to_deg(atan2(-float(dir.x), -float(dir.y)))
			return {"land": lt, "dir": dir, "water": Vector2i(x, y), "start": start, "yaw": yaw}
	return {}


func _stand(ctx: FpContext, bank: Dictionary) -> FpPlayer:
	var p := ctx.player
	p.wade_on = true
	p.free_running = true
	p.teleport(bank["start"], float(bank["yaw"]))
	p.velocity = Vector3.ZERO
	return p


## The bed: GROUND_Y at the bank, RIVERBED_Y mid-tile, a ramp gentle enough to walk (slope under
## the step height per sub-step), depth zero until the bed sinks below the surface.
func _check_bed(ctx: FpContext, bank: Dictionary) -> void:
	var sim := ctx.sim
	var wt: Vector2i = bank["water"]
	var dir: Vector2i = bank["dir"]
	var centre := Vector3(wt.x, 0.0, wt.y)
	var edge := centre - Vector3(dir.x, 0.0, dir.y) * 0.5
	K.check(
		fails,
		is_equal_approx(RB.bed_height(sim, edge.x, edge.z), WS.GROUND_Y),
		"the bed meets the grass at the tile border"
	)
	K.check(
		fails,
		is_equal_approx(RB.bed_height(sim, centre.x, centre.z), WS.RIVERBED_Y),
		"the bed is at RIVERBED_Y mid-tile"
	)
	var worst := 0.0
	var prev := WS.GROUND_Y
	var n := 400
	for k in range(1, n + 1):
		var q := edge + Vector3(dir.x, 0.0, dir.y) * (0.5 * float(k) / float(n))
		var h := RB.bed_height(sim, q.x, q.z)
		worst = maxf(worst, absf(h - prev) / (0.5 / float(n)))
		prev = h
	K.check(
		fails,
		worst < 0.45 and worst * WS.PLAYER_RADIUS < WS.STEP_HEIGHT,
		(
			"the bank ramp slopes %.2f at most: a sub-step climbs under the %.0f cm step"
			% [worst, WS.STEP_HEIGHT / M * 100.0]
		)
	)
	K.check(fails, RB.depth_at(sim, edge.x, edge.z) == 0.0, "no water over the bank's top")
	K.check(
		fails,
		RB.depth_at(sim, centre.x, centre.z) > WS.WADE_MAX,
		"mid-river is deeper than the hero wades"
	)
	var land_p := Vector3(bank["land"].x, 0.0, bank["land"].y)
	K.check(fails, is_nan(RB.bed_height(sim, land_p.x, land_p.z)), "bed_height is NAN on land")


## The bed mesh CityView built and RiverBed.bed_height (which the collision reads) agree at
## three interior points of EVERY triangle, so the eye and the feet see one bed on straight banks,
## corners, lakes and bridge-end tiles alike. The scan also reports how many distinct neighbour
## patterns (the eight land flags of a tile) it covered.
func _check_mesh_agrees(ctx: FpContext) -> void:
	var view: CityView = ctx.view
	var arrays := (view._bed_node.mesh as ArrayMesh).surface_get_arrays(0)
	var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var tris := idx.size() / 3
	K.check(fails, tris > 0, "the bed mesh has triangles (%d)" % tris)
	var worst := 0.0
	var tested := 0
	var patterns := {}
	for t in range(tris):
		var a := vs[idx[t * 3]]
		var b := vs[idx[t * 3 + 1]]
		var c := vs[idx[t * 3 + 2]]
		# Interior points of the triangle (barycentric), skipping the degenerate ones.
		for w: Vector3 in [Vector3(0.2, 0.3, 0.5), Vector3(0.6, 0.2, 0.2), Vector3(0.1, 0.1, 0.8)]:
			var p := a * w.x + b * w.y + c * w.z
			var h := RB.bed_height(ctx.sim, p.x, p.z)
			if is_nan(h):
				continue
			worst = maxf(worst, absf(h - p.y))
			tested += 1
			var land := RB.land_flags(ctx.sim, roundi(p.x), roundi(p.z))
			var key := 0
			for k in range(land.size()):
				key |= (1 if land[k] else 0) << k
			patterns[key] = true
	K.check(
		fails, tested > tris, "bed mesh sampled at %d points over %d triangles" % [tested, tris]
	)
	K.check(
		fails,
		patterns.size() >= 4,
		(
			"the scan covered %d tile neighbour patterns (straight banks, corners, lakes)"
			% patterns.size()
		)
	)
	K.check(
		fails,
		worst < 1e-5,
		"the bed mesh and RiverBed.bed_height agree (worst %s u)" % str(snappedf(worst, 1e-9))
	)


## The hero wades in: the feet follow the bed down, the walk ends at WADE_MAX of water or before,
## never over a bridge, and walking back returns the feet to the grass level.
func _check_wade(ctx: FpContext, bank: Dictionary) -> void:
	var p := _stand(ctx, bank)
	var col := ctx.collision
	var deepest := 0.0
	var bridge := false
	for k in range(900):
		p.simulate(Vector2(0, 1), false, DT)
		deepest = maxf(deepest, col.water_depth(p.position))
		var t := col.tile_at(p.position)
		bridge = bridge or (t >= 0 and ctx.sim.kind[t] == D.ROAD and ctx.sim.terrain[t] == D.WATER)
	var depth := col.water_depth(p.position)
	K.check(
		fails, deepest > 0.5 * M, "walking toward the river enters it: %.2f m deep" % (deepest / M)
	)
	K.check(
		fails,
		deepest <= WS.WADE_MAX + 1e-4,
		"and stops at %.2f m of water (limit %.2f m)" % [deepest / M, WS.WADE_MAX / M]
	)
	K.check(
		fails,
		deepest > WS.WADE_MAX * 0.85,
		(
			"it reaches nearly the limit (%.2f m): the bank ramp is walkable all the way"
			% (deepest / M)
		)
	)
	var bed := RB.bed_height(ctx.sim, p.position.x, p.position.z)
	K.check(
		fails,
		absf(p.position.y - bed) < 1e-4 and p.position.y < WS.WATER_Y,
		"the feet stand on the bed (%.3f m, bed %.3f m)" % [p.position.y / M, bed / M]
	)
	K.check(fails, not bridge, "the walk never touched a bridge tile")
	K.check(fails, absf(p.wade_depth - depth) < 1e-4, "wade_depth reads the water under the feet")
	# Sprint into the limit: no tunnelling past it.
	p.teleport(bank["start"], float(bank["yaw"]))
	var worst := 0.0
	for k in range(600):
		p.simulate(Vector2(0, 1), true, DT, false, k % 40 == 0)
		worst = maxf(worst, col.water_depth(p.position))
	K.check(
		fails,
		worst <= WS.WADE_MAX + 1e-4,
		"a sprint with jumps cannot tunnel past the limit (%.2f m)" % (worst / M)
	)
	# And back out onto the grass.
	p.teleport(bank["start"], float(bank["yaw"]))
	for k in range(420):
		p.simulate(Vector2(0, 1), false, DT)
	var in_water := col.water_depth(p.position) > 0.1 * M
	K.check(fails, in_water, "fixture: wading in the shallows")
	p.teleport(p.position, float(bank["yaw"]) + 180.0, 0.0, false)
	var on_land := -1
	for k in range(900):
		p.simulate(Vector2(0, 1), false, DT)
		var t := col.tile_at(p.position)
		if on_land < 0 and t >= 0 and ctx.sim.terrain[t] != D.WATER:
			on_land = k
		if on_land >= 0 and k > on_land + 30:
			break
	var out := (
		on_land >= 0
		and col.water_depth(p.position) == 0.0
		and absf(p.position.y - col.walk_height(p.position)) < 1e-4
		and absf(p.position.y - WS.GROUND_Y) < 0.012
	)
	K.check(
		fails, out, "walking back leaves the water at ground level (y %.3f m)" % (p.position.y / M)
	)


## Speed in 0.7 m of water against dry land: the same run covers less than 60 % of the ground.
func _check_speed(ctx: FpContext, bank: Dictionary) -> void:
	var p := _stand(ctx, bank)
	var col := ctx.collision
	var dir: Vector2i = bank["dir"]
	var lt: Vector2i = bank["land"]
	var d3 := Vector3(dir.x, 0.0, dir.y)
	# A point in 0.7 m of water on the ramp, found by search along the walking line.
	var pos := Vector3.ZERO
	for k in range(0, 400):
		var q := Vector3(lt.x, 0.0, lt.y) + d3 * (0.5 + 0.2 * float(k) / 400.0)
		if col.water_depth(q) >= 0.7 * M:
			pos = q
			break
	K.check(fails, pos != Vector3.ZERO, "fixture: a spot in 0.7 m of water")
	pos.y = col.walk_height(pos, WS.WADE_MAX)
	var dry := _pace(p, Vector3(lt.x, WS.GROUND_Y, lt.y), bank)
	var wet := _pace(p, pos, bank)
	K.check(
		fails,
		wet > 0.0 and wet < 0.6 * dry,
		(
			"a 1 s run covers %.2f m in 0.7 m of water against %.2f m dry (%.0f %%)"
			% [wet / M, dry / M, wet / maxf(dry, 1e-9) * 100.0]
		)
	)


## Metres of ground a 1 s run covers from `at`, along the bank (the depth stays the same).
func _pace(p: FpPlayer, at: Vector3, bank: Dictionary) -> float:
	var dir: Vector2i = bank["dir"]
	var along := Vector2(-dir.y, dir.x)
	p.teleport(at, rad_to_deg(atan2(-along.x, -along.y)), 0.0, false)
	var start := p.position
	for k in range(60):
		p.simulate(Vector2(0, 1), true, DT)
	return Vector2(p.position.x - start.x, p.position.z - start.z).length()


## Past the ankles no sprint builds: free running's leap pace is capped at a run.
func _check_sprint(ctx: FpContext, bank: Dictionary) -> void:
	K.check(
		fails,
		WADE.caps_sprint(0.4 * M) and not WADE.caps_sprint(0.2 * M),
		"no sprint past 0.3 m of water"
	)
	K.check(
		fails,
		(
			is_equal_approx(WADE.speed_factor(0.0), 1.0)
			and is_equal_approx(WADE.speed_factor(WS.WADE_MAX), WS.WADE_SLOW)
			and WADE.speed_factor(0.4 * M) < 1.0
			and WADE.speed_factor(0.4 * M) > WS.WADE_SLOW
		),
		"the wading factor runs from 1 at the ankle to WADE_SLOW at the limit"
	)
	K.check(
		fails,
		WADE.jump_factor(0.5 * M) < 1.0 and WADE.jump_factor(0.0) == 1.0,
		"a jump in water is weaker"
	)
	var p := _stand(ctx, bank)
	p.wade_depth = 0.5 * M
	K.check(
		fails,
		p._top_speed(true) <= WS.RUN * WADE.speed_factor(0.5 * M) + 1e-9,
		"a sprint in 0.5 m tops out under a run"
	)
	p.wade_depth = 0.0


## NPCs, cars, animals and thrown bodies: water stays a wall whatever the hero does.
func _check_others(ctx: FpContext, bank: Dictionary) -> void:
	var col := ctx.collision
	var dir: Vector2i = bank["dir"]
	var lt: Vector2i = bank["land"]
	var d3 := Vector3(dir.x, 0.0, dir.y)
	var wet := Vector3(lt.x, 0.0, lt.y) + d3 * 0.6
	K.check(fails, is_nan(col.ground_height(wet)), "ground_height is NAN over open water")
	K.check(fails, is_nan(col.walk_height(wet)), "walk_height is NAN over open water by default")
	K.check(
		fails,
		is_nan(col.support_height(wet, R, 0.0, WS.STEP_HEIGHT)),
		"support_height is NAN over water by default"
	)
	K.check(
		fails,
		col.is_blocked(wet, R) and col.body_blocked(wet, R, WS.PLAYER_HEIGHT),
		"is_blocked and body_blocked hold over water by default"
	)
	K.check(fails, col.surface_at(wet) == "water", "surface_at names the water")
	K.check(
		fails,
		not col.is_blocked(wet, R, WS.WADE_MAX),
		"a wader may stand in the shallows (%.2f m)" % (col.water_depth(wet) / M)
	)
	var from := Vector3(lt.x, WS.GROUND_Y, lt.y) + d3 * 0.4
	var out := from
	for k in range(200):
		out = col.move_body(out, d3 * 0.01, R, WS.PLAYER_HEIGHT, WS.STEP_HEIGHT)
	var border := (out.x - lt.x) * dir.x + (out.z - lt.y) * dir.y
	K.check(
		fails, border <= 0.5 + 1e-4, "an NPC's move_body stops at the tile border (%.4f)" % border
	)
	var hero := from
	for k in range(200):
		hero = col.move_body(hero, d3 * 0.01, R, WS.PLAYER_HEIGHT, WS.STEP_HEIGHT, WS.WADE_MAX)
	K.check(
		fails,
		(hero.x - lt.x) * dir.x + (hero.z - lt.y) * dir.y > 0.55,
		"a wader's move_body goes on into the water"
	)
	# Open water is not a bridge: the road-on-water tiles keep their own ground.
	for i in ctx.sim.active:
		if ctx.sim.terrain[i] == D.WATER and ctx.sim.kind[i] == D.ROAD:
			var c := Vector3(D.tx(i), 0.0, D.ty(i))
			K.check(fails, col.water_depth(c) == 0.0, "no wading depth under a bridge tile")
			K.check(
				fails,
				is_nan(col.wade_height(c, WS.WADE_MAX)),
				"wade_height is NAN under a bridge tile"
			)
			break
	# Animals, walkers and cars are the other callers of the default arguments: a signature check.
	for fn: String in [
		"walk_height",
		"support_height",
		"move_body",
		"is_blocked",
		"body_blocked",
		"nearest_free",
		"resolve_out",
		"soft_people_move"
	]:
		var want := 0.0
		for m: Dictionary in col.get_method_list():
			if str(m["name"]) == fn:
				var defs: Array = m["default_args"]
				want = float(defs[defs.size() - 1]) if not defs.is_empty() else -1.0
		K.check(fails, want == 0.0, "%s's wade_max defaults to 0 (water a wall)" % fn)


## unstick_player (fp_mode, health, police) leaves a wading hero where they stand, and still moves
## one with the flag off.
func _check_unstick(ctx: FpContext, bank: Dictionary) -> void:
	var p := _stand(ctx, bank)
	var col := ctx.collision
	var dir: Vector2i = bank["dir"]
	var lt: Vector2i = bank["land"]
	# Standing at 0.5 m of water, found on the ramp.
	var pos := Vector3.ZERO
	for k in range(0, 400):
		var q := (
			Vector3(lt.x, 0.0, lt.y) + Vector3(dir.x, 0.0, dir.y) * (0.5 + 0.2 * float(k) / 400.0)
		)
		if col.water_depth(q) >= 0.5 * M:
			pos = q
			break
	pos.y = col.walk_height(pos, WS.WADE_MAX)
	p.teleport(pos, float(bank["yaw"]), 0.0, false)
	var before := p.position
	var moved: bool = ctx.mode.unstick_player()
	K.check(
		fails, not moved and p.position == before, "unstick_player leaves a wading hero in place"
	)
	p.wade_on = false
	moved = ctx.mode.unstick_player()
	K.check(
		fails,
		moved and col.water_depth(p.position) == 0.0,
		"with hero_wade off it still moves the hero out of the water"
	)
	p.wade_on = true


## Flag off: the river is the wall it was.
func _check_flag_off(ctx: FpContext, bank: Dictionary) -> void:
	var p := _stand(ctx, bank)
	p.wade_on = false
	K.check(fails, p.wade_limit() == 0.0, "flag off: no wade limit")
	var deepest := 0.0
	var wet_nan := false
	for k in range(600):
		p.simulate(Vector2(0, 1), true, DT)
		deepest = maxf(deepest, ctx.collision.water_depth(p.position))
		wet_nan = wet_nan or is_nan(ctx.collision.ground_height(p.position))
	K.check(
		fails,
		deepest == 0.0 and not wet_nan,
		"flag off: the hero stops at the bank, never over water"
	)
	p.wade_on = true
	K.check(fails, p.wade_limit() == WS.WADE_MAX, "flag on: WADE_MAX")
	K.check(fails, FeatureFlags.enabled("hero_wade"), "the hero_wade flag ships on")


## Walking on into water past the limit says so once.
func _check_toast(ctx: FpContext, bank: Dictionary) -> void:
	var p := _stand(ctx, bank)
	var got: Array[String] = []
	var cb := func(text: String, _kind: String) -> void: got.append(text)
	ctx.bus.toast.connect(cb)
	for k in range(1200):
		p.simulate(Vector2(0, 1), false, DT)
	ctx.bus.toast.disconnect(cb)
	K.check(
		fails,
		got.count(WADE.TOO_DEEP_TEXT) == 1,
		"a 'Too deep to wade' notice shows once (%d)" % got.count(WADE.TOO_DEEP_TEXT)
	)


## The water mesh carries the current, and the ripples rotate through four slots.
func _check_surface(ctx: FpContext) -> void:
	var sim := ctx.sim
	var tile := Vector2i(-999, -999)
	for i in sim.active:
		if sim.terrain[i] == D.WATER and sim.kind[i] != D.ROAD:
			var x := D.tx(i)
			var y := D.ty(i)
			var ew := int(RB.is_water_at(sim, x - 1, y)) + int(RB.is_water_at(sim, x + 1, y))
			var ns := int(RB.is_water_at(sim, x, y - 1)) + int(RB.is_water_at(sim, x, y + 1))
			if ew == 2 and ns == 0:
				tile = Vector2i(x, y)
				break
	if tile.x != -999:
		K.check(
			fails,
			WATER.tile_flow(sim, tile.x, tile.y) == Vector2(1.0, 0.0),
			"a river running east-west flows along +x"
		)
	K.check(fails, WATER.tile_flow(sim, -9999, -9999) == Vector2.ZERO, "no current on land")
	var mesh := WATER.mesh(sim, WS.WATER_Y)
	var arrays := mesh.surface_get_arrays(0)
	K.check(
		fails,
		(
			(arrays[Mesh.ARRAY_COLOR] as PackedColorArray).size()
			== (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		),
		"every water vertex carries the current"
	)
	var r := WATER.Ripples.new()
	K.check(fails, not r.alive(), "no ripples at first")
	for k in range(6):
		r.add(float(k), 0.0, 1.0)
	var live := 0
	for s: Vector4 in r.slots:
		live += int(s.z >= 0.0)
	K.check(
		fails,
		live == WATER.SLOTS,
		"six rings in four slots: the oldest are replaced (%d alive)" % live
	)
	K.check(fails, r.tick(WATER.LIFE * 0.5) and r.alive(), "rings live on while young")
	K.check(fails, not r.tick(WATER.LIFE), "and free their slots once old")


## The view: the water material is told which renderer draws it (the web's depth read is the
## Compatibility formula), flood planes use it, and a ripple lights the shader and then goes dark.
func _check_view(ctx: FpContext) -> void:
	var view: CityView = ctx.view
	var mat: ShaderMaterial = view._water_mat
	K.check(fails, mat != null, "the water has its shader material")
	if mat == null:
		return
	var compat := RenderingServer.get_current_rendering_method() == "gl_compatibility"
	K.check(
		fails,
		bool(mat.get_shader_parameter("compat")) == compat,
		"the water material's compat flag matches the renderer (%s)" % compat
	)
	# Headless is the dummy renderer, so the real decision is tested through the override: the
	# web build's method turns the Compatibility depth read on, the desktop ones leave it off.
	for pair: Array in [["gl_compatibility", true], ["forward_plus", false], ["mobile", false]]:
		view.render_method_override = pair[0]
		var m: ShaderMaterial = view._new_water_material()
		K.check(
			fails,
			m != null and bool(m.get_shader_parameter("compat")) == bool(pair[1]),
			"a %s renderer builds the water with compat %s" % [pair[0], pair[1]]
		)
	view.render_method_override = ""
	K.check(
		fails,
		mat.shader.code.contains("compat ? vec3(SCREEN_UV, z)"),
		"the shader unprojects with the Compatibility depth formula"
	)
	K.check(fails, not view.water_rippling(), "a still river has no ripple")
	view.water_ripple(Vector3(1, 0, 1), 0.8)
	view._tick_ripples(0.1)
	K.check(
		fails,
		view.water_rippling() and float(mat.get_shader_parameter("ripple_on")) > 0.5,
		"a ripple lights the shader"
	)
	view._tick_ripples(WATER.LIFE + 0.1)
	K.check(
		fails,
		not view.water_rippling() and float(mat.get_shader_parameter("ripple_on")) < 0.5,
		"and the shader goes dark when it dies"
	)


## The land tiles touching water, counted straight from the terrain; checks the mask against it.
func _count_shore_tiles(sim: CitySim, mask: PackedByteArray) -> int:
	var wet_n := 0
	var bad_mask := 0
	for i in range(D.W * D.H):
		var touches := false
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if (dx != 0 or dy != 0) and RB.is_water_at(sim, D.tx(i) + dx, D.ty(i) + dy):
					touches = true
		var want := touches and sim.terrain[i] != D.WATER
		wet_n += int(want)
		if (mask[i] == 1) != want:
			bad_mask += 1
	K.check(
		fails,
		wet_n > 20 and bad_mask == 0,
		(
			"the shore mask marks exactly the %d land tiles touching water (%d wrong)"
			% [wet_n, bad_mask]
		)
	)
	return wet_n


## The shore band: only land tiles touching water are meshed finer, their vertices carry the sand
## and wet numbers (alpha 0.5 marks them), the waterline is full sand and wet, and the bed's
## vertices carry the same from their height.
func _check_shore(ctx: FpContext) -> void:
	var view: CityView = ctx.view
	var sim := ctx.sim
	var mask := SHORE.mask(sim)
	var wet_n := _count_shore_tiles(sim, mask)
	var shore_tris := 0
	var plain_tris := 0
	var marker_wrong := 0
	var code_wrong := 0
	for g: MeshInstance3D in view._ground_chunks:
		var arrays := (g.mesh as ArrayMesh).surface_get_arrays(0)
		var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var cs: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		K.check(fails, cs.size() == vs.size(), "every ground vertex carries a colour")
		for t in range(0, vs.size() - 2, 3):
			var c := (vs[t] + vs[t + 1] + vs[t + 2]) / 3.0
			var x := roundi(c.x)
			var y := roundi(c.z)
			var in_mask := D.in_bounds(x, y) and mask[D.idx(x, y)] == 1
			var marked := absf(cs[t].a - SHORE.TILE_MARK) < 0.02
			if in_mask != marked:
				marker_wrong += 1
			if marked:
				shore_tris += 1
				if SHORE.decode(cs[t]) != SHORE.water_flags(sim, x, y):
					code_wrong += 1
			else:
				plain_tris += 1
	K.check(
		fails,
		shore_tris == 2 * wet_n and plain_tris > 20,
		(
			"ground: a quad per shore tile (%d triangles for %d tiles), %d plain"
			% [shore_tris, wet_n, plain_tris]
		)
	)
	K.check(
		fails,
		marker_wrong == 0,
		"only shore tiles carry the marker (%d wrong triangles)" % marker_wrong
	)
	K.check(
		fails,
		code_wrong == 0,
		"every shore tile's colour codes its water neighbours (%d wrong)" % code_wrong
	)
	var all8: Array[bool] = [true, false, true, true, false, true, true, false]
	K.check(
		fails,
		(
			SHORE.decode(SHORE.encode(all8)) == all8
			and (
				SHORE.decode(SHORE.encode([false, false, false, false, false, false, false, false]))
				== [false, false, false, false, false, false, false, false]
			)
		),
		"the neighbour code round-trips"
	)
	var edge := SHORE.band(0.0)
	var far := SHORE.band(SHORE.SHORE_W)
	K.check(
		fails,
		(
			edge.x > 0.999
			and edge.y > 0.999
			and far.x < 0.001
			and far.y < 0.001
			and SHORE.band(SHORE.WET_W).y < 0.001
			and SHORE.band(SHORE.WET_W).x > 0.3
		),
		"the band is full sand and wet at the waterline, wet ends a third of the way"
	)
	var bed: PackedColorArray = (view._bed_node.mesh as ArrayMesh).surface_get_arrays(0)[
		Mesh.ARRAY_COLOR
	]
	K.check(
		fails,
		bed.size() > 0 and absf(bed[0].a - SHORE.BED_MARK) < 0.02,
		"the bed carries the band marker"
	)
	var top := SHORE.bed_color(WS.GROUND_Y)
	var at_water := SHORE.bed_color(WS.WATER_Y)
	var deep := SHORE.bed_color(WS.RIVERBED_Y)
	K.check(fails, top.r > 0.99 and top.g < 0.01, "the bank's top is dry sand")
	K.check(fails, at_water.g > 0.99 and at_water.r > 0.99, "the waterline is wet sand")
	K.check(fails, deep.r < 0.3 and deep.g > 0.99, "the deep bed is silt, wet")
	var src: String = (load("res://shaders/ground_detail.gdshader") as Shader).code
	K.check(
		fails,
		src.contains("abs(shore_v.a - 0.5) < 0.05") and src.contains("shore.x > 0.004"),
		"the ground shader reads the shore marker"
	)


## The wade feature: a footfall in the water rings the surface, one on land does not.
func _check_feature(ctx: FpContext, bank: Dictionary) -> void:
	var f := K.make_feature(ctx, "hero_wade") as FpFeature
	K.check(
		fails, f != null and f.get_script() == WADE_FEATURE, "the hero_wade feature is registered"
	)
	if f == null:
		return
	var p := _stand(ctx, bank)
	var view: CityView = ctx.view
	var land := Vector3(bank["land"].x, 0.0, bank["land"].y)
	p.emit_signal("stepped", "grass", land)
	K.check(
		fails,
		not view.water_rippling() and int(f.get("rings")) == 0,
		"a step on grass rings nothing"
	)
	var lt: Vector2i = bank["land"]
	var dir: Vector2i = bank["dir"]
	var wet := Vector3(lt.x, 0.0, lt.y) + Vector3(dir.x, 0.0, dir.y) * 0.62
	p.emit_signal("stepped", "water", wet)
	K.check(
		fails,
		int(f.get("rings")) == 1 and view.water_rippling(),
		"a step in the water rings the surface"
	)
	var dry := Vector3(lt.x, 0.0, lt.y) + Vector3(dir.x, 0.0, dir.y) * 0.505
	var n := int(f.get("rings"))
	p.emit_signal("stepped", "water", dry)
	K.check(fails, int(f.get("rings")) == n, "a step on the bank's dry shelf does not")
	f.teardown()
	p.emit_signal("stepped", "water", wet)
	K.check(fails, int(f.get("rings")) == n, "after teardown the feature is deaf")


## A boat in the shallows is solid to the wading hero (boat_boxes_near is what FpPlayer's traffic
## poll adds to the dynamic boxes): he stops at the hull instead of walking through it.
func _check_boats(ctx: FpContext, bank: Dictionary) -> void:
	var life: CityLife = ctx.view.life
	K.check(fails, life != null and life.boat_count() > 0, "fixture: the city has boats")
	if life == null or life.boat_count() == 0:
		return
	var col := ctx.collision
	var node: Node3D = life._boats[0]["node"]
	var lt: Vector2i = bank["land"]
	var dir: Vector2i = bank["dir"]
	var d3 := Vector3(dir.x, 0.0, dir.y)
	var home := node.global_position
	var rot := node.rotation
	node.rotation = Vector3.ZERO
	node.global_position = Vector3(lt.x, WS.WATER_Y, lt.y) + d3 * 0.75
	var boxes := life.boat_boxes_near(node.global_position, 0.6)
	K.check(
		fails,
		boxes.size() >= 1 and boxes[0].size.x > 0.05 and boxes[0].size.z > 0.2,
		"the boat's hull is a box (%s)" % str(boxes[0].size if not boxes.is_empty() else "none")
	)
	K.check(
		fails,
		(
			life.boat_boxes_near(node.global_position + Vector3(5.0, 0.0, 5.0), 0.6).is_empty()
			or life.boat_count() > 1
		),
		"boats beyond the reach are left out"
	)
	var p := _stand(ctx, bank)
	K.check(fails, p._boat_boxes().size() == boxes.size(), "the player asks CityLife for the boats")
	p.wade_on = false
	K.check(fails, p._boat_boxes().is_empty(), "and not with hero_wade off")
	p.wade_on = true
	col.dynamic_boxes = boxes
	var box := boxes[0]
	for k in range(900):
		p.simulate(Vector2(0, 1), false, DT)
	col.dynamic_boxes = []
	var pos := p.position
	var inside := (
		pos.x > box.position.x
		and pos.x < box.end.x
		and pos.z > box.position.z
		and pos.z < box.end.z
	)
	K.check(fails, not inside, "the wader stops at the hull, not inside it")
	node.global_position = home
	node.rotation = rot


## A hero wading to the limit and knocked down (down_view) keeps the first-person eye above the
## water surface: the plane is drawn from above only, so an eye under it would see no river. Dry
## ground leaves the knocked-down eye where it was.
func _check_eye(ctx: FpContext, bank: Dictionary) -> void:
	var p := _stand(ctx, bank)
	for k in range(900):
		p.simulate(Vector2(0, 1), false, DT)
	K.check(
		fails,
		p.wade_depth > 0.7 * WS.WADE_MAX,
		"fixture: at the limit (%.2f m)" % (p.wade_depth / M)
	)
	var was := p.down_w
	p.down_w = 1.0
	var eye_y := (p.position + p._fp_local().origin).y
	K.check(
		fails,
		eye_y >= WS.WATER_Y + WADE.EYE_CLEAR - 1e-5,
		(
			"a knocked-down wader's eye stays above the surface (%.2f m, surface %.2f m)"
			% [eye_y / M, WS.WATER_Y / M]
		)
	)
	p.crouched = true
	p.down_w = 0.0
	eye_y = (p.position + p._fp_local().origin).y
	K.check(
		fails,
		eye_y > WS.WATER_Y,
		"a crouched wader's eye is above the surface too (%.2f m)" % (eye_y / M)
	)
	p.crouched = false
	# On dry ground the clamp is out of the way: the down eye is DOWN_EYE over the feet.
	p.teleport(bank["start"], float(bank["yaw"]))
	p.wade_depth = 0.0
	p.down_w = 1.0
	K.check(
		fails,
		is_equal_approx(p._fp_local().origin.y, FpPlayer.DOWN_EYE),
		"on dry ground the knocked-down eye is unchanged"
	)
	p.down_w = was
	K.check(fails, WADE.eye_floor(0.0, 0.0) == -INF, "no depth, no floor")


## The poll that hands traffic blockers to the collision also hands it the boats' hull boxes, so a
## hero wading into a boat is stopped by it (the hook, not just the boxes).
func _check_boat_poll(ctx: FpContext, bank: Dictionary) -> void:
	var life: CityLife = ctx.view.life
	if life == null or life.boat_count() == 0:
		return
	var node: Node3D = life._boats[0]["node"]
	var home := node.global_position
	var rot := node.rotation
	node.rotation = Vector3.ZERO
	var lt: Vector2i = bank["land"]
	var dir: Vector2i = bank["dir"]
	node.global_position = Vector3(lt.x, WS.WATER_Y, lt.y) + Vector3(dir.x, 0.0, dir.y) * 0.75
	var p := _stand(ctx, bank)
	var traffic := FakeTraffic.new()
	ctx.features["traffic"] = traffic
	ctx.collision.dynamic_boxes = []
	p._traffic_t = 0.0
	p._poll_traffic(DT)
	K.check(
		fails,
		not ctx.collision.dynamic_boxes.is_empty(),
		"the poll puts the boats' hulls into the collision"
	)
	p.wade_on = false
	ctx.collision.dynamic_boxes = []
	p._traffic_t = 0.0
	p._poll_traffic(DT)
	K.check(fails, ctx.collision.dynamic_boxes.is_empty(), "and leaves them out with hero_wade off")
	p.wade_on = true
	ctx.features.erase("traffic")
	traffic.free()
	ctx.collision.dynamic_boxes = []
	node.global_position = home
	node.rotation = rot
