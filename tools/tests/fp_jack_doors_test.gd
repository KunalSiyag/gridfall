extends SceneTree
## A carjacked driver and the open door (jack_landing.gd, jack_throw.gd, the carjack_throw flag),
## for every car model there is, not the coupe's numbers alone: the thrown body must not go through
## the door hanging out beside it. The door is the real one, with its thickness (the card behind the
## skin) and its glass and frame (car_doors.gd), not the line of its skin; the body is the real
## one, every skinned vertex of it. The doors of SUVs and vans hang close to the seat, so no turn
## of the line clears them there: the point the body is let go at is moved down the car's side as
## far as it needs (SHIFT_MAX at most), the twist goes the way that sweeps the trailing legs off
## the door and the body keeps facing the car's side (a body turned with the line swings its arm
## into the door's rear corner). Checked per model from the real door numbers (the outline and
## door_info agree, the shift, the best line and the twist), then the real thing: the driver (a
## resident drawn at the wheel, their own avatar) taken through traffic's claim_car with the door
## swung wide, both spin signs (the walker's id odd or even: with a door open the twist is the
## door's, never theirs), then with it part open (a bystander stopped it swinging), the skinned body
## against the door's own triangles on every frame from the release to the landing. A control with
## the flag off shows the measure catches the plain throw going through the doors of the taller
## cars, and the cost (a limb through the car's own rear side behind the door) is measured too: the
## doors that clear without it get no shift, so no more of it than the turn alone costs. A car
## beside the door shortens the throw wherever along the road it stands, with the line turned off
## straight out by each model's own door (the body's root comes down clear of it, not in its nose).

const DT := 1.0 / 60.0
const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const JL := preload("res://scripts/fp/traffic/jack_landing.gd")
const JACK := preload("res://scripts/fp/traffic/carjack.gd")
const JT := preload("res://scripts/fp/traffic/jack_throw.gd")
const DOORS := preload("res://scripts/fp/traffic/car_doors.gd")
const LG := preload("res://scripts/fp/traffic/lane_graph.gd")
const TRIPS := preload("res://scripts/fp/traffic/trips.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
## The body is measured from the release (s after the blow: the haul is over at 0.45) to this long
## after the touchdown at the latest; the side of the car from the haul's middle.
const MESH_FROM_S := 0.4
const MESH_TO_S := 0.95
const SIDE_FROM_S := 0.2
const AFTER_S := 0.3
## Every sixth vertex of the body is followed; those within NEAR of the door's box are measured.
const STRIDE := 6
const NEAR := 0.2
## The least a vertex of the body may come to the door's triangles (m): none through it, and a
## clear hand's breadth short of touching. Measured over every model and 38 avatars: 0.05 at the
## least.
const MESH_MIN := 0.02
## The most a limb may poke through the car's own side behind the door (m) and for how long (s): the
## cost of letting the driver go down the side, measured over every model (the plain drag and
## throw, flag off, has the right arm through the rear quarter by 0.25 m as well).
const SIDE_MAX := 0.45
const SIDE_S := 0.45
## Throws per model and spin sign: the models whose door needs the shift get more avatars.
const HARD_REPS := 6
const EASY_REPS := 2
## A model with no shift (the door clears without it) has a limb through the car's own side for at
## most this long (s): the turn alone costs 0.23 s at the worst, the 0.05 m shift made it 0.37.
const NO_SHIFT_SIDE_S := 0.28
## Cars beside the door, flank to side gaps and nose or tail places (steps of 0.25 m from this far
## behind the release to this far ahead), and how clear the body's root must come down of every
## one of them (the reach of the lying body, reactions.gd BODY_R and DOWN_REACH).
const NB_GAPS := [1.6, 2.0, 2.4]
const NB_BEHIND_M := 9.0
const NB_AHEAD_M := 4.0
const NB_STEP_M := 0.25


## What carjack.gd's _fling reads of the traffic feature: its vehicles.
class VehStub:
	extends RefCounted
	var cars: Array = []


class FeatureStub:
	extends RefCounted
	var vehicles := VehStub.new()


var ctx: FpContext
var traffic: FpFeature
var drive: FpFeature
var fails: Array[String] = []
var ran: Array[String] = []
## The lane the cars stand on (and its road tile) and the car model on it now.
var lane: LG.Lane = null
var lane_tile: int = -1
var door_model: int = -1
## Every person_hit and the walker last hit; the next resident to try at the wheel.
var hits: Array = []
var victim: WK.Walker = null
var _ridx := 0
## Doors' triangles by model and amount, and the body meshes' vertex data by mesh.
var _doors: Dictionary = {}
var _meshes: Dictionary = {}


func _init() -> void:
	await process_frame
	if _setup():
		var models := _models()
		K.check(
			fails,
			models.size() == (traffic.get("_car_models") as Array).size() and models.size() >= 17,
			"every car model traffic hands out has a door that opens (%d)" % models.size()
		)
		door_model = int(models[0])
		if _pick_lane():
			await _warm()
			_check_geometry(models)
			_check_neighbours(models)
			_check_rig(models)
			_check_partial(models)
			_check_gates(models)
			_check_control()
	K.check(fails, ran.size() == 6, "every section ran to its end (%s)" % str(ran))
	FeatureFlags.reload()
	K.finish(self, "FP_JACK_DOORS_TEST", fails)


## The roster's avatar scenes load in the background, a frame at a time: run frames until a driver
## is drawn at the wheel (the first throws of a run otherwise find none, and are thrown with no
## haul).
func _warm() -> void:
	K.quiet_walkers(traffic)
	var drawn := false
	for _k in range(600):
		var c := _driven_car()
		drawn = (traffic.get("occupants") as RefCounted).call("driver_of", c.id) != null
		if drawn:
			break
		await process_frame
	K.check(fails, drawn, "fixture: a driver drawn at the wheel (the roster's scenes have loaded)")


## A grown city with the hero on foot and the traffic and drive features (time run by hand, no
## ambient traffic); false (a failed check) when either feature is missing.
func _setup() -> bool:
	ctx = K.make_ctx(get_root(), {"view": true, "grow": true, "camera_mode": "first"})
	ctx.player.set_process(false)
	traffic = K.make_feature(ctx, "traffic")
	drive = K.make_feature(ctx, "drive")
	var found := traffic != null and drive != null
	K.check(fails, found, "the traffic and drive features are registered")
	if not found:
		return false
	drive.set_process(false)
	for prop: String in ["auto_step", "ambient_enabled"]:
		traffic.set(prop, false)
	# The throw's look is hit_feel's: the checks do not depend on the user's flags.
	for flag: String in ["car_doors", "carjack", "hit_feel", "carjack_throw"]:
		FeatureFlags.set_override(flag, true)
	ctx.bus.person_hit.connect(_on_hit)
	return true


## The car models traffic hands out whose door opens.
func _models() -> Array:
	var out: Array = []
	var render: RefCounted = traffic.get("render")
	for m: int in traffic.get("_car_models"):
		var mo: RefCounted = render.call("model", m)
		if DOORS.of(str(mo.get("key")), mo.get("scene")).ok:
			out.append(m)
	return out


# ------------------------------------------------------------------ the geometry


## From the real door numbers of each model: the outline is the real door's (door_info's hinge and
## open rear edge are on it), the shift is within SHIFT_MAX and the least that has the best turn
## SHIFT_MARGIN clear of the door (none for the doors that clear without it; or, past what SHIFT_MAX
## can do, the most there is); the line throw_line takes is DOOR_MARGIN clear where a turn gets that
## far, else among the furthest there are; the twist's direction is away from the door (-1: it
## hangs ahead of the line).
func _check_geometry(models: Array) -> void:
	var worst := INF
	var needs: Array[String] = []
	var bad: Array[String] = []
	var none := 0
	for m: int in models:
		door_model = m
		var c := _lane_car("ambient")
		traffic.call("set_door", 1.0, c.id)
		var door: Dictionary = traffic.call("door_info", c.id)
		var pan: PackedVector2Array = traffic.call("door_outline", c.id, 1.0)
		for k: String in ["hinge", "open_rear"]:
			var at := door[k] as Vector3
			var off := JL.outline_dist(Vector2(at.x, at.z), pan)
			if pan.is_empty() or absf(off) > 0.03 * WS.M:
				bad.append("model %d: %s is %.3f m off the outline" % [m, k, off / WS.M])
		var start := Vector2(c.half_w + JACK.OUT, (door["seat"] as Vector3).z)
		var len_u := JACK.JACK_FLING * WS.M
		var shift := JL.exit_shift(start, len_u, pan)
		var moved := Vector2(start.x, start.y - shift)
		var gap := JL.best_gap(moved, len_u, pan)
		worst = minf(worst, gap)
		var line := JL.throw_line(Transform3D.IDENTITY, moved, JACK.JACK_FLING, pan, null, [], -1)
		var spin := JL.spin_away(moved, JL.dir_at(float(line["angle"])), pan)
		var line_gap := float(line["gap"]) * WS.M
		var capped := shift >= JL.SHIFT_MAX - 1e-9
		if shift > JL.SHIFT_MAX + 1e-9 or (gap < JL.SHIFT_MARGIN - 1e-9 and not capped):
			bad.append("model %d: shift %.2f m, best gap %.2f m" % [m, shift / WS.M, gap / WS.M])
		var less := Vector2(start.x, start.y - (shift - JL.SHIFT_STEP))
		if shift > 0.0 and JL.best_gap(less, len_u, pan) >= JL.SHIFT_MARGIN:
			bad.append("model %d: shift %.2f m is more than it needs" % [m, shift / WS.M])
		if line_gap < minf(JL.DOOR_MARGIN, gap - JL.GAP_TIE) - 1e-9 or spin != -1.0:
			bad.append(
				(
					"model %d: line gap %.2f of %.2f m, twist %+.0f"
					% [m, line_gap / WS.M, gap / WS.M, spin]
				)
			)
		if shift > 0.0:
			needs.append("%d (%.2f m)" % [m, shift / WS.M])
		else:
			none += 1
	var msg := "every model: the outline is the real door's, the shift the least that has the best "
	msg += "turn SHIFT_MARGIN clear within"
	K.check(fails, bad.is_empty(), "%s SHIFT_MAX, twist away %s" % [msg, str(bad)])
	K.check(
		fails,
		none >= 8,
		(
			"the doors that clear without it (hatchbacks, sedans, taxi) get no shift: %d of %d"
			% [none, models.size()]
		)
	)
	print(
		(
			"  worst door gap %.3f m (DOOR_MARGIN %.2f); let go down the side: %s"
			% [worst / WS.M, JL.DOOR_MARGIN / WS.M, ", ".join(needs)]
		)
	)
	ran.append("geometry")


# ------------------------------------------------------------------ the neighbours


## A car beside the door shortens the throw (carjack.gd _fling), wherever along the road its nose or
## tail is that the body can come down by it: with each model's own door, so the line turned
## rearward (up to 25 degrees: it lands the root up to 0.76 m down the side from where it is let go,
## the cut is made before and cannot know) and the release moved down the side, the root of the
## body comes down at least ROOT_R off a car 1.6 to 2.4 m off the side, whether the car is counted
## beside the door or not (a car whose nose was 1.0 to 1.7 m behind the place they are let go was
## not: the body landed in its nose).
func _check_neighbours(models: Array) -> void:
	var cj := JACK.new()
	var fs := FeatureStub.new()
	cj.f = fs
	var bad: Array[String] = []
	var tried := 0
	var cut := 0
	for m: int in models:
		door_model = m
		var c := _lane_car("ambient")
		traffic.call("set_door", 1.0, c.id)
		var door: Dictionary = traffic.call("door_info", c.id)
		var pan: PackedVector2Array = traffic.call("door_outline", c.id, 1.0)
		var me := VH.Car.new()
		me.half_w = c.half_w
		me.length = c.length
		var out := Vector2(c.half_w + JACK.OUT, (door["seat"] as Vector3).z)
		out.y -= JL.exit_shift(out, JACK.JACK_FLING * WS.M, pan)
		var worst := INF
		for gap: float in NB_GAPS:
			for k in range(-roundi(NB_BEHIND_M / NB_STEP_M), roundi(NB_AHEAD_M / NB_STEP_M) + 1):
				var o := VH.Car.new()
				o.half_w = c.half_w
				o.length = c.length
				var at := Vector2(
					c.half_w + gap * WS.M + o.half_w, out.y + float(k) * NB_STEP_M * WS.M
				)
				o.pos = Vector3(at.x, 0.0, at.y)
				fs.vehicles.cars = [me, o]
				var fling := cj._fling(me, Transform3D.IDENTITY, out.y)
				var line := JL.throw_line(Transform3D.IDENTITY, out, fling, pan, null, [], -1)
				var run := clampf(float(line["fling"]), JACK.MIN_FLING, fling)
				var root := out + JL.dir_at(float(line["angle"])) * run * WS.M
				var off := (
					Vector2(
						maxf(absf(root.x - at.x) - o.half_w, 0.0),
						maxf(absf(root.y - at.y) - 0.5 * o.length, 0.0)
					)
					. length()
				)
				tried += 1
				cut += 1 if fling < JACK.JACK_FLING - 1e-6 else 0
				worst = minf(worst, off)
				if off < JL.ROOT_R - 1e-6 and bad.size() < 6:
					bad.append(
						(
							"model %d, %.1f m off, %.2f m along: root %.2f m off the car"
							% [m, gap, (at.y - out.y) / WS.M, off / WS.M]
						)
					)
	var msg := "%d cars beside the door of every model, cut or not (%d cut): " % [tried, cut]
	msg += "the root of the body comes down at least %.2f m off each " % (JL.ROOT_R / WS.M)
	K.check(fails, bad.is_empty() and cut > 0 and cut < tried, msg + str(bad))
	ran.append("neighbours")


# ------------------------------------------------------------------ the rig


## Every model, both spin signs, avatars varied: no vertex of the body through the real door.
func _check_rig(models: Array) -> void:
	var worst := {"mesh": INF, "side": -INF, "side_s": 0.0, "plain_s": 0.0}
	var short: Array[String] = []
	var runs := 0
	for m: int in models:
		var plain := _shift_of(m, 1.0) <= 0.0
		for parity: int in [0, 1]:
			for _rep in range(EASY_REPS if plain else HARD_REPS):
				var r := _throw(m, parity, 1.0)
				runs += 1
				if r.is_empty():
					short.append("model %d parity %d: nothing thrown" % [m, parity])
					continue
				worst["mesh"] = minf(worst["mesh"], float(r["mesh"]))
				worst["side"] = maxf(worst["side"], float(r["side"]))
				worst["side_s"] = maxf(worst["side_s"], float(r["side_s"]))
				if plain:
					worst["plain_s"] = maxf(worst["plain_s"], float(r["side_s"]))
				if _fails(r) or (plain and float(r["side_s"]) > NO_SHIFT_SIDE_S):
					short.append(_describe(m, parity, r))
	var msg := "%d throws, every model and spin sign: no vertex through the door (%d crossings, "
	msg += "at least %.2f m off), the twist away from it, "
	msg += "no limb far or long through the car's side (no shift where none is needed: %.2f s)"
	var crossed := 0
	for line: String in short:
		crossed += 1 if line.contains("crossed") else 0
	K.check(
		fails,
		short.is_empty(),
		(
			"%s (%d short: %s)"
			% [
				msg % [runs, crossed, MESH_MIN, NO_SHIFT_SIDE_S],
				short.size(),
				str(short.slice(0, 4))
			]
		)
	)
	print(
		(
			"  worst of %d throws: %.3f m from the door; car side %.3f m for %.2f s (%.2f s plain)"
			% [runs, worst["mesh"], worst["side"], worst["side_s"], worst["plain_s"]]
		)
	)
	ran.append("rig")


## True when throw record r is short of the limits.
func _fails(r: Dictionary) -> bool:
	return (
		absf(float(r["lands"]) - _whole_s()) > 0.01
		or int(r["cross"]) > 0
		or float(r["mesh"]) < MESH_MIN
		or float(r["side"]) > SIDE_MAX
		or float(r["side_s"]) > SIDE_S
		or float(r["spin"]) >= 0.0
	)


## The seconds from the blow to the touchdown of the whole throw: hauled out, then the full fling in
## the air (a throw with no driver drawn at the wheel, or a fling cut short, lands sooner).
func _whole_s() -> float:
	return JT.HAUL_S + JT.make(JACK.STRENGTH, JACK.JACK_FLING, Vector3.RIGHT, 1.0).air


func _describe(m: int, parity: int, r: Dictionary) -> String:
	var kinds := "mesh %.3f%s" % [r["mesh"], " crossed %d" % int(r["cross"]) if r["cross"] else ""]
	return (
		"model %d parity %d av %d: %s side %.3f m %.2f s spin %+.2f lands %.3f"
		% [m, parity, int(r["av"]), kinds, r["side"], r["side_s"], r["spin"], r["lands"]]
	)


## The door part open (a bystander in its swing stopped it, carjack.gd takes the door as it hangs):
## the outline is the real door's at that swing (its rear edge, turned about the hinge by the swing,
## is on it) and the driver comes out where that door asks (a hatchback's: 0.30 m down the side with
## it 0.7 open, none wide open). The body clears it as far as the plan can: with the door 0.85 open
## every model but the vans (their door hangs across the way out: 0.01 to 0.02 m at the closest, one
## throw in six through it) has no vertex through it, 0.7 open for the models measured here (the
## vans' door is through for half of the throws) and, 0.5 open, none (the door is across the way out
## of every model and no line or shift of 0.35 m clears it: the body goes through it, as the plain
## throw does). The door a bystander holds short is rare: the hero's own opening swings it wide.
func _check_partial(models: Array) -> void:
	var bad: Array[String] = []
	for m: int in models:
		door_model = m
		var c := _lane_car("ambient")
		var door: Dictionary = traffic.call("door_info", c.id)
		var hinge := door["hinge"] as Vector3
		var rear := door["rear"] as Vector3
		for amount: float in [0.0, 0.35, 1.0]:
			var pan: PackedVector2Array = traffic.call("door_outline", c.id, amount)
			var edge := hinge + Basis(Vector3.UP, -DOORS.OPEN_ANGLE * amount) * (rear - hinge)
			var off := JL.outline_dist(Vector2(edge.x, edge.z), pan)
			if pan.is_empty() or absf(off) > 0.03 * WS.M:
				bad.append("model %d at %.2f: rear edge %.3f m off" % [m, amount, off / WS.M])
	K.check(fails, bad.is_empty(), "the outline follows the door's swing %s" % str(bad.slice(0, 3)))
	var hatch := models[2] as int
	var part := _out_z(hatch, 0.7)
	var wide := _out_z(hatch, 1.0)
	var asked := _shift_of(hatch, 0.7) / WS.M
	var ok := asked > 0.2 and absf(part + asked) < 0.02
	ok = ok and absf(wide + _shift_of(hatch, 1.0) / WS.M) < 0.02
	var msg := (
		"a hatchback's driver comes out %.2f m down the side from the door 0.7 open, " % -part
	)
	msg += "%.2f m wide open (as it hangs, not as if wide open)" % -wide
	K.check(fails, ok, msg)
	var short: Array[String] = []
	var runs := 0
	var render: RefCounted = traffic.get("render")
	var cases: Array = []
	for m: int in models:
		if not str((render.call("model", m) as RefCounted).get("key")).contains("van"):
			cases.append([m, 0.85])
	for m: int in [models[0], models[2], models[5], models[7], models[11]]:
		cases.append([m, 0.7])
	for c: Array in cases:
		var r := _throw(int(c[0]), 0, float(c[1]))
		runs += 1
		if r.is_empty() or int(r["cross"]) > 0 or float(r["mesh"]) < MESH_MIN:
			var what := _describe(int(c[0]), 0, r) if not r.is_empty() else "none"
			short.append("model %d at %.2f: %s" % [c[0], c[1], what])
	var label := "%d throws with the door 0.85 open (every model but the vans) or 0.7: " % runs
	K.check(fails, short.is_empty(), label + "no vertex through it %s" % str(short.slice(0, 3)))
	ran.append("partial")


## The shift (u) carjack.gd gives the driver of model m's car whose door hangs open by amount.
func _shift_of(m: int, amount: float) -> float:
	door_model = m
	var car := _lane_car("ambient")
	traffic.call("set_door", amount, car.id)
	var pan: PackedVector2Array = traffic.call("door_outline", car.id, amount)
	var door: Dictionary = traffic.call("door_info", car.id)
	var start := Vector2(car.half_w + JACK.OUT, (door["seat"] as Vector3).z)
	return JL.exit_shift(start, JACK.JACK_FLING * WS.M, pan)


## The shift down the car's side is the carjack_throw flag's with hit_feel's, as all the look is: a
## van's driver (whose door asks 0.3 m of it) comes out level with the seat with either flag off.
func _check_gates(models: Array) -> void:
	var render: RefCounted = traffic.get("render")
	var van := -1
	for m: int in models:
		if str((render.call("model", m) as RefCounted).get("key")).contains("van"):
			van = m
	var shift := _shift_of(van, 1.0) / WS.M if van >= 0 else 0.0
	var found := {}
	for cfg: Array in [
		["both", true, true], ["hit_feel off", true, false], ["flag off", false, true]
	]:
		FeatureFlags.set_override("carjack_throw", cfg[1])
		FeatureFlags.set_override("hit_feel", cfg[2])
		found[cfg[0]] = _out_z(van)
	FeatureFlags.set_override("carjack_throw", true)
	FeatureFlags.set_override("hit_feel", true)
	var bad: Array[String] = []
	for k: String in found:
		var want := -shift if k == "both" else 0.0
		if absf(float(found[k]) - want) > 0.02:
			bad.append("%s: %.3f m (%.3f)" % [k, found[k], want])
	var msg := "the van's driver comes out %.2f m down the side with both flags on, " % shift
	msg += "level with the seat with either off %s" % str(bad)
	K.check(fails, van >= 0 and shift > 0.1 and bad.is_empty(), msg)
	ran.append("gates")


## Where (m along the car, off the seat's place) the driver of model m's car with its door open by
## amount comes out as the hero takes it, the moment they do.
func _out_z(m: int, amount: float = 1.0) -> float:
	door_model = m
	K.quiet_walkers(traffic)
	var c := _driven_car()
	c.hold = true
	traffic.call("set_door", amount, c.id)
	var xf := Transform3D(Basis(Vector3.UP, c.yaw + c.vis_yaw), c.pos + c.vis_off)
	_face(xf * Vector3(c.half_w + 1.5 * WS.M, 0.0, 0.0))
	var seat: Vector3 = (traffic.call("door_info", c.id) as Dictionary)["seat"]
	hits.clear()
	victim = null
	traffic.call("claim_car", c.id, ctx.player.position)
	if victim == null:
		return NAN
	return ((xf.affine_inverse() * victim.pos).z - seat.z) / WS.M


## The control: the test has teeth. With the carjack_throw flag off (the plain drag and throw, the
## line straight out) the body of a pickup's, SUV's or van's driver goes through the door, which the
## measure here reads as a crossing.
func _check_control() -> void:
	FeatureFlags.set_override("carjack_throw", false)
	var crossed := 0
	var tried := 0
	var render: RefCounted = traffic.get("render")
	for m: int in _models():
		var key := str((render.call("model", m) as RefCounted).get("key"))
		if not (key.contains("pickup") or key.contains("suv") or key.contains("van")):
			continue
		for parity: int in [0, 1]:
			var r := _throw(m, parity, 1.0)
			tried += 1
			if not r.is_empty() and int(r["cross"]) > 0:
				crossed += 1
	FeatureFlags.set_override("carjack_throw", true)
	var msg := "control: with the flag off the plain throw goes through the taller cars' doors"
	K.check(
		fails, tried > 0 and crossed * 2 >= tried, "%s (%d of %d throws)" % [msg, crossed, tried]
	)
	ran.append("control")


## One car of model m with a resident drawn at the wheel (the door swung out by amount), taken
## through claim_car by the hero beside it. {"mesh" (the least distance, m, from any followed vertex
## of the skinned body to the door's triangles, MESH_FROM_S on to the touchdown and AFTER_S past
## it; NEAR when none came as near), "cross" (how many frames a vertex's step went through a
## triangle), "side" and "side_s" (the most a limb strays through the car's side plane behind the
## door's rear shut line, m, and the seconds it is more than 5 cm through), "spin" (the plan's
## twist) and "av"}; {} when nothing was thrown. parity is the walker's id parity.
func _throw(m: int, parity: int, amount: float) -> Dictionary:
	door_model = m
	K.quiet_walkers(traffic)
	var c := _driven_car()
	c.hold = true
	traffic.call("set_door", amount, c.id)
	var wk: WK = traffic.get("walkers")
	while (int(wk.get("_next_id")) & 1) != parity:
		wk.remove(wk.make("ambient"))
	var xf := Transform3D(Basis(Vector3.UP, c.yaw + c.vis_yaw), c.pos + c.vis_off)
	_face(xf * Vector3(c.half_w + 1.5 * WS.M, 0.0, 0.0))
	var door: Dictionary = traffic.call("door_info", c.id)
	var rear: Vector3 = (door["rear"] as Vector3) / WS.M
	hits.clear()
	victim = null
	traffic.call("claim_car", c.id, ctx.player.position)
	if hits.is_empty() or victim == null:
		return {}
	var info: Dictionary = hits[0][2]
	var tris: Dictionary = _door_of(m, amount)
	var best := {"mesh": NEAR, "cross": 0, "side": 0.0, "side_s": 0.0, "frames": 0}
	var prev := PackedVector3Array()
	var t := 0.0
	var end := minf(float(info.get("lands_in", 1.0)) + AFTER_S, MESH_TO_S + AFTER_S)
	while t < end:
		ctx.player.update_view(DT)
		traffic.call("step", DT)
		traffic.call("sync_visuals", DT)
		t += DT
		var inv := xf.affine_inverse()
		_measure_side(best, inv, rear, t)
		if t >= MESH_FROM_S and t <= MESH_TO_S:
			prev = _measure_mesh(best, inv, tris, prev)
	if int(best["frames"]) == 0:
		return {}
	best["spin"] = _spin_of(victim)
	best["av"] = victim.av
	best["lands"] = float(info.get("lands_in", 0.0))
	return best


## The plan's twist (rad) of the throw walker w is under, 0 with none.
func _spin_of(w: WK.Walker) -> float:
	var active: Dictionary = (traffic.get("reactions") as RefCounted).get("_active")
	var re: Object = active.get(w.id)
	if re == null or re.get("jack") == null:
		return 0.0
	return float((re.get("jack") as RefCounted).get("spin"))


## Turns the hero to look at the world point at, from where they stand.
func _face(at: Vector3) -> void:
	var from: Vector3 = ctx.player.position
	ctx.player.teleport(from, rad_to_deg(atan2(from.x - at.x, from.z - at.z)))
	ctx.player.update_view(DT)
	traffic.call("sync_visuals", DT)


## One frame's measure of how far a limb strays through the car's side plane behind the door's rear
## shut edge (rear, m; car frame inv): each bone segment of the victim's skeleton that crosses the
## plane at the height of the body side, how far behind the edge it does, into best, from
## SIDE_FROM_S.
func _measure_side(best: Dictionary, inv: Transform3D, rear: Vector3, t: float) -> void:
	var b: Object = victim.body
	if t < SIDE_FROM_S or b == null or b.get("skel") == null:
		return
	var sk: Skeleton3D = b.get("skel")
	var pos := PackedVector3Array()
	for i in range(sk.get_bone_count()):
		pos.append(inv * (sk.global_transform * sk.get_bone_global_pose(i)).origin / WS.M)
	var through := -INF
	for i in range(pos.size()):
		var rad := _radius(sk.get_bone_name(i))
		var par := sk.get_bone_parent(i)
		if rad < 0.05 or par < 0:
			continue
		var a3 := pos[par]
		var b3 := pos[i]
		if (a3.x - rear.x) * (b3.x - rear.x) >= 0.0:
			continue
		var k := (rear.x - a3.x) / (b3.x - a3.x)
		var yc := a3.y + (b3.y - a3.y) * k
		if yc > 0.4 and yc < 1.7:
			through = maxf(through, rear.z - (a3.z + (b3.z - a3.z) * k - rad))
	best["side"] = maxf(best["side"], through)
	if through > 0.05:
		best["side_s"] = float(best["side_s"]) + DT


## Radius (m) of a bone's segment by what it is, 0 for what is not counted (the face).
func _radius(nm: String) -> float:
	if nm.begins_with("Bip01") or nm.contains("Eye") or nm == "Jaw":
		return 0.0
	for d: String in ["Thumb", "Index", "Middle", "Ring", "Little"]:
		if nm.contains(d):
			return 0.02
	for t: String in ["Hips", "Spine", "Chest", "Neck", "Shoulder"]:
		if nm.contains(t):
			return 0.14
	return 0.11 if nm == "Head" else 0.05


## One frame's measure of the skinned body (every STRIDE-th vertex, in the car's frame, metres)
## against the door's triangles, tris ({"tris", "boxes", "bounds"}): the least distance, and the
## frames a vertex's step from the last frame (prev, the points then) went through a triangle.
## Returns this frame's points.
func _measure_mesh(
	best: Dictionary, inv: Transform3D, door: Dictionary, prev: PackedVector3Array
) -> PackedVector3Array:
	var pts := _skin_pts(victim.body, inv)
	best["frames"] = int(best["frames"]) + 1
	var bounds: AABB = (door["bounds"] as AABB).grow(NEAR)
	var tris: PackedVector3Array = door["tris"]
	var boxes: Array[AABB] = door["boxes"]
	var crossed := false
	for i in range(pts.size()):
		var p := pts[i]
		if not bounds.has_point(p):
			continue
		var box := AABB(p, Vector3.ZERO).grow(NEAR)
		for j in range(boxes.size()):
			if not boxes[j].intersects(box):
				continue
			var a := tris[3 * j]
			var b := tris[3 * j + 1]
			var c := tris[3 * j + 2]
			best["mesh"] = minf(best["mesh"], _tri_dist(p, a, b, c))
			if prev.size() == pts.size() and _seg_tri(prev[i], p, a, b, c):
				crossed = true
	if crossed:
		best["cross"] = int(best["cross"]) + 1
	return pts


## The door of model m swung out by amount as triangles in the car's frame (metres): {"tris" (three
## points to a triangle), "boxes" (each triangle's bounds) and "bounds" (all of them)}. Made once.
func _door_of(m: int, amount: float) -> Dictionary:
	var key := "%d:%.2f" % [m, amount]
	if _doors.has(key):
		return _doors[key]
	var mo: RefCounted = (traffic.get("render") as RefCounted).call("model", m)
	var dd: DOORS.Door = DOORS.of(str(mo.get("key")), mo.get("scene"))
	var off: Transform3D = mo.get("offset")
	var turn := Basis(Vector3.UP, -DOORS.OPEN_ANGLE * amount)
	var tris := PackedVector3Array()
	var boxes: Array[AABB] = []
	var bounds := AABB()
	var first := true
	var mesh: ArrayMesh = dd.door_mesh
	for s in range(mesh.get_surface_count()):
		var arr := mesh.surface_get_arrays(s)
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var idx := PackedInt32Array()
		if arr[Mesh.ARRAY_INDEX] != null:
			idx = arr[Mesh.ARRAY_INDEX]
		var cv := PackedVector3Array()
		for v: Vector3 in vs:
			cv.append(off * (dd.body_xf * (dd.hinge + turn * v)) / WS.M)
		var n := idx.size() if idx.size() > 0 else cv.size()
		for i in range(0, n - 2, 3):
			var tri := PackedVector3Array()
			for k in range(3):
				tri.append(cv[idx[i + k]] if idx.size() > 0 else cv[i + k])
			tris.append_array(tri)
			var box := AABB(tri[0], Vector3.ZERO).expand(tri[1]).expand(tri[2])
			boxes.append(box)
			bounds = box if first else bounds.merge(box)
			first = false
	var out := {"tris": tris, "boxes": boxes, "bounds": bounds}
	_doors[key] = out
	return out


## Every STRIDE-th vertex of the skinned body b (a people_kit body) in the frame inv (the world to
## the car's), metres, posed as it is drawn now (the skin's bind poses on the skeleton's bones).
func _skin_pts(b: Object, inv: Transform3D) -> PackedVector3Array:
	var sk: Skeleton3D = b.get("skel")
	var out := PackedVector3Array()
	var sk_xf := inv * sk.global_transform
	for g: Variant in b.get("meshes"):
		var mi := g as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var data := _mesh_data(mi)
		var vs: PackedVector3Array = data[0]
		var bones: PackedInt32Array = data[1]
		var weights: PackedFloat32Array = data[2]
		var per: int = data[3]
		var skin: Skin = mi.skin
		var mats: Array[Transform3D] = []
		for i in range(skin.get_bind_count()):
			var bone := skin.get_bind_bone(i)
			if bone < 0:
				bone = sk.find_bone(skin.get_bind_name(i))
			mats.append(
				(
					sk.get_bone_global_pose(bone) * skin.get_bind_pose(i)
					if bone >= 0
					else Transform3D()
				)
			)
		for i in range(vs.size()):
			var acc := Vector3.ZERO
			for j in range(per):
				var w := weights[i * per + j]
				if w > 0.0:
					acc += w * (mats[bones[i * per + j]] * vs[i])
			out.append(sk_xf * acc / WS.M)
	return out


## The followed vertices of mesh instance mi's mesh, their bone indices and weights (per of each),
## read once: [vertices, bones, weights, per].
func _mesh_data(mi: MeshInstance3D) -> Array:
	var key := mi.mesh.get_instance_id()
	if _meshes.has(key):
		return _meshes[key]
	var vs := PackedVector3Array()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	var per := 4
	for s in range(mi.mesh.get_surface_count()):
		var arr := mi.mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var bo: PackedInt32Array = arr[Mesh.ARRAY_BONES]
		var we: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		per = bo.size() / maxi(v.size(), 1)
		for i in range(0, v.size(), STRIDE):
			vs.append(v[i])
			for j in range(per):
				bones.append(bo[i * per + j])
				weights.append(we[i * per + j])
	var out := [vs, bones, weights, per]
	_meshes[key] = out
	return out


## The distance from point p to triangle abc: to its plane where p's projection falls inside it,
## else to the nearest of its three edges.
func _tri_dist(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> float:
	var n := (b - a).cross(c - a)
	var n2 := n.length_squared()
	if n2 > 1e-18:
		var q := p - n * ((p - a).dot(n) / n2)
		var inside := (b - a).cross(q - a).dot(n) >= 0.0 and (c - b).cross(q - b).dot(n) >= 0.0
		if inside and (a - c).cross(q - c).dot(n) >= 0.0:
			return p.distance_to(q)
	var d := p.distance_to(Geometry3D.get_closest_point_to_segment(p, a, b))
	d = minf(d, p.distance_to(Geometry3D.get_closest_point_to_segment(p, b, c)))
	return minf(d, p.distance_to(Geometry3D.get_closest_point_to_segment(p, c, a)))


## True when the segment p0-p1 goes through triangle abc (Moller-Trumbore).
func _seg_tri(p0: Vector3, p1: Vector3, a: Vector3, b: Vector3, c: Vector3) -> bool:
	var d := p1 - p0
	var e1 := b - a
	var e2 := c - a
	var h := d.cross(e2)
	var det := e1.dot(h)
	if absf(det) < 1e-12:
		return false
	var f := 1.0 / det
	var s := p0 - a
	var u := f * s.dot(h)
	if u < 0.0 or u > 1.0:
		return false
	var q := s.cross(e1)
	var v := f * d.dot(q)
	if v < 0.0 or u + v > 1.0:
		return false
	var t := f * e2.dot(q)
	return t >= 0.0 and t <= 1.0


# ------------------------------------------------------------------ the fixture


func _on_hit(at: Vector3, cause: String, info: Dictionary) -> void:
	hits.append([at, cause, info])
	victim = traffic.call("_walker_by_id", int(info.get("walker", -1)))


## The first straight lane of a road tile (not a bridge) with 3 m of free ground out from the
## driver's side of a car of door_model halfway along it; false (a failed fixture) for none.
func _pick_lane() -> bool:
	var tiles: Dictionary = (traffic.get("lanes") as LG).tiles
	var keys: Array = tiles.keys()
	keys.sort()
	for i: int in keys:
		if (tiles[i] as LG.TileInfo).bridge:
			continue
		for l: LG.Lane in (tiles[i] as LG.TileInfo).lanes:
			if l.kind == LG.STRAIGHT and _free_beside(l):
				lane = l
				lane_tile = i
				return true
	K.check(fails, false, "fixture: a straight lane with room beside a car on it")
	return false


## True when the ground out to 3 m off the driver's side of a car of door_model halfway along l is
## walkable and free at its front, middle and rear.
func _free_beside(l: LG.Lane) -> bool:
	var car := (traffic.get("vehicles") as VH).make(
		"car", "ambient", traffic.call("dims", door_model)
	)
	(traffic.get("vehicles") as VH).place(car, l, 0.5)
	var xf := Transform3D(Basis(Vector3.UP, car.yaw), car.pos)
	(traffic.get("vehicles") as VH).remove(car)
	for x_m: float in [0.4, 1.2, 2.0, 3.0]:
		for z: float in [-0.45, 0.0, 0.45]:
			var q := xf * Vector3(car.half_w + x_m * WS.M, 0.0, z * car.length)
			var g := ctx.collision.walk_height(q)
			if is_nan(g) or ctx.collision.is_blocked(Vector3(q.x, g, q.z), WS.PLAYER_RADIUS):
				return false
	return true


## A car of door_model of role stopped halfway along the lane and drawn, every other vehicle gone,
## the hero on foot beside its driver's side.
func _lane_car(role: String, rid: String = "") -> VH.Car:
	var vh: VH = traffic.get("vehicles")
	if traffic.get("_driven") != null:
		traffic.call("leave_car")
	for o: VH.Car in vh.cars.duplicate():
		vh.remove(o)
	ctx.collision.dynamic_boxes = []
	var c := vh.make("car", role, traffic.call("dims", door_model))
	c.model = door_model
	c.driver_id = rid
	vh.place(c, lane, 0.5)
	var xf := Transform3D(Basis(Vector3.UP, c.yaw), c.pos)
	ctx.player.teleport(xf * Vector3(c.half_w + WS.M, 0.0, -0.35 * c.length), 0.0)
	ctx.player.update_view(DT)
	traffic.call("sync_visuals", DT)
	return c


## A resident's car of door_model stopped on the lane with the resident drawn at its wheel (the next
## resident who can be, of up to a dozen tried), on a drive.
func _driven_car() -> VH.Car:
	var people: Array = ctx.residents.people
	var c: VH.Car = null
	for _try in range(12):
		var r: Dictionary = people[_ridx % people.size()]
		_ridx += 1
		var trip := TRIPS.Trip.new()
		trip.rid = str(r["id"])
		trip.mode = "car"
		trip.phase = "drive"
		trip.from_i = int(r["home"])
		trip.to_i = int(r["work"]) if int(r["work"]) >= 0 else trip.from_i
		var front: int = ctx.directory.frontage(trip.to_i)
		trip.dest_tile = front if (traffic.get("lanes") as LG).tiles.has(front) else lane_tile
		c = _lane_car("resident", trip.rid)
		trip.car = c
		c.owner = trip
		(traffic.get("trips") as TRIPS).trips[trip.rid] = trip
		(traffic.get("trips") as TRIPS).cars[trip.rid] = c
		traffic.call("sync_visuals", DT)
		if (traffic.get("occupants") as RefCounted).call("driver_of", c.id) != null:
			break
	return c
