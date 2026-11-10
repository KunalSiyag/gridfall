extends Control
## The mayors' league (feature "reporter", L): the five AI mayors ranked on people, jobs, approval
## and funds (25 points each, ReporterDesk.standings), each with the badge of the model they run
## on, then the player's press card (rank, points, stories filed), the story on assignment, the
## open leads with a button to chase one, and the latest stories. The feature fills it through
## show_league(); nothing here reads the sim.

## The Chase button of open lead k (0: the newest) was pressed.
signal chase_requested(lead: int)

const S := preload("res://scripts/fp/ui/hud_style.gd")
const LG := preload("res://scripts/fp/reporter/league_ledger.gd")
const MINDS := preload("res://scripts/fp/reporter/league_minds.gd")
const DOT := preload("res://scripts/fp/reporter/health_dot.gd")

const WIDTH := 960.0
## The panel's side margins (hud_style.panel) and the gap between two table cells.
const MARGIN := 20.0
const GAP := 8.0
## Table columns: [heading, width px, right-aligned]. With the 8 px gaps they fill the panel's
## inner width (WIDTH less its 20 px margins; Orders and Speed come from the model ledger). District
## holds the longest district name whole (165 px at 14 px: fp_league_ledger_test measures it) and
## Mayor the longest name with its model's badge and the light (207 px).
const COLS := [
	["#", 26, false],
	["Mayor", 220, false],
	["District", 168, false],
	["People", 58, true],
	["Jobs", 52, true],
	["Approval", 72, true],
	["Funds", 74, true],
	["Orders", 60, true],
	["Speed", 64, true],
	["Score", 54, true],
]
const LISTED_STORIES := 3
const TITLES := ["Mayors' league", "Services & minds"]
## The second page's one-line note, under its title.
const MINDS_NOTE := "Who answers for the city besides the mayors: calls so far and how they went"

## 0: the mayors' table and the press card; 1: Services & minds (Tab flips).
var page: int = 0
var _title: Label
var _sub: Label
var _page_a: VBoxContainer
var _page_b: VBoxContainer
var _minds_table: GridContainer
var _minds_none: Label
var _flip_hint: Label
var _sub_text: String = ""
var _table: GridContainer
var _press: Label
var _assignment: Label
var _leads: VBoxContainer
var _stories: VBoxContainer
var _lead_texts: Array[String] = []
var _minds_lines: Array[String] = []


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
	_title = S.plain(TITLES[0], 26, S.WHITE, S.title())
	col.add_child(_title)
	_sub = S.plain("", 14, S.TEXT_DIM, S.font())
	col.add_child(_sub)
	_page_a = _page(col)
	_table = GridContainer.new()
	_table.name = "Table"
	_table.columns = COLS.size()
	_table.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_table.add_theme_constant_override("h_separation", int(GAP))
	_table.add_theme_constant_override("v_separation", 6)
	_page_a.add_child(_table)
	_page_a.add_child(_rule())
	_page_a.add_child(S.caps_label("Your press card", 12, S.AMBER, 0))
	_press = S.plain("", 16, S.TEXT, S.bold())
	_page_a.add_child(_press)
	_assignment = S.plain("", 14, S.TEXT, S.font())
	_assignment.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_page_a.add_child(_assignment)
	_leads = _section(_page_a, "Open leads")
	_stories = _section(_page_a, "Latest stories")
	_page_b = _page(col)
	_minds_table = GridContainer.new()
	_minds_table.name = "MindsTable"
	_minds_table.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_minds_table.add_theme_constant_override("h_separation", int(GAP))
	_minds_table.add_theme_constant_override("v_separation", 6)
	_page_b.add_child(_minds_table)
	_minds_none = S.plain(MINDS.EMPTY, 14, S.TEXT_DIM)
	_page_b.add_child(_minds_none)
	_page_b.visible = false
	col.add_child(_footer())


## rows: ReporterDesk.standings(), best first. desk: {"day" ("Day 6 · 14:20"), "press" (the
## player's rank and points), "assignment" (the story's headline, "" for none), "leads" (open
## leads' lines, newest first), "stories" ({"text", "points", "bonus"}, newest first)}.
func show_league(rows: Array[Dictionary], desk: Dictionary) -> void:
	_sub_text = "%s · People, jobs, approval and funds: 25 points each" % desk.get("day", "")
	_sub.text = _sub_text if page == 0 else MINDS_NOTE
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


## Rows of the Services & minds page: ModelLedger.services().
func show_minds(rows: Array[Dictionary]) -> void:
	MINDS.fill(_minds_table, rows)
	_minds_none.visible = rows.is_empty()
	_minds_lines.clear()
	for r: Dictionary in rows:
		_minds_lines.append(MINDS.line(r))


## Tab: the other page (the mayors' table, Services & minds).
func flip_page() -> void:
	set_page(1 - page)


func set_page(k: int) -> void:
	page = clampi(k, 0, TITLES.size() - 1)
	_page_a.visible = page == 0
	_page_b.visible = page == 1
	_title.text = TITLES[page]
	# The panel is centred, so a page of another height would move its title under the player's
	# eye: the second page takes the first page's last height.
	_page_b.custom_minimum_size.y = _page_a.size.y if page == 1 else 0.0
	_sub.text = _sub_text if page == 0 else MINDS_NOTE
	if _flip_hint != null:
		_flip_hint.text = TITLES[1 - page]


## True for the key that flips the page (Tab, pressed, not an echo).
static func is_flip(event: InputEvent) -> bool:
	var k := event as InputEventKey
	return (
		k != null
		and k.pressed
		and not k.echo
		and (k.keycode == KEY_TAB or k.physical_keycode == KEY_TAB)
	)


## The Services & minds rows as text, one per model (see league_minds.gd line()).
func minds_lines() -> PackedStringArray:
	return PackedStringArray(_minds_lines)


## The health word each mayor's light shows, in table order.
func health_dots() -> PackedStringArray:
	var out := PackedStringArray()
	for cell in _table.get_children():
		for n in cell.get_children():
			if n is Control and n.has_method("set_health"):
				out.append(str(n.get("health")))
	return out


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
		var orders_text := str(
			r.get("orders_text", LG.orders_text(int(r.get("orders", 0)), int(r.get("refused", 0))))
		)
		var no_orders := orders_text == LG.NO_DATA
		var orders := S.plain(orders_text, 14, S.TEXT_DIM if no_orders else S.TEXT, S.font())
		if no_orders:
			orders.tooltip_text = LG.NO_DATA_TIP
			orders.mouse_filter = Control.MOUSE_FILTER_PASS
		_add_cell(orders, COLS[7])
		_add_cell(S.plain(str(r.get("speed", "-")), 14, S.TEXT, S.font()), COLS[8])
		_add_cell(S.plain(str(int(r["score"])), 17, S.WHITE, S.bold()), COLS[9])


## The mayor's name in their colour and their model's badge.
func _who(r: Dictionary, tint: Color) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 8)
	if r.has("health"):
		h.add_child(DOT.make(str(r["health"])))
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
	bar.add_child(S.key_cap("Tab", 12))
	_flip_hint = S.plain(TITLES[1], 13, S.TEXT_DIM)
	bar.add_child(_flip_hint)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(14, 0)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(gap)
	bar.add_child(S.key_cap("L", 12))
	bar.add_child(S.key_cap("Esc", 12))
	bar.add_child(S.plain("Close", 13, S.TEXT_DIM))
	return bar


## One page of the modal: a column that shows or hides as a whole.
static func _page(col: VBoxContainer) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 8)
	col.add_child(v)
	return v


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
		var l: Label = (
			n as Label
			if n is Label
			else (n.get_child(0) as Label if n.get_child_count() > 0 else null)
		)
		if l != null:
			parts.append(l.text)
	return " ".join(parts)
