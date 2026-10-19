extends Control
## Full-screen map (slice B) on M: the minimap's tile images at large size, north up, with district
## names, street names (from the directory) at 6 px per tile and closer, incidents, pings, the
## waypoint and the player. Hovering shows what is under the cursor (place, district, distance, an
## incident or the waypoint) in a small card. Drag pans, the wheel zooms about the cursor, a left
## click sets the waypoint (ping(world, "player")), a right click or a click on the waypoint clears
## it. Pushes the &"map" modal; M or Esc closes it (consumed). Ignored under other modals and in
## photo mode.

const D := preload("res://scripts/sim/sim_defs.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const WS := preload("res://scripts/fp/world_scale.gd")
const MinimapModel := preload("res://scripts/fp/ui/minimap_model.gd")
const MAP_SHADER := preload("res://ui/fp/map.gdshader")

const MODAL := &"map"
const MIN_PPT := 3.0
const MAX_PPT := 28.0
const START_PPT := 12.0
## Street names show at this zoom and closer.
const STREET_PPT := 6.0
const ZOOM_STEP := 1.18
const CLICK_SLOP := 5.0
const FADE := 0.14
const MARGIN := 32.0

var ctx: FpContext
var hud: Node
var model: MinimapModel
## Pixels per tile.
var ppt: float = START_PPT
## World point (x, z) at the screen centre.
var center: Vector2 = Vector2.ZERO
var _bg: ColorRect
var _rect: ColorRect
var _mat: ShaderMaterial
var _overlay: Control
var _header: Label
var _scale_label: Label
var _press: Vector2 = Vector2.INF
var _drag_last: Vector2 = Vector2.ZERO
var _moved: bool = false
var _pushed: bool = false
var _age: float = 0.0
var _labels_dirty: bool = true
## {"name": String, "pos": Vector2 (world), "vertical": bool, "len": int (tiles)}
var _streets: Array[Dictionary] = []
## {"name": String, "lines": PackedStringArray, "pos": Vector2 (world)}
var _districts: Array[Dictionary] = []
var _time: float = 0.0
## Tile under the cursor (-1 when none) and the hover card's lines (title, detail).
var hover_tile: int = -1
var _hover_pos: Vector2 = Vector2.INF
var _hover_lines: PackedStringArray = PackedStringArray()
var _hover_key: String = ""
var _card_box: StyleBoxFlat


func setup(p_ctx: FpContext, p_hud: Node) -> void:
	ctx = p_ctx
	hud = p_hud
	name = "MapScreen"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_bg = ColorRect.new()
	_bg.name = "Backdrop"
	_bg.color = Color(0.035, 0.045, 0.06, 1.0)
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)
	_rect = ColorRect.new()
	_rect.name = "Map"
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = MAP_SHADER
	_mat.set_shader_parameter("world_origin", Vector2(D.X0, D.Y0))
	_mat.set_shader_parameter("world_size", Vector2(D.W, D.H))
	_mat.set_shader_parameter("shape", 1)
	_mat.set_shader_parameter("corner", 0.0)
	_mat.set_shader_parameter("opacity", 1.0)
	_mat.set_shader_parameter("borders", true)
	_rect.material = _mat
	add_child(_rect)
	# Soft dark bands behind the title and the key hints, so they read over roads.
	for top: bool in [true, false]:
		var band := TextureRect.new()
		band.name = "Band"
		band.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var g := GradientTexture2D.new()
		g.fill_from = Vector2(0, 0) if top else Vector2(0, 1)
		g.fill_to = Vector2(0, 1) if top else Vector2(0, 0)
		var grad := Gradient.new()
		grad.colors = PackedColorArray([Color(0.02, 0.025, 0.035, 0.72), Color(0.02, 0.025, 0.035, 0.0)])
		g.gradient = grad
		g.width = 4
		g.height = 64
		band.texture = g
		band.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		band.stretch_mode = TextureRect.STRETCH_SCALE
		band.anchor_right = 1.0
		band.anchor_top = 0.0 if top else 1.0
		band.anchor_bottom = 0.0 if top else 1.0
		band.offset_top = 0.0 if top else -130.0
		band.offset_bottom = 130.0 if top else 0.0
		add_child(band)
	_overlay = Control.new()
	_overlay.name = "Labels"
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)
	_build_chrome()
	if ctx.bus != null:
		ctx.bus.world_ready.connect(func() -> void: _labels_dirty = true)
	if ctx.sim != null:
		ctx.sim.tiles_changed.connect(func(_i: PackedInt32Array) -> void: _labels_dirty = true)


## Binds the tile model (null hides the map and refuses to open).
func bind(p_model: MinimapModel) -> void:
	model = p_model
	if model != null:
		_mat.set_shader_parameter("col_tex", model.texture)
		_mat.set_shader_parameter("data_tex", model.data_texture)
		_mat.set_shader_parameter("survey_tex", model.survey_texture)
	elif visible:
		close()
	_labels_dirty = true


## True while the map shows.
func is_open() -> bool:
	return visible


## Opens the map centred on the player (pushes &"map"). False when it may not open now.
func open() -> bool:
	if visible or model == null or ctx.is_modal():
		return false
	if ctx.player != null and ctx.player.photo_mode:
		return false
	if ctx.player != null:
		center = Vector2(ctx.player.position.x, ctx.player.position.z)
	ppt = START_PPT
	if _labels_dirty:
		_rebuild_labels()
	visible = true
	_age = 0.0
	modulate.a = 0.0
	_clear_hover()
	if not _pushed:
		ctx.push_modal(MODAL)
		_pushed = true
	_refresh_header()
	_apply_view()
	return true


## Closes the map and pops its modal (safe when closed).
func close() -> void:
	visible = false
	_press = Vector2.INF
	_clear_hover()
	if _pushed:
		_pushed = false
		ctx.pop_modal(MODAL)


## World point (x, z) under a screen point of this Control.
func screen_to_world(p: Vector2) -> Vector2:
	return center + (p - _view_size() * 0.5) / ppt


## Screen point of a world point (x, z).
func world_to_screen(w: Vector2) -> Vector2:
	return (w - center) * ppt + _view_size() * 0.5


## A left click at screen point p: sets the waypoint there, or clears it when p is on it.
func click_at(p: Vector2) -> void:
	var wp: Variant = hud.call("waypoint")
	if wp != null:
		var q: Vector3 = wp
		if world_to_screen(Vector2(q.x, q.z)).distance_to(p) < 12.0:
			hud.call("clear_waypoint")
			_overlay.queue_redraw()
			return
	var w := screen_to_world(p)
	w.x = clampf(w.x, D.X0, D.X0 + D.W - 1)
	w.y = clampf(w.y, D.Y0, D.Y0 + D.H - 1)
	hud.call("set_waypoint", Vector3(w.x, 0.0, w.y))
	_overlay.queue_redraw()


## Zooms by factor about screen point p.
func zoom_at(p: Vector2, factor: float) -> void:
	var w := screen_to_world(p)
	ppt = clampf(ppt * factor, MIN_PPT, MAX_PPT)
	center = w - (p - _view_size() * 0.5) / ppt
	_apply_view()


## Updates the hover card for screen point p: an incident or the waypoint under the cursor, else
## the tile's place label with its district and distance. Returns the card's lines.
func hover_at(p: Vector2) -> PackedStringArray:
	_hover_pos = p
	var w := screen_to_world(p)
	var x := roundi(w.x)
	var y := roundi(w.y)
	hover_tile = D.idx(x, y) if D.in_bounds(x, y) else -1
	var key := str(hover_tile)
	var lines := PackedStringArray()
	if ctx.sim != null:
		for ev: Dictionary in ctx.sim.events:
			var q := Vector2(float(ev.get("x", 0)), float(ev.get("y", 0)))
			if world_to_screen(q).distance_to(p) < 12.0:
				key = "ev%d" % int(ev.get("id", -1))
				lines = PackedStringArray([D.debrand(str(ev.get("label", "Incident"))), "Incident · " + _distance_to(q)])
				break
	var wp: Variant = hud.call("waypoint") if lines.is_empty() else null
	if wp != null:
		var q := Vector2((wp as Vector3).x, (wp as Vector3).z)
		if world_to_screen(q).distance_to(p) < 12.0:
			key = "wp"
			lines = PackedStringArray(["Waypoint", _distance_to(q) + " · click to clear"])
	if lines.is_empty() and hover_tile >= 0 and ctx.directory != null:
		if key == _hover_key:
			return _hover_lines
		var title := _sentence(D.debrand(ctx.directory.place_label(hover_tile)))
		var parts := PackedStringArray()
		var dn := _sentence(D.debrand(ctx.directory.district_name(hover_tile)))
		if dn != title:
			parts.append(dn)
		if ctx.sim != null and ctx.sim.burning[hover_tile] > 0:
			parts.append("On fire")
		elif ctx.sim != null and not ctx.sim.is_surveyed(x, y):
			parts.append("Unsurveyed")
		parts.append(_distance_to(Vector2(x, y)))
		lines = PackedStringArray([title, " · ".join(parts)])
	_hover_key = key
	_hover_lines = lines
	return lines


## The hover card's lines (empty when it is hidden).
func hover_lines() -> PackedStringArray:
	return _hover_lines


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_clear_hover()


func _clear_hover() -> void:
	_hover_pos = Vector2.INF
	_hover_lines = PackedStringArray()
	_hover_key = ""
	hover_tile = -1


func _distance_to(q: Vector2) -> String:
	if ctx.player == null:
		return ""
	return S.distance(Vector2(q.x - ctx.player.position.x, q.y - ctx.player.position.z).length()) + " away"


static func _sentence(t: String) -> String:
	return t.substr(0, 1).to_upper() + t.substr(1) if not t.is_empty() else t


func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo() or not (event is InputEventKey or event is InputEventAction or event is InputEventJoypadButton):
		return
	if visible:
		if event.is_action_pressed("map_toggle") or event.is_action_pressed("pause_menu"):
			close()
			get_viewport().set_input_as_handled()
	elif event.is_action_pressed("map_toggle"):
		if open():
			get_viewport().set_input_as_handled()


func _gui_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			zoom_at(mb.position, ZOOM_STEP)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			zoom_at(mb.position, 1.0 / ZOOM_STEP)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_press = mb.position
				_drag_last = mb.position
				_moved = false
			else:
				if _press != Vector2.INF and not _moved:
					click_at(mb.position)
				_press = Vector2.INF
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			hud.call("clear_waypoint")
			_overlay.queue_redraw()
		accept_event()
	elif event is InputEventMouseMotion and _press != Vector2.INF:
		var mm := event as InputEventMouseMotion
		if mm.position.distance_to(_press) > CLICK_SLOP:
			_moved = true
		if _moved:
			center -= (mm.position - _drag_last) / ppt
			_drag_last = mm.position
			_apply_view()
			_clear_hover()
		accept_event()
	elif event is InputEventMouseMotion:
		hover_at((event as InputEventMouseMotion).position)
		accept_event()


func _process(delta: float) -> void:
	if not visible:
		return
	_time += delta
	if _age < FADE:
		_age = minf(FADE, _age + delta)
		modulate.a = _age / FADE
	_overlay.queue_redraw()


func _apply_view() -> void:
	var lo := Vector2(D.X0, D.Y0)
	var hi := lo + Vector2(D.W, D.H)
	center = center.clamp(lo, hi)
	_mat.set_shader_parameter("center", center)
	_mat.set_shader_parameter("ppt", ppt)
	_mat.set_shader_parameter("rect_size", _view_size())
	_overlay.queue_redraw()
	var m := 5000.0
	for step: float in [20.0, 50.0, 100.0, 200.0, 500.0, 1000.0, 2000.0]:
		if step * WS.M * ppt >= 60.0:
			m = step
			break
	_scale_label.text = S.distance(m * WS.M)
	_scale_label.set_meta("bar_px", m * WS.M * ppt)


func _view_size() -> Vector2:
	return size if size.x > 0.0 and size.y > 0.0 else get_viewport_rect().size


func _build_chrome() -> void:
	var head := VBoxContainer.new()
	head.name = "Header"
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.position = Vector2(MARGIN + 8.0, MARGIN)
	head.add_theme_constant_override("separation", 0)
	add_child(head)
	var title := S.label("Map", 40, S.WHITE, S.title(), 0)
	title.add_theme_constant_override("shadow_offset_y", 2)
	head.add_child(title)
	_header = S.label("", 15, S.TEXT_DIM, S.font(), 3)
	head.add_child(_header)
	var foot := HBoxContainer.new()
	foot.name = "Hints"
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	foot.anchor_top = 1.0
	foot.anchor_bottom = 1.0
	foot.offset_left = MARGIN + 8.0
	foot.offset_top = -MARGIN - 26.0
	foot.offset_bottom = -MARGIN
	foot.add_theme_constant_override("separation", 7)
	add_child(foot)
	for pair: Array in [["Drag", "Pan"], ["Wheel", "Zoom"], ["Click", "Set waypoint"], ["Right-click", "Clear"], ["M", ""], ["Esc", "Close"]]:
		var k := S.key_cap(str(pair[0]), 12)
		k.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		foot.add_child(k)
		if not str(pair[1]).is_empty():
			foot.add_child(S.label(str(pair[1]), 14, S.TEXT_DIM, S.font(), 3))
			var sp := Control.new()
			sp.custom_minimum_size = Vector2(10, 0)
			sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
			foot.add_child(sp)
	_scale_label = S.label("", 13, S.TEXT_DIM, S.bold(), 3)
	_scale_label.name = "Scale"
	_scale_label.anchor_left = 1.0
	_scale_label.anchor_right = 1.0
	_scale_label.anchor_top = 1.0
	_scale_label.anchor_bottom = 1.0
	_scale_label.offset_left = -MARGIN - 160.0
	_scale_label.offset_right = -MARGIN - 8.0
	_scale_label.offset_top = -MARGIN - 34.0
	_scale_label.offset_bottom = -MARGIN - 14.0
	_scale_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_scale_label)


func _refresh_header() -> void:
	var parts := PackedStringArray()
	if ctx.sim != null:
		parts.append("Day %d" % ctx.sim.day)
	if ctx.sky != null:
		parts.append(ctx.sky.clock_text())
	if ctx.player != null and ctx.directory != null:
		parts.append(ctx.directory.street_at(ctx.player.position))
	_header.text = D.debrand(" · ".join(parts))


## District name anchors and street-run labels, rebuilt when the map opens after a change.
func _rebuild_labels() -> void:
	_labels_dirty = false
	_streets.clear()
	_districts.clear()
	var sim := ctx.sim
	if sim == null or ctx.directory == null:
		return
	var sums: Dictionary = {}
	var r := Rect2i(D.X0, D.Y0, D.W, D.H)
	if not sim.active.is_empty():
		var a0 := sim.active[0]
		var a1 := sim.active[sim.active.size() - 1]
		r = Rect2i(D.tx(a0), D.ty(a0), D.tx(a1) - D.tx(a0) + 1, D.ty(a1) - D.ty(a0) + 1)
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var i := D.idx(x, y)
			var d := sim.district[i]
			if d >= 0:
				var s: Vector3 = sums.get(d, Vector3.ZERO)
				sums[d] = s + Vector3(x, y, 1)
	for d: int in sums:
		var s: Vector3 = sums[d]
		if d < D.MAYORS.size() and s.z > 0:
			var dn := str(D.MAYORS[d]["district"]).to_upper()
			_districts.append({"name": dn, "lines": _split_name(dn), "pos": Vector2(s.x / s.z, s.y / s.z)})
	# Street runs: E-W along rows, N-S along columns; one label per run of 3+ tiles.
	for y in range(r.position.y, r.end.y):
		_scan_runs(r.position.x, r.end.x, y, false)
	for x in range(r.position.x, r.end.x):
		_scan_runs(r.position.y, r.end.y, x, true)


func _scan_runs(a: int, b: int, fixed: int, vertical: bool) -> void:
	var sim := ctx.sim
	var start := -1
	for k in range(a, b + 1):
		var on := false
		if k < b:
			var i := D.idx(fixed, k) if vertical else D.idx(k, fixed)
			on = sim.kind[i] == D.ROAD and _has_arm(fixed, k, vertical)
		if on and start < 0:
			start = k
		elif not on and start >= 0:
			var n := k - start
			if n >= 3:
				var name_ := ""
				for j in range(start, k):
					var t := D.idx(fixed, j) if vertical else D.idx(j, fixed)
					if not _has_arm(j, fixed, not vertical):
						name_ = ctx.directory.street_name(t)
						break
				if not name_.is_empty():
					var mid := (start + k - 1) * 0.5
					_streets.append({"name": D.debrand(name_), "pos": Vector2(fixed, mid) if vertical else Vector2(mid, fixed), "vertical": vertical, "len": n})
			start = -1


## True when the road tile at (fixed, k) continues along the run (vertical: N or S; else E or W).
func _has_arm(fixed: int, k: int, vertical: bool) -> bool:
	var sim := ctx.sim
	for s: int in [-1, 1]:
		var x: int = fixed if vertical else k + s
		var y: int = k + s if vertical else fixed
		if D.in_bounds(x, y) and sim.kind[D.idx(x, y)] == D.ROAD:
			return true
	return false


func _draw_overlay() -> void:
	if model == null:
		return
	var o := _overlay
	var f := S.bold()
	var caps := S.caps()
	var view := _view_size()
	var screen := Rect2(Vector2.ZERO, view).grow(-4.0)
	# GPS route to the waypoint, under every label.
	var rt: PackedVector2Array = hud.call("route")
	if rt.size() >= 2:
		var pts := PackedVector2Array()
		for w in rt:
			pts.append(world_to_screen(w))
		var rw := clampf(ppt * 0.28, 3.0, 7.0)
		o.draw_polyline(pts, Color(0.0, 0.05, 0.08, 0.45), rw + 2.5, true)
		o.draw_polyline(pts, Color(S.ACCENT, 0.9), rw, true)
	# Labels never overlap: the player and the waypoint first, then districts, streets, incidents.
	var placed: Array[Rect2] = [
		Rect2(0, 0, 440, 112), Rect2(0, view.y - 84, 780, 84),
		Rect2(view.x - 230, view.y - 84, 230, 84), Rect2(view.x - 96, 0, 96, 96),
	]
	if ctx.player != null:
		placed.append(Rect2(world_to_screen(Vector2(ctx.player.position.x, ctx.player.position.z)) - Vector2(16, 16), Vector2(32, 32)))
	# District names (two lines when long).
	var dfs := 13 if ppt < 10.0 else 16
	var lh := float(dfs) + 4.0
	for e: Dictionary in _districts:
		var p := world_to_screen(e["pos"])
		if not screen.has_point(p):
			continue
		var lines: PackedStringArray = e["lines"]
		var w := 0.0
		for t in lines:
			w = maxf(w, caps.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, dfs).x)
		var r := Rect2(p.x - w * 0.5, p.y - lh * lines.size() * 0.5, w, lh * lines.size())
		if _hits(placed, r):
			continue
		placed.append(r)
		for k in range(lines.size()):
			var t := lines[k]
			var tw := caps.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, dfs).x
			var base := Vector2(p.x - tw * 0.5, r.position.y + lh * k + dfs * 0.95)
			o.draw_string_outline(caps, base, t, HORIZONTAL_ALIGNMENT_LEFT, -1, dfs, 5, Color(0.02, 0.03, 0.05, 0.6))
			o.draw_string(caps, base, t, HORIZONTAL_ALIGNMENT_LEFT, -1, dfs, Color(1, 1, 1, 0.6))
	# Street names.
	if ppt >= STREET_PPT:
		var sfs := 11 if ppt < 12.0 else 13
		for e: Dictionary in _streets:
			var p := world_to_screen(e["pos"])
			if not screen.has_point(p):
				continue
			var t: String = e["name"]
			var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, sfs).x
			if w + 10.0 > float(e["len"]) * ppt:
				continue
			var vert := bool(e["vertical"])
			# Beside the road (above an E-W street, left of a N-S avenue), never on the white line.
			var off := 0.3 * ppt + 3.0
			var c := p + (Vector2(-(off + sfs * 0.45), 0.0) if vert else Vector2(0.0, -(off + sfs * 0.45)))
			var r := Rect2(c - Vector2(sfs * 0.6, w * 0.5 + 2.0), Vector2(sfs * 1.2, w + 4.0)) if vert else Rect2(c - Vector2(w * 0.5 + 2.0, sfs * 0.6), Vector2(w + 4.0, sfs * 1.2))
			if _hits(placed, r):
				continue
			placed.append(r)
			o.draw_set_transform(p, -PI * 0.5 if vert else 0.0)
			var base := Vector2(-w * 0.5, -off)
			o.draw_string_outline(f, base, t, HORIZONTAL_ALIGNMENT_LEFT, -1, sfs, 4, Color(0.03, 0.04, 0.06, 0.85))
			o.draw_string(f, base, t, HORIZONTAL_ALIGNMENT_LEFT, -1, sfs, Color(1, 1, 1, 0.92))
		o.draw_set_transform(Vector2.ZERO, 0.0)
	# Pings, under the incidents; one on an incident is left out.
	var pings: Array = hud.get("pings")
	for e: Dictionary in pings:
		var pos: Vector3 = e["pos"]
		if _near_incident(Vector2(pos.x, pos.z)):
			continue
		var p := world_to_screen(Vector2(pos.x, pos.z))
		var col := S.RED if str(e["reason"]).begins_with("event:") else S.AMBER
		var a := float(e.get("alpha", 1.0))
		o.draw_arc(p, 8.0, 0.0, TAU, 32, Color(col, a), 2.0, true)
		o.draw_circle(p, 3.0, Color(col, a), true, -1.0, true)
	# Incidents.
	if ctx.sim != null:
		var pulse := 0.5 + 0.5 * sin(_time * 4.0)
		for ev: Dictionary in ctx.sim.events:
			var p := world_to_screen(Vector2(float(ev.get("x", 0)), float(ev.get("y", 0))))
			if not screen.grow(20).has_point(p):
				continue
			o.draw_circle(p, 11.0 + 4.0 * pulse, Color(S.RED, 0.2 * (1.0 - pulse)), true, -1.0, true)
			o.draw_circle(p, 9.0, Color(0.05, 0.02, 0.02, 0.7), true, -1.0, true)
			o.draw_circle(p, 8.0, S.RED, true, -1.0, true)
			o.draw_line(p + Vector2(0, -4.2), p + Vector2(0, 1.2), Color.WHITE, 2.2, true)
			o.draw_circle(p + Vector2(0, 3.8), 1.3, Color.WHITE, true, -1.0, true)
			var t := D.debrand(str(ev.get("label", "")))
			var tr := Rect2(p + Vector2(13.0, -9.0), Vector2(f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x + 4.0, 18.0))
			if not t.is_empty() and not _hits(placed, tr):
				placed.append(tr)
				var base := p + Vector2(14.0, 5.0)
				o.draw_string_outline(f, base, t, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 4, Color(0.03, 0.02, 0.02, 0.85))
				o.draw_string(f, base, t, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1.0, 0.82, 0.82))
	# Waypoint.
	var wp: Variant = hud.call("waypoint")
	if wp != null:
		var q: Vector3 = wp
		var p := world_to_screen(Vector2(q.x, q.z))
		var r := 10.0
		o.draw_colored_polygon(PackedVector2Array([p + Vector2(0, -r - 2), p + Vector2(r * 0.85 + 2, 0), p + Vector2(0, r + 2), p + Vector2(-r * 0.85 - 2, 0)]), Color(0.02, 0.03, 0.05, 0.6))
		o.draw_colored_polygon(PackedVector2Array([p + Vector2(0, -r), p + Vector2(r * 0.85, 0), p + Vector2(0, r), p + Vector2(-r * 0.85, 0)]), S.ACCENT)
		o.draw_circle(p, 2.4, Color(0.02, 0.05, 0.07), true, -1.0, true)
		if ctx.player != null:
			var t := S.distance(Vector2(q.x - ctx.player.position.x, q.z - ctx.player.position.z).length())
			var base := p + Vector2(15.0, 5.0)
			o.draw_string_outline(f, base, t, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 4, Color(0.02, 0.03, 0.05, 0.85))
			o.draw_string(f, base, t, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, S.ACCENT)
	# Player.
	if ctx.player != null:
		var p := world_to_screen(Vector2(ctx.player.position.x, ctx.player.position.z))
		var by := ctx.player.yaw
		var fwd := Vector2(-sin(by), -cos(by))
		var side := Vector2(-fwd.y, fwd.x)
		var k := 1.25
		var tip := p + fwd * 10.0 * k
		var pts := PackedVector2Array([tip, p - fwd * 6.5 * k + side * 7.0 * k, p - fwd * 2.8 * k, p - fwd * 6.5 * k - side * 7.0 * k])
		var sh := PackedVector2Array()
		for v in pts:
			sh.append(v + Vector2(0, 1.5))
		o.draw_circle(p, 18.0, Color(S.ACCENT, 0.12), true, -1.0, true)
		o.draw_colored_polygon(sh, Color(0, 0, 0, 0.5))
		o.draw_colored_polygon(pts, S.ACCENT)
		var rim := pts.duplicate()
		rim.append(tip)
		o.draw_polyline(rim, Color.WHITE, 1.6, true)
	# Scale bar.
	var bar := float(_scale_label.get_meta("bar_px", 0.0))
	if bar > 0.0:
		var x1 := view.x - MARGIN - 8.0
		var y := view.y - MARGIN - 10.0
		o.draw_line(Vector2(x1 - bar, y), Vector2(x1, y), Color(1, 1, 1, 0.8), 2.0)
		o.draw_line(Vector2(x1 - bar, y - 5), Vector2(x1 - bar, y + 1), Color(1, 1, 1, 0.8), 2.0)
		o.draw_line(Vector2(x1, y - 5), Vector2(x1, y + 1), Color(1, 1, 1, 0.8), 2.0)
	# North arrow, top right.
	var na := Vector2(view.x - MARGIN - 22.0, MARGIN + 26.0)
	o.draw_circle(na, 18.0, Color(0.03, 0.04, 0.06, 0.75), true, -1.0, true)
	o.draw_arc(na, 18.0, 0.0, TAU, 40, Color(1, 1, 1, 0.3), 1.0, true)
	o.draw_colored_polygon(PackedVector2Array([na + Vector2(0, -12), na + Vector2(5, -3), na + Vector2(-5, -3)]), S.WHITE)
	var nw := f.get_string_size("N", HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	o.draw_string(f, na + Vector2(-nw * 0.5, 11.0), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, S.WHITE)
	_draw_hover(o, view)


## The hovered tile's outline and the hover card beside the cursor, kept on screen.
func _draw_hover(o: Control, view: Vector2) -> void:
	if _hover_lines.is_empty() or _hover_pos == Vector2.INF:
		return
	if _hover_key.is_valid_int() and hover_tile >= 0 and ppt >= 6.0:
		var c := world_to_screen(Vector2(D.tx(hover_tile), D.ty(hover_tile)))
		var r := Rect2(c - Vector2(ppt, ppt) * 0.5, Vector2(ppt, ppt))
		o.draw_rect(r.grow(1.0), Color(0, 0, 0, 0.35), false, 3.0)
		o.draw_rect(r, Color(1, 1, 1, 0.7), false, 1.5)
	var f := S.bold()
	var g := S.font()
	var t0 := _hover_lines[0]
	var t1 := _hover_lines[1] if _hover_lines.size() > 1 else ""
	var w := maxf(f.get_string_size(t0, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x, g.get_string_size(t1, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x)
	var sz := Vector2(w + 24.0, 50.0 if not t1.is_empty() else 32.0)
	var at := _hover_pos + Vector2(18.0, 16.0)
	if at.x + sz.x > view.x - 12.0:
		at.x = _hover_pos.x - 18.0 - sz.x
	if at.y + sz.y > view.y - 12.0:
		at.y = _hover_pos.y - 16.0 - sz.y
	at = at.clamp(Vector2(12, 12), view - sz - Vector2(12, 12)).round()
	if _card_box == null:
		_card_box = S.box(Color(0.045, 0.055, 0.085, 0.9), 8, 12, 8, Color(1, 1, 1, 0.1), 1)
		_card_box.shadow_color = Color(0, 0, 0, 0.35)
		_card_box.shadow_size = 8
	o.draw_style_box(_card_box, Rect2(at, sz))
	o.draw_string(f, at + Vector2(12.0, 21.0), t0, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, S.WHITE)
	if not t1.is_empty():
		o.draw_string(g, at + Vector2(12.0, 40.0), t1, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, S.TEXT_DIM)


## True when an incident stands within 1.5 tiles of world point w.
func _near_incident(w: Vector2) -> bool:
	if ctx.sim == null:
		return false
	for ev: Dictionary in ctx.sim.events:
		if Vector2(float(ev.get("x", 0)), float(ev.get("y", 0))).distance_squared_to(w) < 2.25:
			return true
	return false


## Splits a long name into two balanced lines at a space ("NORTHWEST" / "CIVIC CAMPUS").
static func _split_name(n: String) -> PackedStringArray:
	var words := n.split(" ", false)
	if n.length() <= 12 or words.size() < 2:
		return PackedStringArray([n])
	var best := 1
	var best_d := 1 << 20
	for k in range(1, words.size()):
		var a := " ".join(words.slice(0, k)).length()
		var b := " ".join(words.slice(k)).length()
		if absi(a - b) < best_d:
			best_d = absi(a - b)
			best = k
	return PackedStringArray([" ".join(words.slice(0, best)), " ".join(words.slice(best))])


static func _hits(placed: Array[Rect2], r: Rect2) -> bool:
	for q in placed:
		if q.grow(3.0).intersects(r):
			return true
	return false
