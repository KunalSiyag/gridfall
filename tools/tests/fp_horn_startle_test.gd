extends SceneTree
## People startle at the hero's horn (horn_street; the drive feature sounds it on the bus and
## reactions.gd's startle answers): everyone it carries to turns to the car and rocks back, the
## near ones hop a step off the road, a long press carries wider and earns a shake of the head.
## One ripple per crowd — a horn right on the last one's heels gets no answer — and the flag off
## leaves the street unstirred. The reactions run on their own here, no traffic feature needed.

const WK := preload("res://scripts/fp/traffic/walkers.gd")
const RE := preload("res://scripts/fp/traffic/reactions.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const K := preload("res://tools/tests/fp_kit.gd")
const DT := 1.0 / 60.0

var fails: Array[String] = []


func _init() -> void:
	await process_frame
	_check_tap()
	_check_long()
	_check_long_escalation()
	_check_cooldown()
	_check_flag_off()
	FeatureFlags.reload()
	K.finish(self, "FP_HORN_STARTLE_TEST", fails)


# ------------------------------------------------------------------ helpers


## Walkers walking at the given distances (m) straight ahead of the origin, and their reactions.
func _street(distances: Array) -> Dictionary:
	var wk := WK.new()
	wk.player_pos = Vector3.ZERO
	var re := RE.new()
	re.setup(wk, null, 12)
	var ws: Array = []
	for d: float in distances:
		var w := wk.make("ambient")
		w.resident_id = "h-%d" % w.id
		wk.stand(w, Vector3(0.0, 0.0, d * WS.M), 0.0)
		w.state = "walk"
		ws.append(w)
	return {"wk": wk, "re": re, "ws": ws}


func _run(re: RE, secs: float) -> void:
	for _k in range(ceili(secs / DT - 1e-6)):
		re.step(DT)


## The live reaction of walker w in re, null when none.
func _record(re: RE, w: WK.Walker) -> Variant:
	return (re.get("_active") as Dictionary).get(w.id)


## True when the reaction r still holds a head-shake step.
func _shakes(r: Variant) -> bool:
	if r == null:
		return false
	for st: Array in r.get("steps"):
		if str(st[0]) == "place" and st[1] == &"no":
			return true
	return false


## How far w is turned toward the origin (0 when it faces it squarely).
func _off_facing(w: WK.Walker) -> float:
	var q := w.pos + w.vis_off
	return absf(wrapf(w.yaw - atan2(-q.x, -q.z), -PI, PI))


# ------------------------------------------------------------------ checks


## A tap: the people it carries to startle — a beat turned to the car, rocked back, the near
## ones stepping back — and one beyond its carry does not stir.
func _check_tap() -> void:
	var f := _street([3.0, 7.0, 10.0, 20.0, 40.0])
	var re: RE = f["re"]
	var ws: Array = f["ws"]
	var got: Array = re.startle(Vector3.ZERO, 35.0 * WS.M, false)
	var in_it := got.has(ws[0]) and got.has(ws[1]) and got.has(ws[2]) and got.has(ws[3])
	K.check(fails, in_it and not got.has(ws[4]), "the horn startles those it reaches, no further")
	_run(re, 0.55)
	var near_stepped := (
		str((ws[0] as WK.Walker).state) == "react"
		and (ws[0] as WK.Walker).vis_off.length() > 0.1 * WS.M
		and (ws[1] as WK.Walker).vis_off.length() > 0.1 * WS.M
	)
	K.check(fails, near_stepped, "the near ones step back off the road")
	var far_stay := (
		str((ws[2] as WK.Walker).state) == "react"
		and (ws[2] as WK.Walker).vis_off.length() < 0.02 * WS.M
		and (ws[3] as WK.Walker).vis_off.length() < 0.02 * WS.M
	)
	K.check(fails, far_stay, "the rest only stop and look")
	_run(re, 0.35)
	var faced := _off_facing(ws[0]) < 0.5 and _off_facing(ws[1]) < 0.5 and _off_facing(ws[2]) < 0.5
	K.check(fails, faced, "and they face the car")
	K.check(fails, str((ws[4] as WK.Walker).state) == "walk", "the one beyond keeps walking")
	_run(re, 7.0)
	var over := true
	for i: int in 4:
		var w: WK.Walker = ws[i]
		over = over and str(w.state) == "walk" and w.vis_off.length() < 0.02 * WS.M
	K.check(fails, over, "then everyone walks on composed")


## A long press reaches wider with its step back, and the near ones shake their head at it.
func _check_long() -> void:
	var f := _street([3.0, 10.0, 14.0])
	var re: RE = f["re"]
	var ws: Array = f["ws"]
	var got: Array = re.startle(Vector3.ZERO, 35.0 * WS.M, true)
	K.check(fails, got.size() == 3, "the long press startles all three")
	_run(re, 0.6)
	var w1: WK.Walker = ws[1]
	K.check(
		fails,
		w1.vis_off.length() > 0.1 * WS.M and w1.react == &"no",
		"ten metres out steps back and shakes their head at it"
	)
	var w2: WK.Walker = ws[2]
	K.check(
		fails,
		w2.vis_off.length() < 0.02 * WS.M and w2.react == &"",
		"fourteen metres out only stops and looks"
	)


## The real press path: the tap on the press, the held press 0.6 s on from the same place. The
## ripple in flight escalates instead of dying on the cooldown: ten metres out steps back after
## all and both of those within the long reach shake their head once turned, the one past it keeps
## the plain reaction — and a fresh press once the cooldown has run startles again.
func _check_long_escalation() -> void:
	var f := _street([5.0, 10.0, 14.0])
	var re: RE = f["re"]
	var ws: Array = f["ws"]
	var got: Array = re.startle(Vector3.ZERO, 35.0 * WS.M, false)
	K.check(fails, got.size() == 3, "escalation: the tap startles all three")
	_run(re, 0.6)
	got = re.startle(Vector3.ZERO, 35.0 * WS.M, true)
	K.check(
		fails,
		got.has(ws[0]) and got.has(ws[1]) and not got.has(ws[2]),
		"the held press escalates its own ripple out to 12 m, no further"
	)
	var mid: Variant = _record(re, ws[1])
	K.check(
		fails,
		mid != null and not (mid.get("slide") as Vector3).is_zero_approx(),
		"ten metres out steps back off the road after all"
	)
	K.check(
		fails,
		_shakes(_record(re, ws[0])) and _shakes(mid),
		"and both shake their head at it once turned"
	)
	var far: Variant = _record(re, ws[2])
	K.check(
		fails,
		far != null and (far.get("steps") as Array).is_empty(),
		"the one past the reach keeps the plain reaction"
	)
	_run(re, RE.HORN_CD + 4.0)
	K.check(
		fails,
		re.startle(Vector3.ZERO, 35.0 * WS.M, false).size() == 3,
		"a press once the cooldown has run startles again"
	)


## Once per crowd: a horn right after the last, near it, gets no answer; one from further off,
## or after a few seconds, does.
func _check_cooldown() -> void:
	var f := _street([5.0, 25.0])
	var re: RE = f["re"]
	var ws: Array = f["ws"]
	var first: Array = re.startle(Vector3.ZERO, 15.0 * WS.M, false)
	K.check(fails, first == [ws[0]], "the first honk startles the one it reaches")
	_run(re, 0.2)
	K.check(
		fails, re.startle(Vector3.ZERO, 15.0 * WS.M, false).is_empty(), "honk spam gets no answer"
	)
	var far: Array = re.startle(Vector3(0.0, 0.0, 24.0 * WS.M), 15.0 * WS.M, false)
	K.check(fails, far == [ws[1]], "but a horn from another street over does")
	var f2 := _street([5.0])
	var re2: RE = f2["re"]
	re2.startle(Vector3.ZERO, 15.0 * WS.M, false)
	_run(re2, RE.HORN_CD + 0.3)
	K.check(
		fails,
		re2.startle(Vector3.ZERO, 15.0 * WS.M, false).size() == 1,
		"and after a few seconds the crowd answers again"
	)


## With the flag off nobody stirs.
func _check_flag_off() -> void:
	var f := _street([5.0])
	var re: RE = f["re"]
	FeatureFlags.set_override("horn_street", false)
	K.check(
		fails,
		re.startle(Vector3.ZERO, 35.0 * WS.M, true).is_empty(),
		"with the flag off nobody stirs"
	)
	FeatureFlags.set_override("horn_street", true)
	K.check(
		fails,
		re.startle(Vector3.ZERO, 35.0 * WS.M, false).size() == 1,
		"and back on they startle again"
	)
