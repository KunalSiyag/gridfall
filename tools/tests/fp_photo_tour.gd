extends Node
## First-person windowed photo tour (docs/fp/S0-foundation.md §17.5), run inside Main through
## GRIDFALL_FP_PHOTO_DIR=<dir>: grows a city offline, then saves eye-level shots with and without
## the HUD (<name>_hud.png and <name>.png) from fp_shots.find() plus every feature's photo_shots().

const SHOTS := preload("res://tools/tests/fp_shots.gd")
const REGISTRY := preload("res://scripts/fp/fp_features.gd")
## Seconds to let growth-time toasts and resident speech bubbles fade before the first shot.
const SETTLE_SECONDS := 7.5


## Grows the city, then walks the shot list. dir is the output folder.
func run(main: Node, dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var sim: CitySim = main.sim
	var fp: FpMode = main.fp
	sim.start()
	var days := int(OS.get_environment("GRIDFALL_PHOTO_DAYS")) if OS.has_environment("GRIDFALL_PHOTO_DAYS") else 6
	await main.grow_offline(days, 240000)
	# Paused so no disaster interrupts the tour; vehicles and avatars keep animating.
	sim.set_speed(0)
	var player := fp.player
	player.input_enabled = false
	var shots: Array = SHOTS.find(sim, fp.directory, fp.collision)
	for e: Dictionary in REGISTRY.FEATURES:
		var f := fp.ctx.feature(str(e["id"]))
		if f == null:
			continue
		for s: Variant in f.photo_shots():
			if typeof(s) == TYPE_DICTIONARY:
				var shot := (s as Dictionary).duplicate()
				shot["feature"] = f
				shots.append(shot)
	var first: Dictionary = shots[0]
	main.sky.fixed_hour = float(first.get("hour", 10.5))
	player.teleport(first["pos"], float(first.get("yaw", 0.0)), float(first.get("pitch", 0.0)))
	await get_tree().create_timer(SETTLE_SECONDS).timeout
	var last_hour := -1.0
	for s: Dictionary in shots:
		var f: FpFeature = s.get("feature", null)
		if f != null and not str(s.get("prepare", "")).is_empty():
			f.call(str(s["prepare"]))
		var hour := float(s.get("hour", 10.5))
		main.sky.fixed_hour = hour
		player.teleport(s["pos"], float(s.get("yaw", 0.0)), float(s.get("pitch", 0.0)))
		await get_tree().create_timer(2.4 if not is_equal_approx(hour, last_hour) else 1.6).timeout
		last_hour = hour
		await RenderingServer.frame_post_draw
		_save(dir, str(s["name"]) + "_hud")
		fp.hud.set_hud_visible(false)
		await get_tree().process_frame
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		_save(dir, str(s["name"]))
		fp.hud.set_hud_visible(true)
		if f != null and not str(s.get("restore", "")).is_empty():
			f.call(str(s["restore"]))
		var p := player.position
		print("FP_PHOTO: shot %s pos=(%.3f,%.3f,%.3f) yaw=%.1f" % [s["name"], p.x, p.y, p.z, float(s.get("yaw", 0.0))])
	print("FP_PHOTO: DONE n=%d day=%d pop=%d" % [shots.size(), sim.day, int(sim.stats["population"])])
	main.audio._exit_tree()
	get_tree().quit(0)


func _save(dir: String, shot_name: String) -> void:
	get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, shot_name])
