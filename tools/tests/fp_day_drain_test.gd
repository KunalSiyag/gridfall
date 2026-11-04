extends SceneTree
## Day-start drain scheduler (SpreadDrain, flag day_drain_fast): at 4x and 8x the sliced sim runs
## several of the day's spread pieces (the brain's day round, the residents' plan batches) in one
## frame instead of one a frame. Pacing only: the same pieces in the same order, so the city after
## the same days is identical with the scheduler on and off; and 1x and 2x keep one piece a frame.
## Boots nothing but sim nodes, headless and offline. Prints FP_DAY_DRAIN_TEST: PASS|FAIL.

const K := preload("res://tools/tests/fp_kit.gd")
const SK := preload("res://tools/tests/sim_save_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const SP := preload("res://scripts/fp/sim/sim_perf_feature.gd")
const GATED := preload("res://tools/tests/support/gated_client.gd")

var fails: Array[String] = []


func _init() -> void:
	await process_frame
	K.watchdog(self, "FP_DAY_DRAIN_TEST", 240.0)
	_check_scheduler()
	_check_speed_gate()
	await _check_same_city()
	await _check_same_city_gated()
	await _check_hooks()
	await _check_pump_share()
	_check_flag()
	K.finish(self, "FP_DAY_DRAIN_TEST", fails)


## A source of n numbered pieces that logs which piece ran, in what order.
class Fake:
	extends RefCounted
	var name: String
	var items: Array[int] = []
	var log: Array
	var cost_ms: float = 0.0

	func _init(p_name: String, n: int, p_log: Array) -> void:
		name = p_name
		log = p_log
		for i in n:
			items.append(i)

	func gate() -> bool:
		return not items.is_empty()

	func step() -> void:
		log.append("%s%d" % [name, items.pop_front()])
		if cost_ms > 0.0:
			OS.delay_usec(int(cost_ms * 1000.0))


func _sources(a: Fake, b: Fake) -> Array:
	return [[a.gate, a.step], [b.gate, b.step]]


func _check_scheduler() -> void:
	var log := []
	var m := Fake.new("m", 5, log)
	var b := Fake.new("b", 3, log)
	var stats := {}
	var n := SpreadDrain.run(_sources(m, b), 100.0, stats)
	K.check(fails, n == 8 and not m.gate.call() and not b.gate.call(), "all 8 pieces ran (%d)" % n)
	K.check(
		fails,
		log == ["m0", "b0", "m1", "b1", "m2", "b2", "m3", "m4"],
		"the sources alternate in frame order, each in its own order: %s" % str(log)
	)
	K.check(
		fails,
		int(stats.get("pieces", 0)) == 8 and int(stats.get("frames", 0)) == 1,
		"stats count the pieces and the frame"
	)
	# The cap: never more than MAX_PIECES in one frame.
	log = []
	var big := Fake.new("m", 100, log)
	K.check(
		fails,
		SpreadDrain.run(_sources(big, Fake.new("b", 100, log)), 1000.0) == SpreadDrain.MAX_PIECES,
		"at most MAX_PIECES (%d) in a frame" % SpreadDrain.MAX_PIECES
	)
	# No budget: nothing runs.
	K.check(
		fails,
		SpreadDrain.run(_sources(Fake.new("m", 3, []), Fake.new("b", 3, [])), 0.0) == 0,
		"a zero budget runs nothing"
	)
	K.check(fails, SpreadDrain.run([], 5.0) == 0, "no sources: nothing runs")
	# The budget: pieces that cost about 2 ms stop a 5 ms frame after a few, not all of them.
	log = []
	var slow_m := Fake.new("m", 20, log)
	var slow_b := Fake.new("b", 20, log)
	slow_m.cost_ms = 2.0
	slow_b.cost_ms = 2.0
	var t0 := Time.get_ticks_usec()
	var ran := SpreadDrain.run(_sources(slow_m, slow_b), 5.0, {})
	var took := float(Time.get_ticks_usec() - t0) / 1000.0
	K.check(
		fails,
		ran >= 1 and ran <= 4 and took < 9.0,
		"2 ms pieces in a 5 ms budget: %d ran in %.1f ms" % [ran, took]
	)
	# A piece as heavy as the frame budget (a browser's 8 ms): measured once, then the frame's own
	# per-frame piece is all it holds and the drain adds none.
	var heavy := Fake.new("h", 30, [])
	heavy.cost_ms = 8.0
	var hstats := {}
	var first := SpreadDrain.run([[heavy.gate, heavy.step]], SpreadDrain.BUDGET_MS, hstats)
	var second := SpreadDrain.run([[heavy.gate, heavy.step]], SpreadDrain.BUDGET_MS, hstats)
	K.check(
		fails,
		first == 1 and second == 0,
		"8 ms pieces: measured once, then none added (%d, %d)" % [first, second]
	)
	# The per-frame paths run one piece for each waiting source: pieces of 6 ms from two sources
	# already fill a frame (12 ms against an 8 ms budget), so the drain must add NOTHING to it.
	# (It used to run one extra piece every frame: p95 of the frame 9.8 -> 17.5 ms.)
	var m6 := Fake.new("m", 60, [])
	var b6 := Fake.new("b", 60, [])
	m6.cost_ms = 6.0
	b6.cost_ms = 6.0
	var s6 := {}
	var measure := SpreadDrain.run(_sources(m6, b6), SpreadDrain.BUDGET_MS, s6)
	var extra := 0
	for _k in 10:
		extra += SpreadDrain.run(_sources(m6, b6), SpreadDrain.BUDGET_MS, s6)
	K.check(
		fails,
		measure <= 1 and extra == 0,
		(
			"two sources of 6 ms pieces fill the frame: no extra piece (%d, then %d in 10 frames)"
			% [measure, extra]
		)
	)
	# Cheap pieces (1 ms, two sources: 2 ms forced) leave room: the drain adds some, but the frame's
	# whole piece work, forced pieces included, stays inside the budget.
	var m1 := Fake.new("m", 200, [])
	var b1 := Fake.new("b", 200, [])
	m1.cost_ms = 1.0
	b1.cost_ms = 1.0
	var s1 := {}
	SpreadDrain.run(_sources(m1, b1), SpreadDrain.BUDGET_MS, s1)
	var worst := 0
	for _k in 5:
		var n1 := SpreadDrain.run(_sources(m1, b1), SpreadDrain.BUDGET_MS, s1)
		worst = maxi(worst, n1)
		K.check(
			fails,
			float(n1 + 2) * 1.0 <= SpreadDrain.BUDGET_MS + 1.5,
			"1 ms pieces: extra %d + 2 forced fit the %.0f ms budget" % [n1, SpreadDrain.BUDGET_MS]
		)
	K.check(fails, worst >= 2, "1 ms pieces leave room for extras (%d)" % worst)
	# A very heavy one is skipped for many frames while its estimate falls slowly, then tried again.
	var huge := Fake.new("x", 30, [])
	huge.cost_ms = 40.0
	var xstats := {}
	var ran_x := SpreadDrain.run([[huge.gate, huge.step]], SpreadDrain.BUDGET_MS, xstats)
	var skipped := 0
	while (
		SpreadDrain.run([[huge.gate, huge.step]], SpreadDrain.BUDGET_MS, xstats) == 0
		and skipped < 400
	):
		skipped += 1
	K.check(
		fails,
		ran_x == 1 and skipped >= 20 and skipped < 400,
		"40 ms pieces are skipped for %d frames, then retried" % skipped
	)
	# A source that adds a piece while it runs is drained in the same pass.
	log = []
	var grow := Fake.new("g", 1, log)
	var again := Callable(self, "_grow_once").bind(grow)
	var stats2 := {}
	var pass_n := SpreadDrain.run([[grow.gate, again]], 100.0, stats2)
	K.check(fails, pass_n == 2 and grow.items.is_empty(), "a piece that queues another: both ran")


var _grown := false


func _grow_once(g: Fake) -> void:
	g.step()
	if not _grown:
		_grown = true
		g.items.append(7)


func _check_speed_gate() -> void:
	K.check(fails, not SpreadDrain.active_at(1, 5.0), "1x: no drain")
	K.check(fails, not SpreadDrain.active_at(2, 5.0), "2x: no drain")
	K.check(fails, SpreadDrain.active_at(4, 5.0), "4x: drain")
	K.check(fails, SpreadDrain.active_at(8, 5.0), "8x: drain")
	K.check(fails, SpreadDrain.active_at(16, 5.0), "16x: drain")
	K.check(fails, not SpreadDrain.active_at(8, 0.0), "budget 0: off at every speed")


## The sim's frame loop on a grown seed-7 city for DAYS days: returns frames it took, how long the
## clock sat at dawn waiting for the pieces, and the state hash after the same game ticks.
func _run(doc: Dictionary, spd: int, drain_ms: float) -> Dictionary:
	var w := SK.load_into_new(get_root(), doc)
	var sim: CitySim = w["sim"]
	sim.day_gate = Callable()
	sim.slice_budget_ms = 4.0
	sim.slice_budget_cap_ms = 12.0
	sim.drain_budget_ms = drain_ms
	sim.sliced = true
	sim.set_speed(spd)
	# Two whole days and two ticks into the third, so the dawn round of both days has run; the speed
	# drops to 0 the moment the tick commits, so neither run starts another.
	var target := (sim.day + 2) * D.GROWTH_TICKS_PER_DAY + 2
	var frames := 0
	var parked := 0
	while (
		frames < 6000 and (sim.global_tick() < target or sim.job_pending() or sim.spread_pending())
	):
		sim._process(0.5)
		frames += 1
		if sim.tick_in_day == 0 and sim.spread_pending():
			parked += 1
		if sim.global_tick() >= target:
			sim.set_speed(0)
		await process_frame
	sim.set_speed(0)
	var out := {
		"frames": frames,
		"parked": parked,
		"day": sim.day,
		"tick": sim.tick_in_day,
		"pieces": int(sim.drain_stats().get("pieces", 0)),
		"pending": sim.spread_pending() or sim.job_pending(),
		"people": (w["people"] as Residents).people.size(),
	}
	sim.set_tick_phase(0.0)
	out["hash"] = SK.state_hash(w)
	SK.free_world(w)
	return out


func _grown_doc() -> Dictionary:
	var w := SK.make_world(get_root(), 7)
	var sim: CitySim = w["sim"]
	sim.day_gate = Callable()
	K.grow(sim, w["people"], 60)
	var doc := SK.document(w)
	SK.free_world(w)
	return doc


func _check_same_city() -> void:
	var doc := _grown_doc()
	for spd in [4, 8]:
		var off := await _run(doc, spd, 0.0)
		var on := await _run(doc, spd, SpreadDrain.BUDGET_MS)
		K.check(
			fails,
			not bool(off["pending"]) and not bool(on["pending"]),
			"%dx: both runs finish their day (%s / %s)" % [spd, str(off), str(on)]
		)
		K.check(
			fails,
			off["day"] == on["day"] and off["tick"] == on["tick"],
			"%dx: the same game time (day %d tick %d)" % [spd, int(on["day"]), int(on["tick"])]
		)
		K.check(
			fails,
			off["hash"] == on["hash"],
			(
				"%dx: the same city with the drain on and off (%d people, %d pieces drained)"
				% [spd, int(on["people"]), int(on["pieces"])]
			)
		)
		K.check(
			fails,
			int(off["pieces"]) == 0 and int(on["pieces"]) > 0,
			"%dx: the drain ran pieces only when on (%d)" % [spd, int(on["pieces"])]
		)
		K.check(
			fails,
			int(on["parked"]) < int(off["parked"]),
			(
				"%dx: the clock waits fewer frames at dawn (%d against %d)"
				% [spd, int(on["parked"]), int(off["parked"])]
			)
		)
	for spd in [1, 2]:
		var low := await _run(doc, spd, SpreadDrain.BUDGET_MS)
		K.check(
			fails,
			int(low["pieces"]) == 0,
			"%dx: the scheduler stays out of the way (%d pieces)" % [spd, int(low["pieces"])]
		)


## The same city with the drain on and off when the mayors' calls are held by hand and released at
## the dusk wait (the day gate, wait_for_ai) in the order they were sent or the reverse: a parked
## live call must not make the drained day differ.
func _run_gated(doc: Dictionary, spd: int, drain_ms: float, reverse: bool) -> Dictionary:
	var w := SK.make_world(get_root(), int((doc.get("sim", {}) as Dictionary).get("seed", 7)))
	var gated: GATED = GATED.new()
	gated.name = "GatedClient"
	get_root().add_child(gated)
	gated.live_enabled = false
	gated.each = true
	(w["client"] as Node).queue_free()
	w["client"] = gated
	(w["brain"] as CityBrain).setup(w["sim"], gated)
	(w["minds"] as ResidentMinds).setup(w["sim"], w["people"], gated, w["brain"])
	SK.apply(w, doc)
	var sim: CitySim = w["sim"]
	sim.slice_budget_ms = 4.0
	sim.slice_budget_cap_ms = 12.0
	sim.drain_budget_ms = drain_ms
	sim.sliced = true
	sim.set_speed(spd)
	var target := (sim.day + 2) * D.GROWTH_TICKS_PER_DAY + 2
	var frames := 0
	var released := 0
	var waits := 0
	while (
		frames < 30000 and (sim.global_tick() < target or sim.job_pending() or sim.spread_pending())
	):
		sim._process(0.5)
		frames += 1
		if sim.waiting_for_ai and not sim.spread_pending():
			waits += 1
			var n := gated.parked.size() - released
			if n > 0:
				var base := released
				for k in n:
					gated.release(base + (n - 1 - k if reverse else k))
				released = base + n
		if sim.global_tick() >= target:
			sim.set_speed(0)
		await process_frame
	sim.set_speed(0)
	var out := {"day": sim.day, "waits": waits, "sent": gated.sent.size()}
	sim.set_tick_phase(0.0)
	out["hash"] = SK.state_hash(w)
	out["pieces"] = int(sim.drain_stats().get("pieces", 0))
	SK.free_world(w)
	return out


func _check_same_city_gated() -> void:
	var doc := _grown_doc()
	for spd in [4, 8]:
		for reverse in [false, true]:
			var off := await _run_gated(doc, spd, 0.0, reverse)
			var on := await _run_gated(doc, spd, SpreadDrain.BUDGET_MS, reverse)
			var tag := "%dx gated %s" % [spd, "reversed" if reverse else "in order"]
			K.check(
				fails,
				int(on["waits"]) > 0 and int(off["waits"]) > 0,
				(
					"%s: the dusk wait was reached (%d, %d frames)"
					% [tag, int(off["waits"]), int(on["waits"])]
				)
			)
			K.check(
				fails,
				off["hash"] == on["hash"] and off["day"] == on["day"] and off["sent"] == on["sent"],
				"%s: the same city and the same calls with the drain on and off" % tag
			)
			K.check(
				fails, int(on["pieces"]) > 0, "%s: the drain ran (%d)" % [tag, int(on["pieces"])]
			)


## Both spread sources are wired to the drain: the residents' (CitySim.spread_step) and the brain's
## (add_spread_source's third argument). A dropped registration leaves a source on its one piece a
## frame, which neither the scheduler test nor the hash test would notice.
func _check_hooks() -> void:
	var w := SK.make_world(get_root(), 7)
	var sim: CitySim = w["sim"]
	var minds: ResidentMinds = w["minds"]
	var brain: CityBrain = w["brain"]
	var srcs := sim._drain_sources()
	K.check(fails, srcs.size() == 2, "two sources are drainable: %d" % srcs.size())
	if srcs.size() == 2:
		K.check(
			fails,
			(
				(srcs[0][1] as Callable).get_object() == minds
				and (srcs[0][0] as Callable).get_object() == minds
			),
			"the residents' plan batches are the first source (minds.drain_step)"
		)
		K.check(
			fails,
			(
				(srcs[1][1] as Callable).get_object() == brain
				and (srcs[1][0] as Callable).get_object() == brain
			),
			"the brain's day round is the second (brain.drain_step)"
		)
		# And driving them drains the real queues, in each queue's own order.
		var order: Array[String] = []
		for i in 3:
			minds._spread.append(func() -> void: order.append("m%d" % i))
			brain._queue.append(func() -> void: order.append("b%d" % i))
		var n := SpreadDrain.run(srcs, 1000.0, {})
		K.check(
			fails,
			n == 6 and order == ["m0", "b0", "m1", "b1", "m2", "b2"],
			"the drain runs both queues in order (%d pieces: %s)" % [n, str(order)]
		)
	SK.free_world(w)


## What the drain spends comes out of the pump's share of the frame, so a frame costs the budget
## and not the budget and the drain (sim.last_pump_budget_ms).
func _check_pump_share() -> void:
	var w := SK.make_world(get_root(), 7)
	var sim: CitySim = w["sim"]
	sim.day_gate = Callable()
	sim.set_day_seconds(12.0)
	sim.slice_budget_ms = 4.0
	sim.slice_budget_cap_ms = 12.0
	sim.sliced = true
	sim.set_speed(4)
	var frames := 0
	while not sim.job_pending() and frames < 200:
		sim._process(0.5)
		frames += 1
	K.check(fails, sim.job_pending(), "a tick is in flight after %d frames" % frames)
	var full := CitySim.scaled_budget_ms(4.0, 12.0, 4)
	# No drain: the pump keeps the whole budget.
	sim.drain_budget_ms = 0.0
	sim._process(0.0)
	K.check(
		fails,
		is_equal_approx(sim.last_pump_budget_ms, full),
		"no drain: the pump gets the whole %.1f ms (%.1f)" % [full, sim.last_pump_budget_ms]
	)
	# A drain that spends about 6 ms leaves the pump the rest.
	var log: Array[int] = []
	var cost := Callable(self, "_spend").bind(log, 3.0)
	var gate := Callable(self, "_has_pieces").bind(log, 20)
	sim.add_spread_source(gate, Callable(self, "_noop"), cost)
	sim.drain_budget_ms = SpreadDrain.BUDGET_MS
	sim._process(0.0)
	var share := sim.last_pump_budget_ms
	K.check(
		fails,
		log.size() >= 2 and share <= full - 5.5,
		"the drain ran %d pieces and the pump got %.1f of the %.1f ms" % [log.size(), share, full]
	)
	sim.remove_spread_source(gate)
	sim.set_speed(0)
	SK.free_world(w)


func _noop() -> void:
	pass


func _spend(log: Array[int], ms: float) -> void:
	log.append(1)
	OS.delay_usec(int(ms * 1000.0))


func _has_pieces(log: Array[int], total: int) -> bool:
	return log.size() < total


## Flag day_drain_fast off: the street and the Planner get a zero drain budget.
func _check_flag() -> void:
	var ctx := K.make_ctx(get_root(), {"view": true})
	var f: FpFeature = K.make_feature(ctx, "sim_perf")
	K.check(
		fails,
		is_equal_approx(ctx.sim.drain_budget_ms, SpreadDrain.BUDGET_MS),
		"flag on: the sim's drain budget is %.1f ms" % ctx.sim.drain_budget_ms
	)
	f.teardown()
	FeatureFlags.set_override(SpreadDrain.FLAG, false)
	K.check(fails, is_equal_approx((f as SP).drain_budget(), 0.0), "flag off: drain budget 0")
	f.setup(ctx)
	K.check(fails, is_equal_approx(ctx.sim.drain_budget_ms, 0.0), "flag off: the sim gets no drain")
	f.teardown()
	FeatureFlags.set_override(SpreadDrain.FLAG, true)
