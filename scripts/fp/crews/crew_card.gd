extends Control
## The player's crews on the HUD (feature "crews"), top left under the top bar: how many crews are
## free, a row per order a crew is on (the crew, the order, the time left, what the crew does now,
## a progress bar and how far away the site is) and the orders still waiting for a crew. The
## feature fills it through show_jobs(); nothing here reads the sim.

const S := preload("res://scripts/fp/ui/hud_style.gd")

const WIDTH := 300.0
## Text width inside a row: WIDTH less the 10 px side margins and the 3 px stripe.
const INNER := WIDTH - 23.0
const SAFE := 24.0
## Under the compass strip (it ends at y 106 in the 1600x900 base), level with the AI feed.
const TOP := 118.0
const BAR_H := 4.0
## Waiting orders listed by name; the rest are counted.
const MAX_WAITING := 3
const ROW_BG := Color(0.03, 0.04, 0.07, 0.7)
const WAIT_BG := Color(0.03, 0.04, 0.07, 0.5)
const BAR_BG := Color(1, 1, 1, 0.14)

var _col: VBoxContainer
var _free: Label
var _list: VBoxContainer
var _wait_box: PanelContainer
var _waiting: Label
var _hint: HBoxContainer
## order id -> {"panel", "crew", "label", "left", "detail", "fill"}
var _rows: Dictionary = {}


func setup() -> void:
	name = "CrewCard"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_col = VBoxContainer.new()
	_col.name = "Column"
	_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_col.add_theme_constant_override("separation", 4)
	_col.offset_left = SAFE
	_col.offset_right = SAFE + WIDTH
	_col.offset_top = TOP
	add_child(_col)
	var head := _hbox(8)
	head.name = "Header"
	var title := S.caps_label("Your crews", 12, S.AMBER, 2)
	title.name = "Title"
	head.add_child(title)
	_free = S.label("", 12, S.TEXT_DIM, S.font(), 2)
	_free.name = "Free"
	_free.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_free.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_child(_free)
	_col.add_child(head)
	_list = VBoxContainer.new()
	_list.name = "Rows"
	_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list.add_theme_constant_override("separation", 4)
	_col.add_child(_list)
	_wait_box = PanelContainer.new()
	_wait_box.name = "Waiting"
	_wait_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wait_box.add_theme_stylebox_override("panel", S.box(WAIT_BG, S.RADIUS, 10, 4))
	_waiting = S.plain("", 12, S.TEXT_DIM, S.font())
	_waiting.name = "Text"
	_waiting.custom_minimum_size = Vector2(INNER, 0)
	_wait_box.add_child(_waiting)
	_wait_box.visible = false
	_col.add_child(_wait_box)
	_hint = _hbox(6)
	_hint.name = "Hint"
	var key := S.key_cap("B", 10)
	key.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_hint.add_child(key)
	_hint.add_child(S.caps_label("Phone: order a build", 10, S.TEXT_DIM, 2))
	_col.add_child(_hint)


## rows, the orders a crew is on and then the waiting ones: {"id", "crew" (index, -1 while it
## waits), "label", "stage" (what the crew does now; "" while it waits), "step" ("3 of 5"),
## "fraction" (0..1), "left" (time left, or until a crew is free), "where" ("240 m NE")}. free:
## crews with no order, of crews.
func show_jobs(rows: Array[Dictionary], free: int, crews: int) -> void:
	_free.text = "%d of %d free" % [free, crews] if free > 0 else "all busy"
	var keep := {}
	var waiting := PackedStringArray()
	for r: Dictionary in rows:
		if int(r["crew"]) < 0:
			waiting.append("%s · starts in %s" % [r["label"], r["left"]])
			continue
		var id := int(r["id"])
		keep[id] = true
		if not _rows.has(id):
			_rows[id] = _make_row()
			_list.add_child(_rows[id]["panel"])
		_fill_row(_rows[id], r)
		_list.move_child(_rows[id]["panel"], keep.size() - 1)
	for id: int in _rows.keys():
		if not keep.has(id):
			var p: Control = _rows[id]["panel"]
			_list.remove_child(p)
			p.queue_free()
			_rows.erase(id)
	_show_waiting(waiting)
	_hint.visible = free > 0


## Orders on screen with a crew.
func row_count() -> int:
	return _rows.size()


## The text of order id's row ("Crew 1 · Police Station · 2:05 · pouring concrete · …"), "" when
## no crew is on it.
func row_text(id: int) -> String:
	if not _rows.has(id):
		return ""
	var r: Dictionary = _rows[id]
	var parts := PackedStringArray()
	for k: String in ["crew", "label", "left", "detail"]:
		parts.append((r[k] as Label).text)
	return " · ".join(parts)


## The progress bar's share of order id's row (0..1), -1 when no crew is on it.
func row_fraction(id: int) -> float:
	return float((_rows[id]["fill"] as Control).anchor_right) if _rows.has(id) else -1.0


## The waiting orders' lines ("" when none waits).
func waiting_text() -> String:
	return _waiting.text if _wait_box.visible else ""


## "1 of 2 free" or "all busy".
func free_text() -> String:
	return _free.text


func _show_waiting(lines: PackedStringArray) -> void:
	var shown := lines.slice(0, MAX_WAITING)
	if lines.size() > MAX_WAITING:
		shown.append("and %d more waiting" % (lines.size() - MAX_WAITING))
	var t := "\n".join(shown)
	if not t.is_empty():
		t = "Waiting: " + t
	_waiting.text = t
	_wait_box.visible = not t.is_empty()


func _make_row() -> Dictionary:
	var p := PanelContainer.new()
	p.name = "Order"
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", S.stripe(S.box(ROW_BG, S.RADIUS, 10, 6), S.AMBER, 3))
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 3)
	p.add_child(v)
	var top := _hbox(8)
	top.name = "Top"
	v.add_child(top)
	var crew := S.caps_label("", 12, S.AMBER, 0)
	crew.name = "Crew"
	crew.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(crew)
	var label := S.plain("", 15, S.WHITE, S.bold())
	label.name = "Label"
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(label)
	var left := S.plain("", 15, S.TEXT, S.bold())
	left.name = "Left"
	top.add_child(left)
	var detail := S.plain("", 12, S.TEXT_DIM, S.font())
	detail.name = "Detail"
	detail.clip_text = true
	detail.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	detail.custom_minimum_size = Vector2(INNER, 0)
	v.add_child(detail)
	var bar := ColorRect.new()
	bar.name = "Bar"
	bar.color = BAR_BG
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.custom_minimum_size = Vector2(INNER, BAR_H)
	v.add_child(bar)
	var fill := ColorRect.new()
	fill.name = "Fill"
	fill.color = S.AMBER
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fill.anchor_bottom = 1.0
	bar.add_child(fill)
	return {"panel": p, "crew": crew, "label": label, "left": left, "detail": detail, "fill": fill}


func _fill_row(row: Dictionary, r: Dictionary) -> void:
	_set_text(row["crew"], "Crew %d" % (int(r["crew"]) + 1))
	_set_text(row["label"], str(r["label"]))
	_set_text(row["left"], str(r["left"]))
	var parts := PackedStringArray()
	for k: String in ["stage", "step", "where"]:
		if not str(r.get(k, "")).is_empty():
			parts.append(str(r[k]))
	_set_text(row["detail"], " · ".join(parts))
	(row["fill"] as Control).anchor_right = clampf(float(r.get("fraction", 0.0)), 0.0, 1.0)


static func _set_text(l: Label, t: String) -> void:
	if l.text != t:
		l.text = t


static func _hbox(sep: int) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", sep)
	return h
