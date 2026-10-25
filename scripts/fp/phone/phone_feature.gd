extends FpFeature
## The phone and its Build app (integration feature "phone"). B opens a phone that orders roads,
## zones, buildings and bulldozing on the tile the hero looks at. Each order is placed for the
## mayor who owns that land and paid from that district's treasury, through
## CitySim.apply_player_order, so it follows the same rules as the mayors' own orders; the
## construction sites it opens go to the player's crews, which build in real time (the crews
## feature draws them; with its flag off orders go to the contractors through apply_action). The
## phone says how many crews are free and how long an order would take.

const D := preload("res://scripts/sim/sim_defs.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const RULES := preload("res://scripts/fp/phone/build_rules.gd")
const PHONE := preload("res://scripts/fp/phone/phone_ui.gd")
const GHOST := preload("res://scripts/fp/phone/build_ghost.gd")
## How far ahead of the hero the phone aims, in tiles: looking up, level and down.
const REACH := 6.0
const AIM_LEVEL := 2.0
const NEAR := 0.6
const AIM_UP := deg_to_rad(25.0)
const AIM_DOWN := deg_to_rad(40.0)
const REFRESH := 0.1
const HINT := "LMB place   RMB undo   B close\n1-6 tools   Wheel surface or building"

var open: bool = false
var tool: String = "road"
var building: String = "park"
## The road tool's surface, a D.ROAD_GRADES index (paved unless the road_grades flag is on).
var grade: int = D.GRADE_PAVED
var anchor: Vector2i = D.NO_TILE
var target: Vector2i = D.NO_TILE
var preview: Dictionary = {}
var phone: PHONE
var ghost: GHOST
var _driving: bool = false
var _t: float = 0.0


func feature_id() -> String:
	return "phone"


func setup(p_ctx: FpContext) -> void:
	super.setup(p_ctx)
	if ctx.hud != null:
		phone = PHONE.new()
		phone.setup()
		ctx.hud.slot("overlay").add_child(phone)
	if ctx.world_root != null:
		ghost = GHOST.new()
		ghost.setup()
		ctx.world_root.add_child(ghost)
	if ctx.bus != null:
		ctx.bus.drive_changed.connect(_on_drive_changed)


func teardown() -> void:
	close_phone()
	if ctx != null and ctx.bus != null and ctx.bus.drive_changed.is_connected(_on_drive_changed):
		ctx.bus.drive_changed.disconnect(_on_drive_changed)
	for n: Node in [phone, ghost]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	phone = null
	ghost = null


func on_world_rebuilt() -> void:
	anchor = D.NO_TILE
	if open:
		refresh()


func from_dict(_d: Dictionary) -> void:
	close_phone()


func self_test() -> Dictionary:
	var path := RULES.road_path(Vector2i(0, 0), Vector2i(2, 1))
	return {"ok": path.size() == 4, "detail": "road (0,0)->(2,1): %d tiles" % path.size()}


# ------------------------------------------------------------------ phone


## Opens the phone; false while driving, in a menu or without a city.
func open_phone() -> bool:
	if open:
		return true
	if _driving or ctx == null or ctx.sim == null or ctx.player == null or ctx.is_modal():
		return false
	open = true
	anchor = D.NO_TILE
	if phone != null:
		phone.set_shown(true)
	refresh()
	return true


func close_phone() -> void:
	open = false
	anchor = D.NO_TILE
	preview = {}
	if phone != null and is_instance_valid(phone):
		phone.set_shown(false)
	if ghost != null and is_instance_valid(ghost):
		ghost.clear()


func set_tool(id: String) -> void:
	if not RULES.TOOLS.has(id):
		return
	if id != tool:
		anchor = D.NO_TILE
	tool = id
	refresh()


## Steps through the Build tool's list (d = +1 or -1).
func cycle_building(d: int) -> void:
	var k := RULES.BUILDINGS.find(building)
	building = RULES.BUILDINGS[posmod(k + d, RULES.BUILDINGS.size())]
	refresh()


## Steps through the road surfaces, paved to grass trail (d = +1 or -1).
func cycle_grade(d: int) -> void:
	grade = posmod(grade + d, D.ROAD_GRADES.size())
	refresh()


## The tile ahead of the hero along the camera's heading. A tile is 20 m and the eye under 2 m up,
## so a ray to the ground would swing by tiles per degree: the pitch picks the distance instead.
func aim_tile() -> Vector2i:
	var p := ctx.player
	var dir := p.forward()
	if p.camera != null:
		dir = -p.camera.global_basis.z
	var flat := Vector2(dir.x, dir.z)
	if flat.length() < 1e-3:
		flat = Vector2(p.forward().x, p.forward().z)
	var at := flat.normalized() * aim_distance(asin(clampf(dir.y, -1.0, 1.0)))
	return Vector2i(roundi(p.position.x + at.x), roundi(p.position.z + at.y))


## Tiles ahead for a view pitch: AIM_LEVEL looking straight ahead, out to REACH looking up by
## AIM_UP, in to NEAR looking down by AIM_DOWN.
static func aim_distance(pitch: float) -> float:
	if pitch >= 0.0:
		return lerpf(AIM_LEVEL, REACH, clampf(pitch / AIM_UP, 0.0, 1.0))
	return lerpf(AIM_LEVEL, NEAR, clampf(-pitch / AIM_DOWN, 0.0, 1.0))


## Re-aims and re-checks the order, then redraws the ghost and the phone.
func refresh() -> void:
	if open:
		refresh_at(aim_tile())


## Re-checks the order at tile t and redraws the ghost and the phone.
func refresh_at(t: Vector2i) -> void:
	if not open:
		return
	target = t
	preview = RULES.preview(ctx.sim, tool, anchor, target, building, grade)
	var tiles: Array = preview["tiles"]
	if tiles.is_empty():
		tiles = [target]
	if ghost != null:
		ghost.show_tiles(tiles, _can_click(), anchor)
	if phone != null:
		phone.show_state(_state())


func _state() -> Dictionary:
	var mi := int(preview.get("mi", -1))
	var st := {"tool": tool, "ok": _can_click(), "hint": HINT}
	if mi >= 0:
		st["district"] = str(D.MAYORS[mi]["district"])
		st["mayor"] = "Acting for Mayor %s" % ctx.sim.mayors[mi]["name"]
		st["treasury"] = int(ctx.sim.mayors[mi]["treasury"])
	else:
		st["district"] = "Unclaimed land"
		st["mayor"] = "No mayor builds here"
	if tool == "build":
		var spec: Dictionary = D.BUILDINGS[building]
		st["building"] = "‹ %s  %s ›" % [spec["label"], "$" + str(spec["cost"])]
	elif tool == "road" and ctx.sim.road_grades:
		var g := D.grade_info(grade)
		st["building"] = "‹ %s  $%d a tile ›" % [g["label"], int(g["cost"])]
	st["line"] = _line()
	st["crews"] = _crews_line()
	return st


## How many of the player's crews are free and, for a road or a building, how long this order
## would take or when a crew frees up for it. "" while construction is instant.
func _crews_line() -> String:
	var sim := ctx.sim
	if not sim.staged() or not FeatureFlags.enabled("crews"):
		return ""
	var free := sim.crews_free()
	var line := "Crews: %d of %d free" % [free, D.CREWS] if free > 0 else "Crews: all busy"
	var secs := RULES.crew_seconds(sim, tool, building, preview)
	if secs < 0.0:
		return line
	if free > 0:
		return "%s · builds in %s" % [line, S.countdown(secs, sim.speed)]
	return "%s · starts in %s" % [line, S.countdown(sim.crew_wait(), sim.speed)]


## True while a click here would do something: place the order, or set a first corner.
func _can_click() -> bool:
	return bool(preview.get("ok", false)) or (_first() and int(preview.get("mi", -1)) >= 0)


func _first() -> bool:
	return RULES.TWO_POINT.has(tool) and anchor == D.NO_TILE


func _line() -> String:
	if _first() and int(preview.get("mi", -1)) >= 0:
		return "Click to start the road here" if tool == "road" else "Click a first corner"
	if not bool(preview.get("ok", false)):
		return str(preview.get("reason", ""))
	var n: int = (preview["tiles"] as Array).size()
	var cost := "$%d" % int(preview["cost"])
	match tool:
		"road":
			var what := (
				"road" if grade == D.GRADE_PAVED else str(D.grade_info(grade)["label"]).to_lower()
			)
			return "%d tiles of %s, %s" % [n, what, cost]
		"zone_r", "zone_c", "zone_i":
			var what := str(RULES.TOOL_LABELS[tool]).to_lower()
			return "Zone %d tiles for %s, %s" % [n, what, cost]
		"build":
			return "Place a %s here, %s" % [D.BUILDINGS[building]["label"], cost]
	return "Clear this lot, %s" % cost


## Places the order at the aimed tile. A road or zone takes two clicks: the first sets the corner.
## Returns apply_action's {ok, reason, cost}, {"ok": true, "pending": true} after a first corner,
## or {"ok": false, "reason"} when the preview already says no.
func place() -> Dictionary:
	return place_at(aim_tile()) if open else {"ok": false, "reason": "the phone is closed"}


## place() at tile t instead of the aimed tile.
func place_at(t: Vector2i) -> Dictionary:
	if not open:
		return {"ok": false, "reason": "the phone is closed"}
	refresh_at(t)
	if _first():
		if int(preview.get("mi", -1)) < 0:
			_toast(str(preview["reason"]), "alert")
			return {"ok": false, "reason": preview["reason"]}
		anchor = target
		refresh_at(t)
		return {"ok": true, "pending": true}
	if not bool(preview.get("ok", false)):
		_toast(str(preview.get("reason", "")), "alert")
		return {"ok": false, "reason": preview.get("reason", "")}
	var mi := int(preview["mi"])
	var a: Dictionary = preview["action"]
	var crews := FeatureFlags.enabled("crews")
	var res := ctx.sim.apply_player_order(mi, a) if crews else ctx.sim.apply_action(mi, a)
	if bool(res.get("ok", false)):
		_toast(_placed(mi, res), "success")
		if res.has("job"):
			Analytics.track("crew_order", {"tool": tool, "queued": int(res["job"]["crew"]) < 0})
	else:
		_toast(_sentence(str(res.get("reason", ""))), "alert")
	anchor = D.NO_TILE
	refresh_at(t)
	return res


## The toast for a placed order: the district and what happened, or for a crew order who builds
## it and when ("Police Station: crew 1 on it, ready in 2:19").
func _placed(mi: int, res: Dictionary) -> String:
	var j: Dictionary = res.get("job", {})
	if j.is_empty():
		return "%s: %s" % [D.MAYORS[mi]["district"], _brief(str(res.get("reason", "")))]
	var when: Vector2 = ctx.sim.crew_schedule().get(int(j["id"]), Vector2.ZERO)
	var sp := ctx.sim.speed
	if int(j["crew"]) >= 0:
		var c := int(j["crew"]) + 1
		return "%s: crew %d on it, ready in %s" % [j["label"], c, S.countdown(when.y, sp)]
	return "%s: all crews busy, starts in %s" % [j["label"], S.countdown(when.x, sp)]


## Drops the first corner, or closes the phone when there is none.
func cancel() -> void:
	if anchor != D.NO_TILE:
		anchor = D.NO_TILE
		refresh()
	else:
		close_phone()


func _process(delta: float) -> void:
	if not open:
		return
	if _driving or ctx == null or ctx.is_modal():
		close_phone()
		return
	_t -= delta
	if _t <= 0.0:
		_t = REFRESH
		refresh()


func _input(event: InputEvent) -> void:
	if ctx == null or ctx.player == null or event.is_echo():
		return
	if not open:
		if event.is_action_pressed("phone_toggle") and open_phone():
			get_viewport().set_input_as_handled()
		return
	if ctx.is_modal():
		return
	var handled := true
	if event.is_action_pressed("phone_toggle") or event.is_action_pressed("pause_menu"):
		close_phone()
	elif event is InputEventKey and (event as InputEventKey).pressed:
		var k := int((event as InputEventKey).physical_keycode) - KEY_1
		if k >= 0 and k < RULES.TOOLS.size():
			set_tool(RULES.TOOLS[k])
		else:
			handled = false
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		handled = _click(event as InputEventMouseButton)
	else:
		handled = false
	if handled and is_inside_tree():
		get_viewport().set_input_as_handled()


func _click(mb: InputEventMouseButton) -> bool:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not DisplayServer.get_name() == "headless":
		return false
	match mb.button_index:
		MOUSE_BUTTON_LEFT:
			place()
		MOUSE_BUTTON_RIGHT:
			cancel()
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			var d := -1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1
			if tool == "build":
				cycle_building(d)
			elif tool == "road" and ctx.sim.road_grades:
				cycle_grade(d)
			else:
				return false
		_:
			return false
	return true


func _on_drive_changed(active: bool) -> void:
	_driving = active
	if active:
		close_phone()


func _toast(text: String, kind: String) -> void:
	if ctx.bus != null and not text.is_empty():
		ctx.bus.toast.emit(text, kind)


## The sim's reason up to its first aside: "road construction started on 4 tiles (open in ..."
## -> "Road construction started on 4 tiles".
static func _brief(t: String) -> String:
	for cut: String in [" (", ";"]:
		var k := t.find(cut)
		if k > 0:
			t = t.left(k)
	return _sentence(t)


static func _sentence(t: String) -> String:
	return t.substr(0, 1).to_upper() + t.substr(1) if not t.is_empty() else t
