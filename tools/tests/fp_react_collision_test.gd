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


## Hits w with cause along dir (src behind them, push along dir), samples the drawn body to the
## reaction's end. The hero watches 2.5 m back, so the body draws and its head is the posed
## bone.
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
	var ret: Dictionary = react.call("hit", w, src, dir * WS.M, STRENGTH, cause, fling_m * WS.M)
	var t := 0.0
	var ticks := 0
	while t < REACT_S:
		tr.call("step", DT)
		tr.call("sync_visuals", DT)
		t += DT
		ticks += 1
		_clock += DT
		if int(t / DT) % 2 == 0:
			_sample_body(label, w)
	return ret


## A punch knocks them down, the throw flies them into a wall 1.2 m along the run.
func _check_throw_into_wall(at: Vector3, run: Vector3) -> void:
	var label := "a thrown body comes to rest against a wall"
	ctx.collision.add_test_box(_wall(at, run, 1.2))
	var w := _victim(at, run)
	var ret := _hit_and_watch(label, w, at, run, "punch", 2.5)
	K.check(fails, bool(ret.get("down", false)), "fixture: the punch knocks them down")
	_report(label)
	wk.remove(w)
	ctx.collision.clear_test_boxes()


## A car runs them down, the throw flies them into a car-shaped box 1.5 m along the run.
func _check_throw_into_car(at: Vector3, run: Vector3) -> void:
	ctx.collision.add_test_box(_car(at, run, 1.5))
	var w := _victim(at, run)
	var ret := _hit_and_watch("a body thrown at a car lands clear of it", w, at, run, "car", 2.5)
	K.check(fails, bool(ret.get("down", false)), "fixture: the car knocks them down")
	_report("a body thrown at a car lands clear of it")
	wk.remove(w)
	ctx.collision.clear_test_boxes()


## A punch throws them at a lamp-post-shaped box 1.1 m along the run.
func _check_throw_into_post(at: Vector3, run: Vector3) -> void:
	ctx.collision.add_test_box(_post(at, run, 1.1))
	var w := _victim(at, run)
	var ret := _hit_and_watch("a body thrown at a post lands clear of it", w, at, run, "punch", 2.5)
	K.check(fails, bool(ret.get("down", false)), "fixture: the punch knocks them down")
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
