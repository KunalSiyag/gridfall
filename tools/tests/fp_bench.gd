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
const SIM_SIGNALS := [
	"tiles_changed", "tick_done", "stats_updated", "day_started", "day_ended", "territory_changed",
	"site_started", "site_stage", "site_finished", "event_started", "event_ended", "city_log",
]
const VIEW_SIGNALS := ["tile_built", "tile_cleared", "world_rebuilt"]
const HITCH_MS := 33.3
const MAX_HITCHES := 12
const PIPELINES := [
	Performance.PIPELINE_COMPILATIONS_CANVAS, Performance.PIPELINE_COMPILATIONS_MESH,
	Performance.PIPELINE_COMPILATIONS_SURFACE, Performance.PIPELINE_COMPILATIONS_DRAW,
	Performance.PIPELINE_COMPILATIONS_SPECIALIZATION,
]
const PIPELINE_KINDS := ["canvas", "mesh", "surface", "draw", "specialization"]

var main: Node
var fp: FpMode
var out_dir := ""
var vp_rid: RID
var rows: Dictionary = {}
var prof: Dictionary = {}
var harness: ProcessHarness = null
## Geometry that entered the tree since the last frame, by _added_key: what a slow frame drew
## for the first time (new building models, sites, street props).
var added: Dictionary = {}


## Runs the _process of the nodes it took over (in tree order) and times each one, so a slow frame
## can name the nodes it spent its script time in.
class ProcessHarness extends Node:
	var nodes: Array[Node] = []
	var names: Array[String] = []
	var frame: Dictionary = {}  # name -> ms in the last frame

	func take(tree_root: Node) -> void:
		for n in tree_root.find_children("*", "", true, false):
			var sc: Script = n.get_script()
			if n == self or sc == null or not n.is_processing() or not n.has_method("_process"):
				continue
			n.set_process(false)
			nodes.append(n)
			names.append("%s(%s)" % [n.name, sc.resource_path.get_file().get_basename()])

	func _process(delta: float) -> void:
		frame.clear()
		for k in range(nodes.size()):
			var n := nodes[k]
			if not is_instance_valid(n) or not n.is_inside_tree() or not n.can_process():
				continue
			var t := Time.get_ticks_usec()
			n.call("_process", delta)
			frame[names[k]] = (Time.get_ticks_usec() - t) / 1000.0

	## The n nodes that took longest in the last frame, [name, ms].
	func top(n: int) -> Array:
		var keys := frame.keys()
		keys.sort_custom(func(a: String, b: String) -> bool:
			return float(frame[a]) > float(frame[b]))
		var out: Array = []
		for k: String in keys.slice(0, n):
			out.append([k, snappedf(float(frame[k]), 0.1)])
		return out


func _measure(label: String, secs: float) -> Dictionary:
	for _i in range(20):
		await process_frame
	var sim: CitySim = main.sim
	var ro: Object = fp.ctx.feature("render_opt")
	_reset_stats(sim, ro)
	var times: Array[float] = []
	var gpu := 0.0
	var cpu := 0.0
	var n := 0
	var hitches: Array = []
	var pipes := _pipelines()
	var drawn0 := Engine.get_frames_drawn()
	var t0 := Time.get_ticks_usec()
	var last := t0
	while float(Time.get_ticks_usec() - t0) < secs * 1e6:
		var phys0 := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
		await process_frame
		var now := Time.get_ticks_usec()
		var dt := float(now - last) / 1000.0
		times.append(dt)
		last = now
		var g := RenderingServer.viewport_get_measured_render_time_gpu(vp_rid)
		var c := RenderingServer.viewport_get_measured_render_time_cpu(vp_rid)
		gpu += g
		cpu += c
		n += 1
		var p := _pipelines()
		var phys1 := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
		var phys_d: float = phys1 - phys0
		if dt > HITCH_MS and hitches.size() < MAX_HITCHES:
			var h := _hitch(dt, g, c, _pipeline_delta(p, pipes), phys_d if phys_d >= 0.0 else phys1)
			if harness != null:
				h["nodes"] = harness.top(4)
			h["added"] = _top_counts(added, 6)
			hitches.append(h)
		added.clear()
		pipes = p
	var r := {"label": label, "frames": n}
	r.merge(_frame_stats(times))
	r.merge({
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
		"drawn": Engine.get_frames_drawn() - drawn0,
	})
	_feature_stats(r, ro, sim, label)
	_breakdown(r, hitches)
	rows[label] = r
	print("FPBENCH ", JSON.stringify(r))
	if int(r["drawn"]) * 2 < n:
		print("FPBENCH: WARNING %s drew %d of %d frames (window hidden?)" % [label, r["drawn"], n])
	return r


func _reset_stats(sim: CitySim, ro: Object) -> void:
	if sim.has_method("reset_slice_stats"):
		sim.call("reset_slice_stats")
	if ro != null and ro.has_method("reset_stats"):
		ro.call("reset_stats")
	main.view.reset_section_stats()
	for id: String in ["hud_widgets", "traffic", "audio"]:
		var f: Object = fp.ctx.feature(id)
		if f != null and f.has_method("reset_section_stats"):
			f.call("reset_section_stats")


## fps, avg, p50, p99 and max of the frame times (ms) of one row.
static func _frame_stats(times: Array[float]) -> Dictionary:
	var sorted := times.duplicate()
	sorted.sort()
	var avg := 0.0
	for t in times:
		avg += t
	avg /= maxf(1.0, float(times.size()))
	var out := {
		"fps": snappedf(1000.0 / maxf(avg, 0.001), 0.1), "avg_ms": snappedf(avg, 0.01),
		"p50_ms": 0.0, "p99_ms": 0.0, "max_ms": 0.0,
	}
	if not sorted.is_empty():
		out["p50_ms"] = snappedf(sorted[int(sorted.size() * 0.5)], 0.01)
		out["p99_ms"] = snappedf(sorted[mini(int(sorted.size() * 0.99), sorted.size() - 1)], 0.01)
		out["max_ms"] = snappedf(sorted[-1], 0.01)
	return out


func _feature_stats(r: Dictionary, ro: Object, sim: CitySim, label: String) -> void:
	if ro != null and ro.get("hlod") != null:
		var hl: Object = ro.get("hlod")
		r["g2"] = {
			"active": ro.get("active"), "tiles": (hl.get("tiles") as Dictionary).size(),
			"impostor_chunks": (hl.get("chunk_nodes") as Dictionary).size(),
			"occluder_boxes": (ro.get("occluders") as Object).call("box_count"), "vis_building": hl.get("vis_building"),
			"frame_us_max": ro.get("frame_us_max"), "pass_us_max": ro.get("pass_us_max"),
			"warm_us_max": ro.get("warm_us_max"), "rebuild_us_max": ro.get("rebuild_us_max"),
			"pass_pending": ro.call("pass_pending") if ro.has_method("pass_pending") else 0,
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


func _breakdown(r: Dictionary, hitches: Array) -> void:
	r["hitches"] = hitches
	var sections := {}
	for k: String in main.view.section_us_max:
		sections[k] = snappedf(int(main.view.section_us_max[k]) / 1000.0, 0.1)
	r["view_sections_ms"] = sections
	# Features that time their own hot spots the same way (hud_widgets' minimap flush and GPS
	# reroute, traffic's per-tile rebuild steps).
	var fsections := {}
	for id: String in ["hud_widgets", "traffic", "audio"]:
		var f: Object = fp.ctx.feature(id)
		var m: Variant = f.get("section_us_max") if f != null else null
		if typeof(m) != TYPE_DICTIONARY or (m as Dictionary).is_empty():
			continue
		var sub := {}
		for k: String in m:
			sub[k] = snappedf(int(m[k]) / 1000.0, 0.1)
		fsections[id] = sub
	if not fsections.is_empty():
		r["feature_sections_ms"] = fsections
	if not prof.is_empty():
		r["signals"] = _top(prof, 12)
		prof.clear()


## Replaces every connection of the signals in names on obj with a timed call of the same callable,
## accumulating {"calls", "total_ms", "max_ms"} per handler into prof (the tick rows' breakdown).
static func _time_signals(obj: Object, names: Array, prof: Dictionary) -> void:
	for s: Dictionary in obj.get_signal_list():
		var sig := str(s["name"])
		if not names.has(sig):
			continue
		var argc := (s["args"] as Array).size()
		for c: Dictionary in obj.get_signal_connection_list(sig):
			var cb: Callable = c["callable"]
			var key := "%s>%s.%s" % [sig, _owner_name(cb.get_object()), cb.get_method()]
			var timed := func(a: Variant = null, b: Variant = null, d: Variant = null) -> void:
				var t := Time.get_ticks_usec()
				cb.callv([a, b, d].slice(0, argc))
				var ms := (Time.get_ticks_usec() - t) / 1000.0
				var blank := {"calls": 0, "total_ms": 0.0, "max_ms": 0.0}
				var e: Dictionary = prof.get_or_add(key, blank)
				e["calls"] = int(e["calls"]) + 1
				e["total_ms"] = float(e["total_ms"]) + ms
				e["max_ms"] = maxf(float(e["max_ms"]), ms)
			obj.disconnect(sig, cb)
			obj.connect(sig, timed, int(c["flags"]) & ~CONNECT_PERSIST)


static func _owner_name(o: Object) -> String:
	if o == null:
		return "?"
	var sc: Script = o.get_script()
	if sc != null and not sc.resource_path.is_empty():
		return sc.resource_path.get_file().get_basename()
	return o.get_class()


## The slowest handlers in prof, rounded, slowest worst call first.
static func _top(prof: Dictionary, n: int) -> Array:
	var keys := prof.keys()
	keys.sort_custom(func(x: String, y: String) -> bool:
		return float(prof[x]["max_ms"]) > float(prof[y]["max_ms"]))
	var out: Array = []
	for k: String in keys.slice(0, n):
		var e: Dictionary = prof[k]
		var total := snappedf(float(e["total_ms"]), 0.1)
		out.append([k, int(e["calls"]), total, snappedf(float(e["max_ms"]), 0.1)])
	return out


func _on_node_added(n: Node) -> void:
	if n is GeometryInstance3D:
		var key := _added_key(n)
		added[key] = int(added.get(key, 0)) + 1


## The scene file that owns n, else the nearest ancestor with a given name ("Site", "StreetProps").
static func _added_key(n: Node) -> String:
	var o := n.owner
	if o != null and not o.scene_file_path.is_empty():
		return o.scene_file_path.get_file()
	var p := n.get_parent()
	while p != null and str(p.name).begins_with("@"):
		p = p.get_parent()
	return str(p.name) if p != null else n.get_class()


## The n biggest counts, [key, count].
static func _top_counts(counts: Dictionary, n: int) -> Array:
	var keys := counts.keys()
	keys.sort_custom(func(x: String, y: String) -> bool: return int(counts[x]) > int(counts[y]))
	return keys.slice(0, n).map(func(k: String) -> Array: return [k, counts[k]])


## Pipeline compilations so far, per kind (PIPELINE_KINDS). Draw compiles stall the frame that
## needs them; surface ones run when a new mesh and material pair enters the scene (hidden or not),
## mesh ones as meshes load, specialization ones in the background.
static func _pipelines() -> PackedInt32Array:
	var out := PackedInt32Array()
	for m in PIPELINES:
		out.append(int(Performance.get_monitor(m)))
	return out


static func _pipeline_delta(now: PackedInt32Array, before: PackedInt32Array) -> Dictionary:
	var out := {}
	for k in range(now.size()):
		if now[k] != before[k]:
			out[PIPELINE_KINDS[k]] = now[k] - before[k]
	return out


## Where a slow frame went: scripts (_process and signals), physics, render CPU and GPU (as
## measured, a frame or two late) and the pipelines it compiled. physics_ms is the physics time
## spent inside this idle frame: TIME_PHYSICS_PROCESS is per-frame on some platforms and cumulative
## on others (web), so the caller passes the delta between this frame's edges, falling back to the
## absolute reading when the monitor is per-frame (a negative delta).
static func _hitch(
	dt: float, gpu: float, rcpu: float, pipes: Dictionary, physics: float
) -> Dictionary:
	return {
		"ms": snappedf(dt, 0.1),
		"process_ms": snappedf(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, 0.1),
		"physics_ms": snappedf(physics * 1000.0, 0.1),
		"rcpu_ms": snappedf(rcpu, 0.1), "gpu_ms": snappedf(gpu, 0.1), "pipelines": pipes,
	}


## The HUD's own cost: the HUD toggles every AB_FRAMES frames and each state sums the GPU and render
## CPU time of its frames, skipping AB_SKIP after a toggle (the measured times lag). Back-to-back
## rows drift by several ms on a shared or throttling GPU; alternating cancels that.
func _hud_ab(secs: float) -> void:
	const AB_FRAMES := 12
	const AB_SKIP := 3
	var sums := {true: [0.0, 0.0, 0], false: [0.0, 0.0, 0]}
	var on := false
	var k := 0
	var t0 := Time.get_ticks_usec()
	while float(Time.get_ticks_usec() - t0) < secs * 1e6:
		if k % AB_FRAMES == 0:
			on = not on
			fp.hud.set_hud_visible(on)
		await process_frame
		if k % AB_FRAMES >= AB_SKIP:
			var s: Array = sums[on]
			s[0] = float(s[0]) + RenderingServer.viewport_get_measured_render_time_gpu(vp_rid)
			s[1] = float(s[1]) + RenderingServer.viewport_get_measured_render_time_cpu(vp_rid)
			s[2] = int(s[2]) + 1
		k += 1
	fp.hud.set_hud_visible(false)
	var avg := func(state: bool, j: int) -> float:
		var s: Array = sums[state]
		return snappedf(float(s[j]) / maxf(1.0, float(s[2])), 0.01)
	var r := {"label": "street_eye_hud_ab", "frames": k}
	r["gpu_on_ms"] = avg.call(true, 0)
	r["gpu_off_ms"] = avg.call(false, 0)
	r["rcpu_on_ms"] = avg.call(true, 1)
	r["rcpu_off_ms"] = avg.call(false, 1)
	r["hud_gpu_ms"] = snappedf(float(r["gpu_on_ms"]) - float(r["gpu_off_ms"]), 0.01)
	r["hud_rcpu_ms"] = snappedf(float(r["rcpu_on_ms"]) - float(r["rcpu_off_ms"]), 0.01)
	r["viewport"] = "%dx%d" % [get_root().size.x, get_root().size.y]
	rows["street_eye_hud_ab"] = r
	print("FPBENCH ", JSON.stringify(r))


## FPBENCH_HUD_PROBE=1: the HUD's GPU cost per slot, interleaved so drift in the 3D scene cancels
## out: every slot shown, none, and each slot alone, twice.
func _hud_probe() -> void:
	var slots: Array = ["top_bar", "minimap_slot", "chat_slot", "center", "toasts"]
	for round_i in range(2):
		for only: String in ["all", "none"] + slots:
			for s: String in slots:
				fp.hud.slot(s).visible = only == "all" or only == s
			await _measure("probe%d_%s" % [round_i, only], 2.5)
	fp.hud.set_hud_visible(true)


## The camera the player is actually using: A's player reports it; the S0 player is first person only.
func _camera_mode() -> String:
	var m: Variant = fp.player.get("camera_mode")
	return str(m) if m != null else "first"


## Saves the next drawn frame. A window the window manager hides or minimises stops drawing while
## frames still run (the bench used to wait forever for frame_post_draw), so give up after 5 s.
func _shot(file: String) -> void:
	var drew := [false]
	var mark := func() -> void: drew[0] = true
	RenderingServer.frame_post_draw.connect(mark, CONNECT_ONE_SHOT)
	var t0 := Time.get_ticks_msec()
	while not drew[0] and Time.get_ticks_msec() - t0 < 5000:
		await process_frame
	if not drew[0]:
		RenderingServer.frame_post_draw.disconnect(mark)
		print("FPBENCH: WARNING %s not saved, the window has not drawn for 5 s" % file)
		return
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
	if OS.get_environment("FPBENCH_HUD_PROBE") == "1":
		await _hud_probe()
	await _measure("street_eye_hud", 4.0)
	await _shot("bench_street.png")
	fp.hud.set_hud_visible(false)
	await _measure("street_eye_nohud", 4.0)
	await _hud_ab(6.0)
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
	_time_signals(sim, SIM_SIGNALS, prof)
	_time_signals(main.view, VIEW_SIGNALS, prof)
	node_added.connect(_on_node_added)
	harness = ProcessHarness.new()
	harness.name = "BenchProcessHarness"
	harness.process_priority = -1000
	get_root().add_child(harness)
	harness.take(get_root())
	print("FPBENCH harness took %d nodes" % harness.nodes.size())
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
		if int(r.get("drawn", 0)) * 2 < int(r["frames"]):
			var drew := "%s drew %d of %d frames" % [l, int(r["drawn"]), int(r["frames"])]
			why.append(drew + " (window hidden?)")
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
