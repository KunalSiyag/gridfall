extends SceneTree
## The haul of a carjack's pull-out (jack_pull.gd, the carjack_throw flag) through reactions.gd,
## bare walkers stepped by hand: let go down the car's side where the open door asks (carjack.gd's
## shift), the body goes straight out over the sill from the seat first, as with no shift, and
## drifts rearward only over the last of the haul to the place it is let go; and a fast car's pace,
## which the haul keeps whole, eases down over the last CARRY_EASE_S of it to the pace the slide
## keeps, so the body is not stopped dead from one frame to the next at the release (it was, by the
## difference of the two paces, for a car faster than CARRY_MAX).

const WS := preload("res://scripts/fp/world_scale.gd")
const CJ := preload("res://scripts/fp/traffic/carjack.gd")
const JP := preload("res://scripts/fp/traffic/jack_pull.gd")
const RE := preload("res://scripts/fp/traffic/reactions.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const K := preload("res://tools/tests/fp_kit.gd")
const SEED := 12
const DT := 1.0 / 60.0
## The car stands at the origin heading +Z, its driver's side +X: half its width, where the seat's
## feet are in it (x, then y above the road) and where the driver comes out beside the door.
const HALF_W := 0.9 * WS.M
const SEAT_X := 0.45 * WS.M
const SEAT_Y := 0.15 * WS.M
const SEAT_Z := -0.2 * WS.M
const STRENGTH := CJ.STRENGTH
const DROP := CJ.DROP_M

var fails: Array[String] = []
var ran: Array[String] = []


func _init() -> void:
	await process_frame
	FeatureFlags.set_override("hit_feel", true)
	FeatureFlags.set_override("carjack_throw", true)
	_check_haul_shift()
	_check_ease()
	_check_drag_entries()
	FeatureFlags.reload()
	K.check(fails, ran.size() == 3, "every section ran to its end (%s)" % str(ran))
	K.finish(self, "FP_JACK_HAUL_TEST", fails)


## One carjack through reactions.gd with the driver drawn at the wheel, stepped by hand to the
## fall: the plan, where they are let go (shift off the straight out place, u: carjack.gd's, down
## the car's side) and the drawn feet frame by frame ([time, feet]) until the fall has begun and a
## few frames into it ("down": the index of the first frame of it).
func _haul(carry: Vector3, shift: Vector3) -> Dictionary:
	var wk := WK.new()
	wk.setup(null, null, null, null, SEED)
	var w := wk.make("ambient")
	var at := Vector3(HALF_W + CJ.OUT, 0.0, SEAT_Z) + shift
	wk.stand(w, at, 0.0)
	w.state = "walk"
	w.carry = carry
	w.seated = true
	var re := RE.new()
	re.setup(wk, null, SEED)
	re.hit(w, Vector3(HALF_W + WS.M, 0.0, 0.5 * WS.M), Vector3.RIGHT, STRENGTH, "carjack", DROP)
	var r: RE.Reaction = (re.get("_active") as Dictionary).get(w.id)
	re.drag_out(w, Vector3(SEAT_X, SEAT_Y, SEAT_Z), 0.0, shift)
	var frames: Array = []
	var down := -1
	var t := 0.0
	while re.count() > 0 and t < 3.0:
		re.step(DT)
		t += DT
		frames.append([t, w.pos + w.vis_off])
		if down < 0 and r.mode == "place":
			down = frames.size() - 1
		if down >= 0 and frames.size() > down + 6:
			break
	return {"plan": r.jack, "at": at, "frames": frames, "down": down}


## Let go down the car's side: the haul goes straight out over the sill from the seat first, as it
## would with no shift, and drifts rearward only after the first SHIFT_AT of the way across
## (smoothly, their feet pointing at the door) to the place they are let go. The body's place at
## every frame of the haul against the line from the seat out to where they would have been let go
## with no shift.
func _check_haul_shift() -> void:
	var share := JP.SHIFT_AT
	var back := 0.3 * WS.M
	var a := _haul(Vector3.ZERO, Vector3(0.0, 0.0, -back))
	var p: JP.Plan = a["plan"]
	var at: Vector3 = a["at"]
	var straight := at + Vector3(0.0, 0.0, back)
	var from := Vector3(SEAT_X, SEAT_Y, SEAT_Z)
	var frames: Array = a["frames"]
	var off_line := 0.0
	var late := 0.0
	var steady := true
	var last := 0.0
	for i in range(0, int(a["down"])):
		var f: Array = frames[i]
		var x := float(f[0]) / JP.HAUL_S
		var k := JP.pull(x, p.m1)
		var feet := f[1] as Vector3
		var drift := feet.z - from.lerp(straight, k).z
		if k <= share:
			off_line = maxf(off_line, absf(drift))
		else:
			steady = steady and drift <= last + 1e-6
			late = minf(late, drift)
		last = drift
	var msg := "straight out over the sill first: on the line to the straight-out place until "
	msg += "%.0f%% of the way (%.3f m off)" % [100.0 * share, off_line / WS.M]
	K.check(fails, off_line < 0.01 * WS.M, msg)
	K.check(
		fails,
		late < -0.9 * back and steady,
		(
			"and drifts rearward after it, steadily: %.2f m by the release (of %.2f m)"
			% [-late / WS.M, back / WS.M]
		)
	)
	var land: Vector3 = (frames[a["down"]] as Array)[1]
	K.check(
		fails,
		absf(land.z - at.z) < 0.04 * WS.M,
		"let go at the shifted place (%.3f m off)" % (absf(land.z - at.z) / WS.M)
	)
	# With no shift the haul is the straight line, so a shift of nothing changes nothing.
	var flat := _haul(Vector3.ZERO, Vector3.ZERO)
	var level := 0.0
	for i in range(0, int(flat["down"])):
		level = maxf(
			level, absf((((flat["frames"] as Array)[i] as Array)[1] as Vector3).z - SEAT_Z)
		)
	K.check(
		fails,
		level < 0.01 * WS.M,
		"no shift: level with the seat all the way (%.3f m)" % (level / WS.M)
	)
	ran.append("haul_shift")


## A moving car's pace is not stepped at the release: the body's pace along the road (per frame,
## from the drawn feet) changes smoothly from the haul's through the hand-off into the slide, at
## most about what the ease over CARRY_EASE_S asks (smoothstep: 1.5 times the average) a frame, for
## cars from just over CARRY_MAX to 30 m/s, and the slide leaves at about CARRY_MAX of it. Without
## the ease the step was (v - CARRY_MAX) in one frame.
func _check_ease() -> void:
	var worst := 0.0
	for v_ms: float in [6.5, 8.3, 14.0, 20.0, 30.0]:
		var v := v_ms * WS.M
		var a := _haul(Vector3(0.0, 0.0, v), Vector3.ZERO)
		var frames: Array = a["frames"]
		var step := 0.0
		var last := NAN
		for i in range(1, mini(int(a["down"]) + 4, frames.size())):
			var pace := (
				((frames[i] as Array)[1] as Vector3).z - ((frames[i - 1] as Array)[1] as Vector3).z
			)
			pace /= DT
			if not is_nan(last):
				step = maxf(step, absf(pace - last))
			last = pace
		var bound := 1.6 * (v - JP.CARRY_MAX) / (JP.CARRY_EASE_S / DT)
		var msg := "a car at %.1f m/s: the body's pace changes by at most " % v_ms
		msg += "%.2f m/s a frame to the release (%.2f)" % [step / WS.M, bound / WS.M]
		K.check(fails, step <= bound + 0.05 * WS.M, msg)
		var leaves := (
			(
				((frames[a["down"]] as Array)[1] as Vector3).z
				- ((frames[a["down"] - 1] as Array)[1] as Vector3).z
			)
			/ DT
		)
		K.check(
			fails,
			absf(leaves - JP.CARRY_MAX) < 0.1 * v,
			(
				"and the haul reaches the release at about the slide's pace (%.1f m/s)"
				% (leaves / WS.M)
			)
		)
		worst = maxf(worst, step / WS.M)
	print("  worst pace change at the release %.2f m/s a frame" % worst)
	ran.append("ease")


## A drag made with the four entries the haul once had (from, to, the facing at either end: no
## shift) begins as one with no shift, not with a read past the end of it.
func _check_drag_entries() -> void:
	var wk := WK.new()
	wk.setup(null, null, null, null, SEED)
	var w := wk.make("ambient")
	var r := RE.Reaction.new()
	r.w = w
	r.jack = JP.plan_down(r, Vector3.RIGHT, DROP, 1.0, 1.5)
	var from := Vector3(SEAT_X, SEAT_Y, SEAT_Z)
	r.drag = [from, Vector3(HALF_W + CJ.OUT, 0.0, SEAT_Z), 0.0, 0.5 * PI]
	var haul := JP.begin(r)
	K.check(
		fails,
		is_equal_approx(haul, JP.HAUL_S) and r.jack.haul and r.jack.shift == Vector3.ZERO,
		"a drag of four entries begins the haul with no shift (%.2f s)" % haul
	)
	r.drag.append(Vector3(0.0, 0.0, -0.3 * WS.M))
	JP.begin(r)
	K.check(
		fails,
		r.jack.shift.is_equal_approx(Vector3(0.0, 0.0, -0.3 * WS.M)),
		"and with the fifth, the shift it gives"
	)
	ran.append("drag_entries")
