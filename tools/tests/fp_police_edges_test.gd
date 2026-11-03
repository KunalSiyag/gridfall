extends "res://tools/tests/fp_police_base.gd"
## The police response's edges (traffic's police_response.gd and police_bust.gd, the police_response
## flag): an officer's walk ends where it is meant to (float32 positions cannot make the last hair
## of a step), so both officers reach their posts and the recall takes as long as the walk back; the
## arrest fade holds the input and gives back only what it took (the health feature's stagger hands
## it back mid-fade); the hero's pace is the same at 1x, 4x and 8x with the hero moving once a drawn
## frame; a teleport's warm-up does not run the response's clocks; officers do not get out with the
## stay about to run out; a car still on its way turns back once the hero is taken; a hero running
## rings round the car is not answered for ever; only a police car called for the hero's offence is
## a response (an ambulance, a sim disaster's police crew are not); the nearest station; an
## officer's place card; the road tile the chase goes for.

const D_EVENT := 77


func _init() -> void:
	await process_frame
	K.watchdog(self, "FP_POLICE_EDGES_TEST", 280.0)
	if _setup():
		_build_station()
		_check_walk_arrives()
		_check_officers_reach_posts()
		_check_input_hold()
		_check_pace_frames()
		_check_warm_up()
		_check_late_stay()
		_check_en_route()
		_check_circling()
		_check_called_only()
		_check_nearest_station()
		_check_officer_card()
		_check_road_tile()
	K.finish(self, "FP_POLICE_EDGES_TEST", fails)


## A walk to a point a hair beyond its stop radius (the step is below the spacing of float32
## positions, so the officer cannot move it) ends there; it used to walk on the spot for ever.
func _check_walk_arrives() -> void:
	var c := _quick("carjack")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	var off: Variant = _officer(c, 0)
	var at := Vector3(10.0, off.w.pos.y, 10.0)
	off.w.pos = at
	var stop := 0.3 * WS.M
	var to := at
	var hair := 0.0
	for k in range(1, 40):
		to = Vector3(at.x + stop + float(k) * 1e-7, at.y, at.z)
		var gap := Vector2(to.x - at.x, to.z - at.z).length() - stop
		if gap > 1e-7 and gap < 4.0e-7:
			hair = gap
			break
	K.check(fails, hair > 0.0, "fixture: a target %s u beyond the stop radius" % str(hair))
	var there := false
	for _k in range(5):
		there = there or _pol()._walk_to(off, to, POLICE.WALK, DT, stop)
	K.check(
		fails, there, "a walk a hair short of its stop radius is over (not walking on the spot)"
	)
	_reset()


## Calls to two road tiles where the walk to the post used to stall (the officers stayed "out" for
## the whole stay, a hero 15 m off never approached or arrested): both officers are at their posts,
## the hero is shouted at and arrested, and a recall takes the walk back, not the 8 s allowed.
func _check_officers_reach_posts() -> void:
	for i: int in [16407, 18132]:
		var at := Vector3(D.tx(i), here.y, D.ty(i))
		_reset()
		K.check(fails, tr.call_crew("police", at, 40.0, "carjack"), "tile %d: a crew is called" % i)
		_hero_at(at)
		_wait(func() -> bool: return _responded(_car()), 120.0)
		var c := _car()
		if c == null or not _responded(c):
			K.check(fails, false, "tile %d: the car reaches the scene" % i)
			continue
		var head := Vector3(sin(c.yaw), 0.0, cos(c.yaw))
		_hero_at(Vector3(c.pos.x, here.y, c.pos.z) + head * 15.0 * WS.M)
		_step(6.0)
		K.check(
			fails,
			not _modes(c).has("out") and not _modes(c).is_empty(),
			"tile %d: both officers are past 'out' after 6 s (%s)" % [i, str(_modes(c))]
		)
		var done := _wait(func() -> bool: return not busts.is_empty(), 40.0)
		K.check(
			fails,
			done and _toasted("Stop right there!") >= 1,
			"tile %d: the hero 15 m off is shouted at and arrested (%s)" % [i, str(_modes(c))]
		)
		# The walk back to the car: at its door well inside the 8 s allowed, then the car sets off.
		_reset()
		K.check(fails, tr.call_crew("police", at, 40.0, "carjack"), "tile %d: called again" % i)
		_hero_at(at)
		_wait(func() -> bool: return _responded(_car()), 120.0)
		c = _car()
		if c == null or not _responded(c):
			K.check(fails, false, "tile %d: the car reaches the scene again" % i)
			continue
		_step(6.0)
		_hero_at(_along(c, 61.0))
		var t0: float = tr.clock
		var back := _wait(func() -> bool: return _pol().phase_of(c.id) == "chase", 7.0)
		var took: float = tr.clock - t0
		K.check(
			fails,
			back and took < 4.0,
			"tile %d: officers back in the car and the chase on in %.1f s" % [i, took]
		)
	_reset()


## The arrest fade holds the input and gives back only what it took: an arrest in the middle of the
## health feature's guard-break stagger (which hands the input back 0.8 s on) leaves the hero able
## to act when it is over; a hero whose input was off already (a scripted shot) is not given it.
func _check_input_hold() -> void:
	var health := K.make_feature(ctx, "health")
	K.check(fails, health != null, "fixture: the health feature")
	if health == null:
		return
	health.set_process(false)
	var c := _quick("carjack")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	_freeze(c)
	ctx.player.input_enabled = true
	health.call("_guard_break", Vector3(0, 0, 1))
	K.check(fails, not ctx.player.input_enabled, "fixture: the stagger holds the input")
	_pol()._bust(_pol()._resp[c.id])
	var t := 0.0
	var back_early := false
	while t < 3.0:
		_step(0.1)
		# Held when the fade has had its say; the stagger hands it back after.
		back_early = back_early or (ctx.player.input_enabled and tr.police.bust.active())
		health.call("tick", 0.1)
		t += 0.1
	K.check(fails, not tr.police.bust.active(), "fixture: the fade is over")
	K.check(
		fails,
		ctx.player.input_enabled,
		"an arrest in the middle of a stagger leaves the hero their input"
	)
	K.check(fails, not back_early, "and the fade held the input the stagger handed back")
	# Off already: it stays off.
	c = _quick("carjack")
	_freeze(c)
	ctx.player.input_enabled = false
	_pol()._bust(_pol()._resp[c.id])
	_step(3.0)
	K.check(
		fails,
		not tr.police.bust.active() and not ctx.player.input_enabled,
		"a hero whose input was off before the arrest is not given it"
	)
	_reset()


## The hero moves once per drawn frame while the street steps 1, 4 or 8 times in it: the pace the
## chase reads is the same at every speed (6 m/s a run, 1.4 m/s a walk), not a spike on each frame's
## first step.
func _check_pace_frames() -> void:
	var c := _quick("carjack")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	_freeze(c)
	for speed: int in [1, 4, 8]:
		for walk: float in [1.4, 6.0]:
			(c.owner as Dictionary)["stay"] = 5000.0
			ctx.sim.speed = speed
			var p := _along(c, 12.0)
			var lo := INF
			var hi := 0.0
			for frame in range(int(4.0 / DT)):
				p += Vector3(0.0, 0.0, walk * WS.M * DT)
				_hero_at(p)
				for _k in range(speed):
					tr.step(DT)
				if frame >= int(1.0 / DT):
					lo = minf(lo, _pol()._hero_v)
					hi = maxf(hi, _pol()._hero_v)
			ctx.sim.speed = 1
			if walk < 2.0:
				K.check(
					fails,
					hi <= POLICE.CATCH_HERO,
					(
						"x%d: a walk of %.1f m/s never reads as more than %.1f (%.1f)"
						% [speed, walk, 2.5, hi / WS.M]
					)
				)
			else:
				K.check(
					fails,
					lo >= 0.8 * walk * WS.M and hi <= 1.2 * walk * WS.M,
					(
						"x%d: a run of %.1f m/s reads %.1f to %.1f"
						% [speed, walk, lo / WS.M, hi / WS.M]
					)
				)
	_reset()


## A teleport's 14 s warm-up (the feature's _refill) runs the street at once; the response's clocks
## (the arrest cool-down, the officers' give-ups) sit it out.
func _check_warm_up() -> void:
	var c := _quick("carjack")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	var rt0: float = _pol()._rt
	tr._force_refill = true
	tr._process(0.05)
	var gain: float = _pol()._rt - rt0
	K.check(
		fails, gain < 1.0, "a warm-up of %.1f s moved the response's clock %.1f s" % [14.0, gain]
	)
	K.check(fails, not tr.warming, "and the feature is not left warming")
	_reset()


## Officers do not get out with the stay about to run out: a hero who turns up in its last seconds
## would see two officers for a frame and then none (a recall at once). With the stay to run they
## do.
func _check_late_stay() -> void:
	var c := _arrive_far("carjack", 700.0)
	if c == null or not _responded(c):
		K.check(fails, false, "fixture: a car at the scene, the hero 700 m off")
		return
	(c.owner as Dictionary)["stay"] = 6.0
	_hero_at(_along(c, 30.0))
	var seen := false
	for _k in range(10):
		_step(DT)
		seen = seen or _officers_alive() > 0
	K.check(fails, not seen, "a hero who turns up with 6 s of the stay left sees no officers")
	c = _arrive_far("carjack", 700.0)
	_hero_at(_along(c, 30.0))
	_step(0.3)
	K.check(fails, _officers_alive() == 2, "with the stay to run the officers get out")
	_reset()


## A second police car still on its way when the hero is taken turns back: it does not arrive to
## hunt a hero who is fined and outside the station.
func _check_en_route() -> void:
	var c := _quick("carjack")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	_freeze(c)
	_pol()._resp[c.id].warned = true
	# The game's own second call waits out the 90 s cool-down: this one is made by hand.
	K.check(fails, tr.call_crew("police", here, 40.0, "punch"), "fixture: a second call")
	_step(0.5)
	var second: VH.Car = null
	for k: VH.Car in tr.vehicles.cars:
		if k.role == "crew" and k != c and not k.dead:
			second = k
	K.check(
		fails,
		second != null and _phase(second) == "to_scene",
		"fixture: a second police car is on its way"
	)
	ctx.player.input_enabled = true
	_hero_at(_officer(c, 0).w.pos)
	_wait(func() -> bool: return not busts.is_empty(), 10.0)
	K.check(fails, busts.size() == 1, "fixture: the hero is taken")
	_step(0.3)
	K.check(
		fails,
		second != null and (second.dead or _phase(second) == "leaving"),
		"the car still on its way turns back"
	)
	_step(45.0)
	K.check(
		fails,
		_toasted("Police arrived") == 1 and _toasted("Police are after you") == 0,
		(
			"and nobody 'arrives' to hunt the released hero (%s)"
			% str(toasts.map(func(t: Array) -> String: return t[0]))
		)
	)
	_reset()


## A hero running rings round the car 20 m off, out of the officers' reach: the officers are after
## them for at most BUSY_MAX seconds in all, then the car goes (the stay used to be held for as long
## as the hero ran, up to the 240 s a call lasts).
func _check_circling() -> void:
	var c := _quick("carjack")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	var centre := Vector3(c.pos.x, here.y, c.pos.z)
	var ang := 0.0
	var t0: float = tr.clock
	var left := false
	while tr.clock - t0 < 150.0 and not left:
		ang += 3.0 / 20.0 * DT
		_hero_at(centre + Vector3(sin(ang), 0.0, cos(ang)) * 20.0 * WS.M)
		_step(DT)
		left = _phase(c) == "leaving" or c.dead
	var took: float = tr.clock - t0
	K.check(
		fails,
		left and took < 100.0,
		"the car goes within 100 s of a hero who runs rings (%.0f s)" % took
	)
	K.check(fails, busts.is_empty(), "and the hero out of reach was not arrested")
	_reset()


## Only a police car called for the hero's offence is a response: an ambulance (it has a stay too)
## and a police crew a sim disaster sends (it has no stay, and stays while the event lives) are not.
func _check_called_only() -> void:
	_reset()
	K.check(fails, tr.call_crew("ambulance", here, 30.0, "car"), "an ambulance is called")
	var ok := _wait(func() -> bool: return _car() != null and _phase(_car()) == "at_scene", 200.0)
	K.check(fails, ok, "fixture: the ambulance is at the scene")
	_step(1.0)
	K.check(
		fails,
		_pol()._resp.is_empty() and _officers_alive() == 0 and _toasted("Police arrived") == 0,
		"an ambulance at the scene is no police response"
	)
	_reset()
	var target: Vector2i = tr._road_near(Vector2i(roundi(here.x), roundi(here.z)))
	var from: Vector2i = tr._station_road(D.POLICE, target)
	ctx.sim.events.append({"id": D_EVENT, "x": target.x, "y": target.y, "kind": "fire"})
	tr.fleets.dispatch_crew("police", from, target)
	ok = _wait(func() -> bool: return _car() != null and _phase(_car()) == "at_scene", 200.0)
	K.check(fails, ok, "fixture: the sim's police crew is at its event")
	_step(1.0)
	K.check(
		fails,
		_pol()._resp.is_empty() and _officers_alive() == 0 and _toasted("Police arrived") == 0,
		"a sim disaster's police crew puts nobody out"
	)
	ctx.sim.events.clear()
	_reset()


## The hero is put outside the nearest police station: with two, each end of the city has its own.
func _check_nearest_station() -> void:
	var far_lot: Array = []
	var far_d := 0.0
	for lot: Array in ctx.sim.open_lots(0, 200):
		var d := Vector2(float(lot[0]) - station.x, float(lot[1]) - station.y).length()
		if d > far_d:
			far_d = d
			far_lot = lot
	K.check(
		fails, far_d > 8.0, "fixture: a lot well away from the first station (%.0f tiles)" % far_d
	)
	if far_d <= 8.0:
		return
	var res := ctx.sim.apply_action(
		0, {"type": "build", "building": "police", "x": int(far_lot[0]), "y": int(far_lot[1])}
	)
	K.check(fails, bool(res.get("ok", false)), "fixture: a second station (%s)" % str(res))
	var a := Vector2(station.x, station.y)
	var b := Vector2(float(far_lot[0]), float(far_lot[1]))
	var near_a: Dictionary = tr.police.bust.station_spot(Vector3(a.x, here.y, a.y + 1.0))
	var near_b: Dictionary = tr.police.bust.station_spot(Vector3(b.x, here.y, b.y + 1.0))
	K.check(fails, not near_a.is_empty() and not near_b.is_empty(), "both ends have a spot")
	if near_a.is_empty() or near_b.is_empty():
		return
	var pa := Vector2((near_a["pos"] as Vector3).x, (near_a["pos"] as Vector3).z)
	var pb := Vector2((near_b["pos"] as Vector3).x, (near_b["pos"] as Vector3).z)
	K.check(
		fails,
		pa.distance_to(a) < pa.distance_to(b) and pb.distance_to(b) < pb.distance_to(a),
		"each hero is put outside the station nearest them"
	)


## An officer's place card names them on duty, not out and about; a pedestrian's is as it was.
func _check_officer_card() -> void:
	var c := _quick("carjack")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	var card: Variant = ctx.hud.card
	card.open(tr._walker_target(_officer(c, 0).w, 1.0))
	var texts: PackedStringArray = card.texts()
	K.check(
		fails,
		"On duty at the scene" in texts and not ("Out and about on the street" in texts),
		"an officer's card says on duty (%s)" % str(texts)
	)
	card.close()
	var plain: WK.Walker = tr.walkers.make("resident")
	tr.walkers.stand(plain, ctx.player_position() + Vector3(6.0 * WS.M, 0, 0), 0.0)
	card.open(tr._walker_target(plain, 1.0))
	texts = card.texts()
	K.check(
		fails,
		"Out and about on the street" in texts and not ("On duty at the scene" in texts),
		"a pedestrian's card is as it was (%s)" % str(texts)
	)
	card.close()
	plain.dead = false
	tr.walkers.remove(plain)
	_reset()


## The road tile the chase goes for is the nearest to the hero (found ring by ring, not by looking
## at every road tile): the same distance as the brute-force answer, none beyond LOSE_R.
func _check_road_tile() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var bad := 0
	for _k in range(400):
		var p := Vector3(rng.randf_range(-6.0, 44.0), 0.0, rng.randf_range(-6.0, 44.0))
		var got: int = _pol()._road_tile(p)
		var best := POLICE.LOSE_R
		for i: int in tr.lanes.tiles.keys():
			best = minf(best, Vector2(D.tx(i) - p.x, D.ty(i) - p.z).length())
		var dg := Vector2(D.tx(got) - p.x, D.ty(got) - p.z).length() if got >= 0 else POLICE.LOSE_R
		if absf(dg - best) > 1e-4:
			bad += 1
	K.check(
		fails, bad == 0, "the nearest road tile is the brute-force one (%d of 400 differ)" % bad
	)
	K.check(fails, _pol()._road_tile(Vector3(120.0, 0.0, 120.0)) == -1, "none beyond 500 m")
