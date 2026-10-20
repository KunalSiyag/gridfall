extends SceneTree
## The player's crews (CitySim.apply_player_order): phone orders go to D.CREWS crews that build in
## real seconds at game speed (2 to 5 minutes for a building), later orders queue for a free crew,
## contractors and growth ticks leave crew sites alone, residents can help, a crew that finishes
## takes the next order with the rest of the time, and orders survive save/load, skipping to
## morning, bulldozing (cancel) and sliced ticks.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")

var fails: Array[String] = []
var sim: CitySim
var started: Array[Dictionary] = []
var finished: Array[Dictionary] = []
var staged: Array[int] = []


func _init() -> void:
	await process_frame
	_check_seconds()
	var s := K.make_sim(get_root())
	sim = s["sim"]
	sim.construction_mode = "staged"
	sim.start()
	sim.mayors[0]["treasury"] = 60000
	sim.crew_job_started.connect(func(j: Dictionary) -> void: started.append(j))
	sim.crew_job_finished.connect(func(j: Dictionary) -> void: finished.append(j))
	sim.site_stage.connect(func(st: Dictionary) -> void: staged.append(int(st["i"])))
	_check_order_and_queue()
	_check_ticks()
	_check_save_load()
	_check_cancel()
	_check_help()
	_check_frames()
	_check_skip()
	_check_instant()
	K.finish(self, "FP_CREW_JOBS_TEST", fails)


# ------------------------------------------------------------------ helpers


func _build(key: String) -> Dictionary:
	var lot: Array = sim.open_lots(0, 10)[0]
	var a := {"type": "build", "building": key, "x": int(lot[0]), "y": int(lot[1])}
	return sim.apply_player_order(0, a)


func _tile(res: Dictionary) -> int:
	return D.idx(int(res.get("x", -99)), int(res.get("y", -99)))


func _job(res: Dictionary) -> Dictionary:
	return res.get("job", {})


## A road over 5 open land tiles in a row in district 0.
func _road_order() -> Dictionary:
	for i in range(D.W * D.H):
		var x := D.tx(i)
		var y := D.ty(i)
		var n := 0
		while n < 5 and _open(x + n, y):
			n += 1
		if n == 5:
			return sim.apply_player_order(0, {"type": "road", "x": x, "y": y, "x2": x + 4, "y2": y})
	return {}


func _open(x: int, y: int) -> bool:
	if not D.in_bounds(x, y):
		return false
	var i := D.idx(x, y)
	return sim.district[i] == 0 and sim.kind[i] == D.EMPTY and sim.terrain[i] == D.LAND


# ------------------------------------------------------------------ checks


func _check_seconds() -> void:
	var lo := INF
	var hi := 0.0
	for key: String in D.BUILDINGS.keys():
		var secs := D.crew_seconds("park" if key == "park" else "build", D.build_ticks(key))
		lo = minf(lo, secs)
		hi = maxf(hi, secs)
	K.check(
		fails,
		is_equal_approx(D.crew_seconds("park", D.build_ticks("park")), D.CREW_MIN_S),
		"a park takes a crew %.0f s" % D.CREW_MIN_S
	)
	K.check(
		fails,
		is_equal_approx(D.crew_seconds("build", D.build_ticks("airport")), D.CREW_MAX_S),
		"the airport takes a crew %.0f s" % D.CREW_MAX_S
	)
	K.check(
		fails,
		lo >= 120.0 and hi <= 300.0,
		"every building takes a crew 2 to 5 minutes (%.0f-%.0f s)" % [lo, hi]
	)


func _check_order_and_queue() -> void:
	var park := _build("park")
	var pj := _job(park)
	var pi := _tile(park)
	K.check(
		fails,
		bool(park.get("ok", false)) and not pj.is_empty(),
		"a player's build order opens a crew job (%s)" % str(park.get("reason", ""))
	)
	if pj.is_empty():
		return
	K.check(
		fails,
		int(pj["crew"]) == 0 and started.size() == 1 and is_equal_approx(float(pj["total"]), 120.0),
		"crew 1 takes the park at once, 120 s of work (%s)" % str(pj)
	)
	K.check(
		fails,
		sim.kind[pi] == D.SITE and int(sim.sites[pi].get("job", 0)) == int(pj["id"]),
		"the park's lot is a crew site"
	)
	K.check(fails, sim.crew_job_at(pi) == pj, "crew_job_at finds the order from its tile")
	var police := _build("police")
	var school := _build("school")
	var cj := _job(police)
	var sj := _job(school)
	K.check(
		fails,
		int(cj.get("crew", -9)) == 1 and int(sj.get("crew", -9)) == -1 and sim.crews_free() == 0,
		"crew 2 takes the police station, the school waits for a free crew"
	)
	var when: Dictionary = sim.crew_schedule()
	var sw: Vector2 = when.get(int(sj.get("id", -1)), Vector2(-1, -1))
	K.check(
		fails,
		is_equal_approx(sw.x, 120.0) and is_equal_approx(sw.y, 120.0 + float(sj.get("total", 0.0))),
		"the school starts when the park's crew is free (%s)" % str(sw)
	)
	staged.clear()
	sim.advance_crews(60.0)
	var st: Dictionary = sim.sites.get(pi, {})
	K.check(
		fails,
		int(st.get("stage", -1)) == 1 and staged.has(pi) and sim.kind[pi] == D.SITE,
		"half way the park is at its second stage (%s)" % sim.site_stage_name(st)
	)
	K.check(
		fails,
		is_equal_approx(sim.site_fraction(st), 0.5),
		"the site shows the crew's share of the work (%.2f)" % sim.site_fraction(st)
	)
	# Every building but a park takes over 139 s, so the police station is still going at 130 s.
	sim.advance_crews(60.0 + 10.0)
	K.check(fails, sim.kind[pi] == D.PARK, "after 120 s the park is open")
	K.check(
		fails,
		finished.size() == 1 and int(finished[0]["id"]) == int(pj["id"]),
		"crew_job_finished reports the park"
	)
	K.check(
		fails,
		int(sj["crew"]) == 0 and is_equal_approx(float(sj["done"]), 10.0),
		"crew 1 moved on to the school with the rest of the time (%.1f s)" % float(sj["done"])
	)
	var ci := _tile(police)
	sim.advance_crews(float(cj["total"]) - float(cj["done"]) + 1.0)
	K.check(fails, sim.kind[ci] == D.POLICE, "the police station opens after its crew time")
	K.check(fails, sim.crews_free() == 1, "one crew is free again")
	var logged := false
	for l: String in sim.log_lines:
		logged = logged or l.contains("built by the player's crew")
	K.check(fails, logged, "the city log says the player's crew built it")
	var road := _road_order()
	var rj := _job(road)
	K.check(
		fails,
		int(rj.get("crew", -9)) == 1 and (rj.get("tiles", []) as Array).size() == 5,
		"a road order is one crew job over all its tiles (%s)" % str(rj)
	)
	sim.advance_crews(1000.0)
	K.check(fails, sim.crew_jobs.is_empty(), "every order is done after enough crew time")


func _check_ticks() -> void:
	var res := _build("park")
	var i := _tile(res)
	K.ticks(sim, D.build_ticks("park") + 2)
	K.check(
		fails,
		sim.kind[i] == D.SITE and float(sim.sites[i]["progress"]) == 0.0,
		"growth ticks and contractors leave a crew site alone"
	)
	K.check(fails, float(sim.sites[i]["rate"]) == 0.0, "the view has no tick rate to extrapolate")
	sim.advance_crews(1000.0)


func _check_save_load() -> void:
	var res := _build("hospital")
	var j := _job(res)
	sim.advance_crews(40.0)
	var saved: Variant = JSON.parse_string(JSON.stringify(sim.to_dict()))
	var s2 := K.make_sim(get_root())
	var sim2: CitySim = s2["sim"]
	K.check(fails, sim2.from_dict(saved as Dictionary), "a save with crew orders loads")
	var j2: Dictionary = sim2.crew_job_at(_tile(res))
	K.check(
		fails,
		(
			not j2.is_empty()
			and int(j2["crew"]) == int(j["crew"])
			and is_equal_approx(float(j2["done"]), 40.0)
			and is_equal_approx(float(j2["total"]), float(j["total"]))
		),
		"the order, its crew and its progress survive save/load (%s)" % str(j2)
	)
	sim2.advance_crews(float(j2.get("total", 0.0)))
	K.check(
		fails,
		sim2.kind[_tile(res)] == D.HOSPITAL and sim2.crew_jobs.is_empty(),
		"the loaded crew finishes the hospital"
	)
	sim.advance_crews(1000.0)
	for key: String in ["people", "client", "sim"]:
		(s2[key] as Node).queue_free()


func _check_cancel() -> void:
	var res := _build("school")
	var i := _tile(res)
	finished.clear()
	var bd := sim.apply_player_order(0, {"type": "bulldoze", "x": D.tx(i), "y": D.ty(i)})
	sim.advance_crews(0.0)
	K.check(
		fails,
		bool(bd.get("ok", false)) and not sim.sites.has(i) and sim.crew_jobs.is_empty(),
		"bulldozing a crew site cancels the order (%s)" % str(bd.get("reason", ""))
	)
	K.check(
		fails,
		finished.size() == 1 and bool(finished[0].get("cancelled", false)),
		"crew_job_finished reports it as cancelled"
	)
	K.check(fails, sim.crews_free() == D.CREWS, "the crew is free again")


func _check_help() -> void:
	var res := _build("fire_station")
	var j := _job(res)
	var i := _tile(res)
	sim.add_site_work(i, 4.0, "Ann Lee (builder)")
	var want := 4.0 / float(j["work"]) * float(j["total"])
	K.check(
		fails,
		is_equal_approx(float(j["done"]), want),
		"a resident's shift moves the crew order on by its share (%.2f s)" % float(j["done"])
	)
	K.check(
		fails,
		(sim.sites[i]["crew"] as Dictionary).has("Ann Lee (builder)"),
		"the helper is on the site's crew list"
	)
	sim.add_site_work(i, 100.0, "Bo Ng (builder)")
	K.check(
		fails,
		float(j["done"]) < float(j["total"]) * 0.2,
		"helpers stay capped per tick (%.1f of %.1f s)" % [float(j["done"]), float(j["total"])]
	)
	sim.advance_crews(1000.0)


func _check_frames() -> void:
	# A long day, so no growth tick (and no resident shift) runs in these frames.
	sim.set_day_seconds(1200.0)
	var res := _build("park")
	var j := _job(res)
	sim.set_speed(2)
	sim._process(1.5)
	K.check(
		fails,
		is_equal_approx(float(j["done"]), 3.0),
		"each frame moves the crews on by delta x speed (%.2f s)" % float(j["done"])
	)
	sim.set_speed(0)
	sim._process(5.0)
	K.check(fails, is_equal_approx(float(j["done"]), 3.0), "paused crews do not work")
	sim.set_speed(1)
	sim.sliced = true
	K.check(fails, sim.begin_tick(), "fixture: a sliced tick in flight")
	sim._crew_frame(2.0)
	K.check(
		fails,
		is_equal_approx(float(j["done"]), 3.0),
		"crew time waits while a sliced tick is in flight"
	)
	sim._finish_job_now()
	var before := float(j["done"])
	sim._crew_frame(0.0)
	K.check(
		fails,
		is_equal_approx(float(j["done"]), before + 2.0),
		"and is applied once the tick is done (%.2f s)" % float(j["done"])
	)
	sim.sliced = false
	sim.advance_crews(1000.0)


func _check_skip() -> void:
	# Start from dawn, so the skip covers a whole day of crew time.
	sim.skip_to_next_day()
	var res := _build("stadium")
	var i := _tile(res)
	var day := sim.day
	sim.skip_to_next_day()
	K.check(
		fails,
		sim.day == day + 1 and sim.kind[i] == D.STADIUM and sim.crew_jobs.is_empty(),
		"skipping to morning lets the crews finish the stadium"
	)
	sim.set_day_seconds(D.BASE_DAY_SECONDS)
	var res2 := _build("park")
	sim.finish_all_sites()
	K.check(
		fails,
		sim.kind[_tile(res2)] == D.PARK and sim.crew_jobs.is_empty(),
		"finish_all_sites also finishes the crews' orders"
	)


func _check_instant() -> void:
	sim.construction_mode = "instant"
	var res := _build("park")
	K.check(
		fails,
		_job(res).is_empty() and sim.kind[_tile(res)] == D.PARK,
		"with instant construction the order builds at once, no crew"
	)
	sim.construction_mode = "staged"
