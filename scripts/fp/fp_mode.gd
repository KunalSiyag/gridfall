class_name FpMode
extends Node3D
## First-person composition root: builds the context, bus, player, collision, HUD and every
## registered feature, owns time controls, pause, the mouse and the FP save section.

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const REGISTRY := preload("res://scripts/fp/fp_features.gd")
const SETTINGS_PATH := "user://gridfall_fp_settings.json"
const DEFAULT_SETTINGS := {
	"mouse_sensitivity": 0.0022, "invert_y": false, "fov": 72.0, "head_bob": true,
	"quality": "medium", "show_hud": true, "music_volume_db": 0.0, "sfx_volume_db": 0.0,
}
## Save keys FpMode owns; a feature id must not use them.
const RESERVED_KEYS := ["version", "player", "time_scale"]
const SAVE_VERSION := 1

var ctx: FpContext
var bus: GameBus
var player: FpPlayer
var collision: CollisionWorld
var hud: FpHud
var directory: CityDirectory
var time_scale: int = 1
var paused: bool = false
## Every patch passed to apply_settings, in order (tests read it; also filled when not set up).
var settings_log: Array[Dictionary] = []
## False keeps the pointer free (scripted tours and benchmarks; GRIDFALL_FP_PHOTO_DIR or
## GRIDFALL_MOUSE=free), so a windowed test run never grabs the desktop pointer.
var capture_mouse: bool = true
var _set_up: bool = false
var _features_node: Node3D
var _focused: bool = true
var _skipping: bool = false


## Builds everything. main is the Main node (main.gd); reads its sim, residents, minds, brain,
## client, view, sky, audio, camera and sun_light fields.
func setup(main: Node3D) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if OS.has_environment("GRIDFALL_FP_PHOTO_DIR") or OS.get_environment("GRIDFALL_MOUSE") == "free":
		capture_mouse = false
	var settings := _load_settings()
	bus = GameBus.new()
	bus.name = "Bus"
	add_child(bus)
	directory = CityDirectory.new()
	directory.setup(main.get("sim"))
	ctx = FpContext.new()
	ctx.main = main
	ctx.mode = self
	ctx.sim = main.get("sim")
	ctx.residents = main.get("residents")
	ctx.minds = main.get("minds")
	ctx.brain = main.get("brain")
	ctx.client = main.get("client")
	ctx.view = main.get("view")
	ctx.sky = main.get("sky")
	ctx.audio = main.get("audio")
	ctx.sun = main.get("sun_light")
	var cam: Camera3D = main.get("camera")
	ctx.env = cam.environment if cam != null else null
	ctx.bus = bus
	ctx.directory = directory
	ctx.settings = settings
	collision = CollisionWorld.new()
	collision.name = "Collision"
	add_child(collision)
	collision.setup(ctx)
	ctx.collision = collision
	var world := Node3D.new()
	world.name = "World"
	add_child(world)
	ctx.world_root = world
	player = FpPlayer.new()
	player.name = "Player"
	player.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(player)
	ctx.player = player
	player.setup(ctx)
	hud = FpHud.new()
	hud.name = "FpHud"
	add_child(hud)
	ctx.hud = hud
	hud.setup(ctx)
	_features_node = Node3D.new()
	_features_node.name = "Features"
	_features_node.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(_features_node)
	var order: Array[FpFeature] = []
	for entry: Dictionary in REGISTRY.FEATURES:
		var id := str(entry["id"])
		var path := str(entry["path"])
		if not ResourceLoader.exists(path):
			push_warning("FpMode: feature %s missing at %s" % [id, path])
			continue
		var f: FpFeature = (load(path) as GDScript).new()
		f.name = id
		_features_node.add_child(f)
		ctx.features[id] = f
		order.append(f)
	for f in order:
		f.setup(ctx)
	ctx.view.world_rebuilt.connect(_on_world_rebuilt)
	ctx.view.tile_built.connect(collision.on_tile_built)
	ctx.view.tile_cleared.connect(collision.on_tile_cleared)
	bus.modal_changed.connect(func(_a: bool) -> void: _update_mouse_mode())
	_set_up = true
	_on_world_rebuilt()
	from_dict({})
	_update_mouse_mode.call_deferred()


## Tears down the features (reverse order) and the HUD, releases the mouse, unpauses.
func teardown() -> void:
	if not _set_up:
		return
	_set_up = false
	var list := _feature_list()
	list.reverse()
	for f in list:
		f.teardown()
	if ctx.view != null:
		if ctx.view.world_rebuilt.is_connected(_on_world_rebuilt):
			ctx.view.world_rebuilt.disconnect(_on_world_rebuilt)
		if ctx.view.tile_built.is_connected(collision.on_tile_built):
			ctx.view.tile_built.disconnect(collision.on_tile_built)
		if ctx.view.tile_cleared.is_connected(collision.on_tile_cleared):
			ctx.view.tile_cleared.disconnect(collision.on_tile_cleared)
	if hud != null:
		hud.queue_free()
		hud = null
		ctx.hud = null
	paused = false
	if is_inside_tree():
		get_tree().paused = false
	if not _headless():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Save section, see S0 §6.4.
func to_dict() -> Dictionary:
	var d := {"version": SAVE_VERSION, "player": player.to_dict() if player != null else {}, "time_scale": time_scale}
	for f in _feature_list():
		var id := f.feature_id()
		if id.is_empty() or id in RESERVED_KEYS:
			continue
		var fd := f.to_dict()
		if not fd.is_empty():
			d[id] = fd
	return d


## Restores the save section. {} means a fresh city: player at spawn_point(), features reset.
func from_dict(d: Dictionary) -> void:
	if player != null:
		player.from_dict(d.get("player", {}) if typeof(d.get("player")) == TYPE_DICTIONARY else {})
	if d.has("time_scale"):
		set_time_scale(int(d["time_scale"]))
	for f in _feature_list():
		var fd: Variant = d.get(f.feature_id(), {})
		f.from_dict(fd if typeof(fd) == TYPE_DICTIONARY else {})


## Sets the sim speed to s, snapped to WS.TIME_SCALES; emits bus.time_scale_changed. Paused: stored, applied on resume.
func set_time_scale(s: int) -> void:
	var best: int = WS.TIME_SCALES[0]
	for v: int in WS.TIME_SCALES:
		if absi(v - s) < absi(best - s):
			best = v
	time_scale = best
	if not paused and ctx != null and ctx.sim != null:
		ctx.sim.set_speed(time_scale)
	if bus != null:
		bus.time_scale_changed.emit(time_scale)


## +1 / -1 through WS.TIME_SCALES (bound to time_faster / time_slower).
func step_time_scale(dir: int) -> void:
	var k := maxi(0, WS.TIME_SCALES.find(time_scale))
	set_time_scale(WS.TIME_SCALES[clampi(k + signi(dir), 0, WS.TIME_SCALES.size() - 1)])


## Runs the rest of today's ticks now, so the next day starts at 06:00 (bound to time_skip). Coroutine:
## toasts "Skipping to morning...", awaits 2 frames, then calls sim.skip_to_next_day().
func skip_to_morning() -> void:
	if _skipping or ctx == null or ctx.sim == null:
		return
	_skipping = true
	if bus != null:
		bus.toast.emit("Skipping to morning...", "system")
	await get_tree().process_frame
	await get_tree().process_frame
	ctx.sim.skip_to_next_day()
	_skipping = false


## Pauses the whole SceneTree (get_tree().paused). The FpHud and FpMode keep running. Emits bus.pause_changed.
func set_paused(p: bool) -> void:
	if p == paused:
		return
	paused = p
	get_tree().paused = p
	if ctx != null:
		if p:
			ctx.push_modal(&"pause")
		else:
			ctx.pop_modal(&"pause")
	if not p and ctx != null and ctx.sim != null:
		ctx.sim.set_speed(time_scale)
	if bus != null:
		bus.pause_changed.emit(p)
	_update_mouse_mode()


## Appends patch to settings_log, merges it into ctx.settings, saves SETTINGS_PATH (skipped when
## setup() never ran, as in fp_kit's stub mode), emits bus.settings_changed(settings) and, if
## "quality" changed, bus.quality_changed(preset).
func apply_settings(patch: Dictionary) -> void:
	settings_log.append(patch.duplicate(true))
	if ctx == null:
		return
	var old_quality := str(ctx.settings.get("quality", ""))
	for k: Variant in patch.keys():
		ctx.settings[k] = patch[k]
	if _set_up:
		_save_settings()
	if bus != null:
		bus.settings_changed.emit(ctx.settings)
		var q := str(ctx.settings.get("quality", ""))
		if q != old_quality:
			bus.quality_changed.emit(q)


## Feet position and yaw for a fresh player: the sidewalk in front of City Hall (S0 §7.3).
## {"pos": Vector3, "yaw": float (deg)}.
func spawn_point() -> Dictionary:
	var pos := Vector3(15.5, 0.0, 13.5)
	var yaw := 0.0
	var sim: CitySim = ctx.sim if ctx != null else null
	if sim == null:
		return {"pos": pos, "yaw": yaw}
	var hall := -1
	for i in sim.active:
		if sim.kind[i] == D.HALL:
			hall = i
			break
	var r := directory.frontage(hall) if hall >= 0 and directory != null else -1
	if r >= 0:
		var dir := Vector3(D.tx(hall) - D.tx(r), 0.0, D.ty(hall) - D.ty(r))
		pos = Vector3(D.tx(r), 0.0, D.ty(r)) + dir * WS.SIDEWALK_CENTER
		yaw = rad_to_deg(atan2(-dir.x, -dir.z))
	else:
		var best := -1
		var best_d := INF
		for i in sim.active:
			if sim.kind[i] != D.ROAD:
				continue
			var dd := Vector2(D.tx(i) - 15.5, D.ty(i) - 13.5).length_squared()
			if dd < best_d:
				best_d = dd
				best = i
		if best >= 0:
			pos = RoadTopology.sidewalk_point(sim, best, 1)
			var f := RoadTopology.run_dir(RoadTopology.mask(sim, D.tx(best), D.ty(best)))
			yaw = rad_to_deg(atan2(-f.x, -f.z))
	var g := collision.ground_height(pos) if collision != null else NAN
	pos.y = g if not is_nan(g) else 0.0
	return {"pos": pos, "yaw": yaw}


func _on_world_rebuilt() -> void:
	collision.rebuild_all()
	directory.rebuild()
	player.snap_to_ground()
	for f in _feature_list():
		f.on_world_rebuilt()
	bus.world_ready.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not _set_up:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and not paused and not ctx.is_modal() and capture_mouse and not _headless() and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			get_viewport().set_input_as_handled()
		return
	if event.is_echo():
		return
	if event.is_action_pressed("pause_menu"):
		set_paused(not paused)
		get_viewport().set_input_as_handled()
		return
	if _hotkeys_blocked():
		return
	if event.is_action_pressed("time_faster") or event.is_action_pressed("time_slower"):
		step_time_scale(1 if event.is_action_pressed("time_faster") else -1)
		bus.toast.emit("Time %dx" % time_scale, "system")
	elif event.is_action_pressed("time_skip"):
		skip_to_morning()
	elif event.is_action_pressed("hud_toggle"):
		if player.photo_mode:
			return
		hud.set_hud_visible(not hud.is_hud_visible())
	elif event.is_action_pressed("quick_save"):
		if ctx.main != null:
			ctx.main.call("save_game")
	elif event.is_action_pressed("quick_load"):
		if ctx.main != null:
			ctx.main.call("load_game")
	else:
		return
	get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_focused = true
		_update_mouse_mode()
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_focused = false
		_update_mouse_mode()


## Hotkeys work with nothing modal, or under the pause card alone (S0 §7.2).
func _hotkeys_blocked() -> bool:
	return ctx.is_modal() and not (ctx.modal_count() == 1 and ctx.has_modal(&"pause"))


## Captured iff not paused, nothing modal and the window has focus; headless runs skip it.
func _update_mouse_mode() -> void:
	if not _set_up or _headless() or not is_inside_tree():
		return
	var want := capture_mouse and not paused and not ctx.is_modal() and _focused
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if want else Input.MOUSE_MODE_VISIBLE


func _feature_list() -> Array[FpFeature]:
	var out: Array[FpFeature] = []
	if ctx == null:
		return out
	for entry: Dictionary in REGISTRY.FEATURES:
		var f: FpFeature = ctx.features.get(str(entry["id"]), null)
		if f != null and is_instance_valid(f):
			out.append(f)
	return out


func _load_settings() -> Dictionary:
	var s := DEFAULT_SETTINGS.duplicate(true)
	if not FileAccess.file_exists(SETTINGS_PATH):
		return s
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		return s
	for k: Variant in (parsed as Dictionary).keys():
		if not s.has(k):
			continue
		var v: Variant = (parsed as Dictionary)[k]
		var numeric := typeof(v) in [TYPE_INT, TYPE_FLOAT] and typeof(s[k]) in [TYPE_INT, TYPE_FLOAT]
		if typeof(v) == typeof(s[k]) or numeric:
			s[k] = v
	return s


func _save_settings() -> void:
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(ctx.settings))
	f.close()


static func _headless() -> bool:
	return DisplayServer.get_name() == "headless"
