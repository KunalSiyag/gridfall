extends "res://tools/tests/fp_police_base.gd"
## When the police car catches up (traffic's police_response.gd, the police_response flag): a car
## under way takes a hero for caught only when it can stop (not at speed, not braked to a halt
## across a U-turn arc or a junction movement) and the hero has slowed down or the car is stopped
## already; one that has come as near as the roads go takes a hero off the roads for caught from 60
## m; a hero who runs about within 40 m is not given up on at 30 s ("Police gave up the chase", not
## "lost you", when it does); the 60 m flee radius; a worse offence after the car is there raises
## the fine; the nearest officer walks up; the officers get out on the sidewalk side.

const LG := preload("res://scripts/fp/traffic/lane_graph.gd")


func _init() -> void:
	await process_frame
	K.watchdog(self, "FP_POLICE_CATCH_TEST", 280.0)
	if _setup():
		_build_station()
		_check_catch_rules()
		_check_flee_radius()
		_check_reach_after_chase()
		_check_deploy_stopped()
		_check_late_offence()
		_check_nearest_officer()
		_check_curb_side()
		_check_give_up_words()
		_check_u_turn()
		_check_off_road_catch()
		_check_runs_about_near()
	K.finish(self, "FP_POLICE_CATCH_TEST", fails)


## A car in a chase with the officers aboard: a response in phase "chase" with the hero 61 m off.
func _chasing() -> VH.Car:
	var c := _quick("punch")
	if c == null:
		return null
	_to_posts(c)
	_hero_at(_along(c, 61.0))
	_wait(func() -> bool: return _pol().phase_of(c.id) == "chase", 12.0)
	return c if _pol().phase_of(c.id) == "chase" else null


func _lane_of(kind: int) -> Variant:
	for l: Variant in tr.lanes.lanes:
		if l != null and l.kind == kind:
			return l
	return null


## One step of the chase's own decision on a car of its own (not on the street: it is put on a lane
## of kind `kind`, at v m/s, `arrived` or not) with the hero `m` metres off at pace `hero_v` m/s:
## the response's phase after it ("chase" or "scene": caught).
func _decide(
	kind: int, v: float, m: float, hero_v: float, arrived: bool, still: float = 0.0
) -> String:
	var c := VH.Car.new()
	c.id = 9000
	c.pos = Vector3(here.x, here.y, here.z)
	c.owner = {"phase": "chase", "stay": 0.0, "kind": "police", "t": 0.0}
	c.lane = _lane_of(kind)
	c.s = 0.0
	c.v = v * WS.M
	c.arrived = arrived
	var r := POLICE.Resp.new()
	r.c = c
	r.phase = "chase"
	r.t = 1.0
	r.told = true
	r.still = still
	_hero_at(Vector3(c.pos.x, here.y, c.pos.z + m * WS.M))
	_pol()._hero_v = hero_v * WS.M
	_pol()._chase(r, DT)
	return str(r.phase)


func _check_catch_rules() -> void:
	_reset()
	for kind: int in [LG.STRAIGHT, LG.UTURN, LG.MOVE]:
		K.check(fails, _lane_of(kind) != null, "fixture: a lane of kind %d" % kind)
	K.check(
		fails,
		_decide(LG.STRAIGHT, 8.0, 10.0, 0.0, false) == "chase",
		"a car at 8 m/s does not brake for a hero who stood still 10 m off"
	)
	K.check(
		fails,
		_decide(LG.STRAIGHT, 2.0, 10.0, 6.0, false) == "chase",
		"a car under way does not stop for a hero running 10 m off"
	)
	K.check(
		fails,
		_decide(LG.STRAIGHT, 2.0, 30.0, 0.0, false) == "chase",
		"nor for a hero 30 m off while it is still under way (CATCH_R 20 m)"
	)
	K.check(
		fails,
		_decide(LG.STRAIGHT, 0.0, 10.0, 6.0, false) == "scene",
		"a car already stopped 10 m from a hero who runs about is caught up with them"
	)
	K.check(
		fails,
		_decide(LG.STRAIGHT, 2.0, 10.0, 0.0, false) == "scene",
		"a car under way catches a hero who stood still 10 m off"
	)
	K.check(
		fails,
		_decide(LG.STRAIGHT, 0.0, 58.0, 0.0, true) == "scene",
		"a car that has arrived as near as the roads go catches a hero 58 m off"
	)
	K.check(
		fails,
		_decide(LG.STRAIGHT, 0.0, 40.0, 0.0, false) == "chase",
		"a car that has not arrived does not, from 40 m"
	)
	K.check(
		fails,
		_decide(LG.STRAIGHT, 0.0, 65.0, 0.0, true) == "chase",
		"and not one 65 m off, beyond the flee radius"
	)
	K.check(
		fails,
		_decide(LG.UTURN, 2.0, 10.0, 0.0, false) == "chase",
		"a car crawling round a U-turn arc is not braked to a stop across the carriageway"
	)
	K.check(fails, _decide(LG.MOVE, 2.0, 10.0, 0.0, false) == "chase", "nor on a junction movement")
	K.check(
		fails,
		_decide(LG.UTURN, 0.0, 10.0, 0.0, false) == "scene",
		"a car already stopped there (held by the traffic) is stopped: the officers get out"
	)
	K.check(
		fails,
		_decide(LG.MOVE, 0.0, 30.0, 6.0, false, 6.0) == "scene",
		"a car stood 6 s in the traffic 30 m from a hero running about is as near as it gets"
	)
	K.check(fails, _decide(LG.MOVE, 0.0, 30.0, 6.0, false, 3.0) == "chase", "but not after 3 s")
	tr.hero_aboard = true
	K.check(
		fails,
		_decide(LG.STRAIGHT, 0.0, 10.0, 0.0, false) == "chase",
		"a hero in a car is not caught up with on foot"
	)
	tr.hero_aboard = false
	_reset()


func _check_flee_radius() -> void:
	var c := _quick("carjack")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	_to_posts(c)
	_hero_at(_along(c, 46.0))
	_step(1.0)
	K.check(fails, _pol().phase_of(c.id) == "scene", "46 m off is not fleeing")
	_hero_at(_along(c, 59.0))
	_step(1.0)
	K.check(fails, _pol().phase_of(c.id) == "scene", "59 m off is not fleeing")
	_hero_at(_along(c, 61.0))
	_step(0.1)
	K.check(
		fails,
		_pol().phase_of(c.id) in ["recall", "chase"],
		"61 m off is (%s)" % _pol().phase_of(c.id)
	)
	_reset()


## After a chase an officer walks up to a hero from as far as the flee radius (the car could get no
## nearer than the road): 45 m is out of the first response's reach and within a chase's.
func _check_reach_after_chase() -> void:
	var c := _quick("carjack")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	_to_posts(c)
	_hero_at(_along(c, 45.0))
	_step(0.3)
	var plain := _modes(c).filter(func(m: String) -> bool: return m == "approach" or m == "warn")
	K.check(fails, plain.is_empty(), "a hero 45 m off is out of the first response's reach")
	_pol()._resp[c.id].chases = 1
	_step(0.3)
	var chased := _modes(c).filter(func(m: String) -> bool: return m == "approach" or m == "warn")
	K.check(
		fails, chased.size() == 1, "but within a chase's: an officer walks up (%s)" % str(_modes(c))
	)
	_reset()


## The officers of a car that has caught up with a hero get out once it has stopped, not while it
## still rolls.
func _check_deploy_stopped() -> void:
	_reset()
	var c := VH.Car.new()
	c.id = 9001
	c.pos = Vector3(here.x, here.y, here.z)
	c.owner = {"phase": "at_scene", "stay": 25.0, "kind": "police", "t": 0.0}
	var r := POLICE.Resp.new()
	r.c = c
	r.phase = "scene"
	r.chases = 1
	_hero_at(Vector3(c.pos.x, here.y, c.pos.z + 10.0 * WS.M))
	c.v = 2.0 * WS.M
	_pol()._scene(r, c.owner, DT)
	K.check(
		fails,
		not r.deployed and r.officers.is_empty(),
		"no officer gets out of a car still rolling"
	)
	c.v = 0.0
	_pol()._scene(r, c.owner, DT)
	K.check(fails, r.deployed and r.officers.size() == 2, "they get out once it has stopped")
	_pol()._free_officers(r)
	_reset()


## A worse offence after the car is there raises the fine the arrest asks.
func _check_late_offence() -> void:
	var c := _quick("punch")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	_freeze(c)
	_pol()._resp[c.id].warned = true
	_pol().note_offence("carjack")
	ctx.player.input_enabled = true
	_hero_at(_officer(c, 0).w.pos)
	_wait(func() -> bool: return not busts.is_empty(), 6.0)
	K.check(
		fails,
		busts.size() == 1 and busts[0][0] == 500 and busts[0][1] == "carjack",
		"a carjack after the punch that called the car is fined $500 (%s)" % str(busts)
	)
	_reset()


## Of the officers at their posts the one nearest the hero walks up, whichever side they are on.
func _check_nearest_officer() -> void:
	for dir: float in [1.0, -1.0]:
		var c := _quick("carjack")
		if c == null:
			K.check(fails, false, "fixture: a police car at the scene")
			return
		_to_posts(c)
		var hero := Vector3(c.pos.x, here.y, c.pos.z + dir * 24.0 * WS.M)
		var d0 := Vector2(hero.x - _officer(c, 0).w.pos.x, hero.z - _officer(c, 0).w.pos.z).length()
		var d1 := Vector2(hero.x - _officer(c, 1).w.pos.x, hero.z - _officer(c, 1).w.pos.z).length()
		var want := 0 if d0 < d1 else 1
		_hero_at(hero)
		_step(0.3)
		K.check(
			fails,
			_officer(c, want).mode in ["approach", "warn"] and _officer(c, 1 - want).mode == "post",
			(
				"hero %s of the car: the nearer officer (%d) walks up (%s)"
				% ["behind" if dir > 0.0 else "ahead", want, str(_modes(c))]
			)
		)
		_reset()


## The officers get out on the side of the car the sidewalk is on: the same car turned round has
## the other side.
func _check_curb_side() -> void:
	var c := _quick("carjack")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	var side: float = _pol()._curb_side(c)
	var back := VH.Car.new()
	back.pos = c.pos
	back.yaw = c.yaw + PI
	back.vis_yaw = c.vis_yaw
	var other: float = _pol()._curb_side(back)
	K.check(
		fails,
		absf(side) == 1.0 and other == -side,
		"the car turned round has the other curb side (%.0f, %.0f)" % [side, other]
	)
	K.check(fails, _pol()._resp[c.id].side == side, "and the officers got out on it")
	_reset()


## "Police gave up the chase" within 40 m of the hero, "Police lost you" beyond it.
func _check_give_up_words() -> void:
	var c := _chasing()
	if c == null:
		K.check(fails, false, "fixture: a car in a chase")
		return
	_pol()._lose(_pol()._resp[c.id], 30.0 * WS.M)
	K.check(
		fails,
		_toasted("Police gave up the chase") == 1 and _toasted("Police lost") == 0,
		"given up on 30 m from the hero: 'Police gave up the chase' (%s)" % str(toasts)
	)
	c = _chasing()
	_pol()._lose(_pol()._resp[c.id], 90.0 * WS.M)
	K.check(
		fails,
		_toasted("Police lost you") == 1,
		"given up on 90 m from the hero: 'Police lost you' (%s)" % str(toasts)
	)
	_reset()


## A car crawling round the U-turn arc of a chase's first leg is not stopped there for a hero who
## stands close by: it goes on and catches them on a lane it can stop in.
func _check_u_turn() -> void:
	var c := _chasing()
	if c == null:
		K.check(fails, false, "fixture: a car in a chase")
		return
	var on_arc := _wait(
		func() -> bool:
			return c.lane != null and c.lane.kind == LG.UTURN and c.v > POLICE.STOPPED_V,
		30.0
	)
	K.check(fails, on_arc, "fixture: the chase car crawls round a U-turn arc")
	if not on_arc:
		_reset()
		return
	_hero_at(Vector3(c.pos.x, here.y, c.pos.z + 8.0 * WS.M))
	var caught_on_arc := false
	for _k in range(int(1.0 / DT)):
		_step(DT)
		if c.lane.kind == LG.UTURN and c.v > POLICE.STOPPED_V and _pol().phase_of(c.id) == "scene":
			caught_on_arc = true
	K.check(fails, not caught_on_arc, "the car is not braked to a stop on the arc")
	var later := _wait(func() -> bool: return _pol().phase_of(c.id) == "scene", 60.0)
	K.check(fails, later, "it catches the hero once it is off the arc (%s)" % _pol().phase_of(c.id))
	_reset()


## A hero standing 25 to 45 m off the roads (in a park) is reached: the car comes as near as the
## roads go and the officers get out from there (it was "Police lost you" with the car 27 m away).
## Whether they get through to the hero is the terrain's (they have no path-finding).
func _check_off_road_catch() -> void:
	var c := _chasing()
	if c == null:
		K.check(fails, false, "fixture: a car in a chase")
		return
	var spot := _far_spot(c, 25.0, 45.0, 120.0)
	K.check(fails, spot.is_finite(), "fixture: a spot 25 to 45 m off the roads (%s)" % str(spot))
	if not spot.is_finite():
		_reset()
		return
	_hero_at(spot)
	var caught := _wait(
		func() -> bool: return _pol().phase_of(c.id) == "scene" or _pol().phase_of(c.id) == "",
		120.0
	)
	var gap := _flat_m(ctx.player_position(), c.pos)
	K.check(
		fails,
		caught and _pol().phase_of(c.id) == "scene" and _toasted("Police lost") == 0,
		(
			"a hero %.0f m off the roads is caught up with (%s, car %.0f m)"
			% [_gap_m(spot), _pol().phase_of(c.id), gap]
		)
	)
	var out := _wait(func() -> bool: return _officers_alive() == 2, 20.0)
	K.check(fails, out, "and its officers get out and walk up (%s)" % str(_modes(c)))
	_reset()


## A hero who runs about near the car is not "lost" at 30 s with the car 27 m away: the chase goes
## on while it is within 40 m, the car (held by the traffic 22 m off, or stopped near them) is as
## near as it gets, the officers get out and arrest them.
func _check_runs_about_near() -> void:
	var c := _quick("punch")
	if c == null:
		K.check(fails, false, "fixture: a police car at the scene")
		return
	_to_posts(c)
	var stand := _along(c, 100.0)
	_hero_at(stand)
	_wait(func() -> bool: return _pol().phase_of(c.id) == "chase", 12.0)
	var t0: float = tr.clock
	var jit := 0.0
	var near := false
	var out := false
	while tr.clock - t0 < 100.0 and busts.is_empty() and _pol().phase_of(c.id) != "":
		jit = 0.15 * WS.M if jit <= 0.0 else -0.15 * WS.M
		_hero_at(stand + Vector3(jit, 0.0, 0.0))
		_step(DT)
		near = near or _flat_m(ctx.player_position(), c.pos) <= 40.0
		out = out or _officers_alive() > 0
	K.check(fails, near, "fixture: the car came within 40 m of the hero")
	K.check(
		fails,
		_toasted("Police lost") == 0 and _toasted("Police gave up") == 0,
		(
			"a hero running about near the car is not given up on (%s)"
			% str(toasts.map(func(t: Array) -> String: return t[0]))
		)
	)
	K.check(fails, out, "the car stopped near them and the officers got out")
	K.check(fails, busts.size() == 1, "and arrested them (%s)" % str(busts))
	_reset()
