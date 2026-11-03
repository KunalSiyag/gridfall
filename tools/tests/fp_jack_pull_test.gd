extends SceneTree
## A carjack is a grab and a pull-out, not a throw (jack_pull.gd, the carjack_throw flag with
## hit_feel; docs/fp/ARCHITECTURE.md, Integration: driving). Two parts here, the real flow in a
## grown city (the hero's hands, the driver's skinned body) is fp_jack_flow_test's.
## The curves are pure functions of time: monotone where the sequence has a phase, continuous where
## one hands on to the next, finite everywhere, the drawn body lowered so its lowest part rests on
## the road and never in the air.
## Through reactions.gd, bare walkers stepped by hand: the driver comes out over the sill in HAUL_S,
## facing as they sat, leaning to the door and back, sits down on the road and lies back along the
## car, its drawn height never above where it started (nothing lifts it: no lift, no air, no flip),
## the tip back only ever backward, resting 0.5 to 1.2 m from the sill, told landed once as the hips
## touch the road, then up and the reaction ends as it did before, whatever the step of the clock
## (nothing left tipped or lowered); the same twice; the pulled out driver is down through the haul,
## the sit-down, the lie and the get-up but not through the shout and the run after it
## (reactions.is_down); a moving car's pace carries the body on (the haul all of it, easing down to
## the slide's, at most CARRY_MAX); one not drawn at the wheel is knocked down where they stand;
## either flag off (carjack_throw, hit_feel) is the old drag and throw (it flings them over 1.5 m).
## The room beside the door is fp_jack_room_test's, the door clearance for every model
## fp_jack_doors_test's, the landing's shake and sound fp_jack_touchdown_test's, the haul let go
## down the car's side fp_jack_haul_test's.

const DT := 1.0 / 60.0
const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const RE := preload("res://scripts/fp/traffic/reactions.gd")
const JP := preload("res://scripts/fp/traffic/jack_pull.gd")
const CJ := preload("res://scripts/fp/traffic/carjack.gd")
const SEED := 12
## The car stands at the origin heading +Z, its driver's side +X: half its width, where the seat's
## feet are in it (x, then y above the road).
const HALF_W := 0.9 * WS.M
const SEAT := Vector3(0.45 * WS.M, 0.15 * WS.M, -0.2 * WS.M)
## Where the driver rests, out from the sill (m): the least and the most.
const REST := Vector2(0.5, 1.2)
## The most any part of the body may be above the road once it is out of the seat (m).
const AIR_MAX := 0.25

var fails: Array[String] = []
var ran: Array[String] = []


func _init() -> void:
	await process_frame
	FeatureFlags.set_override("hit_feel", true)
	FeatureFlags.set_override("carjack_throw", true)
	_check_curves()
	_check_pull()
	_check_carry()
	_check_standing()
	_check_flags_off()
	_check_clock()
	_check_down()
	K.check(fails, ran.size() == 7, "every section ran to its end (%s)" % str(ran))
	FeatureFlags.reload()
	K.finish(self, "FP_JACK_PULL_TEST", fails)


# ------------------------------------------------------------------ the curves


func _finite(v: float) -> bool:
	return not is_nan(v) and not is_inf(v)


## True when f is non-decreasing (or non-increasing) over a..b sampled n times.
func _monotone(f: Callable, up: bool, a: float, b: float, n: int = 200) -> bool:
	var prev := float(f.call(a))
	for k in range(1, n + 1):
		var v := float(f.call(lerpf(a, b, float(k) / float(n))))
		if (up and v < prev - 1e-9) or (not up and v > prev + 1e-9):
			return false
		prev = v
	return true


## The phases are monotone, the hand-offs continuous, nothing is NaN, the body never lifted.
func _check_curves() -> void:
	var p := JP.Plan.new()
	p.seated = true
	p.lean = JP.HAUL_ROLL
	p.tip = JP.HAUL_TIP
	p.door = Vector3.RIGHT
	p.m1 = 0.8
	var sane := true
	for k in range(0, 101):
		var x := float(k) / 100.0
		var t := JP.FALL_S * x
		for v: float in [
			JP.pull(x, p.m1),
			JP.haul_lean(x, p),
			JP.haul_tip(x, p),
			JP.haul_drop(JP.haul_tip(x, p), 0.3 * (1.0 - x)),
			JP.fall_tip(t, p),
			JP.drop_at(JP.fall_tip(t, p)),
			JP.blend_tip(x),
			JP.blend_drop(x),
			JP.drop_at(x * JP.FALL_BACK)
		]:
			sane = sane and _finite(v)
	K.check(fails, sane, "every curve is finite over its whole span")
	K.check(
		fails,
		_monotone(func(x: float) -> float: return JP.pull(x, p.m1), true, 0.0, 1.0),
		"the pull only goes forward"
	)
	K.check(
		fails,
		(
			_monotone(func(x: float) -> float: return JP.haul_lean(x, p), true, 0.0, 1.0)
			and is_equal_approx(JP.haul_lean(1.0, p), JP.HAUL_ROLL)
			and JP.haul_lean(0.0, p) == 0.0
			and _monotone(func(x: float) -> float: return JP.haul_tip(x, p), true, 0.0, 1.0)
			and is_equal_approx(JP.haul_tip(1.0, p), JP.HAUL_TIP)
			and JP.haul_tip(0.0, p) == 0.0
		),
		"the roll to the door and the tip back grow from nothing to HAUL_ROLL and HAUL_TIP"
	)
	K.check(
		fails,
		(
			_monotone(func(t: float) -> float: return JP.fall_tip(t, p), true, 0.0, JP.FALL_S)
			and is_equal_approx(JP.fall_tip(0.0, p), JP.haul_tip(1.0, p))
			and is_equal_approx(JP.fall_tip(JP.FALL_S, p), JP.FALL_BACK)
		),
		"the tip back goes on from the haul's to FALL_BACK, never forward, never back up"
	)
	K.check(
		fails,
		(
			_monotone(func(a: float) -> float: return JP.drop_at(a), true, 0.0, JP.FALL_BACK)
			and JP.drop_at(0.0) == 0.0
			and JP.drop_at(JP.FALL_BACK) <= JP.DROP_MAX + 1e-9
		),
		"the drawn hips are lowered more the further back the body tips, to DROP_MAX at most"
	)
	_check_lowering(p)
	var contact := JP.contact_s(p)
	K.check(
		fails,
		(
			contact > 0.0
			and contact < JP.FALL_S
			and absf(JP.fall_tip(contact, p) - JP.SEAT_CONTACT) < 1e-6
		),
		"the hips touch the road %.2f s in, as the tip reaches SEAT_CONTACT" % contact
	)
	K.check(
		fails,
		JP.drop_at(JP.SEAT_CONTACT) >= 0.8 * JP.SIT_HIP,
		(
			"and by then the hips are down by most of the height of the seat's (%.2f of %.2f m)"
			% [JP.drop_at(JP.SEAT_CONTACT), JP.SIT_HIP]
		)
	)
	var carried_ok := true
	p.haul_carry = Vector3(0.0, 0.0, 20.0 * WS.M)
	p.carry = Vector3(0.0, 0.0, JP.CARRY_MAX)
	var prev := JP.carried(p, 0.0).z
	for k in range(1, 101):
		var z := JP.carried(p, JP.HAUL_S * float(k) / 100.0).z
		carried_ok = carried_ok and z >= prev - 1e-9
		prev = z
	K.check(fails, carried_ok, "a fast car's pace carries the body on, never back")
	ran.append("curves")


## The drawn hips' lowering: in the haul, and as the lying pose comes in over the fall's end.
func _check_lowering(p: JP.Plan) -> void:
	# The haul lowers the hips by what the tip lifts the feet, less the root's depth under the road:
	# never more than the tip asks, none while it is deep, all of it with none, and the fall takes
	# it on from where the haul left it.
	var ok_drop := JP.haul_drop(0.0, 0.2) == 0.0 and JP.haul_drop(0.0, 0.0) == 0.0
	ok_drop = ok_drop and is_equal_approx(JP.haul_drop(JP.HAUL_TIP, 0.0), JP.drop_at(JP.HAUL_TIP))
	for k in range(0, 101):
		var x := float(k) / 100.0
		var tip := JP.haul_tip(x, p)
		for depth: float in [0.0, 0.1, 0.3]:
			ok_drop = ok_drop and JP.haul_drop(tip, depth) >= 0.0
			ok_drop = (
				ok_drop
				and (
					JP.haul_drop(tip, depth)
					<= JP.drop_at(tip) - minf(depth, JP.drop_at(tip)) + 1e-9
				)
			)
	var said := "the haul's lowering is never negative and never more than the tip asks, less the "
	said += "root's depth under the road"
	K.check(fails, ok_drop, said)
	# The lying pose comes in over the fall's end: what is left of the tip and the lowering goes out
	# from all to nothing, faster than the clip comes in (below the way left), the lowering faster
	# than the tip.
	var share_ok := is_equal_approx(JP.blend_tip(1.0), JP.FALL_BACK) and JP.blend_tip(0.0) == 0.0
	share_ok = share_ok and is_equal_approx(JP.blend_drop(1.0), JP.drop_at(JP.FALL_BACK))
	share_ok = share_ok and JP.blend_drop(0.0) == 0.0
	share_ok = (
		share_ok and _monotone(func(k: float) -> float: return JP.blend_tip(k), true, 0.0, 1.0)
	)
	share_ok = (
		share_ok and _monotone(func(k: float) -> float: return JP.blend_drop(k), true, 0.0, 1.0)
	)
	for k in range(1, 100):
		var x := float(k) / 100.0
		share_ok = share_ok and JP.blend_tip(x) < JP.FALL_BACK * x
		share_ok = share_ok and JP.blend_drop(x) / JP.DROP_MAX < JP.blend_tip(x) / JP.FALL_BACK
	K.check(fails, share_ok, "the tip and the lowering go out faster than the lying pose comes in")


# ------------------------------------------------------------------ one pull through reactions


## A walker at the door of the car, a reaction layer with no collision world, and the car's seat:
## the stage for one pull.
func _stage(seated: bool) -> Dictionary:
	var wk := WK.new()
	wk.setup(null, null, null, null, SEED)
	var w := wk.make("ambient")
	wk.stand(w, Vector3(HALF_W + CJ.OUT, 0.0, SEAT.z), 0.0)
	w.state = "walk"
	w.seated = seated
	var re := RE.new()
	re.setup(wk, null, SEED)
	var landed: Array = []
	re.on_landed = func(who: WK.Walker) -> void: landed.append([who.pos + who.vis_off, who.id])
	return {"wk": wk, "w": w, "re": re, "landed": landed}


## One carjack through reactions.gd, stepped by hand (in steps of dt s) to the reaction's end: the
## hit's result, the reaction, the walker and a frame by frame record [t, drawn feet, bump, tilt,
## roll, yaw, clip, mode, pivot, is_down].
func _pull(seated: bool = true, carry: Vector3 = Vector3.ZERO, dt: float = DT) -> Dictionary:
	var s := _stage(seated)
	var w: WK.Walker = s["w"]
	var re: RE = s["re"]
	w.carry = carry
	var res := re.hit(
		w, Vector3(HALF_W + WS.M, 0.0, 0.5 * WS.M), Vector3.RIGHT, CJ.STRENGTH, "carjack", CJ.DROP_M
	)
	var r: RE.Reaction = (re.get("_active") as Dictionary).get(w.id)
	w.carry = Vector3.ZERO
	w.seated = false
	var out := {"res": res, "r": r, "w": w, "re": re, "landed": s["landed"], "frames": []}
	if seated:
		re.drag_out(w, SEAT, 0.0)
	var frames: Array = out["frames"]
	var t := 0.0
	while re.count() > 0 and t < 12.0:
		re.step(dt)
		t += dt
		var mode := r.mode
		frames.append(
			[
				t,
				w.pos + w.vis_off,
				r.bump,
				w.vis_tilt,
				w.vis_roll,
				w.yaw,
				w.react,
				mode,
				w.vis_pivot,
				re.is_down(w)
			]
		)
	return out


## The whole sequence of a driver drawn at the wheel, front to back.
func _check_pull() -> void:
	var a := _pull()
	var f: Array = a["frames"]
	var plan: JP.Plan = (a["r"] as RE.Reaction).jack
	K.check(fails, plan != null and plan.seated, "the flags on: a plan, for one drawn at the wheel")
	if plan == null:
		return
	var down := -1
	for i in range(f.size()):
		if f[i][7] == "place":
			down = i
			break
	_check_haul(f, down)
	_check_grounded(a, down)
	_check_rest(f)
	_check_landing(a, plan)
	_check_poses(a, down)
	_check_smooth(f)
	var b := _pull()
	var same := (b["frames"] as Array).size() == f.size()
	for i in range(f.size() if same else 0):
		same = same and (f[i][1] as Vector3) == ((b["frames"] as Array)[i][1] as Vector3)
	K.check(fails, same, "the same blow twice: the same body, frame for frame")
	ran.append("pull")


## Out over the sill in HAUL_S, beside the door level with the seat, facing as they sat all the way
## (through the haul, the fall and the lie), leaning to the door and back in the haul.
func _check_haul(f: Array, down: int) -> void:
	var took := float(f[maxi(down, 0)][0])
	K.check(
		fails,
		down > 0 and absf(took - JP.HAUL_S) <= 2.0 * DT,
		"out over the sill in HAUL_S (%.3f s of %.2f)" % [took, JP.HAUL_S]
	)
	var at: Vector3 = f[down][1]
	var said := "the haul ends beside the door, level with the seat (%.2f m out)"
	var beside := absf(at.x - (HALF_W + CJ.OUT)) < 0.02 * WS.M and absf(at.z - SEAT.z) < 0.02 * WS.M
	K.check(fails, beside, said % ((at.x - HALF_W) / WS.M))
	var held := true
	var roll := 0.0
	var tip := 0.0
	for i in range(f.size()):
		if f[i][7] in ["drag", "place"]:
			held = held and absf(angle_difference(float(f[i][5]), 0.0)) < 1e-4
		if f[i][7] == "drag":
			roll = minf(roll, float(f[i][4]))
			tip = maxf(tip, -float(f[i][3]))
	said = "facing as they sat all the way (a turn of nothing), leaning to the door in the haul (a "
	said += "roll of %.2f rad) and back (a tip of %.2f)"
	K.check(
		fails, held and roll < -0.9 * JP.HAUL_ROLL and tip > 0.9 * JP.HAUL_TIP, said % [roll, tip]
	)


## Never in the air: no lift, no air time, nothing but a lowering of the drawn body, which is never
## above where it was left; the drawn feet never higher than they came out of the seat; the tip
## only ever backward and no further than FALL_BACK.
func _check_grounded(a: Dictionary, down: int) -> void:
	var f: Array = a["frames"]
	var r: RE.Reaction = a["r"]
	var lifted := false
	var high := -INF
	var flip := false
	for i in range(f.size()):
		lifted = lifted or float(f[i][2]) > 1e-9
		if i >= down:
			high = maxf(high, (f[i][1] as Vector3).y)
		flip = flip or float(f[i][3]) > 1e-6 or absf(float(f[i][3])) > JP.FALL_BACK + 1e-6
	K.check(
		fails,
		not lifted and r.lift == 0.0 and r.air == 0.0,
		"nothing lifts the body: no lift, no bump, no air"
	)
	var said := "the drawn feet are never more than %.2f m up once out of the seat (%.3f m)"
	K.check(fails, high <= AIR_MAX * WS.M, said % [AIR_MAX, high / WS.M])
	said = "the body is only ever tipped back, as far as FALL_BACK and no further: no flip"
	K.check(fails, not flip, said)


## Where it rests: out from the sill, 0.5 to 1.2 m, and never further at any frame.
func _check_rest(f: Array) -> void:
	var furthest := 0.0
	for i in range(f.size()):
		if f[i][7] == "place":
			furthest = maxf(furthest, ((f[i][1] as Vector3).x - HALF_W) / WS.M)
	var rest := ((f[_first_clip(f, &"get_up")][1] as Vector3).x - HALF_W) / WS.M
	var said := "it rests %.2f m out from the sill (%.2f to %.2f), never further (%.2f)"
	var ok := rest >= REST.x and rest <= REST.y and furthest <= REST.y + 1e-6
	K.check(fails, ok, said % [rest, REST.x, REST.y, furthest])


## The landing: once, as the hips touch the road, as the blow's result says, where it lies.
func _check_landing(a: Dictionary, plan: JP.Plan) -> void:
	var landed: Array = a["landed"]
	var lands_in := float((a["res"] as Dictionary).get("lands_in", -1.0))
	var said := "landed once, told as the hips touch the road (%.3f s in, %d told)"
	var planned := absf(lands_in - (JP.HAUL_S + JP.contact_s(plan))) < 1e-6
	K.check(fails, landed.size() == 1 and planned, said % [lands_in, landed.size()])
	if landed.size() != 1:
		return
	var at: Vector3 = (landed[0] as Array)[0]
	said = "told where it lies on the road, not lowered under it (%.2f m up, %.2f m out)"
	var out_m := (at.x - HALF_W) / WS.M
	K.check(fails, absf(at.y) < 0.01 * WS.M and out_m > 0.3, said % [at.y / WS.M, out_m])


## The sit pose through the haul and the fall, then the get-up clip lies; the end: up, the walker's
## own state back, nothing left tipped, offset or pivoted.
func _check_poses(a: Dictionary, down: int) -> void:
	var f: Array = a["frames"]
	var sat: bool = f[0][6] == JP.DRAG_CLIP and f[down + 5][6] == JP.DRAG_CLIP
	K.check(
		fails,
		sat and _first_clip(f, &"get_up") > down,
		"the sit pose through the haul and the fall, then the get-up clip lies"
	)
	var w: WK.Walker = a["w"]
	var clean := w.vis_tilt == 0.0 and w.vis_roll == 0.0 and w.vis_pivot == 0.0
	clean = clean and w.react != RE.DRAG_CLIP and (a["r"] as RE.Reaction).bump == 0.0
	K.check(fails, clean, "the reaction ends clean: no tilt, roll, pivot or lowering left")


## Nothing pops: the drawn feet and the tip change by a little each frame.
func _check_smooth(f: Array) -> void:
	var jump := 0.0
	var tip_jump := 0.0
	for i in range(1, f.size()):
		var moving: bool = f[i][7] in ["drag", "place"] and f[i - 1][7] in ["drag", "place"]
		if moving and f[i][6] in [JP.DRAG_CLIP, &"get_up"]:
			jump = maxf(jump, ((f[i][1] as Vector3) - (f[i - 1][1] as Vector3)).length())
			tip_jump = maxf(tip_jump, absf(float(f[i][3]) - float(f[i - 1][3])))
	var said := "nothing pops: at most %.3f m and %.3f rad a frame"
	K.check(fails, jump < 0.2 * WS.M and tip_jump < 0.2, said % [jump / WS.M, tip_jump])


## The first frame on clip, or the last one.
func _first_clip(f: Array, clip: StringName) -> int:
	for i in range(f.size()):
		if f[i][6] == clip:
			return i
	return f.size() - 1


## A car going along +Z carries the driver's pace through the haul and the slide: down the road by
## what the plan says, and at 20 m/s (past CARRY_MAX) the slide keeps CARRY_MAX of it.
func _check_carry() -> void:
	for v_ms: float in [4.0, 20.0]:
		var v := v_ms * WS.M
		var a := _pull(true, Vector3(0.0, 0.0, v))
		var f: Array = a["frames"]
		var plan: JP.Plan = (a["r"] as RE.Reaction).jack
		var down := 0
		for i in range(f.size()):
			if f[i][7] == "place":
				down = i
				break
		var slide_end := down + roundi(JP.SLIDE_S / DT)
		var moved := float((f[slide_end][1] as Vector3).z - SEAT.z)
		var want := JP.carried(plan, JP.HAUL_S).z + plan.carry.z * 0.5 * JP.SLIDE_S
		K.check(
			fails,
			absf(moved - want) < 0.05 * WS.M + 0.02 * want,
			(
				"a car at %.0f m/s: the driver goes %.2f m down the road with it (%.2f expected)"
				% [v_ms, moved / WS.M, want / WS.M]
			)
		)
		var out_m := ((f[slide_end][1] as Vector3).x - HALF_W) / WS.M
		K.check(
			fails,
			out_m >= REST.x and out_m <= REST.y,
			"and comes down %.2f m out beside the door, the same as from a standstill" % out_m
		)
		var air := -INF
		for i in range(down, slide_end):
			air = maxf(air, (f[i][1] as Vector3).y)
		K.check(fails, air <= AIR_MAX * WS.M, "never up (%.3f m)" % (air / WS.M))
	ran.append("carry")


## Someone not drawn at the wheel (nobody to haul): knocked down where they stand with the plain
## knock-down clip, level, told landed STAND_CONTACT s in, then up.
func _check_standing() -> void:
	var a := _pull(false)
	var f: Array = a["frames"]
	var r: RE.Reaction = a["r"]
	var plan: JP.Plan = r.jack
	var lands_in := float((a["res"] as Dictionary).get("lands_in", -1.0))
	var level := true
	var tipped := false
	for i in range(f.size()):
		level = level and absf((f[i][1] as Vector3).y) < 1e-6 and float(f[i][2]) == 0.0
		tipped = tipped or float(f[i][3]) != 0.0
	K.check(
		fails,
		plan != null and not plan.seated and f[0][6] == &"knockback" and level and not tipped,
		"not drawn at the wheel: the plain knock-down, level, no tip, no haul"
	)
	K.check(
		fails,
		absf(lands_in - JP.STAND_CONTACT) < 1e-6 and (a["landed"] as Array).size() == 1,
		"told landed %.2f s in, once" % lands_in
	)
	var rest := 0.0
	for i in range(f.size()):
		if f[i][6] == &"get_up":
			rest = ((f[i][1] as Vector3).x - HALF_W - CJ.OUT) / WS.M
			break
	K.check(
		fails,
		rest > 0.0 and rest <= CJ.DROP_M + 0.01,
		"it goes %.2f m beyond where it stood, no further than the drop" % rest
	)
	ran.append("standing")


## Whatever the step of the clock (a slow frame rate, a fast-forward), the pull ends the same way:
## told landed once, and once the lying pose is in (BLEND_S into the lie) nothing left tipped,
## rolled or lowered, the drawn feet on the road; the sit-down never above where it started; the
## same step through the whole sequence, an old step of the clock having left a part of the tip on
## for the lie, and the lean's pivot let go with the tip (not held until the reaction is over).
func _check_clock() -> void:
	for dt: float in [DT, 1.0 / 30.0, 1.0 / 20.0, 8.0 / 60.0]:
		var a := _pull(true, Vector3.ZERO, dt)
		var f: Array = a["frames"]
		var lie := _first_clip(f, &"get_up")
		var t_lie := float(f[lie][0])
		var left := 0
		var worst := 0.0
		var pivot := 0.0
		var high := -INF
		for i in range(f.size()):
			if f[i][7] in ["drag", "place"] and i >= _first_clip(f, JP.DRAG_CLIP):
				high = maxf(high, (f[i][1] as Vector3).y)
			# From BLEND_S into the lie to the reaction's end: the get-up, the shout and the run.
			if float(f[i][0]) - t_lie >= JP.BLEND_S + dt:
				pivot = maxf(pivot, absf(float(f[i][8])))
			if f[i][6] == &"get_up" and float(f[i][0]) - t_lie >= JP.BLEND_S + dt:
				left += 1
				worst = maxf(
					worst,
					maxf(
						maxf(absf(float(f[i][3])), absf(float(f[i][4]))),
						maxf(absf(float(f[i][2])), absf((f[i][1] as Vector3).y) / WS.M)
					)
				)
		var said := "step %.3f s: the lying pose is clean once it is in (%d frames, the worst "
		said += "tip, roll, lowering or height %.4f), landed %d time(s), never above the seat "
		said += "(%.2f m)"
		var told := (a["landed"] as Array).size()
		K.check(
			fails,
			left >= 3 and worst < 1e-6 and told == 1 and high <= SEAT.y + 1e-6,
			said % [dt, left, worst, told, high / WS.M]
		)
		# The lean's pivot (the sit pose's hips) is let go with the tip: a blow on the one running
		# off turns about their own hips again (a punch's reel, a trample, a brawl throw).
		said = "step %.3f s: and the lean's pivot is back to the body's own hips once the tip is "
		said += "out, for the get-up, the shout and the run (%.2f body m left)"
		K.check(fails, pivot == 0.0, said % [dt, pivot])
	ran.append("clock")


## The pulled out driver is down (reactions.is_down: the hero cannot punch, hold or photograph them
## as they lie) from the haul through the get-up, and not for the shout and the run that follow it:
## the plan staying set for the whole reaction is no reason to stay down.
func _check_down() -> void:
	var a := _pull()
	var f: Array = a["frames"]
	var up_end := -1
	for i in range(f.size()):
		if f[i][6] == &"get_up":
			up_end = i
	var down_in := true
	for i in range(0, up_end + 1):
		down_in = down_in and bool(f[i][9])
	var after := 0
	var down_after := 0
	for i in range(up_end + 1, f.size()):
		after += 1
		down_after += 1 if bool(f[i][9]) else 0
	var said := "down from the haul through the get-up (%s), and not after it, in the shout and "
	said += "the run (%d of %d frames after it)"
	K.check(fails, down_in and after >= 10 and down_after == 0, said % [down_in, down_after, after])
	ran.append("down")


## Either flag off is the old drag and the old throw: no plan, the haul the plain one (the sit pose
## tipped back), and the fling over 1.5 m on an arc (the control: the new sequence is not that).
func _check_flags_off() -> void:
	for cfg: Array in [["carjack_throw", false], ["hit_feel", false]]:
		FeatureFlags.set_override(cfg[0], cfg[1])
		var s := _stage(true)
		var w: WK.Walker = s["w"]
		var re: RE = s["re"]
		var res := re.hit(
			w,
			Vector3(HALF_W + WS.M, 0.0, 0.5 * WS.M),
			Vector3.RIGHT,
			CJ.STRENGTH,
			"carjack",
			CJ.PLAIN_SLIDE
		)
		var r: RE.Reaction = (re.get("_active") as Dictionary).get(w.id)
		w.seated = false
		re.drag_out(w, SEAT, 0.0)
		var seen := false
		var peak := 0.0
		var t := 0.0
		while re.count() > 0 and t < 12.0:
			re.step(DT)
			t += DT
			if w.react == &"get_up" and not seen:
				seen = true
				peak = (w.pos + w.vis_off).x - HALF_W - CJ.OUT
		var plain := r.jack == null and not (res as Dictionary).has("lands_in")
		var said := "%s off: no plan, nothing said of a landing, flung %.2f m beyond the door "
		said += "as it always was"
		K.check(fails, plain and peak >= 1.5 * WS.M, said % [cfg[0], peak / WS.M])
		FeatureFlags.set_override(cfg[0], true)
	ran.append("flags_off")
