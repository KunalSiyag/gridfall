extends SceneTree
## A thrown carjack driver beside another car too close to land between the two (a gap of a metre
## or less, flank to side: the body comes down in the next car, as it must, and the press-out has
## to shove it back out), and a body held off screen (people.gd tier 4, its mixer stopped and its
## pose frozen where it was last drawn). The head of such a body follows its feet (people.gd
## head_of): left behind in the car the feet were pressed out of, it was found inside it every
## step, and every step shoved the whole body on (0.6 m a step: 4 to 5 m through the hero's own
## car, in 0.1 s, with the car's tail 0.5 to 1 m behind the seat; the plain throw: 1 m).

const DT := 1.0 / 60.0
const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const DOORS := preload("res://scripts/fp/traffic/car_doors.gd")
## The most the victim's drawn feet may be moved off where the blow found them (m) at any time in
## the seconds SPAN_S after it: the haul out of the seat is a metre, the slide a little more; the
## shove ran to 4 to 5 m.
const MOST_M := 2.0
const SPAN_S := 4.0

var ctx: FpContext
var traffic: FpFeature
var fails: Array[String] = []
var ran: Array[String] = []
var lane: LG.Lane = null
var door_model := -1
var victim: WK.Walker = null


func _init() -> void:
	await process_frame
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "first"})
	ctx.player.set_process(false)
	traffic = K.make_feature(ctx, "traffic")
	if traffic == null:
		K.check(fails, false, "fixture: the traffic feature")
		K.finish(self, "FP_JACK_TIGHT_TEST", fails)
		return
	for prop: String in ["auto_step", "ambient_enabled"]:
		traffic.set(prop, false)
	for flag: String in ["car_doors", "carjack", "hit_feel", "carjack_throw"]:
		FeatureFlags.set_override(flag, true)
	(traffic.get("people") as RefCounted).set("blocking", true)
	ctx.bus.person_hit.connect(_on_hit)
	door_model = _door_model()
	if door_model >= 0 and _pick_lane():
		await _check_head()
		_check_tight()
	K.check(fails, ran.size() == 2, "every section ran to its end (%s)" % str(ran))
	FeatureFlags.reload()
	K.finish(self, "FP_JACK_TIGHT_TEST", fails)


func _on_hit(_at: Vector3, cause: String, info: Dictionary) -> void:
	if cause == "carjack":
		victim = traffic.call("_walker_by_id", int(info.get("walker", -1)))


## The first car model whose driver's door opens.
func _door_model() -> int:
	var render: RefCounted = traffic.get("render")
	for m: int in traffic.get("_car_models"):
		var mo: RefCounted = render.call("model", m)
		if DOORS.of(str(mo.get("key")), mo.get("scene")).ok:
			return m
	K.check(fails, false, "fixture: a car model whose door opens")
	return -1


## The straight lanes of road tiles (not bridges), tile by tile.
func _straights() -> Array[LG.Lane]:
	var out: Array[LG.Lane] = []
	var tiles: Dictionary = (traffic.get("lanes") as LG).tiles
	var keys: Array = tiles.keys()
	keys.sort()
	for i: int in keys:
		var info: LG.TileInfo = tiles[i]
		for l: LG.Lane in info.lanes:
			if l.kind == LG.STRAIGHT and not info.bridge:
				out.append(l)
	return out


## The first straight lane with walkable room 3 m off a car's driver's side along its length.
func _pick_lane() -> bool:
	for l: LG.Lane in _straights():
		if _free_beside(l):
			lane = l
			return true
	K.check(fails, false, "fixture: a straight lane with room beside a car on it")
	return false


func _free_beside(l: LG.Lane) -> bool:
	var vh: VH = traffic.get("vehicles")
	var car := vh.make("car", "ambient", traffic.call("dims", door_model))
	vh.place(car, l, 0.5)
	var xf := Transform3D(Basis(Vector3.UP, car.yaw), car.pos)
	vh.remove(car)
	for x_m: float in [0.4, 1.2, 2.0, 3.0]:
		for z: float in [-0.45, 0.0, 0.45]:
			if not _walkable(xf * Vector3(car.half_w + x_m * WS.M, 0.0, z * car.length)):
				return false
	return true


## True when the hero could stand at q: ground there, nothing in the way.
func _walkable(q: Vector3) -> bool:
	var g := ctx.collision.walk_height(q)
	return not is_nan(g) and not ctx.collision.is_blocked(Vector3(q.x, g, q.z), WS.PLAYER_RADIUS)


## An ambient driver's car stopped halfway along the lane, drawn, every other vehicle and everyone
## on foot gone, the hero on foot beside its driver's side (looking along the road, away from it).
func _lane_car() -> VH.Car:
	var vh: VH = traffic.get("vehicles")
	if traffic.get("_driven") != null:
		traffic.call("leave_car")
	for o: VH.Car in vh.cars.duplicate():
		vh.remove(o)
	K.quiet_walkers(traffic)
	ctx.collision.dynamic_boxes = []
	var c := vh.make("car", "ambient", traffic.call("dims", door_model))
	c.model = door_model
	vh.place(c, lane, 0.5)
	c.hold = true
	var xf := Transform3D(Basis(Vector3.UP, c.yaw), c.pos)
	ctx.player.teleport(xf * Vector3(c.half_w + WS.M, 0.0, -0.35 * c.length), 0.0)
	ctx.player.update_view(DT)
	traffic.call("sync_visuals", DT)
	return c


func _frame() -> void:
	traffic.call("step", DT)
	traffic.call("sync_visuals", DT)


## A body held off screen keeps the pose it was last drawn in, where it was: head_of carries that
## head along with the feet the walker's moved to (it gave the head where it was last drawn, and a
## press-out of the feet then found it still in the car); while a body is drawn its own posed head
## is the head, wherever the feet are asked of.
func _check_head() -> void:
	_lane_car()
	var people: RefCounted = traffic.get("people")
	var wk: WK = traffic.get("walkers")
	var base := ctx.player.position
	ctx.player.teleport(base, 0.0)
	ctx.player.update_view(DT)
	var w := wk.make("ambient")
	wk.stand(w, base + Vector3(0.0, 0.0, -4.0 * WS.M), 0.0)
	var drawn := false
	for _k in range(120):
		_frame()
		await process_frame
		drawn = w.body != null and w.tier >= 0 and w.tier <= 2
		if drawn:
			break
	K.check(fails, drawn, "fixture: a person on the pavement drawn in a body (tier %d)" % w.tier)
	if not drawn:
		return
	var feet: Vector3 = w.pos + w.vis_off
	var head: Vector3 = people.call("head_of", w, feet)
	var shift := Vector3(0.7 * WS.M, 0.0, -0.4 * WS.M)
	var moved: Vector3 = people.call("head_of", w, feet + shift)
	K.check(
		fails,
		moved.distance_to(head) < 0.001 * WS.M,
		"a body that is drawn: the head is its posed bone, wherever the feet are asked of"
	)
	# The hero turns away: the body is off screen (tier 4) and is held as it was.
	ctx.player.teleport(ctx.player.position, 180.0)
	ctx.player.update_view(DT)
	for _k in range(30):
		_frame()
		await process_frame
		if w.tier == 4:
			break
	K.check(fails, w.tier == 4, "fixture: the body held off screen (tier %d)" % w.tier)
	if w.tier != 4:
		return
	var held: Vector3 = people.call("head_of", w, w.pos + w.vis_off)
	K.check(
		fails,
		held.distance_to(head) < 0.001 * WS.M,
		(
			"held off screen where it stands, the head is the posed bone's (%.4f m)"
			% (held.distance_to(head) / WS.M)
		)
	)
	w.vis_off += shift
	var after: Vector3 = people.call("head_of", w, w.pos + w.vis_off)
	var off := after.distance_to(held + shift)
	K.check(
		fails,
		off < 0.001 * WS.M,
		(
			"pushed %.2f m, the head goes with the feet (%.4f m off where they went)"
			% [shift.length() / WS.M, off / WS.M]
		)
	)
	ran.append("head")


## A car 0.6 m or 1 m off the driver's side (flank to side), its tail 0.5 to 1 m behind the seat,
## held still: the real flow, the haul and the throw, the victim off screen as the hero is in the
## seat. The victim's drawn feet stay within MOST_M of where they were let go at every frame.
func _check_tight() -> void:
	var worst := 0.0
	var off_screen := 0
	var runs := 0
	for cfg: Array in [[0.6, 3.5], [1.0, 3.5], [1.0, 4.0], [0.6, 0.0]]:
		var c := _lane_car()
		var vh: VH = traffic.get("vehicles")
		var o := vh.make("car", "ambient", traffic.call("dims", door_model))
		o.model = door_model
		var xf := Transform3D(Basis(Vector3.UP, c.yaw), c.pos)
		var seat_z: float = ((traffic.call("door_info", c.id) as Dictionary)["seat"] as Vector3).z
		var gap_m: float = cfg[0]
		var nose_m: float = cfg[1]
		o.pos = (
			xf
			* Vector3(
				c.half_w + gap_m * WS.M + o.half_w, 0.0, seat_z + nose_m * WS.M - 0.5 * o.length
			)
		)
		o.yaw = c.yaw
		o.hold = true
		traffic.call("set_door", 1.0, c.id)
		traffic.call("sync_visuals", DT)
		for _k in range(14):
			_frame()
		victim = null
		traffic.call("claim_car", c.id, ctx.player.position, false)
		runs += 1
		if victim == null:
			K.check(fails, false, "fixture: the carjack's blow at gap %.1f m" % gap_m)
			continue
		var seen := 0
		var run_worst := 0.0
		for _k in range(roundi(SPAN_S / DT)):
			_frame()
			var off := Vector2(victim.vis_off.x, victim.vis_off.z).length()
			run_worst = maxf(run_worst, off)
			seen += 1 if victim.tier == 4 else 0
		print(
			(
				"  gap %.1f nose %.1f: moved %.2f m, tier 4 for %d frames"
				% [gap_m, nose_m, run_worst / WS.M, seen]
			)
		)
		worst = maxf(worst, run_worst)
		off_screen += 1 if seen > 0 else 0
		var msg := (
			"a car %.1f m off the door, its nose %.1f m ahead of the seat: " % [gap_m, nose_m]
		)
		msg += "the body is moved %.2f m at the most (of %.1f)" % [run_worst / WS.M, MOST_M]
		K.check(fails, run_worst <= MOST_M * WS.M, msg)
	var tail := "fixture: the victim was off screen (tier 4) in the throws with a tail behind"
	K.check(fails, off_screen >= 3 and runs == 4, tail)
	print("  most any victim was moved off where they were let go: %.2f m" % (worst / WS.M))
	ran.append("tight")
