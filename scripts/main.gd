extends Node3D
## GridFall: a SimCity-style city run by five autonomous GMI Cloud AI mayors.
## Wires the tile simulation, the GMI brain, the 3D city view, the HUD, camera and audio.

const SAVE_PATH := "user://gridfall_save.json"
## Environment switches that make a run a tool run (trailer, smokes, photo tours).
const TOOL_MODES := [
	"GRIDFALL_CINEMATIC", "GRIDFALL_SMOKE_TEST", "GRIDFALL_PHOTO_DIR",
	"GRIDFALL_FP_SMOKE", "GRIDFALL_FP_PHOTO_DIR",
]
const D := preload("res://scripts/sim/sim_defs.gd")

@onready var sim: CitySim = $CitySim
@onready var client: GmiClient = $GmiClient
@onready var brain: CityBrain = $CityBrain
@onready var view: CityView = $CityView
@onready var camera_rig: GridFallCamera = $View
@onready var camera: Camera3D = $View/Camera
@onready var sun_light: DirectionalLight3D = $Sun
@onready var audio: GridFallAudioDirector = $AudioDirector
@onready var hud: CityHud = $HUD

var _crisis: float = 0.0
var residents: Residents
var minds: ResidentMinds
var sky: SkyDirector
const WS := preload("res://scripts/fp/world_scale.gd")
## First-person composition (null in orbit mode). Built by enter_fp(), freed by exit_fp().
var fp: FpMode = null
## "orbit" or "fp"; tools and saves can read it.
var view_mode: String = "orbit"
## Orbit sim speed to restore on exit_fp() (1 when first person was entered before the sim ran).
var _orbit_speed: int = 1
## FpMode.to_dict() from the last exit_fp(), so Tab in orbit returns the hero to where they were.
var _fp_saved: Dictionary = {}
## Autosaves (the first tick of each morning, quitting) are on only in normal play: tool runs,
## tests and the benchmark never touch the player's city.
var autosave_enabled: bool = false
## Where autosaves go; tests point it away from the player's slot.
var autosave_path: String = SAVE_PATH
var _autosave_due: bool = false


func _ready() -> void:
	# Before the city is built, so the smaller shadow maps and buffers are the first allocated.
	var gpu := GpuMemory.decide()
	if bool(gpu["low"]):
		GpuMemory.apply_to(get_viewport())
	if bool(gpu["low"]) or DisplayServer.get_name() != "headless":
		print(GpuMemory.describe(gpu))
	var ops := OpsAlerts.new()
	ops.name = "OpsAlerts"
	ops.main = self
	add_child(ops)
	var start := {"view": "fp" if wants_fp() else "orbit", "flags": FeatureFlags.snapshot()}
	start["low_vram"] = bool(gpu["low"])
	Analytics.track("session_start", start)
	sim.set_speed(0)
	sim.road_grades = FeatureFlags.enabled("road_grades")
	residents = Residents.new()
	residents.name = "Residents"
	residents.enabled = OS.get_environment("GRIDFALL_RESIDENTS") != "0"
	residents.bike_share = Residents.BIKE_SHARE if FeatureFlags.enabled("cyclists") else 0.0
	add_child(residents)
	minds = ResidentMinds.new()
	minds.name = "ResidentMinds"
	add_child(minds)
	await get_tree().process_frame
	brain.setup(sim, client)
	_setup_people()
	minds.plans_done.connect(brain.residents_spoke)
	sim.tick_done.connect(_on_tick_done)
	# Loaded before the first view.setup, so the city is built once.
	var resume := _resume_data()
	view.fp_mode = wants_fp()
	view.setup(sim, camera)
	hud.setup(sim, brain, client)
	sky = SkyDirector.new()
	sky.name = "SkyDirector"
	add_child(sky)
	sky.setup(sim, camera.environment, sun_light, view)

	hud.setup_people(residents, minds)
	view.tile_clicked.connect(func(x: int, y: int) -> void: hud.handle_tile_click(x, y))
	view.resident_clicked.connect(func(id: String) -> void: hud.show_resident(id))
	hud.resident_selected.connect(func(id: String) -> void:
		if view.avatars == null:
			return
		view.avatars.select(id)
		if not id.is_empty():
			focus(view.avatars.position_of(id), 14.0, "resident:" + id)
	)
	view.tile_hovered.connect(func(x: int, y: int) -> void: hud.set_hover(x, y))
	hud.speed_requested.connect(func(s: int) -> void:
		sim.set_speed(s)
		hud.set_speed_display(s)
	)
	hud.overlay_requested.connect(func(mode: String) -> void: view.set_overlay(mode))
	hud.focus_district_requested.connect(_focus_district)
	hud.focus_tile_requested.connect(func(x: int, y: int) -> void: focus(Vector3(x, 0, y), 30.0, "tile"))
	hud.save_requested.connect(save_game)
	hud.load_requested.connect(load_game)
	hud.new_city_requested.connect(new_game)
	hud.mute_requested.connect(func() -> void: audio.toggle_mute())

	brain.mayor_thinking.connect(func(mi: int) -> void: view.show_mayor_thinking(mi))
	brain.mayor_decided.connect(func(mi: int, entry: Dictionary) -> void:
		view.show_mayor_decision(mi, entry)
		audio.play_sfx("res://sounds/placement-a.ogg", -14.0)
	)
	brain.citizens_spoke.connect(func(v: Array) -> void: view.show_citizen_voices(v))
	sim.day_started.connect(func(_d: int) -> void:
		audio.play_sfx("res://sounds/day_bell.wav", -12.0)
		_update_mood()
	)
	sim.event_started.connect(func(ev: Dictionary) -> void:
		audio.play_sfx("res://sounds/gridlock_alert.wav", -6.0)
		focus(Vector3(int(ev["x"]), 0, int(ev["y"])), 34.0, "event:" + str(ev["type"]))
		_update_mood()
	)
	sim.event_ended.connect(func(_ev: Dictionary) -> void: _update_mood())

	match OS.get_environment("GRIDFALL_CINEMATIC"):
		"prep":
			_prep_cinematic()
			return
		"record":
			var cine := Cinematic.new()
			cine.name = "Cinematic"
			add_child(cine)
			cine.run(self)
			return
	if OS.get_environment("GRIDFALL_SMOKE_TEST") == "1":
		_run_smoke_test()
		return
	if OS.has_environment("GRIDFALL_PHOTO_DIR"):
		_run_photo_tour(OS.get_environment("GRIDFALL_PHOTO_DIR"))
		return
	var fp_smoke := OS.get_environment("GRIDFALL_FP_SMOKE") == "1"
	var fp_photo := OS.get_environment("GRIDFALL_FP_PHOTO_DIR")
	if wants_fp():
		enter_fp()
	if fp_smoke:
		var smoke: Node = (load("res://tools/tests/fp_smoke.gd") as GDScript).new()
		smoke.name = "FpSmoke"
		add_child(smoke)
		smoke.call("run", self)
		return
	if not fp_photo.is_empty():
		var tour: Node = (load("res://tools/tests/fp_photo_tour.gd") as GDScript).new()
		tour.name = "FpPhotoTour"
		add_child(tour)
		tour.call("run", self, fp_photo)
		return
	autosave_enabled = _plays_for_real()
	if resume.is_empty():
		_start_new()
	else:
		_continue(resume)


## A fresh city at launch: day 1 starts and the clock runs at GRIDFALL_SPEED (default 1).
func _start_new() -> void:
	sim.start()
	var start_speed := int(OS.get_environment("GRIDFALL_SPEED")) if OS.has_environment("GRIDFALL_SPEED") else 1
	if fp != null:
		fp.set_time_scale(start_speed)
		notify("Welcome to GridFall. WASD to walk, Tab for the city overview, Enter to chat, M for the map, Esc to pause.")
	else:
		sim.set_speed(start_speed)
		hud.set_speed_display(start_speed)
		hud.toast("Five GMI mayors are drafting their first plans...")


## Orbit view: Tab (overview_toggle) goes back down to the street.
func _unhandled_input(event: InputEvent) -> void:
	if fp != null or event.is_echo() or not event.is_action_pressed("overview_toggle"):
		return
	# Tool runs (trailer, orbit smoke, orbit photo tour) stay in orbit.
	if OS.get_environment("GRIDFALL_CINEMATIC") in ["prep", "record"] or OS.get_environment("GRIDFALL_SMOKE_TEST") == "1" or OS.has_environment("GRIDFALL_PHOTO_DIR"):
		return
	get_viewport().set_input_as_handled()
	enter_fp()
	fp.set_time_scale(fp.time_scale)
	notify("Back on the street. Tab opens the city overview.")


func _exit_tree() -> void:
	Analytics.track("session_end", {"secs": snappedf(Analytics.uptime_s(), 0.1), "day": sim.day if sim != null else 0, "view": view_mode})


func _process(delta: float) -> void:
	if sky != null:
		sky.crisis = lerpf(sky.crisis, _crisis, minf(1.0, delta * 2.0))
	# After the morning's first tick has committed: today's mayor plans are in, and a load resumes
	# mid-day instead of starting the day over.
	if _autosave_due and sim.tick_in_day >= 1 and not sim.job_pending():
		_autosave_due = false
		autosave("morning")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		autosave("quit")


func _on_tick_done(t: int) -> void:
	if t == 0 and autosave_enabled:
		_autosave_due = true


func _update_mood() -> void:
	var dev := maxf(1.0, float(sim.stats.get("developed", 0)))
	var dark := float(sim.stats.get("unpowered", 0)) / dev
	_crisis = clampf(dark * 1.4 + float(sim.events.size()) * 0.22, 0.0, 1.0)
	audio.set_blackout_intensity(_crisis, "WARNING" if _crisis > 0.4 else "NOMINAL")


func _setup_people() -> void:
	residents.setup(sim)
	minds.setup(sim, residents, client, brain)
	brain.minds = minds


func _focus_district(mi: int) -> void:
	var b := sim.district_rect(mi)
	var c := Vector2(b.position) + Vector2(b.size) * 0.5 - Vector2(0.5, 0.5)
	focus(Vector3(c.x, 0, c.y), 36.0, "district:%d" % mi)


func save_game(path: String = SAVE_PATH) -> bool:
	var err := _write_save(path, "manual")
	if err != OK:
		notify("Save failed: cannot write %s (%s)" % [path, error_string(err)], "alert")
		return false
	notify("City saved (Day %d)" % sim.day, "success")
	return true


## Saves the city to autosave_path while autosave_enabled. reason: "morning" (a small toast) or
## "quit" (silent: the window is closing).
func autosave(reason: String) -> bool:
	if not autosave_enabled:
		return false
	var err := _write_save(autosave_path, reason)
	if err != OK:
		notify("Autosave failed (%s)" % error_string(err), "alert")
		return false
	if reason == "morning":
		notify("Autosaved: Day %d" % sim.day, "system")
	return true


## The pause menu's Quit: saves the city, then quits.
func quit_game() -> void:
	autosave("quit")
	get_tree().quit()


func _write_save(path: String, reason: String) -> Error:
	var data := {"sim": sim.to_dict(), "brain": brain.to_dict(), "client": client.to_dict(), "residents": residents.to_dict(), "minds": minds.to_dict(), "saved_at": Time.get_datetime_string_from_system()}
	if fp != null:
		data["fp"] = fp.to_dict()
	elif not _fp_saved.is_empty():
		data["fp"] = _fp_saved
	var err := SaveSlot.write(path, data)
	if err == OK:
		client.flush_cache()
		Analytics.track("save", {"day": sim.day, "view": view_mode, "reason": reason})
	return err


func load_game(path: String = SAVE_PATH) -> bool:
	var d := SaveSlot.read(path)
	if d.is_empty():
		var why := "Save file is invalid" if SaveSlot.exists(path) else "No saved city yet (press Save first)"
		notify(why, "alert")
		return false
	if not _restore(d):
		notify("Save file is invalid", "alert")
		return false
	view.setup(sim, active_camera())
	hud.setup(sim, brain, client)
	hud.setup_people(residents, minds)
	var fd: Variant = d.get("fp", {})
	if fp != null:
		fp.from_dict(fd if typeof(fd) == TYPE_DICTIONARY else {})
	else:
		_fp_saved = fd if typeof(fd) == TYPE_DICTIONARY else {}
	# Mid-day saves already have today's mayor decisions applied; only a boundary save needs a fresh day.
	if sim.tick_in_day == 0:
		sim.start()
	_update_mood()
	Analytics.track("load", {"day": sim.day, "view": view_mode})
	notify("Loaded city from Day %d" % sim.day, "success")
	return true


## Applies a save's data (sim, brain, client, people); false when the sim rejects it.
func _restore(d: Dictionary) -> bool:
	if not sim.from_dict(d.get("sim", {})):
		return false
	brain.from_dict(d.get("brain", {}))
	client.from_dict(d.get("client", {}))
	_setup_people()
	residents.from_dict(d.get("residents", {}))
	minds.from_dict(d.get("minds", {}))
	sim._recompute_all()
	sim.waiting_for_ai = false
	return true


## True for a player's own launch: main is the running scene (not inside a test or the benchmark)
## and no tool mode is selected.
func _plays_for_real() -> bool:
	if get_tree().current_scene != self:
		return false
	for k: String in TOOL_MODES:
		if OS.has_environment(k):
			return false
	return true


## The saved city a normal launch continues, already applied to the sim, or {} for a new city (no
## save, GRIDFALL_NEW_CITY=1, or a save the sim rejects).
func _resume_data() -> Dictionary:
	if not _plays_for_real() or OS.get_environment("GRIDFALL_NEW_CITY") == "1":
		return {}
	var d := SaveSlot.read(SAVE_PATH)
	if d.is_empty():
		return {}
	if _restore(d):
		return d
	# from_dict can reject a save after applying part of it.
	push_warning("GridFall: the saved city did not load; starting a new one")
	sim.new_city(randi() % 100000)
	brain.setup(sim, client)
	_setup_people()
	return {}


## Continues the city _resume_data() restored: the player, the features and the time of day.
func _continue(d: Dictionary) -> void:
	var fd: Variant = d.get("fp", {})
	if fp != null:
		fp.from_dict(fd if typeof(fd) == TYPE_DICTIONARY else {})
		fp.set_time_scale(fp.time_scale)
	else:
		_fp_saved = fd if typeof(fd) == TYPE_DICTIONARY else {}
		sim.set_speed(1)
		hud.set_speed_display(1)
	if sim.tick_in_day == 0:
		sim.start()
	_update_mood()
	Analytics.track("continue", {"day": sim.day, "view": view_mode})
	print("GRIDFALL: continuing the saved city, day %d tick %d" % [sim.day, sim.tick_in_day])
	notify("Welcome back: Day %d. New city in the pause menu starts over." % sim.day, "success")


func new_game() -> void:
	sim.new_city(randi() % 100000)
	brain.setup(sim, client)
	_setup_people()
	view.setup(sim, active_camera())
	hud.setup(sim, brain, client)
	hud.setup_people(residents, minds)
	if fp != null:
		fp.from_dict({})
	_fp_saved = {}
	sim.start()
	_update_mood()
	Analytics.track("new_city", {"seed": sim.city_seed})
	notify("A new GridFall has been founded", "success")


## True when this run will play in first person: no legacy tool mode (cinematic, orbit smoke,
## orbit photo tour) is selected, and either an FP tool mode is or GRIDFALL_VIEW is not "orbit".
## Mirrors the boot ladder in _ready(), so the early view flag and enter_fp() always agree.
static func wants_fp() -> bool:
	if OS.get_environment("GRIDFALL_CINEMATIC") in ["prep", "record"]:
		return false
	if OS.get_environment("GRIDFALL_SMOKE_TEST") == "1" or OS.has_environment("GRIDFALL_PHOTO_DIR"):
		return false
	return OS.get_environment("GRIDFALL_FP_SMOKE") == "1" or OS.has_environment("GRIDFALL_FP_PHOTO_DIR") or OS.get_environment("GRIDFALL_VIEW") != "orbit"


## Draws attention to a world point. Orbit: moves the camera rig (old behaviour).
## First person: never teleports; emits GameBus.ping(p, reason) for the HUD and minimap.
## reason: "event:<type>" | "resident:<id>" | "tile" | "district:<mi>" | "" .
func focus(p: Vector3, dist: float, reason: String = "") -> void:
	if fp != null:
		fp.bus.ping.emit(p, reason)
		return
	camera_rig.focus_world_point(p, dist)


## Player-facing notice: CityHud toast in orbit, GameBus.toast in first person.
## kind: "info" | "alert" | "success" | "system".
func notify(text: String, kind: String = "info") -> void:
	if fp != null:
		fp.bus.toast.emit(text, kind)
	else:
		hud.toast(text)


## The camera the city view should use for picking and shake.
func active_camera() -> Camera3D:
	return fp.player.camera if fp != null else camera


## Switches to first person (S0 §6.3). Safe to call twice.
func enter_fp() -> void:
	if fp != null:
		return
	view_mode = "fp"
	camera_rig.set_process(false)
	camera_rig.set_process_input(false)
	camera_rig.set_process_unhandled_input(false)
	hud.visible = false
	hud.process_mode = Node.PROCESS_MODE_DISABLED
	view.set_fp_mode(true)
	_orbit_speed = sim.speed if sim.speed > 0 else 1
	sim.set_day_seconds(WS.FP_DAY_SECONDS)
	fp = FpMode.new()
	fp.name = "FpMode"
	add_child(fp)
	fp.setup(self)
	view.set_camera(fp.player.camera)
	if not _fp_saved.is_empty():
		# The orbit clock ran on since; only the player and the features come back.
		var back := _fp_saved.duplicate(true)
		back.erase("day_phase")
		_fp_saved = {}
		fp.from_dict(back)
	Analytics.track("enter_fp", {"day": sim.day, "features": fp.ctx.features.size()})


## Back to the orbit view and CityHud (used by B's "Quit to orbit"). Safe to call twice.
## It frees FpHud, so a caller inside an FP node's signal (a Button's pressed) must use
## ctx.main.call_deferred("exit_fp"); a locked object cannot be freed mid-emit.
func exit_fp() -> void:
	if fp == null:
		return
	_fp_saved = fp.to_dict()
	fp.teardown()
	fp.queue_free()
	fp = null
	view.set_fp_mode(false)
	view.set_camera(camera)
	camera.make_current()
	camera_rig.set_process(true)
	camera_rig.set_process_input(true)
	camera_rig.set_process_unhandled_input(true)
	hud.process_mode = Node.PROCESS_MODE_INHERIT
	hud.visible = true
	sim.set_day_seconds(D.BASE_DAY_SECONDS)
	sim.set_speed(_orbit_speed)
	hud.set_speed_display(_orbit_speed)
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	view_mode = "orbit"
	Analytics.track("exit_fp", {"day": sim.day})
	hud.toast("Planner view. Press Tab to walk the streets again.")


## Grows the city offline at full speed with the legacy 12 s day, for tests and tours, then restores
## the current day length and speed 0. The caller must have called sim.start(). Returns when
## sim.day >= days or after cap_ms of wall clock time.
func grow_offline(days: int, cap_ms: int) -> void:
	client.set_live(false)
	var saved_day_seconds := sim.day_seconds
	var was_sliced: Variant = sim.get("sliced")
	if was_sliced == true:
		sim.set("sliced", false)
	sim.set_day_seconds(D.BASE_DAY_SECONDS)
	sim.set_speed(16)
	var t0 := Time.get_ticks_msec()
	while sim.day < days and Time.get_ticks_msec() - t0 < cap_ms:
		await get_tree().process_frame
	sim.set_speed(0)
	sim.set_day_seconds(saved_day_seconds)
	if was_sliced == true:
		sim.set("sliced", true)
	if view.has_method("flush_rebuild_queue"):
		view.call("flush_rebuild_queue")


## Grows a city offline for the cinematic trailer and saves it at a day boundary, so the
## recording run opens with all five mayors calling GMI live.
func _prep_cinematic() -> void:
	client.set_live(false)
	var days := int(OS.get_environment("GRIDFALL_PHOTO_DAYS")) if OS.has_environment("GRIDFALL_PHOTO_DAYS") else 12
	sim.start()
	sim.set_speed(16)
	var t0 := Time.get_ticks_msec()
	while sim.day < days and Time.get_ticks_msec() - t0 < 300000:
		await get_tree().process_frame
	sim.set_speed(0)
	_build_showcase()
	await get_tree().process_frame
	save_game(Cinematic.SAVE)
	print("GRIDFALL_CINE: prepped day=%d tick=%d pop=%d" % [sim.day, sim.tick_in_day, int(sim.stats["population"])])
	audio._exit_tree()
	get_tree().quit(0)

## Offline photo tour: grows the city, sets off a fire, and saves screenshots of the city's landmarks.
func _run_photo_tour(dir: String) -> void:
	client.set_live(false)
	DirAccess.make_dir_recursive_absolute(dir)
	var days := int(OS.get_environment("GRIDFALL_PHOTO_DAYS")) if OS.has_environment("GRIDFALL_PHOTO_DAYS") else 10
	sim.start()
	sim.set_speed(16)
	var t0 := Time.get_ticks_msec()
	while sim.day < days and Time.get_ticks_msec() - t0 < 240000:
		await get_tree().process_frame
	# Paused so a new disaster cannot pull the camera away mid-tour; vehicles keep moving.
	sim.set_speed(0)
	if OS.get_environment("GRIDFALL_PHOTO_SHOWCASE") == "1":
		_build_showcase()
		await get_tree().create_timer(1.0).timeout
	var shots: Array = [["overview", Vector3(15.5, 0, 13.5), 62.0]]
	for k: int in [D.AIRPORT, D.WIND, D.STADIUM, D.TRAIN, D.UNIVERSITY, D.LANDFILL]:
		for i in sim.active:
			if sim.kind[i] == k:
				shots.append([str(D.KIND_NAMES[k]).to_snake_case(), Vector3(D.tx(i), 0, D.ty(i)), 16.0])
				break
	for i in sim.active:
		if sim.kind[i] == D.ZONE_C and sim.level[i] >= 3:
			shots.append(["downtown", Vector3(D.tx(i), 0, D.ty(i)), 18.0])
			break
	for i in range(D.W * D.H):
		if sim.terrain[i] == D.WATER and sim.kind[i] != D.ROAD and D.in_core(D.tx(i), D.ty(i)):
			shots.append(["river", Vector3(D.tx(i), 0, D.ty(i)), 20.0])
			break
	sky.fixed_hour = 10.5 if sky.fixed_hour < 0.0 else sky.fixed_hour
	for s: Array in shots:
		camera_rig.focus_world_point(s[1], s[2])
		await get_tree().create_timer(1.6).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, s[0]])
	for t: Array in [["dusk", 18.4], ["night", 23.0]]:
		sky.fixed_hour = t[1]
		for s: Array in [shots[0], shots[shots.size() - 1] if shots.size() > 1 else shots[0]]:
			camera_rig.focus_world_point(s[1], s[2])
			await get_tree().create_timer(2.4).timeout
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("%s/%s_%s.png" % [dir, s[0], t[0]])
	sky.fixed_hour = 10.5
	var cs := _construction_showcase()
	if not cs.is_empty():
		var shots_c: Array = [["construction", cs[0], 14.0], ["construction_close", (cs[1] as Array)[mini(3, (cs[1] as Array).size() - 1)], 7.0]]
		for s: Array in shots_c:
			camera_rig.focus_world_point(s[1], s[2])
			await get_tree().create_timer(1.8).timeout
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, s[0]])
		sky.fixed_hour = 21.5
		camera_rig.focus_world_point(cs[0], 14.0)
		await get_tree().create_timer(2.4).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(dir + "/construction_night.png")
		sky.fixed_hour = 10.5
	var ev := sim.trigger_disaster("fire", 16, 14, "player", "photo tour")
	await get_tree().create_timer(5.0).timeout
	camera_rig.focus_world_point(Vector3(int(ev.get("x", 16)), 0, int(ev.get("y", 14))), 16.0)
	await get_tree().create_timer(2.0).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(dir + "/fire_response.png")
	print("GRIDFALL_PHOTO: %d shots day=%d pop=%d life=%s" % [shots.size() + 1, sim.day, int(sim.stats["population"]), JSON.stringify(view.life.vehicle_counts())])
	audio._exit_tree()
	get_tree().quit(0)


## Opens a row of construction sites, one per stage, so a single shot shows the whole sequence.
## Returns the world point to frame, or an empty array when no lots are free.
func _construction_showcase() -> Array:
	var mode := sim.construction_mode
	sim.construction_mode = "staged"
	var plan := [["university", 0], ["hospital", 1], ["school", 2], ["stadium", 3], ["train_station", 4], ["police", 3]]
	var best: Array = []
	var best_mi := 0
	for mi in range(D.MAYORS.size()):
		var lots: Array = sim.open_lots(mi, 80)
		for a: Variant in lots:
			var row: Array = [a]
			for b: Variant in lots:
				if int(b[1]) == int(a[1]) and int(b[0]) > int(row[-1][0]) and int(b[0]) <= int(row[-1][0]) + 2:
					row.append(b)
			if row.size() > best.size():
				best = row
				best_mi = mi
	if best.is_empty():
		sim.construction_mode = mode
		return []
	var placed: Array = []
	for k in range(mini(best.size(), plan.size())):
		var key: String = plan[k][0]
		sim.mayors[best_mi]["treasury"] = int(sim.mayors[best_mi]["treasury"]) + int(D.BUILDINGS[key]["cost"])
		var r := sim.apply_action(best_mi, {"type": "build", "building": key, "x": int(best[k][0]), "y": int(best[k][1])})
		if not bool(r.get("ok", false)) or not r.has("x"):
			continue
		var i := D.idx(int(r["x"]), int(r["y"]))
		if not sim.sites.has(i):
			continue
		var s: Dictionary = sim.sites[i]
		s["stage"] = mini(int(plan[k][1]), (s["stages"] as Array).size() - 1)
		s["progress"] = float(s["stage_work"]) * 0.6
		sim._mark(i)
		placed.append(Vector3(int(r["x"]), 0, int(r["y"])))
	sim._flush_changes(true)
	sim.construction_mode = mode
	print("GRIDFALL_PHOTO: construction showcase %d sites for %s" % [placed.size(), sim.mayors[best_mi]["name"]])
	if placed.is_empty():
		return []
	var c := Vector3.ZERO
	for p: Vector3 in placed:
		c += p
	return [c / float(placed.size()), placed]

## Funds each district and builds any big project the city is still missing, so every model shows up.
func _build_showcase() -> void:
	var wanted := ["airport", "stadium", "train_station", "university", "wind_farm", "landfill"]
	for k in range(wanted.size()):
		var key: String = wanted[k]
		var kind := int(D.BUILDINGS[key]["kind"])
		if Array(sim.kind).has(kind):
			continue
		var built := false
		var last_reason := "no open lots"
		for step in range(D.MAYORS.size()):
			var mi := (k + step) % D.MAYORS.size()
			var grant := int(D.BUILDINGS[key]["cost"]) + 500
			sim.mayors[mi]["treasury"] = int(sim.mayors[mi]["treasury"]) + grant
			for lot: Variant in sim.open_lots(mi, 60):
				var r := sim.apply_action(mi, {"type": "build", "building": key, "x": int(lot[0]), "y": int(lot[1])})
				if bool(r.get("ok", false)):
					print("GRIDFALL_PHOTO: showcase %s at %s" % [key, str(lot)])
					built = true
					break
				last_reason = str(r.get("reason", ""))
			if built:
				break
			sim.mayors[mi]["treasury"] = int(sim.mayors[mi]["treasury"]) - grant
		if not built:
			print("GRIDFALL_PHOTO: showcase %s failed: %s" % [key, last_reason])
	# The landmark shots need the finished buildings, not their construction sites.
	sim.finish_all_sites()


func _print_residents(tag: String) -> void:
	var by_src: Dictionary = {}
	var jobs: Dictionary = {}
	for r in residents.people:
		by_src[str(r["source"])] = int(by_src.get(str(r["source"]), 0)) + 1
		jobs[str(r["job_title"])] = int(jobs.get(str(r["job_title"]), 0)) + 1
	print("%s: residents=%d share=%.1f left=%d sources=%s sentiment=%s minds=%s" % [tag, residents.people.size(), residents.share, residents.departed.size(), JSON.stringify(by_src), JSON.stringify(residents.sentiment), JSON.stringify(minds.stats)])
	print("%s: jobs=%s" % [tag, JSON.stringify(jobs)])
	var hot := 0
	var roads := 0
	var tmax := 0.0
	for i in sim.active:
		if sim.kind[i] == D.ROAD:
			roads += 1
			tmax = maxf(tmax, sim.traffic[i])
			if sim.traffic[i] > 0.7:
				hot += 1
	var money: Array = residents.district_money()
	print("%s: traffic avg=%.2f max=%.2f hot=%d/%d income=%s money_today=%s" % [tag, float(sim.stats.get("traffic", 0)), tmax, hot, roads, str(sim.mayors.map(func(m: Dictionary) -> String: return "%d-%d" % [int(m["last_income"]), int(m["last_upkeep"])])), JSON.stringify(money)])
	for r in residents.people.slice(0, 3):
		print("%s: %s (%s) mood=%.1f savings=%d state=%s plan=%s thought=%s" % [tag, r["name"], r["job_title"], float(r["mood"]), int(float(r["savings"])), r["state"], JSON.stringify(r["plan"]), r["thought"]])


func _run_smoke_test() -> void:
	client.set_live(false)
	sim.start()
	sim.set_speed(16)
	var t0 := Time.get_ticks_msec()
	while sim.day < 6 and Time.get_ticks_msec() - t0 < 60000:
		await get_tree().process_frame
	print("GRIDFALL_SMOKE: day=%d pop=%d funds=%d developed=%d stats=%s" % [sim.day, int(sim.stats["population"]), sim.total_funds(), int(sim.stats["developed"]), JSON.stringify(client.stats)])
	print("GRIDFALL_SMOKE: treasuries=%s" % str(sim.mayors.map(func(m: Dictionary) -> int: return int(m["treasury"]))))
	_print_residents("GRIDFALL_SMOKE")
	var ev := sim.trigger_disaster("earthquake", 16, 16, "player", "smoke")
	print("GRIDFALL_SMOKE: quake rubble=%d" % (ev.get("tiles", []) as Array).size())
	if residents.is_active():
		var t1 := Time.get_ticks_msec()
		sim.set_speed(16)
		while sim.events.has(ev) and Time.get_ticks_msec() - t1 < 30000:
			await get_tree().process_frame
		sim.set_speed(0)
		print("GRIDFALL_SMOKE: quake resolved=%s progress=%d/%d helpers=%s" % [not sim.events.has(ev), int(ev["progress"]), int(ev["work"]), JSON.stringify((ev["helpers"] as Dictionary).keys().slice(0, 8))])
	for mode: String in ["power", "pollution", "services", "none"]:
		view.set_overlay(mode)
		await get_tree().process_frame
	for _f in range(30):
		await get_tree().process_frame
	print("GRIDFALL_SMOKE: life=%s bus_stops=%d" % [JSON.stringify(view.life.vehicle_counts()), view.bus_stops.size()])
	hud.handle_tile_click(15, 16)
	if not residents.people.is_empty() and view.avatars != null:
		hud.show_resident(str(residents.people[0]["id"]))
		view.avatars.select(str(residents.people[0]["id"]))
		print("GRIDFALL_SMOKE: avatars=%s" % JSON.stringify(view.avatars.visible_count()))
	await get_tree().process_frame
	sim.set_speed(0)
	if sim.tick_in_day == 0:
		sim.step_tick()
	save_game()
	var pop_before := int(sim.stats["population"])
	var day_before := sim.day
	var ok := load_game()
	print("GRIDFALL_SMOKE: save/load ok=%s day %d->%d pop %d->%d" % [ok, day_before, sim.day, pop_before, int(sim.stats["population"])])
	await get_tree().process_frame
	print("GRIDFALL_SMOKE: " + ("PASS" if ok and sim.day == day_before and int(sim.stats["population"]) > 0 else "FAIL"))
	audio._exit_tree()
	get_tree().quit(0)
