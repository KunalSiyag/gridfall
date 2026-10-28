extends SceneTree
## Headless traffic _process cost probe (round 4 web perf): boots main.tscn on foot offline,
## grows the city, parks the hero on the fp_shots "street" sidewalk, then times the traffic
## feature's step (fixed 1/60 s) and sync_visuals (the frame's real delta) separately per frame,
## alongside the live agent counts. This is the script-side cost the browser profile sees as
## traffic's _process (6.6-12.9 ms there); native headless numbers are the before/after proxy.
## Run headless with GRIDFALL_OFFLINE=1 and an isolated XDG_DATA_HOME; TRAFFIC_PERF_FRAMES
## (default 300) and TRAFFIC_PERF_DAYS (default 6) tune the run. Prints TRAFFIC_PERF {json} per
## configuration, then TRAFFIC_PERF: DONE.

const SHOTS := preload("res://tools/tests/fp_shots.gd")
const VH := preload("res://scripts/fp/traffic/vehicles.gd")
const WK := preload("res://scripts/fp/traffic/walkers.gd")

var main: Node
var fp: FpMode
var traffic: FpFeature


func _init() -> void:
	await process_frame
	OS.set_environment("GRIDFALL_VIEW", "fp")
	OS.set_environment("GRIDFALL_MOUSE", "free")
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_root().add_child(main)
	for _i in range(5):
		await process_frame
	fp = main.fp
	var sim: CitySim = main.sim
	if fp == null:
		print("TRAFFIC_PERF: FAIL first person did not start")
		quit(1)
		return
	fp.apply_settings({"camera_mode": "first", "quality": "medium"}, false)
	var days := _env_int("TRAFFIC_PERF_DAYS", 6)
	var tg := Time.get_ticks_msec()
	await main.grow_offline(days, 120000)
	print(
		(
			"TRAFFIC_PERF grown day=%d pop=%d in %d ms"
			% [sim.day, int(sim.stats["population"]), Time.get_ticks_msec() - tg]
		)
	)
	main.sky.fixed_hour = 10.5
	var player := fp.player
	player.input_enabled = false
	var street: Dictionary = SHOTS.find(sim, fp.directory, fp.collision)[0]
	player.teleport(street["pos"], float(street["yaw"]), float(street["pitch"]))
	for _i in range(60):
		await process_frame
	traffic = fp.ctx.feature("traffic")
	if traffic == null:
		print("TRAFFIC_PERF: FAIL no traffic feature")
		quit(1)
		return
	# The probe steps traffic itself, timed: the feature's own _process is parked.
	traffic.set("auto_step", false)
	traffic.set_process(false)
	await _measure("full", _env_int("TRAFFIC_PERF_FRAMES", 300))
	print("TRAFFIC_PERF: DONE")
	quit(0)


## Times step() and sync_visuals() over frames and prints the row.
func _measure(label: String, frames: int) -> void:
	var step_ts: Array[float] = []
	var vis_ts: Array[float] = []
	var last := Time.get_ticks_usec()
	for _i in range(frames):
		await process_frame
		var now := Time.get_ticks_usec()
		var delta := (now - last) / 1e6
		last = now
		var t0 := Time.get_ticks_usec()
		traffic.call("step", 1.0 / 60.0)
		var t1 := Time.get_ticks_usec()
		traffic.call("sync_visuals", delta)
		var t2 := Time.get_ticks_usec()
		step_ts.append((t1 - t0) / 1000.0)
		vis_ts.append((t2 - t1) / 1000.0)
	var cars: int = (traffic.get("vehicles") as VH).cars.size()
	var walkers: int = (traffic.get("walkers") as WK).walkers.size()
	var row := {
		"config": label,
		"frames": frames,
		"cars": cars,
		"walkers": walkers,
		"step_ms": _stats(step_ts),
		"visuals_ms": _stats(vis_ts),
		"total_ms": _stats(_sum(step_ts, vis_ts)),
	}
	print("TRAFFIC_PERF " + JSON.stringify(row))


func _stats(ts: Array[float]) -> Dictionary:
	var sorted := ts.duplicate()
	sorted.sort()
	var total := 0.0
	for v in ts:
		total += v
	return {
		"avg_ms": snappedf(total / maxf(1.0, ts.size()), 0.01),
		"p50_ms": snappedf(sorted[int(sorted.size() * 0.5)], 0.01),
		"p99_ms": snappedf(sorted[mini(int(sorted.size() * 0.99), sorted.size() - 1)], 0.01),
		"max_ms": snappedf(sorted[-1], 0.01),
	}


func _sum(a: Array[float], b: Array[float]) -> Array[float]:
	var out: Array[float] = []
	for i in range(a.size()):
		out.append(a[i] + b[i])
	return out


func _env_int(key: String, fallback: int) -> int:
	return int(OS.get_environment(key)) if OS.has_environment(key) else fallback
