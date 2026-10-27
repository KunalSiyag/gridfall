extends SceneTree
## Fighters' tempers (flag fight_tempers): a person who fights back fights their own way, fixed
## to who they are. A guard turns the hero's blows aside while the scrap is theirs (nothing of
## them moves, nothing counts), the guard chipping until one lands in full (guard_chip); a
## dancer sidesteps round the hero while waiting to punch; a
## caller shouts friends over and they join in; a bolt squares up, thinks better of it and runs;
## a bruiser leads with the cross and answers a blow the moment it lands. With the flag off
## everyone fights plain. Reactions run on their own, as fp_combat_pose_test runs them.

const K := preload("res://tools/tests/fp_kit.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const RE := preload("res://scripts/fp/traffic/reactions.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const DT := 1.0 / 60.0

var fails: Array[String] = []


func _init() -> void:
	await process_frame
	_check_fixed()
	_check_guard()
	_check_guard_chip()
	_check_dancer()
	_check_caller()
	_check_bolt()
	_check_bruiser()
	_check_flag_off()
	FeatureFlags.reload()
	K.finish(self, "FP_TEMPERS_TEST", fails)


# ------------------------------------------------------------------ helpers


## A hero at the origin and one fighter metres in front of them, their temper pinned: a jab
## makes them square up (fight_odds 1).
func _pair(pin: int, metres := 1.0) -> Dictionary:
	var wk := WK.new()
	wk.player_pos = Vector3.ZERO
	var w := wk.make("ambient")
	w.resident_id = "t-%d" % w.id
	wk.stand(w, Vector3(0.0, 0.0, metres * WS.M), PI)
	w.state = "walk"
	var re := RE.new()
	re.setup(wk, null, 12)
	re.fight_odds = {"punch": 1.0, "shove": 1.0}
	re.fight_temper = {w.id: pin}
	re.hero_open = true
	return {"wk": wk, "w": w, "re": re}


## The hero's jab at w (strength 0.45), from the origin, pushing them away.
func _jab(re: RE, w: WK.Walker) -> Dictionary:
	return re.hit(w, Vector3.ZERO, Vector3(0.0, 0.0, 1.0) * WS.M, 0.45, "punch")


## Runs the reactions for secs.
func _run(re: RE, secs: float) -> void:
	for _k in range(ceili(secs / DT - 1e-6)):
		re.step(DT)


## A temper is fixed to who the walker is, and the pin or the flag decides it.
func _check_fixed() -> void:
	var wk := WK.new()
	var re := RE.new()
	re.setup(wk, null, 12)
	var seen := {}
	for _k in 24:
		var w := wk.make("ambient")
		w.resident_id = "s-%d" % w.id
		wk.stand(w, Vector3.ZERO, 0.0)
		var t := int(re.temper_of(w))
		seen[t] = true
		K.check(fails, t == int(re.temper_of(w)), "a walker's temper stays fixed (%d)" % t)
	K.check(
		fails,
		seen.size() >= 4,
		"the street does not all fight one way (%d tempers seen)" % seen.size()
	)
	var w := wk.make("ambient")
	re.fight_temper = {w.id: RE.T_GUARD}
	K.check(fails, int(re.temper_of(w)) == RE.T_GUARD, "the test pin picks the temper")
	FeatureFlags.set_override("fight_tempers", false)
	re.fight_temper = {}
	var plain := true
	for o: WK.Walker in wk.walkers:
		plain = plain and int(re.temper_of(o)) == RE.T_PLAIN
	K.check(fails, plain, "and without the flag everyone is plain")
	FeatureFlags.set_override("fight_tempers", true)


## A guard turns the hero's blows aside while the scrap is theirs, and they count for nothing.
func _check_guard() -> void:
	var f := _pair(RE.T_GUARD)
	var w: WK.Walker = f["w"]
	var re: RE = f["re"]
	re.guard_share = 1.0
	K.check(fails, not _jab(re, w).is_empty(), "the jab that starts it lands")
	_run(re, 3.0)
	K.check(fails, re.fighting(w), "they square up to the hero")
	var q := w.pos + w.vis_off
	var res := _jab(re, w)
	K.check(
		fails,
		not res.is_empty() and str(res["clip"]) == "hit_chest" and not bool(res["down"]),
		"their guard turns the next jab aside"
	)
	K.check(
		fails,
		(w.pos + w.vis_off).distance_to(q) < 0.02 * WS.M,
		"it neither moves them nor knocks them down"
	)
	_run(re, 0.6)
	K.check(fails, re.fighting(w), "and the scrap stays theirs")
	res = re.hit(w, Vector3.ZERO, Vector3(0.0, 0.0, 1.0) * WS.M, 0.9, "punch")
	K.check(fails, not bool(res["down"]), "even a heavy one, turned off them")
	_run(re, 0.6)
	K.check(fails, re.fighting(w), "the scrap goes on")
	re.guard_share = 0.0
	q = w.pos + w.vis_off
	res = _jab(re, w)
	_run(re, 0.2)
	K.check(
		fails,
		str(res["clip"]) == "hit_head" and (w.pos + w.vis_off).distance_to(q) > 0.02 * WS.M,
		"with the share gone the jab lands in full"
	)


## A guard's guard wears out (guard_chip): every blow turned aside chips it, and the one that
## takes the chip past 1 lands in full instead; with the flag off the guard never tires.
func _check_guard_chip() -> void:
	var f := _pair(RE.T_GUARD)
	var w: WK.Walker = f["w"]
	var re: RE = f["re"]
	re.guard_share = 1.0
	K.check(fails, not _jab(re, w).is_empty(), "the jab that starts it lands")
	_run(re, 3.0)
	var clips: Array[String] = []
	var still := true
	for _i: int in 2:
		var q := w.pos + w.vis_off
		clips.append(str(_jab(re, w)["clip"]))
		still = still and (w.pos + w.vis_off).distance_to(q) < 0.02 * WS.M
		_run(re, 0.2)
	K.check(
		fails,
		clips[0] == "hit_chest" and clips[1] == "hit_chest" and still,
		"the first two jabs are turned aside, nothing moving (%s)" % str(clips)
	)
	var q := w.pos + w.vis_off
	clips.append(str(_jab(re, w)["clip"]))
	_run(re, 0.2)
	K.check(
		fails,
		clips[2] == "hit_head" and (w.pos + w.vis_off).distance_to(q) > 0.02 * WS.M,
		"the third beats the guard and lands in full (%s)" % str(clips)
	)
	var g := _pair(RE.T_GUARD)
	var w2: WK.Walker = g["w"]
	var re2: RE = g["re"]
	re2.guard_share = 1.0
	FeatureFlags.set_override("guard_chip", false)
	_jab(re2, w2)
	_run(re2, 3.0)
	var off_clips: Array[String] = []
	for _i: int in 3:
		off_clips.append(str(_jab(re2, w2)["clip"]))
		_run(re2, 0.2)
	FeatureFlags.set_override("guard_chip", true)
	K.check(
		fails,
		off_clips == ["hit_chest", "hit_chest", "hit_chest"],
		"with the flag off the guard never tires (%s)" % str(off_clips)
	)


## A dancer sidesteps round the hero while they wait, keeping their ring, and keeps punching.
func _check_dancer() -> void:
	var f := _pair(RE.T_DANCER)
	var w: WK.Walker = f["w"]
	var re: RE = f["re"]
	K.check(fails, not _jab(re, w).is_empty(), "the jab that starts it lands")
	_run(re, 4.0)
	var q := w.pos + w.vis_off
	_run(re, 2.0)
	var p := w.pos + w.vis_off
	var radial := Vector2(q.x, q.z).normalized()
	var moved := Vector2(p.x - q.x, p.z - q.z)
	var lateral := absf(moved.x * -radial.y + moved.y * radial.x)
	K.check(
		fails,
		lateral > 0.2 * WS.M and Vector2(p.x, p.z).length() < RE.FIGHT_REACH * 1.15,
		"a dancer sidesteps round the hero, keeping their ring (%.2f m off the line)" % lateral
	)
	K.check(fails, re.fighting(w), "still in the scrap")
	K.check(
		fails,
		int(re.punches_landed) >= 1,
		"and still landing punches (%d)" % int(re.punches_landed)
	)


## A caller shouts their call longer and drafts the friend near enough to see into the scrap.
func _check_caller() -> void:
	var wk := WK.new()
	wk.player_pos = Vector3.ZERO
	var caller := wk.make("ambient")
	caller.resident_id = "caller"
	wk.stand(caller, Vector3(0.0, 0.0, WS.M), PI)
	caller.state = "walk"
	var friend := wk.make("ambient")
	friend.resident_id = "friend"
	wk.stand(friend, Vector3(2.0 * WS.M, 0.0, 0.5 * WS.M), 0.0)
	friend.state = "walk"
	var far := wk.make("ambient")
	far.resident_id = "far"
	wk.stand(far, Vector3(20.0 * WS.M, 0.0, 0.0), 0.0)
	far.state = "walk"
	var re := RE.new()
	re.setup(wk, null, 12)
	re.fight_odds = {"punch": 1.0, "shove": 1.0}
	re.fight_temper = {caller.id: RE.T_CALLER, friend.id: RE.T_PLAIN}
	re.hero_open = true
	K.check(fails, not _jab(re, caller).is_empty(), "the jab that starts it lands")
	K.check(
		fails,
		re.count() == 2,
		"the call drafts the friend near enough to see (%d reacting)" % re.count()
	)
	var r: RE.Reaction = re.get("_active")[friend.id]
	K.check(fails, r != null and r.fighter, "and the friend joins the scrap")
	var rc: RE.Reaction = re.get("_active")[caller.id]
	var entry := 0.0
	for s: Array in rc.steps:
		if str(s[0]) == "place" and s[1] == &"shout":
			entry = float(s[2])
	K.check(fails, entry > 1.0, "the caller's shout is a call (%.1f s)" % entry)
	_run(re, 8.0)
	K.check(fails, re.fighting(friend), "the friend squares up")
	K.check(
		fails,
		int(re.punches_landed) >= 1,
		"and the scrap lands on the hero (%d)" % int(re.punches_landed)
	)


## A bolt squares up, thinks better of it and runs.
func _check_bolt() -> void:
	var f := _pair(RE.T_BOLT)
	var w: WK.Walker = f["w"]
	var re: RE = f["re"]
	K.check(fails, not _jab(re, w).is_empty(), "the jab that starts it lands")
	var fought := false
	var t := 0.0
	while t < 10.0:
		re.step(DT)
		t += DT
		fought = fought or re.fighting(w)
		if w.react == &"run":
			break
	K.check(fails, fought, "they square up first")
	K.check(fails, w.react == &"run", "then run off, as a plain fight would outlast the check")
	K.check(fails, t < 7.0, "a bolt's scrap is short (%.1f s)" % t)


## A bruiser leads with the cross and answers a blow the moment it lands.
func _check_bruiser() -> void:
	var f := _pair(RE.T_BRUISER)
	var w: WK.Walker = f["w"]
	var re: RE = f["re"]
	var winds: Array = []
	re.on_wind_up = func(id: int, _fist: Vector3, _secs: float) -> void: winds.append(id)
	K.check(fails, not _jab(re, w).is_empty(), "the jab that starts it lands")
	var t := 0.0
	while t < 6.0 and winds.is_empty():
		re.step(DT)
		t += DT
	K.check(fails, not winds.is_empty(), "they come in punching")
	K.check(fails, w.react == &"punch_cross", "a tough one leads with the cross")
	K.check(fails, not _jab(re, w).is_empty(), "and take a jab on the way")
	while not re.fighting(w) and t < 12.0:
		re.step(DT)
		t += DT
	var answer := 0.0
	while answer < 0.5 and winds.size() < 2:
		re.step(DT)
		answer += DT
	K.check(fails, winds.size() >= 2, "answering the blow at once (%.2f s)" % answer)


## With the flag off everyone fights plain: nobody turns a blow aside, nobody leads with the
## cross.
func _check_flag_off() -> void:
	FeatureFlags.set_override("fight_tempers", false)
	var f := _pair(RE.T_BRUISER)
	var w: WK.Walker = f["w"]
	var re: RE = f["re"]
	K.check(fails, not _jab(re, w).is_empty(), "the jab that starts it lands")
	var t := 0.0
	while not re.fighting(w) and t < 4.0:
		re.step(DT)
		t += DT
	var winds: Array = []
	re.on_wind_up = func(id: int, _fist: Vector3, _secs: float) -> void: winds.append(id)
	while t < 8.0 and winds.is_empty():
		re.step(DT)
		t += DT
	K.check(
		fails, not winds.is_empty() and w.react == &"punch_jab", "and nobody leads with the cross"
	)
	var g := _pair(RE.T_GUARD)
	var gw: WK.Walker = g["w"]
	var gre: RE = g["re"]
	gre.guard_share = 1.0
	K.check(fails, not _jab(gre, gw).is_empty(), "the guard's start lands too")
	_run(gre, 3.0)
	K.check(fails, gre.fighting(gw), "they square up")
	var res := _jab(gre, gw)
	K.check(fails, str(res["clip"]) == "hit_head", "without the flag nobody turns a blow aside")
	FeatureFlags.set_override("fight_tempers", true)
