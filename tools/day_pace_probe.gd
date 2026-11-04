extends SceneTree
## Game days per 20 s of 20 fps frames at 1x, 2x, 4x and 8x on a saved city, the way the browser's
## Planner runs them (sliced sim, budget 4 ms at 1x growing to 12 ms at 8x), with the day-start
## drain scheduler (SpreadDrain) on or off. Headless and offline; the numbers are the native model
## of the Planner (docs/runbooks/web-probe-kit.md, "Day pace").
##
## usage: GRIDFALL_OFFLINE=1 godot --headless --path . -s tools/day_pace_probe.gd -- <save.json>
## <drain_ms> [frames]
##   drain_ms  0 = scheduler off (one piece a frame), 8 = on (SpreadDrain.BUDGET_MS)
##   frames    frames per speed, 400 = 20 s at 20 fps (default)
## Prints one `DAYPACE {json}` line per speed: days gained, the clock's longest stay at the day
## start (game hours it sat at 06:00, in frames), the drain's piece counts, and the frame cost.

const SK := preload("res://tools/tests/sim_save_kit.gd")
const FRAME_S := 0.05


func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		print("usage: -- <save.json> <drain_ms> [frames]")
		quit(2)
		return
	var save: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	var drain_ms := float(args[1])
	var frames := int(args[2]) if args.size() > 2 else 400
	for spd in [1, 2, 4, 8]:
		var w := SK.make_world(get_root(), 7)
		var sim: CitySim = w["sim"]
		SK.apply(w, save)
		sim.day_gate = Callable()
		sim.set_day_seconds(12.0)
		sim.slice_budget_ms = 4.0
		sim.slice_budget_cap_ms = 12.0
		sim.drain_budget_ms = drain_ms
		sim.sliced = true
		sim.set_speed(spd)
		var d0 := float(sim.day) + sim.day_progress()
		var ms: Array = []
		var parked := 0
		var longest := 0
		var day_seen := sim.day
		for i in frames:
			var t0 := Time.get_ticks_usec()
			sim._process(FRAME_S)
			ms.append(float(Time.get_ticks_usec() - t0) / 1000.0)
			# Frames in a row the clock sat at the day's first tick while pieces were still waiting.
			if sim.day != day_seen:
				day_seen = sim.day
				parked = 0
			if sim.tick_in_day == 0 and sim.spread_pending():
				parked += 1
				longest = maxi(longest, parked)
			await process_frame
		ms.sort()
		var drain := sim.drain_stats()
		print(
			"DAYPACE ",
			(
				JSON
				. stringify(
					{
						"speed": spd,
						"drain_ms": drain_ms,
						"days": snappedf(float(sim.day) + sim.day_progress() - d0, 0.01),
						"day": sim.day,
						"longest_dawn_frames": longest,
						"p50_ms": snappedf(ms[ms.size() / 2], 0.1),
						"p99_ms": snappedf(ms[int(ms.size() * 0.99)], 0.1),
						"max_ms": snappedf(ms[-1], 0.1),
						"drain_pieces": int(drain.get("pieces", 0)),
						"drain_frames": int(drain.get("frames", 0)),
						"piece_ms": snappedf(float(drain.get("ema_ms", 0.0)), 0.01),
					}
				)
			)
		)
		sim.set_speed(0)
		sim.sliced = false
		SK.free_world(w)
	quit(0)
