extends SceneTree
## The Planner view is the city the player lives in (owner report: "why is the orbit view a
## different city than the one in which player is living?"). Three things used to send it
## somewhere else, each pinned here against the real Main, headless and offline:
## 1. Leaving first person never moved the orbit rig, so the Planner opened on the founding core
##    (WORLD_CENTER, zoom 62) whichever district the hero stood in. It now opens over the hero:
##    the rig snaps to the hero's tile at HERO_ZOOM within the pan limits, once per arrival (the
##    player's own panning and focus calls after that are left alone), the same on boot into the
##    Planner and on Load there, and the view marks the spot with a ring and a "You" label. A New
##    City in the Planner shows its own core again, and a hero whose position is unusable leaves no
##    stale marker behind.
## 2. A Load the sim rejected had already replaced the live city with a fresh one while first
##    person went on drawing the old one, and so did a save whose sim was fine but another section
##    (the brain, the people, the minds) or a record of the sim was the wrong kind of value. A
##    rejected Load now changes nothing, whatever the reason. A slot the build refuses no longer
##    hides the good save kept as its backup, in game or at boot (the next autosave used to move
##    the refused file over that backup and the player started a new city).
## 3. Mayor and support answers still in flight when New City or Load replaced the city landed in
##    the new one. Through Main's own New City and Load they now change nothing, and the
##    Planner's inspector tab goes back to its hint: it used to keep the old city's tile, with
##    "Asking the street inspector on GMI..." for good once the old answer was dropped.
## The geometry is asserted as numbers (world position, zoom, the ground rectangle the camera
## sees, whether the hero is in it). How it looks is not testable headless.
## Prints FP_PLANNER_VIEW_TEST: PASS|FAIL.

const K := preload("res://tools/tests/fp_kit.gd")
const D := preload("res://scripts/sim/sim_defs.gd")
const GATED := preload("res://tools/tests/support/gated_client.gd")
const MAIN := preload("res://scripts/main.gd")
const TOKEN := "FP_PLANNER_VIEW_TEST"
const SAVE := "user://planner_view_save.json"
const BAD := "user://planner_view_bad.json"
const SLOT := "user://planner_view_slot.json"
## HOME: 15 tiles from the founding core's centre (15.5, 13.5), in the south-east district.
## FAR: open land outside the core, where the old default view showed nothing of the hero.
const HOME := Vector3(26.5, 0.0, 23.5)
const FAR := Vector3(60.5, 0.0, -30.5)

var fails: Array[String] = []
var main: Node
var cam: GridFallCamera
var _rebuilt := 0
var _changes := 0
## Where the first exit put the rig (the hero's tile at ground level).
var _home := Vector3.ZERO


func check(ok: bool, what: String) -> void:
	K.check(fails, ok, what)


func _init() -> void:
	K.watchdog(self, TOKEN, 280.0)
	await process_frame
	OS.set_environment("GRIDFALL_VIEW", "fp")
	OS.set_environment("GRIDFALL_OFFLINE", "1")
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	get_root().add_child(main)
	await _frames(5)
	cam = main.camera_rig
	check(main.fp != null and main.view_mode == "fp", "fixture: main boots on foot")
	main.sim.set_speed(0)
	_check_camera_api()
	await _check_exit_from_foot()
	await _check_player_keeps_the_camera()
	await _check_marker_follows_the_mode()
	await _check_second_visit()
	await _check_unusable_hero()
	await _check_new_city_in_planner()
	await _check_orbit_boot_and_load()
	await _check_rejected_load()
	await _check_rejected_sections()
	await _check_stale_answers()
	await _check_stale_inspector()
	await _check_refused_slot_keeps_backup()
	for p: String in [SAVE, BAD, SLOT, SaveSlot.backup_path(SLOT), SaveSlot.backup_path(BAD)]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	main.audio._exit_tree()
	K.finish(self, TOKEN, fails)


func _frames(n: int) -> void:
	for _i in range(n):
		await process_frame


## The rig's own contract: snap_to puts rig and camera at the target now, inside the pan limits.
func _check_camera_api() -> void:
	var rig := GridFallCamera.new()
	var arm := Camera3D.new()
	arm.name = "Camera"
	rig.add_child(arm)
	get_root().add_child(rig)
	rig.snap_to(Vector3(30.0, 0.0, -20.0), 35.0)
	check(
		rig.position == Vector3(30.0, 0.0, -20.0) and rig.target_position == rig.position,
		"snap_to: the rig is at the point now, not gliding (%s)" % str(rig.position)
	)
	check(
		rig.zoom == 35.0 and is_equal_approx(rig.camera.position.z, 35.0),
		"snap_to: the camera arm is at the zoom now (%.1f)" % rig.camera.position.z
	)
	rig.snap_to(Vector3(500.0, 3.0, -500.0), 1000.0)
	var hi := GridFallCamera.MAX_COORD - 1.0
	var lo := GridFallCamera.MIN_COORD + 1.0
	check(
		rig.position == Vector3(hi, 0.0, lo) and rig.zoom == GridFallCamera.MAX_ZOOM,
		"snap_to: clamped to the pan limits (%s, zoom %.0f)" % [str(rig.position), rig.zoom]
	)
	rig.snap_to(Vector3(0.0, 0.0, 0.0), 1.0)
	check(rig.zoom == GridFallCamera.MIN_ZOOM, "snap_to: clamped to the zoom limits")
	rig.free()
	var pos: Variant = MAIN.saved_hero_position({"player": {"pos": [3.0, 0.0, 4.0]}})
	check(pos == Vector3(3.0, 0.0, 4.0), "saved_hero_position: reads the player's pos")
	for bad: Variant in [
		{},
		{"player": 5},
		{"player": {}},
		{"player": {"pos": [1.0, 2.0]}},
		{"player": {"pos": ["a", "b", "c"]}},
		{"player": {"pos": [INF, 0.0, 0.0]}},
		{"player": {"pos": [NAN, 0.0, 1.0]}},
		{"player": {"pos": [5000.0, 0.0, 0.0]}},
	]:
		check(
			MAIN.saved_hero_position(bad) == null,
			"saved_hero_position: %s is no position" % str(bad)
		)


## The ground the camera sees at a window aspect (width / height): its four view rays, from the
## camera's own transform and vertical field of view, cast onto y = 0, as (x, z) points. Analytic,
## because the headless viewport is not the shape of a player's window.
func _footprint(aspect: float) -> PackedVector2Array:
	var xf := cam.camera.global_transform
	var th := tan(deg_to_rad(cam.camera.fov) * 0.5)
	var out := PackedVector2Array()
	for c: Vector2 in [
		Vector2(-1.0, 1.0), Vector2(1.0, 1.0), Vector2(1.0, -1.0), Vector2(-1.0, -1.0)
	]:
		var dir := (xf.basis * Vector3(c.x * th * aspect, c.y * th, -1.0)).normalized()
		if dir.y < -0.001:
			var p := xf.origin + dir * (-xf.origin.y / dir.y)
			out.append(Vector2(p.x, p.z))
	return out


func _bounds(poly: PackedVector2Array) -> Rect2:
	var r := Rect2(poly[0], Vector2.ZERO)
	for p: Vector2 in poly:
		r = r.expand(p)
	return r


## Walks to HOME, leaves first person: the Planner opens over the hero.
func _check_exit_from_foot() -> void:
	var before := Vector3(cam.target_position)
	check(
		before == GridFallCamera.WORLD_CENTER and cam.zoom == GridFallCamera.DEFAULT_ZOOM,
		"before: the rig sits on the founding core at the default zoom (%s)" % str(before)
	)
	main.fp.player.teleport(HOME, 0.0)
	await _frames(2)
	var hero: Vector3 = main.fp.ctx.player_position()
	check(
		hero.distance_to(GridFallCamera.WORLD_CENTER) > 10.0,
		(
			"fixture: the hero stands %.1f tiles from the founding core's centre"
			% hero.distance_to(GridFallCamera.WORLD_CENTER)
		)
	)
	main.exit_fp()
	check(main.view_mode == "orbit" and main.fp == null, "exit_fp: in the Planner")
	var want := Vector3(hero.x, 0.0, hero.z)
	_home = want
	check(
		cam.target_position == want and cam.position == want,
		(
			"exit_fp: the rig is over the hero at once: target %s, position %s"
			% [str(cam.target_position), str(cam.position)]
		)
	)
	check(
		(
			cam.zoom == GridFallCamera.HERO_ZOOM
			and is_equal_approx(cam.camera.position.z, GridFallCamera.HERO_ZOOM)
		),
		(
			"exit_fp: at HERO_ZOOM (%.0f), the camera arm already there (%.1f)"
			% [cam.zoom, cam.camera.position.z]
		)
	)
	check(cam.camera.current, "exit_fp: the orbit camera is the current one")
	# The numbers: where the hero is on screen, and the ground the Planner shows.
	var hero_ground := Vector3(hero.x, 0.0, hero.z)
	var size := cam.camera.get_viewport().get_visible_rect().size
	var px := cam.camera.unproject_position(hero_ground)
	check(
		px.distance_to(size * 0.5) < 1.0,
		"hero on screen at %s of %s: the centre of the view" % [str(px), str(size)]
	)
	check(
		cam.camera.is_position_in_frustum(hero_ground),
		"the hero's tile is inside the camera frustum"
	)
	check(cam.camera.keep_aspect == Camera3D.KEEP_HEIGHT, "the camera's fov is the vertical one")
	for aspect: float in [4.0 / 3.0, 16.0 / 9.0, 21.0 / 9.0]:
		var poly := _footprint(aspect)
		check(poly.size() == 4, "aspect %.2f: the view's four corners all meet the ground" % aspect)
		if poly.size() != 4:
			continue
		var box := _bounds(poly)
		check(
			Geometry2D.is_point_in_polygon(Vector2(hero.x, hero.z), poly),
			"aspect %.2f: the hero's tile is inside the view rectangle on the ground" % aspect
		)
		check(
			box.size.x < 100.0 and box.size.y < 60.0,
			(
				"aspect %.2f: a neighbourhood (%.0f x %.0f tiles), not the whole map"
				% [aspect, box.size.x, box.size.y]
			)
		)
		var rounded := PackedVector2Array()
		for p: Vector2 in poly:
			rounded.append(p.snappedf(0.1))
		print(
			(
				"  info aspect %.2f: ground corners (x,z) %s, bounds %.1f x %.1f tiles"
				% [aspect, str(rounded), box.size.x, box.size.y]
			)
		)
	print(
		(
			"  info hero %s, rig %s, zoom %.0f, headless viewport %s"
			% [str(hero), str(cam.position), cam.zoom, str(size)]
		)
	)
	var marker: Node3D = main.view.hero_marker
	check(
		marker != null and marker.is_visible_in_tree(),
		"the Planner marks the hero: a marker, shown"
	)
	if marker != null:
		check(
			(
				is_equal_approx(marker.position.x, hero.x)
				and is_equal_approx(marker.position.z, hero.z)
			),
			"the marker is on the hero's tile (%s)" % str(marker.position)
		)


## Only on that transition: the player's own pan, zoom and the HUD's focus are never undone.
func _check_player_keeps_the_camera() -> void:
	await _frames(10)
	check(
		cam.target_position == _home and cam.position.is_equal_approx(_home),
		"10 frames later the rig is still over the hero: nothing re-centres it"
	)
	cam.target_position = Vector3(-40.0, 0.0, 50.0)
	cam.zoom = 90.0
	await _frames(10)
	check(
		cam.target_position == Vector3(-40.0, 0.0, 50.0) and cam.zoom == 90.0,
		"the player's pan and zoom stay put (%s, %.0f)" % [str(cam.target_position), cam.zoom]
	)
	main.focus(Vector3(50.0, 0.0, 45.0), 30.0, "tile")
	check(
		cam.target_position == Vector3(50.0, 0.0, 45.0) and cam.zoom == 30.0,
		"the HUD's focus still moves the rig"
	)
	main.focus(Vector3(10.0, 0.0, 10.0), 99.0, "event:fire")
	check(
		cam.target_position == Vector3(10.0, 0.0, 10.0) and cam.zoom == 30.0,
		"an event still pans at the player's zoom"
	)


## The marker is a Planner thing: on foot it is not drawn.
func _check_marker_follows_the_mode() -> void:
	var marker: Node3D = main.view.hero_marker
	main.enter_fp()
	await _frames(3)
	check(
		marker != null and is_instance_valid(marker) and not marker.is_visible_in_tree(),
		"on foot the hero marker is not drawn"
	)


## A second visit places the rig again, now at where the hero went, and moves the marker.
func _check_second_visit() -> void:
	main.fp.player.teleport(FAR, 90.0)
	await _frames(2)
	var hero: Vector3 = main.fp.ctx.player_position()
	main.exit_fp()
	await _frames(3)
	var want := Vector3(hero.x, 0.0, hero.z)
	check(
		(
			cam.target_position == want
			and cam.position == want
			and cam.zoom == GridFallCamera.HERO_ZOOM
		),
		"second exit: the rig is over the hero's new spot (%s)" % str(cam.position)
	)
	var marker: Node3D = main.view.hero_marker
	check(
		(
			marker != null
			and marker.is_visible_in_tree()
			and is_equal_approx(marker.position.x, hero.x)
			and is_equal_approx(marker.position.z, hero.z)
		),
		"second exit: the marker moved with the hero"
	)
	check(
		Geometry2D.is_point_in_polygon(Vector2(hero.x, hero.z), _footprint(16.0 / 9.0)),
		"second exit: the hero is inside the view rectangle"
	)


## Leaving first person from a spot outside the world (a corrupt position): the rig stays
## where the player had it, and the marker of the earlier visit is hidden, not left pointing at a
## spot the hero has left.
func _check_unusable_hero() -> void:
	var marker: Node3D = main.view.hero_marker
	check(
		marker != null and marker.is_visible_in_tree(),
		"unusable hero: fixture: the last visit's marker is showing"
	)
	main.enter_fp()
	await _frames(3)
	main.fp.player.teleport(Vector3(5000.0, 0.0, 0.0), 0.0)
	var spot := Vector3(cam.target_position)
	var zoom := cam.zoom
	main.exit_fp()
	await _frames(2)
	check(main.view_mode == "orbit", "unusable hero: still back in the Planner")
	check(
		cam.target_position == spot and cam.zoom == zoom,
		"unusable hero: the rig stays where it was (%s)" % str(cam.target_position)
	)
	check(
		marker != null and not marker.is_visible_in_tree(),
		"unusable hero: the marker of the earlier visit is hidden"
	)


## A New City in the Planner has no hero yet: the rig leaves the old hero's spot, which is empty
## land in the new city, and shows the new core, as at boot.
func _check_new_city_in_planner() -> void:
	main.view.show_hero_marker(Vector3(FAR.x, 0.0, FAR.z))
	cam.snap_to(FAR, 55.0)
	check(
		cam.target_position.distance_to(GridFallCamera.WORLD_CENTER) > 30.0,
		"new city: fixture: the rig is far from the founding core (%s)" % str(cam.target_position)
	)
	main.new_game()
	main.sim.set_speed(0)
	await _frames(2)
	var core := GridFallCamera.WORLD_CENTER
	check(
		cam.target_position == core and cam.position == core,
		"new city: the rig is over the new core at once (%s)" % str(cam.position)
	)
	check(
		(
			cam.zoom == GridFallCamera.DEFAULT_ZOOM
			and is_equal_approx(cam.camera.position.z, GridFallCamera.DEFAULT_ZOOM)
		),
		"new city: at the default zoom (%.0f)" % cam.zoom
	)
	var marker: Node3D = main.view.hero_marker
	check(
		marker == null or not marker.is_visible_in_tree(),
		"new city: no marker for a hero the new city does not have"
	)


## Boot into the Planner with a saved hero (Main._continue) and a Load in the Planner frame the
## hero too; a save with no hero section (a fresh city) leaves the rig where the player put it.
func _check_orbit_boot_and_load() -> void:
	var rig_spot := Vector3(0.0, 0.0, 0.0)
	cam.snap_to(rig_spot, 80.0)
	var here := Vector3(70.5, 0.3, -12.5)
	main._continue({"fp": {"player": {"pos": [here.x, here.y, here.z]}}})
	check(
		(
			cam.target_position == Vector3(here.x, 0.0, here.z)
			and cam.zoom == GridFallCamera.HERO_ZOOM
		),
		(
			"boot into the Planner with a saved hero: the rig opens over it (%s)"
			% str(cam.target_position)
		)
	)
	var marker: Node3D = main.view.hero_marker
	check(marker != null and marker.is_visible_in_tree(), "...and the view marks it")
	cam.snap_to(rig_spot, 80.0)
	main._continue({})
	check(
		cam.target_position == rig_spot and cam.zoom == 80.0,
		"boot with no saved hero: the rig is left where it was"
	)
	# Load in the Planner: the save carries the hero (the section Main holds for the next Tab).
	main._continue({"fp": {"player": {"pos": [here.x, here.y, here.z]}}})
	check(main.save_game(SAVE), "fixture: the Planner saves")
	cam.snap_to(Vector3(-50.0, 0.0, -50.0), 150.0)
	check(main.load_game(SAVE), "fixture: the save loads in the Planner")
	var saved: Variant = MAIN.saved_hero_position(SaveSlot.read(SAVE).get("fp", {}))
	check(saved != null, "fixture: the save holds a hero position")
	if saved != null:
		var v: Vector3 = saved
		check(
			cam.target_position == Vector3(v.x, 0.0, v.z) and cam.zoom == GridFallCamera.HERO_ZOOM,
			(
				"Load in the Planner: the rig opens over the loaded hero (%s)"
				% str(cam.target_position)
			)
		)
	marker = main.view.hero_marker
	check(
		marker != null and is_instance_valid(marker) and marker.is_visible_in_tree(),
		"Load in the Planner: the rebuilt view has its marker"
	)


## A save the sim rejects, loaded on foot: nothing changes, first person and the sim agree.
func _check_rejected_load() -> void:
	main.enter_fp()
	await _frames(3)
	var save := SaveSlot.read(SAVE)
	var sim_doc := save["sim"] as Dictionary
	sim_doc["seed"] = 12345
	sim_doc["kind"] = (sim_doc["kind"] as Array).slice(0, 100)
	check(SaveSlot.write(BAD, save) == OK, "fixture: the truncated save is written")
	var sim: CitySim = main.sim
	var before := JSON.stringify(sim.to_dict()).hash()
	var seed_before := sim.city_seed
	var toasts: Array[String] = []
	main.fp.bus.toast.connect(func(text: String, _kind: String) -> void: toasts.append(text))
	_rebuilt = 0
	_changes = 0
	main.view.world_rebuilt.connect(func() -> void: _rebuilt += 1)
	sim.tiles_changed.connect(func(_t: PackedInt32Array) -> void: _changes += 1)
	var ok: bool = main.load_game(BAD)
	await _frames(3)
	check(not ok, "rejected load: load_game says no")
	check(
		toasts.has("Save file is invalid"), "rejected load: the player is told (%s)" % str(toasts)
	)
	check(
		JSON.stringify(sim.to_dict()).hash() == before and sim.city_seed == seed_before,
		"rejected load: the sim is the city the player is standing in (seed %d)" % sim.city_seed
	)
	check(
		_changes == 0 and _rebuilt == 0, "rejected load: the view was not rebuilt, no tile changed"
	)
	check(
		main.fp != null and main.view_mode == "fp" and main.view.fp_mode,
		"rejected load: still on foot"
	)


## What a load must leave alone when it refuses a save: the sim, the brain, the people and the
## minds, and the count of cities the brain and the minds have served.
func _state() -> Array:
	return [
		JSON.stringify(main.sim.to_dict()).hash(),
		JSON.stringify(main.brain.to_dict()).hash(),
		JSON.stringify(main.residents.to_dict()).hash(),
		JSON.stringify(main.minds.to_dict()).hash(),
		main.brain._generation,
		main.minds._generation,
	]


## A save whose sim names another city and has the right tile arrays, but one section is the wrong
## kind of value: the sim's own (a mayor that is null, an incident without a type) or another
## system's (the brain a list, the people a string). The load used to replace the sim first and
## fail on the section after, so the sim showed the saved city and the view the old one.
func _check_rejected_sections() -> void:
	var cases := {
		"sim.mayors = [null]": func(d: Dictionary) -> void: _sim(d)["mayors"] = [null],
		"sim.ordinances = []": func(d: Dictionary) -> void: _sim(d)["ordinances"] = [],
		"sim.sites = 'x'": func(d: Dictionary) -> void: _sim(d)["sites"] = "x",
		"sim.events = [{}]": func(d: Dictionary) -> void: _sim(d)["events"] = [{}],
		"sim.day = null": func(d: Dictionary) -> void: _sim(d)["day"] = null,
		"brain = [1]": func(d: Dictionary) -> void: d["brain"] = [1],
		"brain.client = []": func(d: Dictionary) -> void: _brain(d)["client"] = [],
		"brain.client.session_cache = 'x'":
		func(d: Dictionary) -> void: _brain_client(d)["session_cache"] = "x",
		"brain.client.stats = null": func(d: Dictionary) -> void: _brain_client(d)["stats"] = null,
		"brain.mayor_state = [null]":
		func(d: Dictionary) -> void: (d["brain"] as Dictionary)["mayor_state"] = [null],
		"client = []": func(d: Dictionary) -> void: d["client"] = [],
		"brain.mayor_state[0].log = null":
		func(d: Dictionary) -> void: _mayor_state(d)["log"] = null,
		"brain.mayor_state[0].thoughts = 'x'":
		func(d: Dictionary) -> void: _mayor_state(d)["thoughts"] = "x",
		"residents = 'x'": func(d: Dictionary) -> void: d["residents"] = "x",
		"residents.enabled = 'x'":
		func(d: Dictionary) -> void: (d["residents"] as Dictionary)["enabled"] = "x",
		"residents.people = [5]":
		func(d: Dictionary) -> void: (d["residents"] as Dictionary)["people"] = [5],
		"minds = 5": func(d: Dictionary) -> void: d["minds"] = 5,
		"minds.stats = []": func(d: Dictionary) -> void: (d["minds"] as Dictionary)["stats"] = [],
	}
	var before := _state()
	var toasts: Array[String] = []
	main.fp.bus.toast.connect(func(text: String, _kind: String) -> void: toasts.append(text))
	_rebuilt = 0
	_changes = 0
	var bad: Array[String] = []
	for name: String in cases.keys():
		var save := SaveSlot.read(SAVE)
		_sim(save)["seed"] = 12345
		(cases[name] as Callable).call(save)
		check(SaveSlot.write(BAD, save) == OK, "fixture: %s is written" % name)
		toasts.clear()
		var ok: bool = main.load_game(BAD)
		if ok or _state() != before or not toasts.has("Save file is invalid"):
			bad.append(name)
	await _frames(3)
	check(
		bad.is_empty(),
		(
			"rejected sections: all %d refused and told, nothing changed (not: %s)"
			% [cases.size(), str(bad)]
		)
	)
	check(_changes == 0 and _rebuilt == 0, "rejected sections: the view was not rebuilt")
	check(main.sim.city_seed != 12345, "rejected sections: the sim is still the city on screen")


func _sim(save: Dictionary) -> Dictionary:
	return save["sim"] as Dictionary


func _mayor_state(save: Dictionary) -> Dictionary:
	return ((save["brain"] as Dictionary)["mayor_state"] as Array)[0] as Dictionary


func _brain(save: Dictionary) -> Dictionary:
	return save["brain"] as Dictionary


func _brain_client(save: Dictionary) -> Dictionary:
	return _brain(save)["client"] as Dictionary


## New City and Load with answers still in flight: through Main's own paths they change nothing.
func _check_stale_answers() -> void:
	var brain: CityBrain = main.brain
	var sim: CitySim = main.sim
	var gated: GATED = GATED.new()
	gated.name = "GatedClient"
	main.add_child(gated)
	gated.live_enabled = false
	brain.client = gated
	gated.hold = true
	brain._run_mayor(0, sim.day)
	brain._run_mayor(3, sim.day)
	brain._run_support("news", sim.day, Callable(brain, "_run_news"))
	check(brain.pending_calls() == 3, "stale: two mayors and the Gazette are in flight")
	gated.hold = false
	main.new_game()
	await _frames(2)
	check(
		brain.pending_calls() == 0,
		"stale: New City clears them (%d pending)" % brain.pending_calls()
	)
	var city := JSON.stringify(sim.to_dict()).hash()
	var brain_doc := JSON.stringify(brain.to_dict())
	gated.gate.emit()
	await _frames(3)
	check(
		(
			JSON.stringify(sim.to_dict()).hash() == city
			and JSON.stringify(brain.to_dict()) == brain_doc
		),
		"stale: after New City the old answers land on nothing"
	)
	# The same through Load.
	brain.client = gated
	gated.hold = true
	brain._run_mayor(1, sim.day)
	brain._run_support("news", sim.day, Callable(brain, "_run_news"))
	check(brain.pending_calls() == 2, "stale: a mayor and the Gazette are in flight again")
	gated.hold = false
	check(main.load_game(SAVE), "fixture: Load takes the good save")
	await _frames(2)
	check(
		brain.pending_calls() == 0, "stale: Load clears them (%d pending)" % brain.pending_calls()
	)
	city = JSON.stringify(sim.to_dict()).hash()
	brain_doc = JSON.stringify(brain.to_dict())
	gated.gate.emit()
	await _frames(3)
	check(
		(
			JSON.stringify(sim.to_dict()).hash() == city
			and JSON.stringify(brain.to_dict()) == brain_doc
		),
		"stale: after Load the old answers land on nothing"
	)
	gated.queue_free()


## The inspector tab shows the tile the player clicked, in the city that was there. New City and
## Load replace that city, so the tab goes back to its hint, whether the report was still being
## asked for (an answer from the old city lands later and is dropped) or had come in already.
func _check_stale_inspector() -> void:
	var brain: CityBrain = main.brain
	var hud: CityHud = main.hud
	var gated: GATED = GATED.new()
	gated.name = "GatedInspector"
	main.add_child(gated)
	gated.live_enabled = false
	check(
		not main.sim.tile_report(15, 13).is_empty(), "inspector: fixture: the tile is in the city"
	)
	for how: String in ["New City", "Load"]:
		for asked: String in ["in flight", "answered"]:
			var what := "inspector (%s, %s)" % [how, asked]
			brain.client = gated
			gated.hold = asked == "in flight"
			hud.handle_tile_click(15, 13)
			await _frames(2)
			check(
				bool(hud._last_inspect.get("pending", false)) == (asked == "in flight"),
				(
					"%s: fixture: the tab shows the old city's tile (%s)"
					% [what, str(hud._last_inspect.keys())]
				)
			)
			if how == "Load":
				check(main.load_game(SAVE), "%s: fixture: Load takes the good save" % what)
			else:
				main.new_game()
			await _frames(2)
			check(hud._last_inspect.is_empty(), "%s: the old city's tile is gone" % what)
			check(
				hud._inspect_rt.text.contains("Click any tile"),
				"%s: the tab shows its hint, not the old tile" % what
			)
			gated.hold = false
			gated.gate.emit()
			await _frames(3)
			check(
				hud._last_inspect.is_empty() and hud._inspect_rt.text.contains("Click any tile"),
				"%s: the old city's late answer adds nothing" % what
			)
	# A tile asked about in the new city is still answered.
	brain.client = gated
	hud.handle_tile_click(15, 13)
	await _frames(2)
	check(
		not hud._last_inspect.is_empty() and not bool(hud._last_inspect.get("pending", true)),
		"inspector: a tile asked about in the new city is answered"
	)
	gated.queue_free()


## A slot this build refuses (a file that parses but would not load) does not hide the good save
## kept as its backup: Load in game and the launch that continues the city both go on from the
## backup instead of reporting an invalid save or starting a new city, and the launch still starts
## a new city when the slot and its backup are both refused.
func _check_refused_slot_keeps_backup() -> void:
	var good := SaveSlot.read(SAVE)
	var good_seed := int((good["sim"] as Dictionary)["seed"])
	var good_day := int((good["sim"] as Dictionary)["day"])
	var refused := good.duplicate(true)
	var sim_doc := refused["sim"] as Dictionary
	var sim_doc_size := (sim_doc["kind"] as Array).size()
	sim_doc["kind"] = (sim_doc["kind"] as Array).slice(0, 100)
	for p: String in [SLOT, SaveSlot.backup_path(SLOT)]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	check(SaveSlot.write(SLOT, good) == OK, "slot: fixture: the good save is written")
	check(SaveSlot.write(SLOT, refused) == OK, "slot: fixture: a refused save follows it")
	check(
		_kinds(SLOT) == 100 and _kinds(SaveSlot.backup_path(SLOT)) == sim_doc_size,
		"slot: fixture: the slot holds the refused save, the good one is its backup"
	)
	main.new_game()
	await _frames(2)
	var sim: CitySim = main.sim
	check(sim.city_seed != good_seed, "slot: fixture: the live city is not the good save's")
	var toasts: Array[String] = []
	main.fp.bus.toast.connect(func(text: String, _kind: String) -> void: toasts.append(text))
	check(main.load_game(SLOT), "slot: Load goes on from the backup when the slot is refused")
	check(
		sim.city_seed == good_seed and sim.day == good_day,
		"slot: Load: the city is the backup's (seed %d, day %d)" % [sim.city_seed, sim.day]
	)
	check(not toasts.has("Save file is invalid"), "slot: Load: no invalid-save toast")
	# The launch: main is the running scene, and continues the city its autosave slot holds.
	main.new_game()
	await _frames(2)
	main.autosave_path = SLOT
	current_scene = main
	var resumed: Dictionary = main._resume_data()
	check(
		not resumed.is_empty() and sim.city_seed == good_seed and sim.day == good_day,
		"slot: the launch continues the backup's city (seed %d, day %d)" % [sim.city_seed, sim.day]
	)
	# Neither file loads: a new city, as before.
	check(SaveSlot.write(SLOT, refused) == OK, "slot: fixture: the refused save is written again")
	check(_kinds(SaveSlot.backup_path(SLOT)) == 100, "slot: fixture: the backup is refused too")
	toasts.clear()
	check(not main.load_game(SLOT), "slot: Load says no when the slot and its backup are refused")
	check(toasts.has("Save file is invalid"), "slot: Load: the player is told")
	main.new_game()
	await _frames(2)
	var before := sim.city_seed
	var fresh: Dictionary = main._resume_data()
	check(
		fresh.is_empty() and sim.city_seed != before and sim.city_seed != good_seed,
		"slot: the launch starts a new city when nothing in the slot loads"
	)
	# No readable file at all is not a refusal: the launch leaves the city as the boot made it.
	for p: String in [SLOT, SaveSlot.backup_path(SLOT)]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	before = sim.city_seed
	check(main._resume_data().is_empty() and sim.city_seed == before, "slot: no slot, no change")
	current_scene = null
	main.autosave_path = MAIN.SAVE_PATH


## The length of the tile kind array of the save file at path (0 when it holds none).
func _kinds(path: String) -> int:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return 0
	var sim_doc: Variant = (parsed as Dictionary).get("sim")
	if typeof(sim_doc) != TYPE_DICTIONARY:
		return 0
	var kind: Variant = (sim_doc as Dictionary).get("kind")
	return (kind as Array).size() if typeof(kind) == TYPE_ARRAY else 0
