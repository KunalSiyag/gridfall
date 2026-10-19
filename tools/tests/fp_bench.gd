extends SceneTree
## First-person performance report (docs/fp/S0-foundation.md §17.6, owned by G2: slices/G2-renderperf.md
## §4). Boots main.tscn on foot, grows the city offline, stands on the fp_shots "street" sidewalk and
## measures frame cost with and without the HUD, looking across, per quality preset, from the
## third-person camera, and through sim ticks and a day boundary at speed 1. Prints one
## FPBENCH {json} line per measurement, then FPBENCH: DONE. Report-only unless FPBENCH_ENFORCE=1,
## which fails (exit 1, "FPBENCH: FAIL <reasons>") when street_eye_nohud on Medium misses D11.

const SHOTS := preload("res://tools/tests/fp_shots.gd")
## D11 measures at 1600x900. Some window managers open the window smaller than --resolution, so
## the bench sets the size itself and reports the real one in every row (the gate checks it).
const TARGET_SIZE := Vector2i(1600, 900)
## D11 targets, enforced with FPBENCH_ENFORCE=1.
const MAX_P50_MS := 16.7
const MAX_P99_MS := 33.0
const MAX_DRAWS := 2000
const MAX_VRAM_MB := 1536.0
## TPS_PLAN T9 animated-people budget (enforced once E2 reports it).
const MAX_ANIM_US := 1500.0
const MAX_CHAR_DRAWS := 150

var main: Node
var fp: FpMode
var out_dir := ""
var vp_rid: RID
var rows: Dictionary = {}


func _measure(label: String, secs: float) -> Dictionary:
	for _i in range(20):
		await process_frame
	var sim: CitySim = main.sim
	if sim.has_method("reset_slice_stats"):
		sim.call("reset_slice_stats")
	var ro: Object = fp.ctx.feature("render_opt")
	if ro != null and ro.has_method("reset_stats"):
		ro.call("reset_stats")
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
		"tex_mb": snappedf(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0, 0.1),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"hitches_over_33ms": times.filter(func(t: float) -> bool: return t > 33.3).size(),
		"viewport": "%dx%d" % [get_root().size.x, get_root().size.y],
		"quality": str(fp.ctx.settings.get("quality", "medium")),
		"camera": _camera_mode(),
	}
	if ro != null and ro.get("hlod") != null:
		var hl: Object = ro.get("hlod")
		r["g2"] = {
			"active": ro.get("active"), "tiles": (hl.get("tiles") as Dictionary).size(),
			"impostor_chunks": (hl.get("chunk_nodes") as Dictionary).size(),
			"occluder_boxes": (ro.get("occluders") as Object).call("box_count"), "vis_building": hl.get("vis_building"),
			"frame_us_max": ro.get("frame_us_max"), "pass_us_max": ro.get("pass_us_max"),
		}
	var traffic: Object = fp.ctx.feature("traffic")
	if traffic != null and traffic.has_method("anim_stats"):
		r["anim"] = traffic.call("anim_stats")
	var avatar: Object = fp.player.get("avatar")
	if avatar != null and avatar.get("anim_us") != null:
		r["hero_anim_us"] = avatar.get("anim_us")
	var rig: Object = fp.player.get("rig")
	if rig != null and rig.get("update_us") != null:
		r["rig_us"] = rig.get("update_us")
	if (label == "street_tick" or label == "street_day_end") and sim.has_method("slice_stats"):
		r["sim"] = sim.call("slice_stats")
	rows[label] = r
	print("FPBENCH ", JSON.stringify(r))
	return r


## The camera the player is actually using: A's player reports it; the S0 player is first person only.
func _camera_mode() -> String:
	var m: Variant = fp.player.get("camera_mode")
	return str(m) if m != null else "first"


func _shot(file: String) -> void:
	await RenderingServer.frame_post_draw
	get_root().get_texture().get_image().save_png(out_dir.path_join(file))


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
	fp = main.fp
	var sim: CitySim = main.sim
	if fp == null:
		print("FPBENCH: first person did not start")
		print("FPBENCH: DONE")
		quit(0)
		return
	# Keep the first-person baselines comparable: eye-level camera, Medium, not saved (D13).
	fp.apply_settings({"camera_mode": "first", "quality": "medium"}, false)
	# Main's play boot already called sim.start(); grow on top of it.
	var days := int(OS.get_environment("FPBENCH_DAYS")) if OS.has_environment("FPBENCH_DAYS") else 6
	var tg := Time.get_ticks_msec()
	await main.grow_offline(days, 120000)
	print("FPBENCH grown day=%d pop=%d active=%d in %d ms" % [sim.day, int(sim.stats["population"]), sim.active.size(), Time.get_ticks_msec() - tg])
	main.sky.fixed_hour = 10.5
	var player := fp.player
	player.input_enabled = false
	var street: Dictionary = SHOTS.find(sim, fp.directory, fp.collision)[0]
	var eye_yaw := float(street["yaw"])
	player.teleport(street["pos"], eye_yaw, float(street["pitch"]))
	print("FPBENCH street at %s yaw %.1f" % [str(player.position), eye_yaw])
	get_root().size = TARGET_SIZE
	for _i in range(60):
		await process_frame
	await _measure("street_eye_hud", 4.0)
	await _shot("bench_street.png")
	fp.hud.set_hud_visible(false)
	await _measure("street_eye_nohud", 4.0)
	player.teleport(player.position, eye_yaw + 90.0, 0.0, false)
	await _measure("street_cross_nohud", 4.0)
	await _shot("bench_cross.png")
	# Quality presets: the street pose and the cross view (the heavier one) per preset.
	for q: String in ["low", "medium", "high"]:
		fp.apply_settings({"quality": q}, false)
		player.teleport(street["pos"], eye_yaw, float(street["pitch"]))
		await _measure("street_eye_nohud_" + q, 3.0)
		player.teleport(street["pos"], eye_yaw + 90.0, 0.0, false)
		await _measure("street_cross_nohud_" + q, 3.0)
		await _shot("bench_cross_%s.png" % q)
	fp.apply_settings({"quality": "medium"}, false)
	# Third person (D13): the same street pose behind the hero; A's camera blend takes 0.35 s.
	player.teleport(street["pos"], eye_yaw, float(street["pitch"]))
	fp.apply_settings({"camera_mode": "third"}, false)
	for _i in range(60):
		await process_frame
	await _measure("street_tps_nohud", 4.0)
	await _shot("bench_street_tps.png")
	fp.apply_settings({"camera_mode": "first"}, false)
	player.teleport(street["pos"], eye_yaw, float(street["pitch"]))
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
	var code := 0
	if OS.get_environment("FPBENCH_ENFORCE") == "1":
		var why := _enforce()
		if not why.is_empty():
			print("FPBENCH: FAIL ", "; ".join(why))
			code = 1
		else:
			print("FPBENCH: PASS D11 targets met")
	print("FPBENCH: DONE")
	main.audio._exit_tree()
	quit(code)


## D11 failures of the enforced rows ([] when every target is met). street_tps_nohud joins once
## the third-person camera really runs (A1), its animation budget once E2 reports real numbers.
func _enforce() -> Array[String]:
	var why: Array[String] = []
	var labels := ["street_eye_nohud"]
	if str((rows.get("street_tps_nohud", {}) as Dictionary).get("camera", "first")) == "third":
		labels.append("street_tps_nohud")
	for l: String in labels:
		var r: Dictionary = rows.get(l, {})
		if r.is_empty():
			why.append("%s missing" % l)
			continue
		if float(r["p50_ms"]) > MAX_P50_MS:
			why.append("%s p50 %.2f ms > %.1f" % [l, float(r["p50_ms"]), MAX_P50_MS])
		if float(r["p99_ms"]) > MAX_P99_MS:
			why.append("%s p99 %.2f ms > %.1f" % [l, float(r["p99_ms"]), MAX_P99_MS])
		if float(r["draws"]) > MAX_DRAWS:
			why.append("%s draws %d > %d" % [l, int(r["draws"]), MAX_DRAWS])
		if float(r["vram_mb"]) > MAX_VRAM_MB:
			why.append("%s VRAM %.0f MB > %.0f" % [l, float(r["vram_mb"]), MAX_VRAM_MB])
		var anim: Dictionary = r.get("anim", {})
		# The pre-E2 stub reports anim_us 0.
		if l == "street_tps_nohud" and float(anim.get("anim_us", 0.0)) > 0.0:
			if float(anim["anim_us"]) > MAX_ANIM_US:
				why.append("%s anim %.0f us > %.0f" % [l, float(anim["anim_us"]), MAX_ANIM_US])
			if int(anim.get("char_draws", 0)) > MAX_CHAR_DRAWS:
				why.append("%s character draws %d > %d" % [l, int(anim["char_draws"]), MAX_CHAR_DRAWS])
	return why
