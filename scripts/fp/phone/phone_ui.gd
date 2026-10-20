extends Control
## The Build app's phone: who you build for (the district, its mayor and treasury), the six tools,
## the building picked for the Build tool, what placing here would do, and the keys. The feature
## fills it through show_state(); nothing here reads the sim.

const S := preload("res://scripts/fp/ui/hud_style.gd")
const RULES := preload("res://scripts/fp/phone/build_rules.gd")
const WIDTH := 280.0
const FROM_RIGHT := 24.0
const FROM_BOTTOM := 96.0
const SLIDE := 0.16

var _panel: PanelContainer
var _district: Label
var _mayor: Label
var _treasury: Label
var _tools: Dictionary = {}
var _building: Label
var _line: Label
var _hint: Label
var _shown: bool = false
var _t: float = 0.0
var _state: Dictionary = {}


func setup() -> void:
	name = "BuildPhone"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel = S.panel(Color(0.03, 0.04, 0.07, 0.9), S.RADIUS_PANEL, 16, 14, Color(1, 1, 1, 0.14))
	_panel.name = "Phone"
	_panel.custom_minimum_size = Vector2(WIDTH, 0)
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 6)
	_panel.add_child(v)
	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(top)
	top.add_child(S.plain("BUILD", 13, S.ACCENT, S.caps()))
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(gap)
	_treasury = S.plain("", 15, S.GOOD, S.bold())
	_treasury.name = "Treasury"
	top.add_child(_treasury)
	_district = S.plain("", 15, S.WHITE, S.display())
	_district.name = "District"
	_district.uppercase = true
	_district.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_district)
	_mayor = S.plain("", 13, S.TEXT_DIM, S.font())
	_mayor.name = "Mayor"
	v.add_child(_mayor)
	v.add_child(_rule())
	v.add_child(_tool_grid())
	_building = S.plain("", 15, S.TEXT, S.bold())
	_building.name = "Building"
	v.add_child(_building)
	v.add_child(_rule())
	_line = S.plain("", 14, S.TEXT, S.font())
	_line.name = "Line"
	_line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_line.custom_minimum_size = Vector2(WIDTH - 32.0, 0)
	v.add_child(_line)
	_hint = S.plain("", 12, S.TEXT_DIM, S.caps())
	_hint.name = "Hint"
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size = Vector2(WIDTH - 32.0, 0)
	v.add_child(_hint)
	add_child(_panel)
	_panel.visible = false


func _rule() -> ColorRect:
	var r := ColorRect.new()
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.color = S.PANEL_LINE
	r.custom_minimum_size = Vector2(0, 1)
	return r


func _tool_grid() -> GridContainer:
	var g := GridContainer.new()
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	g.columns = 3
	g.add_theme_constant_override("h_separation", 6)
	g.add_theme_constant_override("v_separation", 6)
	for k in range(RULES.TOOLS.size()):
		var id: String = RULES.TOOLS[k]
		var cell := PanelContainer.new()
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.custom_minimum_size = Vector2(76, 0)
		var h := HBoxContainer.new()
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_theme_constant_override("separation", 5)
		cell.add_child(h)
		h.add_child(S.plain(str(k + 1), 11, S.TEXT_FAINT, S.bold()))
		h.add_child(S.plain(str(RULES.TOOL_LABELS[id]), 13, S.TEXT, S.bold()))
		g.add_child(cell)
		_tools[id] = cell
	return g


## Slides the phone in (true) or out.
func set_shown(on: bool) -> void:
	_shown = on
	if on:
		_panel.visible = true


func is_shown() -> bool:
	return _shown


## st: {"district", "mayor", "treasury" (int or null), "tool", "building" (label, "" hides),
## "line", "ok", "hint"}.
func show_state(st: Dictionary) -> void:
	_state = st
	_district.text = str(st.get("district", ""))
	_mayor.text = str(st.get("mayor", ""))
	var t: Variant = st.get("treasury", null)
	_treasury.text = S.money(int(t)) if t != null else ""
	_treasury.add_theme_color_override("font_color", S.GOOD if t != null and int(t) >= 0 else S.RED)
	for id: String in _tools:
		var on := id == str(st.get("tool", ""))
		var bg := Color(0.0, 0.88, 1.0, 0.16) if on else Color(1, 1, 1, 0.05)
		var line := S.ACCENT if on else Color(0, 0, 0, 0)
		(_tools[id] as PanelContainer).add_theme_stylebox_override(
			"panel", S.box(bg, S.RADIUS, 8, 5, line, 1 if on else 0)
		)
	_building.text = str(st.get("building", ""))
	_building.visible = not _building.text.is_empty()
	_line.text = str(st.get("line", ""))
	_line.add_theme_color_override("font_color", S.TEXT if bool(st.get("ok", false)) else S.AMBER)
	_hint.text = str(st.get("hint", ""))


## The last state shown (tests read it).
func state() -> Dictionary:
	return _state


func _process(delta: float) -> void:
	_t = clampf(_t + (delta if _shown else -delta) / SLIDE, 0.0, 1.0)
	_panel.visible = _t > 0.0
	if not _panel.visible:
		return
	var view := size if size.x > 0.0 else get_viewport_rect().size
	var sz := _panel.get_combined_minimum_size()
	_panel.size = sz
	var ease_t := 1.0 - pow(1.0 - _t, 3.0)
	var x := view.x - FROM_RIGHT - sz.x + (1.0 - ease_t) * (sz.x + FROM_RIGHT)
	_panel.position = Vector2(x, view.y - FROM_BOTTOM - sz.y).round()
	_panel.modulate.a = ease_t
