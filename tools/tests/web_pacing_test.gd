extends SceneTree
## The browser physics catch-up cap (Quality.cap_physics_steps): on the web the engine's max
## physics steps per frame drops to Quality.WEB_MAX_PHYSICS_STEPS, so a slow frame cannot add a
## multiple of the browser's 6-35 ms per-step cost while catching up; the desktop default stays
## untouched. The test forces the web path with the web argument; it also pins
## park_physics_server (web parks the empty physics space, desktop leaves it). Headless, offline.
## Prints WEB_PACING_TEST: PASS|FAIL.

const Q := preload("res://scripts/fp/render/quality.gd")

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
	Engine.max_physics_steps_per_frame = before
	await process_frame
	print("WEB_PACING_TEST: " + ("PASS" if fails.is_empty() else "FAIL " + str(fails)))
	quit(0 if fails.is_empty() else 1)
