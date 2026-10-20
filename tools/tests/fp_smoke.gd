extends Node
## First-person headless smoke (docs/fp/S0-foundation.md §17.4), run inside Main through
## GRIDFALL_FP_SMOKE=1: grows a city offline, then checks the FP wiring, time controls, walking,
## blocking, no camera yank, directory, de-branding, HUD, pause (the world freezes), save/load
## (time of day included), getting out of a box that appears underfoot, hidden resident bubbles,
## every feature's self_test and the orbit round trip (no tick burst). Failures are collected;
## prints FP_SMOKE: PASS|FAIL.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const REGISTRY := preload("res://scripts/fp/fp_features.gd")
const ACTIONS := [
	"move_forward", "move_back", "move_left", "move_right", "sprint", "crouch", "jump", "interact",
	"chat_open", "map_toggle", "pause_menu", "time_faster", "time_slower", "time_skip", "photo_mode",
	"hud_toggle", "quick_save", "quick_load",
]
const BRANDS := ["Argon", "DeepSeek", "Kimi", "Qwen", "Grok"]
const SAVE := "user://fp_smoke_save.json"
const AUTOSAVE := "user://fp_smoke_autosave.json"
const DT := 1.0 / 60.0

var main: Node
var fails: Array[String] = []
var pings: Array[String] = []
var scales: Array[int] = []
var pauses: Array[bool] = []
var tile_events: int = 0
var world_ready: int = 0
## A player's own save may sit in the slot (runs outside the gate share user://).
var _started := int(Time.get_unix_time_from_system())


## 11c. Autosave writes main's slot on a window close request and once the morning's first tick has
## committed, and only while autosave_enabled (tool runs like this one leave it off).
func _check_autosave(sim: CitySim) -> void:
	var real: String = main.SAVE_PATH
	var off: bool = not main.autosave_enabled
	var untouched := not SaveSlot.exists(real) or FileAccess.get_modified_time(real) < _started
	check(off and untouched, "tool runs never autosave (flag off, slot untouched)")
	var slot := AUTOSAVE
	main.autosave_path = slot
	var speed := sim.speed
	sim.set_speed(0)
	while sim.job_pending():
		await get_tree().process_frame
	main.autosave_enabled = true
	main.notification(NOTIFICATION_WM_CLOSE_REQUEST)
	check(SaveSlot.read(slot).has("fp"), "a window close request saves the city")
	_remove_slot(slot)
	var tick := sim.tick_in_day
	sim.tick_in_day = 0
	sim.tick_done.emit(0)
	await get_tree().process_frame
	var early := FileAccess.file_exists(slot)
	sim.tick_in_day = 1
	await get_tree().process_frame
	await get_tree().process_frame
	var saved := SaveSlot.read(slot).has("fp")
	check(not early and saved, "the morning autosave waits for the first tick, then saves")
	sim.tick_in_day = tick
	main.autosave_enabled = false
	main.autosave_path = real
	_remove_slot(slot)
	sim.set_speed(speed)


func _remove_slot(slot: String) -> void:
	for p: String in [slot, SaveSlot.backup_path(slot)]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func check(ok: bool, what: String) -> void:
	print(("FP_SMOKE:   ok   " if ok else "FP_SMOKE:   FAIL ") + what)
	if not ok:
		fails.append(what)


## Runs every step; never aborts early except when FP did not start at all.
func run(p_main: Node) -> void:
	main = p_main
	var sim: CitySim = main.sim
	var view: CityView = main.view
	# 1. Grow offline (hard check).
	main.client.set_live(false)
	sim.start()
	var t0 := Time.get_ticks_msec()
	await main.grow_offline(3, 60000)
	print("FP_SMOKE: grown day=%d pop=%d in %d ms" % [sim.day, int(sim.stats["population"]), Time.get_ticks_msec() - t0])
	check(sim.day >= 3, "grew to day 3 (day %d)" % sim.day)
	var fp: FpMode = main.fp
	if fp == null:
		check(false, "FpMode exists")
		_finish()
		return
	_listen(fp)
	var ctx := fp.ctx
	# 2. Wiring.
	check(main.view_mode == "fp", "view_mode is fp")
	check(get_viewport().get_camera_3d() == fp.player.camera, "the FP camera is current")
	check(fp.player.camera.environment != null and fp.player.camera.environment == main.camera.environment, "the FP camera shares the Environment")
	var rig: Node3D = main.camera_rig
	check(not rig.is_processing() and not rig.is_processing_input() and not rig.is_processing_unhandled_input(), "the orbit rig is off")
	check(not main.hud.visible and main.hud.process_mode == Node.PROCESS_MODE_DISABLED, "CityHud is hidden and disabled")
	check(view.fp_mode and _orbit_layers_hidden(view), "CityView hides labels, territory, icons, cursor and mayor bots")
	check(is_equal_approx(sim.day_seconds, WS.FP_DAY_SECONDS), "the FP day is %d s" % int(WS.FP_DAY_SECONDS))
	check(view.camera == fp.player.camera, "CityView picks with the FP camera")
	# 3. Input actions and features.
	var missing: Array[String] = []
	for a: String in ACTIONS:
		if not InputMap.has_action(a):
			missing.append(a)
	check(missing.is_empty(), "all 18 input actions exist %s" % str(missing))
	var feats_ok := true
	for e: Dictionary in REGISTRY.FEATURES:
		feats_ok = feats_ok and ctx.feature(str(e["id"])) != null
	check(feats_ok and ctx.features.size() == REGISTRY.FEATURES.size(), "every registry feature is built (%d)" % ctx.features.size())
	# 4. Time.
	fp.set_time_scale(4)
	check(sim.speed == 4 and scales.has(4), "time scale 4 drives the sim")
	fp.step_time_scale(1)
	check(fp.time_scale == 8 and sim.speed == 8, "step_time_scale(+1) gives 8x")
	fp.set_time_scale(1)
	var day0 := sim.day
	await fp.skip_to_morning()
	check(sim.day == day0 + 1 and sim.tick_in_day == 0, "skip_to_morning starts day %d at dawn (day %d tick %d)" % [day0 + 1, sim.day, sim.tick_in_day])
	# 5. Player.
	var p := fp.player
	p.input_enabled = false
	fp.from_dict({})
	var hall := _find_kind(sim, D.HALL)
	var front := fp.directory.frontage(hall)
	check(front >= 0 and Vector2(p.position.x - D.tx(front), p.position.z - D.ty(front)).length() <= 1.5, "the player spawns by City Hall's frontage road")
	check(absf(p.position.y - fp.collision.ground_height(p.position)) < 0.002, "the player stands on the ground")
	var spawn := p.position
	var spawn_yaw := rad_to_deg(p.yaw)
	var run := RoadTopology.run_dir(RoadTopology.mask(sim, D.tx(front), D.ty(front))) if front >= 0 else Vector3(1, 0, 0)
	p.teleport(spawn, rad_to_deg(atan2(-run.x, -run.z)))
	for _k in range(120):
		p.simulate(Vector2(0, 1), false, DT)
	var walked := Vector2(p.position.x - spawn.x, p.position.z - spawn.z).length()
	check(walked > 0.1, "2 s along the sidewalk moves %.3f" % walked)
	p.teleport(spawn, spawn_yaw)
	var inside := false
	var r := WS.PLAYER_RADIUS * 0.99
	for _k in range(300):
		p.simulate(Vector2(0, 1), false, DT)
		for b: AABB in fp.collision.boxes(hall):
			if b.grow(r).has_point(p.position):
				inside = true
	check(not fp.collision.boxes(hall).is_empty() and not inside, "walking into City Hall for 5 s never enters its boxes")
	check(tile_events > 0, "player_tile_changed fired (%d)" % tile_events)
	# 6. No camera yank: events and focus() ping instead of moving anything.
	var p0 := p.position
	var cam0: Vector3 = rig.get("target_position")
	pings.clear()
	sim.trigger_disaster("fire", 16, 14, "player", "fp smoke")
	for _k in range(30):
		await get_tree().process_frame
	main.focus(Vector3(3, 0, 3), 20.0, "tile")
	var event_ping := false
	for reason: String in pings:
		event_ping = event_ping or reason.begins_with("event:")
	check(pings.size() >= 2 and event_ping, "a fire and focus() ping (%s)" % str(pings))
	check(p.position.distance_to(p0) < 1e-6, "the player did not move")
	check((rig.get("target_position") as Vector3).distance_to(cam0) < 1e-6, "the orbit rig did not move")
	# 7. Directory.
	var street := fp.directory.street_at(p.position)
	check(not street.is_empty(), "street_at names the player's street (%s)" % street)
	var c_lot := _find_level(sim, D.ZONE_C)
	check(c_lot < 0 or not fp.directory.business_name(c_lot).is_empty(), "C lots have business names (%s)" % (fp.directory.business_name(c_lot) if c_lot >= 0 else "none"))
	# 8. De-branding.
	var names_ok := true
	for i in range(sim.mayors.size()):
		names_ok = names_ok and str(sim.mayors[i]["name"]) == str(D.MAYORS[i]["display"])
	check(names_ok, "sim mayors carry display names")
	check(D.debrand("Argon-4") == "Ada Okafor", "debrand(Argon-4)")
	# Reads the top bar through the slot API only (B replaces the placeholder label with chips):
	# the visible text must name the day within 1 s, and no text under the bar may carry a brand.
	var bar := fp.hud.slot("top_bar")
	var status := ""
	for _k in range(20):
		await get_tree().create_timer(0.05).timeout
		status = _bar_text(bar, true)
		if status.contains("Day"):
			break
	var all_text := _bar_text(bar, false)
	var branded := false
	for w: String in BRANDS:
		branded = branded or all_text.contains(w)
	check(status.contains("Day") and not branded, "the top bar is unbranded and shows the day (%s)" % status)
	# 9. HUD.
	var slots_ok := true
	for n: String in FpHud.SLOTS:
		slots_ok = slots_ok and fp.hud.slot(n) != null
	check(slots_ok and fp.hud.is_hud_visible(), "all six HUD slots exist and are visible")
	fp.hud.set_hud_visible(false)
	var off := not fp.hud.is_hud_visible() and not fp.hud.slot("top_bar").visible
	fp.hud.set_hud_visible(true)
	check(off and fp.hud.is_hud_visible() and fp.hud.slot("top_bar").visible, "set_hud_visible toggles the HUD")
	# 10. Pause.
	fp.set_paused(true)
	check(get_tree().paused and ctx.is_modal() and pauses.has(true), "set_paused(true) pauses the tree and pushes a modal")
	check(not ctx.world_root.can_process() and not fp.player.can_process() and fp.hud.can_process(), "paused: world_root and the player freeze, the HUD runs")
	fp.set_paused(false)
	check(not get_tree().paused and not ctx.is_modal() and ctx.world_root.can_process(), "unpause")
	# 11. Save and load (with the time of day inside the current 300 s tick).
	sim.set_tick_phase(0.4)
	var progress := sim.day_progress()
	main.save_game(SAVE)
	sim.set_tick_phase(0.9)
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(SAVE))
	var has_pos := typeof(saved) == TYPE_DICTIONARY and typeof((saved as Dictionary).get("fp", {}).get("player", {}).get("pos")) == TYPE_ARRAY
	check(has_pos, "the save carries fp.player.pos")
	var here := p.position
	p.teleport(here + Vector3(2, 0, 0), 0.0)
	var ready0 := world_ready
	var loaded: bool = main.load_game(SAVE)
	check(loaded, "load_game returns true")
	check(p.position.distance_to(here) < 0.01, "load restores the player (%s vs %s)" % [p.position, here])
	check(world_ready > ready0, "world_ready fired again on load")
	check(view.fp_mode and view.camera == fp.player.camera and get_viewport().get_camera_3d() == fp.player.camera, "after load the FP camera is still in charge")
	check(absf(sim.day_progress() - progress) < 0.01, "load restores the time of day (%.4f vs %.4f)" % [sim.day_progress(), progress])
	# 11b. A box appearing underfoot never traps the player.
	var hall_c := Vector3(D.tx(hall), 0, D.ty(hall))
	p.teleport(hall_c, 0.0)
	var trapped := fp.collision.is_blocked(p.position, WS.PLAYER_RADIUS)
	view.tile_built.emit(hall, view.tile_holder(hall))
	check(trapped and not fp.collision.is_blocked(p.position, WS.PLAYER_RADIUS) and p.position.distance_to(hall_c) < 2.0, "tile_built next to the player moves them clear (to %s)" % str(p.position))
	if front >= 0:
		var outd := Vector3(D.tx(front) - D.tx(hall), 0, D.ty(front) - D.ty(hall))
		p.teleport(hall_c, rad_to_deg(atan2(-outd.x, -outd.z)))
		for _k in range(600):
			p.simulate(Vector2(0, 1), true, DT)
		check(not fp.collision.is_blocked(p.position, WS.PLAYER_RADIUS), "the player can walk out of a box they stand in (to %s)" % str(p.position))
	p.teleport(here, 0.0)
	await _check_autosave(sim)
	# 12. Feature self-tests.
	for _k in range(30):
		await get_tree().process_frame
	var labels := _visible_labels(view)
	var bubbles := _visible_labels(view.avatars) if view.avatars != null else 0
	print("FP_SMOKE: visible Label3D under CityView: %d (resident bubbles %d)" % [labels, bubbles])
	check(view.avatars == null or not view.avatars.fp_hidden or bubbles == 0, "resident speech bubbles stay hidden while avatars.fp_hidden")
	for e: Dictionary in REGISTRY.FEATURES:
		var f := ctx.feature(str(e["id"]))
		var res: Dictionary = f.self_test() if f != null else {"ok": false, "detail": "missing"}
		print("FP_SMOKE: feature %s ok=%s %s" % [e["id"], str(bool(res.get("ok", false))).to_lower(), str(res.get("detail", ""))])
		if not bool(res.get("ok", false)):
			fails.append("feature %s self_test: %s" % [e["id"], res.get("detail", "")])
	# 13. Settle, the orbit round trip, summary.
	for _k in range(60):
		await get_tree().process_frame
	var npings := pings.size()
	# 30 s of real play at 8x leaves most of a 300 s tick pending; the 12 s orbit day must not
	# drain it as dozens of ticks.
	fp.set_time_scale(8)
	sim.set_tick_phase(0.8)
	var progress0 := sim.day_progress()
	var tick0 := sim.global_tick()
	main.exit_fp()
	check(absf(sim.day_progress() - progress0) < 1e-4, "exit_fp keeps the time of day (%.4f vs %.4f)" % [sim.day_progress(), progress0])
	for _k in range(10):
		await get_tree().process_frame
	var speed_btns: Dictionary = main.hud.get("_speed_btns")
	check(sim.global_tick() - tick0 <= 1 and sim.speed == 1 and (speed_btns[1] as Button).button_pressed, "after exit_fp: %d ticks in 10 frames, orbit speed %d shown" % [sim.global_tick() - tick0, sim.speed])
	check(main.fp == null and main.view_mode == "orbit" and get_viewport().get_camera_3d() == main.camera and main.hud.visible and not view.fp_mode and is_equal_approx(sim.day_seconds, 12.0), "exit_fp returns to the orbit view")
	main.enter_fp()
	await get_tree().process_frame
	check(main.fp != null and get_viewport().get_camera_3d() == main.fp.player.camera and view.fp_mode and not main.hud.visible, "enter_fp again rebuilds first person")
	print("FP_SMOKE: day=%d pop=%d features=%d pings=%d" % [sim.day, int(sim.stats["population"]), ctx.features.size(), npings])
	_finish()


func _finish() -> void:
	print("FP_SMOKE: " + ("PASS" if fails.is_empty() else "FAIL " + str(fails)))
	main.audio._exit_tree()
	get_tree().quit(0 if fails.is_empty() else 1)


func _listen(fp: FpMode) -> void:
	fp.bus.ping.connect(func(_p: Vector3, reason: String) -> void: pings.append(reason))
	fp.bus.time_scale_changed.connect(func(s: int) -> void: scales.append(s))
	fp.bus.pause_changed.connect(func(v: bool) -> void: pauses.append(v))
	fp.bus.player_tile_changed.connect(func(_x: int, _y: int) -> void: tile_events += 1)
	fp.bus.world_ready.connect(func() -> void: world_ready += 1)


func _orbit_layers_hidden(view: CityView) -> bool:
	for key: String in ["_labels_root", "_territory_root", "_power_icons", "_water_icons", "_cursor"]:
		var n: Node3D = view.get(key)
		if n != null and n.visible:
			return false
	for av: Dictionary in view.get("_avatars"):
		if (av["root"] as Node3D).visible:
			return false
	return true


## The text of every Label and RichTextLabel under n, joined with " | " (visible ones only when
## visible_only is set).
func _bar_text(n: Node, visible_only: bool) -> String:
	var parts: PackedStringArray = []
	for c: Node in n.find_children("*", "Control", true, false):
		if visible_only and not (c as Control).is_visible_in_tree():
			continue
		if c is Label:
			parts.append((c as Label).text)
		elif c is RichTextLabel:
			parts.append((c as RichTextLabel).get_parsed_text())
	return " | ".join(parts)


func _visible_labels(n: Node) -> int:
	var c := 1 if n is Label3D and (n as Label3D).is_visible_in_tree() else 0
	for k in n.get_children():
		c += _visible_labels(k)
	return c


func _find_kind(sim: CitySim, k: int) -> int:
	for i in sim.active:
		if sim.kind[i] == k:
			return i
	return -1


func _find_level(sim: CitySim, k: int) -> int:
	for i in sim.active:
		if sim.kind[i] == k and sim.level[i] > 0:
			return i
	return -1
