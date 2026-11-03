extends SceneTree
## The first-day opening (flag first_day_opening; scripts/fp/first_day.gd): a fresh street city
## opens on a clear morning at 07:30, its five founding mayor turns land within about 3.5 minutes
## at 1x, and the hero faces down the avenue instead of the City Hall wall. Off, or on a loaded
## save, everything is as before. Pinned here:
## - Weather.daily_state / target_state: day 1 is clear under the opening, for every seed; other
##   days and the flag off keep the daily draw;
## - CitySim.start_at_progress: 07:30 on the street clock, a no-op once a tick has run, saved
##   through the FpMode day phase, and two runs of the same seed end in the same sim bytes;
## - MayorTurns: the compressed day-1 schedule (all five before the first growth tick, the same
##   rotation order), the ordinary schedule on day 2 and after clear();
## - the replay cache is keyed by day, so the same recorded answers come back in both orders;
## - the spawn: City Hall 45 degrees off the line of sight, a straight avenue ahead, the spot
##   itself unchanged, the old yaw when the opening is off;
## - the real Main, booted headless and offline as a player's launch (a fresh XDG_DATA_HOME, no
##   key): opening on, flag off, and a loaded save are three different boots.
## How the first frame looks is not testable headless. Prints FP_FIRST_DAY_TEST: PASS|FAIL. Boots
## Main and autosaves: run it with a throwaway XDG_DATA_HOME (tools/gate.sh does).

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const WEATHER := preload("res://scripts/fp/street/weather.gd")
const FIRST_DAY := preload("res://scripts/fp/first_day.gd")
const MayorTurns := preload("res://scripts/ai/mayor_turns.gd")
const TOKEN := "FP_FIRST_DAY_TEST"
const FLAG := "first_day_opening"

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN, 400.0)
	await process_frame
	check(FeatureFlags.enabled(FLAG), "the flag defaults to on")
	_check_weather()
	_check_schedule()
	_check_clock_and_determinism()
	await _check_world()
	await _check_main()
	K.finish(self, TOKEN, fails)


func _frames(n: int) -> void:
	for _k in range(n):
		await process_frame


# ------------------------------------------------------------------ weather


func _rainy_seeds() -> Array[int]:
	var out: Array[int] = []
	for s in range(0, 400):
		if WEATHER.daily_state(s, 1) != "clear":
			out.append(s)
	return out


func _check_weather() -> void:
	var rainy := _rainy_seeds()
	check(
		rainy.size() >= 20,
		"fixture: some seeds draw a grey or rainy day 1 (%d of 400)" % rainy.size()
	)
	var all_clear := true
	var same_later := true
	var off_same := true
	for s: int in rainy:
		all_clear = all_clear and WEATHER.daily_state(s, 1, true) == "clear"
		off_same = off_same and WEATHER.daily_state(s, 1, false) == WEATHER.daily_state(s, 1)
		for day in range(2, 8):
			same_later = (
				same_later and WEATHER.daily_state(s, day, true) == WEATHER.daily_state(s, day)
			)
	check(all_clear, "the opening makes day 1 clear for every seed that would not be")
	check(same_later, "days 2 to 7 keep the daily draw under the opening")
	check(off_same, "without the opening day 1 keeps its draw")
	# The weather node: target_state reads the context's opening and the sim's day.
	var root := get_root()
	var kit := K.make_ctx(root, {"hud": false, "player": false})
	var w: Node = WEATHER.new()
	root.add_child(w)
	w.ctx = kit
	kit.sim.city_seed = rainy[0]
	check(
		w.target_state() != "clear",
		"the weather node follows the draw by default (%s)" % w.target_state()
	)
	kit.first_day_opening = true
	check(w.target_state() == "clear", "and is clear on day 1 of the opening")
	kit.sim.events.append({"id": 1, "type": "flood", "label": "Flood", "x": 3, "y": 3})
	check(w.target_state() == "rain", "an incident still brings its own weather")
	kit.sim.events.clear()
	kit.sim.day = 2
	check(w.target_state() == WEATHER.daily_state(rainy[0], 2), "day 2 is the daily draw again")
	kit.sim.day = 1
	kit.first_day_opening = false
	kit.mode.from_dict({})
	check(not kit.first_day_opening, "a load or a new city (FpMode.from_dict) ends the opening")
	w.free()


# ------------------------------------------------------------------ schedule


func _check_schedule() -> void:
	var normal := MayorTurns.new()
	normal.start(1, true)
	check(
		is_equal_approx(float(normal.next_turn()["at"]), MayorTurns.at(0)),
		"ordinary day 1: first turn at 0.09"
	)
	var t := MayorTurns.new()
	t.opening = true
	t.start(1, true)
	var n := D.MAYORS.size()
	var first := D.FIRST_DAY_START + D.FIRST_DAY_SPAN * 0.5 / float(n)
	var last := D.FIRST_DAY_START + D.FIRST_DAY_SPAN * (float(n) - 0.5) / float(n)
	check(
		is_equal_approx(float(t.next_turn()["at"]), first),
		"opening day 1: the first turn at %.4f" % first
	)
	check(MayorTurns.order(1) == (t.due as Array), "the rotation order is the ordinary one")
	var secs_first := (first - D.FIRST_DAY_START) * 1200.0
	var secs_last := (last - D.FIRST_DAY_START) * 1200.0
	check(
		secs_first < 30.0,
		"the first mayor acts within 30 s of the start at 1x (%.0f s)" % secs_first
	)
	check(secs_last <= 300.0, "the fifth within 5 minutes (%.0f s)" % secs_last)
	check(last < 0.25, "all five before the first growth tick (%.3f)" % last)
	check(last < MayorTurns.at(1), "the whole founding round ends before the second ordinary turn")
	# take_due pays out the turns in order as progress passes each one.
	var seen: Array[int] = []
	for step in range(0, 301):
		var p := D.FIRST_DAY_START + float(step) / 300.0 * D.FIRST_DAY_SPAN * 1.2
		var mi := t.take_due(p, true)
		if mi >= 0:
			seen.append(mi)
	check(
		seen == MayorTurns.order(1),
		"progress takes the five turns one by one, in order (%s)" % str(seen)
	)
	# Day 2 and a cleared queue use the ordinary spread even when armed.
	t.start(2, true)
	check(
		is_equal_approx(float(t.next_turn()["at"]), MayorTurns.at(0)),
		"day 2 is the ordinary schedule"
	)
	t.start(1, true)
	t.clear()
	check(not t.opening, "clear() disarms the opening")
	t.start(1, true)
	check(
		is_equal_approx(float(t.next_turn()["at"]), MayorTurns.at(0)),
		"a cleared queue runs day 1 as before"
	)
	# A saved queue restores as an ordinary one.
	var saved := MayorTurns.new()
	saved.opening = true
	saved.start(1, true)
	var back := MayorTurns.new()
	back.from_dict(saved.to_dict())
	check(
		is_equal_approx(float(back.next_turn()["at"]), MayorTurns.at(0)),
		"a restored queue keeps the ordinary spread"
	)
	# Not staggered: nothing queued, nothing changes.
	var flat := MayorTurns.new()
	flat.opening = true
	check(not flat.start(1, false) and flat.due.is_empty(), "no stagger, no queue")


# ------------------------------------------------------------------ clock and determinism


func _sim_bytes(opening: bool) -> String:
	var kit := Node.new()
	get_root().add_child(kit)
	var s: Dictionary = K.make_sim(kit, 7)
	var sim: CitySim = s["sim"]
	sim.set_process(false)
	sim.set_speed(0)
	s["people"].set_process(false)
	sim.start()
	if opening:
		sim.start_at_progress(D.FIRST_DAY_START)
	for _k in range(6):
		sim.step_tick()
	var out := JSON.stringify(sim.to_dict())
	kit.free()
	return out


func _check_clock_and_determinism() -> void:
	var kit := Node.new()
	get_root().add_child(kit)
	var s: Dictionary = K.make_sim(kit, 7)
	var sim: CitySim = s["sim"]
	sim.set_process(false)
	sim.set_speed(0)
	sim.set_day_seconds(1200.0)
	check(is_zero_approx(sim.day_progress()), "a new city starts at progress 0 (06:00)")
	sim.start_at_progress(D.FIRST_DAY_START)
	var hour := fmod(6.0 + sim.day_progress() * 24.0, 24.0)
	check(
		is_equal_approx(hour, 7.5),
		"start_at_progress opens the street clock at 07:30 (%.3f)" % hour
	)
	check(sim.tick_in_day == 0 and sim.day == 1, "still tick 0 of day 1")
	check(is_equal_approx(sim.tick_phase(), 0.25), "a quarter of the first growth tick has run")
	sim.step_tick()
	var phase := sim.tick_phase()
	sim.start_at_progress(0.9)
	check(sim.tick_in_day == 1 and sim.tick_phase() == phase, "after a tick it changes nothing")
	kit.free()
	var a := _sim_bytes(true)
	var b := _sim_bytes(true)
	check(
		not a.is_empty() and a == b, "two opening runs of one seed end in byte-identical sim state"
	)
	var c := _sim_bytes(false)
	check(
		c == a,
		"and the clock offset leaves the six ticks' outcome as it was (%d bytes)" % c.length()
	)


# ------------------------------------------------------------------ the world: spawn and the brain


func _check_world() -> void:
	var root := get_root()
	var ctx := K.make_ctx(root, {"hud": false, "view": true, "minds": false})
	ctx.sim.set_process(false)
	ctx.sim.set_speed(0)
	ctx.directory.rebuild()
	var mode := ctx.mode
	var before := mode.spawn_point()
	# The opening is off until begin(): the spawn keeps facing City Hall.
	var hall := ctx.sim.kind.find(D.HALL)
	var hx := float(D.tx(hall))
	var hz := float(D.ty(hall))
	var pos: Vector3 = before["pos"]
	var toward := Vector3(hx - pos.x, 0.0, hz - pos.z).normalized()
	var f0 := _forward(float(before["yaw"]))
	check(
		f0.dot(toward) > 0.99, "fixture: the old spawn faces City Hall (dot %.3f)" % f0.dot(toward)
	)
	check(FIRST_DAY.begin(mode), "begin() runs on a set-up mode")
	check(ctx.first_day_opening, "the context knows the opening is on")
	check(
		is_equal_approx(ctx.sim.day_progress(), D.FIRST_DAY_START),
		"begin() opens the clock at 07:30"
	)
	var after := mode.spawn_point()
	var f1 := _forward(float(after["yaw"]))
	check(
		(after["pos"] as Vector3).is_equal_approx(before["pos"]),
		"the spot is the same, only the heading turns"
	)
	var ang := rad_to_deg(acos(clampf(f1.dot(toward), -1.0, 1.0)))
	check(absf(ang - 45.0) < 2.0, "City Hall is 45 degrees off the line of sight (%.1f)" % ang)
	check(
		absf(wrapf(rad_to_deg(ctx.player.yaw) - float(after["yaw"]), -180.0, 180.0)) < 0.01,
		"the hero was turned to it"
	)
	var road := ctx.directory.frontage(hall)
	var dirc := Vector3(D.tx(hall) - D.tx(road), 0.0, D.ty(hall) - D.ty(road))
	var along := f1 - dirc * f1.dot(dirc)
	var run := _road_run(ctx.sim, Vector3(D.tx(road), 0.0, D.ty(road)), along)
	check(run >= 3, "a straight avenue runs ahead (%d road tiles)" % run)
	ctx.first_day_opening = true
	ctx.sim.day = 2
	check(
		is_equal_approx(float(mode.spawn_point()["yaw"]), float(before["yaw"])),
		"past day 1 the spawn is the old one"
	)
	ctx.sim.day = 1
	mode.from_dict({})
	check(
		is_equal_approx(float(mode.spawn_point()["yaw"]), float(before["yaw"])),
		"a new or loaded city spawns as before"
	)
	# A saved opening day restores its clock through the day phase, and not the opening.
	ctx.sim.start_at_progress(D.FIRST_DAY_START)
	var saved := mode.to_dict()
	check(
		is_equal_approx(float(saved["day_phase"]), 0.25),
		"the save carries the 07:30 clock (day_phase %.2f)" % float(saved["day_phase"])
	)
	mode.from_dict(saved)
	check(
		is_equal_approx(ctx.sim.day_progress(), D.FIRST_DAY_START) and not ctx.first_day_opening,
		"a load keeps the time and drops the opening"
	)
	await _check_brain()


func _forward(yaw_deg: float) -> Vector3:
	var y := deg_to_rad(yaw_deg)
	return Vector3(-sin(y), 0.0, -cos(y))


func _road_run(sim: CitySim, from: Vector3, f: Vector3) -> int:
	var n := 0
	var x := roundi(from.x)
	var y := roundi(from.z)
	var sx := signi(roundi(f.x)) if absf(f.x) > absf(f.z) else 0
	var sy := signi(roundi(f.z)) if absf(f.z) >= absf(f.x) else 0
	for _k in range(8):
		x += sx
		y += sy
		if not D.in_bounds(x, y) or sim.kind[D.idx(x, y)] != D.ROAD:
			break
		n += 1
	return n


## The recorded answers come back by role, mayor and day, so a different turn time changes none.
func _mayor_calls(ctx: FpContext) -> Array:
	var calls: Array = []
	ctx.client.call_logged.connect(
		func(rec: Dictionary) -> void:
			if str(rec.get("role", "")) == "mayor":
				calls.append(
					(
						"%s|%s|%d|%s|%s"
						% [
							rec.get("role"),
							rec.get("agent", ""),
							int(rec.get("day", -1)),
							rec.get("source", ""),
							rec.get("summary", "")
						]
					)
				)
	)
	return calls


func _brain_world(armed: bool) -> FpContext:
	var ctx := K.make_ctx(get_root(), {"hud": false, "player": false, "minds": false})
	ctx.sim.set_process(false)
	ctx.sim.set_speed(0)
	ctx.brain.stagger_mayors = true
	FIRST_DAY.arm(ctx.brain, armed)
	return ctx


func _check_brain() -> void:
	var a := _brain_world(true)
	var calls_a := _mayor_calls(a)
	a.sim.start()
	var first := MayorTurns.order(1)[0]
	var at0 := float(a.brain.turns.next_turn()["at"])
	check(
		is_equal_approx(at0, D.FIRST_DAY_START + D.FIRST_DAY_SPAN * 0.5 / float(D.MAYORS.size())),
		"the brain of an armed city queues the compressed round (first turn at %.4f)" % at0
	)
	check(int(a.brain.turns.next_turn()["mi"]) == first, "led by the day's usual first mayor")
	a.sim.start_at_progress(D.FIRST_DAY_START)
	await _frames(5)
	check(calls_a.is_empty(), "nobody has acted before their turn (%d calls)" % calls_a.size())
	a.sim.set_tick_phase(1.0)
	await _frames(40)
	check(
		calls_a.size() == 5,
		"all five mayors took their day-1 turn before the first growth tick (%d)" % calls_a.size()
	)
	var b := _brain_world(false)
	var calls_b := _mayor_calls(b)
	b.sim.start()
	b.sim.set_tick_phase(1.0)
	await _frames(40)
	check(
		calls_b.size() == 1,
		"the ordinary schedule has one turn done by the same moment (%d)" % calls_b.size()
	)
	for _k in range(D.GROWTH_TICKS_PER_DAY):
		b.sim.step_tick()
	await _frames(40)
	var day1_a := calls_a.filter(func(s: String) -> bool: return s.contains("|1|"))
	var day1_b := calls_b.filter(func(s: String) -> bool: return s.contains("|1|"))
	day1_a.sort()
	day1_b.sort()
	check(
		day1_a.size() == 5 and day1_a == day1_b,
		"both orders ask the replay cache for the same five day-1 answers"
	)
	check(
		day1_a.all(func(s: String) -> bool: return s.contains("|cache|")),
		"and the recorded answers play (source cache)"
	)


# ------------------------------------------------------------------ the real Main


func _boot() -> Node:
	var packed := load("res://scenes/main.tscn") as PackedScene
	change_scene_to_packed(packed)
	await _frames(8)
	return current_scene


func _weather_of(main: Node) -> Node:
	return main.fp.ctx.feature("streetscape").get("weather")


func _check_main() -> void:
	OS.set_environment("GRIDFALL_VIEW", "fp")
	OS.set_environment("GRIDFALL_OFFLINE", "1")
	OS.set_environment("GRIDFALL_NEW_CITY", "1")
	var rain_today := WEATHER.daily_state(7, 1)
	check(
		rain_today != "clear",
		"fixture: the default seed's day 1 is not clear without the opening (%s)" % rain_today
	)
	# 1. Opening on, a fresh city.
	FeatureFlags.set_override(FLAG, true)
	var main := await _boot()
	check(
		main != null and main.fp != null and main.autosave_enabled,
		"fixture: a player's launch boots on foot with autosave"
	)
	var ctx: FpContext = main.fp.ctx
	main.sim.set_speed(0)
	check(
		ctx.first_day_opening and main.brain.turns.opening, "fresh + flag on: the opening is armed"
	)
	check(
		absf(main.sim.day_progress() - D.FIRST_DAY_START) < 0.01,
		"the clock opened at 07:30 (%.4f)" % main.sim.day_progress()
	)
	check(_weather_of(main).state == "clear", "the sky is clear (%s)" % _weather_of(main).state)
	check(
		absf(float(main.brain.turns.next_turn()["at"]) - 0.0815) < 0.001,
		"the first mayor is due at 0.0815"
	)
	var coach: FpFeature = ctx.feature("coach_card")
	check(
		coach != null and coach.call("card_visible"),
		"the coach card, not a toast, welcomes the player"
	)
	var toasts := ctx.hud.toasts.texts()
	check(
		not " ".join(toasts).contains("Welcome to GridFall"), "no welcome toast (%s)" % str(toasts)
	)
	var yaw_open := float(main.fp.spawn_point()["yaw"])
	ctx.first_day_opening = false
	var yaw_old := float(main.fp.spawn_point()["yaw"])
	ctx.first_day_opening = true
	check(
		absf(wrapf(yaw_open - yaw_old, -180.0, 180.0)) > 40.0,
		"the spawn heading turned off the wall (%.1f vs %.1f)" % [yaw_open, yaw_old]
	)
	main.sim.set_tick_phase(0.5)
	check(main.autosave("quit"), "the city saves (a later boot loads it)")
	main.audio._exit_tree()
	# 2. Flag off, a fresh city: exactly today.
	FeatureFlags.set_override(FLAG, false)
	main = await _boot()
	main.sim.set_speed(0)
	ctx = main.fp.ctx
	check(not ctx.first_day_opening and not main.brain.turns.opening, "flag off: nothing armed")
	check(
		main.sim.day_progress() < 0.01,
		"flag off: the clock opens at 06:00 (%.4f)" % main.sim.day_progress()
	)
	check(
		_weather_of(main).state == rain_today,
		"flag off: the day's own weather (%s)" % _weather_of(main).state
	)
	check(
		absf(float(main.brain.turns.next_turn()["at"]) - MayorTurns.at(0)) < 0.0001,
		"flag off: the mayors spread over the day"
	)
	check(
		(
			not main.fp.spawn_point().is_empty()
			and absf(wrapf(float(main.fp.spawn_point()["yaw"]) - yaw_old, -180.0, 180.0)) < 0.01
		),
		"flag off: the hero faces City Hall as before"
	)
	# 2b. A New city from the pause menu is a fresh interactive city too: it gets the opening, and
	# the sky goes clear at once (begin() resyncs the weather) rather than easing out of the rain.
	FeatureFlags.set_override(FLAG, true)
	var rainy_roll := -1
	for r in range(1, 200):
		seed(r)
		if WEATHER.daily_state(randi() % 100000, 1) != "clear":
			rainy_roll = r
			break
	check(rainy_roll > 0, "fixture: a New city roll with a rainy day 1")
	seed(rainy_roll)
	main.new_game()
	main.sim.set_speed(0)
	var fresh_ctx: FpContext = main.fp.ctx
	check(
		WEATHER.daily_state(main.sim.city_seed, 1) != "clear",
		"fixture: the new city's own day 1 is not clear (seed %d)" % main.sim.city_seed
	)
	check(
		fresh_ctx.first_day_opening and main.brain.turns.opening,
		"New city: the opening is armed (flag turned on after boot)"
	)
	check(
		absf(main.sim.day_progress() - D.FIRST_DAY_START) < 0.01,
		"New city: the clock opens at 07:30 (%.4f)" % main.sim.day_progress()
	)
	check(
		_weather_of(main).state == "clear",
		"New city: the sky is clear at once (%s)" % _weather_of(main).state
	)
	main.audio._exit_tree()
	# 3. Flag on, a loaded save: exactly today.
	FeatureFlags.set_override(FLAG, true)
	OS.set_environment("GRIDFALL_NEW_CITY", "")
	main = await _boot()
	main.sim.set_speed(0)
	ctx = main.fp.ctx
	check(
		FileAccess.file_exists("user://gridfall_save.json"), "fixture: the first boot left a save"
	)
	check(
		main.sim.day == 1 and absf(main.sim.day_progress() - 0.125) < 0.01,
		"a loaded save keeps its saved time (%.4f)" % main.sim.day_progress()
	)
	check(not ctx.first_day_opening and not main.brain.turns.opening, "loaded save: no opening")
	check(
		_weather_of(main).state == rain_today,
		"loaded save: the day's own weather (%s)" % _weather_of(main).state
	)
	check(
		not bool(main.fp.ctx.feature("coach_card").call("card_visible")),
		"loaded save: no welcome card"
	)
	main.audio._exit_tree()
	FeatureFlags.set_override(FLAG, true)
	await _check_round_trip_and_tools()


## Day 1 survives a Planner view round trip (the street mode is rebuilt, and its from_dict used to
## drop the opening, so the sky fell back to the day's own rain), and a tool launch (a scripted run
## selected by an environment switch) never arms it, whatever the flag says.
func _check_round_trip_and_tools() -> void:
	OS.set_environment("GRIDFALL_NEW_CITY", "1")
	var main := await _boot()
	main.sim.set_speed(0)
	check(main.fp != null and main.fp.ctx.first_day_opening, "fixture: a fresh opening city")
	check(
		WEATHER.daily_state(main.sim.city_seed, 1) != "clear",
		"fixture: day 1 would be rain without the opening"
	)
	main.exit_fp()
	await _frames(3)
	check(main.fp == null and main.view_mode == "orbit", "fixture: in the Planner view")
	main.enter_fp()
	await _frames(3)
	check(main.fp != null and main.sim.day == 1, "back on foot, still day 1")
	check(main.fp.ctx.first_day_opening, "the opening came back with the street mode")
	check(
		_weather_of(main).state == "clear",
		"and so did the clear sky (%s)" % _weather_of(main).state
	)
	# Past day 1 the day's own draw rules, as before.
	main.sim.day = 2
	check(
		_weather_of(main).target_state() == WEATHER.daily_state(main.sim.city_seed, 2),
		"day 2 draws its own weather"
	)
	main.sim.day = 1
	# A tool launch arms nothing.
	for k: String in ["GRIDFALL_CINEMATIC", "GRIDFALL_FP_SMOKE", "GRIDFALL_PHOTO_DIR"]:
		OS.set_environment(k, "1")
		check(not main._arm_opening(), "tool switch %s: the opening is not armed" % k)
		check(not main.brain.turns.opening, "tool switch %s: the schedule is not compressed" % k)
		OS.unset_environment(k)
	check(main._arm_opening(), "without a tool switch the same Main arms it again")
	main.audio._exit_tree()
