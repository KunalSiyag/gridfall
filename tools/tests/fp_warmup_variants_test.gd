extends SceneTree
## The web shader warm-up, round 2 (scripts/fp/warmup/, flags warmup_orbit_variants and
## web_shader_warmup): WarmCollector groups materials by shader variant (WarmSignature), the
## catalogue (data/warm_orbit_variants.json) holds the Planner's own materials, the stage draws its
## copies alone (isolate), the Planner states (orbit, orbitlit) and warm_orbit (behind the overlay)
## draw everything in the Planner's light and fog, and the flag off gives the old per-material
## warm-up. fp_warmup_test has the rest of the warm-up. Headless, offline. Prints
## FP_WARMUP_VARIANTS_TEST: PASS|FAIL.

const K := preload("res://tools/tests/fp_kit.gd")
const WK := preload("res://tools/tests/warm_kit.gd")
const TOKEN := "FP_WARMUP_VARIANTS_TEST"

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN, 120.0)
	await process_frame
	var flag_before := FeatureFlags.enabled(ShaderWarmup.FLAG, true)
	_check_variants()
	await _check_orbit_state()
	await _check_variants_flag_off()
	await _check_warm_orbit()
	await _check_isolation()
	await _check_veil_flash()
	_check_progress_clamp()
	FeatureFlags.set_override(ShaderWarmup.FLAG, flag_before)
	FeatureFlags.set_override(ShaderWarmup.VARIANT_FLAG, true)
	ShaderWarmup.force = false
	WK.clear_tuning()
	K.finish(self, TOKEN, fails)


## One recipe per shader variant: same-signature materials collapse, different ones do not, and the
## flag-off recipe count (a material each) is what it was.
func _check_variants() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	for k in 5:
		var hue := Color.from_hsv(k * 0.1, 1, 1)
		root.add_child(WK.mesh_inst(BoxMesh.new(), Vector3(k, 0, 0), WK.mat(hue)))
	root.add_child(WK.mesh_inst(BoxMesh.new(), Vector3(9, 0, 0), WK.mat(Color.RED, 1)))
	var cull := WK.mat(Color.RED)
	cull.cull_mode = BaseMaterial3D.CULL_DISABLED
	root.add_child(WK.mesh_inst(BoxMesh.new(), Vector3(10, 0, 0), cull))
	var textured := WK.mat(Color.RED)
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	textured.albedo_texture = ImageTexture.create_from_image(img)
	root.add_child(WK.mesh_inst(BoxMesh.new(), Vector3(11, 0, 0), textured))
	WarmCollector.by_variant = true
	var recipes := WarmCollector.collect(root, Vector3.ZERO)
	check(
		recipes.size() == 4,
		(
			"five colours, an alpha, a two-sided and a textured one are 4 variants (%d)"
			% recipes.size()
		)
	)
	var counted := 0
	for r: Dictionary in recipes:
		counted += int(r["n"])
	check(counted == 8, "every instance is still counted (%d)" % counted)
	WarmCollector.by_variant = false
	check(
		WarmCollector.collect(root, Vector3.ZERO).size() == 8,
		"by_variant off: a recipe per material instance, as before"
	)
	WarmCollector.by_variant = true
	# Colour, roughness and texture content never change the signature; a flag or enum does.
	var a := WK.mat(Color.RED)
	var b := WK.mat(Color.BLUE)
	b.roughness = 0.1
	check(WarmSignature.of(a) == WarmSignature.of(b), "colour and roughness are not part of it")
	b.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	WarmSignature.clear_cache()  # signatures are cached for one pass
	check(WarmSignature.of(a) != WarmSignature.of(b), "shading mode is")
	var sm := ShaderMaterial.new()
	sm.shader = Shader.new()
	check(WarmSignature.of(sm).begins_with("S:"), "a shader material is its shader")
	check(WarmSignature.of(null) == "null", "no material has a signature too")
	# describe -> build keeps the signature (the catalogue's round trip).
	var tri := WK.mat(Color.GREEN)
	tri.uv1_triplanar = true
	tri.normal_enabled = true
	tri.normal_texture = textured.albedo_texture
	tri.cull_mode = BaseMaterial3D.CULL_FRONT
	tri.texture_repeat = false
	var spec: Variant = WarmSignature.describe(tri)
	check(spec != null, "a standard material can be described")
	var rebuilt := WarmSignature.build(spec as Dictionary)
	check(
		rebuilt != null and WarmSignature.of(rebuilt) == WarmSignature.of(tri),
		"a rebuilt stand-in has the same signature (%s)" % str(WarmSignature.of(rebuilt)).left(80)
	)
	check(WarmSignature.describe(sm) == null, "a shader material with no path cannot be described")
	check(WarmSignature.build({"t": "nope"}) == null, "an unknown spec builds nothing")
	root.free()
	# The catalogue: the data file loads into recipes whose stand-ins have their recorded
	# signatures.
	var cat := WarmCollector.orbit_catalogue()
	check(cat.size() >= 1, "the Planner's catalogue is not empty (%d)" % cat.size())
	var text := FileAccess.get_file_as_string(WarmCollector.ORBIT_PATH)
	var json: Dictionary = JSON.parse_string(text)
	var sigs: Array = []
	for e: Dictionary in json["variants"]:
		sigs.append(e["sig"])
	var same := true
	for r: Dictionary in cat:
		same = same and WarmSignature.of(r["override"] as Material) in sigs
	check(same, "every stand-in has the signature the catalogue recorded")
	var big := true
	for k in range(1, cat.size()):
		big = big and int(cat[k - 1]["n"]) >= int(cat[k]["n"])
	check(big, "biggest user first")


## The Planner states: "orbit" holds four splits and exponential fog, "orbitlit" the same with the
## lamps on, and a run with one of them also draws the Planner's own recipes.
func _check_orbit_state() -> void:
	ShaderWarmup.force = true
	FeatureFlags.set_override(ShaderWarmup.FLAG, true)
	FeatureFlags.set_override(ShaderWarmup.VARIANT_FLAG, true)
	WK.write_tuning({"states": ["orbit+orbitlit"]})
	var m := WK.fake_main(get_root())
	m.sun_light = DirectionalLight3D.new()
	m.sun_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	m.add_child(m.sun_light)
	var env := Environment.new()
	env.fog_mode = Environment.FOG_MODE_DEPTH
	m.cam.environment = env
	await ShaderWarmup.run(m)
	var rep := ShaderWarmup.report
	var cat := WarmCollector.orbit_catalogue().size()
	var st: Array = rep["states"]
	check(
		int(rep["orbit_recipes"]) == cat and cat > 0,
		"an orbit state brings the catalogue (%d)" % int(rep.get("orbit_recipes", -1))
	)
	check(
		st.size() == 1 and int(st[0]["drawn"]) == int(rep["recipes"]) + cat,
		"it draws the scene's recipes and the catalogue (%s)" % str(st)
	)
	check(
		int(st[0]["frames"]) >= 2 * (int(rep["recipes"]) + cat) / ShaderWarmup.MAX_BATCH,
		"each batch twice, lamps off then on"
	)
	check(
		(
			m.sun_light.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
			and env.fog_mode == Environment.FOG_MODE_DEPTH
		),
		"the splits and the fog are back as they were"
	)
	check(m.cam.get_child_count() == 0, "the stage is gone")
	# The default states draw no Planner recipes.
	WK.write_tuning({"states": ["unlit"]})
	await ShaderWarmup.run(m)
	check(int(ShaderWarmup.report["orbit_recipes"]) == 0, "no orbit state: no catalogue")
	m.free()
	WK.clear_tuning()


## Flag warmup_orbit_variants off: a recipe per material, no catalogue, a grown scene is skipped.
func _check_variants_flag_off() -> void:
	ShaderWarmup.force = true
	FeatureFlags.set_override(ShaderWarmup.FLAG, true)
	FeatureFlags.set_override(ShaderWarmup.VARIANT_FLAG, false)
	WK.write_tuning({"states": ["orbit"], "large_scene_recipes": 3})
	var m := WK.fake_main(get_root())
	m.sun_light = DirectionalLight3D.new()
	m.add_child(m.sun_light)
	# The fixture's four materials have four signatures, so only the instance count can differ: add
	# five more of one kind, which collapse with the flag on and do not with it off.
	var extra := Node3D.new()
	for k in 5:
		var hue := Color.from_hsv(k * 0.1, 1, 1)
		extra.add_child(WK.mesh_inst(BoxMesh.new(), Vector3(k, 0, 0), WK.mat(hue, 2)))
	m.add_child(extra)
	await ShaderWarmup.run(m)
	var rep := ShaderWarmup.report
	check(
		rep.get("skipped", "") == "large_scene" and int(rep["recipes"]) == 9,
		"flag off: 9 per-material recipes over a limit of 3: skipped (%s)" % str(rep).left(100)
	)
	FeatureFlags.set_override(ShaderWarmup.VARIANT_FLAG, true)
	WK.write_tuning({"states": ["unlit"], "large_scene_recipes": 5})
	await ShaderWarmup.run(m)
	rep = ShaderWarmup.report
	check(
		not rep.has("skipped") and int(rep["recipes"]) == 4 and bool(rep["by_variant"]),
		"flag on: the same scene is 4 variants and is warmed (%s)" % str(rep).left(100)
	)
	m.free()
	WK.clear_tuning()


## warm_orbit (the Planner's own warm-up behind the overlay) draws everything in the Planner's
## state, reports its progress before each frame, never goes back, and leaves the scene as it found
## it.
func _check_warm_orbit() -> void:
	var m := WK.fake_main(get_root())
	m.sun_light = DirectionalLight3D.new()
	m.add_child(m.sun_light)
	var seen: Array[int] = []
	var sink := func(pct: int, _done: int, _total: int) -> void: seen.append(pct)
	var rep := await ShaderWarmup.warm_orbit(m, sink)
	check(not rep.is_empty() and int(rep["orbit_recipes"]) > 0, "warm_orbit reports its recipes")
	var line: Dictionary = rep["state"]
	check(
		int(line["drawn"]) == int(rep["recipes"]) + int(rep["orbit_recipes"]),
		"it draws the scene and the catalogue (%s)" % str(line)
	)
	var mono := not seen.is_empty()
	for k in range(1, seen.size()):
		mono = mono and seen[k] >= seen[k - 1]
	check(
		mono and seen[0] < 100,
		"progress starts below 100, never goes back (%s)" % str(seen).left(50)
	)
	check(seen[-1] >= 90, "and ends near 100 (%d)" % seen[-1])
	check(m.cam.get_child_count() == 0, "no stage left under the camera")
	check(not bool(rep["cut"]), "within the ceiling nothing is cut")
	check(
		line["state"] == "orbit", "no lamp is on: one pass, the Planner by day (%s)" % line["state"]
	)
	var lamp := OmniLight3D.new()
	lamp.light_energy = 1.0
	m.add_child(lamp)
	var lit := await ShaderWarmup.warm_orbit(m, sink)
	check(lit["state"]["state"] == "orbitlit", "a lamp is on: the Planner by night (orbitlit)")
	check(
		int(lit["state"]["frames"]) <= 2 * int(lit["state"]["drawn"]),
		"and still one pass, not both (%s)" % str(lit["state"])
	)
	m.free()


## The stage draws the copies alone: camera and sun look at the stage's layer while it isolates, and
## both are back as they were after release(), after the stage leaves the tree, and after a run.
func _check_isolation() -> void:
	var cam := Camera3D.new()
	get_root().add_child(cam)
	var sun := DirectionalLight3D.new()
	cam.add_child(sun)
	cam.cull_mask = 12345
	sun.light_cull_mask = 54321
	var stage := WarmStage.new()
	stage.attach(cam)
	stage.isolate(sun)
	check(
		stage.is_isolating() and cam.cull_mask == WarmStage.ISOLATE_LAYER,
		"isolate(): the camera sees the stage's layer only"
	)
	check(sun.light_cull_mask == WarmStage.ISOLATE_LAYER, "and so does the sun")
	check(
		(sun.layers & WarmStage.ISOLATE_LAYER) != 0 and (sun.layers & 1) != 0,
		"the sun joins the stage's layer (a camera's mask culls lights too) and keeps its own"
	)
	check(
		(
			stage.omni.layers == WarmStage.ISOLATE_LAYER
			and stage.spot.layers == WarmStage.ISOLATE_LAYER
		),
		"the stage's lamps are on it"
	)
	stage.isolate(sun)
	stage.release()
	check(
		cam.cull_mask == 12345 and sun.light_cull_mask == 54321 and not stage.is_isolating(),
		"release(): both masks are back (a second isolate() changed nothing)"
	)
	check(sun.layers == 1, "and the sun's own layers")
	stage.release()
	check(cam.cull_mask == 12345, "a second release() does nothing")
	var copies := stage.show_batch(WarmCollector.orbit_catalogue().slice(0, 2))
	var on_layer := true
	for c: Node in stage.get_children():
		if c is GeometryInstance3D:
			on_layer = on_layer and (c as GeometryInstance3D).layers == WarmStage.ISOLATE_LAYER
	check(copies == 2 and on_layer, "the copies live on the stage's layer")
	stage.isolate(sun)
	cam.remove_child(stage)
	check(cam.cull_mask == 12345 and sun.light_cull_mask == 54321, "leaving the tree releases it")
	stage.free()
	# A run isolates and gives everything back.
	ShaderWarmup.force = true
	FeatureFlags.set_override(ShaderWarmup.FLAG, true)
	FeatureFlags.set_override(ShaderWarmup.VARIANT_FLAG, true)
	WK.write_tuning({"states": ["unlit", "noshadow"]})
	var m := WK.fake_main(get_root())
	m.sun_light = DirectionalLight3D.new()
	m.add_child(m.sun_light)
	m.cam.cull_mask = 777
	m.sun_light.light_cull_mask = 888
	await ShaderWarmup.run(m)
	check(
		m.cam.cull_mask == 777 and m.sun_light.light_cull_mask == 888,
		"run() leaves the camera and sun masks as it found them"
	)
	FeatureFlags.set_override(ShaderWarmup.VARIANT_FLAG, false)
	await ShaderWarmup.run(m)
	check(
		m.cam.cull_mask == 777 and m.sun_light.light_cull_mask == 888,
		"flag off: the same, and the stage never isolated"
	)
	FeatureFlags.set_override(ShaderWarmup.VARIANT_FLAG, true)
	m.free()
	cam.free()
	WK.clear_tuning()


var _veil := true
var _seen_isolating := true
var _seen_mask := 0


func _veil_now() -> bool:
	return _veil


## The veil lifted while a warm-up frame is pending (the page's timeout, a hidden tab): the stage's
## masks must be back BEFORE that frame is drawn, or the player sees one frame of empty sky. The
## probe below is connected after the guard, so it sees what the frame's draw would.
func _check_veil_flash() -> void:
	var cam := Camera3D.new()
	cam.cull_mask = 4242
	get_root().add_child(cam)
	var sun := DirectionalLight3D.new()
	cam.add_child(sun)
	var stage := WarmStage.new()
	stage.attach(cam)
	stage.isolate(sun)
	ShaderWarmup.veil_check = _veil_now
	for lifted in [false, true]:
		_veil = true
		stage.isolate(sun)
		_start_frame(stage, true)
		_veil = not lifted
		_seen_isolating = true
		_seen_mask = -1
		get_root().get_tree().process_frame.connect(_probe.bind(stage, cam), CONNECT_ONE_SHOT)
		await process_frame
		await process_frame
		if lifted:
			check(
				not _seen_isolating,
				"veil lifted under the frame: the masks are back before it draws"
			)
			check(_seen_mask == 4242, "and the camera sees what it saw (%d)" % _seen_mask)
		else:
			check(_seen_isolating, "veil still up: the stage stays isolated for the frame")
		stage.release()
	# Not behind the veil (the Planner warm-up's own overlay): never unmasked.
	_veil = false
	stage.isolate(sun)
	_start_frame(stage, false)
	_seen_isolating = false
	get_root().get_tree().process_frame.connect(_probe.bind(stage, cam), CONNECT_ONE_SHOT)
	await process_frame
	await process_frame
	check(_seen_isolating, "not behind the veil: the guard stays out of it")
	stage.release()
	ShaderWarmup.veil_check = Callable()
	cam.remove_child(stage)
	stage.free()
	cam.free()


## Starts a stage frame without waiting for it (the test watches what the frame's draw would see).
func _start_frame(stage: WarmStage, behind_veil: bool) -> void:
	var tree := get_root().get_tree()
	var go := func() -> void: await ShaderWarmup._stage_frame(tree, stage, behind_veil)
	go.call()


func _probe(stage: WarmStage, cam: Camera3D) -> void:
	_seen_isolating = stage.is_isolating()
	_seen_mask = cam.cull_mask


## The loader's percentage never goes back, even when the plan's own estimate does (a slow item
## late in the run makes the budget pay for fewer items): the reported value is clamped.
func _check_progress_clamp() -> void:
	var sent: Array[int] = []
	var sink := func(pct: int, _d: int, _t: int) -> void: sent.append(pct)
	var run_state := {
		"began": Time.get_ticks_usec(),
		"budget_ms": 3000.0,
		"done": 2,
		"total": 10,
		"pct": 70,
		"progress": sink,
	}
	# 2 of 10 would read 20%, the run had already said 70.
	ShaderWarmup._report_progress(run_state, 0.0, 0)
	check(
		sent == [70] and int(run_state["pct"]) == 70,
		"progress below what was said is held (%s)" % str(sent)
	)
	run_state["done"] = 9
	ShaderWarmup._report_progress(run_state, 0.0, 0)
	check(
		sent[-1] == 90 and int(run_state["pct"]) == 90,
		"and forward progress goes through (%s)" % str(sent)
	)
