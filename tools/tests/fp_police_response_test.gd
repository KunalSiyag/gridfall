extends "res://tools/tests/fp_police_base.gd"
## The police at the scene (traffic's police_response.gd and police_bust.gd, the police_response
## flag). A crew called for a carjack or an assault drives from the nearest station (or from out of
## town with none) and at the scene posts "Police arrived on <street>" and puts two officers (the
## roster's police bodies) out beside the car; a hero on foot within 60 m gets one walking up,
## "Stop right there!" from 12 m; 3 m from an officer for 2 s after the shout (whoever is near
## shouts first), or in a stopped car beside the police car, is an arrest (a fine by the offence,
## the fade, the hero out of any car and outside the nearest station, the officers back in the car
## and the crew away early); a hero beyond 500 m is "No sign of the suspect"; a blow at an officer
## is resisting; the officers keep to real seconds at 4x and 8x. The chase and the safety checks are
## fp_police_chase_test.gd's.


func _init() -> void:
	await process_frame
	K.watchdog(self, "FP_POLICE_RESPONSE_TEST", 280.0)
	if _setup():
		_check_no_station()
		_build_station()
		_check_arrival()
		_check_arrival_far()
		_check_held_near_scene()
		_check_far_approach()
		_check_approach_and_arrest()
		_check_warning_first()
		_check_real_seconds()
		_check_arrest_thresholds()
		_check_out_of_reach()
		_check_stopped_car()
		_check_real_car()
		_check_resisting()
		_check_calls()
	K.finish(self, "FP_POLICE_RESPONSE_TEST", fails)


## With no station the crew comes from out of town: officers out, an arrest where the hero stands
## (nowhere to be put), the crew gone.
func _check_no_station() -> void:
	K.check(fails, _stations() == 0, "fixture: the city has no police station")
	K.check(fails, tr.police.bust.station_spot(here).is_empty(), "so there is no spot to put them")
	var c := _arrive("carjack", 400.0)
	K.check(fails, c != null, "a crew from out of town reaches the scene")
	if c == null:
		return
	K.check(
		fails,
		str((c.owner as Dictionary).get("why", "")) == "carjack",
		"the crew keeps what it was called for"
	)
	K.check(fails, _pol().officers_of(c.id).size() == 2, "its officers get out with no station")
	ctx.player.input_enabled = true
	var p0 := ctx.player_position()
	_wait(func() -> bool: return not busts.is_empty(), 40.0)
	_step(2.0)
	var moved := _flat_m(ctx.player_position(), p0)
	K.check(
		fails,
		busts.size() == 1 and busts[0][0] == 500,
		"the hero standing there is busted, fined $500 (%s)" % str(busts)
	)
	K.check(fails, moved < 0.5, "with no station nobody moves them (%.1f m)" % moved)
	K.check(fails, _toasted("Released outside") == 0, "and they are not released anywhere")
	K.check(fails, ctx.player.input_enabled, "their input is back after the fade")
	_wait(func() -> bool: return _phase(c) == "leaving" or c.dead, 30.0)
	K.check(
		fails,
		_pol().officers_of(c.id).is_empty() and (c.dead or _phase(c) == "leaving"),
		"the officers are back in the car and the crew leaves"
	)


## A crew called from the station drives to the scene and posts where it is; two officers in the
## roster's police bodies get out beside it.
func _check_arrival() -> void:
	var c := _arrive("carjack", 200.0)
	K.check(fails, c != null, "a crew from the station reaches the scene")
	if c == null:
		return
	var os: Array = _pol().officers_of(c.id)
	K.check(
		fails,
		_pol().phase_of(c.id) == "scene" and os.size() == 2,
		"at the scene two officers are out (%d, %s)" % [os.size(), _pol().phase_of(c.id)]
	)
	var street := str(tr.street_label(tr.police._tile(c.pos)))
	K.check(
		fails,
		_toasted("Police arrived on " + street) == 1 and not street.is_empty(),
		"'Police arrived on %s' is posted once (%s)" % [street, str(toasts)]
	)
	var dressed := true
	var near := true
	var kinds := {}
	for w: WK.Walker in os:
		var n := str(tr.people.avatar_name(w))
		dressed = dressed and n in BODIES and w.role == "officer"
		near = near and _flat_m(w.pos, c.pos) <= 4.0 and is_finite(w.pos.y)
		kinds[n] = true
	K.check(fails, dressed and kinds.size() == 2, "they are the roster's police, two different")
	K.check(fails, near, "and stand by the car")
	K.check(
		fails,
		c.siren and c.state == "at the scene" and _toasted("Police lost") == 0,
		"the car keeps its siren and its place"
	)
	var drawn: Array = tr.walkers_near(c.pos, 4.0 * WS.M)
	var seen := 0
	for e: Dictionary in drawn:
		seen += 1 if int(e["id"]) >= POLICE.FIRST_ID else 0
	K.check(fails, seen == 2, "the street's people lists see them (%d)" % seen)
	tr.sync_visuals(DT)
	var dressed_av := true
	for w: WK.Walker in os:
		dressed_av = dressed_av and w.av >= 0
	K.check(fails, dressed_av, "a frame draws them with a body each")
	_reset()


## Where the hero is when the car gets there decides it: within 50 m the officers get out, within
## 500 m the car goes after them at once ("Police are after you"), further off nobody is found.
func _check_arrival_far() -> void:
	var c := _arrive_far("carjack", 80.0)
	K.check(fails, _responded(c), "fixture: a car at the scene, the hero 80 m down the road")
	if c != null and _responded(c):
		var d := _flat_m(ctx.player_position(), c.pos)
		K.check(
			fails,
			d > 55.0 and _pol().phase_of(c.id) == "chase" and _pol().officers_of(c.id).is_empty(),
			"a hero %.0f m off is hunted at once, nobody gets out (%s)" % [d, _pol().phase_of(c.id)]
		)
		K.check(fails, c.state == "pursuing" and c.siren, "the car is after them, siren on")
		# Told once the car is up to speed (its first leg is often a slow U-turn), not before.
		K.check(
			fails,
			_toasted("Police are after you") == 0,
			"not told while it crawls round the U-turn"
		)
		var told := _wait(func() -> bool: return _toasted("Police are after you") > 0, 40.0)
		var r: Variant = _pol()._resp.get(c.id)
		K.check(
			fails,
			told and _toasted("Police are after you") == 1 and r != null,
			"and told: 'Police are after you' (%s)" % str(toasts)
		)
		if r != null:
			K.check(
				fails,
				c.v >= POLICE.TOLD_V - 0.2 * WS.M or r.t >= POLICE.TOLD_S - 0.2,
				"when it was up to speed (%.1f m/s at %.1f s)" % [c.v / WS.M, r.t]
			)
	c = _arrive_far("carjack", 700.0)
	K.check(fails, _responded(c), "fixture: a car at the scene, the hero 700 m off")
	if c != null and _responded(c):
		var d := _flat_m(ctx.player_position(), c.pos)
		K.check(
			fails,
			d > 505.0 and _toasted("No sign of the suspect") == 1,
			"a hero %.0f m off is not found: 'No sign of the suspect' (%s)" % [d, str(toasts)]
		)
		K.check(
			fails,
			(
				_toasted("Police are after you") == 0
				and _pol().phase_of(c.id) == "scene"
				and _pol().officers_of(c.id).is_empty()
			),
			"nobody gets out and nobody is chased (%s)" % _pol().phase_of(c.id)
		)
		K.check(fails, c.siren and c.state == "at the scene", "the car keeps its place and siren")
		# A hero who turns up within 50 m of it after all gets the officers.
		_hero_at(_along(c, 30.0))
		_step(0.3)
		K.check(
			fails,
			_pol().officers_of(c.id).size() == 2,
			"one who comes within 50 m of the car then has the officers out"
		)
	_reset()


## Thresholds of the approach (a hero on foot, or in a stopped car, within 60 m of the car, one
## officer), the shout from
## 12 m, then the natural arrest and what follows it.
func _walking(c: VH.Car) -> int:
	return _modes(c).filter(func(m: String) -> bool: return m == "approach" or m == "warn").size()


## The review's gaps: a hero 35 to 58 m off was ignored (the approach stopped at 30 m while one
## at 61 m was hunted), and a hero sitting in a stopped car 9 to 35 m off was never walked up to.
func _check_far_approach() -> void:
	var c := _quick("carjack")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	_step(3.0)
	for m: float in [35.0, 48.0, 58.0]:
		_hero_at(_along(c, m))
		_step(0.5)
		K.check(
			fails,
			_walking(c) == 1,
			"a hero on foot %.0f m off gets one officer walking up (%s)" % [m, str(_modes(c))]
		)
		_reset()
		c = _quick("carjack")
		if c == null:
			return
		_step(3.0)
	_drive(_along(c, 20.0), 0.0)
	_hero_at(_along(c, 20.0))
	_step(1.0)
	K.check(
		fails,
		_walking(c) == 1,
		"a hero sitting in a stopped car 20 m off gets one officer walking up (%s)" % str(_modes(c))
	)
	tr._driven = null
	_reset()


## A police car held still near its scene (the hero standing in the roadway keeps it short of its
## stop) counts as arrived after SCENE_HELD_S, not before, not far off and not while it moves.
func _check_held_near_scene() -> void:
	var fl: RefCounted = tr.fleets
	var scene := Vector2(40.0, 40.0)
	var c := VH.Car.new()
	c.pos = Vector3(scene.x + 8.0 * WS.M, 0.0, scene.y)
	var o := {"kind": "police", "stay": 40.0, "scene": scene}
	var held := false
	for _i in range(5):
		held = fl._held_near_scene(c, o, 1.0)
	K.check(fails, not held, "a car held 5 s near its scene is not yet there")
	held = fl._held_near_scene(c, o, 1.5)
	K.check(fails, held, "a car held 6.5 s within 25 m of its scene counts as arrived")
	var moving := {"kind": "police", "stay": 40.0, "scene": scene}
	c.v = 3.0 * WS.M
	for _i in range(10):
		held = fl._held_near_scene(c, moving, 1.0)
	K.check(fails, not held, "a car that keeps moving never counts, however long it takes")
	c.v = 0.0
	c.pos = Vector3(scene.x + 200.0 * WS.M, 0.0, scene.y)
	var far := {"kind": "police", "stay": 40.0, "scene": scene}
	for _i in range(10):
		held = fl._held_near_scene(c, far, 1.0)
	K.check(fails, not held, "a car stood far from its scene does not count")
	var engine := {"kind": "ambulance", "stay": 40.0, "scene": scene}
	c.pos = Vector3(scene.x, 0.0, scene.y)
	for _i in range(10):
		held = fl._held_near_scene(c, engine, 1.0)
	K.check(fails, not held, "only police cars are treated so")


func _check_approach_and_arrest() -> void:
	var c := _quick("carjack")
	K.check(fails, c != null and _phase(c) == "at_scene", "fixture: a police car at the scene")
	if c == null:
		return
	K.check(fails, _modes(c).size() == 2, "officers are out (%s)" % str(_modes(c)))
	# Settle the officers with the hero far off (at the scene itself they would shout at once).
	_hero_at(_along(c, 58.0))
	_step(3.0)
	# In a car under way they are not approached either.
	_drive(_along(c, 20.0), 5.0)
	_hero_at(_along(c, 20.0))
	_step(1.0)
	K.check(fails, _modes(c).has("approach") == false, "nor a hero in a moving car at 20 m")
	tr._driven = null
	_hero_at(_along(c, 29.0))
	_step(0.5)
	var modes := _modes(c)
	var walking := modes.filter(func(m: String) -> bool: return m == "approach" or m == "warn")
	K.check(
		fails, walking.size() == 1, "a hero on foot 29 m off gets one officer (%s)" % str(modes)
	)
	var up: Variant = null
	for k in range(2):
		if _officer(c, k).mode == "approach":
			up = _officer(c, k)
	K.check(fails, up != null, "approaching")
	if up == null:
		return
	var d0 := _flat_m(up.w.pos, ctx.player_position())
	_step(1.0)
	var d1 := _flat_m(up.w.pos, ctx.player_position())
	K.check(fails, d1 < d0 - 1.0, "who closes on the hero (%.1f -> %.1f m)" % [d0, d1])
	K.check(fails, up.w.state == "walk" and up.w.v > 0.0, "walking")
	# The shout from 12 m: not at 13, once at 11 and not again.
	_hero_at(up.w.pos + Vector3(0, 0, 13.0 * WS.M))
	_step(0.2)
	K.check(fails, _toasted("Stop right there!") == 0, "no shout from 13 m")
	_hero_at(up.w.pos + Vector3(0, 0, 11.0 * WS.M))
	ctx.player.input_enabled = true
	var funds0: int = ctx.sim.total_funds()
	_step(0.2)
	K.check(
		fails,
		_toasted("Stop right there!") == 1 and up.mode == "warn" and up.w.react == &"shout",
		"'Stop right there!' from 11 m, the officer shouting (%s)" % str(toasts)
	)
	_step(2.0)
	K.check(fails, _toasted("Stop right there!") == 1, "and not again")
	# A person who sees it, to remember it.
	var rid := str(ctx.residents.people[0]["id"])
	var wit: WK.Walker = tr.walkers.make("resident")
	wit.resident_id = rid
	tr.walkers.stand(wit, ctx.player_position() + Vector3(4.0 * WS.M, 0, 0), 0.0)
	var mood0 := float(ctx.residents.find(rid)["mood"])
	# The hero stands still and is taken.
	var got := _wait(func() -> bool: return not busts.is_empty(), 30.0)
	K.check(
		fails,
		got and busts[0][0] == 500 and busts[0][1] == "carjack",
		"busted: $500 for the carjack (%s)" % str(busts)
	)
	K.check(
		fails,
		_toasted("Busted: fined $500 for carjacking") == 1,
		"'Busted: fined $500 for carjacking' once (%s)" % str(toasts)
	)
	var bust: RefCounted = tr.police.bust
	K.check(
		fails, bust.active() and not ctx.player.input_enabled, "the fade begins and holds the input"
	)
	var close := _flat_m(up.w.pos, ctx.player_position())
	K.check(fails, close <= 3.0 + 1.0, "an officer was within reach of them (%.1f m)" % close)
	var from := ctx.player_position()
	bust.tick(0.2)
	var layer: ColorRect = ctx.hud.slot("overlay").get_node_or_null("PoliceFade")
	K.check(
		fails,
		layer != null and absf(layer.color.a - 0.5) < 0.1,
		"the screen is half black a quarter second in"
	)
	bust.tick(0.35)
	var at := ctx.player_position()
	K.check(fails, layer.color.a > 0.99, "black when the hero is moved")
	K.check(fails, _toasted("Released outside") == 0, "no word where while it is black")
	K.check(
		fails,
		Vector2(at.x - station.x, at.z - station.y).length() < 1.5 and _flat_m(at, from) > 40.0,
		"outside the police station (%s, station %s)" % [str(at), str(station)]
	)
	bust.tick(0.3)
	K.check(fails, _toasted("Released outside") == 1, "with a word where once it can be read")
	bust.tick(1.5)
	K.check(
		fails,
		not bust.active() and ctx.player.input_enabled and layer.color.a == 0.0,
		"the picture and the input come back"
	)
	K.check(fails, ctx.residents.find(rid)["mood"] > mood0, "the one who saw it is easier")
	var mem := str(ctx.residents.find(rid)["memory"])
	K.check(fails, mem.contains("saw the police arrest a visitor"), "and remembers it")
	K.check(fails, ctx.sim.total_funds() == funds0, "no city funds were touched")
	K.check(fails, hit_causes.is_empty(), "nobody was struck on the way")
	# The crew leaves early, the officers aboard.
	var stay: float = (c.owner as Dictionary)["stay"]
	_wait(func() -> bool: return _phase(c) == "leaving", 30.0)
	K.check(
		fails,
		_phase(c) == "leaving" and not c.siren and stay > 5.0,
		"the crew leaves with %.0f s of its stay to run" % stay
	)
	K.check(
		fails,
		_pol().officers_of(c.id).is_empty() and _pol().phase_of(c.id) == "",
		"officers aboard"
	)
	_step(3.0)
	K.check(fails, busts.size() == 1, "and nobody is arrested twice")
	wit.dead = false
	tr.walkers.remove(wit)


## The warning comes first: a hero standing at the car as the officers get out (or in a stopped car
## beside it) is shouted at, and the arrest is 2 s after the shout is over, not before it.
func _check_warning_first() -> void:
	var c := _arrive("carjack", 200.0)
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	_wait(func() -> bool: return not busts.is_empty(), 15.0)
	var shout := _toast_at("Stop right there!")
	K.check(
		fails, shout >= 0.0 and busts.size() == 1, "the hero at the car is shouted at, then taken"
	)
	if shout >= 0.0 and busts.size() == 1:
		var gap: float = busts[0][2] - shout
		K.check(
			fails,
			gap >= 3.3 and gap <= 6.0,
			"the arrest comes 2 s after the shout is over, %.1f s after it" % gap
		)
		K.check(
			fails,
			_toast_at("Police arrived") <= shout and _toasted("Stop right there!") == 1,
			"the shout is once, after 'Police arrived'"
		)
	_reset()


## 4x and 8x: the officers walk at their own pace and the warning keeps its length in real seconds.
func _check_real_seconds() -> void:
	_check_real_walk()
	_check_real_at_car()
	_check_real_pace()


## A hero 25 m off: an officer walks up at 2 m/s of real time, shouts and the arrest is 3.3 real
## seconds after the shout or more, at 4x and at 8x.
func _check_real_walk() -> void:
	for speed: int in [4, 8]:
		var c := _quick("carjack")
		if c == null:
			K.check(fails, false, "fixture: a police car at the scene")
			return
		_to_posts(c)
		_hero_at(_along(c, 25.0))
		_step_speed(0.2, speed)
		var up: Variant = null
		for k in range(2):
			if _officer(c, k).mode == "approach":
				up = _officer(c, k)
		K.check(fails, up != null, "x%d: one officer walks up to a hero 25 m off" % speed)
		if up == null:
			continue
		var p0: Vector3 = up.w.pos
		_step_speed(1.0, speed)
		var moved := _flat_m(up.w.pos, p0)
		K.check(
			fails,
			moved > 1.5 and moved < 2.5,
			"x%d: the officer covers %.1f m in a real second (2 m/s)" % [speed, moved]
		)
		_hero_at(up.w.pos + Vector3(0, 0, 11.0 * WS.M))
		ctx.player.input_enabled = true
		var t_shout := -1.0
		var t_bust := -1.0
		var clock0: float = tr.clock
		for _k in range(int(30.0 / DT)):
			_step_speed(DT, speed)
			if t_shout < 0.0 and _toasted("Stop right there!") > 0:
				t_shout = tr.clock
			if not busts.is_empty():
				t_bust = busts[0][2]
				break
		var real_gap := (t_bust - t_shout) / float(speed)
		K.check(
			fails,
			t_shout >= clock0 and t_bust > t_shout and real_gap >= 3.3,
			"x%d: shout to arrest takes %.1f real seconds (3.3 or more)" % [speed, real_gap]
		)
		_reset()


## A hero at the car at 8x: the shout and the count are real seconds too, and officers sent back
## to the car have their 8 real seconds, not 8 game ones.
func _check_real_at_car() -> void:
	var c8 := _quick("carjack")
	if c8 != null:
		_freeze(c8)
		_hero_at(_officer(c8, 0).w.pos)
		ctx.player.input_enabled = true
		for _k in range(int(30.0 / DT)):
			_step_speed(DT, 8)
			if not busts.is_empty():
				break
		var ts := _toast_at("Stop right there!")
		var gap: float = (busts[0][2] - ts) / 8.0 if ts >= 0.0 and not busts.is_empty() else -1.0
		K.check(
			fails, gap >= 3.3 and gap <= 4.6, "x8: at the car, shout to arrest is %.1f real s" % gap
		)
	_reset()
	c8 = _quick("carjack")
	if c8 != null:
		_to_posts(c8)
		for off: Variant in _pol()._resp[c8.id].officers:
			off.w.pos += Vector3(0.0, 0.0, 25.0 * WS.M)
		_hero_at(_along(c8, 61.0))
		_step_speed(3.0, 8)
		K.check(
			fails,
			_pol().phase_of(c8.id) == "recall" and not _pol().officers_of(c8.id).is_empty(),
			(
				"x8: officers 25 m off are still running back after 3 real s (%s)"
				% _pol().phase_of(c8.id)
			)
		)
	_reset()


## The hero's pace is measured in real seconds: 0.05 m a step at 4x is 4 m/s.
func _check_real_pace() -> void:
	_quick("punch")
	ctx.sim.speed = 4
	var p := ctx.player_position()
	# 0.75 real seconds of it: the pace is the path over each PACE_S real seconds, and the
	# window the hero starts in is a part one.
	for _k in range(60):
		p += Vector3(0.0, 0.0, 0.05 * WS.M)
		_hero_at(p)
		tr.step(DT)
	ctx.sim.speed = 1
	var pace: float = _pol()._hero_v / WS.M
	K.check(fails, absf(pace - 4.0) < 0.4, "x4: the hero's pace is real-time (%.2f m/s)" % pace)
	_reset()


## ARREST_R and ARREST_S: officers held still, the hero 3.2 m off for a while is left alone, the
## count falls back while they are clear, and 2 s within 3 m is an arrest.
func _check_arrest_thresholds() -> void:
	var c := _quick("punch")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	_freeze(c)
	# They have been warned (the warning gating is _check_warning_first's).
	_pol()._resp[c.id].warned = true
	var o: Variant = _officer(c, 0)
	var near: Vector3 = o.w.pos + Vector3(3.2 * WS.M, 0, 0)
	_hero_at(near)
	ctx.player.position.y = o.w.pos.y
	_step(5.0)
	K.check(fails, busts.is_empty(), "3.2 m from an officer for 5 s is no arrest")
	var inside: Vector3 = o.w.pos + Vector3(2.8 * WS.M, 0, 0)
	inside.y = o.w.pos.y
	_hero_at(inside)
	_step(1.0)
	_hero_at(near)
	_step(0.5)
	_hero_at(inside)
	_step(1.4)
	K.check(
		fails,
		busts.is_empty(),
		"1.0 s, away 0.5 s and 1.4 s within 3 m is not 2 s (the count falls back)"
	)
	_step(0.4)
	K.check(
		fails,
		busts.size() == 1 and busts[0][0] == 200 and busts[0][1] == "punch",
		"the 2 s are an arrest, fined $200 for the assault (%s)" % str(busts)
	)
	K.check(
		fails,
		_toasted("Busted: fined $200 for assault") == 1,
		"'Busted: fined $200 for assault' (%s)" % str(toasts)
	)
	_reset()


## A hero 2.5 m above the officers (a ledge) is within the 3 m on the flat but out of reach: they
## are not arrested, and the officers do not stand at them for ever: the crew goes in the end.
func _check_out_of_reach() -> void:
	var c := _quick("carjack")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	_to_posts(c)
	_hero_at(_along(c, 10.0))
	ctx.player.position.y += 2.5 * WS.M
	var left := _wait(func() -> bool: return _phase(c) == "leaving" or c.dead, 90.0)
	K.check(
		fails, left, "a hero on a ledge out of reach: the police leave in the end (%s)" % _phase(c)
	)
	K.check(fails, busts.is_empty(), "and nobody was arrested")
	K.check(
		fails,
		_toasted("Stop right there!") >= 1 and _toasted("Stop right there!") <= 3,
		"they shouted once or twice, not for ever (%d)" % _toasted("Stop right there!")
	)
	_reset()


## In a car: moving, or too far from the police car, no arrest; stopped within 8 m, arrest.
func _check_stopped_car() -> void:
	var c := _quick("carjack")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	_freeze(c)
	_drive(_beside(c, 5.0), 5.0)
	_hero_at(_beside(c, 5.0))
	_step(5.0)
	K.check(fails, busts.is_empty(), "a car under way beside the police car is not stopped")
	_drive(_beside(c, 9.0), 0.3)
	_hero_at(_beside(c, 9.0))
	_step(5.0)
	K.check(fails, busts.is_empty(), "a stopped car 9 m off is not beside it")
	_drive(_beside(c, 7.0), 0.3)
	_hero_at(_beside(c, 7.0))
	_step(0.3)
	K.check(
		fails,
		_toasted("Stop right there!") == 1,
		"a stopped car beside the police car is shouted at first (%s)" % str(toasts)
	)
	_step(3.0)
	K.check(fails, busts.is_empty(), "a stopped car 7 m off is not held for 3.3 s")
	_step(0.5)
	K.check(
		fails,
		busts.size() == 1 and busts[0][0] == 500,
		"a stopped car beside the police car is an arrest 2 s after the shout (%s)" % str(busts)
	)
	K.check(
		fails,
		busts.size() == 1 and busts[0][2] - _toast_at("Stop right there!") >= 3.3,
		"the shout came 3.3 s or more before it"
	)
	_step(0.7)
	K.check(fails, not ctx.player.input_enabled, "the fade holds the input")
	_step(2.0)
	_reset()


## The hero in a real car (the drive feature) stopped beside the police car: arrested, taken out of
## the car by the drive feature's own exit, put outside the station, on foot again.
func _check_real_car() -> void:
	var c := _quick("carjack")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	_freeze(c)
	var it := K.make_feature(ctx, "interact")
	var drive := K.make_feature(ctx, "drive")
	K.check(fails, it != null and drive != null, "fixture: the interact and drive features")
	if it == null or drive == null:
		return
	it.set_process(false)
	drive.set_process(false)
	FeatureFlags.set_override("car_doors", false)
	FeatureFlags.set_override("carjack", false)
	var m: int = tr.car_model_for("police-test")
	var a: VH.Car = tr.vehicles.make("car", "ambient", tr.dims(m))
	a.model = m
	tr.vehicles.place(a, c.lane, clampf(c.s - 0.25, 0.05, c.lane.length - 0.05))
	a.v = 0.0
	var left := Basis(Vector3.UP, a.yaw) * Vector3(a.half_w + 0.6 * WS.M, 0.0, 0.0)
	_hero_at(a.pos + left)
	var in_car: bool = drive.call("enter") == true and bool(drive.get("active"))
	K.check(fails, in_car and tr._driven != null, "fixture: the hero sits in a stopped car")
	if in_car:
		_step(1.5)
		K.check(fails, busts.is_empty(), "1.5 s in the stopped car is not yet an arrest")
		_wait(func() -> bool: return not busts.is_empty(), 6.0)
		K.check(
			fails,
			busts.size() == 1 and busts[0][0] == 500,
			"the stopped car beside the police car is an arrest (%s)" % str(busts)
		)
		_step(1.0)
		var at := ctx.player_position()
		K.check(
			fails,
			not bool(drive.get("active")) and tr._driven == null,
			"the drive feature got them out of the car"
		)
		K.check(
			fails,
			Vector2(at.x - station.x, at.z - station.y).length() < 1.5,
			"outside the police station (%s, station %s)" % [str(at), str(station)]
		)
		_step(2.0)
		K.check(fails, ctx.player.input_enabled, "and on foot with their input back")
	drive.call("exit", true)
	FeatureFlags.set_override("car_doors", true)
	FeatureFlags.set_override("carjack", true)
	for other: VH.Car in tr.vehicles.cars.duplicate():
		if other.role != "crew":
			tr.vehicles.remove(other)
	_reset()


## A blow at an officer is an arrest at once, fined $300, and the officer is not a scene.
func _check_resisting() -> void:
	var c := _quick("punch")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	var w: WK.Walker = _officer(c, 0).w
	hit_causes.clear()
	var info: Dictionary = tr.hit_walker(
		w.id, ctx.player_position(), Vector3(0, 0, 1), 0.9, "punch"
	)
	K.check(fails, info.is_empty() and hit_causes.is_empty(), "a blow at an officer is no scene")
	K.check(
		fails,
		busts.size() == 1 and busts[0][0] == 300 and busts[0][1] == "officer",
		"it is resisting: $300 (%s)" % str(busts)
	)
	K.check(
		fails,
		w.state != "react" and w.react == &"" and not tr.reactions._active.has(w.id),
		"the officer does not reel"
	)
	K.check(fails, not bool(tr.grab_walker(w.id, ctx.player_position())), "nor can they be grabbed")
	_reset()


## Through the street's own path: the first knock-down calls the police, a carjack inside the
## cool-down calls nobody but is held against the crew already on its way.
func _check_calls() -> void:
	_reset()
	K.quiet_walkers(tr)
	var a := K.person_ahead(ctx, tr, 2.0)
	var b := K.person_ahead(ctx, tr, 3.0)
	var info: Dictionary = tr.hit_walker(
		a.id, ctx.player_position(), Vector3(0, 0, 1), 1.0, "punch"
	)
	K.check(fails, str(info.get("crew", "")) == "police", "a knock-down calls the police")
	var crews: int = tr.fleets.count("crew") + tr.fleets.pending.size()
	var again: Dictionary = tr.hit_walker(
		b.id, ctx.player_position(), Vector3(0, 0, 1), 0.85, "carjack", 1.8
	)
	K.check(
		fails,
		(
			str(again.get("crew", "")) == ""
			and tr.fleets.count("crew") + tr.fleets.pending.size() == crews
		),
		"a second call inside the cool-down sends nobody"
	)
	var c: VH.Car = _car()
	K.check(
		fails,
		c != null and str((c.owner as Dictionary).get("why", "")) == "punch",
		"the crew was called for the assault"
	)
	_wait(_at_scene, 200.0)
	K.check(
		fails,
		(
			_pol()._resp.has(c.id)
			and _pol()._resp[c.id].fine == 500
			and _pol()._resp[c.id].why == "carjack"
		),
		"at the scene the worse thing they did since sets the fine"
	)
	_reset()
