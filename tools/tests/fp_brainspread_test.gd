extends SceneTree
## CityBrain's day round spread over frames (docs/fp/requests/F-needs.md, "To S0 #1"): inside the
## sliced day job only the first mayor runs in the day_started emission and the other pieces follow
## one per frame through sim.run_in_phase, while the synchronous path (step_tick) still runs the
## whole round inline. Both paths end in the same city and brain state, every call of a round
## carries that round's trace id, and a save mid-round drains the round first. Staggered turns
## (street mode) land without forcing a synchronous finish. The dusk sweep (waiting staggered
## turns plus the session-cache flush) spreads the same way, on the ending day, before the next
## dawn; the sync path still runs it inside day_ended. Headless, offline.
## Prints FP_BRAINSPREAD_TEST: PASS|FAIL.

const TICKS := 20
## Frames per game day in _street_frames.
const DAY_FRAMES := 1600
const ROLES := ["mayor", "citizens", "news", "chaos", "operator", "council"]
const D := preload("res://scripts/sim/sim_defs.gd")

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
	await _check_save_mid_round(b)
	_free_world(a)
	_free_world(b)
	await process_frame
	await _check_staggered()
	await process_frame
	await _check_day_end_spread()
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
	# The dusk sweep (a lone flush piece on unstaggered days) also pends the spread; let frames
	# drain it and hold out for a mid-round pend (the day's round still short of its five mayors).
	while (
		(not brain.spread_pending() or int(w["decided"]) - int(w["base"]) == 5) and guard < 200000
	):
		guard += 1
		if brain.spread_pending():
			await process_frame
			continue
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


## Street mode (CityBrain.stagger_mayors) spreads the mayors' turns over the day. They start from
## the brain's _process, mid-tick or between ticks, so their actions must not force the tick in
## flight, or the spread work it waits for, to finish in a single frame.
func _check_staggered() -> void:
	var w := _world(true)
	var sim: CitySim = w["sim"]
	var brain: CityBrain = w["brain"]
	brain.stagger_mayors = true
	sim.slice_budget_ms = 0.0
	sim.set_speed(1)
	# Measured over the first whole staggered day, from its dawn to the next.
	var day := sim.day + 1
	var seen := {"queued": -1, "forced": 0, "ticks": []}
	sim.day_started.connect(
		func(d: int) -> void:
			var n := int(sim.slice_stats().get("sync_finishes", 0))
			if d == day:
				seen["queued"] = brain.turns.due.size()
				seen["forced"] = n
			elif d == day + 1:
				seen["forced"] = n - int(seen["forced"])
	)
	brain.mayor_decided.connect(
		func(_mi: int, e: Dictionary) -> void:
			if int(e.get("day", -1)) == day:
				(seen["ticks"] as Array).append(sim.tick_in_day)
	)
	await _street_frames(sim, func() -> bool: return brain.turns.day > day)
	var ticks: Array = seen["ticks"]
	var spread := {}
	for t: int in ticks:
		spread[t] = true
	check(
		int(seen["queued"]) == 5 and ticks.size() == 5 and spread.size() >= 3,
		"the five staggered turns land through the day (ticks %s)" % str(ticks)
	)
	check(
		int(seen["forced"]) == 0, "and never force a synchronous finish (%d)" % int(seen["forced"])
	)
	_free_world(w)


## Street-mode frames until done() holds: the sim's own sliced clock at a fixed DAY_FRAMES frames
## per day, one job step per frame (a zero budget), so a tick spans many frames and the brain's
## _process sees turns come due both mid-tick and between ticks, the same on every machine.
func _street_frames(sim: CitySim, done: Callable) -> void:
	var frame := 0
	while not bool(done.call()) and frame < 20000:
		frame += 1
		sim._process(sim.day_seconds / float(DAY_FRAMES))
		await process_frame


## The dusk sweep spreads like the dawn round (docs/fp/slices/F-simperf.md): in the sliced day job
## _on_day_ended leaves the waiting staggered turns — each bound to the ending day, which sim.day
## and turns.day leave behind before they run — and the session-cache flush on the brain's queue,
## so the boundary frame returns with the cache unwritten. The pump stops while the queue holds
## work, so the pieces land one per frame before the next day_started. The sync path (step_tick)
## still runs the whole sweep inside the emission, cache write included.
func _check_day_end_spread() -> void:
	await _dusk_sweep_sliced()
	await _dusk_sweep_sync()


## begin_tick when idle and pump(4.0) until done() holds; while work spreads the pump would
## return at once, so those frames just pass (the brain's _process pops one piece per frame).
func _pump_frames(sim: CitySim, done: Callable) -> void:
	var guard := 0
	while not bool(done.call()) and guard < 200000:
		guard += 1
		if sim.spread_pending():
			await process_frame
			continue
		if not sim.is_tick_running():
			sim.begin_tick()
		sim.pump(4.0)


func _dusk_sweep_sliced() -> void:
	var w := _world(true)
	var sim: CitySim = w["sim"]
	var client: GmiClient = w["client"]
	client.record_mode = false
	var path := GmiClient.SESSION_CACHE_PATH
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	sim.set_speed(1)
	sim.slice_budget_ms = 0.0
	var brain: CityBrain = w["brain"]
	var last := D.GROWTH_TICKS_PER_DAY - 1
	await _street_frames(
		sim,
		func() -> bool:
			return sim.day == 1 and sim.tick_in_day == last - 1 and not sim.job_pending()
	)
	# Five staggered turns for day 1, as its dawn would have queued them, this late in the day.
	# Frames after this point only pass while the sim spreads work (never idle), so the brain's
	# _process drip (MayorTurns.sim_idle) cannot fire them before the day-end sweep does.
	brain.turns.start(1, true)
	client.remember("brain|m0", 1, {"note": "dusk"})
	var calls0: int = (w["calls"] as Array).size()
	var forced0 := int(sim.slice_stats().get("sync_finishes", 0))
	var dusk := {"end": -1, "deferred": false, "pending": false, "due": -1, "file": true}
	var dawn := {"at": -1, "file": false}
	sim.day_ended.connect(
		func(d: int) -> void:
			dusk["end"] = d
			dusk["deferred"] = sim.day_end_deferred()
			dusk["pending"] = brain.spread_pending()
			dusk["due"] = brain.turns.due.size()
			dusk["file"] = FileAccess.file_exists(path)
	)
	sim.day_started.connect(
		func(d: int) -> void:
			if d == 2:
				dawn["at"] = (w["calls"] as Array).size()
				dawn["file"] = FileAccess.file_exists(path)
	)
	await _pump_frames(sim, func() -> bool: return int(dusk["end"]) >= 1)
	await _pump_frames(sim, func() -> bool: return int(dawn["at"]) >= 0)
	var held := (w["calls"] as Array).slice(calls0, int(dawn["at"]))
	var mayors := held.filter(
		func(c: Array) -> bool: return str(c[1]) == "mayor" and int(c[0]) == 1
	)
	var swept := (
		int(dusk["end"]) == 1
		and bool(dusk["deferred"])
		and bool(dusk["pending"])
		and int(dusk["due"]) == 0
		and not bool(dusk["file"])
	)
	check(
		swept, "sliced: day_ended queues the dusk sweep (turns + flush), the cache still unwritten"
	)
	check(
		mayors.size() == 5, "sliced: the swept turns still ran on the ending day (%s)" % str(mayors)
	)
	check(bool(dawn["file"]), "sliced: the flush landed before the next dawn")
	check(
		int(sim.slice_stats().get("sync_finishes", 0)) == forced0,
		"sliced: the dusk pieces never forced a synchronous finish"
	)
	await _pump_frames(
		sim, func() -> bool: return not sim.job_pending() and not sim.spread_pending()
	)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_free_world(w)
	await process_frame


## The sync path: the same sweep runs inside the emission, the flush write included. The
## world's first dawn ran before stagger could be set, so the staggered round is day 2's.
func _dusk_sweep_sync() -> void:
	var s := _world(false)
	var sbrain: CityBrain = s["brain"]
	sbrain.stagger_mayors = true
	var ssim: CitySim = s["sim"]
	var sclient: GmiClient = s["client"]
	sclient.record_mode = false
	var path := GmiClient.SESSION_CACHE_PATH
	while ssim.day < 2:
		ssim.step_tick()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	sclient.remember("brain|m0", 2, {"note": "dusk"})
	var scalls0: int = (s["calls"] as Array).size()
	var obs := {"end": -1, "deferred": true, "pending": true, "due": -1, "file": false}
	ssim.day_ended.connect(
		func(d: int) -> void:
			obs["end"] = d
			obs["deferred"] = ssim.day_end_deferred()
			obs["pending"] = sbrain.spread_pending()
			obs["due"] = sbrain.turns.due.size()
			obs["file"] = FileAccess.file_exists(path)
	)
	while ssim.day < 3:
		ssim.step_tick()
	var smayors := (s["calls"] as Array).slice(scalls0).filter(
		func(c: Array) -> bool: return str(c[1]) == "mayor" and int(c[0]) == 2
	)
	var inline := (
		int(obs["end"]) == 2
		and not bool(obs["deferred"])
		and not bool(obs["pending"])
		and int(obs["due"]) == 0
		and bool(obs["file"])
	)
	check(inline, "sync: the dusk sweep runs inside day_ended, cache write included")
	check(smayors.size() == 5, "sync: the swept turns ran on the ending day (%s)" % str(smayors))
	check(Trace.current().is_empty(), "no trace is left current after the dusk sweeps")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_free_world(s)
	await process_frame


func _node(path: String) -> Node:
	var n: Node = (load(path) as GDScript).new()
	get_root().add_child(n)
	return n


func _free_world(w: Dictionary) -> void:
	for key in ["brain", "sim", "people", "minds", "client"]:
		(w[key] as Node).queue_free()
