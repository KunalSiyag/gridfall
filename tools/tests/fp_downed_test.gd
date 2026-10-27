extends SceneTree
## Downed awareness (the downed_awareness flag): a blow that leaves someone down brings the
## nearest free onlooker over to lean in a moment before walking on, once for each knock-down;
## and a fighter whose blows put the hero down stands over them a beat (one last shout) before
## walking off. Bare walkers and reactions, as in fp_tempers_test.

const K := preload("res://tools/tests/fp_kit.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const RE := preload("res://scripts/fp/traffic/reactions.gd")
const DT := 1.0 / 60.0

var fails: Array[String] = []


func _init() -> void:
	await process_frame
	_check_comes_over()
	_check_once_and_flag_off()
	_check_stand_over()
	_check_no_beat_without_a_down()
	FeatureFlags.reload()
	K.finish(self, "FP_DOWNED_TEST", fails)


# ------------------------------------------------------------------ helpers


## Bare walkers and reactions with the hero at the origin and open to a fight.
func _rig() -> Dictionary:
	var wk := WK.new()
	wk.player_pos = Vector3.ZERO
	var re := RE.new()
	re.setup(wk, null, 12)
	re.fight_odds = {"punch": 1.0, "shove": 1.0}
	re.hero_open = true
	return {"wk": wk, "re": re}


## Someone standing metres out at the given angle round the hero, facing them, walking in place.
func _person(wk: WK, a: float, metres: float) -> WK.Walker:
	var w: WK.Walker = wk.make("ambient")
	w.resident_id = "d-%d" % w.id
	wk.stand(w, Vector3(sin(a), 0.0, cos(a)) * (metres * WS.M), a + PI)
	w.state = "walk"
	return w


## Runs the reactions for secs.
func _run(re: RE, secs: float) -> void:
	for _k in range(ceili(secs / DT - 1e-6)):
		re.step(DT)


## Runs the reactions until cond says stop or the seconds run out; returns the seconds it took.
func _until(re: RE, secs: float, cond: Callable) -> float:
	var t := 0.0
	while t < secs and not bool(cond.call()):
		re.step(DT)
		t += DT
	return t


# ------------------------------------------------------------------ checks


## A knock-down brings the nearest onlooker over: they come close, lean in with the head shake,
## then walk on; a farther one never starts.
func _check_comes_over() -> void:
	var rig := _rig()
	var wk: WK = rig["wk"]
	var re: RE = rig["re"]
	var v := _person(wk, 0.0, 3.0)
	var near_by := _person(wk, 0.0, 6.0)
	var far_by := _person(wk, 0.4, 6.0)
	# A car's knock-down lies long enough for the visit to play out.
	var res := re.hit(v, Vector3.ZERO, Vector3(0.0, 0.0, 0.5 * WS.M), 1.0, "car")
	K.check(fails, not res.is_empty() and bool(res["down"]), "the blow leaves them down")
	var closest := INF
	var leaned := false
	var shook := false
	for _k in range(int(10.0 / DT)):
		re.step(DT)
		var d: float = (near_by.pos + near_by.vis_off).distance_to(v.pos + v.vis_off)
		closest = minf(closest, d)
		if d < RE.CHECK_NEAR + 0.2 * WS.M and near_by.vis_tilt > 0.15:
			leaned = true
		if near_by.react == &"no":
			shook = true
	K.check(
		fails,
		closest <= RE.CHECK_NEAR + 0.1 * WS.M,
		"the nearest comes up to the body (%.2f m)" % (closest / WS.M)
	)
	K.check(fails, leaned, "and leans in over them")
	K.check(fails, shook, "with the slow head shake")
	K.check(fails, far_by.react == &"" and far_by.state == "walk", "a farther one never starts")
	K.check(
		fails,
		near_by.state == "walk" and near_by.vis_tilt == 0.0,
		"then walks on, standing straight again"
	)


## One knock-down brings one visitor, and with the flag off nobody comes at all.
func _check_once_and_flag_off() -> void:
	var rig := _rig()
	var wk: WK = rig["wk"]
	var re: RE = rig["re"]
	var v := _person(wk, 0.0, 3.0)
	var first := _person(wk, 0.0, 5.0)
	var second := _person(wk, 0.0, 5.5)
	re.hit(v, Vector3.ZERO, Vector3(0.0, 0.0, 0.5 * WS.M), 1.0, "car")
	var first_came := false
	var second_started := false
	for _k in range(int(10.0 / DT)):
		re.step(DT)
		var d: float = (first.pos + first.vis_off).distance_to(v.pos + v.vis_off)
		if d < RE.CHECK_NEAR + 0.1 * WS.M:
			first_came = true
		if second.react != &"" or not second.vis_off.is_zero_approx():
			second_started = true
	K.check(fails, first_came, "the nearest of two comes over")
	K.check(fails, not second_started, "and only the nearest")
	FeatureFlags.set_override("downed_awareness", false)
	var rig2 := _rig()
	var wk2: WK = rig2["wk"]
	var re2: RE = rig2["re"]
	var v2 := _person(wk2, 0.0, 3.0)
	var b2 := _person(wk2, 0.0, 4.0)
	var res2 := re2.hit(v2, Vector3.ZERO, Vector3(0.0, 0.0, 0.5 * WS.M), 1.0, "car")
	K.check(fails, bool(res2["down"]), "the flag-off blow still downs them")
	_run(re2, 4.0)
	K.check(
		fails,
		b2.state == "walk" and b2.react == &"" and b2.vis_off.is_zero_approx(),
		"but without the flag nobody comes"
	)
	FeatureFlags.set_override("downed_awareness", true)


## A fighter whose hero goes down under them stands over the body a beat before walking off.
func _check_stand_over() -> void:
	var rig := _rig()
	var wk: WK = rig["wk"]
	var re: RE = rig["re"]
	var f := _person(wk, 0.0, 1.0)
	var jab := re.hit(f, Vector3.ZERO, Vector3(0.0, 0.0, WS.M), 0.45, "punch")
	K.check(fails, not jab.is_empty(), "the jab lands")
	var t := _until(re, 5.0, func() -> bool: return re.fighting(f))
	K.check(fails, re.fighting(f), "they square up (%.1f s)" % t)
	re.hero_open = false
	re.hero_down = true
	_until(re, 3.0, func() -> bool: return not re.fighting(f))
	K.check(fails, not re.fighting(f), "the scrap stops when the hero stays down")
	K.check(fails, f.react == &"shout", "and they stand over the hero a beat")
	_run(re, RE.STAND_OVER_S + 1.0)
	K.check(fails, f.react == &"" and f.state == "walk", "then walk off")


## The hero merely leaving (open false, down false) gets no stand-over.
func _check_no_beat_without_a_down() -> void:
	var rig := _rig()
	var wk: WK = rig["wk"]
	var re: RE = rig["re"]
	var f := _person(wk, 0.0, 1.0)
	re.hit(f, Vector3.ZERO, Vector3(0.0, 0.0, WS.M), 0.45, "punch")
	_until(re, 5.0, func() -> bool: return re.fighting(f))
	K.check(fails, re.fighting(f), "they square up")
	re.hero_open = false
	var shouted := false
	for _k in range(int(3.0 / DT)):
		re.step(DT)
		if not re.fighting(f) and f.react == &"shout":
			shouted = true
	K.check(fails, not shouted, "no beat when the hero only drove off")
	K.check(fails, not re.fighting(f) and f.state == "walk", "the scrap just ends")
