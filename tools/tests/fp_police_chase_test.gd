extends "res://tools/tests/fp_police_base.gd"
## The police after the hero and in the corners (traffic's police_response.gd, the police_response
## flag): a hero beyond 60 m or driving off has the car after them for 30 s ("Police are after
## you", "Police lost you"; up to 60 s against one who has stopped while it closes), stopping close
## to one who has slowed down; at most two chases; the arrest cool-down; the fade from the feature's
## _process; guards (a hero lying down, the stay running low, the flag off mid-chase); and with
## the flag off a called car sits at the scene as before. Nothing breaks with a car removed, a hero
## in a wall, a world rebuilt or the feature torn down mid-response.


func _init() -> void:
	await process_frame
	K.watchdog(self, "FP_POLICE_CHASE_TEST", 280.0)
	if _setup():
		_build_station()
		_check_flee_and_give_up()
		_check_pursuit_limits()
		_check_caught()
		_check_drive_off()
		_check_flag_off()
		_check_cooldown()
		_check_wiring()
		_check_guards()
		_check_safety()
	K.finish(self, "FP_POLICE_CHASE_TEST", fails)


## A hero beyond 60 m: the officers go back in the car, then the car follows by its own lanes with
## its siren on; out of reach for PURSUE_S, "Police lost you" and the car goes home.
func _check_flee_and_give_up() -> void:
	var c := _quick("punch")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	K.check(fails, _modes(c).size() == 2, "fixture: officers out")
	_to_posts(c)
	var far := _far_spot(c)
	K.check(fails, far.is_finite(), "fixture: a spot off the roads (%s)" % str(far))
	if not far.is_finite():
		return
	_hero_at(_along(c, 61.0))
	_step(0.1)
	K.check(
		fails,
		_pol().phase_of(c.id) == "recall" and _modes(c).has("back"),
		"a hero 61 m off: the officers go back (%s)" % _pol().phase_of(c.id)
	)
	K.check(fails, c.state == "at the scene", "the car waits for them")
	_hero_at(far)
	var t0: float = tr.clock
	var chasing := _wait(func() -> bool: return _pol().phase_of(c.id) == "chase", 12.0)
	K.check(
		fails,
		(
			chasing
			and _pol().officers_of(c.id).is_empty()
			and (c.owner as Dictionary)["phase"] == "chase"
		),
		"the officers aboard, the car sets off (%s)" % _pol().phase_of(c.id)
	)
	K.check(fails, c.state == "pursuing" and c.siren, "pursuing, siren on (%s)" % c.state)
	var from := Vector2(c.pos.x, c.pos.z)
	var jump := 0.0
	var last := from
	var travelled := 0.0
	var chase0: float = tr.clock
	var lost := false
	var jit := 0.0
	while tr.clock - chase0 < 36.0 and not lost:
		# A hero on the move (6 m/s), not standing there.
		jit = 0.15 * WS.M if jit <= 0.0 else -0.15 * WS.M
		_hero_at(far + Vector3(jit, 0.0, 0.0))
		_step(DT)
		var now := Vector2(c.pos.x, c.pos.z)
		jump = maxf(jump, now.distance_to(last) / DT)
		travelled += now.distance_to(last)
		last = now
		lost = _toasted("Police lost you") > 0
	var took: float = tr.clock - chase0
	K.check(
		fails, jump <= 1.3 * WS.EMERGENCY_SPEED, "the car never jumps (%.1f m/s)" % (jump / WS.M)
	)
	K.check(
		fails,
		travelled > 30.0 * WS.M,
		"it drove after the hero (%.0f m by road)" % (travelled / WS.M)
	)
	K.check(
		fails,
		lost and absf(took - 30.0) < 2.0,
		"'Police lost you' after about 30 s of a hero on the move (%.1f)" % took
	)
	_step(1.0)
	K.check(
		fails,
		_phase(c) == "leaving" and not c.siren and _pol().phase_of(c.id) == "",
		"then the car goes home"
	)
	K.check(fails, busts.is_empty() and t0 < tr.clock, "and nobody was arrested")
	_reset()


## The chase's limits: PURSUE_S against a hero who keeps moving (or one the car is not closing on),
## PURSUE_MAX against one who has stopped while it closes, the extension in real use (a hero 100 m
## down the road), and at most two chases.
func _check_pursuit_limits() -> void:
	var c := _quick("punch")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	var far := _far_spot(c)
	if not far.is_finite():
		K.check(fails, false, "fixture: a spot off the roads")
		return
	# A hero standing 60 m or more off the roads (out of the officers' reach), the car said to be
	# closing: 60 s.
	var took := _lost_after(c, far, false, true)
	K.check(
		fails,
		absf(took - 60.0) < 2.0,
		"closing on a hero who stands still: lost after 60 s (%.1f)" % took
	)
	# The same hero and the car not closing on them: 30 s.
	took = _lost_after(_quick("punch"), far, false, false)
	K.check(fails, absf(took - 30.0) < 2.0, "not closing: lost after 30 s (%.1f)" % took)
	# A hero on the move, the car closing: 30 s all the same.
	took = _lost_after(_quick("punch"), far, true, true)
	K.check(
		fails,
		absf(took - 30.0) < 2.0,
		"closing on a hero on the move: lost after 30 s (%.1f)" % took
	)
	# A hero who stopped 100 m down the road is not given up on at 30 s: caught and arrested.
	c = _quick("punch")
	_to_posts(c)
	_hero_at(_along(c, 100.0))
	_wait(func() -> bool: return _pol().phase_of(c.id) == "chase", 12.0)
	var t0: float = tr.clock
	var caught := _wait(func() -> bool: return _pol().phase_of(c.id) == "scene", 70.0)
	took = tr.clock - t0
	K.check(
		fails,
		caught and took > 31.0 and _toasted("Police lost") == 0,
		"a hero standing 100 m off is reached after %.0f s, not lost at 30" % took
	)
	_wait(func() -> bool: return not busts.is_empty(), 60.0)
	K.check(fails, busts.size() == 1 and busts[0][0] == 200, "and arrested (%s)" % str(busts))
	# At most two chases: a third is "lost" at once, a second is not.
	c = _quick("punch")
	_to_posts(c)
	_pol()._resp[c.id].chases = 2
	_hero_at(_along(c, 61.0))
	_wait(func() -> bool: return _toasted("Police lost") > 0, 15.0)
	K.check(fails, _toasted("Police lost") == 1 and _pol().phase_of(c.id) == "", "no third chase")
	c = _quick("punch")
	_to_posts(c)
	_pol()._resp[c.id].chases = 1
	_hero_at(_along(c, 61.0))
	_wait(func() -> bool: return _pol().phase_of(c.id) == "chase", 15.0)
	K.check(fails, _pol().phase_of(c.id) == "chase", "a second chase is made")
	_reset()


## A hero who runs off and then stops where the car can reach: it brakes where it is, the officers
## get out again once it has stopped, and the arrest follows.
func _check_caught() -> void:
	var c := _quick("punch")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	_to_posts(c)
	_hero_at(_along(c, 61.0))
	var chasing := _wait(func() -> bool: return _pol().phase_of(c.id) == "chase", 12.0)
	K.check(fails, chasing, "a hero 61 m off is followed")
	# A long way there and a long chase: the call has run longer than fleets.gd's CALL_MAX (240 s),
	# which must not send the car home the moment it catches up.
	(c.owner as Dictionary)["t"] = float((c.owner as Dictionary)["t"]) + 230.0
	# They stop 15 m ahead of the car (it faces -z): the car is quick to slow down for them.
	var ahead := Vector3(here.x, here.y, c.pos.z - 15.0 * WS.M)
	_hero_at(ahead)
	var early := false
	var saw_scene := false
	for _k in range(60):
		_step(DT)
		saw_scene = saw_scene or _pol().phase_of(c.id) == "scene"
		early = early or (not _pol().officers_of(c.id).is_empty() and c.v > POLICE.STOPPED_V)
	K.check(
		fails,
		saw_scene and not early,
		"the car closes on a hero who stopped: no officer is out while it rolls"
	)
	K.check(
		fails,
		(c.owner as Dictionary)["phase"] == "at_scene" and c.state == "at the scene",
		"it is at the scene again"
	)
	var out := _wait(func() -> bool: return _pol().officers_of(c.id).size() == 2, 20.0)
	K.check(
		fails,
		out and c.v <= POLICE.STOPPED_V,
		"the officers get out once it has stopped (%.2f m/s)" % (c.v / WS.M)
	)
	_wait(func() -> bool: return not busts.is_empty(), 40.0)
	K.check(fails, busts.size() == 1 and busts[0][0] == 200, "and they are arrested ($200)")
	_reset()


## A hero driving off at speed beyond 25 m is fled from just the same.
func _check_drive_off() -> void:
	var c := _quick("carjack")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	_drive(_along(c, 22.0), 8.0)
	_hero_at(_along(c, 22.0))
	_step(1.0)
	K.check(fails, _pol().phase_of(c.id) == "scene", "a car under way at 22 m is not yet off")
	_drive(_along(c, 27.0), 8.0)
	_hero_at(_along(c, 27.0))
	_step(0.1)
	K.check(
		fails, _pol().phase_of(c.id) == "recall", "driving off beyond 25 m: the officers go back"
	)
	var chasing := _wait(func() -> bool: return _pol().phase_of(c.id) == "chase", 12.0)
	K.check(fails, chasing and c.state == "pursuing", "and the car sets off after them")
	tr._driven = null
	_reset()


## With the flag off a called car is as it was: it sits at the scene with its siren for its stay
## and nobody gets out, nobody is warned or arrested; turned off mid-response it lets go cleanly.
func _check_flag_off() -> void:
	FeatureFlags.set_override("police_response", false)
	var c := _quick("carjack")
	K.check(fails, c != null and _phase(c) == "at_scene", "fixture: a car at the scene, flag off")
	if c != null:
		var t0: float = tr.clock
		_step(6.0)
		var none: Array = tr.walkers.walkers.filter(
			func(w: WK.Walker) -> bool: return w.role == "officer"
		)
		K.check(
			fails,
			none.is_empty() and _pol().phase_of(c.id) == "" and _toasted("Police arrived") == 0,
			"nobody gets out and nothing is said"
		)
		K.check(fails, busts.is_empty() and c.siren and c.state == "at the scene", "as it was")
		_wait(func() -> bool: return _phase(c) == "leaving", 60.0)
		var stayed: float = tr.clock - t0
		K.check(
			fails,
			_phase(c) == "leaving" and absf(stayed - 40.0) < 3.0,
			"it leaves when its stay is over (%.1f s)" % stayed
		)
	FeatureFlags.set_override("police_response", true)
	c = _quick("carjack")
	K.check(fails, c != null and _modes(c).size() == 2, "fixture: officers out, flag on")
	FeatureFlags.set_override("police_response", false)
	_step(0.2)
	var left: Array = tr.walkers.walkers.filter(
		func(w: WK.Walker) -> bool: return w.role == "officer"
	)
	K.check(
		fails,
		left.is_empty() and _pol().phase_of(c.id) == "",
		"turned off mid-response: they are gone"
	)
	FeatureFlags.set_override("police_response", true)
	_reset()


## The 20 s arrest cool-down, in real seconds, on its own: the fade of the first is long over.
func _check_cooldown() -> void:
	var c := _quick("carjack")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	_freeze(c)
	_pol()._resp[c.id].warned = true
	_hero_at(_officer(c, 0).w.pos)
	_wait(func() -> bool: return not busts.is_empty(), 6.0)
	K.check(fails, busts.size() == 1, "fixture: an arrest")
	_step(10.0)
	K.check(fails, not tr.police.bust.active(), "the fade of the first is over")
	var other := POLICE.Resp.new()
	other.fine = 100
	_pol()._bust(other)
	K.check(fails, busts.size() == 1, "an arrest 10 s after one waits")
	_step(11.0)
	_pol()._bust(other)
	K.check(fails, busts.size() == 2 and busts[1][0] == 100, "and one 21 s after it does")
	_reset()


## Wiring: the fade runs from the feature's own _process, a missing station is no spot, a station's
## doorway is not a wall, an officer is no pedestrian and no bystander of a scene, and the flag is
## on by default.
func _check_wiring() -> void:
	K.check(
		fails,
		FeatureFlags.defaults().get("police_response", false) == true,
		"the flag is on by default"
	)
	_reset()
	ctx.player.input_enabled = true
	tr.police.bust.begin(100, "punch", ctx.player_position(), "a street")
	var layer: ColorRect = null
	for _k in range(2):
		tr._process(0.3)
	layer = ctx.hud.slot("overlay").get_node_or_null("PoliceFade")
	K.check(
		fails,
		layer != null and layer.color.a > 0.9 and not ctx.player.input_enabled,
		"the fade runs from the feature's _process (it is black at 0.6 s)"
	)
	for _k in range(6):
		tr._process(0.3)
	K.check(
		fails,
		not tr.police.bust.active() and ctx.player.input_enabled and layer.color.a == 0.0,
		"and is over, the input back, 2.4 s on"
	)
	# The station's doorway: the hero put there is out of any box built on the spot.
	var spot: Dictionary = tr.police.bust.station_spot(here)
	K.check(fails, not spot.is_empty(), "fixture: a station spot")
	if not spot.is_empty():
		var sp: Vector3 = spot["pos"]
		ctx.collision.add_test_box(AABB(sp - Vector3(0.6, 0.0, 0.6), Vector3(1.2, 3.0, 1.2)))
		_reset()
		tr.police.bust.begin(100, "punch", ctx.player_position(), "a street")
		tr.police.bust.tick(0.6)
		var in_box: bool = ctx.collision.is_blocked(ctx.player.position, WS.PLAYER_RADIUS)
		K.check(
			fails, not in_box, "a hero put in a box on the station's doorway is moved out of it"
		)
		tr.police.bust.tick(2.0)
		ctx.collision.clear_test_boxes()
	# An officer reads as one when looked at, and is not a bystander the street's scenes use.
	var c := _quick("carjack")
	if c != null:
		var w: WK.Walker = _officer(c, 0).w
		var card: Dictionary = tr._walker_target(w, 1.0)
		K.check(
			fails,
			str(card.get("label", "")) == "a police officer",
			"an officer is named as one (%s)" % str(card)
		)
		var plain: WK.Walker = tr.walkers.make("resident")
		tr.walkers.stand(plain, ctx.player_position() + Vector3(6.0 * WS.M, 0, 0), 0.0)
		K.check(
			fails,
			not tr.reactions._free(w) and tr.reactions._free(plain),
			"reactions leave officers out and take an ordinary walker"
		)
		plain.dead = false
		tr.walkers.remove(plain)
	_reset()


## Guards: nobody lying down is arrested, the officers go back by themselves when the stay runs low,
## the stay is held while they are at the hero and while they walk back, an officer is called off a
## hero who got away, and the flag turned off mid-chase sends the car home.
func _check_guards() -> void:
	var c := _quick("carjack")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	var health := K.make_feature(ctx, "health")
	K.check(fails, health != null, "fixture: the health feature")
	if health != null:
		health.set_process(false)
		_freeze(c)
		_pol()._resp[c.id].warned = true
		_hero_at(_officer(c, 0).w.pos)
		health.set("_down_t", 1.0)
		_step(4.0)
		K.check(fails, busts.is_empty(), "a hero lying knocked down is not arrested")
		health.set("_down_t", -1.0)
		_wait(func() -> bool: return not busts.is_empty(), 6.0)
		K.check(fails, busts.size() == 1, "and is once they are up")
	# The stay running low: the officers go back by themselves.
	c = _quick("carjack")
	_to_posts(c)
	_freeze(c)
	_hero_at(_along(c, 35.0))
	(c.owner as Dictionary)["stay"] = 8.5
	_step(1.0)
	K.check(
		fails,
		_pol().phase_of(c.id) != "scene" and float((c.owner as Dictionary)["stay"]) > 5.0,
		"with 8 s of the stay to run the officers go back to leave (%s)" % _pol().phase_of(c.id)
	)
	# A stay used up while they are at the hero is held.
	c = _quick("carjack")
	_to_posts(c)
	_hero_at(_along(c, 29.0))
	_step(0.3)
	(c.owner as Dictionary)["stay"] = 3.0
	_step(0.3)
	K.check(
		fails,
		float((c.owner as Dictionary)["stay"]) >= 9.5 and _phase(c) == "at_scene",
		(
			"the stay is held while an officer is after the hero (%.1f)"
			% float((c.owner as Dictionary)["stay"])
		)
	)
	# An officer's time at the hero counts from when they got there: walking resets it.
	var walker: Variant = null
	for k in range(2):
		if _officer(c, k).mode == "approach" or _officer(c, k).mode == "warn":
			walker = _officer(c, k)
	if walker != null:
		walker.mode = "approach"
		walker.held = 3.0
		_step(0.1)
		K.check(
			fails, walker.held == 0.0, "an officer on the way to the hero has not been 'at' them"
		)
	# A hero 46 m off, in reach of the flee radius, is still walked up to.
	_hero_at(_along(c, 46.0))
	_step(0.3)
	var walking := _modes(c).filter(func(m: String) -> bool: return m == "approach" or m == "warn")
	K.check(fails, not walking.is_empty(), "an officer keeps after a hero 46 m away")
	# The stay held while the officers walk back, however slowly.
	c = _quick("carjack")
	_to_posts(c)
	for off: Variant in _pol()._resp[c.id].officers:
		off.w.pos += Vector3(0.0, 0.0, 25.0 * WS.M)
	(c.owner as Dictionary)["stay"] = 0.3
	_hero_at(_along(c, 61.0))
	_step(1.0)
	K.check(
		fails,
		_phase(c) == "at_scene" and _pol().phase_of(c.id) == "recall",
		(
			"the car waits for officers still on their way back (%s, %s)"
			% [_phase(c), _pol().phase_of(c.id)]
		)
	)
	# The flag turned off in a chase: the car goes home.
	c = _quick("punch")
	_to_posts(c)
	_hero_at(_along(c, 61.0))
	_wait(func() -> bool: return _pol().phase_of(c.id) == "chase", 12.0)
	FeatureFlags.set_override("police_response", false)
	_step(0.3)
	K.check(
		fails,
		_phase(c) == "leaving" and not c.siren,
		"the flag turned off mid-chase sends the car home (%s)" % _phase(c)
	)
	FeatureFlags.set_override("police_response", true)
	_reset()


func _check_safety() -> void:
	# A car taken off the street takes its officers with it.
	var c := _quick("carjack")
	K.check(fails, c != null and _officers_alive() == 2, "fixture: officers out")
	if c != null:
		tr.vehicles.remove(c)
		_step(0.2)
		K.check(
			fails,
			_officers_alive() == 0 and _pol()._resp.is_empty(),
			"the crew removed: officers freed"
		)
	# A hero shut in a wall is not walked into: the officer gives up, and tries again later.
	c = _quick("carjack")
	if c != null:
		var spot := _along(c, 20.0)
		var wall := Vector3(here.x - 0.6, 0.0, c.pos.z + 10.0 * WS.M)
		ctx.collision.add_test_box(AABB(wall, Vector3(1.2, 3.0, 0.1)))
		_hero_at(spot)
		_to_posts(c)
		_step(13.0)
		var r: Variant = _pol()._resp.get(c.id)
		K.check(fails, r != null and r.officers.size() == 2, "the wall stops them: both still out")
		var gave := false
		if r != null:
			for off: Variant in r.officers:
				gave = gave or float(off.until) > _pol()._rt
		K.check(
			fails,
			gave and busts.is_empty(),
			"a hero behind a wall: the officer gives up for a while"
		)
		ctx.collision.clear_test_boxes()
	# A world rebuilt (a load) mid-response drops them all; the next call works.
	c = _quick("carjack")
	K.check(fails, c != null and _officers_alive() == 2, "fixture: officers out")
	ctx.player.input_enabled = true
	tr.on_world_rebuilt()
	K.check(
		fails,
		_officers_alive() == 0 and _pol()._resp.is_empty() and ctx.player.input_enabled,
		"a load mid-response leaves no officer and no hero stuck"
	)
	c = _quick("carjack")
	K.check(fails, c != null and _officers_alive() == 2, "and the next call is answered")
	# A cooldown holds a second arrest.
	_freeze(c)
	ctx.player.input_enabled = true
	_pol()._resp[c.id].warned = true
	_hero_at(_officer(c, 0).w.pos)
	_wait(func() -> bool: return not busts.is_empty(), 6.0)
	K.check(fails, busts.size() == 1, "fixture: one arrest")
	var r: Variant = _pol()._resp.get(c.id)
	if r != null:
		_pol()._bust(r)
	_step(0.1)
	K.check(fails, busts.size() == 1, "a second arrest inside the cool-down waits")
	# Torn down mid-fade (leaving first person): no officer, no fade, the hero's input back.
	K.check(fails, tr.police.bust.active(), "fixture: mid-fade")
	tr.teardown()
	K.check(
		fails,
		_officers_alive() == 0 and not tr.police.bust.active() and ctx.player.input_enabled,
		"teardown mid-response: no officer, no fade"
	)
