extends SceneTree
## Driving (integration feature "drive"): the handling model, getting into a stopped car, driving
## it along a straight road, lane traffic stopping behind it, crashing into a wall (car_impact on
## the bus), sliding along a wall it meets at a glance, knocking a lane car off its lane (which
## finds its way back), getting out beside the door, the car left standing as an obstacle, the
## seated hero, keys and pad bindings, and teardown. Getting in and out is the instant way (the
## car_doors flag off; fp_car_doors_test covers the walk to the door). Time runs through
## drive_step(1/60) and the traffic feature's step(1/30).

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const OBB := preload("res://scripts/fp/obb2d.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const MODEL := preload("res://scripts/fp/drive/drive_model.gd")
const DT := 1.0 / 60.0
const KMH := WS.M / 3.6

var fails: Array[String] = []
var ctx: FpContext
var tr: FpFeature
var drive: FpFeature
var lanes: Array = []
var heading := Vector2.ZERO
## The straight road's tiles, in the order heading runs along them.
var road: Array[int] = []
## [at, closing speed, what] of every car_impact.
var impacts: Array = []


func _init() -> void:
	await process_frame
	_check_model()
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "first"})
	ctx.player.set_process(false)
	tr = K.make_feature(ctx, "traffic")
	var it := K.make_feature(ctx, "interact")
	drive = K.make_feature(ctx, "drive")
	K.check(
		fails, drive != null and drive.feature_id() == "drive", "the drive feature is registered"
	)
	if drive == null or tr == null:
		K.finish(self, "FP_DRIVE_TEST", fails)
		return
	tr.set("auto_step", false)
	tr.set("ambient_enabled", false)
	drive.set_process(false)
	it.set_process(false)
	FeatureFlags.set_override("car_doors", false)
	ctx.bus.car_impact.connect(
		func(at: Vector3, v: float, what: String) -> void: impacts.append([at, v, what])
	)
	K.check(
		fails,
		drive.self_test().get("ok", false),
		"self_test: %s" % drive.self_test().get("detail", "")
	)
	if not _road():
		K.finish(self, "FP_DRIVE_TEST", fails)
		return
	_check_enter(it)
	_check_seated()
	_check_drive()
	_check_camera()
	_check_yield()
	_check_exit()
	_check_crash()
	_check_glance()
	_check_shove()
	_check_keys()
	_check_teardown()
	K.finish(self, "FP_DRIVE_TEST", fails)


# ------------------------------------------------------------------ model


func _check_model() -> void:
	var m := MODEL.new()
	m.reset(0.0, 0.24)
	_run(m, 1.0, 0.0, 0.0, 0.0, "asphalt", 3.0)
	var v3 := m.speed()
	K.check(
		fails,
		v3 > 40.0 * KMH and v3 < 90.0 * KMH,
		"model: 3 s of full throttle reaches %.0f km/h" % (v3 / KMH)
	)
	K.check(
		fails,
		absf(m.yaw) < 1e-6 and m.heading().y > 0.999,
		"model: no steering keeps the heading (+Z at yaw 0)"
	)
	_run(m, 1.0, 0.0, 0.0, 0.0, "asphalt", 20.0)
	K.check(
		fails,
		m.speed() <= MODEL.TOP + 1e-4,
		"model: top speed holds (%.0f km/h)" % (m.speed() / KMH)
	)
	_run(m, 0.0, 1.0, 0.0, 0.0, "asphalt", 3.0)
	K.check(fails, absf(m.speed()) < 2.0 * KMH or m.speed() < 0.0, "model: braking stops the car")
	m.reset(0.0, 0.24)
	_run(m, 0.0, 1.0, 0.0, 0.0, "asphalt", 6.0)
	var rev := m.speed()
	K.check(
		fails,
		rev < -2.0 * WS.M and rev >= -MODEL.REVERSE_TOP - 1e-4,
		"model: S from rest reverses (%.1f m/s)" % (rev / WS.M)
	)
	m.reset(0.0, 0.24)
	_run(m, 1.0, 0.0, 0.0, 0.0, "asphalt", 2.0)
	_run(m, 0.5, 0.0, 1.0, 0.0, "asphalt", 0.5)
	K.check(
		fails,
		m.heading().x < -0.05,
		"model: steering right turns toward the car's right (-X at yaw 0): %.2f" % m.heading().x
	)
	var g := MODEL.new()
	g.reset(0.0, 0.24)
	_run(g, 1.0, 0.0, 0.0, 0.0, "grass", 20.0)
	K.check(
		fails,
		g.speed() < 0.6 * MODEL.TOP,
		(
			"model: grass holds the car well under its asphalt top speed (%.0f km/h)"
			% (g.speed() / KMH)
		)
	)
	K.check(
		fails,
		_slip(1.0) > 2.0 * _slip(0.0),
		"model: the handbrake lets the car slide (slip %.3f vs %.3f u/s)" % [_slip(1.0), _slip(0.0)]
	)


func _run(
	m: MODEL, th: float, br: float, st: float, hb: float, surface: String, secs: float
) -> void:
	for _k in range(roundi(secs / DT)):
		m.step(th, br, st, hb, surface, DT)


## Sideways speed after a hard turn at 50 km/h with the handbrake at hand.
func _slip(hand: float) -> float:
	var m := MODEL.new()
	m.reset(0.0, 0.24)
	m.vel = Vector2(0.0, 50.0 * KMH)
	_run(m, 0.0, 0.0, 1.0, hand, "asphalt", 0.4)
	var h := m.heading()
	return absf(m.vel.dot(Vector2(-h.y, h.x)))


# ------------------------------------------------------------------ world


func _vh() -> VH:
	return tr.get("vehicles")


## The longest straight road run; its first lane heads along it.
func _road() -> bool:
	var lg: LG = tr.get("lanes")
	var best: Array[int] = []
	var best_e := 0
	for i: int in lg.tiles.keys():
		for e: int in _straight_edges(lg.tiles[i]):
			var run := _run_from(lg, i, e)
			if run.size() > best.size():
				best = run
				best_e = e
	K.check(fails, best.size() >= 3, "fixture: a straight road of 3+ tiles (%d)" % best.size())
	if best.size() < 3:
		return false
	lanes = lg.lanes_along(best, LG.OPP[best_e], best_e)
	heading = LG.DIRS[best_e]
	road = best
	return not lanes.is_empty()


## The N-S / E-W edges a plain straight (not a bridge) runs along.
func _straight_edges(t: LG.TileInfo) -> Array[int]:
	var out: Array[int] = []
	if t.piece == "straight" and not t.bridge:
		out.assign([0, 1].filter(func(e: int) -> bool: return t.mask & (1 << e)))
	return out


## Straight tiles from i onward along edge e.
func _run_from(lg: LG, i: int, e: int) -> Array[int]:
	var run: Array[int] = [i]
	var nx := lg.across(i, e)
	while nx >= 0 and lg.info(nx) != null and (lg.info(nx) as LG.TileInfo).piece == "straight":
		run.append(nx)
		nx = lg.across(nx, e)
	return run


## Every vehicle but the player's goes.
func _clear_others() -> void:
	var keep := int(tr.call("driven_id"))
	for c: VH.Car in _vh().cars.duplicate():
		if c.id != keep and c.role != VH.PLAYER:
			_vh().remove(c)
	ctx.collision.dynamic_boxes = []


func _drive(th: float, br: float, st: float, secs: float) -> void:
	for k in range(roundi(secs / DT)):
		drive.call("drive_step", th, br, st, 0.0, DT)
		if k % 2 == 0:
			tr.call("step", DT * 2.0)
		ctx.player.update_view(DT)


func _car() -> VH.Car:
	return _vh().by_id.get(int(drive.get("car_id")))


# ------------------------------------------------------------------ checks


func _check_enter(it: FpFeature) -> void:
	_clear_others()
	var m: int = tr.call("car_model_for", "drive-test")
	var c := _vh().make("car", "ambient", tr.call("dims", m))
	c.model = m
	_vh().place(c, lanes[0], 0.35)
	c.v = 0.0
	var left := Basis(Vector3.UP, c.yaw) * Vector3(c.half_w + 0.6 * WS.M, 0.0, 0.0)
	ctx.player.teleport(c.pos + left, 0.0)
	var t: Dictionary = drive.call("enter_target")
	K.check(
		fails,
		int(t.get("id", -1)) == c.id,
		"a stopped car beside the hero is the get-in target (%s)" % str(t)
	)
	var got := []
	ctx.bus.drive_changed.connect(func(on: bool) -> void: got.append(on))
	K.check(fails, drive.call("enter") == true and bool(drive.get("active")), "enter() gets in")
	var car := _car()
	K.check(
		fails,
		car != null and car.role == VH.PLAYER and car.driven and car.model == m,
		"the car is now the player's, same model"
	)
	K.check(
		fails,
		not _vh().by_id.has(c.id) and int(tr.call("driven_id")) == car.id,
		"the ambient car it replaced is gone"
	)
	var p := ctx.player
	K.check(
		fails,
		not p.input_enabled and p.view_override and p.camera_mode == "third",
		"walking input is off and the drive camera has the view"
	)
	K.check(fails, got == [true], "drive_changed(true) on the bus")
	K.check(
		fails,
		(it.call("evaluate") as Dictionary).is_empty(),
		"nothing to interact with from behind the wheel"
	)
	K.check(
		fails,
		Vector2(p.position.x - car.pos.x, p.position.z - car.pos.z).length() < car.length * 0.5,
		"the hero rides inside the car"
	)
	_clear_others()


func _check_seated() -> void:
	tr.call("sync_visuals", DT)
	_drive(0.0, 0.0, 0.0, 1.5)
	tr.call("sync_visuals", DT)
	var av := ctx.player.avatar
	var seat: Variant = tr.call("seat_offset")
	var rig: Variant = av.get("rig")
	if seat == null or rig == null:
		K.check(
			fails, seat != null or _car().node == null, "the drawn car has a seat (%s)" % str(seat)
		)
		return
	_drive(0.0, 0.0, 0.0, DT)
	var car := _car()
	var want := Transform3D(Basis(Vector3.UP, car.yaw), car.pos) * (seat as Vector3)
	var hips: Vector3 = (rig as RefCounted).call("bone_world", "Hips")
	var st := str((rig as RefCounted).call("state"))
	var off := (hips - want) / WS.M
	K.check(
		fails,
		av.visible and off.length() < 0.05,
		"the hero's hips are on the driver's seat (%.2f m off)" % off.length()
	)
	K.check(fails, st == "sit" or st == "sit_down", "the hero sits (%s)" % st)


func _check_drive() -> void:
	var car := _car()
	var from := car.pos
	_drive(1.0, 0.0, 0.0, 2.0)
	car = _car()
	var moved := Vector2(car.pos.x - from.x, car.pos.z - from.z)
	var v := float((drive.get("model") as MODEL).speed())
	K.check(
		fails,
		moved.dot(heading) > 8.0 * WS.M,
		"full throttle for 2 s drives the car down the road (%.1f m)" % (moved.dot(heading) / WS.M)
	)
	K.check(fails, absf(moved.normalized().dot(heading)) > 0.98, "straight along it")
	K.check(
		fails,
		v > 20.0 * KMH and absf(car.v - absf(v)) < 1e-4,
		"traffic sees its speed (%.0f km/h)" % (v / KMH)
	)
	var hud: Variant = drive.get("hud")
	if hud != null:
		(hud as Node).call("set_speed", true, v)
		K.check(
			fails,
			str((hud as Node).call("speed_text")) == str(roundi(v / KMH)),
			"the speedometer reads km/h"
		)
	K.check(
		fails, ctx.player.position.distance_to(car.pos) < car.length * 0.5, "the hero rides along"
	)
	_drive(0.0, 1.0, 0.0, 2.0)


## The chase camera rides above the car; looking up from low down (the mouse pushed all the way)
## lowers it but never under the road.
func _check_camera() -> void:
	var car := _car()
	var high: Transform3D = drive.call("camera_xform")
	var above := (high.origin.y - car.pos.y) / WS.M
	K.check(fails, above > 1.0, "the chase camera rides above the car (%.2f m)" % above)
	drive.call("_orbit_by", 0.0, -PI)
	var low: Transform3D = drive.call("camera_xform")
	var clear := (low.origin.y - ctx.collision.ground_height(low.origin)) / WS.M
	K.check(
		fails,
		clear > 0.2 and low.origin.y < high.origin.y,
		"looking up from low down it stays above the road (%.2f m)" % clear
	)
	drive.set("_orbit_pitch", 0.0)


func _check_yield() -> void:
	var car := _car()
	var vh := _vh()
	var m: int = tr.call("car_model_for", "yield-test")
	var ai := vh.make("car", "ambient", tr.call("dims", m))
	ai.model = m
	vh.place(ai, lanes[0], 0.05)
	ai.path = lanes.slice(1)
	ai.v = WS.CAR_CITY
	ai.v0 = WS.CAR_CITY
	var gap := INF
	for _k in range(int(15.0 / (DT * 2.0))):
		tr.call("step", DT * 2.0)
		gap = minf(gap, _box_gap(vh.aabb(ai), vh.aabb(car)))
	K.check(
		fails,
		not ai.dead and ai.v < 0.1 * WS.M and gap > 0.5 * WS.M,
		"lane traffic stops behind the player's car (closest %.1f m)" % (gap / WS.M)
	)
	vh.remove(ai)


func _check_exit() -> void:
	var p := ctx.player
	var toasts: Array[String] = []
	var cb := func(t: String, _k: String) -> void: toasts.append(t)
	ctx.bus.toast.connect(cb)
	_drive(1.0, 0.0, 0.0, 2.5)
	K.check(
		fails,
		drive.call("exit") == false and toasts.size() == 1,
		"too fast to get out: it says so (%s)" % str(toasts)
	)
	ctx.bus.toast.disconnect(cb)
	_drive(0.0, 1.0, 0.0, 3.0)
	var car := _car()
	var id := car.id
	K.check(
		fails,
		drive.call("exit") == true and not bool(drive.get("active")),
		"slowed down, exit() gets out"
	)
	var hud: Variant = drive.get("hud")
	if hud != null:
		K.check(
			fails, str((hud as Node).call("speed_text")) == "", "the speedometer goes away on foot"
		)
	K.check(
		fails,
		p.input_enabled and not p.view_override and p.camera_mode == "first",
		"walking input, the hero's camera and the first-person view are back"
	)
	K.check(
		fails,
		not ctx.collision.is_blocked(p.position, WS.PLAYER_RADIUS),
		"the hero stands on free ground"
	)
	var d: float = tr.call("_body_dist", car, p.position)
	K.check(
		fails,
		d > 0.2 * WS.M and d < 1.5 * WS.M,
		"beside the car (%.1f m from its body)" % (d / WS.M)
	)
	var left := Vector2(car.pos.x - p.position.x, car.pos.z - p.position.z).dot(
		Vector2(-heading.y, heading.x)
	)
	K.check(fails, left != 0.0, "on one side of it")
	K.check(
		fails,
		_vh().by_id.has(id) and not car.driven and int(tr.call("driven_id")) == -1,
		"the car stays where it was left"
	)
	var blocks: Array = tr.call("blockers_near", p.position, 0.2)
	K.check(fails, blocks.size() >= 1, "and blocks the hero on foot")
	var t: Dictionary = drive.call("enter_target")
	K.check(
		fails,
		int(t.get("id", -1)) == id and str(t.get("label", "")) == "your car",
		"it is the get-in target again: %s" % str(t)
	)
	K.check(fails, avatar_free(), "the hero stands up and is drawn at the feet again")


func avatar_free() -> bool:
	var rig: Variant = ctx.player.avatar.get("rig")
	var st := str((rig as RefCounted).call("state")) if rig != null else ""
	return ctx.player.avatar.visible and not st.begins_with("sit")


## Drives into a wall across the road: the body never enters it and the car stops.
func _check_crash() -> void:
	K.check(fails, drive.call("enter") == true, "back in")
	_clear_others()
	var car := _car()
	var start := car.pos
	var h3 := Vector3(heading.x, 0.0, heading.y)
	var wall_c := car.pos + h3 * (25.0 * WS.M)
	var ext := (
		Vector3(absf(heading.y), 0.0, absf(heading.x)) * WS.ROAD_HALF * 1.6
		+ Vector3(0.1, 0.0, 0.1) * WS.M * 5.0
	)
	var wall := AABB(
		Vector3(wall_c.x - ext.x, 0.0, wall_c.z - ext.z), Vector3(ext.x * 2.0, 0.2, ext.z * 2.0)
	)
	ctx.collision.add_test_box(wall)
	impacts.clear()
	var deep := -INF
	var near := (wall_c - start).dot(h3) - 0.5 * WS.M
	for _k in range(roundi(5.0 / DT)):
		drive.call("drive_step", 1.0, 0.0, 0.0, 0.0, DT)
		var c := _car()
		deep = maxf(deep, (c.pos - start).dot(h3) + c.length * 0.5 - near)
	var v := float((drive.get("model") as MODEL).speed())
	K.check(
		fails,
		deep < 0.1 * WS.M,
		"the car never drives into the wall (front %.2f m past its face)" % (deep / WS.M)
	)
	K.check(fails, absf(v) < 5.0 * KMH, "and stops against it (%.0f km/h)" % (v / KMH))
	var hit: Array = impacts[0] if not impacts.is_empty() else [Vector3.ZERO, 0.0, ""]
	K.check(
		fails,
		str(hit[2]) == "wall" and float(hit[1]) > 20.0 * KMH,
		"car_impact reports the crash (%s at %.0f km/h)" % [str(hit[2]), float(hit[1]) / KMH]
	)
	ctx.collision.clear_test_boxes()
	_drive(0.0, 1.0, 0.0, 1.0)


## Meets a wall along the road at 15 degrees and 40 km/h: the car never enters it, turns along it
## and slides on, and car_impact reports only the small speed it closed on the wall at.
func _check_glance() -> void:
	_clear_others()
	var model: MODEL = drive.get("model")
	var dims: Vector3 = drive.get("_dims")
	var a := Vector2(D.tx(road[0]), D.ty(road[0]))
	var side := Vector2(-heading.y, heading.x)
	var face := 0.12
	var mid := a + side * (face + 0.05) + heading * (road.size() * 0.5 - 0.5)
	var ext := (
		Vector3(absf(heading.x), 0.0, absf(heading.y)) * (road.size() * 0.5)
		+ Vector3(absf(side.x), 0.0, absf(side.y)) * 0.05
	)
	ctx.collision.add_test_box(
		AABB(Vector3(mid.x - ext.x, 0.0, mid.y - ext.z), Vector3(ext.x * 2.0, 0.2, ext.z * 2.0))
	)
	var dir := heading * cos(deg_to_rad(15.0)) + side * sin(deg_to_rad(15.0))
	var start := Vector3(a.x, ctx.collision.walk_height(Vector3(a.x, 0.0, a.y)), a.y)
	drive.set("_pos", start)
	model.reset(atan2(dir.x, dir.y), dims.z)
	model.vel = dir * (40.0 * KMH)
	impacts.clear()
	var deep := -INF
	for _k in range(roundi(2.0 / DT)):
		drive.call("drive_step", 0.4, 0.0, 0.0, 0.0, DT)
		deep = maxf(deep, _reach(side, dims) - (a.dot(side) + face))
	var turn := rad_to_deg(absf(model.heading().angle_to(heading)))
	K.check(
		fails,
		deep < 0.1 * WS.M,
		"at a glance the car never enters the wall (%.2f m past its face)" % (deep / WS.M)
	)
	K.check(
		fails,
		model.speed() > 20.0 * KMH and turn < 8.0,
		"it turns along the wall (%.0f deg) and slides on (%.0f km/h)" % [turn, model.speed() / KMH]
	)
	var hit: Array = impacts[0] if not impacts.is_empty() else [Vector3.ZERO, INF, ""]
	K.check(
		fails,
		str(hit[2]) == "wall" and float(hit[1]) < 15.0 * KMH,
		"car_impact: it closed on the wall at %.0f km/h" % (float(hit[1]) / KMH)
	)
	ctx.collision.clear_test_boxes()
	_drive(0.0, 1.0, 0.0, 2.0)


## Runs into the side of a lane car crawling along at 25 km/h: it slides off its lane, braking,
## the player's car loses speed, car_impact reports a car and the bodies never overlap. Once the
## player backs off and it has waited, its driver steers it back onto the lane and drives on.
func _check_shove() -> void:
	_clear_others()
	var vh := _vh()
	var model: MODEL = drive.get("model")
	var dims: Vector3 = drive.get("_dims")
	var m: int = tr.call("car_model_for", "shove-test")
	var ai := vh.make("car", "ambient", tr.call("dims", m))
	ai.model = m
	vh.place(ai, lanes[1], 0.5)
	ai.path = lanes.slice(2)
	ai.v0 = 0.5 * WS.M
	ai.v = ai.v0
	var q := Vector2(ai.pos.x, ai.pos.z)
	var u := OBB.side_axis(ai.yaw)
	if (Vector2(roundf(q.x), roundf(q.y)) - q).dot(u) < 0.0:
		u = -u
	var s2 := q + u * (ai.half_w + dims.z * 0.5 + 1.5 * WS.M)
	drive.set("_pos", Vector3(s2.x, ai.pos.y, s2.y))
	model.reset(atan2(-u.x, -u.y), dims.z)
	model.vel = -u * (25.0 * KMH)
	impacts.clear()
	var deep := 0.0
	var off := 0.0
	var stunned := false
	for _k in range(roundi(1.0 / (DT * 2.0))):
		for _s in range(2):
			drive.call("drive_step", 0.0, 0.0, 0.0, 0.0, DT)
			deep = maxf(deep, _overlap(ai, dims))
		tr.call("step", DT * 2.0)
		off = maxf(off, Vector2(ai.vis_off.x, ai.vis_off.z).length())
		stunned = stunned or ai.stun_t > 0.0
	var cars := impacts.filter(func(h: Array) -> bool: return str(h[2]) == "car")
	var v0 := float(cars[0][1]) / KMH if not cars.is_empty() else 0.0
	K.check(fails, not cars.is_empty(), "car_impact reports hitting a car at %.0f km/h" % v0)
	K.check(
		fails,
		off > 0.3 * WS.M and stunned,
		"the lane car slides %.1f m off its lane, braking" % (off / WS.M)
	)
	K.check(
		fails,
		absf(model.speed()) < 15.0 * KMH and deep < 0.1 * WS.M,
		(
			"the player's car loses speed (%.0f km/h), the bodies never overlap (%.2f m)"
			% [absf(model.speed()) / KMH, deep / WS.M]
		)
	)
	_drive(0.0, 1.0, 0.0, 2.5)
	model.vel = Vector2.ZERO
	_drive(0.0, 0.0, 0.0, DT)
	var back := false
	for _k in range(roundi(20.0 / (DT * 2.0))):
		tr.call("step", DT * 2.0)
		if ai.vis_off == Vector3.ZERO and ai.vis_yaw == 0.0 and ai.stun_t <= 0.0:
			back = true
			break
	K.check(
		fails,
		back and not ai.dead and not bool(tr.get("shoves").call("is_shoved", ai)),
		"it steers back onto its lane and drives on (%.2f m off)" % (ai.vis_off.length() / WS.M)
	)
	_clear_others()


## The farthest the player's car's body reaches along the unit vector side (a coordinate along it).
func _reach(side: Vector2, dims: Vector3) -> float:
	var p: Vector3 = drive.get("_pos")
	var yaw := float((drive.get("model") as MODEL).yaw)
	var u := OBB.side_axis(yaw)
	var v := OBB.heading(yaw)
	var c := Vector2(p.x, p.z).dot(side)
	return c + absf(u.dot(side)) * dims.x + absf(v.dot(side)) * dims.z * 0.5


## Depth of the player's car's body in car c's.
func _overlap(c: VH.Car, dims: Vector3) -> float:
	var p: Vector3 = drive.get("_pos")
	var yaw := float((drive.get("model") as MODEL).yaw)
	var q := c.pos + c.vis_off
	var cy := c.yaw + c.vis_yaw
	var k := OBB.box_box(
		Vector2(p.x, p.z),
		OBB.side_axis(yaw),
		OBB.heading(yaw),
		Vector2(dims.x, dims.z * 0.5),
		Vector2(q.x, q.z),
		OBB.side_axis(cy),
		OBB.heading(cy),
		Vector2(c.half_w, c.length * 0.5)
	)
	return float(k[1]) if not k.is_empty() else 0.0


func _check_keys() -> void:
	var pad := false
	for e: InputEvent in InputMap.action_get_events("vehicle_enter"):
		pad = pad or e is InputEventJoypadButton
	var trig := InputMap.has_action("drive_throttle") and InputMap.has_action("drive_brake")
	K.check(fails, pad and trig, "get in / out has a pad button and the triggers drive")
	drive.call("_input", _action("vehicle_enter"))
	K.check(fails, not bool(drive.get("active")), "F gets out")
	drive.call("_input", _action("vehicle_enter"))
	K.check(fails, bool(drive.get("active")), "F gets back in")
	drive.call("_input", _action("view_toggle"))
	K.check(fails, str(drive.get("view")) == "driver", "V switches to the driver's view")
	ctx.push_modal(&"test")
	drive.call("_input", _action("vehicle_enter"))
	K.check(fails, bool(drive.get("active")), "keys wait while a menu is open")
	ctx.pop_modal(&"test")
	drive.call("_input", _action("view_toggle"))


func _check_teardown() -> void:
	drive.teardown()
	var p := ctx.player
	K.check(
		fails,
		not bool(drive.get("active")) and p.input_enabled and not p.view_override,
		"teardown gets the hero out"
	)
	K.check(fails, int(tr.call("driven_id")) == -1, "and hands the car back to traffic")


static func _box_gap(a: AABB, b: AABB) -> float:
	var dx := maxf(0.0, maxf(a.position.x - b.end.x, b.position.x - a.end.x))
	var dz := maxf(0.0, maxf(a.position.z - b.end.z, b.position.z - a.end.z))
	return Vector2(dx, dz).length()


func _action(a: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = a
	e.pressed = true
	return e
