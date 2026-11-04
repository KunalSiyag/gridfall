extends SceneTree
## The web shader warm-up (scripts/fp/warmup/, flag web_shader_warmup): WarmCollector finds the
## distinct draws of a scene (one recipe per material set, instancing and shadow setting, the
## lightest mesh of each, nearest first, empty nodes left out, the stage
## skipped), WarmStage puts a tiny copy of a recipe in front of the camera and frees it, and
## ShaderWarmup.run() draws every recipe under both lighting families in batches, leaves the scene
## as it found it (no stage, no lights, the camera's children as before) and prints one WARMUP
## report line. Off the web, or with the flag off, it does nothing at all; a spent budget leaves
## the rest lazy. BootClock.finish() awaits the hook after the first frame and before the veil
## frames, and Main passes ShaderWarmup.run. Headless, offline. Prints FP_WARMUP_TEST: PASS|FAIL.

const K := preload("res://tools/tests/fp_kit.gd")
const BEACONS := preload("res://scripts/fp/activity/activity_beacons.gd")
const TOKEN := "FP_WARMUP_TEST"
const TUNING := "user://warmup_tuning.json"

var fails: Array[String] = []


class FakeOverview:
	extends RefCounted
	var open := false
	var enters := 0
	var exits := 0
	var may := true

	func can_enter() -> bool:
		return may and not open

	func enter() -> bool:
		open = true
		enters += 1
		return true

	func exit(_blend: float = 0.0) -> void:
		open = false
		exits += 1


class FakeFeature:
	extends RefCounted
	var made: Array[Node3D] = []

	func warm_prototypes() -> Array[Node3D]:
		var n := Node3D.new()
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new()
		mi.material_override = StandardMaterial3D.new()
		n.add_child(mi)
		made.append(n)
		return [n]


class FakeCtx:
	extends RefCounted
	var ov := FakeOverview.new()
	var features: Dictionary = {}

	func feature(id: String) -> Variant:
		return ov if id == "overview" else null


class FakeFp:
	extends RefCounted
	var ctx := FakeCtx.new()


class FakeMain:
	extends Node3D
	var cam: Camera3D
	var fp: Variant = null
	var sun_light: DirectionalLight3D

	func active_camera() -> Camera3D:
		return cam


## Collects every printed line (a Logger sees print()).
class Console:
	extends Logger
	var lines: Array[String] = []

	func _log_message(message: String, error: bool) -> void:
		if not error:
			lines.append(message.strip_edges())


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN, 120.0)
	await process_frame
	var flag_before := FeatureFlags.enabled(ShaderWarmup.FLAG, true)
	_check_flag()
	_check_collector()
	_check_stage()
	await _check_run()
	await _check_overview()
	await _check_noshadow()
	await _check_prototypes()
	await _check_flag_off()
	await _check_budget()
	await _check_veil()
	await _check_large_scene()
	_check_progress()
	await _check_boot_hook()
	_check_call_sites()
	FeatureFlags.set_override(ShaderWarmup.FLAG, flag_before)
	ShaderWarmup.force = false
	_clear_tuning()
	K.finish(self, TOKEN, fails)


func _clear_tuning() -> void:
	if FileAccess.file_exists(TUNING):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TUNING))


func _write_tuning(d: Dictionary) -> void:
	var f := FileAccess.open(TUNING, FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()


func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	return m


func _mesh_inst(mesh: Mesh, pos: Vector3, mat: Material = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	if mat != null:
		mi.material_override = mat
	return mi


## A scene with known recipes: a shared material on a small and a big box (one recipe, the small
## mesh wins), the same material on a MultiMesh (its own recipe), a second material, a skinned mesh
## and an empty node (no recipe).
func _scene() -> Dictionary:
	var root := Node3D.new()
	var red := _mat(Color.RED)
	var blue := _mat(Color.BLUE)
	var small := BoxMesh.new()
	small.size = Vector3.ONE
	small.material = red
	var big := SphereMesh.new()
	big.material = red
	var a := _mesh_inst(small, Vector3(10, 0, 0))
	var b := _mesh_inst(big, Vector3(2, 0, 0))
	var c := _mesh_inst(BoxMesh.new(), Vector3(30, 0, 0), blue)
	var skinned := _mesh_inst(BoxMesh.new(), Vector3.ZERO, _mat(Color.GREEN))
	skinned.skin = Skin.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = small
	mm.instance_count = 3
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.position = Vector3(5, 0, 0)
	for n: Node in [a, b, c, skinned, mmi, Node3D.new(), MeshInstance3D.new()]:
		root.add_child(n)
	return {
		"root": root,
		"a": a,
		"b": b,
		"c": c,
		"mmi": mmi,
		"red": red,
		"blue": blue,
		"small": small,
		"big": big
	}


func _check_flag() -> void:
	check(bool(FeatureFlags.defaults().get(ShaderWarmup.FLAG, false)), "the flag ships on")
	ShaderWarmup.force = false
	check(not ShaderWarmup.active(), "the desktop build is never active")
	ShaderWarmup.force = true
	FeatureFlags.set_override(ShaderWarmup.FLAG, true)
	check(ShaderWarmup.active(), "web (forced) with the flag on is active")
	FeatureFlags.set_override(ShaderWarmup.FLAG, false)
	check(not ShaderWarmup.active(), "the flag off turns it off")
	FeatureFlags.set_override(ShaderWarmup.FLAG, true)


func _check_collector() -> void:
	var s := _scene()
	var root: Node3D = s["root"]
	root.name = "ScanRoot"
	get_root().add_child(root)
	var recipes := WarmCollector.collect(root, Vector3.ZERO)
	# red (mesh), red (multimesh), blue (mesh), green (skinned mesh): the empty nodes have none.
	check(
		recipes.size() == 4,
		(
			"four recipes: a material, the same on a MultiMesh, two other materials (%d)"
			% recipes.size()
		)
	)
	var plain_red: Dictionary = {}
	var multi: Dictionary = {}
	for r: Dictionary in recipes:
		if bool(r["multi"]):
			multi = r
		elif r["override"] == s["red"]:
			plain_red = r
	check(
		not plain_red.is_empty() and plain_red["override"] == s["red"],
		"a material is one recipe whatever meshes carry it"
	)
	check(int(plain_red.get("n", 0)) == 2, "it counts both instances that use it")
	check(not multi.is_empty() and int(multi["n"]) == 1, "the MultiMesh is its own recipe")
	check(
		is_equal_approx(float(plain_red["dist"]), 2.0),
		"its distance is the nearest instance's (%s)" % str(plain_red.get("dist"))
	)
	check(
		(
			float(recipes[0]["dist"]) <= float(recipes[1]["dist"])
			and float(recipes[1]["dist"]) <= float(recipes[2]["dist"])
			and float(recipes[2]["dist"]) <= float(recipes[3]["dist"])
		),
		"nearest first"
	)
	var shadow_off := _mesh_inst(s["small"] as Mesh, Vector3(40, 0, 0))
	shadow_off.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(shadow_off)
	check(
		WarmCollector.collect(root, Vector3.ZERO).size() == 5,
		"the shadow setting separates combinations"
	)
	check(WarmCollector.collect(root, Vector3.ZERO, 2).size() == 2, "the cap truncates the list")
	check(
		WarmCollector.collect(root, Vector3.ZERO, 10, [shadow_off]).size() == 4,
		"skipped nodes are left out"
	)
	root.free()


func _check_stage() -> void:
	var s := _scene()
	var root: Node3D = s["root"]
	get_root().add_child(root)
	var cam := Camera3D.new()
	get_root().add_child(cam)
	var recipes := WarmCollector.collect(root, Vector3.ZERO)
	var stage := WarmStage.new()
	stage.attach(cam)
	check(
		stage.get_parent() == cam and absf(stage.position.z + WarmStage.DEPTH) < 0.001,
		"the stage sits in front of the camera"
	)
	check(not stage.omni.visible and not stage.spot.visible, "its lamps start off")
	stage.set_lit(true)
	check(stage.omni.visible and stage.spot.visible, "set_lit(true) turns both lamps on")
	check(
		not stage.omni.shadow_enabled and not stage.spot.shadow_enabled, "the lamps cast no shadows"
	)
	var made := stage.show_batch(recipes)
	check(made == recipes.size() and stage.count == made, "every recipe gets a copy")
	var multis := 0
	var plains := 0
	for ch: Node in stage.get_children():
		if ch is MultiMeshInstance3D:
			multis += 1
			check(
				(ch as MultiMeshInstance3D).multimesh.instance_count == 1,
				"a MultiMesh copy has one instance"
			)
		elif ch is MeshInstance3D:
			plains += 1
			check(is_equal_approx((ch as Node3D).scale.x, WarmStage.SCALE), "a copy is shrunk")
	check(
		multis == 1 and plains == 3,
		"the copies keep their kind (%d multi, %d plain)" % [multis, plains]
	)
	stage.clear_batch()
	check(
		stage.count == 0 and stage.get_child_count() == 2,
		"clear_batch frees the copies and keeps the lamps"
	)
	stage.set_lit(false)
	cam.remove_child(stage)
	stage.free()
	cam.free()
	root.free()


func _fake_main(with_cam: bool = true) -> FakeMain:
	var m := FakeMain.new()
	m.name = "FakeMain"
	get_root().add_child(m)
	var s := _scene()
	m.add_child(s["root"] as Node)
	if with_cam:
		m.cam = Camera3D.new()
		m.add_child(m.cam)
	return m


func _check_run() -> void:
	ShaderWarmup.force = true
	FeatureFlags.set_override(ShaderWarmup.FLAG, true)
	_write_tuning({"states": ["lit", "unlit"]})
	var console := Console.new()
	OS.add_logger(console)
	var m := _fake_main()
	var before := m.cam.get_child_count()
	var frames_before := Engine.get_process_frames()
	await ShaderWarmup.run(m)
	var frames_spent := Engine.get_process_frames() - frames_before
	OS.remove_logger(console)
	var rep := ShaderWarmup.report
	check(not rep.is_empty() and int(rep["recipes"]) == 4, "run() reports the recipes it found")
	var states: Array = rep["states"]
	check(
		states.size() == 2 and states[0]["state"] == "lit" and states[1]["state"] == "unlit",
		"both lighting families are drawn, lit first"
	)
	check(
		int(states[0]["drawn"]) == 4 and int(states[1]["drawn"]) == 4,
		"every recipe is drawn under each"
	)
	check(not bool(rep["cut"]), "within budget nothing is cut")
	var drawn_frames := int(states[0]["frames"]) + int(states[1]["frames"])
	check(
		drawn_frames >= 4 and frames_spent >= drawn_frames,
		(
			"every batch is given a frame to draw in (%d frames for %d batches)"
			% [frames_spent, drawn_frames]
		)
	)
	check(
		m.cam.get_child_count() == before, "the camera's children are as before (the stage is gone)"
	)
	var lamps := 0
	var stack: Array[Node] = [get_root()]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if n.name == "ShaderWarmupStage":
			lamps += 1
	check(lamps == 0, "no stage or lamp is left in the tree")
	var line := ""
	for l in console.lines:
		if l.begins_with(ShaderWarmup.REPORT_PREFIX):
			line = l
	var parsed: Variant = (
		JSON.parse_string(line.trim_prefix(ShaderWarmup.REPORT_PREFIX))
		if not line.is_empty()
		else null
	)
	check(
		(
			typeof(parsed) == TYPE_DICTIONARY
			and int((parsed as Dictionary)["v"]) == ShaderWarmup.REPORT_VERSION
		),
		"one WARMUP line carries the report as JSON"
	)
	check(
		rep.has("render") and (rep["render"] as Dictionary).has("scale"),
		"the report says what the renderer was told"
	)
	m.free()
	_clear_tuning()
	check(
		ShaderWarmup.tuning()["states"] == ["prototypes", "unlit+noshadow"],
		"the default states: the prototypes, then the street pass and the no-shadow one"
	)


func _check_prototypes() -> void:
	var recipes := WarmCollector.prototypes()
	var mats := 0
	var scenes := 0
	for r: Dictionary in recipes:
		if str(r["key"]).contains("res://"):
			mats += 1
		else:
			scenes += 1
	check(
		mats >= 1 and scenes >= 1,
		"data/warm_prototypes.json gives materials and model draws (%d, %d)" % [mats, scenes]
	)
	var node := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	mi.material_override = StandardMaterial3D.new()
	node.add_child(mi)
	var extra: Array[Node3D] = [node]
	var with_extra := WarmCollector.prototypes(extra)
	check(with_extra.size() == recipes.size() + 1, "a feature's prototype adds its draws")
	check(not is_instance_valid(node), "and the prototype node is freed")
	var bare_feature := FpFeature.new()
	check(bare_feature.warm_prototypes().is_empty(), "a feature offers none by default")
	bare_feature.free()
	var beacons := BEACONS.new()
	var proto := beacons.warm_prototype()
	check(
		proto.get_node_or_null("Beam") != null and proto.get_node_or_null("Ring") != null,
		"the beacon prototype has its beam and ring"
	)
	proto.free()
	beacons.free()
	ShaderWarmup.force = true
	FeatureFlags.set_override(ShaderWarmup.FLAG, true)
	_write_tuning({"states": ["prototypes"]})
	var m := _fake_main()
	m.fp = FakeFp.new()
	var feat := FakeFeature.new()
	m.fp.ctx.features = {"fake": feat}
	await ShaderWarmup.run(m)
	var st: Array = ShaderWarmup.report["states"]
	check(
		st.size() == 1 and st[0]["state"] == "prototypes" and int(st[0]["drawn"]) >= 3,
		"the prototypes state draws them (%s)" % str(st)
	)
	check(
		feat.made.size() == 1 and not is_instance_valid(feat.made[0]),
		"the feature's prototype was freed after"
	)
	m.free()
	_clear_tuning()


func _check_noshadow() -> void:
	ShaderWarmup.force = true
	FeatureFlags.set_override(ShaderWarmup.FLAG, true)
	_write_tuning({"states": ["noshadow"]})
	var m := _fake_main()
	m.sun_light = DirectionalLight3D.new()
	m.sun_light.shadow_enabled = true
	m.add_child(m.sun_light)
	await ShaderWarmup.run(m)
	var st: Array = ShaderWarmup.report["states"]
	check(
		st.size() == 1 and st[0]["state"] == "noshadow" and int(st[0]["drawn"]) == 4,
		"the no-shadow state draws every recipe"
	)
	check(m.sun_light.shadow_enabled, "the sun's shadow is back on afterwards")
	_write_tuning({"states": ["unlit+noshadow"]})
	await ShaderWarmup.run(m)
	st = ShaderWarmup.report["states"]
	check(
		(
			st.size() == 1
			and int(st[0]["drawn"]) == 4
			and int(st[0]["frames"]) >= 4
			and int(st[0]["frames"]) % 2 == 0
		),
		"a joined state draws each batch once per pass (%s)" % str(st)
	)
	check(m.sun_light.shadow_enabled, "and the sun is as it was")
	m.free()
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	var hold := WarmShadowHold.new()
	hold.start(sun)
	check(hold.is_holding() and not sun.shadow_enabled, "a hold turns the shadow off")
	sun.shadow_enabled = true
	hold._apply()
	check(not sun.shadow_enabled, "and writes it off again before each draw")
	hold.start(sun)
	hold.stop()
	check(
		not hold.is_holding() and sun.shadow_enabled,
		"stop() puts the value back, a second start did nothing"
	)
	hold.stop()
	var env := Environment.new()
	env.fog_mode = Environment.FOG_MODE_DEPTH
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	var orbit := WarmShadowHold.new()
	orbit.start(sun, env, "orbit")
	check(
		(
			sun.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
			and env.fog_mode == Environment.FOG_MODE_EXPONENTIAL
		),
		"an orbit hold sets four splits and exponential fog"
	)
	check(sun.shadow_enabled, "and leaves the shadow on")
	orbit.stop()
	check(
		(
			sun.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
			and env.fog_mode == Environment.FOG_MODE_DEPTH
		),
		"stop() restores the splits and the fog"
	)
	hold.start(null)
	check(not hold.is_holding(), "a hold with no sun does nothing")
	sun.free()
	_clear_tuning()


func _check_overview() -> void:
	ShaderWarmup.force = true
	FeatureFlags.set_override(ShaderWarmup.FLAG, true)
	_write_tuning({"states": ["overview"]})
	var m := _fake_main()
	m.fp = FakeFp.new()
	var ov: FakeOverview = m.fp.ctx.ov
	await ShaderWarmup.run(m)
	check(
		ov.enters == 1 and ov.exits == 1 and not ov.open,
		"the overview is opened once and closed again"
	)
	var st: Array = ShaderWarmup.report["states"]
	check(
		(
			st.size() == 1
			and st[0]["state"] == "overview"
			and int(st[0]["frames"]) == ShaderWarmup.OVERVIEW_FRAMES
		),
		"it is held for its frames and reported"
	)
	ov.may = false
	await ShaderWarmup.run(m)
	check(
		ov.enters == 1 and int(ShaderWarmup.report["states"][0]["drawn"]) == 0,
		"an overview that may not open is skipped"
	)
	m.fp = null
	await ShaderWarmup.run(m)
	check(int(ShaderWarmup.report["states"][0]["drawn"]) == 0, "no street mode: skipped")
	m.free()
	_clear_tuning()


func _check_flag_off() -> void:
	FeatureFlags.set_override(ShaderWarmup.FLAG, false)
	var m := _fake_main()
	var before := m.cam.get_child_count()
	await ShaderWarmup.run(m)
	check(ShaderWarmup.report.is_empty(), "flag off: no report")
	check(m.cam.get_child_count() == before, "flag off: nothing is added to the camera")
	ShaderWarmup.force = false
	FeatureFlags.set_override(ShaderWarmup.FLAG, true)
	await ShaderWarmup.run(m)
	check(ShaderWarmup.report.is_empty(), "off the web: no report")
	m.free()
	ShaderWarmup.force = true
	var bare := FakeMain.new()
	get_root().add_child(bare)
	await ShaderWarmup.run(bare)
	check(ShaderWarmup.report.is_empty(), "no camera: it returns at once")
	bare.free()


func _check_budget() -> void:
	ShaderWarmup.force = true
	FeatureFlags.set_override(ShaderWarmup.FLAG, true)
	_write_tuning({"budget_ms": 0.0, "states": ["unlit"]})
	var m := _fake_main()
	await ShaderWarmup.run(m)
	check(bool(ShaderWarmup.report["cut"]), "a spent budget cuts the run")
	check(
		(
			(ShaderWarmup.report["states"] as Array).is_empty()
			or int((ShaderWarmup.report["states"] as Array)[0]["drawn"]) == 0
		),
		"a cut at the start draws nothing"
	)
	m.free()
	_write_tuning({"states": ["unlit"], "max_recipes": 1})
	var m2 := _fake_main()
	await ShaderWarmup.run(m2)
	check(
		(
			int(ShaderWarmup.report["recipes"]) == 1
			and (ShaderWarmup.report["states"] as Array).size() == 1
		),
		"tuning picks the states and the recipe cap"
	)
	m2.free()
	_clear_tuning()
	check(ShaderWarmup._next_batch(1, 0.5) == 2, "a free batch doubles")
	check(ShaderWarmup._next_batch(4, 2000.0) == 1, "a slow batch shrinks to one")
	check(
		ShaderWarmup._next_batch(2, 1.0) == ShaderWarmup.MAX_BATCH,
		"a cheap copy fills the batch up to the cap"
	)


## The loader's veil going away (its timeout, a hidden tab) stops the warm-up: nothing is drawn in
## front of the player, the sun's shadow is back and the stage is gone.
func _check_veil() -> void:
	ShaderWarmup.force = true
	FeatureFlags.set_override(ShaderWarmup.FLAG, true)
	check(WebSupport.veil_up(), "off the web nothing says the veil is gone")
	ShaderWarmup.veil_check = func() -> bool: return false
	var m := _fake_main()
	m.sun_light = DirectionalLight3D.new()
	m.sun_light.shadow_enabled = true
	m.add_child(m.sun_light)
	var before := m.cam.get_child_count()
	await ShaderWarmup.run(m)
	check(
		(
			ShaderWarmup.report.get("skipped", "") == "veil_gone"
			and not ShaderWarmup.report.has("states")
		),
		"a veil that is already gone: no warm-up at all (%s)" % str(ShaderWarmup.report)
	)
	check(m.cam.get_child_count() == before, "and no stage was built")
	# The veil goes after the first batch of the shadow-off pass has been drawn.
	_write_tuning({"states": ["unlit+noshadow"]})
	var seen := [0]
	ShaderWarmup.veil_check = func() -> bool:
		seen[0] += 1
		return seen[0] <= 3
	await ShaderWarmup.run(m)
	var rep := ShaderWarmup.report
	check(bool(rep.get("veil_gone", false)) and bool(rep["cut"]), "a veil lifted mid-run cuts it")
	var drawn := 0
	for st: Dictionary in rep["states"]:
		drawn += int(st["drawn"])
	check(drawn > 0 and drawn < 4, "after some copies and before the rest (%d of 4)" % drawn)
	check(m.sun_light.shadow_enabled, "the sun's shadow is back on")
	check(m.cam.get_child_count() == before, "and the stage is gone")
	ShaderWarmup.veil_check = Callable()
	m.free()
	_clear_tuning()


## A grown city's scene (many recipes) is not warmed: the report says so and nothing is drawn.
func _check_large_scene() -> void:
	ShaderWarmup.force = true
	FeatureFlags.set_override(ShaderWarmup.FLAG, true)
	check(
		int(ShaderWarmup.tuning()["large_scene_recipes"]) == ShaderWarmup.LARGE_SCENE_RECIPES,
		"the default size that counts as large"
	)
	check(
		ShaderWarmup.LARGE_SCENE_RECIPES > 190 and ShaderWarmup.LARGE_SCENE_RECIPES < 1575,
		"between a new city (190 recipes) and a grown one (1,575)"
	)
	_write_tuning({"large_scene_recipes": 3, "states": ["unlit"]})
	var m := _fake_main()
	var before := m.cam.get_child_count()
	await ShaderWarmup.run(m)
	var rep := ShaderWarmup.report
	check(
		rep.get("skipped", "") == "large_scene" and int(rep["recipes"]) == 4,
		"4 recipes over a limit of 3: skipped (%s)" % str(rep)
	)
	check(not rep.has("states") and m.cam.get_child_count() == before, "nothing is drawn")
	_write_tuning({"large_scene_recipes": 4, "states": ["unlit"]})
	await ShaderWarmup.run(m)
	check(
		not ShaderWarmup.report.has("skipped") and ShaderWarmup.report.has("states"),
		"at the limit it still runs"
	)
	m.free()
	_clear_tuning()


func _check_progress() -> void:
	var f := ShaderWarmup.progress_pct
	check(f.call(3, 10, 0.0, 3000.0) == 30, "the share of the work done")
	check(f.call(3, 10, 3000.0, 3000.0) == 100, "a spent budget is 100% whatever was done")
	check(f.call(3, 10, 1500.0, 3000.0) == 50, "or the share of it, if that is further on")
	check(f.call(10, 10, 100.0, 3000.0) == 100, "all the work is 100%")
	check(
		f.call(0, 0, 0.0, 0.0) == 0 and f.call(5, 1, 9.0e9, 1.0) == 100,
		"clamped and never divides by 0"
	)
	var last := 0
	var mono := true
	for k in range(0, 31):
		var p: int = f.call(k, 40, float(k) * 100.0, 3000.0)
		mono = mono and p >= last
		last = p
	check(mono and last == 100, "it never goes back and ends at 100")


func _check_boot_hook() -> void:
	OS.set_environment(BootClock.ENV, "1")
	BootClock.reset()
	var order: Array[String] = []
	var hook := func() -> void:
		order.append(
			(
				"hook:"
				+ str(BootClock.names().has("first_frame"))
				+ ":"
				+ str(BootClock.names().has("veil_frames"))
			)
		)
		await process_frame
	BootClock.mark("ready_begin")
	await BootClock.finish(self, hook)
	while not BootClock.completed():
		await process_frame
	check(order.size() == 1, "finish() awaits the hook once")
	check(
		order.size() == 1 and order[0] == "hook:true:false",
		"the hook runs after the first frame and before the veil frames (%s)" % str(order)
	)
	var names := BootClock.names()
	check(names.find("veil_frames") > names.find("first_frame"), "the veil frames still come after")
	BootClock.reset()
	OS.unset_environment(BootClock.ENV)


func _check_call_sites() -> void:
	var main_src := FileAccess.get_file_as_string("res://scripts/main.gd")
	var hook := main_src.find("BootClock.finish(get_tree(), ShaderWarmup.run.bind(self))")
	var ready := main_src.find("func _ready()")
	check(
		hook > ready and ready >= 0 and main_src.find("\nfunc ", ready + 5) > hook,
		"Main's _ready hands the warm-up to BootClock.finish"
	)
	var html := FileAccess.get_file_as_string("res://tools/web_export.py")
	check(
		html.contains("window.gfBootStatus") and html.contains("window.gfVeilUp"),
		"the loader page defines the status and veil hooks the warm-up calls"
	)
