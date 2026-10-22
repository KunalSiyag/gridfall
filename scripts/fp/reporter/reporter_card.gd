extends Control
## The Gazette card on the HUD (feature "reporter"), bottom right above the district caption: the
## newest lead and the key to take it, or the story on assignment: what happened, where and how
## far, the scoop clock, the quote so far and what the story still needs (the scene, a quote, a
## photo), with the key to file it. The feature fills it through show_state(); nothing here reads
## the sim.

const S := preload("res://scripts/fp/ui/hud_style.gd")

const WIDTH := 320.0
## Text width inside the card: WIDTH less the 12 px side margins and the 3 px stripe.
const INNER := WIDTH - 27.0
const SAFE := 24.0
## The bottom edge, clear of the district caption (90 px tall over the bottom safe margin).
const FROM_BOTTOM := SAFE + 104.0
const BG := Color(0.03, 0.04, 0.07, 0.78)
const TICK := 9.0

var _stripe: StyleBoxFlat
var _kicker: Label
var _rank: Label
var _headline: Label
var _where: Label
var _quote: Label
var _steps: VBoxContainer
## One per step row: {"row", "box" (the tick's StyleBoxFlat), "label"}.
var _ticks: Array[Dictionary] = []
var _foot: HBoxContainer
var _hint: Label


func setup() -> void:
	name = "ReporterCard"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	panel.name = "Card"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stripe = S.stripe(S.box(BG, S.RADIUS, 12, 8), S.AMBER, 3)
	panel.add_theme_stylebox_override("panel", _stripe)
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -SAFE - WIDTH
	panel.offset_right = -SAFE
	panel.offset_top = -FROM_BOTTOM
	panel.offset_bottom = -FROM_BOTTOM
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(panel)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 4)
	panel.add_child(col)
	var head := _hbox(8)
	col.add_child(head)
	_kicker = S.caps_label("", 12, S.AMBER, 0)
	_kicker.name = "Kicker"
	_kicker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_kicker)
	_rank = S.plain("", 12, S.TEXT_DIM, S.font())
	_rank.name = "Rank"
	head.add_child(_rank)
	_headline = _wrapped(S.plain("", 16, S.WHITE, S.bold()), "Headline")
	col.add_child(_headline)
	_where = S.plain("", 12, S.TEXT_DIM, S.font())
	_where.name = "Where"
	_where.clip_text = true
	_where.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_where.custom_minimum_size = Vector2(INNER, 0)
	col.add_child(_where)
	_quote = _wrapped(S.plain("", 13, S.TEXT, S.font()), "Quote")
	col.add_child(_quote)
	_steps = VBoxContainer.new()
	_steps.name = "Steps"
	_steps.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_steps.add_theme_constant_override("separation", 2)
	col.add_child(_steps)
	_foot = _hbox(6)
	_foot.name = "Hint"
	var key := S.key_cap("K", 11)
	key.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_foot.add_child(key)
	_hint = S.caps_label("", 11, S.TEXT, 2)
	_foot.add_child(_hint)
	col.add_child(_foot)


## st: {"kicker" ("New lead", "On assignment", "Ready to file"), "rank" ("Stringer · 120"),
## "color" (the deciding agent's), "headline", "where" ("214 Maple Street · 240 m · scoop 4:10"),
## "quote" ("" for none), "steps" ([text, done] pairs; none for a lead), "hint" (what K does now;
## "" hides the key)}.
func show_state(st: Dictionary) -> void:
	_set_text(_kicker, str(st.get("kicker", "")))
	_set_text(_rank, str(st.get("rank", "")))
	_set_text(_headline, str(st.get("headline", "")))
	_set_text(_where, str(st.get("where", "")))
	_set_text(_quote, str(st.get("quote", "")))
	_quote.visible = not _quote.text.is_empty()
	_stripe.border_color = st.get("color", S.AMBER)
	_show_steps(st.get("steps", []))
	_set_text(_hint, str(st.get("hint", "")))
	_foot.visible = not _hint.text.is_empty()


## Everything the card says now, " · " between the parts (the step rows read "[x] At the scene").
func card_text() -> String:
	var parts := PackedStringArray()
	for l: Label in [_kicker, _rank, _headline, _where, _quote]:
		if l.visible and not l.text.is_empty():
			parts.append(l.text)
	for t: Dictionary in _ticks:
		if (t["row"] as Control).visible:
			var done := (t["box"] as StyleBoxFlat).bg_color == S.GOOD
			parts.append(("[x] " if done else "[ ] ") + (t["label"] as Label).text)
	if _foot.visible:
		parts.append("K " + _hint.text)
	return " · ".join(parts)


func _show_steps(steps: Array) -> void:
	while _ticks.size() < steps.size():
		_ticks.append(_make_step())
	for k in range(_ticks.size()):
		var t: Dictionary = _ticks[k]
		var shown := k < steps.size()
		(t["row"] as Control).visible = shown
		if not shown:
			continue
		var done := bool(steps[k][1])
		var sb: StyleBoxFlat = t["box"]
		sb.bg_color = S.GOOD if done else Color(0, 0, 0, 0)
		sb.border_color = S.GOOD if done else S.TEXT_FAINT
		var l: Label = t["label"]
		_set_text(l, str(steps[k][0]))
		l.add_theme_color_override("font_color", S.TEXT if done else S.TEXT_DIM)
	_steps.visible = not steps.is_empty()


func _make_step() -> Dictionary:
	var row := _hbox(7)
	var tick := Panel.new()
	tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tick.custom_minimum_size = Vector2(TICK, TICK)
	tick.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := S.box(Color(0, 0, 0, 0), S.RADIUS, 0, 0, S.TEXT_FAINT, 1)
	tick.add_theme_stylebox_override("panel", sb)
	row.add_child(tick)
	var l := S.plain("", 13, S.TEXT_DIM, S.font())
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.custom_minimum_size = Vector2(INNER - TICK - 7.0, 0)
	row.add_child(l)
	_steps.add_child(row)
	return {"row": row, "box": sb, "label": l}


static func _wrapped(l: Label, node_name: String) -> Label:
	l.name = node_name
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.max_lines_visible = 2
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.custom_minimum_size = Vector2(INNER, 0)
	return l


static func _set_text(l: Label, t: String) -> void:
	if l.text != t:
		l.text = t


static func _hbox(sep: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", sep)
	return row
