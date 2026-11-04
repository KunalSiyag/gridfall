extends SceneTree
## Planner stalls (unit A1): on the web the orbit view keeps CitySim.sliced on (whole ticks stalled
## the page 540-670 ms three times per 12 s game day at day 10), and a morning autosave closer than
## a minute of wall clock to the last one is deferred (retried after the gap); quit and manual saves
## always go through.
## Boots the real Main headless and offline, so run it with a throwaway XDG_DATA_HOME (tools/gate.sh
## does). Prints FP_ORBIT_SLICING_TEST: PASS|FAIL.

const K := preload("res://tools/tests/fp_kit.gd")
const SK := preload("res://tools/tests/sim_save_kit.gd")
const SP := preload("res://scripts/fp/sim/sim_perf_feature.gd")
const SLOT := "user://a1_autosave_test.json"

var fails: Array[String] = []
var _now_ms := 0


func _init() -> void:
	await process_frame
	await _check_slicing()
	_check_speed_budget()
	await _check_chain()
	_check_slicing_flag()
	await _check_autosave()
	await _check_autosave_flag()
	K.finish(self, "FP_ORBIT_SLICING_TEST", fails)


func _check_slicing() -> void:
	var ctx := K.make_ctx(get_root(), {"view": true})
	var f: FpFeature = K.make_feature(ctx, "sim_perf")
	var sim := ctx.sim
	K.check(
		fails,
		sim.sliced and is_equal_approx(sim.slice_budget_ms, 4.0),
		"street: sliced on at the medium budget (%.1f ms)" % sim.slice_budget_ms
	)
	K.check(fails, not f.keeps_slicing(), "desktop: the orbit view does not keep the slices")
	f.teardown()
	K.check(fails, not sim.sliced, "desktop: leaving the street turns slicing off, as before")
	f.setup(ctx)
	K.check(fails, sim.sliced, "re-entering the street slices again")
	f.force_web = true
	K.check(fails, f.keeps_slicing(), "web: the orbit view keeps the slices")
	ctx.bus.quality_changed.emit("low")
	K.check(
		fails, is_equal_approx(sim.slice_budget_ms, 3.0), "fixture: Low's street budget is 3 ms"
	)
	f.teardown()
	K.check(
		fails,
		sim.sliced and is_equal_approx(sim.slice_budget_ms, f.ORBIT_BUDGET_MS),
		"web: teardown leaves CitySim.sliced on (%.1f ms budget)" % sim.slice_budget_ms
	)
	K.check(
		fails,
		is_equal_approx(sim.slice_budget_cap_ms, f.ORBIT_BUDGET_CAP_MS),
		"web orbit: the budget may grow with the speed up to %.0f ms" % sim.slice_budget_cap_ms
	)
	f.setup(ctx)
	K.check(
		fails,
		is_equal_approx(sim.slice_budget_cap_ms, 0.0),
		"re-entering the street takes the speed scaling off again"
	)
	f.teardown()
	# A due tick in the orbit view runs as a resumable job, not one whole step.
	sim.set_speed(0)
	sim.begin_tick()
	K.check(
		fails,
		sim.is_tick_running() or sim.job_pending(),
		"web orbit: a tick starts as a sliced job"
	)
	var guard := 0
	while sim.job_pending() and guard < 100000:
		guard += 1
		sim.pump(4.0)
	K.check(fails, not sim.job_pending(), "the job finishes under the budget pumps")


## The speed buttons scale the Planner's slice budget: 4 ms at 1x, the cap at 8x and above, rising
## in between, and no scaling without a cap (the street) or at 1x and below.
func _check_speed_budget() -> void:
	var cap := SP.ORBIT_BUDGET_CAP_MS
	var want := {0: 4.0, 1: 4.0, 2: 20.0 / 3.0, 4: 28.0 / 3.0, 8: 12.0, 16: 12.0}
	for spd: int in want:
		var got := CitySim.scaled_budget_ms(4.0, cap, spd)
		K.check(
			fails,
			absf(got - float(want[spd])) < 0.01,
			"speed %dx: budget %.2f ms (want %.2f)" % [spd, got, float(want[spd])]
		)
	K.check(fails, cap == 12.0 and SP.ORBIT_BUDGET_MS == 4.0, "the Planner's budget is 4 to 12 ms")
	K.check(fails, CitySim.scaled_budget_ms(4.0, 0.0, 8) == 4.0, "no cap: 4 ms at 8x")
	K.check(fails, CitySim.scaled_budget_ms(4.0, 3.0, 8) == 4.0, "a cap under the base is ignored")
	var rising := true
	var last := 0.0
	for spd in [1, 2, 4, 8]:
		var b := CitySim.scaled_budget_ms(4.0, cap, spd)
		rising = rising and b >= last
		last = b
	K.check(fails, rising, "the budget never falls as the speed rises")


## A fast-forward frame spends its whole budget: with the cap on, one frame at 8x finishes a tick
## that a plain 4 ms pump (which stops at UNITS_PER_PUMP units) leaves running, and the city after
## the same ticks is identical either way (pacing only, never the result).
func _check_chain() -> void:
	var plain := await _run_ticks(0.0)
	var chained := await _run_ticks(1000.0)
	K.check(fails, bool(plain["pend_after_one"]), "one 4 ms frame leaves a new city's tick running")
	K.check(
		fails,
		not bool(chained["pend_after_one"]) and int(chained["ticks_after_one"]) == 1,
		"with the cap, one frame at 8x finishes the tick (pumps %d)" % int(chained["pumps_one"])
	)
	K.check(fails, int(chained["pumps_one"]) > 1, "the frame chained several pumps")
	K.check(
		fails,
		plain["hash"] == chained["hash"] and int(plain["ticks"]) == int(chained["ticks"]),
		"chained pumps and single pumps give the same city after %d ticks" % int(plain["ticks"])
	)


func _run_ticks(cap_ms: float) -> Dictionary:
	var w := SK.make_world(get_root(), 7)
	var sim: CitySim = w["sim"]
	sim.day_gate = Callable()
	sim.slice_budget_ms = 4.0
	sim.slice_budget_cap_ms = cap_ms
	sim.sliced = true
	sim.set_speed(8)
	var start := sim.day * 4 + sim.tick_in_day
	sim._process(1.0)
	var out := {
		"pend_after_one": sim.job_pending(),
		"ticks_after_one": sim.day * 4 + sim.tick_in_day - start,
		"pumps_one": int(sim.slice_stats()["pumps"]),
	}
	var guard := 0
	while (sim.day * 4 + sim.tick_in_day - start < 3 or sim.job_pending()) and guard < 4000:
		guard += 1
		sim._process(1.0)
		await process_frame
	sim.set_speed(0)
	sim.set_tick_phase(0.0)
	out["ticks"] = sim.day * 4 + sim.tick_in_day - start
	out["hash"] = SK.state_hash(w)
	SK.free_world(w)
	return out


## Flag web_sliced_planner off: the web leaves first person as the desktop does (whole ticks).
func _check_slicing_flag() -> void:
	var ctx := K.make_ctx(get_root(), {"view": true})
	var f: FpFeature = K.make_feature(ctx, "sim_perf")
	var sim := ctx.sim
	f.force_web = true
	FeatureFlags.set_override("web_sliced_planner", false)
	K.check(fails, not f.keeps_slicing(), "flag off: the web orbit view does not keep the slices")
	# setup() zeroed the cap: raise it as the web Planner would, so teardown must reset it.
	sim.slice_budget_cap_ms = f.ORBIT_BUDGET_CAP_MS
	f.teardown()
	K.check(
		fails,
		not sim.sliced and is_equal_approx(sim.slice_budget_cap_ms, 0.0),
		"flag off: leaving the street turns slicing off on the web too"
	)
	FeatureFlags.set_override("web_sliced_planner", true)
	K.check(fails, f.keeps_slicing(), "flag on: the web orbit view keeps the slices")


func _clock() -> int:
	return _now_ms


func _boot() -> Node:
	change_scene_to_packed(load("res://scenes/main.tscn") as PackedScene)
	for _k in range(8):
		await process_frame
	return current_scene


func _check_autosave() -> void:
	OS.set_environment("GRIDFALL_VIEW", "fp")
	OS.set_environment("GRIDFALL_OFFLINE", "1")
	OS.set_environment("GRIDFALL_NEW_CITY", "1")
	var main := await _boot()
	main.sim.set_speed(0)
	while main.sim.job_pending():
		await process_frame
	main.autosave_enabled = true
	main.autosave_path = SLOT
	# The production clock (Time.get_ticks_msec, never replaced here): the gap works on it as well.
	K.check(fails, main.autosave("morning"), "default clock: the first morning autosave saves")
	K.check(
		fails,
		not main.autosave("morning") and main.autosave_wait_s() > 50.0,
		"default clock: a second one at once is skipped (wait %.1f s)" % main.autosave_wait_s()
	)
	main._last_autosave_ms = -1
	main.autosave_clock = _clock
	_now_ms = 100000
	K.check(fails, main.autosave("morning"), "the first morning autosave saves")
	_now_ms += 12000
	K.check(fails, not main.autosave("morning"), "a morning autosave 12 s later is skipped")
	_now_ms += 47000
	K.check(fails, not main.autosave("morning"), "59 s after the last one it is still skipped")
	K.check(fails, main.autosave("quit"), "a quit save 59 s after goes through")
	_now_ms += 1000
	K.check(fails, main.save_game(SLOT), "a manual save always goes through")
	_now_ms += 61000
	K.check(
		fails,
		main.autosave("morning"),
		"a morning autosave a minute after the last one saves again"
	)
	# The morning flow: a save skipped inside the gap is deferred, not dropped (a closing web tab
	# never reaches the quit autosave), and it runs on the first frame after the gap.
	main.sim.tick_in_day = 0
	main.sim.tick_done.emit(0)
	main.sim.tick_in_day = 1
	_now_ms += 5000
	K.check(fails, main.autosave_wait_s() > 50.0, "fixture: 5 s after the last save, 55 s to wait")
	await process_frame
	await process_frame
	K.check(
		fails,
		bool(main.get("_autosave_due")),
		"inside the gap the morning save stays due (deferred, not dropped)"
	)
	_now_ms += 56000
	await process_frame
	await process_frame
	K.check(fails, not bool(main.get("_autosave_due")), "after the gap the deferred save runs")
	K.check(fails, main.autosave_wait_s() > 59.0, "and starts a new gap")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SLOT))


## Flag autosave_gap off: no morning autosave is ever deferred (the behaviour before the gap).
func _check_autosave_flag() -> void:
	var main := current_scene
	main.autosave_enabled = true
	main.autosave_path = SLOT
	main._last_autosave_ms = -1
	main.autosave_clock = _clock
	_now_ms = 500000
	FeatureFlags.set_override("autosave_gap", false)
	K.check(fails, main.autosave("morning"), "flag off: the first morning autosave saves")
	_now_ms += 1000
	K.check(
		fails,
		main.autosave_wait_s() == 0.0 and main.autosave("morning"),
		"flag off: a second one 1 s later saves too"
	)
	FeatureFlags.set_override("autosave_gap", true)
	K.check(fails, not main.autosave("morning"), "flag on: the gap applies again")
	var wait: float = main.autosave_wait_s()
	K.check(fails, wait > 55.0, "flag on: and it waits (%.1f s)" % wait)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SLOT))
