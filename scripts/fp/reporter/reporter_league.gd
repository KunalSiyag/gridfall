extends Control
## The mayors' league (feature "reporter", L): the five AI mayors ranked on people, jobs, approval
## and funds (25 points each, ReporterDesk.standings), each with the badge of the model they run
## on, then the player's press card (rank, points, stories filed), the story on assignment, the
## open leads with a button to chase one, and the latest stories. The feature fills it through
## show_league(); nothing here reads the sim.

## The Chase button of open lead k (0: the newest) was pressed.
signal chase_requested(lead: int)

const S := preload("res://scripts/fp/ui/hud_style.gd")

const WIDTH := 860.0
## Table columns: [heading, width px, right-aligned]. With the 8 px gaps they fill the panel's
## inner width (WIDTH less its 20 px margins).
const COLS := [
	["#", 26, false],
	["Mayor", 226, false],
	["District", 176, false],
	["People", 66, true],
	["Jobs", 58, true],
	["Approval", 76, true],
	["Funds", 76, true],
	["Score", 56, true],
]
const LISTED_STORIES := 3

var _sub: Label
var _table: GridContainer
var _press: Label
var _assignment: Label
var _leads: VBoxContainer
var _stories: VBoxContainer
var _lead_texts: Array[String] = []


func setup() -> void:
	name = "League"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := S.panel(Color(0.03, 0.04, 0.07, 0.92), S.RADIUS_PANEL, 20, 16)
	panel.name = "Panel"
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -WIDTH * 0.5
	panel.offset_right = WIDTH * 0.5
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(panel)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)
	col.add_child(S.plain("Mayors' league", 26, S.WHITE, S.title()))
	_sub = S.plain("", 14, S.TEXT_DIM, S.font())
	col.add_child(_sub)
	_table = GridContainer.new()
	_table.name = "Table"
	_table.columns = COLS.size()
	_table.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_table.add_theme_constant_override("h_separation", 8)
	_table.add_theme_constant_override("v_separation", 6)
	col.add_child(_table)
	col.add_child(_rule())
	col.add_child(S.caps_label("Your press card", 12, S.AMBER, 0))
	_press = S.plain("", 16, S.TEXT, S.bold())
	col.add_child(_press)
	_assignment = S.plain("", 14, S.TEXT, S.font())
	_assignment.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_assignment)
	_leads = _section(col, "Open leads")
	_stories = _section(col, "Latest stories")
	col.add_child(_footer())


## rows: ReporterDesk.standings(), best first. desk: {"day" ("Day 6 · 14:20"), "press" (the
## player's rank and points), "assignment" (the story's headline, "" for none), "leads" (open
## leads' lines, newest first), "stories" ({"text", "points", "bonus"}, newest first)}.
func show_league(rows: Array[Dictionary], desk: Dictionary) -> void:
	_sub.text = "%s · People, jobs, approval and funds: 25 points each" % desk.get("day", "")
	_fill_table(rows)
	_press.text = str(desk.get("press", ""))
	var on := str(desk.get("assignment", ""))
	_assignment.text = "On assignment: " + on if not on.is_empty() else "No story on assignment."
	var lines: Array[String] = []
	for v: Variant in desk.get("leads", []):
		lines.append(str(v))
	if lines != _lead_texts:
		_lead_texts = lines
		_fill_leads()
	_fill_stories(desk.get("stories", []))


## The table's rows as text, one line per mayor ("1 · Viktor Han · Harbor Heights · ... · 78").
func table_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var cells := _table.get_children()
	for start in range(COLS.size(), cells.size(), COLS.size()):
		var parts := PackedStringArray()
		for c in range(COLS.size()):
			parts.append(_cell_text(cells[start + c]))
		out.append(" · ".join(parts))
	return out


## The Chase buttons, newest lead first.
func chase_buttons() -> Array[Button]:
	var out: Array[Button] = []
	for row in _leads.get_children():
		for c in row.get_children():
			if c is Button:
				out.append(c)
	return out


func _fill_table(rows: Array[Dictionary]) -> void:
	for c in _table.get_children():
		_table.remove_child(c)
		c.queue_free()
	for e: Array in COLS:
		_add_cell(S.caps_label(str(e[0]), 11, S.TEXT_DIM, 0), e)
	for k in range(rows.size()):
		var r: Dictionary = rows[k]
		var tint: Color = r["color"]
		_add_cell(S.plain(str(k + 1), 16, tint, S.bold()), COLS[0])
		_add_cell(_who(r, tint), COLS[1])
		_add_cell(S.plain(str(r["district"]), 14, S.TEXT, S.font()), COLS[2])
		_add_cell(S.plain(S.fmt(int(r["pop"])), 14, S.TEXT, S.font()), COLS[3])
		_add_cell(S.plain(S.fmt(int(r["jobs"])), 14, S.TEXT, S.font()), COLS[4])
		var approval := "%.1f/10" % float(r["approval"])
		_add_cell(S.plain(approval, 14, S.TEXT, S.font()), COLS[5])
		var funds := S.plain(S.money(int(r["funds"])), 14, S.TEXT, S.font())
		if int(r["funds"]) < 0:
			funds.add_theme_color_override("font_color", S.RED)
		_add_cell(funds, COLS[6])
		_add_cell(S.plain(str(int(r["score"])), 17, S.WHITE, S.bold()), COLS[7])


## The mayor's name in their colour and their model's badge.
func _who(r: Dictionary, tint: Color) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 8)
	var name_l := S.plain(str(r["who"]), 15, tint, S.bold())
	name_l.name = "Who"
	h.add_child(name_l)
	if not str(r["model"]).is_empty():
		h.add_child(S.badge(str(r["model"]), tint, 10))
	return h


func _add_cell(c: Control, col: Array) -> void:
	c.custom_minimum_size.x = float(col[1])
	if c is Label:
		var l := c as Label
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		if bool(col[2]):
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_table.add_child(c)


func _fill_leads() -> void:
	for c in _leads.get_children():
		_leads.remove_child(c)
		c.queue_free()
	if _lead_texts.is_empty():
		var none := "None open. Every mayor's decision with a place brings one."
		_leads.add_child(S.plain(none, 14, S.TEXT_DIM))
		return
	for k in range(_lead_texts.size()):
		var row := HBoxContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_constant_override("separation", 10)
		var l := S.plain(_lead_texts[k], 14, S.TEXT, S.font())
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(l)
		var b := S.pill_button("Chase", 13)
		# L and Esc must reach _unhandled_input, never move GUI focus.
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(func() -> void: chase_requested.emit(k))
		row.add_child(b)
		_leads.add_child(row)


func _fill_stories(list: Array) -> void:
	for c in _stories.get_children():
		_stories.remove_child(c)
		c.queue_free()
	if list.is_empty():
		_stories.add_child(S.plain("Nothing filed yet. Press K to take a lead.", 14, S.TEXT_DIM))
		return
	for s: Dictionary in list.slice(0, LISTED_STORIES):
		var bonus := str(s.get("bonus", ""))
		var head := "+%d" % int(s.get("points", 0))
		if not bonus.is_empty():
			head += " · " + bonus
		_stories.add_child(S.plain(head, 12, S.GOOD, S.bold()))
		var t := S.plain(str(s.get("text", "")), 14, S.TEXT, S.font())
		t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		t.max_lines_visible = 2
		_stories.add_child(t)


func _section(col: VBoxContainer, title: String) -> VBoxContainer:
	col.add_child(S.caps_label(title, 12, S.AMBER, 0))
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 4)
	col.add_child(v)
	return v


func _footer() -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.alignment = BoxContainer.ALIGNMENT_END
	bar.add_theme_constant_override("separation", 6)
	bar.add_child(S.key_cap("L", 12))
	bar.add_child(S.key_cap("Esc", 12))
	bar.add_child(S.plain("Close", 13, S.TEXT_DIM))
	return bar


static func _rule() -> ColorRect:
	var r := ColorRect.new()
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.color = Color(1, 1, 1, 0.1)
	r.custom_minimum_size = Vector2(0, 1)
	return r


## A table cell's text: a label's, or for the mayor cell the name and the badge.
static func _cell_text(c: Node) -> String:
	if c is Label:
		return (c as Label).text
	var parts := PackedStringArray()
	for n in c.get_children():
		var l := n as Label if n is Label else n.get_child(0) as Label
		if l != null:
			parts.append(l.text)
	return " ".join(parts)
