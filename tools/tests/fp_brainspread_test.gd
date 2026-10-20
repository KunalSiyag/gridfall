extends SceneTree
## CityBrain's day round spread over frames (docs/fp/requests/F-needs.md, "To S0 #1"): inside the
## sliced day job only the first mayor runs in the day_started emission and the other pieces follow
## one per frame through sim.run_in_phase, while the synchronous path (step_tick) still runs the
## whole round inline. Both paths end in the same city and brain state, every call of a round
## carries that round's trace id, and a save mid-round drains the round first. Headless, offline.
## Prints FP_BRAINSPREAD_TEST: PASS|FAIL.

const TICKS := 20
const ROLES := ["mayor", "citizens", "news", "chaos", "operator", "council"]

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	print(("FP_BRAINSPREAD_TEST:   ok   " if ok else "FP_BRAINSPREAD_TEST:   FAIL ") + what)
	if not ok:
		fails.append(what)


func _init() -> void:
	await process_frame
	var a := _world(false)
	var b := _world(true)
	var sa: CitySim = a["sim"]
	for _k in range(TICKS):
		sa.step_tick()
	await _run_sliced(b, TICKS)
	_check_inline(a, b)
	_check_same(a, b)
	_check_traces(a, "sync")
	_check_traces(b, "sliced")
	check(Trace.current().is_empty(), "no trace is left current after the rounds")
	_check_save_mid_round(b)
	_free_world(a)
	_free_world(b)
	await process_frame
	print("FP_BRAINSPREAD_TEST: " + ("PASS" if fails.is_empty() else "FAIL " + str(fails)))
	quit(0 if fails.is_empty() else 1)


## A seed-7 city with offline Residents, ResidentMinds and a real CityBrain. Listeners around the
## brain's own day_started handler count the mayors that decided inside the emission.
func _world(sliced: bool) -> Dictionary:
	var w := {"decided": 0, "base": 0, "inline": [], "calls": [], "spread_frames": 0}
	var sim: CitySim = _node("res://scripts/sim/city_sim.gd")
	var client: GmiClient = _node("res://scripts/ai/gmi_client.gd")
	client.live_enabled = false
	sim.set_process(false)
	sim.set_speed(0)
	sim.new_city(7)
	client.call_logged.connect(
		func(rec: Dictionary) -> void:
			if str(rec.get("role", "")) in ROLES:
				(w["calls"] as Array).append(
					[
						int(rec.get("day", -1)),
						str(rec.get("role", "")),
						str(rec.get("trace_id", ""))
					]
				)
	)
	var people: Residents = _node("res://scripts/sim/residents.gd")
	var minds: ResidentMinds = _node("res://scripts/ai/resident_minds.gd")
	sim.day_started.connect(func(_d: int) -> void: w["base"] = w["decided"])
	var brain: CityBrain = _node("res://scripts/ai/city_brain.gd")
	brain.setup(sim, client)
	brain.mayor_decided.connect(
		func(_mi: int, _e: Dictionary) -> void: w["decided"] = int(w["decided"]) + 1
	)
	sim.day_started.connect(
		func(_d: int) -> void: (w["inline"] as Array).append(int(w["decided"]) - int(w["base"]))
	)
	people.setup(sim)
	minds.setup(sim, people, client, null)
	sim.sliced = sliced
	sim.start()
	w["sim"] = sim
	w["people"] = people
	w["minds"] = minds
	w["client"] = client
	w["brain"] = brain
	return w


## begin_tick when idle and pump(4.0), letting a frame pass while anything spreads (the brain's
## pieces run in its _process, one per frame).
func _run_sliced(w: Dictionary, ticks: int) -> void:
	var sim: CitySim = w["sim"]
	var brain: CityBrain = w["brain"]
	var committed := 0
	var guard := 0
	while (committed < ticks or sim.job_pending() or sim.spread_pending()) and guard < 500000:
		guard += 1
		if committed < ticks and not sim.is_tick_running():
			sim.begin_tick()
		if sim.pump(4.0):
			committed += 1
		if sim.spread_pending():
			if brain.spread_pending():
				w["spread_frames"] = int(w["spread_frames"]) + 1
			await process_frame
	check(
		committed == ticks and not sim.job_pending(),
		"the sliced world committed %d ticks (%d)" % [ticks, committed]
	)


func _check_inline(a: Dictionary, b: Dictionary) -> void:
	var ia: Array = a["inline"]
	var ib: Array = b["inline"]
	check(
		ia.size() >= 4 and ia.size() == ib.size(),
		"fixture: %d day starts on both paths (%d)" % [ia.size(), ib.size()]
	)
	check(
		ia.all(func(n: int) -> bool: return n == 5),
		"sync: all five mayors decide inside day_started %s" % str(ia)
	)
	# sim.start() begins day 0 synchronously; the later days come from the sliced day job.
	var later := ib.slice(1)
	check(
		not ib.is_empty() and ib[0] == 5 and later.all(func(n: int) -> bool: return n == 1),
		"sliced: day 0 (start) inline, then one mayor inside each day_started %s" % str(ib)
	)
	# Nine more pieces per round (four mayors, five support roles), each on its own frame.
	var frames := int(b["spread_frames"])
	check(
		frames >= 9 * later.size(),
		"sliced: the rounds ran over %d frames (>= %d)" % [frames, 9 * later.size()]
	)
	check(
		int(a["spread_frames"]) == 0 and not (a["brain"] as CityBrain).spread_pending(),
		"sync: nothing waits for a frame"
	)


func _check_same(a: Dictionary, b: Dictionary) -> void:
	var sa: CitySim = a["sim"]
	var sb: CitySim = b["sim"]
	check(
		JSON.stringify(sa.to_dict()) == JSON.stringify(sb.to_dict()),
		"sim.to_dict() is identical on both paths"
	)
	var ba: Dictionary = (a["brain"] as CityBrain).to_dict()
	var bb: Dictionary = (b["brain"] as CityBrain).to_dict()
	var diff: Array[String] = []
	for key: String in [
		"mayor_state",
		"proposals",
		"last_paper",
		"last_chaos",
		"last_operator",
		"last_council",
		"chaos_last_day",
		"complaints"
	]:
		if JSON.stringify(ba.get(key)) != JSON.stringify(bb.get(key)):
			diff.append(key)
	check(diff.is_empty(), "brain state is identical on both paths %s" % str(diff))
	var ra := (a["calls"] as Array).map(func(c: Array) -> String: return "%d:%s" % [c[0], c[1]])
	var rb := (b["calls"] as Array).map(func(c: Array) -> String: return "%d:%s" % [c[0], c[1]])
	check(ra == rb and ra.size() >= 25, "the same calls in the same order (%d)" % ra.size())


## Every call of a round carries that round's trace id; rounds differ.
func _check_traces(w: Dictionary, what: String) -> void:
	var by_day := {}
	var bad: Array[String] = []
	for c: Array in w["calls"]:
		var id := str(c[2])
		if not Trace.is_id(id):
			bad.append("%d:%s none" % [c[0], c[1]])
			continue
		if by_day.has(c[0]) and by_day[c[0]] != id:
			bad.append("%d:%s other" % [c[0], c[1]])
		by_day[c[0]] = id
	var ids := {}
	for id: String in by_day.values():
		ids[id] = true
	check(
		bad.is_empty() and by_day.size() >= 4 and ids.size() == by_day.size(),
		"%s: one trace id per day round, on all its calls %s" % [what, str(bad.slice(0, 4))]
	)


## A save (sim.to_dict, as Main.save_game does first) mid-round runs the rest of the round and the
## day job; from_dict drops a round in progress.
func _check_save_mid_round(w: Dictionary) -> void:
	var sim: CitySim = w["sim"]
	var brain: CityBrain = w["brain"]
	var guard := 0
	while not brain.spread_pending() and guard < 200000:
		guard += 1
		if not sim.is_tick_running():
			sim.begin_tick()
		sim.pump(4.0)
	var held := brain.spread_pending() and sim.spread_pending() and sim.job_pending()
	var decided := int(w["decided"])
	sim.to_dict()
	check(
		(
			held
			and not brain.spread_pending()
			and not sim.job_pending()
			and int(w["decided"]) == decided + 4
		),
		"a save mid-round runs the other four mayors and the day job first"
	)
	guard = 0
	while not brain.spread_pending() and guard < 200000:
		guard += 1
		if not sim.is_tick_running():
			sim.begin_tick()
		sim.pump(4.0)
	var saved := brain.to_dict()
	brain.from_dict(saved)
	check(not brain.spread_pending(), "from_dict drops a round in progress")
	sim.to_dict()


func _node(path: String) -> Node:
	var n: Node = (load(path) as GDScript).new()
	get_root().add_child(n)
	return n


func _free_world(w: Dictionary) -> void:
	for key in ["brain", "sim", "people", "minds", "client"]:
		(w[key] as Node).queue_free()
