class_name FpHud
extends CanvasLayer
## First-person HUD shell: named slot Controls the HUD, chat and other slices fill. S0 ships
## placeholders (status line, crosshair, toasts, pause card) so FP is usable before slice B.

const D := preload("res://scripts/sim/sim_defs.gd")
const SLOTS := ["top_bar", "minimap_slot", "chat_slot", "center", "toasts", "overlay"]
## [anchor_left, anchor_top, anchor_right, anchor_bottom, offset_left, offset_top, offset_right, offset_bottom]
## in the 1600x900 base viewport (canvas_items stretch).
const SLOT_RECTS := {
	"top_bar": [0.0, 0.0, 1.0, 0.0, 16, 12, -16, 64],
	"minimap_slot": [0.0, 1.0, 0.0, 1.0, 16, -252, 252, -16],
	"chat_slot": [0.0, 0.0, 0.0, 1.0, 0, 80, 460, -268],
	"center": [0.0, 0.0, 1.0, 1.0, 0, 0, 0, 0],
	"toasts": [0.5, 0.0, 0.5, 0.0, -320, 76, 320, 236],
	"overlay": [0.0, 0.0, 1.0, 1.0, 0, 0, 0, 0],
}
const FONT_PATH := "res://fonts/lilita_one_regular.ttf"
const STATUS_PERIOD := 0.25
const TOAST_SECONDS := 4.0
const TOAST_FADE := 0.6
const MAX_TOASTS := 4
const TOAST_COLORS := {
	"info": Color(1, 1, 1), "alert": Color(1.0, 0.55, 0.45), "success": Color(0.6, 1.0, 0.65),
	"system": Color(0.75, 0.85, 1.0), "chat": Color(1.0, 0.95, 0.7),
}

var ctx: FpContext
var root: Control
var _slots: Dictionary = {}
var _hud_visible: bool = true
var _font: Font
var _status: Label
var _status_t: float = 0.0
var _toast_box: VBoxContainer
## Each entry: {"label": Label, "t": seconds left}.
var _toasts: Array[Dictionary] = []
var _pause_card: PanelContainer


## Builds the slots and the S0 placeholders and connects to the bus.
func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_font = load(FONT_PATH) if ResourceLoader.exists(FONT_PATH) else null
	root = Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	for n: String in SLOTS:
		var r: Array = SLOT_RECTS[n]
		var c := Control.new()
		c.name = n
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.anchor_left = r[0]
		c.anchor_top = r[1]
		c.anchor_right = r[2]
		c.anchor_bottom = r[3]
		c.offset_left = r[4]
		c.offset_top = r[5]
		c.offset_right = r[6]
		c.offset_bottom = r[7]
		root.add_child(c)
		_slots[n] = c
	_build_placeholders()
	if ctx.bus != null:
		ctx.bus.toast.connect(show_toast)
		ctx.bus.ping.connect(_on_ping)
		ctx.bus.pause_changed.connect(_on_pause_changed)
	_refresh_status()


## The slot Control by name (one of SLOTS); asserts on unknown names.
func slot(slot_name: String) -> Control:
	assert(_slots.has(slot_name), "FpHud: unknown slot " + slot_name)
	return _slots.get(slot_name, null)


## Hides or shows every slot except "overlay" (F1 and photo mode).
func set_hud_visible(v: bool) -> void:
	_hud_visible = v
	for n: String in SLOTS:
		if n != "overlay" and _slots.has(n):
			(_slots[n] as Control).visible = v


## True unless set_hud_visible(false) hid the slots.
func is_hud_visible() -> bool:
	return _hud_visible


## Queues a toast in the "toasts" slot. kind: info|alert|success|system|chat.
func show_toast(text: String, kind: String = "info") -> void:
	if _toast_box == null or text.strip_edges().is_empty():
		return
	while _toasts.size() >= MAX_TOASTS:
		var old: Dictionary = _toasts.pop_front()
		(old["label"] as Label).queue_free()
	var l := _make_label(D.debrand(text), 18)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(640, 0)
	l.modulate = TOAST_COLORS.get(kind, Color.WHITE)
	_toast_box.add_child(l)
	_toasts.append({"label": l, "t": TOAST_SECONDS})


func _process(delta: float) -> void:
	_status_t += delta
	if _status_t >= STATUS_PERIOD:
		_status_t = 0.0
		_refresh_status()
	var k := 0
	while k < _toasts.size():
		var e: Dictionary = _toasts[k]
		e["t"] = float(e["t"]) - delta
		var l: Label = e["label"]
		if float(e["t"]) <= 0.0:
			l.queue_free()
			_toasts.remove_at(k)
			continue
		var a := clampf(float(e["t"]) / TOAST_FADE, 0.0, 1.0)
		l.modulate.a = a
		k += 1


func _build_placeholders() -> void:
	_status = _make_label("", 18)
	_status.name = "Status"
	_status.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	slot("top_bar").add_child(_status)
	var cross := ColorRect.new()
	cross.name = "Crosshair"
	cross.color = Color(1, 1, 1, 0.85)
	cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cross.anchor_left = 0.5
	cross.anchor_right = 0.5
	cross.anchor_top = 0.5
	cross.anchor_bottom = 0.5
	cross.offset_left = -2
	cross.offset_right = 2
	cross.offset_top = -2
	cross.offset_bottom = 2
	slot("center").add_child(cross)
	_toast_box = VBoxContainer.new()
	_toast_box.name = "ToastBox"
	_toast_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	_toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	slot("toasts").add_child(_toast_box)
	_pause_card = PanelContainer.new()
	_pause_card.name = "PauseCard"
	_pause_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.06, 0.1, 0.82)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(18)
	_pause_card.add_theme_stylebox_override("panel", sb)
	_pause_card.anchor_left = 0.5
	_pause_card.anchor_right = 0.5
	_pause_card.anchor_top = 0.5
	_pause_card.anchor_bottom = 0.5
	_pause_card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_pause_card.grow_vertical = Control.GROW_DIRECTION_BOTH
	_pause_card.add_child(_make_label("Paused · Esc resume · F5 save · F9 load · F1 hide HUD", 22))
	_pause_card.visible = false
	slot("overlay").add_child(_pause_card)


func _make_label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _font != null:
		l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_constant_override("outline_size", 6)
	l.add_theme_color_override("font_outline_color", Color(0.03, 0.05, 0.08, 0.95))
	return l


func _refresh_status() -> void:
	if _status == null or ctx == null or ctx.sim == null:
		return
	var sim := ctx.sim
	var mood := float(sim.stats.get("happiness", 0.0)) * 10.0
	if ctx.residents != null and ctx.residents.is_active():
		mood = float(ctx.residents.sentiment.get("mood", 0.0)) * 10.0
	var clock := ctx.sky.clock_text() if ctx.sky != null else "--:--"
	var ts := ctx.mode.time_scale if ctx.mode != null else 1
	var funds := sim.total_funds()
	var money := ("-$" if funds < 0 else "$") + _thousands(absi(funds))
	_status.text = "Day %d · %s · Pop %s · Mood %.1f/10 · %s · %dx" % [sim.day, clock, _thousands(int(sim.stats.get("population", 0))), mood, money, ts]


func _on_ping(world_pos: Vector3, reason: String) -> void:
	var tile := -1
	var x := roundi(world_pos.x)
	var y := roundi(world_pos.z)
	if D.in_bounds(x, y):
		tile = D.idx(x, y)
	var where := ctx.directory.place_label(tile) if ctx.directory != null and tile >= 0 else "the frontier"
	show_toast("Attention: %s near %s" % [_reason_label(reason), where], "alert")


func _reason_label(reason: String) -> String:
	if reason.begins_with("event:"):
		var t := reason.substr(6)
		return str((D.DISASTERS.get(t, {}) as Dictionary).get("label", t.capitalize()))
	if reason.begins_with("resident:"):
		if ctx.residents != null:
			var r := ctx.residents.find(reason.substr(9))
			if not r.is_empty():
				return str(r.get("name", "a resident"))
		return "a resident"
	if reason.begins_with("district:"):
		var mi := int(reason.substr(9))
		if mi >= 0 and mi < D.MAYORS.size():
			return str(D.MAYORS[mi]["district"])
		return "a district"
	match reason:
		"player":
			return "your waypoint"
		"tile":
			return "a report"
	return "something"


func _on_pause_changed(p: bool) -> void:
	if _pause_card != null:
		_pause_card.visible = p


static func _thousands(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return ("-" if n < 0 else "") + s + out
