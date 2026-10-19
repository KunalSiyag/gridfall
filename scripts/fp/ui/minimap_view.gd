extends Control
## The rotating circular minimap (slice B) in minimap_slot: the model's 192 x 192 tile images
## drawn by ui/fp/map.gdshader in a 200 px circle (soft edge, thin ring, no square frame), rotated
## every frame so the view heading points up, with markers drawn on top at 12 Hz (player arrow,
## waypoint, pings, incidents, nearby residents and E's agents) and the street label under it.
## Without a bound model (no hud_widgets feature) only the street label shows.

const D := preload("res://scripts/sim/sim_defs.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const MinimapModel := preload("res://scripts/fp/ui/minimap_model.gd")
const MAP_SHADER := preload("res://ui/fp/map.gdshader")

const DIAM := 200.0
## The circle's top-left inside the slot: the slot starts 16 px from the screen edge, so 8 more
## puts the circle on the 24 px safe margin.
const ORIGIN := Vector2(8.0, 0.0)
## Pixels per tile; the wheel steps through them in first person only (in third person it is A's zoom).
const SCALES := [2.0, 3.5, 6.0]
const DEFAULT_SCALE := 3.5
const MARKER_PERIOD := 1.0 / 12.0
const PEOPLE_PERIOD := 0.5
## Residents and agents within this many tiles are drawn.
const NEAR_TILES := 20.0
const LABEL_Y := 216.0
const LABEL_H := 20.0
const LABEL_FADE := 0.3
const RIM_PAD := 9.0

var ctx: FpContext
var hud: Node
var model: MinimapModel
## Pixels per tile.
var ppt: float = DEFAULT_SCALE
## View yaw (radians, S0 §11 convention); the map rotates by +yaw.
var yaw: float = 0.0
## World point (x, z) at the circle's centre.
var center: Vector2 = Vector2.ZERO
## Test hook: marker redraws so far.
var marker_draws: int = 0
var _map: TextureRect
var _mat: ShaderMaterial
var _overlay: Control
var _ring: Control
var _street: Label
var _street_age: float = 1.0
var _marker_t: float = 0.0
var _people_t: float = PEOPLE_PERIOD
var _drawn_yaw: float = INF
var _drawn_center: Vector2 = Vector2.INF
## Cached marker data in world tiles: {"pos": Vector2, "kind": String, "dir": Vector2}
var _agents: Array[Dictionary] = []
var _people: PackedVector2Array = PackedVector2Array()
var _incidents: PackedVector2Array = PackedVector2Array()
var _time: float = 0.0


## hud is the FpHud (pings and the waypoint come from it).
func setup(p_ctx: FpContext, p_hud: Node) -> void:
	ctx = p_ctx
	hud = p_hud
	name = "Minimap"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map = TextureRect.new()
	_map.name = "Map"
	_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_map.stretch_mode = TextureRect.STRETCH_SCALE
	_map.position = ORIGIN
	_map.size = Vector2(DIAM, DIAM)
	_map.pivot_offset = Vector2(DIAM, DIAM) * 0.5
	_mat = ShaderMaterial.new()
	_mat.shader = MAP_SHADER
	_mat.set_shader_parameter("rect_size", Vector2(DIAM, DIAM))
	_mat.set_shader_parameter("world_origin", Vector2(D.X0, D.Y0))
	_mat.set_shader_parameter("world_size", Vector2(D.W, D.H))
	_mat.set_shader_parameter("shape", 0)
	_mat.set_shader_parameter("opacity", 0.93)
	_map.material = _mat
	_map.visible = false
	add_child(_map)
	_ring = Control.new()
	_ring.name = "Ring"
	_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring.position = ORIGIN - Vector2(12, 12)
	_ring.size = Vector2(DIAM + 24.0, DIAM + 24.0)
	_ring.draw.connect(_draw_ring)
	_ring.visible = false
	add_child(_ring)
	_overlay = Control.new()
	_overlay.name = "Markers"
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.position = ORIGIN - Vector2(12, 12)
	_overlay.size = Vector2(DIAM + 24.0, DIAM + 24.0)
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)
	_street = S.label("", 15, S.TEXT, S.bold(), 3)
	_street.name = "Street"
	_street.position = Vector2(ORIGIN.x, LABEL_Y)
	_street.size = Vector2(DIAM, LABEL_H)
	_street.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_street.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_street)
	if ctx.bus != null:
		ctx.bus.player_tile_changed.connect(_on_player_tile)
	_update_street(true)


## Shows the model's images (the hud_widgets feature binds it; null unbinds).
func bind(p_model: MinimapModel) -> void:
	model = p_model
	_map.visible = model != null
	_ring.visible = model != null
	if model != null:
		_map.texture = model.texture
		_mat.set_shader_parameter("col_tex", model.texture)
		_mat.set_shader_parameter("data_tex", model.data_texture)
		_mat.set_shader_parameter("survey_tex", model.survey_texture)
	_people_t = PEOPLE_PERIOD
	_marker_t = MARKER_PERIOD
	_overlay.queue_redraw()


## The circle's centre in slot coordinates.
func center_in_slot() -> Vector2:
	return _map.get_transform() * (Vector2(DIAM, DIAM) * 0.5)


## Where world point p is drawn, in slot coordinates, through the map's own Control transform.
func world_to_slot(p: Vector3) -> Vector2:
	var local := Vector2(DIAM, DIAM) * 0.5 + (Vector2(p.x, p.z) - center) * ppt
	return _map.get_transform() * local


## The map Control (tests read its rotation and visibility).
func map_rect() -> TextureRect:
	return _map


## The street label text.
func street_text() -> String:
	return _street.text


## Steps the scale through SCALES (dir +1 zooms in); clamped at the ends.
func step_scale(dir: int) -> void:
	var k := 0
	for j in range(SCALES.size()):
		if is_equal_approx(float(SCALES[j]), ppt):
			k = j
	ppt = float(SCALES[clampi(k + signi(dir), 0, SCALES.size() - 1)])
	_mat.set_shader_parameter("ppt", ppt)
	_overlay.queue_redraw()


## Re-reads the street name now (after a load or teleport).
func refresh_street() -> void:
	_update_street(true)


func _unhandled_input(event: InputEvent) -> void:
	if ctx == null or not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or (mb.button_index != MOUSE_BUTTON_WHEEL_UP and mb.button_index != MOUSE_BUTTON_WHEEL_DOWN):
		return
	# Third person: the wheel is A's camera zoom; the minimap keeps its scale.
	if str(ctx.settings.get("camera_mode", "third")) != "first" or ctx.is_modal():
		return
	if ctx.player != null and ctx.player.photo_mode:
		return
	step_scale(1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1)


func _process(delta: float) -> void:
	_time += delta
	if _street_age < LABEL_FADE:
		_street_age = minf(LABEL_FADE, _street_age + delta)
		_street.modulate.a = _street_age / LABEL_FADE
	if ctx == null or ctx.player == null:
		return
	var f := ctx.player.forward()
	if absf(f.x) + absf(f.z) > 1e-6:
		yaw = atan2(-f.x, -f.z)
	center = Vector2(ctx.player.position.x, ctx.player.position.z)
	_map.rotation = yaw
	if model != null:
		_mat.set_shader_parameter("center", center)
		_mat.set_shader_parameter("ppt", ppt)
	if not is_visible_in_tree():
		return
	_people_t += delta
	if _people_t >= PEOPLE_PERIOD:
		_people_t = 0.0
		_collect_people()
	_marker_t += delta
	if _marker_t >= MARKER_PERIOD:
		_marker_t = 0.0
		_collect_markers()
		_overlay.queue_redraw()
	elif absf(wrapf(yaw - _drawn_yaw, -PI, PI)) > 0.004 or center.distance_squared_to(_drawn_center) * ppt * ppt > 0.09:
		_overlay.queue_redraw()


func _on_player_tile(_x: int, _y: int) -> void:
	_update_street(false)


func _update_street(instant: bool) -> void:
	if ctx == null or ctx.directory == null or ctx.player == null or ctx.sim == null:
		return
	var t := D.debrand(ctx.directory.street_at(ctx.player.position))
	if t == _street.text:
		return
	_street.text = t
	# Centred under the circle when it fits, else left-aligned on the safe margin.
	var w := S.bold().get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x + 8.0
	if w <= DIAM:
		_street.position.x = ORIGIN.x
		_street.size.x = DIAM
		_street.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	else:
		_street.position.x = ORIGIN.x
		_street.size.x = w
		_street.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_street_age = LABEL_FADE if instant else 0.0
	_street.modulate.a = 1.0 if instant else 0.0


## E's agents and the incidents (12 Hz).
func _collect_markers() -> void:
	_agents.clear()
	var me := ctx.player.position
	var tf: FpFeature = ctx.feature("traffic")
	if tf != null and tf.has_method("agents_near"):
		for a: Variant in tf.call("agents_near", me, NEAR_TILES):
			if typeof(a) != TYPE_DICTIONARY:
				continue
			var ad: Dictionary = a
			var p: Vector3 = ad.get("pos", me)
			var v: Vector3 = ad.get("vel", Vector3.ZERO)
			var dir := Vector2(v.x, v.z)
			if dir.length_squared() < 1e-10:
				var h := float(ad.get("heading", 0.0))
				dir = Vector2(-sin(h), -cos(h))
			_agents.append({"pos": Vector2(p.x, p.z), "kind": str(ad.get("kind", "car")), "dir": dir.normalized()})
	_incidents.clear()
	if ctx.sim != null:
		for ev: Dictionary in ctx.sim.events:
			_incidents.append(Vector2(float(ev.get("x", 0)), float(ev.get("y", 0))))


## Visible residents near the player: E's visible_near when present, else one pass over
## residents.people that skips indoor residents without a route (never avatars.position_of).
func _collect_people() -> void:
	_people.clear()
	if ctx.player == null:
		return
	var me := ctx.player.position
	var tf: FpFeature = ctx.feature("traffic")
	if tf != null and tf.has_method("visible_near"):
		for r: Variant in tf.call("visible_near", me, NEAR_TILES):
			if typeof(r) == TYPE_DICTIONARY and (r as Dictionary).has("pos"):
				var p: Vector3 = (r as Dictionary)["pos"]
				_people.append(Vector2(p.x, p.z))
		return
	if ctx.residents == null or not ctx.residents.is_active():
		return
	var r2 := NEAR_TILES * NEAR_TILES
	var n := D.W * D.H
	for r: Dictionary in ctx.residents.people:
		var route: Array = r.get("route", [])
		if route.is_empty():
			var st := str(r.get("state", ""))
			if st in ResidentAvatars.INSIDE or st.begins_with("visiting"):
				continue
		var at := int(r.get("at", -1))
		if at < 0 or at >= n:
			continue
		var p := Vector2(D.tx(at), D.ty(at))
		if p.distance_squared_to(Vector2(me.x, me.z)) <= r2:
			_people.append(p)


## Overlay point (local to _overlay) of a world point; clamp pins it inside the rim.
func _to_overlay(w: Vector2, clamp_rim: bool = false) -> Vector2:
	var off := (w - center).rotated(yaw) * ppt
	if clamp_rim:
		var lim := DIAM * 0.5 - RIM_PAD
		if off.length() > lim:
			off = off.normalized() * lim
	return off + Vector2(DIAM, DIAM) * 0.5 + Vector2(12, 12)


func _draw_overlay() -> void:
	marker_draws += 1
	_drawn_yaw = yaw
	_drawn_center = center
	if model == null:
		return
	var o := _overlay
	var c := Vector2(DIAM, DIAM) * 0.5 + Vector2(12, 12)
	var r := DIAM * 0.5
	var lim2 := (r - 2.0) * (r - 2.0)
	# Residents, then agents.
	for p in _people:
		var q := _to_overlay(p)
		if q.distance_squared_to(c) < lim2:
			o.draw_circle(q, 2.6, Color(0.02, 0.03, 0.05, 0.55), true, -1.0, true)
			o.draw_circle(q, 1.8, Color(0.94, 0.96, 1.0, 0.92), true, -1.0, true)
	for a: Dictionary in _agents:
		var q := _to_overlay(a["pos"])
		if q.distance_squared_to(c) >= lim2:
			continue
		var kind := str(a["kind"])
		if kind == "pedestrian":
			o.draw_circle(q, 1.3, Color(1, 1, 1, 0.55), true, -1.0, true)
			continue
		var d: Vector2 = (a["dir"] as Vector2).rotated(yaw)
		var big := kind == "bus" or kind == "truck"
		var half := Vector2(1.7, 3.2) * (1.35 if big else 1.0)
		var col := S.RED if kind == "emergency" else Color(0.86, 0.9, 0.96, 0.95)
		_rot_rect(o, q, half, d, col)
	# Pings (fading over their 30 s life), under the incidents; one on an incident is left out.
	var pings: Array = hud.get("pings") if hud != null else []
	for e: Dictionary in pings:
		var pos: Vector3 = e["pos"]
		var w := Vector2(pos.x, pos.z)
		if _near_incident(w):
			continue
		var a := float(e.get("alpha", 1.0))
		var col := S.RED if str(e["reason"]).begins_with("event:") else S.AMBER
		var q := _to_overlay(w, true)
		o.draw_arc(q, 6.0, 0.0, TAU, 32, Color(col, 0.9 * a), 2.0, true)
		o.draw_circle(q, 2.4, Color(col, a), true, -1.0, true)
	# Incidents (pinned to the rim when off the map).
	var pulse := 0.5 + 0.5 * sin(_time * 4.0)
	for p in _incidents:
		var q := _to_overlay(p, true)
		o.draw_circle(q, 8.0 + 3.0 * pulse, Color(S.RED, 0.18 * (1.0 - pulse)), true, -1.0, true)
		o.draw_circle(q, 7.0, Color(0.05, 0.02, 0.02, 0.6), true, -1.0, true)
		o.draw_circle(q, 6.0, S.RED, true, -1.0, true)
		o.draw_line(q + Vector2(0, -3.2), q + Vector2(0, 0.9), Color.WHITE, 1.8, true)
		o.draw_circle(q + Vector2(0, 2.8), 1.0, Color.WHITE, true, -1.0, true)
	# Waypoint.
	var wp: Variant = hud.call("waypoint") if hud != null else null
	if wp != null:
		var wpp: Vector3 = wp
		var q := _to_overlay(Vector2(wpp.x, wpp.z), true)
		_diamond(o, q, 7.5, Color(0.02, 0.03, 0.05, 0.6))
		_diamond(o, q, 6.0, S.ACCENT)
		o.draw_circle(q, 1.6, Color(0.02, 0.05, 0.07, 0.9), true, -1.0, true)
	# North badge on the rim.
	var n := c + Vector2(0, -(r - 1.0)).rotated(yaw)
	o.draw_circle(n, 9.0, Color(0.03, 0.04, 0.06, 0.88), true, -1.0, true)
	o.draw_arc(n, 9.0, 0.0, TAU, 32, Color(1, 1, 1, 0.35), 1.0, true)
	var f := S.bold()
	var w := f.get_string_size("N", HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	o.draw_string(f, n + Vector2(-w * 0.5, f.get_ascent(12) * 0.5 - 1.0), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
	# Player arrow: the body's facing relative to the view (straight up when they agree).
	var by := ctx.player.yaw if ctx.player != null else yaw
	var fwd := Vector2(-sin(by), -cos(by)).rotated(yaw)
	_arrow(o, c, fwd)


## True when an incident marker already stands within 1.5 tiles of world point w.
func _near_incident(w: Vector2) -> bool:
	for p in _incidents:
		if p.distance_squared_to(w) < 2.25:
			return true
	return false


## The soft outer shadow and the thin ring (static: drawn once).
func _draw_ring() -> void:
	var c := Vector2(DIAM, DIAM) * 0.5 + Vector2(12, 12)
	var r := DIAM * 0.5
	for k in range(5):
		_ring.draw_arc(c, r + 1.0 + k * 1.4, 0.0, TAU, 96, Color(0, 0, 0, 0.16 - k * 0.03), 1.6, true)
	_ring.draw_arc(c, r - 0.75, 0.0, TAU, 128, Color(1, 1, 1, 0.42), 1.5, true)


func _arrow(o: Control, c: Vector2, fwd: Vector2) -> void:
	var side := Vector2(-fwd.y, fwd.x)
	var tip := c + fwd * 9.0
	var l := c - fwd * 6.0 + side * 6.5
	var rr := c - fwd * 6.0 - side * 6.5
	var notch := c - fwd * 2.6
	var shadow := PackedVector2Array([tip + Vector2(0, 1.2), l + Vector2(0, 1.2), notch + Vector2(0, 1.2), rr + Vector2(0, 1.2)])
	o.draw_colored_polygon(shadow, Color(0, 0, 0, 0.45))
	var body := PackedVector2Array([tip, l, notch, rr])
	o.draw_colored_polygon(body, S.ACCENT)
	var rim := body.duplicate()
	rim.append(tip)
	o.draw_polyline(rim, Color(1, 1, 1, 0.95), 1.4, true)


func _diamond(o: Control, c: Vector2, r: float, col: Color) -> void:
	o.draw_colored_polygon(PackedVector2Array([c + Vector2(0, -r), c + Vector2(r * 0.82, 0), c + Vector2(0, r), c + Vector2(-r * 0.82, 0)]), col)


func _rot_rect(o: Control, c: Vector2, half: Vector2, d: Vector2, col: Color) -> void:
	var fwd := d if d.length_squared() > 1e-6 else Vector2(0, -1)
	var side := Vector2(-fwd.y, fwd.x)
	var pts := PackedVector2Array([
		c + fwd * half.y + side * half.x, c + fwd * half.y - side * half.x,
		c - fwd * half.y - side * half.x, c - fwd * half.y + side * half.x,
	])
	var sh := PackedVector2Array()
	for p in pts:
		sh.append(p + Vector2(0, 0.8))
	o.draw_colored_polygon(sh, Color(0, 0, 0, 0.5))
	o.draw_colored_polygon(pts, col)
