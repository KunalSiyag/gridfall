extends SceneTree
## Driving (integration feature "drive"): the handling model, getting into a stopped car, driving
## it along a straight road, lane traffic stopping behind it, crashing into a wall (car_impact on
## the bus), sliding along a wall it meets at a glance, a wall a hand's width thick it cannot
## step past, the street's posts (a corner signal pole, a pedestrian signal, a dressing sign pole)
## rammed at speed without the car's box ever sinking into them, knocking a lane car off its lane
## (which finds its way back), getting out beside the
## door, the car left standing as an obstacle, the hero on foot against cars in motion (never
## inside one's body: eased out, carried along, run down exactly once while hittable, stopped
## short of when not), the seated hero (hips on the seat sunk into the cushion, hands on the rim,
## feet on the pedals, head under the roof, in every drivable body), keys and pad bindings, and
## teardown. Getting in and out is the instant way (the car_doors flag off; fp_car_doors_test
## covers the walk to the door) and nobody is pulled out of a car taken from traffic (carjack
## off; fp_carjack_test). Time runs through drive_step(1/60) and the traffic feature's
## step(1/30). The backhoe's arm rig gets its own check: the rig nodes on the model, Y / U / I / O
## turning them at the wheel, the dig over a site growing the pile, the flag off, and the pile
## staying once the hero is out. Night driving (the night_driving flag) gets its own too: the
## hero's own beam after dark (a dedicated lamp beside the street's shared pool; a bicycle a
## small dim one), H the horn and bell on hero_action and into the street's own horn source, the
## cooldown between presses, and both off with the flag. The horn's reach over the traffic round
## the hero gets two more (the blocked_horns and horn_reach flags): a car the hero's own holds up
## honks at them within a couple of seconds, and a car stopped ahead of them -- stunned by a knock
## -- gets going when they sound it.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const AP := preload("res://scripts/fp/asset_paths.gd")
const OBB := preload("res://scripts/fp/obb2d.gd")
const BC := preload("res://scripts/fp/body_contacts.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const MODEL := preload("res://scripts/fp/drive/drive_model.gd")
const SHOVES := preload("res://scripts/fp/traffic/shoves.gd")
const SEAT := preload("res://scripts/fp/drive/seat_pose.gd")
const RD := preload("res://scripts/fp/traffic/render.gd")
const EM := preload("res://scripts/fp/audio/emitters.gd")
const DRIVE := preload("res://scripts/fp/drive/drive_feature.gd")
const DT := 1.0 / 60.0
const KMH := WS.M / 3.6
## The top of the head rides this multiple of the hips-to-head-bone distance above the hips
## (skull and hair over the head bone), as in seat_pose.gd.
const SKULL_HAIR := 1.40
## On a bicycle the hands sit within this many metres of their grips and the ankles of their
## pedals every frame (the pedals move between the IK's frame and the read: a few cm at speed),
## after the limbs' first frames easing in.
const BIKE_HAND_GAP := 0.06
const BIKE_FOOT_GAP := 0.10
const BIKE_EASE_IN := 15

var fails: Array[String] = []
var ctx: FpContext
var traffic: FpFeature
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
	traffic = K.make_feature(ctx, "traffic")
	var it := K.make_feature(ctx, "interact")
	drive = K.make_feature(ctx, "drive")
	K.check(
		fails, drive != null and drive.feature_id() == "drive", "the drive feature is registered"
	)
	if drive == null or traffic == null:
		K.finish(self, "FP_DRIVE_TEST", fails)
		return
	traffic.set("auto_step", false)
	traffic.set("ambient_enabled", false)
	drive.set_process(false)
	it.set_process(false)
	FeatureFlags.set_override("car_doors", false)
	FeatureFlags.set_override("carjack", false)
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
	_check_car_trample()
	_check_camera()
	_check_yield()
	_check_exit()
	_check_crash()
	_check_glance()
	_check_thin_wall()
	_check_shove()
	_check_keys()
	_check_hero_vs_cars()
	_check_pose_kinds()
	_check_jcb()
	await _check_backhoe_arm()
	await _check_backhoe_save()
	await _check_backhoe_pile_save()
	_check_heavy_motors()
	await _check_bike_ride()
	await _check_night_driving()
	await _check_ambient_driver()
	_check_site_machine()
	_check_car_vs_posts()
	_check_blocked_horns()
	_check_horn_reach()
	_check_horn_street()
	_check_body_mass()
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
	return traffic.get("vehicles")


## The longest straight road run; its first lane heads along it.
func _road() -> bool:
	var lg: LG = traffic.get("lanes")
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
	var keep := int(traffic.call("driven_id"))
	for c: VH.Car in _vh().cars.duplicate():
		if c.id != keep and c.role != VH.PLAYER:
			_vh().remove(c)
	ctx.collision.dynamic_boxes = []


## Every vehicle goes, the player's own included — a clean road, with the hero on foot (a fixture
## that asks traffic about one car it placed must not find a leftover parked beside them).
func _clear_all() -> void:
	for c: VH.Car in _vh().cars.duplicate():
		_vh().remove(c)
	ctx.collision.dynamic_boxes = []


func _drive(th: float, br: float, st: float, secs: float) -> void:
	for k in range(roundi(secs / DT)):
		drive.call("drive_step", th, br, st, 0.0, DT)
		if k % 2 == 0:
			traffic.call("step", DT * 2.0)
		ctx.player.update_view(DT)


func _car() -> VH.Car:
	return _vh().by_id.get(int(drive.get("car_id")))


# ------------------------------------------------------------------ checks


func _check_enter(it: FpFeature) -> void:
	_clear_others()
	var m: int = traffic.call("car_model_for", "drive-test")
	var c := _vh().make("car", "ambient", traffic.call("dims", m))
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
	var p := ctx.player
	p.carry(p.position, p.yaw, Vector3.ZERO, true)
	var held: Dictionary = drive.call("enter_target")
	p.release(true)
	K.check(fails, held.is_empty(), "none while a parkour move carries the hero")
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
		not _vh().by_id.has(c.id) and int(traffic.call("driven_id")) == car.id,
		"the ambient car it replaced is gone"
	)
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
	traffic.call("sync_visuals", DT)
	_drive(0.0, 0.0, 0.0, 1.5)
	traffic.call("sync_visuals", DT)
	var av := ctx.player.avatar
	var seat: Variant = traffic.call("seat_offset")
	var rig: Variant = av.get("rig")
	if seat == null or rig == null:
		K.check(
			fails, seat != null or _car().node == null, "the drawn car has a seat (%s)" % str(seat)
		)
		return
	_drive(0.0, 0.0, 0.0, DT)
	var car := _car()
	var pose: Object = drive.get("pose") as Object
	var sink: float = float(pose.get("sink")) if pose != null else 0.0
	var want := (
		Transform3D(Basis(Vector3.UP, car.yaw), car.pos)
		* ((seat as Vector3) - Vector3(0.0, sink, 0.0))
	)
	var hips: Vector3 = (rig as RefCounted).call("bone_world", "Hips")
	var st := str((rig as RefCounted).call("state"))
	var off := (hips - want) / WS.M
	K.check(
		fails,
		av.visible and off.length() < 0.05,
		(
			"the hero's hips are on the driver's seat, sunk into the cushion (%.2f m off)"
			% off.length()
		)
	)
	K.check(fails, st == "drive", "the hero sits with its hands on the wheel (%s)" % st)


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


## A body knocked down in the road, run over by the car the hero drives: traffic's hit_walker hears
## it as one car hit for the whole pass, never one a frame (car_body hands downed bodies over the
## same as anyone on their feet; traffic's reactions trample them where they lie).
func _check_car_trample() -> void:
	var wk: WK = traffic.get("walkers")
	K.quiet_walkers(traffic)
	var hits: Array = []
	var cb := func(_at: Vector3, cause: String, info: Dictionary) -> void:
		hits.append([cause, bool(info.get("down", false))])
	ctx.bus.person_hit.connect(cb)
	var car := _car()
	var fwd := Vector3(heading.x, 0.0, heading.y)
	var w := wk.make("ambient")
	w.extra = 0
	wk.stand(w, car.pos + fwd * 3.0 * WS.M, atan2(-fwd.x, -fwd.z))
	# Down in the road before the car, the fall and its slide over, lying there for seconds.
	traffic.call("hit_walker", w.id, car.pos + fwd * 2.0 * WS.M, fwd, 0.8, "car")
	for _k in range(roundi(0.6 / DT)):
		traffic.call("step", DT)
	var down := bool((traffic.get("reactions") as Object).call("is_down", w))
	K.check(fails, down, "car trample: fixture, they lie in the road")
	var gap := ((w.pos + w.vis_off) - _car().pos).dot(fwd) / WS.M
	print("FP_DRIVE_TEST: trample body %.1f m down the road" % gap)
	hits.clear()
	var most := 0
	for _k in range(roundi(3.0 / DT)):
		var n := hits.size()
		drive.call("drive_step", 1.0, 0.0, 0.0, 0.0, DT)
		traffic.call("step", DT)
		ctx.player.update_view(DT)
		most = maxi(most, hits.size() - n)
	K.check(
		fails,
		hits.size() == 1 and str(hits[0][0]) == "car",
		"car trample: the body run over hears one car hit (%d)" % hits.size()
	)
	K.check(
		fails,
		not hits.is_empty() and bool(hits[0][1]),
		"car trample: and it is the trample, them still down"
	)
	K.check(fails, most <= 1, "car trample: never one a frame (most %d)" % most)
	ctx.bus.person_hit.disconnect(cb)
	K.quiet_walkers(traffic)
	_drive(0.0, 1.0, 0.0, 1.5)


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
	var m: int = traffic.call("car_model_for", "yield-test")
	var ai := vh.make("car", "ambient", traffic.call("dims", m))
	ai.model = m
	vh.place(ai, lanes[0], 0.05)
	ai.path = lanes.slice(1)
	ai.v = WS.CAR_CITY
	ai.v0 = WS.CAR_CITY
	var gap := INF
	for _k in range(int(15.0 / (DT * 2.0))):
		traffic.call("step", DT * 2.0)
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
	var d: float = traffic.call("_body_dist", car, p.position)
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
		_vh().by_id.has(id) and not car.driven and int(traffic.call("driven_id")) == -1,
		"the car stays where it was left"
	)
	var blocks: Array = traffic.call("blockers_near", p.position, 0.2)
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
	return ctx.player.avatar.visible and st not in ["sit", "drive", "car_out"]


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


## Runs at a wall a hand's width thick across the road, from a standing start at full throttle:
## the car's substeps (car_body.gd SUBSTEP, at most half the body's width a move) can never step
## the body past so thin a wall whole, so the front never crosses its far face and the car stops
## against it, car_impact on the bus.
func _check_thin_wall() -> void:
	_clear_others()
	var car := _car()
	var model: MODEL = drive.get("model")
	var dims: Vector3 = drive.get("_dims")
	var a := Vector2(D.tx(road[0]), D.ty(road[0]))
	var start := Vector3(a.x, ctx.collision.walk_height(Vector3(a.x, 0.0, a.y)), a.y)
	drive.set("_pos", start)
	model.reset(atan2(heading.x, heading.y), dims.z)
	model.vel = Vector2.ZERO
	var h3 := Vector3(heading.x, 0.0, heading.y)
	var wall_c := start + h3 * (25.0 * WS.M)
	var thin := 0.005  # a 20 cm rail
	var ext := (
		Vector3(absf(heading.y), 0.0, absf(heading.x)) * WS.ROAD_HALF * 1.6
		+ Vector3(absf(heading.x), 0.0, absf(heading.y)) * thin
	)
	ctx.collision.add_test_box(
		AABB(
			Vector3(wall_c.x - ext.x, 0.0, wall_c.z - ext.z), Vector3(ext.x * 2.0, 0.2, ext.z * 2.0)
		)
	)
	impacts.clear()
	var far := (wall_c - start).dot(h3) + thin
	var deep := -INF
	for _k in range(roundi(6.0 / DT)):
		drive.call("drive_step", 1.0, 0.0, 0.0, 0.0, DT)
		var c := _car()
		deep = maxf(deep, (c.pos - start).dot(h3) + c.length * 0.5 - far)
	var v := float(model.speed())
	K.check(
		fails,
		deep < 0.05 * WS.M,
		"the car never crosses a 20 cm wall (front %.2f m past its far face)" % (deep / WS.M)
	)
	K.check(fails, absf(v) < 5.0 * KMH, "and stops against it (%.0f km/h)" % (v / KMH))
	var hit: Array = impacts[0] if not impacts.is_empty() else [Vector3.ZERO, INF, ""]
	K.check(
		fails,
		str(hit[2]) == "wall",
		"car_impact reports the thin wall (%s at %.0f km/h)" % [str(hit[2]), float(hit[1]) / KMH]
	)
	ctx.collision.clear_test_boxes()
	_drive(0.0, 1.0, 0.0, 1.0)


## Rams the street's posts at 30 km/h, throttle held, each as the collision world holds it (the
## road tiles' colliders meta: E's corner signal poles and pedestrian signals, G1's dressing sign
## poles, which the view dresses in street view only, so it goes there first, as the game does):
## the car's box never sinks into the post's solid part (anything above the car's step; a signal
## pole's plinth is a kerb it mounts), never gets past it and rests against it, and the post still
## stands. Runs last before teardown, since street view rebuilds the town.
func _check_car_vs_posts() -> void:
	ctx.view.set_fp_mode(true)
	if ctx.view.has_method("flush_rebuild_queue"):
		ctx.view.call("flush_rebuild_queue")
	ctx.collision.rebuild_all()
	_clear_all()
	var c := _stopped_car(traffic.call("car_model_for", "posts"))
	_beside(c, OBB.side_axis(c.yaw), -0.6)
	K.check(fails, drive.call("enter") == true, "posts: the hero gets in")
	var found := _post_targets()
	for kind: String in ["signal pole", "ped signal", "sign"]:
		var cands: Array = found.get(kind, [])
		K.check(
			fails, not cands.is_empty(), "fixture: a %s by the road (%d)" % [kind, cands.size()]
		)
		if not cands.is_empty():
			_ram_post(kind, cands)
	_drive(0.0, 1.0, 0.0, 1.0)
	K.check(fails, drive.call("leave") == true, "posts: and out again")
	_clear_all()


## The road tiles' post colliders in world space, kind -> [{"tile", "c", "shapes": [[c, r, top]]}]:
## a signal pole's plinth and shaft share their spot; a "signal" thinner than 0.1 m is a
## pedestrian signal, and one under 5 cm a stop sign.
func _post_targets() -> Dictionary:
	var out := {}
	for i: int in ctx.sim.active:
		var holder := ctx.view.tile_holder(i) if ctx.sim.kind[i] == D.ROAD else null
		if holder == null:
			continue
		var spots := {}
		for e: Variant in holder.get_meta("colliders", []):
			var d: Dictionary = e if typeof(e) == TYPE_DICTIONARY else {}
			var kind := str(d.get("kind", ""))
			if str(d.get("shape", "")) != "cyl" or not kind in ["signal", "sign"]:
				continue
			if bool(d.get("down", false)):
				continue
			var p: Vector3 = holder.transform * (d.get("pos", Vector3.ZERO) as Vector3)
			var c := Vector2(p.x, p.z)
			var key := "%s:%.4f:%.4f" % [kind, c.x, c.y]
			if not spots.has(key):
				spots[key] = {"tile": i, "c": c, "shapes": [], "kind": kind}
			var top := p.y + float(d.get("h", 0.0))
			(spots[key]["shapes"] as Array).append([c, float(d.get("r", 0.0)), top])
		for t: Dictionary in spots.values():
			var name := str(t["kind"])
			if name == "signal":
				var widest := 0.0
				for s: Array in t["shapes"]:
					widest = maxf(widest, float(s[1]))
				name = "signal pole" if widest >= 0.1 * WS.M else "ped signal"
				if widest < 0.05 * WS.M:
					name = "stop sign"
			if not out.has(name):
				out[name] = []
			(out[name] as Array).append(t)
	return out


## Drives at the first post of cands with a clear straight run in from its tile's middle.
func _ram_post(kind: String, cands: Array) -> void:
	var model: MODEL = drive.get("model")
	var dims: Vector3 = drive.get("_dims")
	var h := Vector2(dims.x, dims.z * 0.5)
	for t: Dictionary in cands:
		var q: Vector2 = t["c"]
		var d := (q - Vector2(D.tx(int(t["tile"])), D.ty(int(t["tile"])))).normalized()
		var start := q - d * (h.y + 8.0 * WS.M)
		if d == Vector2.ZERO or not _run_clear(start, q, d, h, dims.y):
			continue
		drive.set("_pos", Vector3(start.x, ctx.collision.walk_height(_v3(start)), start.y))
		model.reset(atan2(d.x, d.y), dims.z)
		model.vel = d * (30.0 * KMH)
		var deep := 0.0
		var past := -INF
		var touched := false
		for _k in range(roundi(3.0 / DT)):
			drive.call("drive_step", 1.0, 0.0, 0.0, 0.0, DT)
			var p: Vector3 = drive.get("_pos")
			var c := Vector2(p.x, p.z)
			var u := OBB.side_axis(model.yaw)
			var v := OBB.heading(model.yaw)
			for s: Array in t["shapes"]:
				if float(s[2]) <= p.y + WS.STEP_HEIGHT:
					continue
				var hit := OBB.box_circle(c, u, v, h, s[0], float(s[1]))
				if not hit.is_empty():
					deep = maxf(deep, float(hit[1]))
				var near := OBB.box_circle(c, u, v, h, s[0], float(s[1]) + 0.05 * WS.M)
				touched = touched or not near.is_empty()
			past = maxf(past, (c - q).dot(d))
		K.check(
			fails,
			deep < 0.001 * WS.M,
			"the car never sinks into the %s at 30 km/h (%.2f mm)" % [kind, deep / WS.M * 1000.0]
		)
		K.check(fails, touched, "the car reaches the %s (within 5 cm)" % kind)
		K.check(fails, past < 0.0, "and never gets past it (%.2f m)" % (past / WS.M))
		var vk := absf(float(model.speed())) / KMH
		K.check(fails, vk < 5.0, "and rests against the %s (%.1f km/h)" % [kind, vk])
		K.check(fails, _post_stands(t), "the %s still stands in the collision world" % kind)
		return
	K.check(fails, false, "fixture: a clear run at a %s" % kind)


## True when the car's box, heading d, meets nothing but the post on its way from start to just
## short of q (the gathered walls, posts and undrivable ground, sampled every metre).
func _run_clear(start: Vector2, q: Vector2, d: Vector2, h: Vector2, height: float) -> bool:
	var yaw := atan2(d.x, d.y)
	var n := int((q - start).dot(d) / WS.M) - 3
	for k in range(maxi(n, 1)):
		var c := start + d * (float(k) * WS.M)
		var feet := ctx.collision.walk_height(_v3(c))
		if is_nan(feet):
			return false
		var obs := BC.gather(ctx.collision, c, h.length() + 0.05, feet, height)
		if not BC.contacts(ctx.collision, obs, c, yaw, h, feet).is_empty():
			return false
	return true


## Whether every one of post t's cylinders is still among its tile's collision cylinders.
func _post_stands(t: Dictionary) -> bool:
	var cy := ctx.collision.cylinders(int(t["tile"]))
	for s: Array in t["shapes"]:
		var ok := false
		for k in range(0, cy.size(), 4):
			if Vector2(cy[k], cy[k + 1]).distance_to(s[0]) < 1e-4 and absf(cy[k + 2] - s[1]) < 1e-4:
				ok = true
		if not ok:
			return false
	return true


func _v3(p: Vector2) -> Vector3:
	return Vector3(p.x, 0.0, p.y)


## Runs into the side of a lane car crawling along at 25 km/h: it slides off its lane, braking,
## the player's car loses speed, car_impact reports a car and the bodies never overlap. Once the
## player backs off and it has waited, its driver steers it back onto the lane and drives on.
func _check_shove() -> void:
	_clear_others()
	var vh := _vh()
	var model: MODEL = drive.get("model")
	var dims: Vector3 = drive.get("_dims")
	var m: int = traffic.call("car_model_for", "shove-test")
	var ai := vh.make("car", "ambient", traffic.call("dims", m))
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
		traffic.call("step", DT * 2.0)
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
		traffic.call("step", DT * 2.0)
		if ai.vis_off == Vector3.ZERO and ai.vis_yaw == 0.0 and ai.stun_t <= 0.0:
			back = true
			break
	K.check(
		fails,
		back and not ai.dead and not bool(traffic.get("shoves").call("is_shoved", ai)),
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
	var rig := (
		InputMap.has_action("backhoe_arm_up")
		and InputMap.has_action("backhoe_arm_down")
		and InputMap.has_action("backhoe_bucket_curl")
		and InputMap.has_action("backhoe_bucket_dump")
	)
	K.check(fails, rig, "the backhoe's arm keys are bound (Y U I O)")
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


# ------------------------------------------------------- the hero against cars


## The hero on foot against cars (vehicles.gd _hero_contact), one scene after another: a stopped
## car's flank they are stood into eases them out; a car knocked off its lane (shoves.gd never
## sees the hero) slides into them at walking pace and carries them clear of its body instead of
## through it; their own car knocked while they stand beside it does the same; and hit_by_cars
## keeps its meaning: a car too close to stop runs them down exactly once (hero_hit) while they
## are hittable, and stops short of them without touching when they are not (no health feature
## in this test, so traffic never makes them hittable). Every check steps traffic itself: the
## player never moves alone.
func _check_hero_vs_cars() -> void:
	var pc := _car()
	K.check(fails, drive.call("exit") == true, "hero-vs-cars: the hero gets out")
	_clear_others()
	var vh := _vh()
	var sh: Object = traffic.get("shoves")
	var hits: Array = []
	var cb := func(_at: Vector3, kind: String, _s: float, _push: Vector3) -> void: hits.append(kind)
	ctx.bus.hero_hit.connect(cb)
	var m: int = traffic.call("car_model_for", "hero-vs-cars")
	var ai := _stopped_car(m)
	var q := Vector2(ai.pos.x, ai.pos.z)
	var u := OBB.side_axis(ai.yaw)
	if (Vector2(roundf(q.x), roundf(q.y)) - q).dot(u) < 0.0:
		u = -u
	_hero_stopped_flank(ai, u)
	_hero_knocked_flank(sh, ai, u, q, hits)
	_hero_own_car(sh, pc, hits)
	vh.remove(ai)
	var fi := _hero_run_down(vh, m, hits)
	vh.remove(fi)
	var sf := _hero_stops_short(m, hits)
	ctx.bus.hero_hit.disconnect(cb)
	for c in [ai, fi, sf, pc]:
		if c != null and _vh().by_id.has(c.id):
			_vh().remove(c)
	_clear_others()


## A stopped ambient car at the usual spot on the first lane.
func _stopped_car(m: int) -> VH.Car:
	var vh := _vh()
	var c := vh.make("car", "ambient", traffic.call("dims", m))
	c.model = m
	vh.place(c, lanes[0], 0.5)
	c.path = lanes.slice(1)
	c.v = 0.0
	c.v0 = 0.0
	return c


## Stood 5 cm into a stopped car's flank: one step of traffic eases the hero out.
func _hero_stopped_flank(ai: VH.Car, u: Vector2) -> void:
	_beside(ai, u, 0.05)
	K.check(
		fails,
		_hero_depth(ai) > 0.02 * WS.M,
		(
			"stood into a stopped car: the hero starts inside its flank (%.2f m)"
			% (_hero_depth(ai) / WS.M)
		)
	)
	traffic.call("step", DT * 2.0)
	K.check(
		fails,
		_hero_depth(ai) <= 0.01 * WS.M,
		"a stopped car eases the hero out of its flank (%.3f m left)" % (_hero_depth(ai) / WS.M)
	)


## A lane car knocked toward the hero slides its flank into them: carried clear of the body,
## never deeper inside it than one step's slide, nobody run down, and clear once it steers back.
func _hero_knocked_flank(sh: Object, ai: VH.Car, u: Vector2, q: Vector2, hits: Array) -> void:
	hits.clear()
	_beside(ai, u, 0.0)
	var side0 := (Vector2(ctx.player.position.x, ctx.player.position.z) - q).dot(u)
	var deep := 0.0
	sh.call("bump", ai, u * (1.5 * WS.M), q)
	for _k in range(roundi(1.5 / (DT * 2.0))):
		traffic.call("step", DT * 2.0)
		deep = maxf(deep, _hero_depth(ai))
	K.check(
		fails,
		deep > 0.0 and deep <= 0.075 * WS.M,
		(
			"a car knocked into the hero carries them clear, never deeper than a step (%.2f m)"
			% (deep / WS.M)
		)
	)
	var side := (Vector2(ctx.player.position.x, ctx.player.position.z) - q).dot(u)
	K.check(
		fails,
		side - side0 > 0.1 * WS.M and hits.is_empty(),
		"pushed along %.2f m by the flank, nobody run down" % ((side - side0) / WS.M)
	)
	var back := false
	for _k in range(roundi(6.0 / (DT * 2.0))):
		traffic.call("step", DT * 2.0)
		if _hero_depth(ai) > 0.02 * WS.M:
			continue
		if not bool(sh.call("is_shoved", ai)):
			back = true
			break
	K.check(
		fails,
		back and _hero_depth(ai) <= 0.01 * WS.M,
		"once it steers back the hero stands clear of it (%.3f m in)" % (_hero_depth(ai) / WS.M)
	)


## Their own car, knocked while they stand beside it, slides the same way and never passes
## through them.
func _hero_own_car(sh: Object, pc: VH.Car, hits: Array) -> void:
	if pc == null or not _vh().by_id.has(pc.id):
		return
	hits.clear()
	var qp := Vector2(pc.pos.x, pc.pos.z)
	var up := OBB.side_axis(pc.yaw)
	if (Vector2(roundf(qp.x), roundf(qp.y)) - qp).dot(up) < 0.0:
		up = -up
	_beside(pc, up, 0.0)
	var side0 := (Vector2(ctx.player.position.x, ctx.player.position.z) - qp).dot(up)
	var deep := 0.0
	sh.call("bump", pc, up * (1.0 * WS.M), qp)
	for _k in range(roundi(1.5 / (DT * 2.0))):
		traffic.call("step", DT * 2.0)
		deep = maxf(deep, _hero_depth(pc))
	var side := (Vector2(ctx.player.position.x, ctx.player.position.z) - qp).dot(up)
	K.check(
		fails,
		deep > 0.0 and deep <= 0.075 * WS.M and side - side0 > 0.05 * WS.M and hits.is_empty(),
		(
			"their own car knocked into them: carried clear (%.2f m), never inside (%.2f m)"
			% [(side - side0) / WS.M, deep / WS.M]
		)
	)


## A car too close to stop at HIT_MIN and more, the hero hittable (vehicles.step itself: traffic
## would not make them hittable without the health feature): it runs them down once, hero_hit,
## and never goes into their body. The car it made, for the caller to take away.
func _hero_run_down(vh: VH, m: int, hits: Array) -> VH.Car:
	hits.clear()
	var fi := _closing_car(m)
	var stood := ctx.player.position
	vh.player_pos = stood
	vh.player_hittable = true
	var deep := 0.0
	for _k in range(roundi(1.5 / (DT * 2.0))):
		vh.step(DT * 2.0)
		vh.player_pos = ctx.player.position
		vh.player_hittable = true
		deep = maxf(deep, _hero_depth(fi))
		if not hits.is_empty():
			break
	K.check(
		fails,
		hits.size() == 1 and str(hits[0]) == "car",
		"a car too close to stop runs the hittable hero down, once (%s)" % str(hits)
	)
	K.check(
		fails,
		deep <= 0.075 * WS.M and (ctx.player.position - stood).length() <= 0.01 * WS.M,
		"it comes up to their body, not into it (%.2f m), the hero left standing" % (deep / WS.M)
	)
	return fi


## The same car at the same closing speed, the hero not hittable (traffic's rule without the
## health feature): it stops short of them, never touching. The car it made.
func _hero_stops_short(m: int, hits: Array) -> VH.Car:
	hits.clear()
	var sf := _closing_car(m)
	var deep := 0.0
	for _k in range(roundi(1.5 / (DT * 2.0))):
		traffic.call("step", DT * 2.0)
		deep = maxf(deep, _hero_depth(sf))
	K.check(
		fails,
		hits.is_empty() and deep <= 0.0 and sf.v < 1.0 * WS.M,
		(
			"not hittable, the car stops short without touching (%.3f m in, %.1f m/s left)"
			% [deep / WS.M, sf.v / WS.M]
		)
	)
	return sf


## An ambient car of model m at the usual spot, closing on the lane at 8 m/s with the hero stood
## 1.2 m beyond its nose.
func _closing_car(m: int) -> VH.Car:
	var vh := _vh()
	var c := _stopped_car(m)
	c.v = 8.0 * WS.M
	c.v0 = 8.0 * WS.M
	var head := OBB.heading(c.yaw)
	var ahead := Vector2(c.pos.x, c.pos.z) + head * (c.length * 0.5 + WS.PLAYER_RADIUS + 1.2 * WS.M)
	ctx.player.teleport(
		Vector3(ahead.x, ctx.collision.walk_height(Vector3(ahead.x, 0.0, ahead.y)), ahead.y), 0.0
	)
	return c


## The hero stood `into` metres inside car c's flank, on the side of it u points at.
func _beside(c: VH.Car, u: Vector2, into: float) -> void:
	var q := Vector2(c.pos.x + c.vis_off.x, c.pos.z + c.vis_off.z)
	var p := q + u * (c.half_w + WS.PLAYER_RADIUS - into * WS.M)
	ctx.player.teleport(Vector3(p.x, ctx.collision.walk_height(Vector3(p.x, 0.0, p.y)), p.y), 0.0)


## Depth of the hero's circle in car c's drawn body (0 when clear of it).
func _hero_depth(c: VH.Car) -> float:
	var p := ctx.player.position
	var q := c.pos + c.vis_off
	var y := c.yaw + c.vis_yaw
	var k := OBB.box_circle(
		Vector2(q.x, q.z),
		OBB.side_axis(y),
		OBB.heading(y),
		Vector2(c.half_w, c.length * 0.5),
		Vector2(p.x, p.z),
		WS.PLAYER_RADIUS
	)
	return float(k[1]) if not k.is_empty() else 0.0


# ------------------------------------------------------------------ seated pose per body


## One drivable body after another (sedan, hatchback, SUV, coupé, taxi, the vans, pickup, backhoe
## and the working bodies of the heavy_motors flag): the hero gets in, settles, and the pose is
## measured against the body's own driver markers (seat_pose.gd, asset_paths.gd).
func _check_pose_kinds() -> void:
	var render: Variant = traffic.get("render")
	for body: String in [
		"sedan_blue",
		"hatchback_red",
		"suv_grey",
		"coupe_navy",
		"taxi",
		"van_white",
		"van_minibus",
		"pickup_red",
		"backhoe_yellow",
		"bus",
		"truck",
		"garbage_truck"
	]:
		_pose_in_body(render, body)


## One body: out of the last car, a fresh car of that body beside the hero, in, settled, measured
## (then the car is taken away again, the hero left on foot).
func _pose_in_body(render: Variant, body: String) -> void:
	_clear_others()
	_out_and_away(body)
	var m: int = render.call("model_for", AP.VEHICLES_V2_DIR + body + ".glb", WS.VEHICLE_V2_SCALE)
	K.check(fails, m >= 0, "%s: in the model library" % body)
	if m < 0:
		return
	var c := _vh().make("car", "ambient", traffic.call("dims", m))
	c.model = m
	_vh().place(c, lanes[0], 0.35)
	c.v = 0.0
	ctx.player.teleport(
		c.pos + Basis(Vector3.UP, c.yaw) * Vector3(c.half_w + 0.6 * WS.M, 0.0, 0.0), 0.0
	)
	K.check(fails, drive.call("enter") == true, "%s: the hero gets in" % body)
	if not bool(drive.get("active")):
		_vh().remove(c)
		return
	K.check(fails, _car().model == m, "%s: the hero drives that body (model %d)" % [body, m])
	traffic.call("sync_visuals", DT)
	_drive(0.0, 0.0, 0.0, 1.6)
	traffic.call("sync_visuals", DT)
	_pose_check(body)
	_out_and_away(body)


## Out of the car, which is then taken away: a car left behind stays "your car" and would be the
## nearest one to get into again.
func _out_and_away(body: String) -> void:
	if not bool(drive.get("active")):
		return
	var pc := _car()
	K.check(fails, drive.call("exit") == true, "%s: the hero gets out" % body)
	if pc != null and _vh().by_id.has(pc.id):
		_vh().remove(pc)


## The settled pose measured against the body's own markers: the hips on the seat sunk into the
## cushion, the top of the head (skull and hair, SKULL_HAIR as in seat_pose.gd) under the roof
## line, and the limb IK's goals held on the pedal and wheel markers (the modifiers themselves
## only run when a frame is drawn, which headless never does, so the limbs landing on them is
## for the windowed screenshots to show).
func _pose_check(body: String) -> void:
	var car := _car()
	var node: Node3D = car.node
	var seat: Variant = traffic.call("seat_offset")
	var rig: Variant = ctx.player.avatar.get("rig")
	if node == null or seat == null or rig == null:
		K.check(fails, node != null, "%s: the body is drawn, to measure the pose against it" % body)
		return
	var pose: Object = drive.get("pose") as Object
	var sink: float = float(pose.get("sink")) if pose != null else 0.0
	var tf := Transform3D(Basis(Vector3.UP, car.yaw), car.pos)
	var hips: Vector3 = (rig as RefCounted).call("bone_world", "Hips")
	var hip_off := (hips - tf * ((seat as Vector3) - Vector3(0.0, sink, 0.0))).length() / WS.M
	K.check(
		fails,
		hip_off < 0.05,
		"%s: hips on the sunk seat (%.2f m off, sunk %.2f m)" % [body, hip_off, sink / WS.M]
	)
	var seat_n := node.find_child("Seat_Driver", true, false) as Node3D
	if seat_n == null:
		K.check(fails, false, "%s: the body carries Seat_Driver" % body)
		return
	var node_basis := node.global_transform.basis.inverse()
	var base := seat_n.global_position
	var limbs := {
		"LeftHand": "Wheel_L", "RightHand": "Wheel_R", "LeftFoot": "Pedal_L", "RightFoot": "Pedal_R"
	}
	var limbs_rig: Variant = (rig as RefCounted).get("limbs")
	var goals: Array = (limbs_rig as Object).get("targets")
	var weights: Array = (limbs_rig as Object).get("weights")
	var i := 0
	for bone: String in limbs:
		var mk := node.find_child(limbs[bone], true, false) as Node3D
		if mk != null:
			var target := tf * ((seat as Vector3) + node_basis * (mk.global_position - base))
			var held: Vector3 = (goals[i] as Node3D).global_position
			var off := (held - target).length() / WS.M
			K.check(
				fails,
				off < 0.02 and float(weights[i]) > 0.9,
				(
					"%s: %s held on %s (%.2f m off, weight %.2f)"
					% [body, bone, limbs[bone], off, weights[i]]
				)
			)
		else:
			K.check(fails, false, "%s: the body carries %s" % [body, limbs[bone]])
		i += 1
	var roof := node.find_child("Cab_Roof", true, false) as Node3D
	if roof == null:
		K.check(fails, false, "%s: the body carries Cab_Roof" % body)
		return
	var head: Vector3 = (rig as RefCounted).call("bone_world", "Head")
	var top := hips.y + (head.y - hips.y) * SKULL_HAIR
	var over := (
		(top - (tf * ((seat as Vector3) + node_basis * (roof.global_position - base))).y) / WS.M
	)
	K.check(
		fails,
		over < 0.02,
		"%s: the head clears the roof line (%.2f m over, sunk %.2f m)" % [body, over, sink / WS.M]
	)


## The backhoe loader (the jcb flag): a work machine, not a highway one. Its model is the size the
## game draws it at; traffic gives a car of that model a slower, heavier drive profile (topping out
## around 22 km/h at half a car's rate of accel) and its own mass; the parking fill parks backhoes
## at a rare share of curb slots (jcb_in forced to 1 here, so every filled slot takes one) where
## the hero can get in and drive one away; and with the flag off none park and no car of that
## model gets the profile. The seated pose against its cab markers is _check_pose_kinds' business.
func _check_jcb() -> void:
	var vh := _vh()
	var m: int = traffic.call("jcb_model")
	K.check(fails, m >= 0, "jcb: the backhoe is in the model library")
	if m < 0:
		return
	var render: Variant = traffic.get("render")
	var mo: Variant = (render as Object).call("model", m)
	var size: Vector3 = mo.size if mo != null else Vector3.ZERO
	K.check(
		fails,
		absf(size.z / WS.M - 5.6) < 0.2 and absf(size.x / WS.M - 2.3) < 0.2,
		"jcb: a backhoe's size, about 5.6 x 2.3 m (%.1f x %.1f)" % [size.z / WS.M, size.x / WS.M]
	)

	# The profile: slow and heavy, on the drive model itself.
	var prof: Dictionary = traffic.call("drive_profile", _of_model(m).id)
	var dm := MODEL.new()
	dm.reset(0.0, 0.28, prof)
	_run(dm, 1.0, 0.0, 0.0, 0.0, "asphalt", 10.0)
	var car := MODEL.new()
	car.reset(0.0, 0.28, {})
	_run(car, 1.0, 0.0, 0.0, 0.0, "asphalt", 10.0)
	K.check(
		fails,
		dm.speed() > 15.0 * KMH and dm.speed() < 25.0 * KMH,
		"jcb: it tops out around 22 km/h (%.0f km/h)" % (dm.speed() / KMH)
	)
	K.check(
		fails,
		dm.speed() < car.speed() * 0.35,
		"jcb: well short of a car's 108 km/h (%.0f km/h)" % (dm.speed() / KMH)
	)
	var dm2 := MODEL.new()
	dm2.reset(0.0, 0.28, prof)
	_run(dm2, 1.0, 0.0, 0.0, 0.0, "asphalt", 2.0)
	var car2 := MODEL.new()
	car2.reset(0.0, 0.28, {})
	_run(car2, 1.0, 0.0, 0.0, 0.0, "asphalt", 2.0)
	K.check(
		fails,
		dm2.speed() < car2.speed() * 0.6,
		(
			"jcb: and gathers speed at half a car's rate (%.0f of %.0f km/h)"
			% [dm2.speed() / KMH, car2.speed() / KMH]
		)
	)
	K.check(
		fails,
		traffic.call("drive_profile", _of_model(-1).id).is_empty(),
		"jcb: a car keeps a car's profile"
	)
	var massc := _of_model(m)
	massc.mass = 5.5
	K.check(
		fails, absf(SHOVES.mass_of(massc) - 5.5) < 1e-6, "jcb: its mass is five and a half sedans"
	)

	# The parking fill: backhoes at the curb (every filled slot, with the share forced), where
	# the hero can get one and drive it away with the slow profile.
	var amb: Object = traffic.get("ambient")
	amb.set("jcb_in", 1)
	amb.set("jcb_model", func() -> int: return m)
	_clear_others()
	amb.call("fill_parking")
	var parked := 0
	var backhoe: VH.Car = null
	for c: VH.Car in vh.cars:
		if c.parked:
			parked += 1
		if c.label == "a backhoe" and c.slot_tile >= 0:
			backhoe = c
	K.check(
		fails,
		parked > 0 and backhoe != null and absf(backhoe.mass - 5.5) < 1e-6,
		"jcb: backhoes park at the curb, carrying their mass (%d parked)" % parked
	)
	if backhoe != null:
		var side := OBB.side_axis(backhoe.yaw)
		_beside(backhoe, side, -0.6)
		var t: Dictionary = drive.call("enter_target")
		K.check(
			fails,
			int(t.get("id", -1)) == backhoe.id and str(t.get("label", "")) == "the car",
			"jcb: a parked backhoe is the get-in target: %s" % str(t)
		)
		K.check(fails, drive.call("enter") == true, "jcb: the hero gets in")
		_clear_others()
		K.check(
			fails,
			absf(float((drive.get("model") as MODEL).top) / WS.M - 6.1) < 0.05,
			(
				"jcb: and drives it with the slow profile (%.1f m/s top)"
				% (float((drive.get("model") as MODEL).top) / WS.M)
			)
		)
		_drive(1.0, 0.0, 0.0, 1.5)
		var v := float((drive.get("model") as MODEL).speed())
		K.check(
			fails,
			v > 8.0 * KMH and v < 20.0 * KMH,
			"jcb: it lumbers up to speed (%.0f km/h)" % (v / KMH)
		)
		_drive(0.0, 1.0, 0.0, 2.0)
		K.check(fails, drive.call("exit") == true, "jcb: and the hero gets back out")

	# The flag off: no backhoe parks, none gets the profile.
	FeatureFlags.set_override("jcb", false)
	amb.set("jcb_model", Callable(traffic, "jcb_model"))
	_clear_others()
	amb.call("fill_parking")
	var none := 0
	for c: VH.Car in vh.cars:
		if c.label == "a backhoe":
			none += 1
	K.check(
		fails,
		(
			none == 0
			and int(traffic.call("jcb_model")) == -1
			and traffic.call("drive_profile", _of_model(m).id).is_empty()
		),
		"jcb: the flag off parks no backhoe and gives no profile"
	)
	FeatureFlags.set_override("jcb", true)
	amb.set("jcb_in", 37)
	amb.set("jcb_model", Callable(traffic, "jcb_model"))
	_clear_others()


## The backhoe's arm rig (drive/backhoe.gd, the backhoe_arm flag): the full model carries the
## loader arm and bucket as their own nodes, at the wheel Y raises the boom (the bucket hinge
## riding up with it), U folds it back, I curls the bucket in and O tips it out; a dig (tip out,
## then curl in, arm low) grows a dirt pile in front of the machine, and only over a construction
## site; the flag off holds the rig where it stands; and the pile stays once the hero is out.
## The backhoe's model loads in the background, so its node is waited for first (as the ambient
## driver check waits for its character pool).
func _check_backhoe_arm() -> void:
	var amb: Object = traffic.get("ambient")
	var m: int = traffic.call("jcb_model")
	K.check(fails, m >= 0, "arm: fixture, the backhoe model is loaded")
	if m < 0:
		return
	amb.set("jcb_in", 1)
	amb.set("jcb_model", func() -> int: return m)
	_clear_others()
	amb.call("fill_parking")
	var backhoe: VH.Car = null
	for c: VH.Car in _vh().cars:
		if c.label == "a backhoe" and c.slot_tile >= 0:
			backhoe = c
	K.check(fails, backhoe != null, "arm: fixture, a backhoe parked at the kerb")
	if backhoe == null:
		_clear_others()
		return
	_beside(backhoe, OBB.side_axis(backhoe.yaw), -0.6)
	K.check(fails, drive.call("enter") == true, "arm: the hero gets in")
	var node: Node3D = null
	for _k in range(120):
		traffic.call("sync_visuals", DT)
		ctx.player.update_view(DT)
		node = _car().node
		if node != null:
			break
		await process_frame
	var boom := node.find_child("Arm_Boom", true, false) as Node3D
	var bucket := node.find_child("Arm_Bucket", true, false) as Node3D
	K.check(
		fails,
		node != null and boom != null and bucket != null,
		"arm: the full model carries the rig nodes (Arm_Boom, Arm_Bucket)"
	)
	if node == null or boom == null or bucket == null:
		drive.call("exit", true)
		_clear_others()
		return
	var arm: Object = drive.get("arm")
	_clear_others()

	# Y raises the boom: the bucket hinge (the boom's far end) rides up with it. No throttle or
	# brake: brake from rest would creep the machine backwards off its spot.
	var y0 := bucket.global_position.y
	Input.action_press("backhoe_arm_up")
	_drive(0.0, 0.0, 0.0, 1.0)
	Input.action_release("backhoe_arm_up")
	K.check(
		fails,
		float(arm.get("boom")) > deg_to_rad(10.0) and bucket.global_position.y > y0 + 0.1 * WS.M,
		(
			"arm: Y raises the boom, the bucket riding up with it (%.0f deg)"
			% rad_to_deg(float(arm.get("boom")))
		)
	)

	# U folds it back and I curls the bucket in. The arm-key row shows while the hero is at the
	# wheel (the chip's own line is set by _process, so that runs it).
	drive.call("_process", DT)
	var hud: Variant = drive.get("hud")
	K.check(
		fails,
		hud == null or bool(hud.call("rig_shown")),
		"arm: the arm-key row shows at the backhoe's wheel"
	)
	Input.action_press("backhoe_arm_down")
	_drive(0.0, 0.0, 0.0, 2.0)
	Input.action_release("backhoe_arm_down")
	K.check(fails, float(arm.get("boom")) < 0.05, "arm: U folds the boom back down")
	Input.action_press("backhoe_bucket_curl")
	_drive(0.0, 0.0, 0.0, 1.0)
	Input.action_release("backhoe_bucket_curl")
	K.check(
		fails,
		float(arm.get("bucket")) > deg_to_rad(10.0),
		"arm: I curls the bucket in (%.0f deg)" % rad_to_deg(float(arm.get("bucket")))
	)

	# A dig at the kerb (no site there) grows nothing.
	var c := _car()
	var fwd := OBB.heading(c.yaw)
	var spot := c.pos + Vector3(fwd.x, 0.0, fwd.y) * 2.2 * WS.M
	Input.action_press("backhoe_bucket_dump")
	_drive(0.0, 0.0, 0.0, 2.5)
	Input.action_release("backhoe_bucket_dump")
	Input.action_press("backhoe_bucket_curl")
	_drive(0.0, 0.0, 0.0, 2.5)
	Input.action_release("backhoe_bucket_curl")
	K.check(
		fails,
		float(arm.get("pile")) < 0.01,
		"arm: scooping at the kerb digs nothing (no site there)"
	)

	# The same scoop over a construction site grows the pile, in front of the machine.
	var tile := ctx.collision.tile_at(spot)
	ctx.sim.sites[tile] = {"id": 9002, "i": tile, "x": D.tx(tile), "y": D.ty(tile), "type": "build"}
	Input.action_press("backhoe_bucket_dump")
	_drive(0.0, 0.0, 0.0, 2.5)
	Input.action_release("backhoe_bucket_dump")
	Input.action_press("backhoe_bucket_curl")
	_drive(0.0, 0.0, 0.0, 2.5)
	Input.action_release("backhoe_bucket_curl")
	var dirt := (node.get_parent() as Node).find_child("DirtPile", true, false) as MeshInstance3D
	K.check(
		fails,
		float(arm.get("pile")) > 1.0,
		"arm: a scoop at the site grows the dirt pile (%.1f)" % float(arm.get("pile"))
	)
	K.check(
		fails,
		dirt != null and dirt.global_position.distance_to(spot) < 3.0 * WS.M,
		"arm: the pile stands in front of the machine"
	)
	ctx.sim.sites.erase(tile)

	# The flag off: the rig holds where it stands, keys or not.
	Input.action_press("backhoe_arm_up")
	_drive(0.0, 0.0, 0.0, 0.5)
	Input.action_release("backhoe_arm_up")
	var held := float(arm.get("boom"))
	FeatureFlags.set_override("backhoe_arm", false)
	Input.action_press("backhoe_arm_down")
	_drive(0.0, 0.0, 0.0, 1.0)
	Input.action_release("backhoe_arm_down")
	K.check(
		fails,
		absf(float(arm.get("boom")) - held) < 1e-4,
		"arm: the flag off holds the rig where it stands"
	)
	FeatureFlags.set_override("backhoe_arm", true)

	# Out: the pile stays put and the arm-key row hides.
	drive.call("exit", true)
	K.check(
		fails, dirt != null and is_instance_valid(dirt), "arm: the pile stays once the hero is out"
	)
	K.check(
		fails,
		hud == null or not bool(hud.call("rig_shown")),
		"arm: the arm-key row hides once the hero is out"
	)
	amb.set("jcb_in", 37)
	amb.set("jcb_model", Callable(traffic, "jcb_model"))
	_clear_others()


## A backhoe at the kerb with the hero at its wheel and its node drawn (the parking fill forced
## to backhoes, every other car cleared): [the car, its node, its kerb slot (kept: the car's own
## slot fields are released when the hero gets in)], or [] when the fixture fails.
func _backhoe_fixture() -> Array:
	var amb: Object = traffic.get("ambient")
	var m: int = traffic.call("jcb_model")
	if m < 0:
		K.check(fails, false, "arm save: fixture, the backhoe model is loaded")
		return []
	amb.set("jcb_in", 1)
	amb.set("jcb_model", func() -> int: return m)
	_clear_all()
	(drive.get("arm") as Object).call("clear")
	K.check(
		fails,
		(drive.call("to_dict") as Dictionary).is_empty(),
		"arm save: nothing posed anywhere, the drive save is empty"
	)
	amb.call("fill_parking")
	var backhoe: VH.Car = null
	for c: VH.Car in _vh().cars:
		if c.label == "a backhoe" and c.slot_tile >= 0:
			backhoe = c
	K.check(fails, backhoe != null, "arm save: fixture, a backhoe parked at the kerb")
	if backhoe == null:
		return []
	var slot := Vector2i(backhoe.slot_tile, backhoe.slot_k)
	_beside(backhoe, OBB.side_axis(backhoe.yaw), -0.6)
	if not drive.call("enter"):
		K.check(fails, false, "arm save: fixture, the hero gets in")
		return []
	var node: Node3D = null
	for _k in range(120):
		traffic.call("sync_visuals", DT)
		ctx.player.update_view(DT)
		node = _car().node
		if node != null:
			break
		await process_frame
	K.check(fails, node != null, "arm save: fixture, the machine is drawn")
	if node == null:
		drive.call("exit", true)
		return []
	return [backhoe, node, slot]


## Leaves the machine mid-dig -- a pile grown at a planted site with the arm low, then the arm
## raised and the bucket curled -- and gives the state: [boom, bucket, pile levels, the dig
## spot].
func _backhoe_mid_dig() -> Array:
	# The arm all the way down first, however the machine was left: a dig only scoops with the
	# lip at the ground.
	Input.action_press("backhoe_arm_down")
	_drive(0.0, 0.0, 0.0, 4.0)
	Input.action_release("backhoe_arm_down")
	Input.action_press("backhoe_bucket_dump")
	_drive(0.0, 0.0, 0.0, 2.5)
	Input.action_release("backhoe_bucket_dump")
	var c := _car()
	var fwd := OBB.heading(c.yaw)
	var spot := c.pos + Vector3(fwd.x, 0.0, fwd.y) * 2.2 * WS.M
	var tile := ctx.collision.tile_at(spot)
	ctx.sim.sites[tile] = {"id": 9003, "i": tile, "x": D.tx(tile), "y": D.ty(tile), "type": "build"}
	Input.action_press("backhoe_bucket_dump")
	_drive(0.0, 0.0, 0.0, 0.5)
	Input.action_release("backhoe_bucket_dump")
	Input.action_press("backhoe_bucket_curl")
	_drive(0.0, 0.0, 0.0, 2.5)
	Input.action_release("backhoe_bucket_curl")
	ctx.sim.sites.erase(tile)
	# Left mid-dig: the arm up, the bucket curled in.
	Input.action_press("backhoe_arm_up")
	_drive(0.0, 0.0, 0.0, 1.2)
	Input.action_release("backhoe_arm_up")
	Input.action_press("backhoe_bucket_curl")
	_drive(0.0, 0.0, 0.0, 0.5)
	Input.action_release("backhoe_bucket_curl")
	var arm: Object = drive.get("arm")
	return [float(arm.get("boom")), float(arm.get("bucket")), float(arm.get("pile")), spot]


## The load cycle: the cars cleared and the parking fill re-run as a load re-derives them (the
## machine back at its kerb, folded), the drive save restored, the machine drawn again and the
## drive feature's frame run so what the save left is put back. The machine's node, or null when
## it never comes back.
func _backhoe_loaded(parsed: Dictionary, slot: Vector2i) -> Node3D:
	_clear_all()
	var amb: Object = traffic.get("ambient")
	amb.call("fill_parking")
	drive.call("on_world_rebuilt")
	drive.call("from_dict", parsed)
	var node: Node3D = null
	for _k in range(120):
		traffic.call("sync_visuals", DT)
		ctx.player.update_view(DT)
		for c: VH.Car in _vh().cars:
			if c.label == "a backhoe" and c.slot_tile == slot.x and c.slot_k == slot.y:
				node = c.node
		if node != null:
			break
		await process_frame
	if node == null:
		K.check(fails, false, "arm save: the load parks the machine at its kerb again")
		return null
	drive.call("_process", DT)
	return node


## The backhoe's rig survives a save (drive/backhoe.gd to_dict/from_dict): a machine left with
## its arm up and bucket curled reloads posed -- found by the curb slot it came from -- and the
## hero back at its wheel picks the pose up where it was left.
func _check_backhoe_save() -> void:
	var fx := await _backhoe_fixture()
	if fx.is_empty():
		_backhoe_cleanup()
		return
	var dug := _backhoe_mid_dig()
	var boom := float(dug[0])
	var bucket := float(dug[1])
	K.check(
		fails,
		boom > deg_to_rad(10.0) and float(dug[2]) > 1.0,
		(
			"arm save: fixture, the machine is left mid-dig (arm %.0f deg, pile %.1f)"
			% [rad_to_deg(boom), float(dug[2])]
		)
	)
	drive.call("exit", true)
	var parsed: Variant = JSON.parse_string(JSON.stringify(drive.call("to_dict")))
	var back: Dictionary = (
		(parsed as Dictionary).get("backhoe", {}) if typeof(parsed) == TYPE_DICTIONARY else {}
	)
	var poses: Array = back.get("poses", [])
	var slot: Vector2i = fx[2]
	K.check(
		fails,
		(
			typeof(parsed) == TYPE_DICTIONARY
			and poses.size() == 1
			and int(poses[0][0]) == slot.x
			and int(poses[0][1]) == slot.y
			and absf(float(poses[0][2]) - boom) < 1e-4
		),
		"arm save: to_dict carries the pose by the machine's kerb slot (%s)" % str(poses)
	)
	var node: Node3D = null
	if typeof(parsed) == TYPE_DICTIONARY:
		node = await _backhoe_loaded(parsed, slot)
	if node == null:
		_backhoe_cleanup()
		return
	var boom_n := node.find_child("Arm_Boom", true, false) as Node3D
	var bucket_n := node.find_child("Arm_Bucket", true, false) as Node3D
	K.check(
		fails,
		(
			boom_n != null
			and bucket_n != null
			and absf(float(boom_n.get_meta("arm_boom", 0.0)) - boom) < 1e-3
			and absf(float(bucket_n.get_meta("arm_bucket", 0.0)) - bucket) < 1e-3
		),
		"arm save: the load puts the arm back as the hero left it"
	)
	K.check(fails, drive.call("enter") == true, "arm save: the hero gets back in")
	_drive(0.0, 0.0, 0.0, 0.5)
	var arm: Object = drive.get("arm")
	K.check(
		fails,
		(
			absf(float(arm.get("boom")) - boom) < 1e-3
			and absf(float(arm.get("bucket")) - bucket) < 1e-3
		),
		"arm save: and picks the pose up at the wheel again"
	)
	drive.call("exit", true)
	_backhoe_cleanup()


## The dirt pile survives the save: it stands where it was dug after the load, its level kept, so
## a dig left half-done goes on from there.
func _check_backhoe_pile_save() -> void:
	var fx := await _backhoe_fixture()
	if fx.is_empty():
		_backhoe_cleanup()
		return
	var dug := _backhoe_mid_dig()
	var levels := float(dug[2])
	var spot: Vector3 = dug[3]
	K.check(fails, levels > 1.0, "pile save: fixture, the pile is grown (%.1f)" % levels)
	drive.call("exit", true)
	var parsed: Variant = JSON.parse_string(JSON.stringify(drive.call("to_dict")))
	if typeof(parsed) != TYPE_DICTIONARY:
		K.check(fails, false, "pile save: the save survives JSON")
		_backhoe_cleanup()
		return
	K.check(
		fails,
		(parsed as Dictionary).get("backhoe", {}).get("pile", []).size() >= 4,
		"pile save: to_dict carries the pile with its level"
	)
	var slot: Vector2i = fx[2]
	var node := await _backhoe_loaded(parsed, slot)
	if node == null:
		_backhoe_cleanup()
		return
	var dirt := (node.get_parent() as Node).find_child("DirtPile", true, false) as MeshInstance3D
	K.check(
		fails,
		(
			dirt != null
			and is_instance_valid(dirt)
			and dirt.global_position.distance_to(spot) < 3.0 * WS.M
		),
		"pile save: the pile stands where it was dug after the load"
	)
	K.check(fails, drive.call("enter") == true, "pile save: the hero gets back in")
	_drive(0.0, 0.0, 0.0, 0.5)
	var arm: Object = drive.get("arm")
	K.check(
		fails,
		absf(float(arm.get("pile")) - levels) < 0.05,
		"pile save: and the dig goes on from its level (%.1f)" % float(arm.get("pile"))
	)
	drive.call("exit", true)
	_backhoe_cleanup()


## The parking fill's backhoe forcing off again, the pile and pending poses dropped.
func _backhoe_cleanup() -> void:
	var amb: Object = traffic.get("ambient")
	amb.set("jcb_in", 37)
	amb.set("jcb_model", Callable(traffic, "jcb_model"))
	(drive.get("arm") as Object).call("clear")
	_clear_others()


## The town's working vehicles at the wheel (traffic's heavy_motors flag): every fleet body
## carries the driver markers, a stopped bus is the get-in target by its own name and drives on
## its own handling — slower to gather speed, on a shorter steering lock, longer to pull up,
## weighing six sedans, and named the hero's own once taken — the trucks carry their own profiles
## and mass, and none is claimable still moving or with the flag off.
func _check_heavy_motors() -> void:
	# Every working body carries the driver markers (_check_pose_kinds seats the hero in each).
	for body: String in ["bus", "truck", "garbage_truck"]:
		var ps: PackedScene = AP.load_scene(AP.VEHICLES_V2_DIR + body + ".glb")
		var n: Node3D = ps.instantiate() if ps != null else null
		var have := n != null
		for mk: String in AP.DRIVER_MARKERS + ["Seat_Driver"]:
			have = have and n.find_child(mk, true, false) != null
		K.check(fails, have, "heavy: %s carries the driver markers" % body)
		if n != null:
			n.free()

	# A bus at its stop: in by its own name, driving like itself.
	var m: int = traffic.call("vehicle_model", "bus")
	K.check(fails, m >= 0, "heavy: fixture, the bus model is loaded")
	if m < 0:
		return
	_clear_others()
	var bus_len: float = traffic.call("dims", m).z
	var c := _vh().make("bus", "bus", traffic.call("dims", m))
	c.model = m
	c.v = 0.0
	_vh().place(c, lanes[0], 0.35)
	_beside(c, OBB.side_axis(c.yaw), -0.6)
	var t: Dictionary = drive.call("enter_target")
	K.check(
		fails,
		int(t.get("id", -1)) == c.id and str(t.get("label", "")) == "the bus",
		"heavy: a stopped bus is the get-in target by name: %s" % str(t)
	)
	K.check(fails, drive.call("enter") == true, "heavy: the hero gets in")
	var dm: MODEL = drive.get("model")
	K.check(
		fails,
		dm.gain < 0.5 and dm.steer_lock < 0.7 and dm.brake_f < 0.9,
		(
			"heavy: the bus drives on its own profile (%.0f km/h top, gain %.2f, lock %.2f)"
			% [dm.top / WS.M * 3.6, dm.gain, dm.steer_lock]
		)
	)
	K.check(fails, absf(SHOVES.mass_of(_car()) - 6.0) < 1e-6, "heavy: and weighs six sedans")
	K.check(fails, str(_car().label) == "Your bus", "heavy: and is the hero's own bus")

	# Gathering speed, turning and pulling up, against a car over the same ground.
	var prof: Dictionary = traffic.call("drive_profile", _car().id)
	var hvy := MODEL.new()
	hvy.reset(0.0, bus_len, prof)
	_run(hvy, 1.0, 0.0, 0.0, 0.0, "asphalt", 2.0)
	var car := MODEL.new()
	car.reset(0.0, 0.24, {})
	_run(car, 1.0, 0.0, 0.0, 0.0, "asphalt", 2.0)
	K.check(
		fails,
		hvy.speed() < car.speed() * 0.6,
		(
			"heavy: it gathers speed at under a car's rate (%.0f of %.0f km/h)"
			% [hvy.speed() / KMH, car.speed() / KMH]
		)
	)
	var hturn := MODEL.new()
	hturn.reset(0.0, bus_len, prof)
	_run(hturn, 1.0, 0.0, 1.0, 0.0, "asphalt", 2.0)
	var cturn := MODEL.new()
	cturn.reset(0.0, 0.24, {})
	_run(cturn, 1.0, 0.0, 1.0, 0.0, "asphalt", 2.0)
	K.check(
		fails,
		absf(hturn.yaw) < absf(cturn.yaw) * 0.8,
		(
			"heavy: and turns on a shorter lock (%.0f%% of the car's turn)"
			% [100.0 * absf(hturn.yaw) / maxf(absf(cturn.yaw), 1e-4)]
		)
	)
	var v0 := 60.0 * KMH
	var hstop := MODEL.new()
	hstop.reset(0.0, bus_len, prof)
	hstop.vel = Vector2(0.0, v0)
	_run(hstop, 0.0, 1.0, 0.0, 0.0, "asphalt", 1.0)
	var cstop := MODEL.new()
	cstop.reset(0.0, 0.24, {})
	cstop.vel = Vector2(0.0, v0)
	_run(cstop, 0.0, 1.0, 0.0, 0.0, "asphalt", 1.0)
	K.check(
		fails,
		hstop.speed() > cstop.speed() + 1.0 * KMH,
		(
			"heavy: and takes longer to pull up (%.0f of %.0f km/h left)"
			% [hstop.speed() / KMH, cstop.speed() / KMH]
		)
	)
	drive.call("exit", true)

	# The trucks: their own profiles by fleet class, and their kind's mass.
	for kind: String in ["garbage_truck", "truck"]:
		var km: int = traffic.call("vehicle_model", kind)
		K.check(fails, km >= 0, "heavy: fixture, the %s model is loaded" % kind)
		if km < 0:
			continue
		var role := "garbage" if kind == "garbage_truck" else "truck"
		var kc := _vh().make(kind, role, traffic.call("dims", km))
		kc.model = km
		var kprof: Dictionary = traffic.call("drive_profile", kc.id)
		K.check(
			fails,
			(
				not kprof.is_empty()
				and float(kprof.get("gain", 1.0)) < 0.5
				and float(kprof.get("brake", 1.0)) < 1.0
			),
			"heavy: the %s carries its own profile" % kind
		)
		var want := 5.0 if kind == "garbage_truck" else 4.0
		K.check(
			fails, absf(SHOVES.mass_of(kc) - want) < 1e-6, "heavy: and weighs %d sedans" % int(want)
		)
		_vh().remove(kc)

	# None still moving is claimable, and none with the flag off.
	_clear_all()
	var fast := _vh().make("bus", "bus", traffic.call("dims", m))
	fast.model = m
	_vh().place(fast, lanes[0], 0.5)
	fast.v = 4.0 * KMH
	_beside(fast, OBB.side_axis(fast.yaw), -0.6)
	var rolling: Dictionary = drive.call("enter_target")
	K.check(fails, rolling.is_empty(), "heavy: none still moving is get-at-able: %s" % str(rolling))
	fast.v = 0.0
	FeatureFlags.set_override("heavy_motors", false)
	var off: Dictionary = drive.call("enter_target")
	K.check(
		fails,
		off.is_empty(),
		"heavy: the flag off parks no claim on the working vehicles: %s" % str(off)
	)
	FeatureFlags.set_override("heavy_motors", true)
	_vh().remove(fast)
	_clear_others()


## A bicycle at the wheel (the bike_ride flag): a cyclist that has nearly stopped is the get-in
## target by its own name, and the hero rides it from the saddle — its own handling (quick off the
## mark, a far tighter lock, pulling up short), almost no mass, the body staying a bicycle, hands
## on the grips and feet on the pedals (which the crank carries round under them), and off it at
## once, with no door to open.
func _check_bike_ride() -> void:
	var m: int = traffic.call("bike_model")
	K.check(fails, m >= 0, "bike: fixture, the bicycle model is loaded")
	if m < 0:
		return
	_clear_all()
	var c := _vh().make("bike", "ambient", traffic.call("dims", m))
	c.model = m
	_vh().place(c, lanes[0], 0.35)
	c.v = 0.0
	_beside(c, OBB.side_axis(c.yaw), -0.6)
	var t: Dictionary = drive.call("enter_target")
	K.check(
		fails,
		int(t.get("id", -1)) == c.id and str(t.get("label", "")) == "the bicycle",
		"bike: a stopped cyclist is the get-in target by name: %s" % str(t)
	)
	K.check(fails, drive.call("enter") == true, "bike: the hero gets on")
	K.check(fails, bool(drive.get("bike")), "bike: the drive state knows it is a bicycle")
	K.check(fails, _car().kind == "bike", "bike: the body stays a bicycle at the wheel")
	K.check(fails, str(_car().label) == "Your bicycle", "bike: and is the hero's own bicycle")
	var dm: MODEL = drive.get("model")
	K.check(
		fails,
		dm.top < 0.5 * MODEL.TOP and dm.gain > 0.5 and dm.steer_lock > 1.0 and dm.brake_f > 1.0,
		(
			"bike: it rides on its own profile (%.0f km/h top, gain %.2f, lock %.2f)"
			% [dm.top / WS.M * 3.6, dm.gain, dm.steer_lock]
		)
	)
	K.check(
		fails, absf(SHOVES.mass_of(_car()) - 0.12) < 1e-6, "bike: and weighs a twelfth of a car"
	)

	# The full model loads in the background: step until its node is there.
	var node: Node3D = null
	for _k in range(120):
		traffic.call("sync_visuals", DT)
		ctx.player.update_view(DT)
		node = _car().node
		if node != null:
			break
		await process_frame
	var pedal := node.find_child("Pedal_L", true, false) as Node3D
	var grip := node.find_child("Handle_L", true, false) as Node3D
	K.check(
		fails,
		node != null and pedal != null and grip != null,
		"bike: the full model carries the rider markers (pedals, grips)"
	)
	if node == null or pedal == null or grip == null:
		drive.call("exit", true)
		_clear_all()
		return
	await _check_bike_pedalling(node, pedal, grip)
	var pose: Object = drive.get("pose")
	K.check(
		fails,
		pose != null and bool(pose.get("_bike")),
		"bike: the seat pose knows it is a bicycle (hands on the grips, no roof)"
	)

	# Off it at once, with no door to open, and the body goes back to traffic.
	K.check(fails, drive.call("leave") == true, "bike: leave gets the hero off at once")
	K.check(fails, not bool(drive.get("active")), "bike: and the hero is on foot again")
	var sk := (ctx.player.avatar.get("rig") as Object).get("skeleton") as Node3D
	K.check(
		fails,
		sk != null and sk.global_transform.basis.y.normalized().y > 0.99,
		"bike: and stands up straight again (the riding lean is undone)"
	)
	# The player owner's sign-off on the riding lean, condition one: the getoff restore is
	# idempotent, so a getoff without a matching geton (leave while already out, a fall-off after
	# a climb out) must not stack rotations. The same pose.off the exits take, fired with no ride
	# behind it, leaves the skeleton exactly where the first getoff put it.
	if sk != null and pose != null:
		var rig: Variant = ctx.player.avatar.get("rig")
		var xf := sk.transform
		K.check(fails, drive.call("leave") == false, "bike: leave again off foot does nothing")
		pose.call("off", rig)
		K.check(fails, sk.transform == xf, "bike: a getoff without a geton moves nothing")
		pose.call("off", rig)
		K.check(fails, sk.transform == xf, "bike: and nor does a second (no stacked lean)")
		pose.call("reset")
		pose.call("off", rig)
		K.check(fails, sk.transform == xf, "bike: reset then off leaves it be as well")
	_clear_all()
	_check_bike_claim(m)


## Riding a bicycle (the bike_ride flag): the hero's hands hold the grips and their feet stay on
## the pedals the crank carries round, every frame of the ride. The contact is measured on the IK's
## own end bones (hero_limbs.gd's `ends`, after the IK has run; a bone pose read back off the
## skeleton is the clip's, before it), once the limbs have eased in. The rider's pitch off the
## avatar's up is sampled every frame as well (the player owner's sign-off, condition two): the
## lean is the only writer of the skeleton node's transform while riding — the player side
## writes the avatar's transform and the bones' poses — so it must sit at seat_pose.gd's
## BIKE_LEAN, unmoved, frame after frame. The bike is drawn and ridden
## in full (the hero rig has to be live), so this awaits frames like the arm check.
func _check_bike_pedalling(node: Node3D, pedal: Node3D, grip: Node3D) -> void:
	var rig: Variant = ctx.player.avatar.get("rig")
	var av: Node3D = ctx.player.avatar
	var skel: Node3D = null
	if rig is Object:
		skel = (rig as Object).get("skeleton") as Node3D
	var lean_lo := PI
	var lean_hi := 0.0
	var marks: Array[Node3D] = [
		grip,
		node.find_child("Handle_R", true, false) as Node3D,
		pedal,
		node.find_child("Pedal_R", true, false) as Node3D,
	]
	var gaps: Array[float] = [0.0, 0.0, 0.0, 0.0]
	var ped_travel := 0.0
	var quarters := {}
	var samples := 0
	var prev := pedal.global_position
	for _k in range(150):
		drive.call("drive_step", 1.0, 0.0, 0.0, 0.0, DT)
		traffic.call("sync_visuals", DT)
		ctx.player.update_view(DT)
		await process_frame
		if rig == null or str((rig as RefCounted).call("state")) != "drive":
			continue
		samples += 1
		ped_travel += pedal.global_position.distance_to(prev)
		prev = pedal.global_position
		quarters[int(fposmod(float(node.get_meta("crank_th", 0.0)), TAU) / (TAU / 4.0))] = true
		if samples > BIKE_EASE_IN:
			_bike_gaps(rig as RefCounted, marks, gaps)
			if skel != null and av != null:
				var lean := av.global_transform.basis.y.angle_to(skel.global_transform.basis.y)
				lean_lo = minf(lean_lo, lean)
				lean_hi = maxf(lean_hi, lean)
	K.check(
		fails, samples >= 20, "bike: the hero rides it, seated at the wheel (%d frames)" % samples
	)
	K.check(
		fails,
		maxf(gaps[0], gaps[1]) < BIKE_HAND_GAP,
		"bike: the hands stay on the grips (%.2f / %.2f m off at worst)" % [gaps[0], gaps[1]]
	)
	K.check(
		fails,
		maxf(gaps[2], gaps[3]) < BIKE_FOOT_GAP,
		"bike: the feet stay on the pedals (%.2f / %.2f m off at worst)" % [gaps[2], gaps[3]]
	)
	K.check(
		fails,
		ped_travel > 0.3 * WS.M and quarters.size() >= 3,
		(
			"bike: the crank comes round under them (%d quarters, %.1f m of pedal)"
			% [quarters.size(), ped_travel / WS.M]
		)
	)
	K.check(
		fails,
		absf(0.5 * (lean_lo + lean_hi) - SEAT.BIKE_LEAN) < 0.09 and lean_hi - lean_lo < 0.05,
		(
			"bike: the riding lean holds its pitch alone (%.0f deg, %.1f deg spread)"
			% [rad_to_deg(0.5 * (lean_lo + lean_hi)), rad_to_deg(lean_hi - lean_lo)]
		)
	)


## Widens gaps (m) to each limb's distance this frame from its own mark: left and right grip,
## then left and right pedal (the ankle rides SEAT.BIKE_ANKLE over it).
func _bike_gaps(rig: RefCounted, marks: Array[Node3D], gaps: Array[float]) -> void:
	var ends: Array = (rig.get("limbs") as Object).get("ends")
	for i in range(4):
		var want := marks[i].global_position
		if i >= 2:
			want += Vector3.UP * SEAT.BIKE_ANKLE
		gaps[i] = maxf(gaps[i], (ends[i] as Vector3).distance_to(want) / WS.M)


## A cyclist still moving is not claimable (the bike_ride flag), and none is with the flag off.
func _check_bike_claim(m: int) -> void:
	var fast := _vh().make("bike", "ambient", traffic.call("dims", m))
	fast.model = m
	_vh().place(fast, lanes[0], 0.35)
	fast.v = 3.0 * KMH
	_beside(fast, OBB.side_axis(fast.yaw), -0.6)
	var rolling: Dictionary = drive.call("enter_target")
	K.check(fails, rolling.is_empty(), "bike: none still moving is get-at-able: %s" % str(rolling))
	fast.v = 0.0
	FeatureFlags.set_override("bike_ride", false)
	var off2: Dictionary = drive.call("enter_target")
	K.check(
		fails, off2.is_empty(), "bike: the flag off parks no claim on the cyclists: %s" % str(off2)
	)
	FeatureFlags.set_override("bike_ride", true)
	_vh().remove(fast)
	_clear_others()


## Night driving (the night_driving flag): after dark the car the hero drives always throws its
## own beam — a dedicated lamp beside the street's shared pool, a bicycle a small dim one at its
## handlebar — and H at the wheel sounds the horn (a bicycle's bell) on hero_action, which the
## audio feature plays through the street's own horn source. The flag off leaves both off.
func _check_night_driving() -> void:
	FeatureFlags.set_override("night_driving", true)
	_clear_others()
	var rd: RD = traffic.get("render")
	if rd == null:
		K.check(fails, false, "night: fixture, the traffic renderer")
		return
	# The audio feature hears the horn like the street does (the emitters' own counter says so).
	var audio_f: FpFeature = K.make_feature(ctx, "audio")
	if audio_f != null:
		audio_f.set_process(false)
	var em: Object = audio_f.get("emitters") if audio_f != null else null
	var horns0 := int(em.get("horns_played")) if em is Object else -1
	var heard: Array[String] = []
	var on_horn := func(action: String, _at: Vector3) -> void: heard.append(action)
	ctx.bus.hero_action.connect(on_horn)
	# A stopped car at the wheel, after dark: the dedicated lamp, not a pool slot.
	var m: int = traffic.call("car_model_for", "night-drive")
	var c := _stopped_car(m)
	_beside(c, OBB.side_axis(c.yaw), -0.6)
	K.check(fails, drive.call("enter") == true, "night: the hero gets in")
	await _night_frames(4, 1.0)
	K.check(
		fails,
		rd.hero_beam_on and rd.hero_lamp != null and rd.hero_lamp.visible,
		"night: after dark the hero's car throws its own beam (a dedicated lamp)"
	)
	# H sounds the horn: taken at the wheel, heard on the bus, into the street's own horn
	# source; a quick second press waits out the gap.
	_press_horn()
	await process_frame
	K.check(fails, heard == ["horn"], "night: H at the wheel sounds the horn (hero_action)")
	K.check(
		fails,
		horns0 >= 0 and em is Object and int(em.get("horns_played")) > horns0,
		"night: and it reaches the street's own horn source"
	)
	_press_horn()
	await process_frame
	K.check(fails, heard.size() == 1, "night: a second press within the gap waits")
	drive.call("drive_step", 0.0, 0.0, 0.0, 0.0, 1.0)
	_press_horn()
	await process_frame
	K.check(fails, heard.size() == 2, "night: and again once the gap has passed")
	# By day the lamp is off.
	await _night_frames(4, 0.0)
	K.check(fails, not rd.hero_beam_on, "night: by day the hero's lamp is off")
	# A bicycle: a small dim lamp at the handlebar, and a bell instead of the horn. The street is
	# cleared first — the car the hero just left is a player car now, and standing beside it they
	# would take it again.
	K.check(fails, drive.call("leave") == true, "night: out of the car")
	_clear_all()
	var bm: int = traffic.call("bike_model")
	var bk := _vh().make("bike", "ambient", traffic.call("dims", bm))
	bk.model = bm
	_vh().place(bk, lanes[0], 0.35)
	bk.v = 0.0
	_beside(bk, OBB.side_axis(bk.yaw), -0.6)
	K.check(fails, drive.call("enter") == true, "night: and onto a bicycle")
	K.check(fails, bool(drive.get("bike")), "night: the drive state knows it is a bicycle")
	await _night_frames(4, 1.0)
	K.check(
		fails,
		rd.hero_beam_on and rd.hero_lamp != null and rd.hero_lamp.spot_angle < RD.BEAM_ANGLE,
		"night: a bicycle carries a small dim lamp of its own"
	)
	heard.clear()
	_press_horn()
	await process_frame
	K.check(fails, heard == ["bell"], "night: H on a bicycle rings the bell instead")
	# The flag off: neither lamp nor horn.
	FeatureFlags.set_override("night_driving", false)
	heard.clear()
	await _night_frames(4, 1.0)
	K.check(fails, not rd.hero_beam_on, "night: the flag off leaves the hero's lamp off")
	_press_horn()
	await process_frame
	K.check(fails, heard.is_empty(), "night: and the horn with it")
	# Tidy: the flag back to its default, the sky back to day, the hero off the bicycle.
	FeatureFlags.set_override("night_driving", true)
	ctx.bus.hero_action.disconnect(on_horn)
	K.check(fails, drive.call("leave") == true, "night: and off the bicycle again")
	ctx.sky.night = 0.0
	_clear_all()


## Steps frames at the wheel with the sky held at night (1 after dark, 0 by day): render lights
## its lamps a frame behind (set_glow runs after finish), so the states take a frame to settle.
func _night_frames(frames: int, night: float) -> void:
	ctx.sky.night = night
	for _k in range(frames):
		drive.call("drive_step", 0.0, 0.0, 0.0, 0.0, DT)
		traffic.call("sync_visuals", DT)
		ctx.player.update_view(DT)
		await process_frame
		ctx.sky.night = night


## One H press through the input map (the vehicle_horn action), as the player's own would come.
func _press_horn() -> void:
	var h := InputEventKey.new()
	h.keycode = KEY_H
	h.physical_keycode = KEY_H
	h.pressed = true
	Input.parse_input_event(h)
	Input.flush_buffered_events()


## A stopped ambient car of model m at the usual spot, for asking traffic about it.
func _of_model(m: int) -> VH.Car:
	var vh := _vh()
	var c := _stopped_car(m)
	c.model = m
	return c


## An ambient driver seated by traffic's own occupants.gd gets the same treatment as the player
## (drive/seat_pose.gd): hands bent onto the rim, feet onto the footwell floor, and the hips sunk
## until the top of the head clears the roof line, so their feet do not hang through the floorpan
## the chair-height sit clip leaves them at. occupants.gd sets the bone poses directly (no draw-time
## modifier), so this is measurable headless.
func _check_ambient_driver() -> void:
	var occ: Object = traffic.get("occupants")
	var people: Object = traffic.get("people")
	_clear_others()
	var m: int = traffic.call("car_model_for", "driver-check")
	var c := _stopped_car(m)
	# Freeze traffic's own stepping: the seating warms up over frames (the character pool loads in
	# the background), and a stepped car would drive out of range before it is seated.
	var was_processing := traffic.is_processing()
	traffic.set_process(false)
	ctx.player.teleport(
		c.pos + Basis(Vector3.UP, c.yaw) * Vector3(c.half_w + 0.7 * WS.M, 0.0, 0.0), 0.0
	)
	ctx.player.update_view(DT)
	var body: Variant = null
	for _k in range(120):
		traffic.call("sync_visuals", DT)
		body = occ.call("body_of", c.id)
		if body != null:
			break
		await process_frame
	traffic.set_process(was_processing)
	if body == null and not bool(people.get("ok")):
		K.check(fails, true, "ambient driver: skipped, no character assets")
		_vh().remove(c)
		return
	var node: Node3D = c.node
	K.check(
		fails,
		body != null and node != null,
		"ambient driver: a driver is seated in the car (body=%s)" % str(body != null)
	)
	if body == null or node == null:
		_vh().remove(c)
		return
	var sk: Skeleton3D = (body as Object).get("skel")
	var worst_foot := 0.0
	var worst_hand := 0.0
	for k in range(2):
		var side := "Left" if k == 0 else "Right"
		var tag := "L" if k == 0 else "R"
		var pedal := node.find_child("Pedal_%s" % tag, true, false) as Node3D
		var wheel := node.find_child("Wheel_%s" % tag, true, false) as Node3D
		if pedal != null:
			var toes := sk.find_bone(side + "Toes")
			if toes >= 0:
				var at := sk.global_transform * sk.get_bone_global_pose(toes).origin
				worst_foot = maxf(worst_foot, at.distance_to(pedal.global_position) / WS.M)
		if wheel != null:
			var hand := sk.find_bone(side + "Hand")
			if hand >= 0:
				var at := sk.global_transform * sk.get_bone_global_pose(hand).origin
				worst_hand = maxf(worst_hand, at.distance_to(wheel.global_position) / WS.M)
	K.check(
		fails,
		worst_foot < 0.06,
		"ambient driver: feet on the pedals (worst %.3f m off)" % worst_foot
	)
	# The grip is 0.74 m from the shoulder and the arm reaches 0.55 m, so the hand comes as close
	# as full extension allows (0.19 m, against 0.61 m for the plain sit clip's hands on the lap).
	K.check(
		fails,
		worst_hand < 0.25,
		"ambient driver: hands up to the rim (worst %.3f m off)" % worst_hand
	)
	var roof := node.find_child("Cab_Roof", true, false) as Node3D
	if roof != null:
		var hips := sk.find_bone("Hips")
		var head := sk.find_bone("Head")
		var top := 0.0
		if hips >= 0 and head >= 0:
			var h := sk.global_transform * sk.get_bone_global_pose(hips).origin
			var hd := sk.global_transform * sk.get_bone_global_pose(head).origin
			top = h.y + (hd.y - h.y) * SKULL_HAIR
		K.check(
			fails,
			top <= roof.global_position.y + 0.01,
			(
				"ambient driver: head under the roof line (top %.3f m, roof %.3f m)"
				% [top / WS.M, roof.global_position.y / WS.M]
			)
		)
	_vh().remove(c)
	_clear_others()


## A construction site's backhoe: the sim's site_started parks a work machine at the kerb beside the
## site, and site_finished takes it away with the crew.
func _check_site_machine() -> void:
	var amb: Object = traffic.get("ambient")
	amb.set("jcb_model", Callable(traffic, "jcb_model"))
	var m: int = traffic.call("jcb_model")
	K.check(fails, m >= 0, "site machine: fixture, the backhoe model is loaded")
	if m < 0:
		return
	# Clear the kerb first, so the only backhoe that can appear is the site's own.
	_clear_others()
	var lg: LG = traffic.get("lanes")
	var vh := _vh()
	# A lot beside a parkable road tile: the site's own tile and the kerb it works from.
	var site := -1
	for r: int in road:
		if not lg.parkable(r):
			continue
		for n: int in lg.neighbours(r):
			if ctx.sim.kind[n] != D.ROAD:
				site = n
				break
		if site >= 0:
			break
	K.check(fails, site >= 0, "site machine: fixture, a lot beside a parkable road")
	if site < 0:
		return
	var s := {
		"id": 9001,
		"i": site,
		"x": D.tx(site),
		"y": D.ty(site),
		"type": "build",
		"plan": "school",
		"label": "School",
		"crew": {},
	}
	ctx.sim.site_started.emit(s)
	traffic.call("step", DT * 2.0)
	var found: VH.Car = null
	for c: VH.Car in vh.cars:
		if c.label == "a backhoe" and c.slot_tile >= 0:
			found = c
	K.check(
		fails,
		found != null and lg.neighbours(site).has(found.slot_tile),
		"site machine: a backhoe parks at the kerb beside the new site"
	)
	if found == null:
		_clear_others()
		return
	K.check(fails, absf(found.mass - 5.5) < 1e-6, "site machine: carrying its mass")
	var id := found.id
	ctx.sim.site_finished.emit(s)
	traffic.call("step", DT * 2.0)
	K.check(fails, not vh.by_id.has(id), "site machine: and leaves with the crew when it is built")
	_clear_others()


## A car the hero's own holds up honks at them (the blocked_horns flag): a lane car stopped behind
## the car the hero has left standing in the lane keeps a hero_block_s clock, reports it through
## agents_near, and honks through the street's own horn source within a couple of seconds -- where
## the long jam draw alone would rarely fire. The flag off, the clock never runs.
func _check_blocked_horns() -> void:
	FeatureFlags.set_override("blocked_horns", true)
	_clear_all()
	var m: int = traffic.call("car_model_for", "blocked-horn")
	var c := _vh().make("car", "ambient", traffic.call("dims", m))
	c.model = m
	_vh().place(c, lanes[0], 0.5)
	c.v = 0.0
	_beside(c, OBB.side_axis(c.yaw), -0.6)
	K.check(fails, drive.call("enter") == true, "blocked horn: the hero gets in")
	var ai := _stopped_car(m)
	_vh().place(ai, lanes[0], 0.05)
	ai.path = lanes.slice(1)
	ai.v = WS.CAR_CITY
	ai.v0 = WS.CAR_CITY
	var blocked := 0.0
	for _k in range(roundi(6.0 / DT)):
		drive.call("drive_step", 0.0, 1.0, 0.0, 0.0, DT)
		traffic.call("step", DT)
		blocked = maxf(blocked, ai.hero_block_s)
	var seen := -1.0
	for a: Dictionary in traffic.call("agents_near", ai.pos, 0.5):
		if int(a.get("id", -1)) == ai.id:
			seen = float(a.get("hero_block_s", -1.0))
	K.check(
		fails,
		not ai.dead and blocked >= EM.HORN_HERO_S and absf(seen - ai.hero_block_s) < 0.05,
		(
			"blocked horn: a car held up behind the hero's keeps the clock"
			+ " (%.1f s, agents_near %.1f)" % [blocked, seen]
		)
	)
	var em: Object = _emitters()
	var h0 := int(em.get("horns_played")) if em is Object else -1
	var audio_f: FpFeature = ctx.feature("audio")
	var first := -1.0
	for _k in range(roundi(2.0 / DT)):
		var hb := int(em.get("horns_played")) if em is Object else -1
		drive.call("drive_step", 0.0, 1.0, 0.0, 0.0, DT)
		traffic.call("step", DT)
		if audio_f != null:
			audio_f.call("step", DT)
		if em is Object and int(em.get("horns_played")) > hb and first < 0.0:
			first = float(_k) * DT
	K.check(
		fails,
		h0 >= 0 and first >= 0.0 and first < 0.5,
		"blocked horn: and it honks at the hero at once (%.2f s in)" % first
	)
	# The flag off: no clock, so nothing for the horns to read.
	FeatureFlags.set_override("blocked_horns", false)
	ai.hero_block_s = 0.0
	for _k in range(roundi(3.0 / DT)):
		drive.call("drive_step", 0.0, 1.0, 0.0, 0.0, DT)
		traffic.call("step", DT)
	K.check(fails, ai.hero_block_s <= 0.0, "blocked horn: the flag off, the clock never runs")
	FeatureFlags.set_override("blocked_horns", true)
	K.check(fails, drive.call("leave") == true, "blocked horn: and out again")
	_clear_all()


## The horn reaches the street (the horn_reach flag): a car stopped ahead of the car the hero
## drives -- stunned by a knock, as one that has just run someone down -- shakes it off and gets
## going when the hero sounds the horn; a bicycle's bell does not, and neither does the horn with
## the flag off.
func _check_horn_reach() -> void:
	FeatureFlags.set_override("horn_reach", true)
	_clear_all()
	var m: int = traffic.call("car_model_for", "horn-reach")
	var c := _vh().make("car", "ambient", traffic.call("dims", m))
	c.model = m
	_vh().place(c, lanes[0], 0.1)
	c.v = 0.0
	_beside(c, OBB.side_axis(c.yaw), -0.6)
	K.check(fails, drive.call("enter") == true, "horn reach: the hero gets in")
	var ai := _stopped_car(m)
	traffic.call("step", DT)
	ai.stun_t = VH.HIT_STUN
	ai.v = 0.0
	var s0 := ai.s
	ctx.bus.hero_action.emit("horn", c.pos + Vector3(0.0, c.height * 0.5, 0.0))
	K.check(
		fails,
		ai.stun_t <= 0.0 and ai.nudge_t > 0.0,
		"horn reach: the horn shakes off a stunned car ahead"
	)
	for _k in range(roundi(2.5 / DT)):
		drive.call("drive_step", 0.0, 1.0, 0.0, 0.0, DT)
		traffic.call("step", DT)
	K.check(
		fails,
		ai.s > s0 + 0.2 * WS.M,
		"horn reach: and it gets going (%.1f m on)" % ((ai.s - s0) / WS.M)
	)
	ai.stun_t = VH.HIT_STUN
	ai.nudge_t = 0.0
	ctx.bus.hero_action.emit("bell", c.pos)
	K.check(fails, ai.stun_t > 0.0 and ai.nudge_t <= 0.0, "horn reach: a bicycle's bell does not")
	FeatureFlags.set_override("horn_reach", false)
	ctx.bus.hero_action.emit("horn", c.pos)
	K.check(
		fails,
		ai.stun_t > 0.0 and ai.nudge_t <= 0.0,
		"horn reach: the flag off, the horn is only heard"
	)
	FeatureFlags.set_override("horn_reach", true)
	K.check(fails, drive.call("leave") == true, "horn reach: and out again")
	_clear_all()


## The street hears the horn (the horn_street flag): each sounding of the car's horn goes on the
## bus with how far it carries -- a tap short, a press leaned on long -- from where the car stands,
## while a bicycle's bell carries nothing, and with the flag off the horn stays with traffic.
func _check_horn_street() -> void:
	FeatureFlags.set_override("horn_street", true)
	_clear_all()
	var m: int = traffic.call("car_model_for", "horn-street")
	var c := _vh().make("car", "ambient", traffic.call("dims", m))
	c.model = m
	_vh().place(c, lanes[0], 0.1)
	c.v = 0.0
	_beside(c, OBB.side_axis(c.yaw), -0.6)
	K.check(fails, drive.call("enter") == true, "horn street: the hero gets in")
	var heard: Array = []
	var cb := func(at: Vector2, radius: float, long: bool) -> void: heard.append([at, radius, long])
	ctx.bus.horn_sounded.connect(cb)
	drive.get("input").call("horn")
	K.check(
		fails,
		(
			heard.size() == 1
			and not bool(heard[0][2])
			and absf(float(heard[0][1]) - DRIVE.HORN_STREET_R) < 0.01
			and (heard[0][0] - Vector2(c.pos.x, c.pos.z)).length() < 3.0 * WS.M
		),
		"horn street: a tap carries through the street, short (%d heard)" % heard.size()
	)
	Input.action_press("vehicle_horn")
	for _k in range(roundi(0.8 / DT)):
		drive.call("drive_step", 0.0, 1.0, 0.0, 0.0, DT)
	Input.action_release("vehicle_horn")
	K.check(
		fails,
		heard.size() == 2 and bool(heard[1][2]),
		"horn street: and leaning on it goes out long (%d heard)" % heard.size()
	)
	drive.get("input").set("_horn_t", 0.0)
	drive.set("bike", true)
	drive.get("input").call("horn")
	drive.set("bike", false)
	K.check(fails, heard.size() == 2, "horn street: a bicycle's bell carries nothing")
	FeatureFlags.set_override("horn_street", false)
	drive.get("input").set("_horn_t", 0.0)
	drive.get("input").call("horn")
	FeatureFlags.set_override("horn_street", true)
	K.check(fails, heard.size() == 2, "horn street: the flag off, the horn is only heard")
	ctx.bus.horn_sounded.disconnect(cb)
	K.check(fails, drive.call("leave") == true, "horn street: and out again")
	_clear_all()


## The driven body hits as heavy as it is (car_body.gd takes the takeover's recorded mass through
## drive_profile): a hero on a bicycle who runs into a stopped sedan bounces off it and barely
## moves it; a hero bus plows the same sedan down the road and rolls on.
func _check_body_mass() -> void:
	FeatureFlags.set_override("heavy_motors", true)
	var bike: int = traffic.call("bike_model")
	var bus: int = traffic.call("vehicle_model", "bus")
	var sedan: int = traffic.call("car_model_for", "mass-target")
	K.check(fails, bike >= 0 and bus >= 0 and sedan >= 0, "mass: fixture, the models load")
	if bike < 0 or bus < 0 or sedan < 0:
		return
	var by_bike := _ram_throw("bike", "ambient", bike, sedan)
	var by_bus := _ram_throw("bus", "bus", bus, sedan)
	print(
		(
			(
				"mass: the bicycle throws the sedan %.2f m (rebounds to %.1f km/h), "
				+ "the bus %.2f m (keeps %.1f of %.1f km/h)"
			)
			% [by_bike[0], by_bike[2], by_bus[0], by_bus[2], by_bus[1]]
		)
	)
	K.check(
		fails,
		by_bike[1] > 0.0 and by_bike[0] < 0.5 and by_bike[2] < by_bike[1] * 0.2,
		(
			"mass: a hero on a bicycle bounces off the sedan (%.2f m, keeps %.1f of %.1f km/h)"
			% [by_bike[0], by_bike[2], by_bike[1]]
		)
	)
	K.check(
		fails,
		(
			by_bus[1] > 0.0
			and by_bus[0] > 1.0
			and by_bus[0] > by_bike[0] * 4.0
			and by_bus[2] > by_bus[1] * 0.5
		),
		(
			"mass: a hero bus plows it (%.2f m against the bicycle's %.2f, keeps %.1f of %.1f km/h)"
			% [by_bus[0], by_bike[0], by_bus[2], by_bus[1]]
		)
	)


## The hero takes the body (kind, role, model m) and runs it at full throttle into a sedan
## (model sm) held waiting on the lane ahead (hold: it never drives off; a knock still slides
## it, though the hold brakes the slide — the contrast between bodies, not the distance, is the
## signal). The ride joins the sedan's own line 15 m back: left where place() put it, a bicycle
## comes down the gutter line (BIKE_LAT) and never meets a lane-centre sedan. Returns
## [throw m, closing km/h, speed kept through the hit km/h]; closing is -1 when the hero could
## not get on or never reached it.
func _ram_throw(kind: String, role: String, m: int, sm: int) -> Array:
	_clear_all()
	var c := _vh().make(kind, role, traffic.call("dims", m))
	c.model = m
	_vh().place(c, lanes[0], 0.2)
	c.v = 0.0
	_beside(c, OBB.side_axis(c.yaw), -0.6)
	if not bool(drive.call("enter")):
		_clear_all()
		return [0.0, -1.0, 0.0]
	var target := _stopped_car(sm)
	target.hold = true
	var p0: Vector3 = target.pos
	var fwd := Vector2(sin(target.yaw), cos(target.yaw))
	var start := Vector2(p0.x, p0.z) - fwd * (15.0 * WS.M)
	drive.set("_pos", Vector3(start.x, p0.y, start.y))
	var dm: MODEL = drive.get("model")
	dm.yaw = target.yaw
	var sh: Object = traffic.get("shoves")
	var thrown := 0.0
	var closing := -1.0
	var kept := 0.0
	var prev := 0.0
	var settle := -1.0
	for _k in range(roundi(10.0 / DT)):
		var braking := settle >= 0.0 and dm.speed() > 0.0
		drive.call("drive_step", 0.0 if braking else 1.0, 1.0 if braking else 0.0, 0.0, 0.0, DT)
		traffic.call("step", DT)
		thrown = maxf(thrown, (target.pos - p0).length() / WS.M)
		if settle < 0.0 and sh != null and bool(sh.is_shoved(target)):
			closing = prev
			kept = dm.speed()
			settle = 2.0
		elif settle >= 0.0:
			settle -= DT
			if settle < 0.0:
				break
		prev = dm.speed()
	drive.call("exit", true)
	_clear_all()
	return [thrown, closing / WS.M * 3.6, kept / WS.M * 3.6]


## The audio feature's emitters, made if the night check has not (its step is the test's to drive).
func _emitters() -> Object:
	var f: FpFeature = ctx.feature("audio")
	if f == null:
		f = K.make_feature(ctx, "audio")
	if f == null:
		return null
	f.set_process(false)
	return f.get("emitters")


func _check_teardown() -> void:
	drive.teardown()
	var p := ctx.player
	K.check(
		fails,
		not bool(drive.get("active")) and p.input_enabled and not p.view_override,
		"teardown gets the hero out"
	)
	K.check(fails, int(traffic.call("driven_id")) == -1, "and hands the car back to traffic")


static func _box_gap(a: AABB, b: AABB) -> float:
	var dx := maxf(0.0, maxf(a.position.x - b.end.x, b.position.x - a.end.x))
	var dz := maxf(0.0, maxf(a.position.z - b.end.z, b.position.z - a.end.z))
	return Vector2(dx, dz).length()


func _action(a: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = a
	e.pressed = true
	return e
