class_name ShaderWarmup
extends RefCounted
## Shader warm-up for the web build. The Compatibility renderer links each shader program the first
## time something is drawn with it, and in the browser that wait is synchronous (a median of 37 ms,
## up to 213 ms, per program): a new material coming into view, the lamps turning on, the Tab
## overview showing far trees, each stalled the page for several hundred ms in the first minutes of
## play. run() does that work during the loader veil instead (docs/runbooks/web-probe-kit.md,
## "Shader warm-up"): it asks WarmCollector for the distinct draws the scene makes (and for a short
## list of things that are not in it yet but come within the first minutes: people's cut-out
## materials, a construction beacon, a new building's leaves), parks one tiny copy of each in front
## of the camera (WarmStage) in the sun's two shadow states, a few per frame with a time budget, so
## the page stays responsive and the loader can show progress.
## Off the web it does nothing (the desktop links in the pipeline cache), and so with the flag
## web_shader_warmup off. BootClock.finish() calls it right after the first frame, so the veil is
## lifted only when it is done (or its budget is spent: what is left stays lazy, as before).

const FLAG := "web_shader_warmup"
const TUNING_PATH := "user://warmup_tuning.json"
const REPORT_PREFIX := "WARMUP "
const REPORT_VERSION := 1
## Stop starting batches when the stage has run this long (ms): what is left links in play.
const DEFAULT_BUDGET_MS := 3000.0
## A batch is sized to take about this long (ms) at the last frame's cost per copy. Every frame also
## draws the whole street (about 25 ms of fixed cost here), so a bigger batch warms more per second;
## near the end of the budget a batch shrinks to what the rest could pay at COPY_GUESS_MS a copy.
const FRAME_TARGET_MS := 300.0
const MAX_BATCH := 12
const COPY_GUESS_MS := 120.0
## Frames the overview is held open for the warm-up (its camera eases up over the first few).
const OVERVIEW_FRAMES := 6
## A frame over this (ms) is counted in the report as a hitch behind the veil.
const SLOW_FRAME_MS := 100.0
## A scene with more recipes than this is not warmed (a grown city: 1,575 against a new city's
## 190). Every frame of the stage also draws the whole real scene, and the first frame of the
## shadow-off pass draws all of it again in a new state (1.9 s on a day-10 city): the budget is gone
## before the pass has warmed anything, so the warm-up only added 0.8 to 2.1 s of boot and removed
## no hitch (frames over 100 ms 9 and 9, against 9 and 9 without it).
const LARGE_SCENE_RECIPES := 600

## Tests set this to run on the desktop.
static var force: bool = false
## Tests set this to say whether the loader's veil is up (default: WebSupport.veil_up()).
static var veil_check: Callable = Callable()
## The report of the last run ({} before one, and when it did not run).
static var report: Dictionary = {}


## True on the web build (or force) with the flag on.
static func active() -> bool:
	return (force or WebSupport.is_web()) and FeatureFlags.enabled("web_shader_warmup", true)


## The tunables: defaults, overridden by user://warmup_tuning.json (a probe and test knob:
## {"budget_ms", "states": ["prototypes", "unlit+noshadow", "orbit", "overview", "lit", "unlit"],
## "max_recipes", "large_scene_recipes"}).
static func tuning() -> Dictionary:
	var t := {
		"budget_ms": DEFAULT_BUDGET_MS,
		"states": ["prototypes", "unlit+noshadow"],
		"max_recipes": 2000,
		"large_scene_recipes": LARGE_SCENE_RECIPES
	}
	if FileAccess.file_exists(TUNING_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(TUNING_PATH))
		if typeof(parsed) == TYPE_DICTIONARY:
			t.merge(parsed as Dictionary, true)
	return t


## Runs the warm-up for the scene under main (needs main.active_camera()). Awaitable; returns when
## done. Safe to call when inactive: it returns at once.
static func run(main: Node) -> void:
	report = {}
	if main != null and main.is_inside_tree():
		RenderInfo.attach(main)
	if not active() or main == null or not main.is_inside_tree():
		return
	var cam: Camera3D = main.call("active_camera")
	if cam == null or not cam.is_inside_tree():
		return
	if not _veil_up():
		report = {"v": REPORT_VERSION, "skipped": "veil_gone"}
		return
	var tree := main.get_tree()
	var tune := tuning()
	BootClock.mark("warmup_begin")
	var began := Time.get_ticks_usec()
	var recipes := WarmCollector.collect(main, cam.global_position, int(tune["max_recipes"]))
	var collect_ms := float(Time.get_ticks_usec() - began) / 1000.0
	if recipes.size() > int(tune["large_scene_recipes"]):
		report = {
			"v": REPORT_VERSION,
			"skipped": "large_scene",
			"recipes": recipes.size(),
			"collect_ms": snappedf(collect_ms, 0.1),
			"ms": snappedf(float(Time.get_ticks_usec() - began) / 1000.0, 0.1),
		}
		print(REPORT_PREFIX + JSON.stringify(report, "", false))
		BootClock.mark("warmup_end")
		return
	var stage := WarmStage.new()
	stage.attach(cam)
	var states: Array = tune["states"]
	var protos: Array[Dictionary] = []
	if states.has("prototypes"):
		protos = WarmCollector.prototypes(_feature_prototypes(main))
	var run_state := {
		"began": began,
		"budget_ms": float(tune["budget_ms"]),
		"done": 0,
		"total": recipes.size() * (states.size() - (1 if protos.size() > 0 else 0)) + protos.size(),
		"slow": 0,
		"worst": 0.0,
		"cut": false,
	}
	var per_state: Array[Dictionary] = []
	for state: String in states:
		if not _veil_up():
			run_state["cut"] = true
			run_state["veil_gone"] = true
			break
		if state == "overview":
			var ov := await _overview(main, tree)
			per_state.append(ov)
			run_state["slow"] += int(ov["slow"])
			run_state["worst"] = maxf(float(run_state["worst"]), float(ov["worst_ms"]))
			run_state["done"] += recipes.size()
			continue
		var list: Array[Dictionary] = protos if state == "prototypes" else recipes
		per_state.append(await _stage_state(main, tree, stage, list, state, run_state))
		if bool(run_state["cut"]):
			break
	stage.set_lit(false)
	stage.clear_batch()
	cam.remove_child(stage)
	stage.free()
	WebSupport.boot_status("")
	var cut: bool = run_state["cut"]
	var budget_ms: float = run_state["budget_ms"]
	var slow: int = run_state["slow"]
	var worst: float = run_state["worst"]
	var total_ms := float(Time.get_ticks_usec() - began) / 1000.0
	report = {
		"v": REPORT_VERSION,
		"recipes": recipes.size(),
		"states": per_state,
		"cut": cut,
		"veil_gone": bool(run_state.get("veil_gone", false)),
		"collect_ms": snappedf(collect_ms, 0.1),
		"ms": snappedf(total_ms, 0.1),
		"slow_frames": slow,
		"worst_ms": snappedf(worst, 0.1),
		"budget_ms": budget_ms,
		"render": render_state(cam),
	}
	print(REPORT_PREFIX + JSON.stringify(report, "", false))
	BootClock.mark("warmup_end")


## What the renderer is told about the view the warm-up draws in (which shader families it needs
## follow from it): the viewport's scaling, the environment's effects and fog mode, the sun, the
## lights.
static func render_state(cam: Camera3D, with_lights: bool = true) -> Dictionary:
	var vp := cam.get_viewport()
	var env := cam.environment
	var out := {
		"scaling_mode": int(vp.scaling_3d_mode),
		"scale": vp.scaling_3d_scale,
		"msaa": int(vp.msaa_3d)
	}
	if env != null:
		out["fog"] = env.fog_enabled
		out["fog_mode"] = int(env.fog_mode)
		out["glow"] = env.glow_enabled
		out["ssao"] = env.ssao_enabled
		out["adjust"] = env.adjustment_enabled
		out["tonemap"] = int(env.tonemap_mode)
	if not with_lights:
		var sun := cam.get_tree().root.find_child("Sun", true, false) as DirectionalLight3D
		if sun != null:
			out["sun"] = [
				snappedf(sun.light_energy, 0.01),
				sun.shadow_enabled,
				sun.directional_shadow_max_distance
			]
		out["cam"] = [
			snappedf(cam.global_position.y, 0.1), snappedf(cam.far, 1.0), snappedf(cam.fov, 0.1)
		]
		return out
	var lights := {"omni": 0, "omni_on": 0, "spot": 0, "spot_on": 0, "dir": 0}
	var stack: Array[Node] = [cam.get_tree().root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if n is OmniLight3D:
			lights["omni"] += 1
			if (n as Light3D).is_visible_in_tree() and (n as Light3D).light_energy > 0.0:
				lights["omni_on"] += 1
		elif n is SpotLight3D:
			lights["spot"] += 1
			if (n as Light3D).is_visible_in_tree() and (n as Light3D).light_energy > 0.0:
				lights["spot_on"] += 1
		elif n is DirectionalLight3D:
			lights["dir"] += 1
			lights["dir_energy"] = snappedf((n as Light3D).light_energy, 0.01)
			lights["dir_shadow"] = (n as Light3D).shadow_enabled
	out["lights"] = lights
	return out


## The prototypes the street features and the city view offer (warm_prototypes), none without
## street mode.
static func _feature_prototypes(main: Node) -> Array[Node3D]:
	var out: Array[Node3D] = []
	var fp: Variant = main.get("fp")
	if fp == null or fp.ctx == null:
		return out
	for f: Variant in fp.ctx.features.values():
		out.append_array(f.warm_prototypes())
	var view: Variant = main.get("view")
	if view != null and view.has_method("warm_prototypes"):
		out.append_array(view.warm_prototypes())
	return out


## Draws every recipe in one state, a few copies a frame, until the budget in run_state is spent;
## returns the state's line of the report. A state is one pass or several joined with "+": each
## batch of copies is then drawn once per pass, so a material has all its programs before the next
## begins. The passes: "lit": the lamps' loops in the shaders; "unlit": none (the street's own);
## "noshadow": the sun's shadow held off (the overview, dusk and dawn); "orbit": the Planner's four
## shadow splits and fog; "prototypes": the things not in the scene yet, as "unlit". A state with
## "noshadow" or "orbit" in it takes the recipes biggest user first, the others nearest first.
static func _stage_state(
	main: Node,
	tree: SceneTree,
	stage: WarmStage,
	recipes: Array[Dictionary],
	state: String,
	run_state: Dictionary
) -> Dictionary:
	var passes := state.split("+")
	var list: Array[Dictionary] = recipes
	if "noshadow" in passes or "orbit" in passes:
		list = recipes.duplicate()
		list.sort_custom(
			func(a: Dictionary, b: Dictionary) -> bool: return int(a["n"]) > int(b["n"])
		)
	var holds: Dictionary = {}
	var stamp := FirstUse.begin("warm", state)
	var drawn := 0
	var frames := 0
	var state_ms := 0.0
	var batch := 1
	var i := 0
	while i < list.size():
		if not _veil_up():
			# The page lifted the veil under the warm-up (its timeout, a tab that was hidden): the
			# player is playing, so nothing more is drawn in front of them.
			run_state["cut"] = true
			run_state["veil_gone"] = true
			break
		if (
			float(Time.get_ticks_usec() - int(run_state["began"])) / 1000.0
			> float(run_state["budget_ms"])
		):
			run_state["cut"] = true
			break
		var left_ms := (
			float(run_state["budget_ms"])
			- float(Time.get_ticks_usec() - int(run_state["began"])) / 1000.0
		)
		batch = mini(batch, maxi(1, int(left_ms / COPY_GUESS_MS)))
		var t0 := Time.get_ticks_usec()
		drawn += stage.show_batch(list.slice(i, i + batch))
		i += batch
		for pass_name: String in passes:
			_enter_pass(main, stage, holds, pass_name)
			var f0 := Time.get_ticks_usec()
			await _frame(tree)
			var fms := float(Time.get_ticks_usec() - f0) / 1000.0
			frames += 1
			run_state["worst"] = maxf(float(run_state["worst"]), fms)
			if fms > SLOW_FRAME_MS:
				run_state["slow"] += 1
		stage.clear_batch()
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		state_ms += ms
		run_state["done"] += batch
		batch = _next_batch(batch, ms / float(passes.size()))
		var elapsed_ms := float(Time.get_ticks_usec() - int(run_state["began"])) / 1000.0
		var pct := progress_pct(
			int(run_state["done"]),
			int(run_state["total"]),
			elapsed_ms,
			float(run_state["budget_ms"])
		)
		WebSupport.boot_status("Preparing graphics %d%%" % pct)
	for h: WarmShadowHold in holds.values():
		h.stop()
	FirstUse.end("warm", state, stamp)
	return {"state": state, "drawn": drawn, "frames": frames, "ms": snappedf(state_ms, 0.1)}


## Puts the stage and the sun in the state of one pass: the lamps on or off, and the shadow or orbit
## hold started for it and stopped for the others.
static func _enter_pass(main: Node, stage: WarmStage, holds: Dictionary, pass_name: String) -> void:
	stage.set_lit(pass_name == "lit")
	for key: String in holds:
		if key != pass_name:
			(holds[key] as WarmShadowHold).stop()
	if pass_name == "noshadow" or pass_name == "orbit":
		if not holds.has(pass_name):
			holds[pass_name] = WarmShadowHold.new()
		(holds[pass_name] as WarmShadowHold).start(
			main.get("sun_light") as DirectionalLight3D,
			(stage.get_parent() as Camera3D).environment,
			pass_name
		)


## Opens the Tab overview for a few frames and closes it again, with the real feature: the view
## from the air shows the far trees, the aerial fog and shadows and puts every material into the
## renderer's other shader family (the one the first Tab used to stall for 0.9 to 1.7 s). Skipped
## (drawn 0) when there is no street mode or the overview may not open now.
static func _overview(main: Node, tree: SceneTree) -> Dictionary:
	var out := {"state": "overview", "drawn": 0, "frames": 0, "ms": 0.0, "slow": 0, "worst_ms": 0.0}
	var fp: Variant = main.get("fp")
	if fp == null or fp.ctx == null:
		return out
	var ov: Variant = fp.ctx.feature("overview")
	if ov == null or not ov.can_enter():
		return out
	var t0 := Time.get_ticks_usec()
	if not ov.enter():
		return out
	for _k in range(OVERVIEW_FRAMES):
		var f0 := Time.get_ticks_usec()
		await _frame(tree)
		var ms := float(Time.get_ticks_usec() - f0) / 1000.0
		out["frames"] += 1
		out["worst_ms"] = maxf(float(out["worst_ms"]), ms)
		if ms > SLOW_FRAME_MS:
			out["slow"] += 1
	ov.exit(0.0)
	await _frame(tree)
	out["drawn"] = 1
	out["ms"] = snappedf(float(Time.get_ticks_usec() - t0) / 1000.0, 0.1)
	return out


## The loader's percentage: the share of the work done or the share of the budget spent, whichever
## is further along, so a run that ends on its budget (most of them: a scene has more recipes than
## 3 s can draw) reaches 100% as the veil lifts, not the share of recipes it got to.
static func progress_pct(done: int, total: int, elapsed_ms: float, budget_ms: float) -> int:
	var work := float(done) / float(maxi(1, total))
	var time := elapsed_ms / maxf(1.0, budget_ms)
	return clampi(int(100.0 * maxf(work, time)), 0, 100)


## True while the loader's veil is up (the warm-up is only for behind it).
static func _veil_up() -> bool:
	return bool(veil_check.call()) if veil_check.is_valid() else WebSupport.veil_up()


## The next batch size: the cost of the copies so far scales it toward FRAME_TARGET_MS.
static func _next_batch(batch: int, ms: float) -> int:
	if ms < 1.0:
		return mini(MAX_BATCH, batch * 2)
	var per := ms / float(batch)
	return clampi(int(FRAME_TARGET_MS / per), 1, MAX_BATCH)


## One drawn frame (a rendered one in a window, a process frame headless).
static func _frame(tree: SceneTree) -> void:
	if DisplayServer.get_name() == "headless":
		await tree.process_frame
	else:
		await RenderingServer.frame_post_draw
