extends SceneTree
## Reaction determinism: the street's answer to the hero's fists replays exactly. Two fixtures
## built from scratch in this one process run the same shove script into byte-identical
## snapshots -- with the walkers' setup() seeding them, and without it (the default streams of
## the walkers' and reactions' _init() then have to carry; a fresh RandomNumberGenerator used to
## be randomized per process, so only the setup() path reproduced). And with fight_seeded_rolls
## a victim's own outcomes -- whether they fight back, whether a guard turns the next blow aside
## -- roll off the sim seed and who they are, so bystander reactions running first change
## nothing for them. Reactions run on their own, as fp_tempers_test runs them.

const K := preload("res://tools/tests/fp_kit.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const RE := preload("res://scripts/fp/traffic/reactions.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const DT := 1.0 / 60.0
## The sim seed every fixture here boots from.
const SEED := 12

var fails: Array[String] = []


func _init() -> void:
	await process_frame
	_check_double_run(true)
	_check_double_run(false)
	_check_re_setup_ids()
	_check_order_independence()
	FeatureFlags.reload()
	K.finish(self, "FP_REACT_DETERMINISM_TEST", fails)


# ------------------------------------------------------------------ helpers


## Six walkers standing about, the reactions layer seeded off sim seed SEED: people[0] alone off
## the hero's beat (the fight-roll victim), people[1] three metres from the hero at the origin
## (the guard), people[2..5] clustered thirty metres off (the bystanders, within witness reach
## of one another and of nobody else). with_setup also runs the walkers' own setup(); without
## it the default streams of _init() have to carry.
func _build(with_setup: bool) -> Dictionary:
	var wk := WK.new()
	if with_setup:
		wk.setup(null, null, null, null, SEED)
	wk.player_pos = Vector3.ZERO
	var spots: Array[Vector3] = [
		Vector3(0.0, 0.0, -20.0) * WS.M,
		Vector3(0.0, 0.0, 3.0) * WS.M,
		Vector3(30.0, 0.0, 0.0) * WS.M,
		Vector3(31.2, 0.0, 0.0) * WS.M,
		Vector3(30.0, 0.0, 1.2) * WS.M,
		Vector3(31.2, 0.0, 1.2) * WS.M,
	]
	var people: Array = []
	for i in spots.size():
		var w := wk.make("ambient")
		w.resident_id = "r-%d" % w.id
		wk.stand(w, spots[i], PI)
		w.state = "walk"
		people.append(w)
	var re := RE.new()
	re.setup(wk, null, SEED)
	re.hero_open = true
	return {"wk": wk, "re": re, "people": people}


## w takes a blow of strength from a step behind them, pushed along +z.
func _blow(re: RE, w: WK.Walker, strength: float, cause: String) -> Dictionary:
	return re.hit(
		w, w.pos + Vector3(0.0, 0.0, -WS.M), Vector3(0.0, 0.0, 1.0) * WS.M, strength, cause
	)


## Runs the reactions for secs.
func _run(re: RE, secs: float) -> void:
	for _k in range(ceili(secs / DT - 1e-6)):
		re.step(DT)


## The live reaction of walker w in re, null when none.
func _record(re: RE, w: WK.Walker) -> RE.Reaction:
	return (re.get("_active") as Dictionary).get(w.id)


## Everything observable the scenario settled into, as text: per walker the spawn looks, the
## state and the clip playing; per live reaction the outcome flags and the steps ahead.
func _snapshot(f: Dictionary) -> String:
	var lines: Array[String] = []
	for w: WK.Walker in f["people"]:
		lines.append(
			(
				"w%d|%.6f|%.6f|%.6f|%s|%s|%s"
				% [w.id, w.speed, w.lat_jit, w.phase, w.state, str(w.react), str(w.vis_off)]
			)
		)
	var active: Dictionary = f["re"].get("_active")
	var ids := active.keys()
	ids.sort()
	for id in ids:
		var r: RE.Reaction = active[id]
		lines.append(
			(
				"r%d|fighter=%s|down=%s|mode=%s|temper=%d|steps=%s"
				% [id, str(r.fighter), str(r.down), r.mode, r.temper, str(r.steps)]
			)
		)
	return "\n".join(lines)


## The scripted scenario: pre blows on the bystanders with the street watching each, then the
## victim's own shove, the reactions stepped out a while.
func _play(f: Dictionary, pre: int) -> void:
	var re: RE = f["re"]
	var people: Array = f["people"]
	for i in pre:
		var o: WK.Walker = people[2 + i % (people.size() - 2)]
		_blow(re, o, 0.4, "punch")
		re.witness(o, o.pos, 1)
		_run(re, 0.6)
	var v: WK.Walker = people[0]
	_blow(re, v, 0.5, "shove")
	re.witness(v, v.pos, 1)
	_run(re, 2.0)


## The order-independence probe: pre bystander blow-ups (each with the street watching) run
## ahead of the victims' own -- then the fight victim's fighter flag the moment their shove
## lands, and the clip of the guard's second punch (hit_chest turned aside, hit_head landed in
## full). The seeded rolls answer the same whatever pre was.
func _victim_outcome(pre: int) -> Dictionary:
	var f := _build(true)
	var re: RE = f["re"]
	var people: Array = f["people"]
	var v_f: WK.Walker = people[0]
	var v_g: WK.Walker = people[1]
	re.fight_odds = {"punch": 1.0, "shove": 0.5}
	re.fight_temper = {v_g.id: RE.T_GUARD}
	re.guard_share = 0.5
	for i in pre:
		var o: WK.Walker = people[2 + i % (people.size() - 2)]
		_blow(re, o, 0.4, "punch")
		re.witness(o, o.pos, 1)
		_run(re, 0.6)
	# The fight roll, decided at 0.5: fixed the moment the shove lands (hit() plans the answer).
	_blow(re, v_f, 0.5, "shove")
	var r_f := _record(re, v_f)
	var fighter := r_f != null and r_f.fighter
	# The guard roll, decided at 0.5: a punch the standing guard may turn aside.
	_blow(re, v_g, 0.5, "punch")
	_run(re, 3.0)
	var guard_clip := ""
	if re.fighting(v_g):
		guard_clip = str(_blow(re, v_g, 0.45, "punch").get("clip", ""))
	return {"fighter": fighter, "guard_clip": guard_clip}


# ------------------------------------------------------------------ scenarios


## Two fixtures built from scratch in this process run the same script into byte-identical
## snapshots: with the walkers' setup(), and without it (the default-seed fix).
func _check_double_run(with_setup: bool) -> void:
	var a := _build(with_setup)
	_play(a, 3)
	var b := _build(with_setup)
	_play(b, 3)
	var sa := _snapshot(a)
	var sb := _snapshot(b)
	var how := "with setup()" if with_setup else "without wk.setup()"
	K.check(fails, sa.contains("fighter="), "the script left reactions to compare (%s)" % how)
	K.check(fails, sa == sb, "two fresh builds reproduce, %s" % how)
	if sa != sb:
		print(sa)
		print("  ----")
		print(sb)


## Re-running setup() on one walkers module restarts the ids at 1, so a re-setup fixture makes
## the same walkers a fresh one would.
func _check_re_setup_ids() -> void:
	var wk := WK.new()
	wk.setup(null, null, null, null, SEED)
	wk.make("ambient")
	wk.make("ambient")
	wk.setup(null, null, null, null, SEED)
	var w := wk.make("ambient")
	K.check(fails, w.id == 1, "setup() restarts the walker ids (got %d)" % w.id)


## With fight_seeded_rolls the victims' own outcomes read the seeded per-walker roll, so
## bystander reactions running first change neither the fight roll nor the guard roll; with the
## flag off the legacy shared-stream path still replays (same seed, same order).
func _check_order_independence() -> void:
	var quiet := _victim_outcome(0)
	var busy := _victim_outcome(4)
	K.check(
		fails,
		str(quiet["guard_clip"]) != "",
		"fixture: the guard stood for the second punch (%s)" % str(quiet)
	)
	K.check(
		fails,
		quiet == busy,
		"bystanders first change nothing for the victims (%s vs %s)" % [str(quiet), str(busy)]
	)
	FeatureFlags.set_override("fight_seeded_rolls", false)
	var legacy := _victim_outcome(2)
	var legacy2 := _victim_outcome(2)
	FeatureFlags.set_override("fight_seeded_rolls", true)
	K.check(fails, legacy == legacy2, "and the shared stream still replays without the flag")
