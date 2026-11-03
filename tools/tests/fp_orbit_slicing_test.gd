extends SceneTree
## Planner stalls (unit A1): on the web the orbit view keeps CitySim.sliced on (whole ticks stalled
## the page 540-670 ms three times per 12 s game day at day 10), and a morning autosave closer than
## a minute of wall clock to the last one is deferred (retried after the gap); quit and manual saves
## always go through.
## Boots the real Main headless and offline, so run it with a throwaway XDG_DATA_HOME (tools/gate.sh
## does). Prints FP_ORBIT_SLICING_TEST: PASS|FAIL.

const K := preload("res://tools/tests/fp_kit.gd")
const SLOT := "user://a1_autosave_test.json"

var fails: Array[String] = []
var _now_ms := 0


func _init() -> void:
	await process_frame
	await _check_slicing()
	await _check_autosave()
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
