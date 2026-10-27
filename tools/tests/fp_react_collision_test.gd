extends SceneTree
## Knocked down or thrown, nobody ends up inside a wall, a car or a prop (collision rigidity):
## every path that moves a body -- a blow's knock-down flight and skid, a car's throw, the
## trample it gives a body already lying there, the get-up and the walk back -- is stepped to
## its end while the drawn body (its feet, its torso point and its posed head bone) is measured
## against the same boxes and cylinders the mover itself uses. A clip sweeps the posed body
## faster than one tick's press-out can follow, so the claim is what the item asks: upright or
## at rest the body never overlaps geometry at all, and any overlap a sweep drives it into
## eases out within CLEAR_S -- nothing sticks, and it walks away clear. Third person on a grown
## city; traffic's step and sync_visuals run the street.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const OBB := preload("res://scripts/fp/obb2d.gd")
const DT := 1.0 / 60.0
## The body is measured the way the mover moves it: a capsule of BODY_R at the drawn feet
## (reactions.gd), plus the torso point and the posed head bone (people.gd head_of) -- a clip
## that lies the body down puts the head a metre and a half from the feet, so the feet alone
## are not the body.
const BODY_R := 0.25 * WS.M
const HEAD_R := 0.14 * WS.M
## A blow this strong knocks down, and each scenario runs to the reaction's end by this cap.
const STRENGTH := 0.95
const REACT_S := 10.0
## How deep anything may press (5 mm: touching is fine, inside is not).
const TOL := 0.005 * WS.M
## A sweep may drive the body into geometry for this long before it counts as stuck (s); the
## press-out clears a real overlap within a couple of ticks.
const CLEAR_S := 0.25
## Cruise for the moving-car scenarios: 30 km/h, the round-3 measurement speed.
const CRUISE := 8.3 * WS.M
## The block system's designed stop margin (vehicles.gd's MIN_GAP + PLAYER_RADIUS): measured
## stops land metres beyond it -- a floor, not a fit.
const STOP_FLOOR := 0.8 * WS.M

var fails: Array[String] = []
var ctx: FpContext
var tr: FpFeature
var react: RefCounted
var pe: Object
var wk: WK
## Steps every scenario has watched (a monotonic clock for the overlap spans).
var _clock := 0.0
## label -> [deepest depth (u), where (Vector3), what, state, react, t]: the deepest while
## upright (strictly clear) and the deepest anywhere (a sweep, informational).
var _worst_up: Dictionary = {}
var _worst_any: Dictionary = {}
## label -> the >TOL span now open (a step, or -1) and the longest closed one (s).
var _span_open: Dictionary = {}
var _span_max: Dictionary = {}
## label -> the last sample's depth (the end state).
var _last_d: Dictionary = {}
## Bodies seen drawing this scenario (sanity: the head bone was the posed one, not the estimate).
var _posed_heads := 0
## The scenario's real traffic car body, when it has one: the drawn body is measured against it
## too (a moving body the static world the rest of the measurement reads does not hold).
var _car_body = null


func _init() -> void:
	await process_frame
	FeatureFlags.set_override("hit_feel", true)
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "third"})
	ctx.player.set_process(false)
	ctx.view.set_fp_mode(true)
	if ctx.view.has_method("flush_rebuild_queue"):
		ctx.view.call("flush_rebuild_queue")
	ctx.collision.rebuild_all()
	tr = K.make_feature(ctx, "traffic")
	if tr == null:
		K.check(fails, false, "fixture: the traffic feature exists")
		K.finish(self, "FP_REACT_COLLISION_TEST", fails)
		return
	tr.set("auto_step", false)
	tr.set("ambient_enabled", false)
	react = tr.get("reactions")
	pe = tr.get("people")
	wk = tr.get("walkers")
	K.check(
		fails,
		(react.get("body_extent") as Callable).is_valid(),
		"fixture: the posed-body extent is wired into reactions"
	)
	var walk := K.sidewalk(ctx, 6.0 * WS.M)
	K.check(fails, not walk.is_empty(), "fixture: a clear run of sidewalk")
	if not walk.is_empty():
		var run: Vector3 = walk["run"]
		var at: Vector3 = walk["pos"] + run * (2.5 * WS.M)
		print("  fixture: victims at %s, run %s" % [at, run])
		_check_throw_into_wall(at, run)
		_check_throw_into_car(at, run)
		_check_throw_into_post(at, run)
		_check_shove_close_wall(at, run)
		_check_trample_along_wall(at, run)
		_check_throw_into_real_car(at, run)
		K.check(
			fails,
			_posed_heads > 0,
			"fixture: the heads measured were the posed bones (%d)" % _posed_heads
		)
	_check_car_brakes_with_room()
	_check_car_brakes_point_blank()
	_check_throw_across_approaching_car()
	_check_car_brakes_on_the_bend()
	_check_roof_press_boundary()
	Engine.time_scale = 1.0
	K.finish(self, "FP_REACT_COLLISION_TEST", fails)


# ------------------------------------------------------------------ geometry


## A box wall metres along run from feet: faces width 3 m, height 3 m, thickness 0.2 m.
func _wall(feet: Vector3, run: Vector3, metres: float) -> AABB:
	var across := Vector3(absf(run.z), 0.0, absf(run.x))
	var c := feet + run * (metres * WS.M) + Vector3.UP * (1.5 * WS.M)
	var size := across * (3.0 * WS.M) + run.abs() * (0.2 * WS.M)
	size.y = 3.0 * WS.M
	return AABB(c - size * 0.5, size)


## A parked-car-shaped box with its near face metres along run from feet: 4.5 m long, 1.8 m
## wide, 1.45 m tall.
func _car(feet: Vector3, run: Vector3, metres: float) -> AABB:
	var across := Vector3(absf(run.z), 0.0, absf(run.x))
	var c := feet + run * ((metres + 2.25) * WS.M) + Vector3.UP * (0.725 * WS.M)
	var size := run.abs() * (4.5 * WS.M) + across * (1.8 * WS.M)
	size.y = 1.45 * WS.M
	return AABB(c - size * 0.5, size)


## A lamp-post-shaped box metres along run from feet: 0.2 m square, 4 m tall.
func _post(feet: Vector3, run: Vector3, metres: float) -> AABB:
	var c := feet + run * (metres * WS.M) + Vector3.UP * (2.0 * WS.M)
	var size := Vector3(0.2, 4.0, 0.2) * WS.M
	return AABB(c - size * 0.5, size)


# ------------------------------------------------------------------ scenarios


## Hits w with cause along dir (src behind them, push along dir) with a fling in metres
## (reactions.hit takes metres: a 2.5 sends the body 2.5 m along the run), samples the drawn
## body to the reaction's end, and returns hit()'s dict with "travel" added: the farthest the
## body got along dir while down (the flight and the skid; the walk after get-up is not a
## throw). The hero watches 2.5 m back, so the body draws and its head is the posed bone.
func _hit_and_watch(
	label: String, w: WK.Walker, feet: Vector3, dir: Vector3, cause: String, fling_m: float
) -> Dictionary:
	var hero := feet - dir * (2.5 * WS.M)
	ctx.player.teleport(hero, rad_to_deg(atan2(dir.x, dir.z)))
	ctx.player.input_enabled = false
	tr.call("sync_visuals", DT)
	var src := feet - dir * (1.2 * WS.M)
	src.y = feet.y
	_reset(label)
	var ret: Dictionary = react.call("hit", w, src, dir * WS.M, STRENGTH, cause, fling_m)
	var t := 0.0
	var ticks := 0
	var far := 0.0
	while t < REACT_S:
		tr.call("step", DT)
		tr.call("sync_visuals", DT)
		t += DT
		ticks += 1
		_clock += DT
		if bool(react.call("is_down", w)):
			far = maxf(far, (w.pos + w.vis_off - feet).dot(dir))
		if int(t / DT) % 2 == 0:
			_sample_body(label, w)
	ret["travel"] = far
	return ret


## The throw claims with teeth: while down, the body really travelled the metres the fling
## promises -- a fling passed in the wrong scale (12 cm instead of 2.5 m) stops short of every
## obstacle and fails here.
func _reached(label: String, ret: Dictionary, floor_m: float) -> void:
	var far := float(ret.get("travel", 0.0))
	print("  travel: %s %.2f m" % [label, far / WS.M])
	K.check(
		fails,
		far >= floor_m * WS.M,
		"%s: the throw carried %.2f m (floor %.2f m)" % [label, far / WS.M, floor_m]
	)


## A punch knocks them down, the throw flies them into a wall 1.2 m along the run.
func _check_throw_into_wall(at: Vector3, run: Vector3) -> void:
	var label := "a thrown body comes to rest against a wall"
	ctx.collision.add_test_box(_wall(at, run, 1.2))
	var w := _victim(at, run)
	var ret := _hit_and_watch(label, w, at, run, "punch", 2.5)
	K.check(fails, bool(ret.get("down", false)), "fixture: the punch knocks them down")
	_reached(label, ret, 0.35)
	_report(label)
	wk.remove(w)
	ctx.collision.clear_test_boxes()


## A car runs them down, the throw flies them into a car-shaped box 1.5 m along the run.
func _check_throw_into_car(at: Vector3, run: Vector3) -> void:
	ctx.collision.add_test_box(_car(at, run, 1.5))
	var w := _victim(at, run)
	var ret := _hit_and_watch("a body thrown at a car lands clear of it", w, at, run, "car", 2.5)
	K.check(fails, bool(ret.get("down", false)), "fixture: the car knocks them down")
	_reached("a body thrown at a car lands clear of it", ret, 0.6)
	_report("a body thrown at a car lands clear of it")
	wk.remove(w)
	ctx.collision.clear_test_boxes()


## A punch throws them at a lamp-post-shaped box 1.1 m along the run.
func _check_throw_into_post(at: Vector3, run: Vector3) -> void:
	ctx.collision.add_test_box(_post(at, run, 1.1))
	var w := _victim(at, run)
	var ret := _hit_and_watch("a body thrown at a post lands clear of it", w, at, run, "punch", 2.5)
	K.check(fails, bool(ret.get("down", false)), "fixture: the punch knocks them down")
	_reached("a body thrown at a post lands clear of it", ret, 0.25)
	_report("a body thrown at a post lands clear of it")
	wk.remove(w)
	ctx.collision.clear_test_boxes()


## A shove 0.4 m from a wall: even a short knock-down slide has to stop clear of it.
func _check_shove_close_wall(at: Vector3, run: Vector3) -> void:
	var label := "a body knocked down beside a wall stays clear of it"
	ctx.collision.add_test_box(_wall(at, run, 0.4))
	var w := _victim(at, run)
	var ret := _hit_and_watch(label, w, at, run, "shove", 0.0)
	K.check(fails, bool(ret.get("down", false)), "fixture: the shove knocks them down")
	_report(label)
	wk.remove(w)
	ctx.collision.clear_test_boxes()


## Knocked down beside a wall, then a car runs over where they lie: the trample slide along the
## wall has to stay clear of it.
func _check_trample_along_wall(at: Vector3, run: Vector3) -> void:
	var label := "a body trampled along a wall stays clear of it"

	ctx.collision.add_test_box(_wall(at, run, 0.4))
	var w := _victim(at, run)
	var ret := _hit_and_watch(label, w, at, run, "shove", 0.0)
	K.check(fails, bool(ret.get("down", false)), "fixture: the shove knocks them down")
	# Wait out the fall, then trample them along the wall twice.
	var t := 0.0
	while t < 1.5 and bool(react.call("is_down", w)):
		tr.call("step", DT)
		tr.call("sync_visuals", DT)
		t += DT
		_clock += DT
	var across := Vector3(absf(run.z), 0.0, absf(run.x))
	var trampled := 0
	for _k in 2:
		var feet: Vector3 = w.pos + w.vis_off
		var src := feet - across * (2.0 * WS.M)
		src.y = feet.y
		if not (react.call("hit", w, src, across * WS.M, 0.6, "car", 0.0) as Dictionary).is_empty():
			trampled += 1
		var s := 0.0
		while s < 1.6:
			tr.call("step", DT)
			tr.call("sync_visuals", DT)
			s += DT
			_clock += DT
			if int(s / DT) % 2 == 0:
				_sample_body(label, w)
	K.check(fails, trampled == 2, "fixture: the car tramples them twice (%d)" % trampled)
	_report(label)
	wk.remove(w)
	ctx.collision.clear_test_boxes()


## A car runs them down into a REAL parked traffic car: the throw lands the body in the parked
## car's footprint, and no hit can reach it once it is in the air -- only the press-out can ease
## the drawn body clear, and that reads only the static world unless the near car bodies are
## handed to it (reactions.cars_near -> body_spheres.press_out). The car keeps its own lane
## state (its follower would otherwise drag it back mid-scenario); the victim stands on the
## road 3 m behind its centre and the throw flies them into its body.
func _check_throw_into_real_car(_at: Vector3, _run: Vector3) -> void:
	var label := "a body thrown into a real car comes to rest clear of it"
	var setup = _real_car()
	K.check(fails, setup != null, "fixture: a real traffic car body on a lane")
	if setup == null:
		return
	var c = setup["car"]
	var head: Vector3 = setup["head"]
	_car_body = c
	var victim_at: Vector3 = c.pos - head * (3.0 * WS.M)
	var w := _victim(victim_at, head)
	var ret := _hit_and_watch(label, w, victim_at, head, "car", 2.5)
	K.check(fails, bool(ret.get("down", false)), "fixture: the car knocks them down")
	_reached(label, ret, 0.3)
	_report(label)
	wk.remove(w)
	_car_body = null
	(tr.get("vehicles") as Object).remove(c)


## A real traffic car body standing on a lane of the first road that has one, as
## {"car", "head" (the lane's heading)}; null without one. It keeps its lane state: an ambient
## car at rest does not drive off.
func _real_car():
	var vh = tr.get("vehicles")
	for old in vh.cars.duplicate():
		vh.remove(old)
	var lanes_mod = tr.get("lanes")
	for i: int in ctx.sim.active:
		if ctx.sim.kind[i] != D.ROAD:
			continue
		var tiles: Array[int] = [i]
		var lanes: Array = lanes_mod.lanes_along(tiles)
		if lanes.is_empty():
			continue
		var m: int = tr.call("car_model_for", "react-collision-test")
		var c = vh.make("car", "ambient", tr.call("dims", m))
		c.model = m
		vh.place(c, lanes[0], 0.5)
		var h := OBB.heading(c.yaw)
		return {"car": c, "head": Vector3(h.x, 0.0, h.y)}
	return null


# ------------------------------------------------------------------ moving cars

## The moving-car contract (round 4): an ambient car has no strike path at all -- the
## block/brake/clamp system owns every approach. A downed or thrown body is a lane block from
## the hit's first tick, mid-air included (reactions.blocks reads the drawn feet, xz only), so
## the car brakes under IDM and the movement clamp holds it off even when it could never stop
## in time. The press-out owns only a body already inside a stopped car (the parked scenario
## above), and past the roof's height span it does not read the body at all.


## A run of same-mask straight road tiles, at least two long: [tiles in order, heading
## edge]. The moving-car scenarios need one straight with room ahead of the car, not the
## longest one, so this takes the first run that extends past its start tile.
func _straight_run() -> Array:
	var lg: LG = tr.get("lanes")
	for i: int in lg.tiles.keys():
		var t = lg.tiles[i]
		if t.piece != "straight" or t.bridge:
			continue
		for e in range(4):
			if not (t.mask & (1 << e)):
				continue
			var tiles: Array[int] = [i]
			var nx: int = lg.across(i, e)
			while (
				nx >= 0
				and lg.info(nx) != null
				and (lg.info(nx) as LG.TileInfo).piece == "straight"
				and (lg.info(nx) as LG.TileInfo).mask == t.mask
			):
				tiles.append(nx)
				nx = lg.across(nx, e)
			if tiles.size() >= 2:
				return [tiles, e]
	return [[], 0]


## The straight run's lanes in the heading direction; empty without one.
func _run_lanes() -> Array:
	var run := _straight_run()
	var tiles: Array = run[0]
	if tiles.size() < 2:
		return []
	var lg: LG = tr.get("lanes")
	return lg.lanes_along(tiles, LG.OPP[int(run[1])], int(run[1]))


## A test car on lane at s with path ahead of it, already rolling at v: "test" cars keep no
## schedule, they just drive their path under IDM.
func _lane_car(lane: LG.Lane, s: float, path: Array, v: float):
	var vh = tr.get("vehicles")
	var m: int = tr.call("car_model_for", "react-collision-moving")
	var c = vh.make("car", "test", tr.call("dims", m))
	c.model = m
	vh.place(c, lane, s)
	c.path = path.duplicate()
	c.v = v
	c.v0 = v
	return c


## A victim knocked down on lane at s by a car-cause blow along it (a small 0.4 m fling: they
## fall where they stood) and left to settle into the lie. The scenario starts after this.
func _down_on_lane(lane: LG.Lane, s: float) -> WK.Walker:
	var lg: LG = tr.get("lanes")
	var p: Vector2 = lg.pos_at(lane, s)
	var tan: Vector2 = lg.tan_at(lane, s)
	var dir := Vector3(tan.x, 0.0, tan.y)
	var at := Vector3(p.x, WS.GROUND_Y, p.y)
	var w := _victim(at, dir)
	react.call("hit", w, at - dir * WS.M, dir * WS.M, STRENGTH, "car", 0.4)
	for _k in range(90):
		tr.call("step", DT)
		_clock += DT
	return w


## Distance of the car's AABB from the body's drawn feet (0 when the feet are inside it).
func _car_gap(c, w: WK.Walker) -> float:
	var vh = tr.get("vehicles")
	var bb: AABB = vh.aabb(c)
	var p: Vector3 = w.pos + w.vis_off
	var q := Vector3(
		clampf(p.x, bb.position.x, bb.end.x),
		clampf(p.y, bb.position.y, bb.end.y),
		clampf(p.z, bb.position.z, bb.end.z)
	)
	return p.distance_to(q)


## The hero watches from five metres to the body's side: close enough that the body draws its
## posed bones, off the lane so the watching hero is not himself a block on the car's path.
func _watch_from(feet: Vector3, tan: Vector2) -> void:
	var side := Vector3(tan.y, 0.0, -tan.x)
	ctx.player.teleport(feet + side * (5.0 * WS.M), rad_to_deg(atan2(-side.x, -side.z)))
	ctx.player.input_enabled = false
	tr.call("sync_visuals", DT)


## Closes a moving-car scenario: the standard overlap report, then the car and the victim
## leave the stage.
func _finish_moving(label: String, c, w: WK.Walker) -> void:
	_report(label)
	wk.remove(w)
	(tr.get("vehicles") as Object).remove(c)
	_car_body = null


## A downed body twenty metres ahead of a 30 km/h car, room to spare: the brake owns it. The
## car eases to a stop well short, never touches the body, and holds while the reaction runs.
func _check_car_brakes_with_room() -> void:
	var label := "a car with room brakes short of a body on its lane"
	var lanes := _run_lanes()
	K.check(fails, lanes.size() >= 2, "fixture: a straight lane run for the moving cars")
	if lanes.size() < 2:
		return
	var lg: LG = tr.get("lanes")
	var w := _down_on_lane(lanes[0], 0.7)
	K.check(fails, bool(react.call("is_down", w)), "fixture: the victim lies on the lane")
	var c = _lane_car(lanes[0], 0.3, lanes.slice(1), CRUISE)
	_car_body = c
	_watch_from(w.pos + w.vis_off, lg.tan_at(lanes[0], 0.7))
	_reset(label)
	var min_d := INF
	var stop_t := -1.0
	var creep := 0.0
	var t := 0.0
	while t < 8.0:
		tr.call("step", DT)
		tr.call("sync_visuals", DT)
		t += DT
		_clock += DT
		min_d = minf(min_d, _car_gap(c, w))
		if stop_t < 0.0 and c.v < 0.05 * WS.M:
			stop_t = t
		elif stop_t >= 0.0:
			creep = maxf(creep, c.v)
		if int(t / DT) % 2 == 0:
			_sample_body(label, w)
	K.check(fails, stop_t > 0.0, "%s: the car stopped (at %.2f s)" % [label, stop_t])
	K.check(
		fails,
		creep < 0.05 * WS.M,
		"%s: once stopped it never crept (max %.2f m/s)" % [label, creep / WS.M]
	)
	print("  stop gap: %s %.2f m" % [label, min_d / WS.M])
	K.check(
		fails,
		min_d >= STOP_FLOOR,
		(
			"%s: it stopped %.2f m from the body (floor %.2f m)"
			% [label, min_d / WS.M, STOP_FLOOR / WS.M]
		)
	)
	_finish_moving(label, c, w)


## The un-stoppable case: a body three metres ahead of a 30 km/h car cannot be braked for (the
## hardest stop the IDM allows needs ~4.3 m) -- the movement clamp owns it. The car never
## reaches the body; it does not so much as creep.
func _check_car_brakes_point_blank() -> void:
	var label := "a car that cannot stop still never reaches the body"
	var lanes := _run_lanes()
	if lanes.size() < 2:
		return
	var lg: LG = tr.get("lanes")
	var w := _down_on_lane(lanes[0], 0.45)
	K.check(fails, bool(react.call("is_down", w)), "fixture: the victim lies on the lane")
	var c = _lane_car(lanes[0], 0.3, lanes.slice(1), CRUISE)
	_car_body = c
	_watch_from(w.pos + w.vis_off, lg.tan_at(lanes[0], 0.45))
	_reset(label)
	var min_d := INF
	var max_v := 0.0
	var t := 0.0
	while t < 7.0:
		tr.call("step", DT)
		tr.call("sync_visuals", DT)
		t += DT
		_clock += DT
		min_d = minf(min_d, _car_gap(c, w))
		max_v = maxf(max_v, c.v)
		if int(t / DT) % 2 == 0:
			_sample_body(label, w)
	print("  clamp gap: %s %.2f m" % [label, min_d / WS.M])
	K.check(
		fails,
		max_v <= 0.05 * WS.M,
		"%s: the clamp held it from the first tick (max %.2f m/s)" % [label, max_v / WS.M]
	)
	K.check(
		fails,
		min_d >= STOP_FLOOR,
		(
			"%s: it never came closer than %.2f m (floor %.2f m)"
			% [label, min_d / WS.M, STOP_FLOOR / WS.M]
		)
	)
	_finish_moving(label, c, w)


## A body thrown across an approaching car's nose: the flying body is a lane block from the
## hit's first tick (the block is xz-only, no height test), so the car brakes for it mid-air;
## it lands, the clamp keeps the car off it, and nothing is left touching.
func _check_throw_across_approaching_car() -> void:
	var label := "a body thrown across an approaching car is braked for, mid-air included"
	var lanes := _run_lanes()
	if lanes.size() < 2:
		return
	var lg: LG = tr.get("lanes")
	var lane: LG.Lane = lanes[0]
	var c = _lane_car(lane, 0.3, lanes.slice(1), CRUISE)
	_car_body = c
	var p: Vector2 = lg.pos_at(lane, 0.3 + CRUISE * 1.0)
	var tan: Vector2 = lg.tan_at(lane, 0.3 + CRUISE * 1.0)
	var h := Vector3(tan.x, 0.0, tan.y)
	var side := Vector3(tan.y, 0.0, -tan.x)
	var at := Vector3(p.x, WS.GROUND_Y, p.y) + side * (4.0 * WS.M) - h * (1.0 * WS.M)
	var w := _victim(at, -side)
	_watch_from(Vector3(p.x, WS.GROUND_Y, p.y), tan)
	_reset(label)
	var thrown := false
	var v_at_throw := 0.0
	var airborne_closing := false
	var far := 0.0
	var min_d := INF
	var t := 0.0
	while t < 8.0:
		if not thrown and _car_gap(c, w) < 10.0 * WS.M:
			react.call("hit", w, at - side * WS.M, -side * WS.M, STRENGTH, "car", 5.0)
			thrown = true
			v_at_throw = c.v
		tr.call("step", DT)
		tr.call("sync_visuals", DT)
		t += DT
		_clock += DT
		min_d = minf(min_d, _car_gap(c, w))
		if thrown and bool(react.call("is_down", w)):
			far = maxf(far, (w.pos + w.vis_off - at).dot(-side))
			if w.vis_off.y > 0.1 * WS.M and c.v > 1.0 * WS.M:
				airborne_closing = true
		if int(t / DT) % 2 == 0:
			_sample_body(label, w)
	K.check(fails, thrown, "fixture: the throw happened")
	K.check(
		fails,
		v_at_throw >= 5.0 * WS.M,
		"fixture: the car was still at speed when the body flew (%.1f m/s)" % (v_at_throw / WS.M)
	)
	print("  travel: %s %.2f m" % [label, far / WS.M])
	K.check(
		fails,
		far >= 2.0 * WS.M,
		"%s: the throw really crossed the lane (%.2f m)" % [label, far / WS.M]
	)
	K.check(
		fails, airborne_closing, "%s: the car was still closing while the body was mid-air" % label
	)
	K.check(
		fails,
		c.v < 0.05 * WS.M and min_d >= STOP_FLOOR,
		(
			"%s: it braked to a stop %.2f m short (floor %.2f m)"
			% [label, min_d / WS.M, STOP_FLOOR / WS.M]
		)
	)
	_finish_moving(label, c, w)


## The fixture's corner turn: {"tile", "lane", "approach", "exit"} for a corner tile whose
## entry edge faces a straight; empty without one.
func _corner_turn() -> Dictionary:
	var lg: LG = tr.get("lanes")
	for i: int in lg.tiles.keys():
		var t = lg.tiles[i]
		if t.piece != "corner":
			continue
		var edges: Array[int] = []
		for e in range(4):
			if t.mask & (1 << e):
				edges.append(e)
		for fe in edges:
			for te in edges:
				if fe == te:
					continue
				var lane = lg.lane_between(i, fe, te)
				if lane == null:
					continue
				var approach: int = lg.across(i, fe)
				if (
					approach < 0
					or lg.info(approach) == null
					or (lg.info(approach) as LG.TileInfo).piece != "straight"
				):
					continue
				var nxts: Array = lg.next_lanes(lane)
				if nxts.is_empty():
					continue
				return {"tile": i, "lane": lane, "approach": approach, "exit": nxts[0]}
	return {}


## A car rounding the fixture's corner finds a body lying past the apex: the gap walk follows
## the curve, so the brake owns it there too -- the car turns in, brakes to a crawl behind the
## body, and never touches it. (When the reaction ends the block lifts and the car drives on;
## what a resuming car meets is the routing walkers' business, not this suite's.)
func _check_car_brakes_on_the_bend() -> void:
	var label := "a car rounding a bend brakes short of a body past the apex"
	var turn := _corner_turn()
	K.check(fails, not turn.is_empty(), "fixture: a corner with a through lane")
	if turn.is_empty():
		return
	var lg: LG = tr.get("lanes")
	var e := -1
	for cand in range(4):
		if lg.across(int(turn["approach"]), cand) == int(turn["tile"]):
			e = cand
			break
	K.check(fails, e >= 0, "fixture: the corner's approach heading")
	if e < 0:
		return
	var approach: Array = lg.lanes_along([int(turn["approach"])], LG.OPP[e], e)
	K.check(fails, not approach.is_empty(), "fixture: the corner's approach lane")
	if approach.is_empty():
		return
	var lane: LG.Lane = approach[0]
	var exit: LG.Lane = turn["exit"]
	var w := _down_on_lane(exit, 0.15)
	K.check(fails, bool(react.call("is_down", w)), "fixture: the victim lies past the apex")
	var s0: float = maxf(0.3, lane.length - 0.5)
	var c = _lane_car(lane, s0, [turn["lane"], exit], CRUISE)
	_car_body = c
	_watch_from(w.pos + w.vis_off, lg.tan_at(exit, 0.15))
	_reset(label)
	var yaw0: float = c.yaw
	var turned := 0.0
	var min_d := INF
	var crawl := INF
	var t := 0.0
	while t < 8.0:
		tr.call("step", DT)
		tr.call("sync_visuals", DT)
		t += DT
		_clock += DT
		turned = maxf(turned, absf(wrapf(c.yaw - yaw0, -PI, PI)))
		min_d = minf(min_d, _car_gap(c, w))
		crawl = minf(crawl, c.v)
		if int(t / DT) % 2 == 0:
			_sample_body(label, w)
	print(
		(
			"  bend: yaw swung %.2f rad, crawl %.2f m/s, gap %.2f m"
			% [turned, crawl / WS.M, min_d / WS.M]
		)
	)
	K.check(
		fails,
		turned > 0.15,
		"%s: the car was into the turn as it braked (yaw swung %.2f rad)" % [label, turned]
	)
	K.check(
		fails,
		crawl <= 0.2 * WS.M,
		(
			"%s: the brake brought it to a crawl behind the body (slowest %.2f m/s)"
			% [label, crawl / WS.M]
		)
	)
	K.check(
		fails,
		min_d >= STOP_FLOOR,
		(
			"%s: it held %.2f m off the body through the turn (floor %.2f m)"
			% [label, min_d / WS.M, STOP_FLOOR / WS.M]
		)
	)
	_finish_moving(label, c, w)


## The press-out reads a car only up to its roof: a body whose feet overlap the car's side at
## ground level is pressed out, and the same overlap with the body lifted past the roof's
## height span is left alone -- nothing reaches up and swats a body flying over.
func _check_roof_press_boundary() -> void:
	var label := "the press-out reads a car only up to its roof"
	var lanes := _run_lanes()
	if lanes.size() < 2:
		return
	var vh = tr.get("vehicles")
	var c = _lane_car(lanes[0], 0.5, lanes.slice(1), 0.0)
	var bb: AABB = vh.aabb(c)
	var centre: Vector3 = c.pos
	var h2: Vector2 = OBB.heading(c.yaw)
	var side := Vector3(h2.y, 0.0, -h2.x)
	var at: Vector3 = centre + side * (float(c.half_w) + 1.0 * WS.M)
	at.y = WS.GROUND_Y
	var w := _victim(at, side)
	react.call("hit", w, at - side * WS.M, side * WS.M, STRENGTH, "car", 0.0)
	for _k in range(60):
		tr.call("step", DT)
		_clock += DT
	K.check(fails, bool(react.call("is_down", w)), "fixture: the victim lies beside the car")
	# Control: feet a hand's width inside the car's side at ground level -- the press acts.
	var in_feet: Vector3 = centre + side * (float(c.half_w) - 0.1 * WS.M)
	in_feet.y = WS.GROUND_Y
	w.pos = in_feet
	w.vis_off = Vector3.ZERO
	var before := Vector2(in_feet.x, in_feet.z)
	for _k in range(30):
		tr.call("step", DT)
		_clock += DT
	var ground_press := before.distance_to(Vector2((w.pos + w.vis_off).x, (w.pos + w.vis_off).z))
	# The same overlap with the body lifted past the roof: the press skips it entirely.
	w.pos = in_feet
	w.vis_off = Vector3.ZERO
	var rise: float = bb.end.y + 0.05 * WS.M - WS.GROUND_Y
	for _k in range(30):
		w.vis_off.y = rise
		tr.call("step", DT)
		w.vis_off.y = rise
		_clock += DT
	var roof_press := before.distance_to(Vector2((w.pos + w.vis_off).x, (w.pos + w.vis_off).z))
	print(
		(
			"  press: %.2f m at ground level, %.2f m past the roof"
			% [ground_press / WS.M, roof_press / WS.M]
		)
	)
	K.check(
		fails,
		ground_press >= 0.15 * WS.M,
		"%s: an overlap at ground level is pressed out (%.2f m)" % [label, ground_press / WS.M]
	)
	K.check(
		fails,
		roof_press <= 0.02 * WS.M,
		"%s: the same overlap past the roof is left alone (%.2f m)" % [label, roof_press / WS.M]
	)
	vh.remove(c)
	wk.remove(w)


# ------------------------------------------------------------------ measuring


## A fresh victim standing at feet facing along dir, clear of everything around them.
func _victim(at: Vector3, dir: Vector3) -> WK.Walker:
	var w := wk.make("ambient")
	wk.stand(w, at, atan2(dir.x, dir.z))
	return w


## One sample: the drawn feet, the torso point between them and the posed head, each against
## every movement box and cylinder nearby. Upright samples (no knock-down running) are held to
## TOL outright; a down body's sweep is allowed, as long as the overlap does not stick.
func _sample_body(label: String, w: WK.Walker) -> void:
	var feet := w.pos + w.vis_off
	var head: Vector3 = pe.call("head_of", w, feet)
	if w.body != null:
		_posed_heads += 1
	var mid := feet.lerp(head, 0.55)
	var upright := not bool(react.call("is_down", w))
	_press(label, "feet", feet, BODY_R, w, upright)
	_press(label, "torso", mid, BODY_R, w, upright)
	_press(label, "head", head, HEAD_R, w, upright)


## Deepest press of a sphere at q of radius r against the geometry: boxes first, then
## cylinders. The deepest press this label has seen is kept with its part and what pressed it.
func _press(label: String, part: String, q: Vector3, r: float, w: WK.Walker, upright: bool) -> void:
	var d := 0.0
	var what := ""
	for b: AABB in ctx.collision.boxes_near(q, r + 0.3):
		var e := _box_depth(q, r, b)
		if e > d:
			d = e
			what = "box %s" % b
	var cx := roundi(q.x)
	var cz := roundi(q.z)
	for gz in range(cz - 1, cz + 2):
		for gx in range(cx - 1, cx + 2):
			var cy: PackedFloat32Array = ctx.collision.cylinders(D.idx(gx, gz))
			for k in range(0, cy.size(), 4):
				var e := _cyl_depth(q, r, cy[k], cy[k + 1], cy[k + 2], cy[k + 3])
				if e > d:
					d = e
					what = (
						"cyl (%.2f, %.2f, r %.2f, top %.2f)"
						% [cy[k] / WS.M, cy[k + 1] / WS.M, cy[k + 2] / WS.M, cy[k + 3] / WS.M]
					)
	if _car_body != null:
		var e := _car_depth(q, r)
		if e > d:
			d = e
			what = "car %d" % int(_car_body.id)
	var where := [d, q, part, what, w.state, str(w.react), w.react_t]
	var any_prev: Variant = _worst_any.get(label)
	if any_prev == null or d > float(any_prev[0]):
		_worst_any[label] = where
	if upright:
		var up_prev: Variant = _worst_up.get(label)
		if up_prev == null or d > float(up_prev[0]):
			_worst_up[label] = where
	# The stick rule: an overlap past TOL is a sweep only while it lasts under CLEAR_S.
	var opened: Variant = _span_open.get(label)
	if d > TOL:
		if opened == null or float(opened) < 0.0:
			_span_open[label] = _clock
	else:
		if opened != null and float(opened) >= 0.0:
			_span_max[label] = maxf(float(_span_max.get(label, 0.0)), _clock - float(opened))
			_span_open[label] = -1.0
	_last_d[label] = d


## Forgets label's measurements before a fresh run of it.
func _reset(label: String) -> void:
	_worst_up.erase(label)
	_worst_any.erase(label)
	_span_open[label] = -1.0
	_span_max[label] = 0.0
	_last_d.erase(label)


## How deep sphere (q, r) reaches into box b (0 when clear): past the closest point from
## outside, or out through the nearest side face plus r from within -- the same way clear the
## engine's press-out uses. Resting on or hanging under b counts 0.
static func _box_depth(q: Vector3, r: float, b: AABB) -> float:
	var c := Vector3(
		clampf(q.x, b.position.x, b.end.x),
		clampf(q.y, b.position.y, b.end.y),
		clampf(q.z, b.position.z, b.end.z)
	)
	var off := q - c
	var dist := off.length()
	if dist > 1e-9:
		return maxf(0.0, r - dist) if Vector2(off.x, off.z).length() > 1e-9 else 0.0
	var dx := minf(q.x - b.position.x, b.end.x - q.x)
	var dy := minf(q.y - b.position.y, b.end.y - q.y)
	var dz := minf(q.z - b.position.z, b.end.z - q.z)
	if dy <= dx and dy <= dz:
		return 0.0
	return minf(dx, dz) + r


## How deep sphere (q, r) reaches into the cylinder (x, z, rc, top) standing from the ground
## (0 when clear, and when its cap or the ground is the nearer way out -- a rest).
static func _cyl_depth(q: Vector3, r: float, x: float, z: float, rc: float, top: float) -> float:
	var hx := Vector2(q.x - x, q.z - z)
	var l := hx.length()
	var ccx := x + hx.x / maxf(l, 1e-9) * minf(l, rc)
	var ccz := z + hx.y / maxf(l, 1e-9) * minf(l, rc)
	var off := Vector3(q.x - ccx, q.y - clampf(q.y, WS.GROUND_Y, top), q.z - ccz)
	var dist := off.length()
	if dist > 1e-9:
		return maxf(0.0, r - dist) if Vector2(off.x, off.z).length() > 1e-9 else 0.0
	if l <= 1e-9:
		return 0.0
	var out := (rc - l) + r
	return out if out <= minf(top - q.y, q.y - WS.GROUND_Y) else 0.0


## How deep sphere (q, r) reaches into the scenario's real car body (0 when clear): its yaw'd
## rectangle as OBB.box_circle measures it, bounded by the car's height span -- a body flying
## over or resting on the roof is clear of it, as with the static boxes.
func _car_depth(q: Vector3, r: float) -> float:
	var vh = tr.get("vehicles")
	var bb: AABB = vh.aabb(_car_body)
	if q.y < bb.position.y or q.y > bb.end.y:
		return 0.0
	var centre: Vector3 = _car_body.pos + _car_body.vis_off
	var hit: Array = OBB.box_circle(
		Vector2(centre.x, centre.z),
		OBB.side_axis(_car_body.yaw),
		OBB.heading(_car_body.yaw),
		Vector2(_car_body.half_w, _car_body.length * 0.5),
		Vector2(q.x, q.z),
		r
	)
	return 0.0 if hit.is_empty() else float(hit[1])


## Prints one line for label: ok when upright never pressed past TOL, every sweep's overlap
## eased out within CLEAR_S, and the body walked away clear; FAIL otherwise, saying which.
func _report(label: String) -> void:
	var up: Variant = _worst_up.get(label)
	var sweep: Variant = _worst_any.get(label)
	var up_depth := 0.0 if up == null else float(up[0])
	var span := maxf(float(_span_max.get(label, 0.0)), 0.0)
	var opened: Variant = _span_open.get(label)
	if opened != null and float(opened) >= 0.0:
		span = maxf(span, _clock - float(opened))
	var end_depth := float(_last_d.get(label, 0.0))
	var worst := (
		""
		if sweep == null
		else (
			"; worst sweep %s of %s at %s, %s %s @ %.2f s"
			% [sweep[2], sweep[3], str(sweep[1]), sweep[4], sweep[5], float(sweep[6])]
		)
	)
	var msg := (
		"%s (worst upright %.0f mm, deepest sweep %.0f mm, longest overlap %.2f s, end %.0f mm%s)"
		% [
			label,
			up_depth / WS.M * 1000.0,
			(0.0 if sweep == null else float(sweep[0])) / WS.M * 1000.0,
			span,
			end_depth / WS.M * 1000.0,
			worst
		]
	)
	K.check(fails, up_depth <= TOL and span <= CLEAR_S and end_depth <= TOL, msg)
