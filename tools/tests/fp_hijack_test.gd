extends SceneTree
## Action hijacks (the drive feature's action_hijack flag, hijack.gd): at the wheel alongside a car
## moving in traffic with someone at its wheel the prompt reads "Jump across", and F lets go of the
## wheel (the car left rolls on with nobody at it, slowing as a coasting car does, until it stops),
## the hero climbs out onto the roof, leaps across onto the other car and swings down to its
## driver's window, the driver is dragged out (person_hit "carjack") and the hero drives on at the
## car's speed. Too slow, turned away, too far off or with the flag off there is nothing to jump
## to, and the car to take gone on the way drops the hero onto the road. Time runs through the
## drive feature's _hijack_step(1/60), the player's update_view and the traffic feature's step.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const JP := preload("res://scripts/fp/traffic/jack_pull.gd")
const JACK := preload("res://scripts/fp/traffic/carjack.gd")
const RE := preload("res://scripts/fp/traffic/reactions.gd")
const DOORS := preload("res://scripts/fp/traffic/car_doors.gd")
const HIJACK := preload("res://scripts/fp/drive/hijack.gd")
const DT := 1.0 / 60.0
## Both cars set off at this speed (m/s); the player's car this far off the side of the other (m).
const SPEED := 7.0
const APART := 1.2

var fails: Array[String] = []
var ctx: FpContext
var traffic: FpFeature
var drive: FpFeature
var hijack: HIJACK
## A straight lane with open road along its left (the oncoming side) where the player's car runs.
var lane: LG.Lane = null
## A car model whose driver's door opens (the window the hero reaches).
var model_id: int = -1
## The driver last dragged out, the seconds since, when the blow's info says their slide is over,
## and where their drawn feet were then.
var driver: WK.Walker = null
var driver_t: float = 0.0
var driver_done: float = INF
var rest_at: Vector3 = Vector3.INF
## [at, cause, info] of every person_hit, and every hero_action.
var hits: Array = []
var actions: Array = []
## Frames run by _step: the bodies are drawn every fourth, as they are in play.
var steps: int = 0


func _init() -> void:
	await process_frame
	if _setup() and _fixtures():
		_check_target()
		_check_hijack()
		_check_aftermath()
		_check_refusals()
		_check_gone()
	K.finish(self, "FP_HIJACK_TEST", fails)


## A grown city with the traffic and drive features, their time run by hand and every car flag on;
## false (a failed check) when a feature is missing.
func _setup() -> bool:
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "first"})
	ctx.player.set_process(false)
	traffic = K.make_feature(ctx, "traffic")
	drive = K.make_feature(ctx, "drive")
	if traffic == null or drive == null:
		K.check(fails, false, "the traffic and drive features are registered")
		return false
	traffic.set("auto_step", false)
	traffic.set("ambient_enabled", false)
	drive.set_process(false)
	hijack = drive.get("hijack")
	# The pull-out's look is hit_feel's: the checks do not depend on the user's flags.
	for f: String in ["car_doors", "carjack", "action_hijack", "hit_feel", "carjack_throw"]:
		FeatureFlags.set_override(f, true)
	ctx.bus.person_hit.connect(_on_hit)
	ctx.bus.hero_action.connect(func(a: String, _at: Vector3) -> void: actions.append(a))
	return true


## The door model and the lane; false (a failed fixture) without them.
func _fixtures() -> bool:
	var render: RefCounted = traffic.get("render")
	for m: int in traffic.get("_car_models"):
		var mo: RefCounted = render.call("model", m)
		if DOORS.of(str(mo.get("key")), mo.get("scene")).ok:
			model_id = m
			break
	var lg: LG = traffic.get("lanes")
	var ids: Array = lg.tiles.keys()
	ids.sort()
	for i: int in ids:
		var info: LG.TileInfo = lg.tiles[i]
		for l: LG.Lane in info.lanes:
			if lane == null and not info.bridge and l.kind == LG.STRAIGHT and _open_left(l):
				lane = l
	K.check(fails, model_id >= 0 and lane != null, "fixture: a door model and an open road")
	return model_id >= 0 and lane != null


## True when the road off the left of l (where the player's car runs) is open ground all along it
## and on as far again past its end (where the car left rolls on).
func _open_left(l: LG.Lane) -> bool:
	var dims: Vector3 = traffic.call("dims", maxi(model_id, 0))
	var off := dims.x + APART * WS.M
	var from: Vector2 = l.pts[0]
	var h := (l.pts[l.pts.size() - 1] - from).normalized()
	for k in range(1, 20):
		var at := from + h * l.length * float(k) / 10.0
		var q := Vector3(at.x + h.y * off, WS.GROUND_Y, at.y - h.x * off)
		var g := ctx.collision.walk_height(q)
		if is_nan(g) or ctx.collision.is_blocked(Vector3(q.x, g, q.z), dims.x * 0.5):
			return false
	return true


# ------------------------------------------------------------------ checks


## Alongside a car moving in traffic with its driver: "Jump across", the car on the right.
func _check_target() -> void:
	var b := _side_by_side()
	var t: Dictionary = drive.call("hijack_target")
	var ok := int(t.get("id", -1)) == b.id and float(t.get("side", 0.0)) < 0.0
	K.check(fails, ok, "alongside a moving car with its driver it is the one to jump to (%s)" % t)
	var said := str(drive.call("_drive_prompt", true, 1.0))
	K.check(fails, said == "Jump across", 'and the prompt reads "Jump across" (%s)' % said)


## F: the car left rolls on with nobody at the wheel while the hero climbs out, leaps and swings
## down to the window, then drags the driver out and drives on at the car's speed; the car left
## slows as a coasting car does and stops.
func _check_hijack() -> void:
	var b := _side_by_side()
	var a := _driven()
	hits.clear()
	actions.clear()
	drive.call("_input", K.action_event("vehicle_enter"))
	var shoves: RefCounted = traffic.get("shoves")
	var left := (
		int(traffic.call("driven_id")) == -1 and not a.driven and bool(shoves.call("is_shoved", a))
	)
	K.check(fails, hijack.running() and left, "F lets go of the wheel: the hero sets off")
	var r := _run_hijack(b)
	K.check(
		fails,
		r["phases"] == ["out", "leap", "jack"],
		"out onto the roof, across, down to the window: %s" % str(r["phases"])
	)
	K.check(fails, actions == ["hijack"], "hero_action hijack as it leaps (%s)" % str(actions))
	K.check(
		fails,
		float(r["off"]) < 0.5 * WS.M,
		"the hero stays on or between the cars (%.2f m out)" % (float(r["off"]) / WS.M)
	)
	K.check(fails, bool(r["air"]), "and is in the air only in the leap")
	var down := hits.size() == 1 and str(hits[0][1]) == "carjack"
	down = down and bool((hits[0][2] as Dictionary).get("down", false))
	K.check(fails, down, "the driver is dragged out and knocked down (%s)" % str(hits))
	var mine: VH.Car = _vh().by_id.get(int(drive.get("car_id")))
	var held := bool(drive.get("active")) and b.dead and mine != null and mine.driven
	K.check(fails, held and mine.role == VH.PLAYER, "the hero is at the wheel of the car taken")
	var v := float((drive.get("model") as RefCounted).call("speed"))
	K.check(
		fails,
		absf(v - float(r["v"])) < 0.5 * WS.M and v > 3.0 * WS.M,
		"it drives on at the car's speed (%.1f m/s, it was at %.1f)" % [v / WS.M, r["v"] / WS.M]
	)
	_check_coast(a, float(r["a_v"]))
	_check_carried(b, float(r["v"]))


## The driver dragged out of a car moving at v is carried on at its pace (the carjack_throw flag):
## not left hanging where the car was. By the time the blow's info says their slide is over they are
## down the road by what the haul carried (if drawn at the wheel: the car's whole pace, easing to
## CARRY_MAX) and the slide's share of at most CARRY_MAX.
func _check_carried(b: VH.Car, v: float) -> void:
	if not FeatureFlags.enabled("carjack_throw"):
		return
	var at: Vector3 = hits[0][0]
	var heading := Vector3(sin(b.yaw + b.vis_yaw), 0.0, cos(b.yaw + b.vis_yaw))
	var plan := JP.Plan.new()
	plan.haul_carry = heading * v
	plan.carry = heading * minf(v, JP.CARRY_MAX)
	var lands := float((hits[0][2] as Dictionary).get("lands_in", 0.0))
	var hauled := lands > JP.STAND_CONTACT + 0.1
	var want := (
		((JP.carried(plan, JP.HAUL_S) if hauled else Vector3.ZERO) + plan.carry * 0.5 * JP.SLIDE_S)
		. dot(heading)
	)
	var moved := (rest_at - at).dot(heading) if rest_at.is_finite() else NAN
	print(
		(
			"  note: the driver is %.2f m down the road as the slide ends (%.2f expected)"
			% [moved / WS.M, want / WS.M]
		)
	)
	K.check(
		fails,
		moved >= 0.7 * want,
		(
			"the driver is carried on at the car's pace (%.1f m down the road, %.1f m expected)"
			% [moved / WS.M, want / WS.M]
		)
	)


## What follows the pull, with the player driving off and the car left coasting on: the driver is
## hauled out of the seat in the moving car's own frame (not hanging behind it), comes down in the
## gap between the cars (not in the car left's path), and is not pushed down the road by it: they
## lie where they came down, get up and run off.
func _check_aftermath() -> void:
	var b := _side_by_side()
	var a := _driven()
	var left_id := a.id
	var seat: Variant = (traffic.call("door_info", b.id) as Dictionary).get("seat")
	var seat_z: float = (seat as Vector3).z if seat != null else 0.0
	hits.clear()
	drive.call("_input", K.action_event("vehicle_enter"))
	var r := _run_hijack(b)
	var mine: VH.Car = _vh().by_id.get(int(drive.get("car_id")))
	var haul_lag := 0.0
	var hauled := 0
	var in_path := 0
	var pushed := 0.0  # how far from where the slide ended to where they set off
	var ran_off := false
	for k in range(900):
		drive.call("drive_step", 0.0, 0.0, 0.0, 0.0, DT)
		_tick()
		if k % 4 == 0:
			traffic.call("sync_visuals", DT * 4.0)
		if driver == null or mine == null:
			continue
		var feet := driver.pos + driver.vis_off
		var rx: RE.Reaction = (traffic.get("reactions") as RE).get("_active").get(driver.id)
		var mode: String = rx.mode if rx != null else ""
		if mode == "drag":
			var q := _frame_of(mine).affine_inverse() * feet
			haul_lag = maxf(haul_lag, absf(q.z - seat_z))
			hauled += 1
		var left: VH.Car = _vh().by_id.get(left_id)
		if left != null and mode == "place":
			var ql := _frame_of(left).affine_inverse() * feet
			in_path += 1 if absf(ql.x) < left.half_w else 0
		if driver.react == &"run" and rest_at.is_finite() and not ran_off:
			pushed = Vector2(feet.x - rest_at.x, feet.z - rest_at.z).length()
			ran_off = true
	K.check(
		fails,
		hauled > 0 and haul_lag < 0.5 * WS.M,
		(
			"hauled out in the moving car's own frame, %.1f m/s (%.2f m off the seat, %d frames)"
			% [float(r["v"]) / WS.M, haul_lag / WS.M, hauled]
		)
	)
	K.check(
		fails,
		ran_off and in_path == 0,
		"they come down in the gap, never in the car left's path (%d frames in it)" % in_path
	)
	K.check(
		fails,
		pushed < 1.5 * WS.M,
		(
			"and lie where they came down: not pushed along by it (%.1f m by the time they run)"
			% (pushed / WS.M)
		)
	)


## The car left (at a_v as the hijack ended) slows by about 0.6 m/s^2 plus 0.12 per m/s, as a
## coasting car does, and stands still where it stops.
func _check_coast(a: VH.Car, a_v: float) -> void:
	var shoves: RefCounted = traffic.get("shoves")
	var want := a_v
	for _k in range(60):
		want -= (0.6 * WS.M + 0.12 * want) * DT
		_tick()
	var v := (shoves.call("body_vel", a) as Vector2).length()
	K.check(
		fails,
		absf(v - want) < 0.3 * WS.M or (v == 0.0 and want < 2.0 * WS.M),
		(
			"the car left rolls on, slowing as it coasts (%.1f m/s, about %.1f)"
			% [v / WS.M, want / WS.M]
		)
	)
	for _k in range(600):
		_tick()
	var at := a.pos
	for _k in range(60):
		_tick()
	var still := not bool(shoves.call("is_shoved", a)) and not a.dead and a.pos == at
	K.check(fails, still, "and stops, left where it stands")


## Nothing to jump to too slow, turned away, too far off, or with the flag off.
func _check_refusals() -> void:
	var model: RefCounted = drive.get("model")
	var cases := {
		"too slow": func() -> void: model.set("vel", model.call("heading") * 2.0 * WS.M),
		"turned 40 degrees away": func() -> void: _turn(deg_to_rad(40.0)),
		"3 m further off": func() -> void: _shift(3.0 * WS.M),
		"the flag off": func() -> void: FeatureFlags.set_override("action_hijack", false),
	}
	for what: String in cases:
		_side_by_side()
		(cases[what] as Callable).call()
		var t: Dictionary = drive.call("hijack_target")
		K.check(fails, t.is_empty(), "%s: nothing to jump to" % what)
		FeatureFlags.set_override("action_hijack", true)


## The car to take gone half way: the hero drops onto the road, on foot.
func _check_gone() -> void:
	var b := _side_by_side()
	drive.call("jump_across")
	for _k in range(roundi(0.8 / DT)):
		_step()
	_vh().remove(b)
	_step()
	var p := ctx.player
	var fell := not hijack.running() and not bool(drive.get("active")) and p.input_enabled
	K.check(fails, fell and not p.carried, "the car to take gone half way: the hero drops off")


# ------------------------------------------------------------------ helpers


func _vh() -> VH:
	return traffic.get("vehicles")


## The player at the wheel of a car level with an ambient car moving along the lane, APART m off its
## left, both at SPEED; returns the ambient car.
func _side_by_side() -> VH.Car:
	drive.call("exit", true)
	for o: VH.Car in _vh().cars.duplicate():
		_vh().remove(o)
	var dims: Vector3 = traffic.call("dims", model_id)
	var b := _vh().make("car", "ambient", dims)
	b.model = model_id
	_vh().place(b, lane, lane.length * 0.3)
	b.v = SPEED * WS.M
	b.vel = Vector3(sin(b.yaw), 0.0, cos(b.yaw)) * b.v
	var a := _vh().make("car", VH.PLAYER, dims)
	a.model = model_id
	var xf := Transform3D(Basis(Vector3.UP, b.yaw), b.pos)
	a.pos = xf * Vector3(dims.x + APART * WS.M, 0.0, 0.0)
	a.yaw = b.yaw
	var info: Dictionary = traffic.call("claim_car", a.id)
	drive.call("_adopt", info)
	drive.call("_take_wheel")
	var model: RefCounted = drive.get("model")
	model.set("vel", model.call("heading") * SPEED * WS.M)
	drive.call("drive_step", 0.0, 0.0, 0.0, 0.0, DT)
	# The driver at b's wheel is drawn after a few syncs: pulled out of the seat, not from nowhere.
	for _i in range(4):
		traffic.call("sync_visuals", DT)
	return b


## Car c's frame: its place and facing, the drawn ones.
func _frame_of(c: VH.Car) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, c.yaw + c.vis_yaw), c.pos + c.vis_off)


func _driven() -> VH.Car:
	return _vh().by_id.get(int(traffic.call("driven_id")))


## Turns the player's car by dy where it stands.
func _turn(dy: float) -> void:
	var model: RefCounted = drive.get("model")
	model.set("yaw", float(model.get("yaw")) + dy)
	model.set("vel", model.call("heading") * SPEED * WS.M)
	drive.call("drive_step", 0.0, 0.0, 0.0, 0.0, DT)


## Moves the player's car d further off to its left.
func _shift(d: float) -> void:
	var model: RefCounted = drive.get("model")
	var h: Vector2 = model.call("heading")
	drive.set("_pos", (drive.get("_pos") as Vector3) + Vector3(h.y, 0.0, -h.x) * d)
	drive.call("drive_step", 0.0, 0.0, 0.0, 0.0, DT)


## Runs the hijack to its end (at most 4 s): the phases in order, the hero's furthest distance out
## past both cars' sides, whether it was in the air outside the leap or never, the speed of the car
## taken just before the pull and of the car left as it ended.
func _run_hijack(b: VH.Car) -> Dictionary:
	var a := int(hijack.from_id)
	var out := {"phases": [], "off": 0.0, "air": true, "v": 0.0, "a_v": 0.0}
	var phases: Array = out["phases"]
	var secs := 0.0
	while secs < 4.0 and hijack.running():
		if not b.dead:
			out["v"] = b.v
		var ph := hijack.phase
		if phases.is_empty() or phases.back() != ph:
			phases.append(ph)
		_step()
		secs += DT
		out["off"] = maxf(float(out["off"]), _outside(a, b))
		if hijack.running() and ctx.player.grounded == hijack.airborne():
			out["air"] = false
	var left: VH.Car = _vh().by_id.get(a)
	var shoves: RefCounted = traffic.get("shoves")
	out["a_v"] = (shoves.call("body_vel", left) as Vector2).length() if left != null else 0.0
	return out


## How far the hero stands outside the strip spanning car a's (by id) and car b's sides (u): 0 on
## either car, over the gap or hanging at the window.
func _outside(a_id: int, b: VH.Car) -> float:
	var a: VH.Car = _vh().by_id.get(a_id)
	if a == null or b.dead:
		return 0.0
	var p := ctx.player.position
	var inv := Transform3D(Basis(Vector3.UP, b.yaw + b.vis_yaw), b.pos + b.vis_off).affine_inverse()
	var q := inv * p
	var qa := inv * a.pos
	var lo := minf(-b.half_w, qa.x - a.half_w) - HIJACK.HANG_OUT
	var hi := maxf(b.half_w, qa.x + a.half_w) + HIJACK.HANG_OUT
	var span := maxf(b.length, a.length) * 0.5
	return maxf(maxf(lo - q.x, q.x - hi), maxf(absf(q.z) - span - 1.0 * WS.M, 0.0))


func _on_hit(at: Vector3, cause: String, info: Dictionary) -> void:
	hits.append([at, cause, info])
	driver = traffic.call("_walker_by_id", int(info.get("walker", -1)))
	driver_t = 0.0
	driver_done = float(info.get("lands_in", INF)) + JP.SLIDE_S
	rest_at = Vector3.INF


func _step() -> void:
	drive.call("_hijack_step", DT)
	ctx.player.update_view(DT)
	_tick()
	steps += 1
	if steps % 4 == 0:
		traffic.call("sync_visuals", DT * 4.0)


func _tick() -> void:
	traffic.call("step", DT)
	driver_t += DT
	if driver != null and driver_t >= driver_done and not rest_at.is_finite():
		rest_at = driver.pos + driver.vis_off
