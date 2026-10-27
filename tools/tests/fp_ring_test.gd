extends SceneTree
## The brawl ring (flag brawl_ring): three or more fighting the hero slot by arrival — the
## first two engage as ever, the rest hold the ring two metres out on their own ray from the
## fight, facing in and punching nothing, until a slot ahead opens (one down) and they step in;
## the crowd round the ring jeers, one turning to shout every breath or two. With the flag off
## every fighter piles in at once and the crowd keeps its own counsel. Reactions run on their
## own, as fp_tempers_test runs them.

const K := preload("res://tools/tests/fp_kit.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")
const RE := preload("res://scripts/fp/traffic/reactions.gd")
const FB := preload("res://scripts/fp/traffic/fight_back.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const DT := 1.0 / 60.0

var fails: Array[String] = []


func _init() -> void:
	await process_frame
	_check_ring()
	_check_promotion()
	_check_jeers()
	_check_flag_off()
	FeatureFlags.reload()
	K.finish(self, "FP_RING_TEST", fails)


# ------------------------------------------------------------------ helpers


## A hero at the origin, four fighters round them a metre out (all pinned plain, fight_odds 1,
## so a jab each makes them all square up) and n_bys onlookers 9.5 metres out, past the witness
## radius but inside the jeer's.
func _brawl(n_bys := 0) -> Dictionary:
	var wk := WK.new()
	wk.setup(null, null, null, null, 12)  # seeds its rolls; the lanes stay null
	wk.player_pos = Vector3.ZERO
	var re := RE.new()
	re.setup(wk, null, 12)
	re.fight_odds = {"punch": 1.0, "shove": 1.0}
	re.hero_open = true
	var fighters: Array = []
	var tempers := {}
	for i in 4:
		var w := wk.make("ambient")
		w.resident_id = "f-%d" % w.id
		var a := i * PI / 2.0
		wk.stand(w, Vector3(sin(a), 0.0, cos(a)) * WS.M, a + PI)
		w.state = "walk"
		fighters.append(w)
		tempers[w.id] = RE.T_PLAIN
	re.fight_temper = tempers
	var bys: Array = []
	for i in n_bys:
		var o := wk.make("ambient")
		o.resident_id = "b-%d" % o.id
		var a := PI / 4.0 + i * PI / 2.0
		wk.stand(o, Vector3(sin(a), 0.0, cos(a)) * 9.5 * WS.M, a + PI)
		o.state = "walk"
		bys.append(o)
	return {"wk": wk, "re": re, "fighters": fighters, "bys": bys}


## The hero's jab at w (strength 0.45), from the origin, pushing them away.
func _jab(re: RE, w: WK.Walker) -> Dictionary:
	return re.hit(
		w, Vector3.ZERO, Vector3(w.pos.x, 0.0, w.pos.z).normalized() * WS.M, 0.45, "punch"
	)


## Runs the reactions for secs.
func _run(re: RE, secs: float) -> void:
	for _k in range(ceili(secs / DT - 1e-6)):
		re.step(DT)


## The live reaction of walker w in re, null when none.
func _record(re: RE, w: WK.Walker) -> Variant:
	return (re.get("_active") as Dictionary).get(w.id)


## w's distance from the hero (the origin).
func _off(w: WK.Walker) -> float:
	return (w.pos + w.vis_off).distance_to(Vector3.ZERO)


## True when w is turned to face the hero (the origin).
func _facing_in(w: WK.Walker) -> bool:
	var want := atan2(-w.pos.x, -w.pos.z)
	return absf(wrapf(w.yaw - want, -PI, PI)) < 0.3


# ------------------------------------------------------------------- checks


## Two engage, the rest hold the ring two metres out, facing in, punching nothing.
func _check_ring() -> void:
	var b := _brawl()
	var re: RE = b["re"]
	var fighters: Array = b["fighters"]
	for w: WK.Walker in fighters:
		K.check(fails, not _jab(re, w).is_empty(), "the jab that starts it lands")
	var punched := {}
	var t := 0.0
	while t < 5.0:
		re.step(DT)
		t += DT
		for w: WK.Walker in fighters:
			var r: Variant = _record(re, w)
			if r != null and float(r.get("blow_t")) >= 0.0:
				punched[w.id] = true
	var near: Array = []
	var ring: Array = []
	for w: WK.Walker in fighters:
		if _off(w) < RE.FIGHT_REACH + 0.3 * WS.M:
			near.append(w)
		elif absf(_off(w) - FB.RING_R) < 0.4 * WS.M:
			ring.append(w)
	K.check(
		fails,
		near.size() == FB.RING_SLOTS and ring.size() == fighters.size() - FB.RING_SLOTS,
		"two engage, the rest hold the ring (%d in, %d holding)" % [near.size(), ring.size()]
	)
	var held := true
	var facing := true
	for w: WK.Walker in ring:
		held = held and not punched.has(w.id)
		facing = facing and _facing_in(w)
	K.check(fails, held, "the ring holds, punching nothing")
	K.check(fails, facing, "facing in")
	var threw := true
	for w: WK.Walker in near:
		threw = threw and punched.has(w.id)
	K.check(fails, threw, "the two in front do the punching")


## A slot ahead opens — the engaged fighter goes down — and a holder steps in and joins the
## punching, while the last holder still holds the ring.
func _check_promotion() -> void:
	var b := _brawl()
	var re: RE = b["re"]
	var fighters: Array = b["fighters"]
	for w: WK.Walker in fighters:
		_jab(re, w)
	_run(re, 5.0)
	var victim: WK.Walker = null
	var holder: WK.Walker = null
	var last: WK.Walker = null
	var next_seq := 1 << 30
	for w: WK.Walker in fighters:
		if _off(w) < RE.FIGHT_REACH + 0.3 * WS.M:
			if victim == null:
				victim = w
			continue
		# The next in order (the lowest slot among the holders) steps in when a slot opens.
		var s := int((_record(re, w) as Variant).get("slot_seq"))
		if s < next_seq:
			if holder != null:
				last = holder
			next_seq = s
			holder = w
		else:
			last = w
	K.check(
		fails, victim != null and holder != null, "the ring has formed (one engaged, one holding)"
	)
	var res := {}
	var tries := 0
	while tries < 5 and not bool(res.get("down", false)):
		res = re.hit(
			victim,
			Vector3.ZERO,
			Vector3(victim.pos.x, 0.0, victim.pos.z).normalized() * WS.M,
			1.0,
			"punch"
		)
		tries += 1
		_run(re, 0.1)
	K.check(fails, bool(res.get("down", false)), "the engaged fighter goes down")
	var stepped := false
	var t := 0.0
	while t < 4.0 and not stepped:
		re.step(DT)
		t += DT
		stepped = _off(holder) < RE.FIGHT_REACH + 0.3 * WS.M
	K.check(fails, stepped, "a holder steps into the open slot (%.1f s)" % t)
	var threw := false
	t = 0.0
	while t < 3.0 and not threw:
		re.step(DT)
		t += DT
		var r: Variant = _record(re, holder)
		threw = r != null and float(r.get("blow_t")) >= 0.0
	K.check(fails, threw, "and joins the punching")
	var holding := 0
	for w: WK.Walker in fighters:
		if w == victim or w == holder:
			continue
		if absf(_off(w) - FB.RING_R) < 0.4 * WS.M:
			holding += 1
	K.check(
		fails, holding == 1 and _facing_in(last), "the last holder still holds the ring, facing in"
	)


## The crowd round the ring jeers: while three or more fight, someone near turns to the fight
## and shouts.
func _check_jeers() -> void:
	var b := _brawl(3)
	var re: RE = b["re"]
	var fighters: Array = b["fighters"]
	var bys: Array = b["bys"]
	for w: WK.Walker in fighters:
		_jab(re, w)
	_run(re, 2.0)
	var jeered := {}
	var t := 0.0
	while t < 6.0:
		re.step(DT)
		t += DT
		for o: WK.Walker in bys:
			if o.react == &"shout":
				jeered[o.id] = true
	K.check(
		fails, not jeered.is_empty(), "the crowd round the ring jeers (%d of them)" % jeered.size()
	)


## With the flag off every fighter piles in at once and the crowd keeps its own counsel.
func _check_flag_off() -> void:
	FeatureFlags.set_override("brawl_ring", false)
	var b := _brawl(3)
	var re: RE = b["re"]
	var fighters: Array = b["fighters"]
	var bys: Array = b["bys"]
	for w: WK.Walker in fighters:
		_jab(re, w)
	var shouted := false
	var t := 0.0
	while t < 5.0:
		re.step(DT)
		t += DT
		for o: WK.Walker in bys:
			shouted = shouted or o.react == &"shout"
	var piled := 0
	for w: WK.Walker in fighters:
		if _off(w) < RE.FIGHT_REACH + 0.4 * WS.M:
			piled += 1
	K.check(fails, piled == fighters.size(), "with the flag off everyone piles in (%d)" % piled)
	K.check(fails, not shouted, "and the crowd keeps its own counsel")
	FeatureFlags.set_override("brawl_ring", true)
