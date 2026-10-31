extends SceneTree
## The browser physics catch-up cap (Quality.cap_physics_steps): on the web the engine's max
## physics steps per frame drops to Quality.WEB_MAX_PHYSICS_STEPS, so a slow frame cannot add a
## multiple of the browser's 6-35 ms per-step cost while catching up; the desktop default stays
## untouched. The test forces the web path with the web argument; it also pins
## park_physics_server (web parks the empty physics space, desktop leaves it). The real-time pace
## flag (web_real_time_pace, off by default) raises the web cap to 4 at runtime and survives in the
## user flag file; Pacing.step_for bounds the catch-up loops. Headless, offline.
## Prints WEB_PACING_TEST: PASS|FAIL.

const Q := preload("res://scripts/fp/render/quality.gd")
const RENDER_OPT := preload("res://scripts/fp/render/render_opt_feature.gd")

const ENGINE_DEFAULT := 8

var fails: Array[String] = []


func check(ok: bool, what: String) -> void:
	print(("WEB_PACING_TEST:   ok   " if ok else "WEB_PACING_TEST:   FAIL ") + what)
	if not ok:
		fails.append(what)


func _init() -> void:
	await process_frame
	var before := Engine.max_physics_steps_per_frame
	check(Q.WEB_MAX_PHYSICS_STEPS < ENGINE_DEFAULT, "the cap is below the engine default")
	Engine.max_physics_steps_per_frame = ENGINE_DEFAULT
	Q.cap_physics_steps(true)
	check(
		Engine.max_physics_steps_per_frame == Q.WEB_MAX_PHYSICS_STEPS,
		"web: physics catch-up steps cap to %d" % Q.WEB_MAX_PHYSICS_STEPS
	)
	Engine.max_physics_steps_per_frame = ENGINE_DEFAULT
	Q.cap_physics_steps(false)
	check(Engine.max_physics_steps_per_frame == ENGINE_DEFAULT, "desktop: default kept")
	Q.physics_parked = false
	Q.park_physics_server(true)
	check(Q.physics_parked, "web: physics server parked (empty space)")
	Q.physics_parked = false
	Q.park_physics_server(false)
	check(not Q.physics_parked, "desktop: physics server left active")
	PhysicsServer3D.set_active(true)
	_check_real_time_pace()
	_check_pacing_steps()
	_check_saved_flag()
	Engine.max_physics_steps_per_frame = before
	await process_frame
	print("WEB_PACING_TEST: " + ("PASS" if fails.is_empty() else "FAIL " + str(fails)))
	quit(0 if fails.is_empty() else 1)


func _check_real_time_pace() -> void:
	var flag_before := FeatureFlags.enabled("web_real_time_pace", false)
	check(not bool(FeatureFlags.defaults().get("web_real_time_pace", true)), "the flag ships off")
	check(
		(
			Q.WEB_MAX_PHYSICS_STEPS < Q.WEB_MAX_PHYSICS_STEPS_REAL_TIME
			and Q.WEB_MAX_PHYSICS_STEPS_REAL_TIME < ENGINE_DEFAULT
		),
		"the real-time cap sits between the web cap and the engine default"
	)
	FeatureFlags.set_override("web_real_time_pace", false)
	Engine.max_physics_steps_per_frame = ENGINE_DEFAULT
	Q.cap_physics_steps(true)
	check(
		Engine.max_physics_steps_per_frame == Q.WEB_MAX_PHYSICS_STEPS, "flag off: web cap stays 2"
	)
	Q.set_real_time_pace(true, true, false)
	check(Q.real_time_pace(), "turned on at runtime")
	check(
		Engine.max_physics_steps_per_frame == Q.WEB_MAX_PHYSICS_STEPS_REAL_TIME,
		"on: the cap rises to %d this frame" % Q.WEB_MAX_PHYSICS_STEPS_REAL_TIME
	)
	Q.set_real_time_pace(false, true, false)
	check(Engine.max_physics_steps_per_frame == Q.WEB_MAX_PHYSICS_STEPS, "off again: back to 2")
	Engine.max_physics_steps_per_frame = ENGINE_DEFAULT
	Q.set_real_time_pace(true, false, false)
	check(Engine.max_physics_steps_per_frame == ENGINE_DEFAULT, "desktop: default left alone")
	FeatureFlags.set_override("web_real_time_pace", true)
	var feature = RENDER_OPT.new()
	feature._on_pace_requested(false)
	check(not Q.real_time_pace(), "the pause menu's request reaches the switch (bus handler)")
	feature.free()
	FeatureFlags.set_override("web_real_time_pace", flag_before)


func _check_pacing_steps() -> void:
	var step := 1.0 / 30.0
	check(is_equal_approx(Pacing.step_for(1.0 / 60.0, step), step), "a 60 Hz frame keeps the step")
	check(is_equal_approx(Pacing.step_for(0.3, step), step), "a 300 ms frame at 1x keeps the step")
	for dt: float in [0.5, 1.07, 4.0]:
		var h := Pacing.step_for(dt, step)
		var n := int(ceil(dt / h - 0.000001))
		check(n <= Pacing.MAX_STEPS_PER_FRAME, "dt %.2f s works off in %d steps" % [dt, n])
		check(h >= step, "dt %.2f s never shortens the step" % dt)


func _check_saved_flag() -> void:
	var path := "user://web_pacing_test_flags.json"
	check(FeatureFlags.save_user("web_real_time_pace", true, path), "the flag is written to a file")
	check(
		bool(FeatureFlags.read_user(path).get("web_real_time_pace", false)), "...and read back on"
	)
	FeatureFlags.save_user("web_real_time_pace", false, path)
	check(
		not bool(FeatureFlags.read_user(path).get("web_real_time_pace", true)), "...and off again"
	)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
