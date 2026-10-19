extends FpFeature
## City overview: Tab lifts the camera off the hero into an aerial view of the city, with a marker
## over every open construction site and a list of them. N / B fly between sites, F puts the hero on
## the site's sidewalk to watch it go up, G sets a GPS waypoint there, Tab or Esc returns to the
## street. While it is open the hero stands still (a modal is pushed, so the mouse is free for the
## list) and the time controls keep working. "Planner view" leaves for the orbit view (Main.exit_fp).

const D := preload("res://scripts/sim/sim_defs.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const MODAL := &"overview"
const FOV := 50.0
const BLEND_IN := 0.7
const BLEND_OUT := 0.6
## Camera distance from the pivot, world units (1 u = 20 m).
const DIST_MIN := 2.5
const DIST_MAX := 32.0
const DIST_START := 9.0
const DIST_SITE := 4.5
const PITCH_MIN := deg_to_rad(30.0)
const PITCH_MAX := deg_to_rad(85.0)
const PITCH_START := deg_to_rad(55.0)
const HL_CAM := 0.1
const HL_FLY := 0.3
## Pivot speed per unit of camera distance, per second.
const PAN_RATE := 1.1
const KEY_ROTATE := deg_to_rad(90.0)
const MOUSE_ROTATE := 0.005
const MOUSE_TILT := 0.004
const MOUSE_PAN := 0.0016
const ZOOM_STEP := 1.15
## A press that moves less than this (px) before release is a click, not a drag.
const CLICK_SLOP := 6.0
## A click selects the nearest site within this many tiles of the ground point under the cursor.
const PICK_RADIUS := 1.5
const REFRESH := 0.5
const LIST_MAX := 8
## Marker label height above the ground (u): over a mid-rise; labels draw through buildings anyway.
const MARKER_Y := 1.4
## Markers nearest the view centre (plus the selected one) get the full label; the rest a percent.
const FULL_LABELS := 6
## Without road frontage the hero stands this far (u) from the lot centre: clear of the hoarding,
## with the whole build in frame.
const STAND_BACK := 1.1
## View pitch (deg, up) after walking to a site, so the rising frame fills the shot.
const WATCH_PITCH := 10.0
## Seconds between "construction started" toasts on the street.
const TOAST_GAP := 25.0
const SITE_COLOR := Color("#FFB547")
const PICK_COLOR := Color("#00E0FF")

var active: bool = false
## Tile index of the selected site, or -1.
var selected: int = -1
## Open sites by tile index -> marker root (only while active).
var markers: Dictionary = {}
var _pivot: Vector3 = Vector3.ZERO
var _yaw: float = 0.0
var _pitch: float = PITCH_START
var _dist: float = DIST_START
var _c_pivot: Vector3 = Vector3.ZERO
var _c_yaw: float = 0.0
var _c_pitch: float = PITCH_START
var _c_dist: float = DIST_START
var _flying: bool = false
var _refresh_t: float = 0.0
var _toast_cool: float = 0.0
var _drag_button: int = 0
var _drag_moved: float = 0.0
var _press_at: Vector2 = Vector2.ZERO
var _markers_root: Node3D
var _you: Label3D
var _site_mat: StandardMaterial3D
var _pick_mat: StandardMaterial3D
var _layer: CanvasLayer
var _panel: PanelContainer
var _summary: Label
var _rows: VBoxContainer
var _empty: Label
var _detail: Label
var _walk_btn: Button
var _wp_btn: Button
var _hints: Control


func feature_id() -> String:
	return "overview"


func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	_markers_root = Node3D.new()
	_markers_root.name = "Markers"
	add_child(_markers_root)
	_site_mat = _beam_mat(SITE_COLOR)
	_pick_mat = _beam_mat(PICK_COLOR)
	_you = Label3D.new()
	_you.name = "You"
	_you.text = "YOU"
	_you.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_you.fixed_size = true
	_you.no_depth_test = true
	_you.render_priority = 10
	_you.outline_render_priority = 9
	_you.pixel_size = 0.0009
	_you.font = S.bold()
	_you.font_size = 26
	_you.outline_size = 10
	_you.modulate = PICK_COLOR
	_you.outline_modulate = Color(0.02, 0.03, 0.05, 0.85)
	_you.visible = false
	add_child(_you)
	_build_ui()
	if ctx.sim != null:
		ctx.sim.site_started.connect(_on_site_started)


func on_world_rebuilt() -> void:
	if active:
		exit(0.0)


func from_dict(_d: Dictionary) -> void:
	if active:
		exit(0.0)


func teardown() -> void:
	if active:
		exit(0.0)
	if ctx != null and ctx.sim != null and ctx.sim.site_started.is_connected(_on_site_started):
		ctx.sim.site_started.disconnect(_on_site_started)


## True when the overview may open now: on foot, nothing modal, not paused, flying or talking.
func can_enter() -> bool:
	if active or ctx == null or ctx.player == null or ctx.is_modal():
		return false
	if ctx.mode != null and ctx.mode.paused:
		return false
	return not ctx.player.photo_mode and not ctx.player.in_conversation()


## Opens the overview over the hero. False when it may not open now.
func enter() -> bool:
	if not can_enter():
		return false
	active = true
	ctx.push_modal(MODAL)
	var p := ctx.player
	_pivot = Vector3(p.position.x, 0.0, p.position.z)
	_yaw = p.cam_yaw
	_pitch = PITCH_START
	_dist = DIST_START
	_snap_camera()
	_flying = false
	selected = -1
	_drag_button = 0
	p.set_view_override(camera_xform(), FOV, BLEND_IN)
	_layer.visible = true
	_you.visible = true
	_refresh()
	Analytics.track("overview_open", {"sites": markers.size()})
	return true


## Back to the hero's own camera, easing over blend seconds.
func exit(blend: float = BLEND_OUT) -> void:
	if not active:
		return
	active = false
	_drag_button = 0
	if ctx != null:
		ctx.pop_modal(MODAL)
		if ctx.player != null and is_instance_valid(ctx.player):
			ctx.player.clear_view_override(blend)
	_layer.visible = false
	_you.visible = false
	for i: int in markers.keys():
		(markers[i] as Node3D).queue_free()
	markers.clear()
	Analytics.track("overview_close")


func toggle() -> void:
	if active:
		exit()
	else:
		enter()


## Open construction sites other than road paving (one per tile, too many to list), newest first:
## [{"i": tile, "id", "label", "type"}].
func site_list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if ctx == null or ctx.sim == null:
		return out
	for i: int in ctx.sim.sites.keys():
		var s: Dictionary = ctx.sim.sites[i]
		if str(s.get("type", "")) == "road":
			continue
		out.append({"i": i, "id": int(s.get("id", 0)), "label": str(s.get("label", "Construction")), "type": str(s.get("type", ""))})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["id"]) > int(b["id"]))
	return out


## Road tiles being paved right now.
func road_site_count() -> int:
	var n := 0
	if ctx != null and ctx.sim != null:
		for s: Dictionary in ctx.sim.sites.values():
			if str(s.get("type", "")) == "road":
				n += 1
	return n


## Selects the next (dir 1) or previous (dir -1) site in site_list() and flies to it. False if none.
func select_step(dir: int) -> bool:
	var list := site_list()
	if list.is_empty():
		if ctx.bus != null:
			ctx.bus.toast.emit("No construction right now. The mayors start new projects every morning.", "info")
		return false
	var k := -1
	for n in range(list.size()):
		if int(list[n]["i"]) == selected:
			k = n
	k = 0 if k < 0 and dir > 0 else (list.size() - 1 if k < 0 else posmod(k + dir, list.size()))
	focus_site(int(list[k]["i"]))
	return true


## Selects the site on tile i and flies the camera over it.
func focus_site(i: int) -> void:
	selected = i
	_pivot = Vector3(D.tx(i), 0.0, D.ty(i))
	_dist = minf(_dist, DIST_SITE)
	_pitch = maxf(_pitch, deg_to_rad(45.0))
	_flying = true
	_refresh()


## A vantage point to watch lot i go up: the far sidewalk across its frontage street (else the
## near one), or STAND_BACK from the lot toward the hero when it has no road. {"pos": feet,
## "yaw": deg facing the lot}, on free ground.
func stand_point(i: int) -> Dictionary:
	var lot := Vector3(D.tx(i), 0.0, D.ty(i))
	var r := ctx.directory.frontage(i) if ctx.directory != null else -1
	var cands: Array[Vector3] = []
	if r >= 0:
		var road := Vector3(D.tx(r), 0.0, D.ty(r))
		var dir := lot - road
		cands.append(road - dir * WS.SIDEWALK_CENTER)
		cands.append(road + dir * WS.SIDEWALK_CENTER)
	var away := Vector3(ctx.player.position.x - lot.x, 0.0, ctx.player.position.z - lot.z) if ctx.player != null else Vector3.ZERO
	away = away.normalized() if away.length_squared() > 1e-6 else Vector3(0.0, 0.0, 1.0)
	cands.append(lot + away * STAND_BACK)
	var pos := cands[0]
	for c: Vector3 in cands:
		if _free(c):
			pos = c
			break
	if ctx.collision != null:
		var g := ctx.collision.ground_height(pos)
		pos.y = g if not is_nan(g) else 0.0
		if ctx.collision.is_blocked(pos, WS.PLAYER_RADIUS):
			var q := ctx.collision.nearest_free(pos, WS.PLAYER_RADIUS, 2.0)
			if not is_nan(q.x):
				pos = q
	var to_lot := lot - pos
	return {"pos": pos, "yaw": rad_to_deg(atan2(-to_lot.x, -to_lot.z))}


func _free(p: Vector3) -> bool:
	if ctx.collision == null:
		return true
	if not D.in_bounds(roundi(p.x), roundi(p.z)) or is_nan(ctx.collision.ground_height(p)):
		return false
	return not ctx.collision.is_blocked(p, WS.PLAYER_RADIUS)


## Puts the hero on the selected site's sidewalk, facing it, and returns to the street.
func walk_to_selected() -> bool:
	if not active or not ctx.sim.sites.has(selected):
		return false
	var sp := stand_point(selected)
	var what := _site_name(selected)
	ctx.player.teleport(sp["pos"], float(sp["yaw"]), WATCH_PITCH)
	Analytics.track("site_walk", {"site": what})
	exit(BLEND_OUT)
	if ctx.bus != null:
		ctx.bus.toast.emit("You are at the %s site. Watch it go up." % what, "success")
	return true


## Sets a GPS waypoint to the selected site's sidewalk and returns to the street.
func waypoint_to_selected() -> bool:
	if not active or not ctx.sim.sites.has(selected) or ctx.hud == null:
		return false
	var sp := stand_point(selected)
	ctx.hud.set_waypoint(sp["pos"])
	var what := _site_name(selected)
	Analytics.track("site_waypoint", {"site": what})
	exit(BLEND_OUT)
	if ctx.bus != null:
		ctx.bus.toast.emit("Waypoint set: %s" % what, "info")
	return true


## The aerial camera for the current (smoothed) pivot, yaw, pitch and distance.
func camera_xform() -> Transform3D:
	var f := Vector3(-sin(_c_yaw), 0.0, -cos(_c_yaw))
	var pos := _c_pivot - f * _c_dist * cos(_c_pitch) + Vector3.UP * _c_dist * sin(_c_pitch)
	return Transform3D(Basis(), pos).looking_at(_c_pivot, Vector3.UP)


## Moves the view goal: pan (xz, u), rotate (rad), tilt (rad), zoom factor on the distance.
func nudge(pan: Vector2, rotate: float = 0.0, tilt: float = 0.0, zoom: float = 1.0) -> void:
	var f := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
	var r := Vector3(cos(_yaw), 0.0, -sin(_yaw))
	if pan.length_squared() > 0.0:
		_pivot += r * pan.x + f * pan.y
		_flying = false
	_pivot.x = clampf(_pivot.x, D.X0, D.X0 + D.W - 1)
	_pivot.z = clampf(_pivot.z, D.Y0, D.Y0 + D.H - 1)
	_yaw = wrapf(_yaw + rotate, -PI, PI)
	_pitch = clampf(_pitch + tilt, PITCH_MIN, PITCH_MAX)
	_dist = clampf(_dist * zoom, DIST_MIN, DIST_MAX)


func self_test() -> Dictionary:
	if _layer == null or _markers_root == null:
		return {"ok": false, "detail": "overview UI missing"}
	return {"ok": true, "detail": "%d open sites, %d road tiles" % [site_list().size(), road_site_count()]}


func _process(delta: float) -> void:
	_toast_cool = maxf(0.0, _toast_cool - delta)
	if not active or ctx == null or ctx.player == null:
		return
	var dt := minf(delta, 0.1)
	var v := Input.get_vector("move_left", "move_right", "move_back", "move_forward")
	var rot := (1.0 if Input.is_physical_key_pressed(KEY_Q) else 0.0) - (1.0 if Input.is_physical_key_pressed(KEY_E) else 0.0)
	if v.length_squared() > 0.0 or rot != 0.0:
		var fast := 2.5 if Input.is_action_pressed("sprint") else 1.0
		nudge(v * PAN_RATE * _dist * fast * dt, rot * KEY_ROTATE * dt)
	_advance(dt)
	ctx.player.set_view_override(camera_xform(), FOV)
	_you.position = ctx.player.position + Vector3.UP * 0.35
	_refresh_t -= dt
	if _refresh_t <= 0.0:
		_refresh()


## Eases the camera toward its goal (slower while flying to a site).
func _advance(dt: float) -> void:
	var k := 1.0 - pow(2.0, -dt / (HL_FLY if _flying else HL_CAM))
	_c_pivot = _c_pivot.lerp(_pivot, k)
	_c_yaw = lerp_angle(_c_yaw, _yaw, k)
	_c_pitch = lerpf(_c_pitch, _pitch, k)
	_c_dist = lerpf(_c_dist, _dist, k)
	if _flying and _c_pivot.distance_to(_pivot) < 0.02:
		_flying = false


func _snap_camera() -> void:
	_c_pivot = _pivot
	_c_yaw = _yaw
	_c_pitch = _pitch
	_c_dist = _dist


func _unhandled_input(event: InputEvent) -> void:
	if ctx == null:
		return
	if not active:
		if event.is_action_pressed("overview_toggle") and not event.is_echo() and enter():
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		_mouse_button(event as InputEventMouseButton)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		_mouse_motion(event as InputEventMouseMotion)
		get_viewport().set_input_as_handled()
		return
	if event.is_echo():
		return
	if event.is_action_pressed("overview_toggle") or event.is_action_pressed("pause_menu"):
		exit()
	elif event.is_action_pressed("site_next"):
		select_step(1)
	elif event.is_action_pressed("site_prev"):
		select_step(-1)
	elif event.is_action_pressed("site_go"):
		walk_to_selected()
	elif event.is_action_pressed("site_waypoint"):
		waypoint_to_selected()
	elif event.is_action_pressed("time_faster") or event.is_action_pressed("time_slower"):
		# FpMode's own time hotkeys stand down while a modal is pushed.
		if ctx.mode != null:
			ctx.mode.step_time_scale(1 if event.is_action_pressed("time_faster") else -1)
			if ctx.bus != null:
				ctx.bus.toast.emit("Time %dx" % ctx.mode.time_scale, "system")
	elif event.is_action_pressed("time_skip"):
		if ctx.mode != null:
			ctx.mode.skip_to_morning()
	else:
		return
	get_viewport().set_input_as_handled()


func _mouse_button(mb: InputEventMouseButton) -> void:
	if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		nudge(Vector2.ZERO, 0.0, 0.0, 1.0 / ZOOM_STEP)
	elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		nudge(Vector2.ZERO, 0.0, 0.0, ZOOM_STEP)
	elif mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
		if mb.pressed:
			_drag_button = mb.button_index
			_drag_moved = 0.0
			_press_at = mb.position
		elif mb.button_index == _drag_button:
			if _drag_button == MOUSE_BUTTON_LEFT and _drag_moved < CLICK_SLOP:
				_click(mb.position)
			_drag_button = 0


func _mouse_motion(mm: InputEventMouseMotion) -> void:
	if _drag_button == 0:
		return
	var rel := mm.screen_relative
	_drag_moved += rel.length()
	if _drag_button == MOUSE_BUTTON_LEFT:
		nudge(Vector2(-rel.x, rel.y) * MOUSE_PAN * _dist)
	else:
		nudge(Vector2.ZERO, -rel.x * MOUSE_ROTATE, rel.y * MOUSE_TILT)


## Selects the open site nearest the ground point under screen point p.
func _click(p: Vector2) -> void:
	var cam := ctx.player.camera
	if cam == null or not cam.is_inside_tree():
		return
	var o := cam.project_ray_origin(p)
	var n := cam.project_ray_normal(p)
	if n.y > -1e-4:
		return
	var hit := o + n * (-o.y / n.y)
	var best := -1
	var best_d := PICK_RADIUS
	for e: Dictionary in site_list():
		var i := int(e["i"])
		var d := Vector2(D.tx(i) - hit.x, D.ty(i) - hit.z).length()
		if d < best_d:
			best_d = d
			best = i
	if best >= 0:
		focus_site(best)


## Re-reads the open sites: markers, the list and the selection.
func _refresh() -> void:
	_refresh_t = REFRESH
	var list := site_list()
	if selected >= 0 and not ctx.sim.sites.has(selected):
		selected = -1
	var keep := {}
	for e: Dictionary in list:
		keep[int(e["i"])] = true
	for i: int in markers.keys():
		if not keep.has(i):
			(markers[i] as Node3D).queue_free()
			markers.erase(i)
	var near: Array = list.map(func(e: Dictionary) -> int: return int(e["i"]))
	near.sort_custom(func(a: int, b: int) -> bool: return _pivot_d2(a) < _pivot_d2(b))
	var full := {}
	for k in range(mini(FULL_LABELS, near.size())):
		full[near[k]] = true
	for e: Dictionary in list:
		var i := int(e["i"])
		if not markers.has(i):
			markers[i] = _make_marker(i)
		_update_marker(i, full.has(i) or i == selected)
	_refresh_ui(list)


func _pivot_d2(i: int) -> float:
	return Vector2(D.tx(i) - _c_pivot.x, D.ty(i) - _c_pivot.z).length_squared()


func _make_marker(i: int) -> Node3D:
	var root := Node3D.new()
	root.name = "Site_%d" % i
	root.position = Vector3(D.tx(i), 0.0, D.ty(i))
	var beam := MeshInstance3D.new()
	beam.name = "Beam"
	var cm := CylinderMesh.new()
	cm.top_radius = 0.015
	cm.bottom_radius = 0.015
	cm.height = MARKER_Y
	cm.radial_segments = 8
	cm.rings = 1
	beam.mesh = cm
	beam.position.y = MARKER_Y * 0.5
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(beam)
	var lbl := Label3D.new()
	lbl.name = "Label"
	lbl.position.y = MARKER_Y + 0.12
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.fixed_size = true
	lbl.no_depth_test = true
	lbl.render_priority = 10
	lbl.outline_render_priority = 9
	lbl.pixel_size = 0.0009
	lbl.font = S.bold()
	lbl.font_size = 30
	lbl.outline_size = 10
	lbl.outline_modulate = Color(0.02, 0.03, 0.05, 0.85)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	root.add_child(lbl)
	_markers_root.add_child(root)
	return root


func _update_marker(i: int, full: bool) -> void:
	var root: Node3D = markers[i]
	var info := ctx.sim.site_info(i)
	var lbl := root.get_node("Label") as Label3D
	var pct := int(info.get("percent_done", 0))
	if full:
		lbl.text = "%s\n%s · %d%%" % [D.debrand(str(info.get("building", "Construction"))), str(info.get("stage_label", "")), pct]
	else:
		lbl.text = "%d%%" % pct
	var sel := i == selected
	lbl.modulate = PICK_COLOR if sel else (Color(1, 1, 1) if full else Color(1, 1, 1, 0.8))
	lbl.font_size = 34 if sel else (28 if full else 22)
	(root.get_node("Beam") as MeshInstance3D).material_override = _pick_mat if sel else _site_mat


func _site_name(i: int) -> String:
	var info := ctx.sim.site_info(i)
	var what := D.debrand(str(info.get("building", "construction")))
	var place := ctx.directory.place_label(i) if ctx.directory != null else ""
	return "%s, %s" % [what, D.debrand(place)] if not place.is_empty() else what


func _on_site_started(s: Dictionary) -> void:
	if active or _toast_cool > 0.0 or ctx == null or ctx.bus == null:
		return
	if str(s.get("type", "")) != "build" and str(s.get("plan", "")) != "zone_tower":
		return
	_toast_cool = TOAST_GAP
	ctx.bus.toast.emit("Construction started: %s. Press Tab to watch." % _site_name(int(s["i"])), "info")


static func _beam_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(c.r, c.g, c.b, 0.5)
	return m


# ------------------------------------------------------------------ UI

func _build_ui() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "OverviewUI"
	_layer.layer = 11
	_layer.visible = false
	add_child(_layer)
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(root)
	_panel = S.panel()
	_panel.name = "SitePanel"
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.offset_left = -440
	_panel.offset_right = -16
	_panel.offset_top = 84
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	_panel.add_child(col)
	col.add_child(S.plain("CITY OVERVIEW", 15, S.ACCENT, S.caps()))
	_summary = S.plain("", 15, S.TEXT_DIM)
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_summary)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 2)
	col.add_child(_rows)
	_empty = S.plain("No construction right now. The mayors start new projects every morning.", 15, S.TEXT_DIM)
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_empty)
	_detail = S.plain("", 14, S.TEXT)
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_detail)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	col.add_child(actions)
	_walk_btn = _button("Walk there  F", func() -> void: walk_to_selected())
	actions.add_child(_walk_btn)
	_wp_btn = _button("Waypoint  G", func() -> void: waypoint_to_selected())
	actions.add_child(_wp_btn)
	var planner := _button("Planner view", _to_planner)
	planner.tooltip_text = "The top-down city builder view. Press Tab there to come back."
	actions.add_child(planner)
	_hints = _build_hints()
	root.add_child(_hints)


func _build_hints() -> Control:
	var bar := HBoxContainer.new()
	bar.name = "Hints"
	bar.anchor_left = 0.5
	bar.anchor_right = 0.5
	bar.anchor_top = 1.0
	bar.anchor_bottom = 1.0
	bar.offset_left = -560
	bar.offset_right = 560
	bar.offset_top = -52
	bar.offset_bottom = -20
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 16)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for e: Array in [["WASD", "Pan"], ["Q E", "Rotate"], ["Wheel", "Zoom"], ["RMB", "Tilt"], ["N B", "Next site"], ["F", "Walk there"], ["[ ]", "Speed"], ["Tab", "Back to street"]]:
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 6)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(S.key_cap(str(e[0])))
		h.add_child(S.label(str(e[1]), 15, S.TEXT))
		bar.add_child(h)
	return bar


func _button(t: String, cb: Callable) -> Button:
	var b := S.pill_button(t, 14)
	# Tab must reach _unhandled_input, never move GUI focus.
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b


func _refresh_ui(list: Array[Dictionary]) -> void:
	var roads := road_site_count()
	var parts := PackedStringArray()
	parts.append("%d %s under construction" % [list.size(), "site" if list.size() == 1 else "sites"])
	if roads > 0:
		parts.append("%d road %s being paved" % [roads, "tile" if roads == 1 else "tiles"])
	_summary.text = " · ".join(parts)
	_empty.visible = list.is_empty()
	var shown := list.slice(0, LIST_MAX)
	if selected >= 0 and not shown.any(func(e: Dictionary) -> bool: return int(e["i"]) == selected):
		for e: Dictionary in list:
			if int(e["i"]) == selected:
				shown[shown.size() - 1] = e
	while _rows.get_child_count() < shown.size():
		var b := S.menu_button("", 15)
		b.focus_mode = Control.FOCUS_NONE
		b.clip_text = true
		b.pressed.connect(_on_row_pressed.bind(b))
		_rows.add_child(b)
	for k in range(_rows.get_child_count()):
		var b := _rows.get_child(k) as Button
		b.visible = k < shown.size()
		if not b.visible:
			continue
		var i := int(shown[k]["i"])
		var info := ctx.sim.site_info(i)
		b.set_meta("tile", i)
		b.text = "%3d%%   %s · %s" % [int(info.get("percent_done", 0)), D.debrand(str(info.get("building", ""))), str(info.get("stage_label", ""))]
		b.add_theme_color_override("font_color", PICK_COLOR if i == selected else Color(1, 1, 1, 0.78))
	var has_sel := selected >= 0 and ctx.sim.sites.has(selected)
	_walk_btn.disabled = not has_sel
	_wp_btn.disabled = not has_sel or ctx.hud == null
	if has_sel:
		var info := ctx.sim.site_info(selected)
		var crew: Array = info.get("crew", [])
		_detail.text = "%s\nStage %d of %d: %s%s" % [_site_name(selected), int(info.get("stage_number", 1)), int(info.get("stages", 1)), str(info.get("stage_label", "")), ("\nCrew: " + ", ".join(PackedStringArray(crew.slice(0, 4)))) if not crew.is_empty() else ""]
	else:
		_detail.text = "Click a marker or a row, or press N, to pick a site." if not list.is_empty() else ""


func _on_row_pressed(b: Button) -> void:
	if b.has_meta("tile"):
		focus_site(int(b.get_meta("tile")))


func _to_planner() -> void:
	exit(0.0)
	if ctx.main != null:
		# exit_fp frees this feature; it cannot run inside the button's own pressed emission.
		ctx.main.call_deferred("exit_fp")
