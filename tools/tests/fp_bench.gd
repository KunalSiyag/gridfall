extends SceneTree
## First-person performance report (docs/fp/S0-foundation.md §17.6; owned by G2 after S0). Boots
## main.tscn in first person, grows the city offline, stands on the fp_shots "street" sidewalk and
## measures frame cost with and without the HUD, looking across, and through sim ticks and a day
## boundary at speed 1. Prints one FPBENCH {json} line per measurement, then FPBENCH: DONE.
## Report-only: it always quits 0.

const SHOTS := preload("res://tools/tests/fp_shots.gd")
## D11 measures at 1600x900. Some window managers open the window smaller than --resolution, so
## the bench sets the size itself and reports the real one in every row (the gate checks it).
const TARGET_SIZE := Vector2i(1600, 900)

var main: Node
var out_dir := ""
var vp_rid: RID


func _measure(label: String, secs: float) -> Dictionary:
	for _i in range(20):
		await process_frame
	var times: Array[float] = []
	var gpu := 0.0
	var cpu := 0.0
	var n := 0
	var t0 := Time.get_ticks_usec()
	var last := t0
	while float(Time.get_ticks_usec() - t0) < secs * 1e6:
		await process_frame
		var now := Time.get_ticks_usec()
		times.append(float(now - last) / 1000.0)
		last = now
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp_rid)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp_rid)
		n += 1
	var sorted := times.duplicate()
	sorted.sort()
	var avg := 0.0
	for t in times:
		avg += t
	avg /= maxf(1.0, float(times.size()))
	var r := {
		"label": label, "frames": n, "fps": snappedf(1000.0 / maxf(avg, 0.001), 0.1), "avg_ms": snappedf(avg, 0.01),
		"p50_ms": snappedf(sorted[int(sorted.size() * 0.5)], 0.01) if not sorted.is_empty() else 0.0,
		"p99_ms": snappedf(sorted[mini(int(sorted.size() * 0.99), sorted.size() - 1)], 0.01) if not sorted.is_empty() else 0.0,
		"max_ms": snappedf(sorted[-1], 0.01) if not sorted.is_empty() else 0.0,
		"gpu_ms": snappedf(gpu / maxf(1.0, n), 0.01), "rcpu_ms": snappedf(cpu / maxf(1.0, n), 0.01),
		"draws": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		"prims": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"vram_mb": snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"hitches_over_33ms": times.filter(func(t: float) -> bool: return t > 33.3).size(),
		"viewport": "%dx%d" % [get_root().size.x, get_root().size.y],
	}
	print("FPBENCH ", JSON.stringify(r))
	return r


func _init() -> void:
	out_dir = OS.get_environment("FPBENCH_DIR")
	if out_dir.is_empty():
		out_dir = "user://fpbench"
	DirAccess.make_dir_recursive_absolute(out_dir)
	vp_rid = get_root().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp_rid, true)
	OS.set_environment("GRIDFALL_VIEW", "fp")
	OS.set_environment("GRIDFALL_MOUSE", "free")
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_root().add_child(main)
	for _i in range(5):
		await process_frame
	# After boot: a size set in _init, before the window is up, is overridden by the window manager.
	get_root().size = TARGET_SIZE
	var fp: FpMode = main.fp
	var sim: CitySim = main.sim
	if fp == null:
		print("FPBENCH: first person did not start")
		print("FPBENCH: DONE")
		quit(0)
		return
	# Main's play boot already called sim.start(); grow on top of it.
	var days := int(OS.get_environment("FPBENCH_DAYS")) if OS.has_environment("FPBENCH_DAYS") else 6
	var tg := Time.get_ticks_msec()
	await main.grow_offline(days, 120000)
	print("FPBENCH grown day=%d pop=%d active=%d in %d ms" % [sim.day, int(sim.stats["population"]), sim.active.size(), Time.get_ticks_msec() - tg])
	main.sky.fixed_hour = 10.5
	var player := fp.player
	player.input_enabled = false
	var street: Dictionary = SHOTS.find(sim, fp.directory, fp.collision)[0]
	player.teleport(street["pos"], float(street["yaw"]), float(street["pitch"]))
	print("FPBENCH street at %s yaw %.1f" % [str(player.position), float(street["yaw"])])
	get_root().size = TARGET_SIZE
	for _i in range(60):
		await process_frame
	await _measure("street_eye_hud", 4.0)
	await RenderingServer.frame_post_draw
	get_root().get_texture().get_image().save_png(out_dir.path_join("bench_street.png"))
	fp.hud.set_hud_visible(false)
	await _measure("street_eye_nohud", 4.0)
	player.teleport(player.position, float(street["yaw"]) + 90.0, 0.0, false)
	await _measure("street_cross_nohud", 4.0)
	player.teleport(street["pos"], float(street["yaw"]), float(street["pitch"]))
	# Two growth ticks through the normal _process path: the stall slice F must remove.
	var saved_day := sim.day_seconds
	sim.set_day_seconds(12.0)
	sim.set_speed(1)
	await _measure("street_tick", 6.5)
	sim.set_speed(0)
	sim.tick_in_day = 3
	sim.set_speed(1)
	await _measure("street_day_end", 6.5)
	sim.set_speed(0)
	sim.set_day_seconds(saved_day)
	print("FPBENCH: DONE")
	main.audio._exit_tree()
	quit(0)
