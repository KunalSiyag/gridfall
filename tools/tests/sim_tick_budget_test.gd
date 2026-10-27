extends SceneTree
## The per-frame tick budget (CitySim.tick_budget_ms) and backlog clamp: when frames cannot keep
## up, the sim runs slower than the requested speed instead of piling more due ticks onto every
## frame (the browser build spiralled at speed 16). Pacing is the only thing that may change: the
## same seed stepped the same number of ticks must save byte-identical whether the budget is tight
## (one tick a frame) or loose. Drives _process directly with exact deltas, so nothing else that
## keys on wall-clock time runs between ticks. Headless, offline.
## Prints SIM_TICK_BUDGET_TEST: PASS|FAIL.

const D := preload("res://scripts/sim/sim_defs.gd")
const SK := preload("res://tools/tests/sim_save_kit.gd")
const SEED := 7
## Three whole days at 4 ticks a day.
const TICKS := 12
const SPEED := 16
## At speed 16 and the 12 s orbit day a tick is 3 game seconds; 0.5625 s of frame is 9 game
## seconds, exactly three ticks (all values exact in binary, so no rounding drift).
const FRAME_S := 0.5625

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	print(("SIM_TICK_BUDGET_TEST:   ok   " if ok else "SIM_TICK_BUDGET_TEST:   FAIL ") + what)
	if not ok:
		fails.append(what)


func _init() -> void:
	await process_frame
	var loose := _run(1.0e9, false)
	var tight := _run(0.0, false)
	check(
		int(loose["frames"]) == TICKS / 3,
		"loose budget runs three ticks a frame (%d frames)" % int(loose["frames"])
	)
	check(
		int(tight["frames"]) == TICKS,
		"tight budget runs one tick a frame (%d frames)" % int(tight["frames"])
	)
	check(
		float(tight["max_accum"]) <= float(tight["tick_len"]) + 1e-9,
		"tight budget clamps the backlog to one tick"
	)
	check(
		str(loose["save"]) == str(tight["save"]),
		"same seed and %d ticks: byte-identical saves, tight vs loose" % TICKS
	)
	check(
		float(loose["eff"]) > 0.9 * SPEED,
		"loose: effective speed tracks the requested speed (%.2f)" % float(loose["eff"])
	)
	check(
		float(tight["eff"]) < 0.5 * SPEED,
		"tight: effective speed reports the slowdown (%.2f)" % float(tight["eff"])
	)
	var sliced := _run(0.0, true)
	check(int(sliced["ticks"]) >= 1, "sliced: ticks still advance under huge frames")
	check(
		float(sliced["max_accum"]) <= 2.0 * float(sliced["tick_len"]) + 1e-9,
		(
			"sliced: the backlog stays within the job in flight plus one tick (%.1f s)"
			% float(sliced["max_accum"])
		)
	)
	await process_frame
	print("SIM_TICK_BUDGET_TEST: " + ("PASS" if fails.is_empty() else "FAIL " + str(fails)))
	quit(0 if fails.is_empty() else 1)


## A fresh seed-SEED world stepped through _process until TICKS ticks ran (or a frame cap for the
## sliced run). Returns the frames taken, the save document text, the largest pending time and the
## effective speed at the end.
func _run(budget_ms: float, sliced: bool) -> Dictionary:
	var w := SK.make_world(get_root(), SEED)
	var sim: CitySim = w["sim"]
	sim.day_gate = Callable()
	sim.tick_budget_ms = budget_ms
	sim.set_day_seconds(D.BASE_DAY_SECONDS)
	sim.sliced = sliced
	sim.set_speed(SPEED)
	var start := sim.day * D.GROWTH_TICKS_PER_DAY + sim.tick_in_day
	var frames := 0
	var max_accum := 0.0
	var delta := FRAME_S if not sliced else 120.0
	var cap := TICKS * 4 if not sliced else 200
	while sim.day * D.GROWTH_TICKS_PER_DAY + sim.tick_in_day - start < TICKS and frames < cap:
		sim._process(delta)
		frames += 1
		max_accum = maxf(max_accum, sim._time_accum)
	sim.set_speed(0)
	var out := {
		"frames": frames,
		"ticks": sim.day * D.GROWTH_TICKS_PER_DAY + sim.tick_in_day - start,
		"tick_len": sim.tick_seconds(),
		"max_accum": max_accum,
		"eff": sim.effective_speed,
		"save": "" if sliced else JSON.stringify(SK.document(w)),
	}
	sim.sliced = false
	SK.free_world(w)
	return out
