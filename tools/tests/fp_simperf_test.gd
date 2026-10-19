extends SceneTree
## Slice F acceptance (docs/fp/slices/F-simperf.md): a sliced tick reproduces the synchronous one
## exactly (state, every derived map, the order of the signals other slices consume), each pump stays
## within its work-unit limit, and the sync path, skip, the day boundary and its gate, job boundaries
## (save, load, new city, mode switch), spread resident minds and the client cache flush behave.
## Headless and offline. Prints FP_SIMPERF_TEST: PASS|FAIL.

const D := preload("res://scripts/sim/sim_defs.gd")
const TICKS := 40
## sim_test.gd:9-23: the scripted actions of mayor 0, then three of mayor 4.
const ACTS := [
	[0, {"type": "build", "building": "coal_plant", "x": 9, "y": 9}],
	[0, {"type": "build", "building": "water_pump", "x": 9, "y": 7}],
	[0, {"type": "road", "x": 2, "y": 5, "x2": 9, "y2": 5}],
	[0, {"type": "zone", "zone": "R", "x": 2, "y": 6, "w": 6, "h": 3}],
	[0, {"type": "zone", "zone": "C", "x": 2, "y": 3, "w": 6, "h": 2}],
	[0, {"type": "zone", "zone": "I", "x": 11, "y": 2, "w": 1, "h": 1}],
	[0, {"type": "build", "building": "sewage_plant", "x": 9, "y": 3}],
	[0, {"type": "build", "building": "nonsense", "x": 1, "y": 1}],
	[4, {"type": "zone", "zone": "I", "x": 22, "y": 22, "w": 5, "h": 5}],
	[4, {"type": "build", "building": "coal_plant", "x": 22, "y": 20}],
	[4, {"type": "road", "x": 22, "y": 27, "x2": 26, "y2": 27}],
]

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	print(("FP_SIMPERF_TEST:   ok   " if ok else "FP_SIMPERF_TEST:   FAIL ") + what)
	if not ok:
		fails.append(what)


func _init() -> void:
	await process_frame
	var a := _world(false)
	var b := _world(true)
	_run_sync(a)
	await _run_sliced(b, TICKS)
	_compare(a, b)
	_check_budget(b)
	_check_sync_guard()
	await _check_skip(a, b)
	await _check_day_boundary()
	await _check_job_boundaries()
	await _check_minds()
	_check_flush()
	print("FP_SIMPERF_TEST: " + ("PASS" if fails.is_empty() else "FAIL " + str(fails)))
	quit(0 if fails.is_empty() else 1)


# ---------------------------------------------------------------- worlds

## A seed-7 city with the scripted mayors, Residents and offline ResidentMinds, recording the
## signals other slices consume. A brain-like day_started listener (connected before Residents, as
## CityBrain is in main) builds a road inside the emission, and a tick_done listener sets a fire on
## the 10th tick, so nested recomputes run inside the job.
func _world(sliced: bool, fire_tick: int = 10) -> Dictionary:
	var w := {"log": [], "ticks": 0}
	var sim: CitySim = (load("res://scripts/sim/city_sim.gd") as GDScript).new()
	get_root().add_child(sim)
	sim.set_process(false)
	sim.set_speed(0)
	sim.new_city(7)
	var client: GmiClient = (load("res://scripts/ai/gmi_client.gd") as GDScript).new()
	get_root().add_child(client)
	client.live_enabled = false
	var people: Residents = (load("res://scripts/sim/residents.gd") as GDScript).new()
	get_root().add_child(people)
	var minds: ResidentMinds = (load("res://scripts/ai/resident_minds.gd") as GDScript).new()
	get_root().add_child(minds)
	var log: Array = w["log"]
	sim.tiles_changed.connect(func(ix: PackedInt32Array) -> void: log.append(["tiles_changed", Array(ix)]))
	sim.day_started.connect(func(d: int) -> void: log.append(["day_started", d]))
	sim.day_ended.connect(func(d: int) -> void: log.append(["day_ended", d]))
	sim.day_started.connect(func(d: int) -> void:
		var y := 12 + d % 4
		sim.apply_action(0, {"type": "road", "x": 1, "y": y, "x2": 7, "y2": y})
	)
	people.setup(sim)
	minds.setup(sim, people, client, null)
	people.trip_started.connect(func(id: String, f: int, t: int, m: String) -> void: log.append(["trip_started", id, f, t, m]))
	people.resident_said.connect(func(id: String, text: String, k: String) -> void: log.append(["resident_said", id, text, k]))
	sim.tick_done.connect(func(_t: int) -> void:
		w["ticks"] = int(w["ticks"]) + 1
		if int(w["ticks"]) == fire_tick and not people.people.is_empty():
			var h := int(people.people[0]["home"])
			sim.trigger_disaster("fire", D.tx(h), D.ty(h), "test", "forced fire")
	)
	for act: Array in ACTS:
		sim.apply_action(int(act[0]), act[1])
	sim.sliced = sliced
	sim.start()
	w["sim"] = sim
	w["people"] = people
	w["minds"] = minds
	w["client"] = client
	return w


func _run_sync(w: Dictionary) -> void:
	var sim: CitySim = w["sim"]
	for _k in range(TICKS):
		sim.step_tick()


## Drives a sliced world the way the contract describes (begin_tick when idle, pump(4.0), count the
## commits), letting frames pass while the minds spread plan batches, then lets the last day job and
## spread finish through the same path.
func _run_sliced(w: Dictionary, ticks: int) -> void:
	var sim: CitySim = w["sim"]
	var minds: ResidentMinds = w["minds"]
	var committed := 0
	var guard := 0
	while committed < ticks and guard < 500000:
		guard += 1
		if not sim.is_tick_running():
			sim.begin_tick()
		if sim.pump(4.0):
			committed += 1
		if minds.spreading():
			await process_frame
	while (sim.job_pending() or minds.spreading()) and guard < 500000:
		guard += 1
		sim.pump(4.0)
		if minds.spreading():
			await process_frame
	check(committed == ticks and not sim.job_pending(), "the sliced world committed %d ticks (%d)" % [ticks, committed])


func _free_world(w: Dictionary) -> void:
	for key in ["sim", "people", "minds", "client"]:
		var n: Node = w[key]
		n.queue_free()


# ---------------------------------------------------------------- 1. determinism

func _compare(a: Dictionary, b: Dictionary) -> void:
	var sa: CitySim = a["sim"]
	var sb: CitySim = b["sim"]
	var pa: Residents = a["people"]
	var pb: Residents = b["people"]
	print("FP_SIMPERF_TEST: day=%d pop=%d residents=%d sites=%d events=%d log=%d/%d" % [sb.day, int(sb.stats.get("population", 0)), pb.people.size(), sb.sites.size(), sb.events.size(), (a["log"] as Array).size(), (b["log"] as Array).size()])
	check(pa.people.size() >= 5 and sa.day >= 10, "the scenario grew residents (%d) over %d days" % [pa.people.size(), sa.day])
	check(JSON.stringify(sa.to_dict()) == JSON.stringify(sb.to_dict()), "sim.to_dict() is identical")
	check(JSON.stringify(pa.to_dict()) == JSON.stringify(pb.to_dict()), "residents.to_dict() is identical")
	check(JSON.stringify((a["minds"] as ResidentMinds).to_dict()) == JSON.stringify((b["minds"] as ResidentMinds).to_dict()), "minds.to_dict() is identical")
	var diff: Array[String] = []
	for key in ["pollution", "crime", "land_value", "traffic", "happiness", "powered", "watered", "road_dist", "cov_police", "cov_fire", "cov_health", "cov_school", "cov_park", "cov_leisure", "cov_transit", "burning", "demand", "stats"]:
		if var_to_bytes(sa.get(key)) != var_to_bytes(sb.get(key)):
			diff.append(key)
	for key in ["trip_load", "mood_map"]:
		if var_to_bytes(pa.get(key)) != var_to_bytes(pb.get(key)):
			diff.append(key)
	check(diff.is_empty(), "every derived map, demand and stats are bitwise equal %s" % str(diff))
	var la: Array = a["log"]
	var lb: Array = b["log"]
	var first := -1
	for k in range(mini(la.size(), lb.size())):
		if var_to_bytes(la[k]) != var_to_bytes(lb[k]):
			first = k
			break
	if first >= 0:
		print("FP_SIMPERF_TEST: first signal mismatch at %d: sync %s / sliced %s" % [first, str(la[first]).left(160), str(lb[first]).left(160)])
	var kinds := {}
	for e: Array in la:
		kinds[e[0]] = int(kinds.get(e[0], 0)) + 1
	check(first < 0 and la.size() == lb.size(), "the tiles_changed / day / trip_started / resident_said sequence is identical (%d signals: %s)" % [la.size(), JSON.stringify(kinds)])
	check(int(kinds.get("trip_started", 0)) > 0 and int(kinds.get("resident_said", 0)) > 0, "trips and speech happened, so the order check has teeth")
	# The route cache returns exactly what a fresh search does.
	var same := true
	for r: Dictionary in pb.people.slice(0, 8):
		var o: int = pb._near_road(int(r["home"]))
		if o >= 0:
			same = same and pb._bfs(o) == pb._bfs_search(o)
	check(same, "cached road searches equal fresh ones")


func _check_budget(b: Dictionary) -> void:
	var st: Dictionary = (b["sim"] as CitySim).slice_stats()
	print("FP_SIMPERF_TEST: slice_stats %s" % JSON.stringify(st))
	check(int(st["max_units"]) <= CitySim.UNITS_PER_PUMP, "max units per pump %d <= %d (nested sync sections counted)" % [int(st["max_units"]), CitySim.UNITS_PER_PUMP])
	check(int(st["max_step_units"]) <= CitySim.STEP_MAX_UNITS, "max units per step %d <= %d" % [int(st["max_step_units"]), CitySim.STEP_MAX_UNITS])
	check(int(st["ticks"]) >= TICKS, "slice_stats counted the ticks (%d)" % int(st["ticks"]))
	# Wall clock is report-only here (the quick gate runs unlocked on a shared machine).
	print("FP_SIMPERF_TEST: report max_ms=%.2f p95_ms=%.2f avg_ms=%.2f sync_max_ms=%.2f brain_ms=%.2f view_ms=%.2f slowest=%s %.2fms" % [float(st["max_ms"]), float(st["p95_ms"]), float(st["avg_ms"]), float(st["sync_max_ms"]), float(st["brain_ms"]), float(st["view_ms"]), st["slowest_phase"], float(st["slowest_step_ms"])])


# ---------------------------------------------------------------- 3. sync path

func _check_sync_guard() -> void:
	var sim: CitySim = (load("res://scripts/sim/city_sim.gd") as GDScript).new()
	get_root().add_child(sim)
	sim.set_process(false)
	sim.new_city(7)
	sim.set_speed(16)
	var t0 := sim.global_tick()
	sim._process(30.0)
	check(not sim.sliced and sim.global_tick() - t0 == 8, "sync path: a 30 s frame at speed 16 runs exactly 8 ticks (%d)" % (sim.global_tick() - t0))
	sim.queue_free()


# ---------------------------------------------------------------- 4. skip

func _check_skip(a: Dictionary, b: Dictionary) -> void:
	var sa: CitySim = a["sim"]
	sa.step_tick()
	var d0 := sa.day
	check(sa.skip_to_next_day() and sa.day == d0 + 1 and sa.tick_in_day == 0, "sync skip_to_next_day starts day %d at dawn (day %d tick %d)" % [d0 + 1, sa.day, sa.tick_in_day])
	var sb: CitySim = b["sim"]
	sb.step_tick()
	sb.begin_tick()
	sb.pump(1.0)
	var mid := sb.is_tick_running()
	var d1 := sb.day
	var ok := sb.skip_to_next_day()
	check(mid and ok and sb.day == d1 + 1 and sb.tick_in_day == 0 and not sb.job_pending(), "sliced skip_to_next_day finishes the tick in flight, then starts day %d at dawn (day %d tick %d)" % [d1 + 1, sb.day, sb.tick_in_day])
	# The last tick of the day in flight: finishing it is the skip.
	while sb.tick_in_day != 3:
		sb.step_tick()
	(b["minds"] as ResidentMinds).finish_spread()
	sb.begin_tick()
	sb.pump(1.0)
	var d2 := sb.day
	check(sb.skip_to_next_day() and sb.day == d2 + 1 and sb.tick_in_day == 0, "sliced skip during the day's last tick lands on day %d, not %d" % [d2 + 1, d2 + 2])
	(b["minds"] as ResidentMinds).finish_spread()
	_free_world(a)
	_free_world(b)
	await process_frame


# ---------------------------------------------------------------- 5. day boundary

func _check_day_boundary() -> void:
	var w := _world(true, -1)
	var sim: CitySim = w["sim"]
	var people: Residents = w["people"]
	await _run_sliced(w, 12)
	var seen := {"started": {}, "running_in_end": false, "running_in_start": false, "ready_early": false, "ready": 0}
	sim.day_ended.connect(func(_d: int) -> void: seen["running_in_end"] = bool(seen["running_in_end"]) or sim.is_tick_running())
	sim.day_started.connect(func(d: int) -> void:
		var st: Dictionary = seen["started"]
		st[d] = int(st.get(d, 0)) + 1
		seen["running_in_start"] = bool(seen["running_in_start"]) or sim.is_tick_running()
	)
	people.day_ready.connect(func(_d: int) -> void:
		seen["ready"] = int(seen["ready"]) + 1
		seen["ready_early"] = bool(seen["ready_early"]) or people.day_job_running()
	)
	var day0 := sim.day
	await _run_sliced(w, 8)
	var started: Dictionary = seen["started"]
	check(started.size() == 2 and started.get(day0 + 1, 0) == 1 and started.get(day0 + 2, 0) == 1, "sliced: day_started fires exactly once per day (%s)" % JSON.stringify(started))
	check(not bool(seen["running_in_end"]) and not bool(seen["running_in_start"]), "is_tick_running() is false inside day_ended and day_started")
	check(int(seen["ready"]) == 2 and not bool(seen["ready_early"]), "day_ready fires once per day, after pump_day completes")
	# The day gate holds the next day until it opens.
	var gate := {"open": false}
	sim.day_gate = func() -> bool: return bool(gate["open"])
	var day1 := sim.day
	while sim.tick_in_day != 3:
		await _run_sliced(w, 1)
	sim.begin_tick()
	while sim.job_pending():
		sim.pump(4.0)
	check(sim.waiting_for_ai and sim.day == day1 + 1 and started.get(day1 + 1, 0) == 0, "a closed day gate holds day %d (waiting=%s)" % [day1 + 1, str(sim.waiting_for_ai)])
	check(not sim.begin_tick(), "no tick starts while the gate is closed")
	sim.set_speed(1)
	sim._process(0.016)
	check(sim.waiting_for_ai and not sim.job_pending(), "the closed gate keeps holding in _process")
	gate["open"] = true
	sim._process(0.016)
	while sim.job_pending():
		sim.pump(4.0)
	sim.set_speed(0)
	check(not sim.waiting_for_ai and started.get(day1 + 1, 0) == 1, "opening the gate starts day %d through the sliced day job" % (day1 + 1))
	(w["minds"] as ResidentMinds).finish_spread()
	_free_world(w)
	await process_frame


# ---------------------------------------------------------------- 6. job boundaries

func _check_job_boundaries() -> void:
	var c := _world(true, -1)
	var d := _world(false, -1)
	var sc: CitySim = c["sim"]
	var sd: CitySim = d["sim"]
	await _run_sliced(c, 9)
	for _k in range(9):
		sd.step_tick()
	sc.begin_tick()
	for _k in range(3):
		sc.pump(0.5)
	var mid := sc.is_tick_running()
	var save_c := JSON.stringify(sc.to_dict())
	sd.step_tick()
	check(mid and save_c == JSON.stringify(sd.to_dict()), "a save taken mid-job equals the save after the equivalent sync tick")
	check(JSON.stringify((c["people"] as Residents).to_dict()) == JSON.stringify((d["people"] as Residents).to_dict()), "residents after a mid-job save equal the sync tick")
	var saved: Dictionary = sd.to_dict()
	sc.begin_tick()
	sc.pump(0.5)
	var was := sc.is_tick_running()
	sc.from_dict(JSON.parse_string(JSON.stringify(saved)))
	var people: Residents = c["people"]
	check(was and not sc.is_tick_running() and not sc.job_pending() and people.get("_tk").is_empty(), "from_dict mid-job drops the job and its cursors")
	sc.begin_tick()
	sc.pump(0.5)
	sc.new_city(11)
	check(not sc.is_tick_running() and not sc.job_pending() and people.get("_tk").is_empty() and not people.day_job_running(), "new_city mid-job drops the job and its cursors")
	sc.from_dict(JSON.parse_string(JSON.stringify(saved)))
	var t0 := sc.tick_in_day
	sc.begin_tick()
	sc.pump(0.5)
	var running := sc.is_tick_running()
	sc.sliced = false
	check(running and not sc.is_tick_running() and not sc.job_pending() and sc.tick_in_day == (t0 + 1) % D.GROWTH_TICKS_PER_DAY, "sliced = false mid-job finishes the tick (tick %d -> %d)" % [t0, sc.tick_in_day])
	_free_world(c)
	_free_world(d)
	await process_frame


# ---------------------------------------------------------------- 7. minds

func _check_minds() -> void:
	var a := _world(false, -1)
	var sa: CitySim = a["sim"]
	var pa: Residents = a["people"]
	while sa.day < 6:
		sa.step_tick()
	var planned := 0
	for r in pa.people:
		if int(r.get("plan_day", 0)) == sa.day:
			planned += 1
	check(not pa.people.is_empty() and planned == pa.people.size(), "sync: plan_day sets every plan before step_tick returns (%d/%d)" % [planned, pa.people.size()])
	var b := _world(true, -1)
	var sb: CitySim = b["sim"]
	var pb: Residents = b["people"]
	var mb: ResidentMinds = b["minds"]
	while sb.day < 6:
		if not sb.job_pending():
			sb.begin_tick()
		sb.pump(4.0)
		if mb.spreading():
			await process_frame
	while sb.job_pending():
		sb.pump(4.0)
	var spreading_now := mb.spreading()
	var blocked := not sb.begin_tick()
	var frames := 0
	while mb.spreading() and frames < 100:
		await process_frame
		frames += 1
	planned = 0
	for r in pb.people:
		if int(r.get("plan_day", 0)) == sb.day:
			planned += 1
	check(spreading_now and blocked, "sliced: minds spread the day's batches and begin_tick() waits for them")
	check(not mb.spreading() and planned == pb.people.size() and frames >= 2, "the spread batches finish over %d frames and plan everyone (%d/%d)" % [frames, planned, pb.people.size()])
	check(sb.begin_tick(), "begin_tick() starts once the batches are done")
	sb.sliced = false
	_free_world(a)
	_free_world(b)
	await process_frame


# ---------------------------------------------------------------- 4b. client flush

func _check_flush() -> void:
	var client: GmiClient = (load("res://scripts/ai/gmi_client.gd") as GDScript).new()
	get_root().add_child(client)
	client.record_mode = false
	for day in range(1, 7):
		client.remember("resident|r1:Test", day, {"say": "day %d" % day})
	client.remember("brain|m0", 2, {"note": "old"})
	var path := GmiClient.SESSION_CACHE_PATH
	client.flush_cache()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	var kept: Array = (parsed as Dictionary).get("resident|r1:Test", []) if typeof(parsed) == TYPE_DICTIONARY else []
	var days: Array = kept.map(func(e: Variant) -> int: return int((e as Dictionary)["day"]))
	check(days == [4, 5, 6] and ((parsed as Dictionary).get("brain|m0", []) as Array).size() == 1, "flush_cache writes each key's last 3 days (%s)" % str(days))
	check((client.session_cache["resident|r1:Test"] as Array).size() == 6, "flush_cache never prunes session_cache itself")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	client.flush_cache()
	check(not FileAccess.file_exists(path), "flush_cache skips the write when nothing changed")
	client.remember("resident|r1:Test", 7, {"say": "day 7"})
	client.flush_cache()
	check(FileAccess.file_exists(path), "flush_cache writes again after a new entry")
	client.queue_free()
