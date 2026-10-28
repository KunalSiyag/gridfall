extends SceneTree
## Car doors (traffic's car_doors.gd, the drive feature's car_doors flag): every car model's
## driver's door cut out of its body and swung on its hinge; the hero walking round a stopped car
## to that door, opening it, climbing in and shutting it, and the climb out once the car has
## braked to a stop; car_door on the bus; turning back on the way, a blocked door, the door
## coming to rest against someone standing in its swing (and swinging on once they go), a thin
## post just past the hinge refused, and the flag off. Its cars have nobody at the wheel to pull
## out (carjack off; fp_carjack_test). Time runs through climb_step(1/60) and the player's
## update_view.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const DOORS := preload("res://scripts/fp/traffic/car_doors.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const BS := preload("res://scripts/fp/traffic/body_spheres.gd")
const DT := 1.0 / 60.0
const KMH := WS.M / 3.6
## The door touching someone or something is fine, inside them is not. Someone held in the door's
## swing turns to face the hero, which swings their posed torso a few mm toward the door, so their
## case allows a lean's width (the door itself stops a millimetre short of them).
const TOUCH := 0.005 * WS.M
const LEAN := 0.012 * WS.M
const IN_PHASES := ["walk", "align", "open", "step", "turn", "climb", "close"]
const OUT_PHASES := ["open", "climb", "away", "close"]

var fails: Array[String] = []
var ctx: FpContext
var traffic: FpFeature
var drive: FpFeature
var lane: LG.Lane = null
## A car model whose door opens.
var door_model: int = -1
## [at, open] of every car_door on the bus.
var slams: Array = []


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "first"})
	ctx.player.set_process(false)
	traffic = K.make_feature(ctx, "traffic")
	drive = K.make_feature(ctx, "drive")
	if traffic == null or drive == null:
		K.check(fails, false, "the traffic and drive features are registered")
		K.finish(self, "FP_CAR_DOORS_TEST", fails)
		return
	traffic.set("auto_step", false)
	traffic.set("ambient_enabled", false)
	drive.set_process(false)
	ctx.bus.car_door.connect(func(at: Vector3, open: bool) -> void: slams.append([at, open]))
	FeatureFlags.set_override("car_doors", true)
	FeatureFlags.set_override("carjack", false)
	_check_split()
	if door_model >= 0 and _find_spot():
		_check_in()
		_check_out()
		_check_brake()
		_check_turn_back()
		_check_blocked()
		_check_held_by_person()
		_check_drawn_frame()
		_check_post_in_swing()
		_check_flag_off()
	K.finish(self, "FP_CAR_DOORS_TEST", fails)


# ------------------------------------------------------------------ the door


## Every car model traffic hands out: a driver's door between shut lines round the seat, cut out
## of the body, that swings out on its hinge.
func _check_split() -> void:
	var render: RefCounted = traffic.get("render")
	var bad: Array[String] = []
	var n := 0
	for m: int in traffic.get("_car_models"):
		var mo: RefCounted = render.call("model", m)
		var key := str(mo.get("key"))
		var d: DOORS.Door = DOORS.of(key, mo.get("scene"))
		n += 1
		var why := d.why if not d.ok else _door_wrong(d, mo.get("scene"))
		if not why.is_empty():
			bad.append("%s: %s" % [key.get_file(), why])
		elif door_model < 0:
			door_model = m
	K.check(
		fails,
		n >= 5 and bad.is_empty(),
		"every car model has a driver's door that opens (%d models) %s" % [n, str(bad)]
	)


## "" when door d is sound: its hinge line ahead of the seat and its rear edge behind it, the
## handle by that edge on the driver's side, the door's triangles out of the body, and a pivot
## that swings the rear edge out (and back shut).
func _door_wrong(d: DOORS.Door, scene: PackedScene) -> String:
	var pts := DOORS.points(d)
	var hinge: Vector3 = pts["hinge"]
	var seat: Vector3 = pts["seat"]
	var rear: Vector3 = pts["rear"]
	var handle: Vector3 = pts["handle"]
	if not (hinge.z > seat.z and rear.z < seat.z and hinge.x > 0.0 and handle.x > 0.0):
		return "the lines are not round the seat on +X (%s)" % str(pts)
	var out := (pts["open_rear"] as Vector3).x - rear.x
	if absf(handle.z - rear.z) > 0.5 * WS.M or out < 0.5 * WS.M:
		return "the handle or the open door is off (%s)" % str(pts)
	if d.door_tris < 50 or d.door_mesh.get_aabb().size.z > DOORS.DOOR_MAX + 0.1 * WS.M:
		return "the cut is off (%d door triangles)" % d.door_tris
	var node := scene.instantiate() as Node3D
	var ok := DOORS.pose(node, d, 1.0)
	var pivot := node.get_meta("door") as Node3D if node.has_meta("door") else null
	var swung := pivot != null and is_equal_approx(pivot.rotation.y, -DOORS.OPEN_ANGLE)
	DOORS.pose(node, d, 0.0)
	var shut := pivot != null and is_zero_approx(pivot.rotation.y)
	node.free()
	if not (ok and swung and shut):
		return "posing failed (ok %s, open %s, shut %s)" % [ok, swung, shut]
	return ""


# ------------------------------------------------------------------ the climb


## The hero walks round the car from its far side, opens the driver's door, climbs in, shuts it
## and drives.
func _check_in() -> void:
	var c := _place_car()
	_put_hero(c, -1.0)
	var changed: Array = []
	var cb := func(on: bool) -> void: changed.append(on)
	ctx.bus.drive_changed.connect(cb)
	slams.clear()
	K.check(fails, drive.call("board") == true, "F by a car starts getting in")
	var entry: RefCounted = drive.get("entry")
	var route: PackedVector3Array = entry.call("route")
	K.check(
		fails,
		str(entry.get("kind")) == "in" and not bool(drive.get("active")) and route.size() >= 3,
		"the hero sets off round the car on foot (%d route points)" % route.size()
	)
	K.check(fails, changed == [true], "drive_changed(true) as it sets off")
	var car := _car()
	var r := _climb(car, 15.0)
	K.check(
		fails,
		r["phases"] == IN_PHASES,
		"it walks, reaches, opens, steps up, faces forward, climbs in, shuts: %s" % str(r["phases"])
	)
	var states: Array = r["states"]
	K.check(
		fails,
		states.has("car_in") and states.back() == "drive",
		"the hero climbs in (car_in) and takes the wheel (drive): %s" % str(states)
	)
	K.check(
		fails,
		float(r["near"]) > WS.PLAYER_RADIUS * 0.5,
		"the walk keeps off the car's body (%.2f m at the closest)" % (float(r["near"]) / WS.M)
	)
	K.check(
		fails, float(r["wide"]) > 0.99 and car.door == 0.0, "the door opened wide and shut again"
	)
	K.check(
		fails, _slams_ok(car), "car_door: it opens, then slams shut, at the door (%s)" % str(slams)
	)
	K.check(
		fails,
		bool(drive.get("active")) and float(r["secs"]) < 14.0,
		"then the hero drives (after %.1f s)" % float(r["secs"])
	)
	_check_seat(car)
	ctx.bus.drive_changed.disconnect(cb)


## Sat at the wheel: hips on the driver's seat sunk into the cushion, hands on the wheel (drive),
## the drive camera on. The hips sit below the seat marker by design (seat_pose.gd's sink, up to
## 0.17 m into the cushion) so the head clears the roof line, so the seat here is sunk by it.
func _check_seat(car: VH.Car) -> void:
	traffic.call("sync_visuals", DT)
	for _k in range(30):
		drive.call("drive_step", 0.0, 0.0, 0.0, 0.0, DT)
		ctx.player.update_view(DT)
	var rig: RefCounted = ctx.player.avatar.get("rig")
	var seat: Vector3 = (traffic.call("door_info", -1) as Dictionary)["seat"]
	var pose: Object = drive.get("pose") as Object
	var sink: float = float(pose.get("sink")) if pose != null else 0.0
	var want := Transform3D(Basis(Vector3.UP, car.yaw), car.pos) * (seat - Vector3(0.0, sink, 0.0))
	var off := ((rig.call("bone_world", "Hips") as Vector3) - want) / WS.M
	var st := str(rig.call("state"))
	K.check(
		fails,
		off.length() < 0.05 and st == "drive" and ctx.player.view_override,
		(
			"the hero sits on the driver's seat, sunk into the cushion (%.2f m off, %s)"
			% [off.length(), st]
		)
	)


## Stopped, F gets out the long way: the door opens, the hero climbs out onto its feet, steps
## clear and shuts it, and walks on with its own camera.
func _check_out() -> void:
	var car := _car()
	var p := ctx.player
	slams.clear()
	K.check(fails, drive.call("leave") == true, "F behind the wheel starts getting out")
	var r := _climb(car, 12.0)
	K.check(
		fails,
		r["phases"] == OUT_PHASES,
		"it opens, climbs out, steps away, shuts: %s" % str(r["phases"])
	)
	K.check(
		fails, float(r["wide"]) > 0.99 and car.door == 0.0, "the door opened wide and shut again"
	)
	var states: Array = r["states"]
	K.check(
		fails,
		states.front() == "drive" and states.has("car_out") and states.back() == "loco",
		"the hero climbs out (car_out) onto its feet: %s" % str(states)
	)
	K.check(fails, _slams_ok(car), "car_door: open, then the slam (%s)" % str(slams))
	var side := _side_of(car, p.position)
	K.check(
		fails,
		side > car.half_w + WS.PLAYER_RADIUS and side < car.half_w + 1.6 * WS.M,
		"the hero stands beside the driver's door (%.2f m out)" % ((side - car.half_w) / WS.M)
	)
	K.check(
		fails, not ctx.collision.is_blocked(p.position, WS.PLAYER_RADIUS * 0.8), "on free ground"
	)
	var st := str((p.avatar.get("rig") as RefCounted).call("state"))
	K.check(
		fails,
		not bool(drive.get("active")) and p.input_enabled and not p.view_override,
		"walking input and the hero's own camera are back"
	)
	K.check(
		fails,
		st == "loco" and p.camera_mode == "first",
		"standing (%s), in the first-person view it had" % st
	)
	K.check(
		fails,
		int(traffic.call("driven_id")) == -1 and not car.dead and float(r["secs"]) < 8.0,
		"the car stays where it was left (%.1f s)" % float(r["secs"])
	)


## Rolling slowly, F brakes to a stop before the door opens.
func _check_brake() -> void:
	var c := _place_car()
	_put_hero(c, 1.0)
	drive.call("enter")
	var model: RefCounted = drive.get("model")
	for _k in range(roundi(1.5 / DT)):
		drive.call("drive_step", 0.35, 0.0, 0.0, 0.0, DT)
	var v0 := float(model.call("speed"))
	K.check(fails, drive.call("leave") == true, "F at %.0f km/h gets out once stopped" % (v0 / KMH))
	var entry: RefCounted = drive.get("entry")
	var stopped := INF
	for _k in range(roundi(4.0 / DT)):
		drive.call("climb_step", DT)
		ctx.player.update_view(DT)
		if str(entry.get("kind")) == "out":
			stopped = absf(float(model.call("speed")))
			break
	K.check(
		fails,
		v0 > 8.0 * KMH and stopped < 0.2 * WS.M,
		"it brakes from %.0f km/h to a stop first (%.2f m/s)" % [v0 / KMH, stopped / WS.M]
	)
	drive.call("exit", true)


## F on the way to the door turns back: on foot where the hero stands, the car handed back.
func _check_turn_back() -> void:
	var c := _place_car()
	var p := ctx.player
	_put_hero(c, -1.0)
	drive.call("board")
	for _k in range(roundi(0.6 / DT)):
		drive.call("climb_step", DT)
		p.update_view(DT)
	var at := p.position
	drive.call("_input", _press("vehicle_enter"))
	K.check(
		fails,
		not bool(drive.call("_climbing")) and not bool(drive.get("active")) and p.input_enabled,
		"F on the way to the door turns back"
	)
	K.check(
		fails,
		p.position.distance_to(at) < 0.05 * WS.M and int(traffic.call("driven_id")) == -1,
		"where the hero stands, the car back with traffic"
	)


## A wall where the door swings: the hero gets in at once, and out at once on another side.
func _check_blocked() -> void:
	var c := _place_car()
	var b := Basis(Vector3.UP, c.yaw)
	var mid := c.pos + b * Vector3(c.half_w + 0.35 * WS.M, 0.0, 0.0)
	var ext := Vector3(0.12, 0.0, 0.12) * WS.M + (b * Vector3(0.0, 0.0, c.length * 0.4)).abs()
	_put_hero(c, -1.0)
	ctx.collision.add_test_box(
		AABB(mid - Vector3(ext.x, 0.0, ext.z), Vector3(ext.x * 2.0, 1.5 * WS.M, ext.z * 2.0))
	)
	drive.call("board")
	K.check(
		fails,
		bool(drive.get("active")) and not bool(drive.call("_climbing")),
		"no room for the door: the hero gets in at once"
	)
	var car := _car()
	drive.call("leave")
	for _k in range(10):
		drive.call("climb_step", DT)
	K.check(
		fails,
		not bool(drive.get("active")) and car != null and _side_of(car, ctx.player.position) < 0.0,
		"and out at once on the other side"
	)
	ctx.collision.clear_test_boxes()


## Someone stood in the door's swing, held there: the door comes to rest against them (never more
## than LEAN into their body, within TOUCH of it) and the climb in waits; once they go, it swings
## wide and the hero gets in.
func _check_held_by_person() -> void:
	var c := _place_car()
	var pts: Dictionary = traffic.call("door_info", c.id)
	var hinge: Vector3 = pts["hinge"]
	var xf := Transform3D(Basis(Vector3.UP, c.yaw), c.pos)
	var at := xf * Vector3(hinge.x + 0.42 * WS.M, 0.0, (hinge.z + (pts["rear"] as Vector3).z) * 0.5)
	at.y = ctx.collision.walk_height(at)
	var wk: WK = traffic.get("walkers")
	var w := wk.make("ambient")
	wk.stand(w, at, atan2(c.pos.x - at.x, c.pos.z - at.z))
	w.hold = true
	_put_hero(c, 1.0)
	K.check(fails, bool(drive.call("board")), "held door: the hero sets off for the door")
	var car := _car()
	var entry: RefCounted = drive.get("entry")
	var deepest := -INF
	var climbed := false
	for _k in range(roundi(6.0 / DT)):
		_tick()
		deepest = maxf(deepest, _into_body(car, w))
		climbed = climbed or str(entry.get("phase")) == "climb"
	K.check(
		fails,
		deepest <= LEAN and deepest >= -TOUCH,
		"held door: it rests against them (%.1f mm into their body)" % (deepest / WS.M * 1000.0)
	)
	K.check(
		fails,
		car.door < 0.9 and not climbed,
		"held door: and stays short of wide (%.2f), the climb waiting" % car.door
	)
	w.hold = false
	wk.remove(w)
	var run := _climb(car, 10.0)
	K.check(
		fails,
		(
			float(run["wide"]) > 0.9
			and bool(drive.get("active"))
			and not bool(drive.call("_climbing"))
		),
		"held door: they go, it swings wide and the hero gets in (%.2f)" % float(run["wide"])
	)


## A thin post just past the hinge, inside the door's swing but off its shut and wide-open lines:
## the door never opens into it (the hero gets in at once instead).
## A parked car whose drawn frame sits off its logic frame (vis_off still in flight after an
## unpark): the people-arc follows the DRAWN frame, so someone standing at the drawn door holds
## it, and the logic-frame spot the drawn door no longer occupies blocks nobody.
func _check_drawn_frame() -> void:
	var c := _place_car()
	c.vis_off = Basis(Vector3.UP, c.yaw) * Vector3(1.0 * WS.M, 0.0, 0.0)  # 1 m to its left
	var pts: Dictionary = traffic.call("door_info", c.id)
	var hinge: Vector3 = pts["hinge"]
	var rel := Vector3(hinge.x + 0.42 * WS.M, 0.0, (hinge.z + (pts["rear"] as Vector3).z) * 0.5)
	var wk: WK = traffic.get("walkers")
	var w := wk.make("ambient")
	w.hold = true
	# At the DRAWN door: holds the swing.
	var drawn := Transform3D(Basis(Vector3.UP, c.yaw + c.vis_yaw), c.pos + c.vis_off) * rel
	drawn.y = ctx.collision.walk_height(drawn)
	wk.stand(w, drawn, 0.0)
	var held := float(traffic.call("door_clear_of_people", c.id, 1.0, 0.0))
	K.check(fails, held < 0.9, "drawn frame: someone at the drawn door holds it (cap %.2f)" % held)
	# At the LOGIC-frame spot (1 m off the drawn door): nobody blocks.
	var logic := Transform3D(Basis(Vector3.UP, c.yaw), c.pos) * rel
	logic.y = ctx.collision.walk_height(logic)
	wk.stand(w, logic, 0.0)
	var clear := float(traffic.call("door_clear_of_people", c.id, 1.0, 0.0))
	K.check(
		fails, clear == 1.0, "drawn frame: the logic-frame spot blocks nobody (cap %.2f)" % clear
	)
	w.hold = false
	wk.remove(w)


func _check_post_in_swing() -> void:
	var c := _place_car()
	var pts: Dictionary = traffic.call("door_info", c.id)
	var q := (pts["hinge"] as Vector3).lerp(pts["rear"], 0.22)
	var xf := Transform3D(Basis(Vector3.UP, c.yaw), c.pos)
	var post := xf * Vector3(q.x + 0.1 * WS.M, 0.0, q.z)
	post.y = ctx.collision.walk_height(post)
	var size := Vector3(0.1, 1.5, 0.1) * WS.M
	var box := AABB(post - Vector3(size.x, 0.0, size.z) * 0.5, size)
	ctx.collision.add_test_box(box)
	_put_hero(c, 1.0)
	drive.call("board")
	var car := _car()
	var deepest := 0.0
	for _k in range(roundi(8.0 / DT)):
		if not bool(drive.call("_climbing")):
			break
		_tick()
		deepest = maxf(deepest, _into_box(car, box))
	K.check(
		fails,
		deepest <= TOUCH and car != null and car.door < 0.05,
		(
			"post in the swing: the door never opens into it (%.1f mm, door %.2f)"
			% [deepest / WS.M * 1000.0, car.door if car != null else -1.0]
		)
	)
	ctx.collision.clear_test_boxes()


## The flag off: in and out at once.
func _check_flag_off() -> void:
	FeatureFlags.set_override("car_doors", false)
	var c := _place_car()
	_put_hero(c, 1.0)
	drive.call("board")
	var at_once_in := bool(drive.get("active")) and not bool(drive.call("_climbing"))
	drive.call("leave")
	var at_once_out := not bool(drive.get("active")) and not bool(drive.call("_climbing"))
	K.check(fails, at_once_in and at_once_out, "car_doors off: F gets in and out at once")
	FeatureFlags.set_override("car_doors", true)


# ------------------------------------------------------------------ helpers


func _vh() -> VH:
	return traffic.get("vehicles")


func _car() -> VH.Car:
	return _vh().by_id.get(int(drive.get("car_id")))


## A lane on a straight road with free ground all round a car standing halfway along it.
func _find_spot() -> bool:
	var lg: LG = traffic.get("lanes")
	var dims: Vector3 = traffic.call("dims", door_model)
	for i: int in lg.tiles.keys():
		var t: LG.TileInfo = lg.tiles[i]
		if t.piece != "straight" or t.bridge:
			continue
		for e: int in [0, 1]:
			var seq: Array[int] = [i]
			var ls: Array = lg.lanes_along(seq, LG.OPP[e], e) if t.mask & (1 << e) else []
			for l: LG.Lane in ls:
				if _roomy(l, dims):
					lane = l
					return true
	K.check(fails, false, "fixture: a straight road with room round a car")
	return false


## Free ground 1.3 m off the body of a car of dims halfway along l: beside it at three points on
## both sides, in front of it and behind it.
func _roomy(l: LG.Lane, dims: Vector3) -> bool:
	var c := _vh().make("car", "ambient", dims)
	_vh().place(c, l, 0.5)
	var xf := Transform3D(Basis(Vector3.UP, c.yaw), c.pos)
	_vh().remove(c)
	var w := dims.x * 0.5 + 1.3 * WS.M
	var h := dims.z * 0.5 + 1.3 * WS.M
	var around: Array[Vector3] = [Vector3(0.0, 0.0, h), Vector3(0.0, 0.0, -h)]
	for z: float in [-0.5, 0.0, 0.5]:
		around.append(Vector3(w, 0.0, z * dims.z))
		around.append(Vector3(-w, 0.0, z * dims.z))
	for q: Vector3 in around:
		var pt := xf * q
		var g := ctx.collision.walk_height(pt)
		if is_nan(g) or ctx.collision.is_blocked(Vector3(pt.x, g, pt.z), WS.PLAYER_RADIUS):
			return false
	return true


## A fresh stopped car of door_model on the lane, every other vehicle gone, the hero on foot.
func _place_car() -> VH.Car:
	if bool(drive.get("active")) or bool(drive.call("_climbing")):
		drive.call("exit", true)
	for o: VH.Car in _vh().cars.duplicate():
		_vh().remove(o)
	ctx.collision.dynamic_boxes = []
	var c := _vh().make("car", "ambient", traffic.call("dims", door_model))
	c.model = door_model
	_vh().place(c, lane, 0.5)
	c.v = 0.0
	traffic.call("sync_visuals", DT)
	return c


## The hero on foot 1.1 m out from car c's body: on its driver's side (side 1) or the far side
## (-1).
func _put_hero(c: VH.Car, side: float) -> void:
	var xf := Transform3D(Basis(Vector3.UP, c.yaw), c.pos)
	ctx.player.teleport(xf * Vector3(side * (c.half_w + 1.1 * WS.M), 0.0, 0.1 * WS.M), 0.0)


## How far p is out along car c's driver's side (+X in its frame; negative on the far side).
func _side_of(c: VH.Car, p: Vector3) -> float:
	return (p - c.pos).dot(Basis(Vector3.UP, c.yaw).x)


## Runs the climb in or out until it ends (or max_s): the phases and the hero's rig states in
## order, the widest door, the hero's least distance to the car's body on the walk, and the
## seconds it took.
func _climb(car: VH.Car, max_s: float) -> Dictionary:
	var phases: Array = []
	var states: Array = []
	var rig: RefCounted = ctx.player.avatar.get("rig")
	var wide := 0.0
	var near := INF
	var secs := 0.0
	var entry: RefCounted = drive.get("entry")
	var k := 0
	while secs < max_s and bool(drive.call("_climbing")):
		drive.call("climb_step", DT)
		ctx.player.update_view(DT)
		if k % 4 == 0:
			traffic.call("sync_visuals", DT * 4.0)
		k += 1
		secs += DT
		var ph := str(entry.get("phase"))
		if not ph.is_empty() and (phases.is_empty() or str(phases.back()) != ph):
			phases.append(ph)
		var st := str(rig.call("state"))
		if states.is_empty() or str(states.back()) != st:
			states.append(st)
		wide = maxf(wide, car.door)
		if ph == "walk":
			near = minf(near, float(traffic.call("_body_dist", car, ctx.player.position)))
	return {"phases": phases, "states": states, "wide": wide, "near": near, "secs": secs}


## One frame of the climb, as _climb steps it.
func _tick() -> void:
	drive.call("climb_step", DT)
	ctx.player.update_view(DT)
	traffic.call("sync_visuals", DT)


## Car c's driver's door panel opened by its door amount, in world space: the hinge and the
## swung rear edge (xz) and the panel's foot and belt heights.
func _panel(c: VH.Car) -> Dictionary:
	var pts: Dictionary = traffic.call("door_info", c.id)
	var mo: RefCounted = (traffic.get("render") as RefCounted).call("model", c.model)
	var d: DOORS.Door = DOORS.of(str(mo.get("key")), mo.get("scene"))
	var foot := (mo.get("offset") as Transform3D) * (d.body_xf * Vector3(0.0, d.bottom, 0.0))
	var hinge: Vector3 = pts["hinge"]
	var swung := Basis(Vector3.UP, -DOORS.OPEN_ANGLE * c.door) * ((pts["rear"] as Vector3) - hinge)
	var xf := Transform3D(Basis(Vector3.UP, c.yaw), c.pos)
	var h := xf * hinge
	var e := xf * (hinge + swung)
	return {
		"h": Vector2(h.x, h.z),
		"e": Vector2(e.x, e.z),
		"lo": c.pos.y + foot.y,
		"hi": (xf * (pts["rear"] as Vector3)).y
	}


## How deep walker w's body (body_spheres round people.head_of) reaches into car c's door panel;
## negative, how far it is clear of it.
func _into_body(c: VH.Car, w: WK.Walker) -> float:
	var pn := _panel(c)
	var feet := w.pos + w.vis_off
	var spheres := BS.of(feet, (traffic.get("people") as Object).call("head_of", w, feet))
	var worst := -INF
	for k in range(spheres.size()):
		var q: Vector3 = spheres[k]
		var p := Vector2(q.x, q.z)
		var flat := p.distance_to(Geometry2D.get_closest_point_to_segment(p, pn["h"], pn["e"]))
		var up := q.y - clampf(q.y, float(pn["lo"]), float(pn["hi"]))
		worst = maxf(worst, BS.rad_of(k) - Vector2(flat, up).length())
	return worst


## How deep car c's door panel's edge line reaches into box b at the box's middle height (0 when
## clear), sampled every 2 cm from the hinge.
func _into_box(c: VH.Car, b: AABB) -> float:
	var pn := _panel(c)
	var h: Vector2 = pn["h"]
	var e: Vector2 = pn["e"]
	var n := maxi(1, ceili(h.distance_to(e) / (0.02 * WS.M)))
	var worst := 0.0
	for k in range(n + 1):
		var p := h.lerp(e, float(k) / float(n))
		var dx := minf(p.x - b.position.x, b.end.x - p.x)
		var dz := minf(p.y - b.position.z, b.end.z - p.y)
		if dx > 0.0 and dz > 0.0:
			worst = maxf(worst, minf(dx, dz))
	return worst


## Two car_doors since the last clear: open, then shut, both at the driver's side of car.
func _slams_ok(car: VH.Car) -> bool:
	if slams.size() != 2 or not bool(slams[0][1]) or bool(slams[1][1]):
		return false
	return _side_of(car, slams[0][0]) > 0.0 and _side_of(car, slams[1][0]) > 0.0


func _press(action: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	return e
