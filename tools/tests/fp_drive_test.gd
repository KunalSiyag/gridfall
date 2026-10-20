extends SceneTree
## Driving (integration feature "drive"): the handling model, getting into a stopped car, driving
## it along a straight road, lane traffic stopping behind it, crashing into a wall, getting out
## beside the door, the car left standing as an obstacle, the seated hero, keys and pad bindings,
## and teardown. Time runs through drive_step(1/60) and the traffic feature's step(1/30).

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
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
	_check_yield()
	_check_exit()
	_check_crash()
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
	ctx.collision.clear_test_boxes()
	_drive(0.0, 1.0, 0.0, 1.0)


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
