extends SceneTree
## A carjack's throw (jack_throw.gd, the carjack_throw flag; docs/fp/ARCHITECTURE.md, Integration:
## driving). The curves are pure functions of time: monotone where the sequence has a phase,
## continuous where one hands on to the next, finite everywhere. The driver pulled out and thrown
## through reactions.gd comes out over the sill in HAUL_S, flies the plan's arc with the knockback
## clip's back meeting the ground at touchdown, lands beyond the door and clear of the car body,
## then gets up and the reaction ends as it did before; the same twice; the blow's strength sets
## the height, the air time and the twist (its direction the door's when there is one); the turn to
## face the car is never faster than TURN_RATE and the whole facing stays within SPIN_RATE; a moving
## car carries the body on at its pace (the haul all of it, easing down over its last CARRY_EASE_S
## to the flight's, at most CARRY_MAX); either flag off (carjack_throw, hit_feel) is the old drag
## and throw. The bodies are bare walkers with no
## collision world, stepped by hand; the whole flow through a grown city is fp_carjack_test's, the
## room beside the door fp_jack_room_test's, the landing's shake and sound fp_jack_touchdown_test's,
## the haul let go down the car's side and the easing of a fast car's pace fp_jack_haul_test's.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const RE := preload("res://scripts/fp/traffic/reactions.gd")
const JT := preload("res://scripts/fp/traffic/jack_throw.gd")
const CJ := preload("res://scripts/fp/traffic/carjack.gd")
const BANK := preload("res://scripts/fp/audio/audio_bank.gd")
const DT := 1.0 / 60.0
const SEED := 12
## The car stands at the origin heading +Z, its driver's side +X: half its width, where the seat's
## feet are in it (x, then y above the road) and where the driver comes out beside the door.
const HALF_W := 0.9 * WS.M
const SEAT_X := 0.45 * WS.M
const SEAT_Y := 0.15 * WS.M
const SEAT_Z := -0.2 * WS.M
## The blow: strength and metres flung, as carjack.gd has them.
const STRENGTH := CJ.STRENGTH
const FLING := CJ.JACK_FLING
## The lying body reaches this far toward the car from the feet (m, the clip's toes).
const TOES_M := 0.7
const REST_S := 12.0

var fails: Array[String] = []
var ctx: FpContext
var hf: FpFeature
## The whole sequence of the default blow (the flag off section compares the knockdown's lie).
var on_run: Dictionary = {}
## The sections that ran to their end (a script error inside one would otherwise pass quietly).
var ran: Array[String] = []


func _init() -> void:
	await process_frame
	# The look is hit_feel's, as the throw's arc is: the checks do not depend on the user's flags.
	FeatureFlags.set_override("hit_feel", true)
	FeatureFlags.set_override("carjack_throw", true)
	_check_curves()
	_check_make()
	var a := _check_throw()
	on_run = a
	_check_twice(a)
	_check_no_haul()
	_check_strength()
	_check_carry()
	_check_turn_rate()
	_check_flip()
	_check_flag_off()
	FeatureFlags.reload()
	K.check(fails, ran.size() == 10, "every section ran to its end (%s)" % str(ran))
	K.finish(self, "FP_CARJACK_THROW_TEST", fails)


# ------------------------------------------------------------------ the curves


func _finite(v: float) -> bool:
	return not is_nan(v) and not is_inf(v)


## True when f is non-decreasing (or non-increasing) over 0..1 sampled n times, from a to b.
func _monotone(f: Callable, up: bool, a: float, b: float, n: int = 200) -> bool:
	var prev := float(f.call(0.0))
	if not is_equal_approx(prev, a):
		return false
	for k in range(1, n + 1):
		var v := float(f.call(float(k) / float(n)))
		if (v < prev - 1e-9 if up else v > prev + 1e-9) or not _finite(v):
			return false
		prev = v
	return is_equal_approx(prev, b)


## The phases are monotone, the hand-offs continuous, nothing is NaN.
func _check_curves() -> void:
	var p := JT.make(STRENGTH, FLING, Vector3(1.0, 0.0, 0.0), 1.0)
	p.haul = true
	p.lean = JT.HEAD_OUT
	p.turn_t = Vector2(JT.TURN.x * JT.HAUL_S, (JT.TURN.y - JT.TURN.x) * JT.HAUL_S)
	for m1: float in [1.0, 1.32, 2.0, 2.5]:
		var ok := _monotone(func(x: float) -> float: return JT.pull(x, m1), true, 0.0, 1.0)
		K.check(
			fails, ok, "the pull goes from the seat to the door and only forward (m1 %.2f)" % m1
		)
		var h := 1e-4
		var slope := (JT.pull(1.0, m1) - JT.pull(1.0 - h, m1)) / h
		K.check(
			fails, absf(slope - m1) < 0.01, "and ends at speed m1 (%.3f for %.2f)" % [slope, m1]
		)
	K.check(
		fails,
		_monotone(func(x: float) -> float: return JT.lift(x), true, 0.0, JT.LIFT),
		"the haul lifts the hips over the sill, rising to the release"
	)
	K.check(
		fails,
		_monotone(func(x: float) -> float: return JT.turn_at(x * JT.HAUL_S, p), true, 0.0, 1.0),
		"the body turns to face the car through the haul, once"
	)
	K.check(
		fails,
		_monotone(func(x: float) -> float: return JT.haul_lean(x, p), true, 0.0, JT.HEAD_OUT),
		"the lean out of the seat only grows to HEAD_OUT"
	)
	K.check(
		fails,
		_monotone(func(t: float) -> float: return JT.fly_lean(t, p), false, JT.HEAD_OUT, 0.0),
		"and only eases out through the flight, gone at touchdown"
	)
	K.check(
		fails,
		_monotone(func(t: float) -> float: return JT.clip_at(t), true, 0.0, JT.T_CONTACT),
		"the fall clip runs on from its start to its back on the ground, at touchdown"
	)
	K.check(
		fails,
		_monotone(func(t: float) -> float: return JT.fly_lift(t, p), false, JT.LIFT, 0.0),
		"the haul's lift falls away through the flight (the arc takes over)"
	)
	var seam := absf(JT.haul_lean(1.0, p) - JT.fly_lean(0.0, p))
	seam = maxf(seam, absf(JT.lift(1.0) - JT.fly_lift(0.0, p)))
	K.check(fails, seam < 1e-9, "the haul hands the lean and the lift on to the flight unbroken")
	K.check(
		fails,
		is_zero_approx(JT.twist(0.0, p)) and is_zero_approx(JT.twist(1.0, p)),
		"no twist at the release or at touchdown"
	)
	K.check(
		fails,
		is_equal_approx(JT.twist(0.5, p), p.spin) and JT.twist(0.3, p) * p.spin > 0.0,
		"the twist peaks mid-flight at the plan's spin, the way the plan says"
	)
	var bad := 0
	for k in range(0, 401):
		var u := -0.2 + 1.4 * float(k) / 400.0
		for v: float in [
			JT.pull(u, 1.5),
			JT.lift(u),
			JT.turn_at(u * JT.HAUL_S, p),
			JT.haul_lean(u, p),
			JT.fly_lean(u, p)
		]:
			bad += 0 if _finite(v) else 1
		for v: float in [JT.fly_lift(u, p), JT.twist(u, p), JT.clip_at(u)]:
			bad += 0 if _finite(v) else 1
	K.check(fails, bad == 0, "every curve is finite, in range or out of it (%d bad)" % bad)
	# Facing away from the door the body leans back; seated facing forward, door on its left, it
	# leans left (negative roll: the body's +X is its left).
	var back := JT.tilt_roll(0.5, Vector3(1, 0, 0), atan2(-1.0, 0.0))
	K.check(
		fails,
		is_equal_approx(back.x, -0.5) and absf(back.y) < 1e-6,
		"facing away from the door the body leans back (%s)" % str(back)
	)
	var seat := JT.tilt_roll(0.5, Vector3(1, 0, 0), 0.0)
	K.check(
		fails,
		absf(seat.x) < 1e-6 and is_equal_approx(seat.y, -0.5),
		"seated facing forward it leans toward the door on its left (%s)" % str(seat)
	)
	ran.append("curves")


## The plan: harder blows fly higher, stay up longer and twist more; the fall clip's pace puts
## its back on the ground at touchdown; a blow of nothing is still finite.
func _check_make() -> void:
	var weak := JT.make(0.7, FLING, Vector3(2.0, 0.0, 0.0), 1.0)
	var hard := JT.make(1.0, FLING, Vector3(2.0, 0.0, 0.0), 1.0)
	var better := hard.apex > weak.apex and hard.air > weak.air and hard.spin > weak.spin
	K.check(fails, better, "a harder blow flies higher, longer and twists more")
	K.check(
		fails,
		weak.apex > 0.15 and hard.apex < 0.5 and weak.air > 0.3 and hard.air < 0.7,
		(
			"in reach of a body: apex %.2f to %.2f m, %.2f to %.2f s"
			% [weak.apex, hard.apex, weak.air, hard.air]
		)
	)
	var meets := absf(hard.rate * hard.air - JT.T_CONTACT) < 1e-9
	K.check(
		fails, meets, "the slowed clip's back meets the ground at touchdown (pace %.2f)" % hard.rate
	)
	K.check(fails, is_equal_approx(hard.door.length(), 1.0), "the door direction is a level unit")
	K.check(
		fails,
		JT.make(STRENGTH, FLING, Vector3.RIGHT, -1.0).spin < 0.0,
		"the flip sign turns the twist the other way"
	)
	var base := JT.make(STRENGTH, FLING, Vector3.RIGHT, 1.0)
	var faced := JT.make(STRENGTH, FLING, Vector3.RIGHT, 1.0, 0.3)
	K.check(
		fails,
		absf(angle_difference(base.yaw_f, faced.yaw_f) - 0.3) < 1e-9 and faced.door == base.door,
		"the facing at the release can be turned off facing the way they came from, the line kept"
	)
	var zero := JT.make(0.0, 0.0, Vector3.RIGHT, 1.0)
	K.check(
		fails,
		_finite(zero.air) and zero.air > 0.0 and _finite(zero.rate) and _finite(zero.skid),
		"no strength, no fling: still finite"
	)
	ran.append("make")


# ------------------------------------------------------------------ through reactions


## A walker at the door of the car, a reaction layer with no collision world, and the car's
## seat: the stage for one throw.
func _stage(origin: Vector3 = Vector3.ZERO) -> Dictionary:
	var wk := WK.new()
	wk.setup(null, null, null, null, SEED)
	var w := wk.make("ambient")
	var at := origin + Vector3(HALF_W + CJ.OUT, 0.0, SEAT_Z)
	wk.stand(w, at, 0.0)
	w.state = "walk"
	var re := RE.new()
	re.setup(wk, null, SEED)
	return {"wk": wk, "w": w, "re": re, "at": at}


## One carjack through reactions.gd, stepped by hand to the reaction's end: the hit's result,
## the plan, and a frame by frame record. strength and carry (u/s, the car's pace) and whether the
## driver is drawn at the wheel (haul) are the scenario's.
func _throw(strength: float, carry: Vector3 = Vector3.ZERO, haul: bool = true) -> Dictionary:
	var s := _stage()
	var re: RE = s["re"]
	var w: WK.Walker = s["w"]
	var at: Vector3 = s["at"]
	var src := Vector3(HALF_W + 1.0 * WS.M, 0.0, 0.5 * WS.M)
	w.carry = carry
	w.seated = haul
	var res := re.hit(w, src, Vector3.RIGHT, strength, "carjack", FLING)
	var r: RE.Reaction = (re.get("_active") as Dictionary).get(w.id)
	var rec := {"res": res, "w": w, "at": at, "frames": [], "plan": r.jack if r != null else null}
	rec["left0"] = r.left if r != null else NAN  # the knockdown's seconds, before any haul
	var from := Vector3(SEAT_X, SEAT_Y, SEAT_Z)
	if haul and r != null:
		re.drag_out(w, from, 0.0)
	var frames: Array = rec["frames"]
	var t := 0.0
	while re.count() > 0 and t < REST_S:
		re.step(DT)
		t += DT
		frames.append(_frame(t, w, r))
	rec["end_t"] = t
	rec["reaction_ended"] = re.count() == 0
	rec["reaction"] = r
	return rec


## One frame of the record: the time, the drawn feet, tip, roll, facing, the clip, its pace, the
## mode of the step, the throw's clock, the arc's height now and the clip clock the walker keeps.
func _frame(t: float, w: WK.Walker, r: RE.Reaction) -> Array:
	return [
		t,
		w.pos + w.vis_off,
		w.vis_tilt,
		w.vis_roll,
		w.yaw,
		w.react,
		w.react_rate,
		r.mode,
		r.fly_t,
		r.bump,
		w.react_t
	]


## The frame index at which the clip first reads clip, or -1.
func _first(rec: Dictionary, clip: StringName) -> int:
	var frames: Array = rec["frames"]
	for i in range(frames.size()):
		if (frames[i] as Array)[5] == clip:
			return i
	return -1


## The whole sequence, front to back: the haul, the flight, the landing and the get-up.
func _check_throw() -> Dictionary:
	var a := _throw(STRENGTH)
	var res: Dictionary = a["res"]
	var p: JT.Plan = a["plan"]
	var frames: Array = a["frames"]
	K.check(
		fails, bool(res.get("down", false)) and p != null, "the blow knocks them down, on the plan"
	)
	K.check(
		fails,
		p != null and absf(float(res.get("lands_in", -1.0)) - (JT.HAUL_S + p.air)) < 1e-9,
		"and says when they land: the haul and the air (%.2f s)" % float(res.get("lands_in", NAN))
	)
	var sit := _first(a, RE.DRAG_CLIP)
	var down := _first(a, &"knockback")
	var up := _first(a, &"get_up")
	K.check(fails, sit == 0 and down > sit and up > down, "sit, knockback, get_up in that order")
	K.check(
		fails,
		absf(float(down) * DT - JT.HAUL_S) <= 2.0 * DT,
		"the haul takes HAUL_S (%.2f s)" % (float(down) * DT)
	)
	# The haul: out along the door, never back, over the sill, hips not under the road.
	var lateral := -INF
	var back := 0
	var top := 0.0
	var low := INF
	for i in range(0, down):
		var f: Array = frames[i]
		var x: float = (f[1] as Vector3).x
		back += 1 if x < lateral - 1e-9 else 0
		lateral = maxf(lateral, x)
		top = maxf(top, (f[1] as Vector3).y)
		low = minf(low, (f[1] as Vector3).y)
	K.check(fails, back == 0, "hauled out along the door, never back (%d steps back)" % back)
	K.check(
		fails,
		low > -1e-6 and top <= SEAT_Y + JT.LIFT + 1e-6,
		"over the sill by %.2f m, never under the road (%.3f)" % [top / WS.M, low / WS.M]
	)
	var at: Vector3 = a["at"]
	var out: float = ((frames[down - 1] as Array)[1] as Vector3).x
	K.check(
		fails,
		out >= at.x - 0.1 * WS.M,
		"it ends the haul beside the door (%.2f m out)" % ((out - HALF_W) / WS.M)
	)
	_check_haul(a, p, down)
	_check_flight(a, p, down)
	_check_landing(a, down)
	_check_smooth(a)
	_check_handoff(a)
	ran.append("throw")
	return a


## The haul's own numbers: leaning out head first by HEAD_OUT as it clears the sill, ending at the
## pace the flight carries on at (the body is neither stopped at the door nor held a frame there),
## the fall clip's clock starting at 0 as a mixer's does.
func _check_haul(a: Dictionary, p: JT.Plan, down: int) -> void:
	var frames: Array = a["frames"]
	var at: Vector3 = a["at"]
	var last := frames[down - 1] as Array
	var lean := Vector2(float(last[2]), float(last[3])).length()
	K.check(
		fails,
		absf(lean - JT.HEAD_OUT) < 0.02,
		"leaning out by HEAD_OUT as it clears the sill (%.3f of %.2f rad)" % [lean, JT.HEAD_OUT]
	)
	var span := Vector2(at.x - SEAT_X, at.z - SEAT_Z).length() / WS.M
	var end_speed := p.m1 * span / JT.HAUL_S
	var want := JT.release_speed(p)
	K.check(
		fails,
		p.m1 > 1.0 and p.m1 < 2.5 and absf(end_speed - want) < 0.03 * want,
		"the haul ends at the flight's pace (%.2f m/s, the flight's %.2f)" % [end_speed, want]
	)
	var lo := INF
	var hi := 0.0
	for i in range(down - 3, down + 4):
		var d := (frames[i][1] as Vector3) - (frames[i - 1][1] as Vector3)
		var along := Vector2(d.x, d.z).length()
		lo = minf(lo, along)
		hi = maxf(hi, along)
	K.check(
		fails,
		lo > 0.8 * hi,
		(
			"no stall or jump in the ground speed at the hand-off (%.3f to %.3f m a frame)"
			% [lo / WS.M, hi / WS.M]
		)
	)
	var start := float((frames[down] as Array)[10])
	K.check(
		fails,
		start < 0.02,
		"the fall clip's clock starts from its beginning (%.3f s in as it begins)" % start
	)


## The flight: the arc's height, the clip meeting the ground at touchdown, the twist, the lean.
func _check_flight(a: Dictionary, p: JT.Plan, down: int) -> void:
	var frames: Array = a["frames"]
	var w: WK.Walker = a["w"]
	var top := 0.0
	var land := -1
	var twist := 0.0
	var tilt := 0.0
	var roll := 0.0
	var rate_ok := true
	var clip_at_land := NAN
	for i in range(down, frames.size()):
		var f: Array = frames[i]
		if str(f[7]) != "place" or f[5] != &"knockback":
			break
		var flying := float(f[8]) < p.air
		top = maxf(top, float(f[9]))
		if flying:
			twist = maxf(twist, absf(angle_difference(float(f[4]), p.yaw_f)))
			tilt = maxf(tilt, absf(float(f[2])))
			roll = maxf(roll, absf(float(f[3])))
			rate_ok = rate_ok and (float(f[8]) == 0.0 or is_equal_approx(float(f[6]), p.rate))
		elif land < 0:
			land = i
			clip_at_land = float(f[8])
	var expect := 0.0
	for k in range(0, 1001):
		var tau := float(k) / 1000.0
		expect = maxf(expect, 4.0 * p.apex * WS.M * tau * (1.0 - tau) + JT.fly_lift(tau, p))
	K.check(
		fails,
		absf(top - expect) < 0.06 * WS.M and top > p.apex * WS.M,
		(
			"the arc tops out %.2f m up (the plan's %.2f m and the haul's lift %.2f)"
			% [top / WS.M, p.apex, expect / WS.M]
		)
	)
	K.check(fails, land > down, "and comes down (touchdown after %d frames)" % (land - down))
	var air_s := float(land - down) * DT
	K.check(
		fails,
		absf(air_s - p.air) <= 2.0 * DT,
		"in the plan's time in the air (%.2f of %.2f s)" % [air_s, p.air]
	)
	K.check(fails, rate_ok, "the fall clip plays at the plan's pace all the way through the air")
	K.check(
		fails,
		twist > 0.85 * absf(p.spin) and twist <= absf(p.spin) + 1e-6,
		"it twists %.2f rad at most (the plan's %.2f)" % [twist, absf(p.spin)]
	)
	K.check(
		fails,
		tilt <= JT.HEAD_OUT + 1e-6 and roll <= JT.HEAD_OUT + 1e-6,
		"leaning out by no more than HEAD_OUT (tip %.2f, roll %.2f)" % [tilt, roll]
	)
	var after := frames[mini(land + 1, frames.size() - 1)] as Array
	K.check(
		fails,
		(
			is_equal_approx(float(after[6]), 1.0)
			and absf(angle_difference(float(after[4]), p.yaw_f)) < 1e-6
		),
		(
			"from touchdown the clip is at its own pace and the facing back to square (%.3f)"
			% float(after[6])
		)
	)
	print(
		(
			(
				"  numbers: haul %.2f s, air %.2f s, apex %.2f m (arc) %.2f m (with the lift), "
				+ "twist %.2f rad, clip pace %.2f (%.2f at touchdown %.2f), lean out %.2f rad"
			)
			% [
				float(down) * DT,
				air_s,
				p.apex,
				top / WS.M,
				twist,
				p.rate,
				JT.clip_at(1.0),
				clip_at_land,
				tilt
			]
		)
	)


## The landing: beyond the door, clear of the car's body, the whole fling spent.
func _check_landing(a: Dictionary, down: int) -> void:
	var frames: Array = a["frames"]
	var at: Vector3 = a["at"]
	var rest := Vector3.ZERO
	var settled := -1
	for i in range(down, frames.size()):
		var f: Array = frames[i]
		if str(f[7]) == "place" and f[5] == &"get_up":
			rest = f[1]
			settled = i
			break
	K.check(fails, settled > down, "fixture: the body came to rest before it got up")
	var flung := (rest.x - at.x) / WS.M
	K.check(
		fails,
		absf(flung - FLING) < 0.02 and absf(rest.z - at.z) < 0.02 * WS.M,
		(
			"it lands the whole fling (%.2f m) straight out from the door (%.3f m along)"
			% [flung, (rest.z - at.z) / WS.M]
		)
	)
	var toes := (rest.x - HALF_W) / WS.M - TOES_M
	K.check(
		fails,
		toes >= 0.5,
		(
			"its feet, lying, clear of the car's body by %.2f m (%.2f m out at the root)"
			% [toes, (rest.x - HALF_W) / WS.M]
		)
	)
	var floor_y := 1e9
	for i in range(settled, frames.size()):
		floor_y = minf(floor_y, ((frames[i] as Array)[1] as Vector3).y)
	K.check(fails, floor_y > -1e-6, "and never through the road (%.4f m)" % (floor_y / WS.M))
	K.check(
		fails,
		a["reaction_ended"] and (a["w"] as WK.Walker).react == &"",
		"then it gets up and the reaction ends (%.1f s)" % float(a["end_t"])
	)


## Nothing pops: the feet, the facing and the lean change by a little each frame, never by a jump.
func _check_smooth(a: Dictionary) -> void:
	var frames: Array = a["frames"]
	var step := 0.0
	var turn := 0.0
	var lean := 0.0
	var nan := 0
	for i in range(1, frames.size()):
		var f: Array = frames[i]
		var g: Array = frames[i - 1]
		if str(f[7]) == "back":
			break
		step = maxf(step, ((f[1] as Vector3) - (g[1] as Vector3)).length())
		turn = maxf(turn, absf(angle_difference(float(f[4]), float(g[4]))))
		lean = maxf(lean, absf(float(f[2]) - float(g[2])) + absf(float(f[3]) - float(g[3])))
	for f: Array in frames:
		for v: Variant in [f[2], f[3], f[4], f[6], f[8], f[9]]:
			nan += 0 if _finite(float(v)) else 1
		nan += 0 if (f[1] as Vector3).is_finite() else 1
	K.check(fails, nan == 0, "no frame holds a NaN (%d)" % nan)
	K.check(
		fails,
		step < 0.12 * WS.M,
		"no frame moves the body more than 12 cm (%.3f m)" % (step / WS.M)
	)
	K.check(fails, turn < 0.2, "none turns it more than 0.2 rad (%.3f)" % turn)
	K.check(fails, lean < 0.2, "none tips it more than 0.2 rad (%.3f)" % lean)


## The reaction ends as it did: up, the walker's own state back, nothing left tipped or offset.
func _check_handoff(a: Dictionary) -> void:
	var w: WK.Walker = a["w"]
	var ok: bool = a["reaction_ended"] and w.react == &"" and w.state == "walk"
	ok = ok and is_zero_approx(w.vis_tilt) and is_zero_approx(w.vis_roll)
	K.check(
		fails,
		ok,
		"the hand-off: walking again, upright, clip given back (%s %s)" % [w.state, str(w.react)]
	)
	ok = w.vis_off.length() < 0.02 * WS.M and is_equal_approx(w.react_rate, 1.0)
	K.check(fails, ok, "and back where it stood (%.3f m off)" % (w.vis_off.length() / WS.M))


## The same blow twice: the same body, frame for frame.
func _check_twice(a: Dictionary) -> void:
	var b := _throw(STRENGTH)
	var fa: Array = a["frames"]
	var fb: Array = b["frames"]
	var same := fa.size() == fb.size()
	if same:
		for i in range(fa.size()):
			var x: Array = fa[i]
			var y: Array = fb[i]
			same = same and (x[1] as Vector3) == (y[1] as Vector3) and x[2] == y[2] and x[3] == y[3]
			same = same and x[4] == y[4] and x[5] == y[5] and x[6] == y[6] and x[9] == y[9]
	K.check(
		fails, same, "the same blow twice is the same fall, frame for frame (%d frames)" % fa.size()
	)
	ran.append("twice")


## Driver not drawn at the wheel (no haul): the flight alone, level, as the plain throw would
## stand, and the fall still carries on to the get-up.
func _check_no_haul() -> void:
	var a := _throw(STRENGTH, Vector3.ZERO, false)
	var p: JT.Plan = a["plan"]
	var lean := 0.0
	var lift := 0.0
	for f: Array in a["frames"]:
		if f[5] != &"knockback":
			continue
		lean = maxf(lean, absf(float(f[2])) + absf(float(f[3])))
		lift = maxf(lift, float(f[9]) - 4.0 * p.apex * WS.M * 0.25)
	K.check(fails, p != null and not p.haul, "no driver at the wheel, no haul")
	var told := float((a["res"] as Dictionary).get("lands_in", -1.0))
	K.check(
		fails,
		p != null and absf(told - p.air) < 1e-9,
		"and it lands when the air is over (%.2f s)" % told
	)
	K.check(
		fails,
		lean < 1e-6 and lift < 0.01 * WS.M,
		(
			"the flight then starts level from the ground (lean %.3f, extra lift %.3f m)"
			% [lean, lift / WS.M]
		)
	)
	K.check(fails, a["reaction_ended"], "and ends as ever, up again")
	ran.append("no_haul")


## The blow's strength sets the arc: the same fling thrown by 0.72 and by 1.0.
func _check_strength() -> void:
	var weak := _throw(0.72)
	var hard := _throw(1.0)
	var pw: JT.Plan = weak["plan"]
	var ph: JT.Plan = hard["plan"]
	K.check(
		fails,
		pw != null and ph != null and ph.apex > pw.apex and ph.air > pw.air,
		(
			"in reactions: a harder blow flies higher (%.2f to %.2f m) and longer (%.2f to %.2f s)"
			% [pw.apex, ph.apex, pw.air, ph.air]
		)
	)
	var wr: RE.Reaction = weak["reaction"]
	var hr: RE.Reaction = hard["reaction"]
	K.check(
		fails,
		hr.fly_s > wr.fly_s and is_equal_approx(hr.fly_s, ph.air),
		"and that is the reaction's own time in the air (%.2f to %.2f s)" % [wr.fly_s, hr.fly_s]
	)
	ran.append("strength")


## A car going 4 m/s along +Z: the driver keeps its pace, hauled out in its frame (no hanging
## behind it) and flung on along the road, the same landing beside it.
func _check_carry() -> void:
	var v := 4.0 * WS.M
	var carry := Vector3(0.0, 0.0, v)
	var a := _throw(STRENGTH, carry)
	var p: JT.Plan = a["plan"]
	var at: Vector3 = a["at"]
	var drift := _haul_drift(a, v)
	K.check(
		fails,
		drift < 0.02 * WS.M,
		(
			"hauled out in the moving car's own frame, level with the seat (%.3f m drift)"
			% (drift / WS.M)
		)
	)
	var rest := _rest_of(a)
	var along := (rest.z - at.z) / WS.M
	var want := 4.0 * (JT.HAUL_S + p.air / (1.0 - p.skid))
	K.check(
		fails,
		absf(along - want) < 0.05,
		"flung on down the road at the car's pace: %.2f m (%.2f expected)" % [along, want]
	)
	var out := (rest.x - at.x) / WS.M
	K.check(
		fails,
		absf(out - FLING) < 0.02,
		"and as far out from the door as when stopped (%.2f m)" % out
	)
	K.check(
		fails,
		absf(angle_difference(p.yaw_f, atan2(-(rest.x - at.x), -(rest.z - at.z)))) < 0.3,
		"the facing at the release is against the way it travels"
	)
	# Not drawn at the wheel (no haul): the flight alone still goes on at the car's pace.
	var n := _throw(STRENGTH, carry, false)
	var pn: JT.Plan = n["plan"]
	var nrest := _rest_of(n)
	var nalong := (nrest.z - at.z) / WS.M
	var nwant := 4.0 * pn.air / (1.0 - pn.skid)
	K.check(
		fails,
		absf(nalong - nwant) < 0.05 and pn.carry.length() > 0.0,
		"with no haul it is still thrown on at the car's pace: %.2f m (%.2f)" % [nalong, nwant]
	)
	var still := CJ._carry(_car(0.5 * WS.M))
	var slow := CJ._carry(_car(1.5 * WS.M))
	var fast := CJ._carry(_car(20.0 * WS.M))
	K.check(
		fails,
		(
			still == Vector3.ZERO
			and slow.length() > 0.0
			and is_equal_approx(fast.length(), 20.0 * WS.M)
		),
		(
			"a car crawling carries nobody on; a fast one carries them at its whole pace (%.2f m/s)"
			% (fast.length() / WS.M)
		)
	)
	_check_carry_fast(20.0 * WS.M)
	ran.append("carry")


## A car at 20 m/s (past CARRY_MAX): the haul stays level with the seat, the car's own pace (the
## seat moves with it), until the last CARRY_EASE_S, when it eases down to the pace the flight
## keeps; the flight keeps CARRY_MAX of it, no more.
func _check_carry_fast(v: float) -> void:
	var a := _throw(STRENGTH, Vector3(0.0, 0.0, v))
	var p: JT.Plan = a["plan"]
	var at: Vector3 = a["at"]
	var from := JT.HAUL_S - JT.CARRY_EASE_S
	var drift := _haul_drift(a, v, from)
	K.check(
		fails,
		drift < 0.02 * WS.M,
		(
			"at %.0f m/s the haul keeps the seat's pace until it eases down (%.3f m drift)"
			% [v / WS.M, drift / WS.M]
		)
	)
	var slip := (v - JT.CARRY_MAX) * JT.CARRY_EASE_S * 0.5
	var ends := _haul_drift(a, v, JT.HAUL_S)
	K.check(
		fails,
		ends > 0.8 * slip and ends < slip + 0.03 * WS.M,
		(
			"and falls back %.2f m of it by the release (%.2f m when it is done)"
			% [ends / WS.M, slip / WS.M]
		)
	)
	var rest := _rest_of(a)
	var along := (rest.z - at.z) / WS.M
	var want := 20.0 * JT.HAUL_S - slip / WS.M + 5.0 * p.air / (1.0 - p.skid)
	K.check(
		fails,
		is_equal_approx(p.carry.length(), JT.CARRY_MAX) and absf(along - want) < 0.05,
		"and the flight only CARRY_MAX of it: %.2f m down the road (%.2f expected)" % [along, want]
	)


## How far (u) the hauled body strays, along +Z, from the seat of a car going v u/s along it, up to
## t seconds into the haul.
func _haul_drift(a: Dictionary, v: float, t: float = 1e9) -> float:
	var frames: Array = a["frames"]
	var at: Vector3 = a["at"]
	var drift := 0.0
	for i in range(0, _first(a, &"knockback")):
		var f: Array = frames[i]
		if float(f[0]) > t + 1e-6:
			break
		drift = maxf(drift, absf((f[1] as Vector3).z - at.z - v * float(f[0])))
	return drift


## Where the body's drawn feet were as it began to get up.
func _rest_of(a: Dictionary) -> Vector3:
	for f: Array in a["frames"]:
		if f[5] == &"get_up":
			return f[1]
	return Vector3.ZERO


## A car heading +Z at speed v u/s, for carjack.gd's carry.
func _car(v: float) -> VH.Car:
	var c := VH.Car.new()
	c.v = v
	c.yaw = 0.0
	return c


## The turn to face the car is never faster than TURN_RATE, whatever the car's pace: a moving car
## carries the release facing round far past the stopped car's 90 degrees (155 at 8 m/s, which the
## haul's own window would do at 12 rad/s), so it takes longer, on into the flight; the facing at
## touchdown is the same, and the whole sequence, twist and all, stays within SPIN_RATE.
func _check_turn_rate() -> void:
	var worst_haul := 0.0
	var worst_all := 0.0
	for v_ms: float in [0.0, 4.0, 8.3, 14.0, 20.0]:
		var a := _throw(STRENGTH, Vector3(0.0, 0.0, v_ms * WS.M))
		var p: JT.Plan = a["plan"]
		var frames: Array = a["frames"]
		var down := _first(a, &"knockback")
		var peak_haul := 0.0
		var peak_all := 0.0
		var prev := 0.0  # the seat's facing, which drag_out is given
		for i in range(frames.size()):
			var f: Array = frames[i]
			if float(f[8]) > p.air + DT or i > down + 80:
				break
			var rate := absf(angle_difference(prev, float(f[4]))) / DT
			prev = float(f[4])
			peak_all = maxf(peak_all, rate)
			if i < down:
				peak_haul = maxf(peak_haul, rate)
		var turned := absf(angle_difference(0.0, p.yaw_f))
		var in_haul := absf(angle_difference(0.0, float((frames[maxi(down - 1, 0)] as Array)[4])))
		var msg := (
			"a car at %.1f m/s: to face the car it turns %.0f degrees, "
			% [v_ms, rad_to_deg(turned)]
		)
		msg += "%.0f of them in the haul, " % rad_to_deg(in_haul)
		msg += "at %.1f rad/s at most there (%.1f)" % [peak_haul, JT.TURN_RATE]
		K.check(fails, peak_haul <= JT.TURN_RATE + 1e-6, msg)
		K.check(
			fails,
			peak_all <= JT.SPIN_RATE + 1e-6,
			(
				"and the whole sequence, twist and all, at %.2f rad/s at most (%.1f)"
				% [peak_all, JT.SPIN_RATE]
			)
		)
		var at_touch := float(frames[mini(down + roundi(p.air / DT) + 1, frames.size() - 1)][4])
		K.check(
			fails,
			absf(angle_difference(at_touch, p.yaw_f)) < 0.05,
			(
				"it comes down facing as the plan says, tail first (%.3f rad off)"
				% angle_difference(at_touch, p.yaw_f)
			)
		)
		if v_ms == 8.3:
			K.check(
				fails,
				turned > 2.4,
				"the moving car's turn is the big one (%.0f degrees)" % rad_to_deg(turned)
			)
		worst_haul = maxf(worst_haul, peak_haul)
		worst_all = maxf(worst_all, peak_all)
	print("  turn rates: haul peak %.2f rad/s, whole sequence %.2f rad/s" % [worst_haul, worst_all])
	ran.append("turn_rate")


## The twist's direction is the blow's own when carjack.gd says one (jack_flip: away from the open
## door), who they are (the walker's id) when it does not.
func _check_flip() -> void:
	for jf: float in [-1.0, 1.0, 0.0]:
		for id_odd: int in [0, 1]:
			var s := _stage()
			var w: WK.Walker = s["w"]
			w.id = (w.id & ~1) | id_odd
			w.jack_flip = jf
			var re: RE = s["re"]
			re.hit(
				w,
				Vector3(HALF_W + 1.0 * WS.M, 0.0, 0.5 * WS.M),
				Vector3.RIGHT,
				STRENGTH,
				"carjack",
				FLING
			)
			var r: RE.Reaction = (re.get("_active") as Dictionary).get(w.id)
			var want := jf if jf != 0.0 else 1.0 - 2.0 * float(id_odd)
			K.check(
				fails,
				r != null and r.jack != null and signf(r.jack.spin) == want,
				(
					"jack_flip %+.0f, id %s: the twist goes %+.0f"
					% [jf, "odd" if id_odd == 1 else "even", want]
				)
			)
	# The facing at the release: turned by jack_face off facing the way they came from, stopped and
	# in a moving car (whose release facing is against the way it travels), 0 with none given.
	for carry: Vector3 in [Vector3.ZERO, Vector3(0.0, 0.0, 8.0 * WS.M)]:
		var plain_yaw := 0.0
		for face: float in [0.0, 0.35, -0.35]:
			var s := _stage()
			var w: WK.Walker = s["w"]
			w.jack_face = face
			w.carry = carry
			var re: RE = s["re"]
			re.hit(
				w,
				Vector3(HALF_W + 1.0 * WS.M, 0.0, 0.5 * WS.M),
				Vector3.RIGHT,
				STRENGTH,
				"carjack",
				FLING
			)
			var r: RE.Reaction = (re.get("_active") as Dictionary).get(w.id)
			var yaw := r.jack.yaw_f if r != null and r.jack != null else NAN
			if face == 0.0:
				plain_yaw = yaw
			K.check(
				fails,
				absf(angle_difference(plain_yaw, yaw) - face) < 1e-9,
				(
					"jack_face %+.2f turns the facing at the release by it (%.0f m/s car)"
					% [face, carry.length() / WS.M]
				)
			)
	ran.append("flip")


## The flag off: the old drag (0.5 s, the sit pose tipped back) and the old throw, no plan, nothing
## said about when they land.
func _check_flag_off() -> void:
	# The look is the carjack_throw flag's and hit_feel's both: either off is the old throw.
	for off: String in ["carjack_throw", "hit_feel"]:
		FeatureFlags.set_override(off, false)
		var a := _throw(STRENGTH)
		var res: Dictionary = a["res"]
		var down := _first(a, &"knockback")
		K.check(
			fails,
			a["plan"] == null and not res.has("lands_in") and bool(res.get("down", false)),
			"%s off: no plan and no landing time, still knocked down" % off
		)
		K.check(
			fails,
			absf(float(down) * DT - JT.PLAIN_S) <= 2.0 * DT,
			"and the haul is the plain PLAIN_S (%.2f s)" % (float(down) * DT)
		)
		var tilt := 0.0
		for i in range(0, down):
			tilt = maxf(tilt, absf(float((a["frames"] as Array)[i][2])))
		K.check(
			fails,
			(
				absf(tilt - JT.PLAIN_TILT) < 0.01
				and is_zero_approx(float((a["frames"] as Array)[down][3]))
			),
			"tipped back PLAIN_TILT as it comes (%.2f), no roll" % tilt
		)
		K.check(fails, a["reaction_ended"], "and it ends as ever")
		if off == "carjack_throw":
			var on_p: JT.Plan = on_run["plan"]
			var longer := float(on_run["left0"]) - float(a["left0"])
			var extra := on_p.air - JT.T_CONTACT
			K.check(
				fails,
				extra > 0.0 and absf(longer - extra) < 1e-6,
				(
					"the knockdown's lie keeps the slowed fall's extra time (%.3f of %.3f s)"
					% [longer, extra]
				)
			)
		FeatureFlags.set_override(off, true)
	ran.append("flag_off")
