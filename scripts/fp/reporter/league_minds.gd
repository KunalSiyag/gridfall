extends RefCounted
## The league's second page, "Services & minds": the minds that work for the city outside the
## mayors' chairs (the Gazette, the Council Speaker, the Chaos Director, the Grid Operator, Citizen
## Voices, the Street Inspector, the residents' minds and the chat voices), one row per model with
## what it has been asked to do, how many calls, how many answered live, failed, came from a
## recording or were answered by the scripted planner, the typical time to answer and a health
## light. Rows are ModelLedger.services().
## Street text here names people and jobs only ("GridFall Gazette", "Residents", "Chat", the column
## words); the model a row belongs to appears only as its badge (hud_style.badge, meta BADGE_META:
## the one street text allowed to name a model, as on the mayors' table). fp_league_ledger_test
## asserts that every label holding a model's name is a badge.

const S := preload("res://scripts/fp/ui/hud_style.gd")
const LG := preload("res://scripts/fp/reporter/league_ledger.gd")
const DOT := preload("res://scripts/fp/reporter/health_dot.gd")

## [heading, width px, right-aligned]: 8 px gaps between, filling the league panel's inner width
## (ReporterLeague.WIDTH less its margins).
const COLS := [
	["Service", 404, false],
	["Calls", 56, true],
	["Live", 52, true],
	["Failed", 58, true],
	["Replay", 62, true],
	["Scripted", 72, true],
	["Speed", 76, true],
	["Health", 84, false],
]
const TINT := Color("#9DB4FF")
const EMPTY := "Nothing has been asked of these minds yet."


## Fills grid (columns = COLS.size()) with a heading row and one row per entry of rows
## (ModelLedger.services()).
static func fill(grid: GridContainer, rows: Array[Dictionary]) -> void:
	for c in grid.get_children():
		grid.remove_child(c)
		c.queue_free()
	grid.columns = COLS.size()
	for e: Array in COLS:
		_cell(grid, S.caps_label(str(e[0]), 11, S.TEXT_DIM, 0), e)
	for r: Dictionary in rows:
		_cell(grid, _who(r), COLS[0])
		_cell(grid, S.plain(str(int(r["calls"])), 14, S.TEXT, S.font()), COLS[1])
		_cell(grid, S.plain(str(int(r["live_ok"])), 14, S.TEXT, S.font()), COLS[2])
		var failed := int(r["live_fail"])
		var f := S.plain(str(failed), 14, S.RED if failed > 0 else S.TEXT, S.font())
		_cell(grid, f, COLS[3])
		_cell(grid, S.plain(str(int(r["replay"])), 14, S.TEXT, S.font()), COLS[4])
		_cell(grid, S.plain(str(scripted(r)), 14, S.TEXT, S.font()), COLS[5])
		_cell(grid, S.plain(LG.speed_text(r), 14, S.TEXT, S.font()), COLS[6])
		_cell(grid, _health(str(r["health"])), COLS[7])


## A row as text, the way table_lines() reads the mayors' table: "Gazette 4 · Chat 9 · 13 · ...".
static func line(r: Dictionary) -> String:
	var cells := [
		"%s %s" % [r["label"], r["mix"]],
		str(int(r["calls"])),
		str(int(r["live_ok"])),
		str(int(r["live_fail"])),
		str(int(r["replay"])),
		str(scripted(r)),
		LG.speed_text(r),
		LG.health_word(str(r["health"])),
	]
	return " · ".join(PackedStringArray(cells))


## Calls answered by the scripted planner or heuristics (a failed live call, or no key): with
## Live, Failed and Replay it makes a row add up to its Calls.
static func scripted(r: Dictionary) -> int:
	return int(r.get("fallback", 0)) + int(r.get("offline", 0))


static func _who(r: Dictionary) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 8)
	h.add_child(S.badge(str(r["label"]), TINT, 10))
	var mix := S.plain(str(r["mix"]), 14, S.TEXT, S.font())
	mix.name = "Mix"
	mix.clip_text = true
	mix.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	mix.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(mix)
	return h


static func _health(health: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 6)
	h.add_child(DOT.make(health))
	h.add_child(S.plain(LG.health_word(health), 13, S.TEXT_DIM, S.font()))
	return h


static func _cell(grid: GridContainer, c: Control, col: Array) -> void:
	c.custom_minimum_size.x = float(col[1])
	if c is Label:
		var l := c as Label
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		if bool(col[2]):
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	grid.add_child(c)
