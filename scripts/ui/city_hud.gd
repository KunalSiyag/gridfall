class_name CityHud
extends CanvasLayer
## SimCity-style HUD for GridFall: city vitals and RCI demand, time controls, player powers
## (overlays, disasters, decrees, grants, ordinance overrides), the five AI mayor cards, and
## panels for mayor minds, the Gazette, City Hall, the street inspector, the GMI call log and the city feed.

signal speed_requested(s: int)
signal overlay_requested(mode: String)
signal save_requested()
signal load_requested()
signal new_city_requested()
signal focus_district_requested(mi: int)
signal focus_tile_requested(x: int, y: int)
signal mute_requested()
signal resident_selected(id: String)

const D := preload("res://scripts/sim/sim_defs.gd")
const TITLE_FONT := preload("res://fonts/lilita_one_regular.ttf")
const BG := Color(0.055, 0.07, 0.11, 0.93)
const ACCENT := Color(0.0, 0.88, 1.0)
const OVERLAYS := [
	["none", "Normal view"], ["power", "Power grid"], ["water", "Water"], ["pollution", "Pollution"],
	["crime", "Crime"], ["land_value", "Land value"], ["traffic", "Traffic"], ["happiness", "Happiness"],
	["services", "Service coverage"], ["districts", "Districts"],
]
const SPEEDS := [[0, "||"], [1, "1x"], [2, "2x"], [4, "4x"], [8, "8x"]]
const SOURCE_COLORS := {"live": "#5CFF9D", "cache": "#FFD27F", "heuristic": "#FF8A7A"}


class RciMeter extends Control:
	var values: Array[float] = [0.0, 0.0, 0.0]
	const COLS := [Color(0.30, 0.85, 0.42), Color(0.30, 0.62, 1.0), Color(1.0, 0.78, 0.25)]
	const LETTERS := ["R", "C", "I"]

	func _draw() -> void:
		var w := size.x / 3.0
		var bar_h := size.y - 13.0
		var mid := bar_h * 0.5
		draw_rect(Rect2(Vector2.ZERO, Vector2(size.x, bar_h)), Color(0, 0, 0, 0.35))
		for k in range(3):
			var v := clampf(values[k], -1.0, 1.0)
			var h := v * (mid - 1.0)
			draw_rect(Rect2(k * w + 3.0, mid - maxf(h, 0.0), w - 6.0, absf(h)), COLS[k])
			draw_string(ThemeDB.fallback_font, Vector2(k * w + w * 0.5 - 4.0, size.y - 1.0), LETTERS[k], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, COLS[k])
		draw_line(Vector2(0, mid), Vector2(size.x, mid), Color(1, 1, 1, 0.5), 1.0)


var sim: CitySim
var brain: CityBrain
var client: GmiClient

var armed_disaster: String = ""
var selected_mayor: int = 0
var current_overlay: String = "none"

var _root: Control
var _day_label: Label
var _day_bar: ProgressBar
var _stat_labels: Dictionary = {}
var _rci: RciMeter
var _util_bars: Dictionary = {}
var _util_labels: Dictionary = {}
var _ai_label: Label
var _speed_btns: Dictionary = {}
var _live_btn: CheckButton
var _overlay_btns: Dictionary = {}
var _armed_label: Label
var _decree_edit: LineEdit
var _grant_pick: OptionButton
var _ord_box: VBoxContainer
var _ord_checks: Dictionary = {}
var _cards: Array[Dictionary] = []
var _tabs: TabContainer
var _mayor_rt: RichTextLabel
var _gazette_rt: RichTextLabel
var _council_rt: RichTextLabel
var _inspect_rt: RichTextLabel
var _log_rt: RichTextLabel
var _feed_rt: RichTextLabel
var _banner: PanelContainer
var _banner_label: Label
var _banner_t: float = 0.0
var _hover_label: Label
var _toast_label: Label
var _toast_t: float = 0.0
var _refresh_t: float = 0.0
var _log_dirty: bool = true
var _feed_dirty: bool = true
var _mayor_entries: Array[Dictionary] = [{}, {}, {}, {}, {}]
var _mayor_thinking: Array[bool] = [false, false, false, false, false]
var _last_inspect: Dictionary = {}
var _muted: bool = false
var people: Residents
var minds: ResidentMinds
var selected_resident: String = ""
var _people_rt: RichTextLabel
var _people_t: float = 0.0


func _ready() -> void:
	_build()


func setup(p_sim: CitySim, p_brain: CityBrain, p_client: GmiClient) -> void:
	sim = p_sim
	brain = p_brain
	client = p_client
	if not sim.city_log.is_connected(_on_city_log):
		sim.city_log.connect(_on_city_log)
		sim.event_started.connect(_on_event_started)
		sim.day_started.connect(func(_d: int) -> void: _render_council())
		brain.mayor_thinking.connect(func(mi: int) -> void:
			_mayor_thinking[mi] = true
			_refresh_cards()
		)
		brain.mayor_decided.connect(_on_mayor_decided)
		brain.news_published.connect(_on_news)
		brain.council_ruled.connect(_on_council)
		brain.chaos_decided.connect(_on_chaos)
		brain.operator_decided.connect(func(_d: Dictionary) -> void: _render_council())
		brain.inspector_answered.connect(_on_inspector)
		brain.citizens_spoke.connect(func(_v: Array) -> void: _render_council())
		client.call_logged.connect(func(_r: Dictionary) -> void: _log_dirty = true)
	_mayor_entries = [{}, {}, {}, {}, {}]
	_mayor_thinking = [false, false, false, false, false]
	_live_btn.set_pressed_no_signal(client.live_enabled)
	_rebuild_ordinances()
	_render_all()


# ------------------------------------------------------------------ layout

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_build_top_bar()
	_build_tools_panel()
	_build_right_panel()
	_build_dock()
	_build_overlays_ui()


func _build_top_bar() -> void:
	var panel := _panel(BG, ACCENT * Color(1, 1, 1, 0.45))
	panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	panel.offset_left = 8
	panel.offset_top = 6
	panel.offset_right = -8
	panel.offset_bottom = 70
	_root.add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	panel.add_child(row)

	var brand_box := VBoxContainer.new()
	brand_box.add_theme_constant_override("separation", 0)
	row.add_child(brand_box)
	var brand := _label("GRIDFALL", 24, ACCENT)
	brand.add_theme_font_override("font", TITLE_FONT)
	brand_box.add_child(brand)
	brand_box.add_child(_label("5 GMI Cloud AI mayors", 11, Color(0.6, 0.75, 0.9)))

	var day_box := VBoxContainer.new()
	day_box.custom_minimum_size = Vector2(110, 0)
	row.add_child(day_box)
	_day_label = _label("Day 1", 20, Color(1.0, 0.85, 0.3))
	_day_label.add_theme_font_override("font", TITLE_FONT)
	day_box.add_child(_day_label)
	_day_bar = _bar(Color(1.0, 0.85, 0.3))
	_day_bar.custom_minimum_size = Vector2(110, 7)
	day_box.add_child(_day_bar)

	var stats_grid := GridContainer.new()
	stats_grid.columns = 3
	stats_grid.add_theme_constant_override("h_separation", 16)
	stats_grid.add_theme_constant_override("v_separation", 0)
	row.add_child(stats_grid)
	for key: String in ["pop", "jobs", "funds", "happy", "unemp", "events"]:
		var l := _label("-", 13, Color(0.85, 0.92, 1.0))
		l.custom_minimum_size = Vector2(118, 0)
		stats_grid.add_child(l)
		_stat_labels[key] = l

	var rci_box := VBoxContainer.new()
	rci_box.add_theme_constant_override("separation", 0)
	row.add_child(rci_box)
	_rci = RciMeter.new()
	_rci.custom_minimum_size = Vector2(54, 54)
	_rci.tooltip_text = "Zone demand: Residential / Commercial / Industrial"
	rci_box.add_child(_rci)

	var util_grid := GridContainer.new()
	util_grid.columns = 3
	util_grid.add_theme_constant_override("h_separation", 6)
	util_grid.add_theme_constant_override("v_separation", 0)
	row.add_child(util_grid)
	for u: Array in [["power", "Power", Color(1.0, 0.85, 0.2)], ["water", "Water", Color(0.3, 0.65, 1.0)], ["sewage", "Sewage", Color(0.55, 0.85, 0.45)], ["waste", "Waste", Color(0.85, 0.65, 0.4)]]:
		util_grid.add_child(_label(u[1], 12, u[2]))
		var b := _bar(u[2])
		b.custom_minimum_size = Vector2(90, 9)
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		util_grid.add_child(b)
		_util_bars[u[0]] = b
		var vl := _label("-", 11, Color(0.8, 0.85, 0.9))
		vl.custom_minimum_size = Vector2(84, 0)
		util_grid.add_child(vl)
		_util_labels[u[0]] = vl

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var ai_box := VBoxContainer.new()
	ai_box.add_theme_constant_override("separation", 2)
	row.add_child(ai_box)
	var speed_row := HBoxContainer.new()
	speed_row.add_theme_constant_override("separation", 3)
	ai_box.add_child(speed_row)
	for sp: Array in SPEEDS:
		var b := _button(str(sp[1]), 38)
		b.toggle_mode = true
		var s: int = sp[0]
		b.pressed.connect(func() -> void: speed_requested.emit(s))
		speed_row.add_child(b)
		_speed_btns[s] = b
	_ai_label = _label("GMI idle", 11, Color(0.6, 1.0, 0.75))
	_ai_label.custom_minimum_size = Vector2(250, 0)
	ai_box.add_child(_ai_label)

	var sys_box := GridContainer.new()
	sys_box.columns = 3
	sys_box.add_theme_constant_override("h_separation", 3)
	sys_box.add_theme_constant_override("v_separation", 3)
	row.add_child(sys_box)
	var save_b := _button("Save", 56)
	save_b.pressed.connect(func() -> void: save_requested.emit())
	sys_box.add_child(save_b)
	var load_b := _button("Load", 56)
	load_b.pressed.connect(func() -> void: load_requested.emit())
	sys_box.add_child(load_b)
	var new_b := _button("New", 56)
	new_b.pressed.connect(func() -> void: new_city_requested.emit())
	sys_box.add_child(new_b)
	_live_btn = CheckButton.new()
	_live_btn.text = "Live GMI"
	_live_btn.add_theme_font_size_override("font_size", 12)
	_live_btn.tooltip_text = "Off = replay recorded GMI answers, then heuristics"
	_live_btn.toggled.connect(func(on: bool) -> void:
		if client != null:
			client.set_live(on)
			toast("Live GMI inference " + ("ON" if client.live_enabled else "OFF (replay cache)"))
	)
	sys_box.add_child(_live_btn)
	var mute_b := _button("Mute", 56)
	mute_b.pressed.connect(func() -> void:
		_muted = not _muted
		mute_b.text = "Unmute" if _muted else "Mute"
		mute_requested.emit()
	)
	sys_box.add_child(mute_b)


func _build_tools_panel() -> void:
	var panel := _panel(BG, Color(0.5, 0.6, 0.8, 0.35))
	panel.anchor_top = 0.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 8
	panel.offset_top = 78
	panel.offset_right = 262
	panel.offset_bottom = -150
	_root.add_child(panel)
	var tabs := TabContainer.new()
	tabs.add_theme_font_size_override("font_size", 12)
	panel.add_child(tabs)

	# Overlays
	var ov := VBoxContainer.new()
	ov.name = "Overlays"
	ov.add_theme_constant_override("separation", 3)
	tabs.add_child(ov)
	for o: Array in OVERLAYS:
		var b := _button(str(o[1]), 0)
		b.toggle_mode = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var mode: String = o[0]
		b.pressed.connect(func() -> void: set_overlay(mode))
		ov.add_child(b)
		_overlay_btns[mode] = b
	var hint := _label("Click any tile to ask the GMI street inspector what is happening there.", 11, Color(0.65, 0.75, 0.85))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ov.add_child(hint)

	# Disasters
	var dis_scroll := ScrollContainer.new()
	dis_scroll.name = "Disasters"
	dis_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(dis_scroll)
	var dis := VBoxContainer.new()
	dis.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dis.add_theme_constant_override("separation", 3)
	dis_scroll.add_child(dis)
	dis.add_child(_wrap_label("Pick a disaster, then click the map to unleash it. The mayors must respond.", 11, Color(0.75, 0.8, 0.9)))
	for key: String in D.DISASTERS.keys():
		var b := _button(str(D.DISASTERS[key]["label"]), 0)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(func() -> void: arm_disaster(key))
		dis.add_child(b)
	var rnd := _button("Surprise me (random target)", 0)
	rnd.pressed.connect(_random_disaster)
	dis.add_child(rnd)
	var restore := _button("Restore all city systems", 0)
	restore.add_theme_color_override("font_color", Color(0.5, 1.0, 0.65))
	restore.pressed.connect(func() -> void:
		cancel_arm()
		sim.clear_all_events()
		toast("All disasters cleared")
	)
	dis.add_child(restore)
	_armed_label = _wrap_label("", 12, Color(1.0, 0.55, 0.45))
	dis.add_child(_armed_label)

	# Powers
	var pw_scroll := ScrollContainer.new()
	pw_scroll.name = "Powers"
	pw_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(pw_scroll)
	var pw := VBoxContainer.new()
	pw.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pw.add_theme_constant_override("separation", 4)
	pw_scroll.add_child(pw)
	pw.add_child(_label("Decree to all mayors", 13, ACCENT))
	_decree_edit = LineEdit.new()
	_decree_edit.placeholder_text = "e.g. Build more parks!"
	_decree_edit.add_theme_font_size_override("font_size", 12)
	_decree_edit.text_submitted.connect(func(_t: String) -> void: _send_decree())
	pw.add_child(_decree_edit)
	var send := _button("Send decree", 0)
	send.pressed.connect(_send_decree)
	pw.add_child(send)
	pw.add_child(HSeparator.new())
	pw.add_child(_label("Grant city funds", 13, ACCENT))
	_grant_pick = OptionButton.new()
	_grant_pick.add_theme_font_size_override("font_size", 12)
	for m: Dictionary in D.MAYORS:
		_grant_pick.add_item("%s (%s)" % [m["name"], m["district"]])
	pw.add_child(_grant_pick)
	var grant_row := HBoxContainer.new()
	pw.add_child(grant_row)
	for amt: int in [1000, 5000]:
		var gb := _button("+$%s" % _fmt(amt), 0)
		gb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		gb.pressed.connect(func() -> void:
			sim.gift_funds(_grant_pick.selected, amt)
			toast("Granted $%s to %s" % [_fmt(amt), D.MAYORS[_grant_pick.selected]["name"]])
		)
		grant_row.add_child(gb)
	pw.add_child(HSeparator.new())
	pw.add_child(_label("Ordinances (player override)", 13, ACCENT))
	_ord_box = VBoxContainer.new()
	_ord_box.add_theme_constant_override("separation", 0)
	pw.add_child(_ord_box)


func _build_right_panel() -> void:
	var panel := _panel(BG, Color(0.5, 0.6, 0.8, 0.35))
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -392
	panel.offset_top = 78
	panel.offset_right = -8
	panel.offset_bottom = -150
	_root.add_child(panel)
	_tabs = TabContainer.new()
	_tabs.add_theme_font_size_override("font_size", 12)
	panel.add_child(_tabs)
	_mayor_rt = _rich("Mayor")
	_gazette_rt = _rich("Gazette")
	_council_rt = _rich("City Hall")
	_inspect_rt = _rich("Inspect")
	_log_rt = _rich("GMI Log")
	_feed_rt = _rich("Feed")
	_people_rt = _rich("People")
	_people_rt.meta_underlined = true
	_people_rt.meta_clicked.connect(_on_people_meta)
	_tabs.tab_changed.connect(func(_t: int) -> void:
		_log_dirty = true
		_feed_dirty = true
	)


func _rich(tab_name: String) -> RichTextLabel:
	var rt := RichTextLabel.new()
	rt.name = tab_name
	rt.bbcode_enabled = true
	rt.scroll_active = true
	rt.selection_enabled = true
	rt.add_theme_font_size_override("normal_font_size", 13)
	rt.add_theme_font_size_override("bold_font_size", 14)
	rt.add_theme_color_override("default_color", Color(0.86, 0.9, 0.96))
	_tabs.add_child(rt)
	return rt


func _build_dock() -> void:
	var dock := HBoxContainer.new()
	dock.anchor_left = 0.0
	dock.anchor_top = 1.0
	dock.anchor_right = 1.0
	dock.anchor_bottom = 1.0
	dock.offset_left = 8
	dock.offset_top = -142
	dock.offset_right = -8
	dock.offset_bottom = -6
	dock.add_theme_constant_override("separation", 6)
	_root.add_child(dock)
	for mi in range(D.MAYORS.size()):
		var m: Dictionary = D.MAYORS[mi]
		var col := Color(str(m["color"]))
		var card := _panel(BG, col * Color(1, 1, 1, 0.7))
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.mouse_filter = Control.MOUSE_FILTER_STOP
		card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		card.gui_input.connect(func(ev: InputEvent) -> void:
			if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
				select_mayor(mi)
				focus_district_requested.emit(mi)
		)
		dock.add_child(card)
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 1)
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(v)
		var head := HBoxContainer.new()
		head.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(head)
		var name_l := _label(str(m["name"]), 17, col)
		name_l.add_theme_font_override("font", TITLE_FONT)
		head.add_child(name_l)
		var status := _label("", 11, Color(0.7, 0.8, 0.9))
		status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		head.add_child(status)
		v.add_child(_label("%s · %s" % [m["district"], str(m["model"]).get_file()], 10, Color(0.6, 0.68, 0.8)))
		var stats := _label("", 12, Color(0.9, 0.94, 1.0))
		v.add_child(stats)
		var post := _label("", 11, Color(0.82, 0.86, 0.92))
		post.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		post.custom_minimum_size = Vector2(150, 44)
		post.max_lines_visible = 3
		post.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		v.add_child(post)
		for l: Control in [name_l, status, stats, post]:
			l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_cards.append({"panel": card, "status": status, "stats": stats, "post": post, "color": col})


func _build_overlays_ui() -> void:
	_banner = _panel(Color(0.35, 0.05, 0.08, 0.92), Color(1.0, 0.35, 0.35, 0.9))
	_banner.anchor_left = 0.5
	_banner.anchor_right = 0.5
	_banner.offset_left = -330
	_banner.offset_right = 330
	_banner.offset_top = 80
	_banner.offset_bottom = 124
	_banner.visible = false
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_banner)
	_banner_label = _label("", 16, Color(1, 0.95, 0.9))
	_banner_label.add_theme_font_override("font", TITLE_FONT)
	_banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_banner.add_child(_banner_label)

	_hover_label = _label("", 12, Color(0.9, 0.95, 1.0))
	_hover_label.anchor_top = 1.0
	_hover_label.anchor_bottom = 1.0
	_hover_label.offset_left = 272
	_hover_label.offset_top = -172
	_hover_label.offset_right = 1000
	_hover_label.offset_bottom = -150
	_hover_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_hover_label.add_theme_constant_override("outline_size", 5)
	_hover_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_hover_label)

	_toast_label = _label("", 14, Color(0.7, 1.0, 0.85))
	_toast_label.anchor_left = 0.5
	_toast_label.anchor_right = 0.5
	_toast_label.anchor_top = 1.0
	_toast_label.anchor_bottom = 1.0
	_toast_label.offset_left = -300
	_toast_label.offset_right = 300
	_toast_label.offset_top = -180
	_toast_label.offset_bottom = -152
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	_toast_label.add_theme_constant_override("outline_size", 6)
	_toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_toast_label)


# ------------------------------------------------------------------ public API

func set_overlay(mode: String) -> void:
	current_overlay = mode
	for k: String in _overlay_btns.keys():
		(_overlay_btns[k] as Button).set_pressed_no_signal(k == mode)
	overlay_requested.emit(mode)


func show_tab(i: int) -> void:
	_tabs.current_tab = clampi(i, 0, _tabs.get_tab_count() - 1)
	_log_dirty = true
	_feed_dirty = true


func set_speed_display(s: int) -> void:
	for k: int in _speed_btns.keys():
		(_speed_btns[k] as Button).set_pressed_no_signal(k == s)


func select_mayor(mi: int) -> void:
	selected_mayor = clampi(mi, 0, D.MAYORS.size() - 1)
	for i in range(_cards.size()):
		var sb := (_cards[i]["panel"] as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat
		if sb != null:
			sb.border_width_top = 4 if i == selected_mayor else 1
			sb.bg_color = Color(0.09, 0.12, 0.19, 0.96) if i == selected_mayor else BG
	_tabs.current_tab = 0
	_render_mayor()


func arm_disaster(type_name: String) -> void:
	armed_disaster = type_name
	_armed_label.text = "ARMED: %s. Click a tile on the map (Esc cancels)." % D.DISASTERS[type_name]["label"]
	toast("Click the map to unleash: " + str(D.DISASTERS[type_name]["label"]))


func cancel_arm() -> void:
	armed_disaster = ""
	if _armed_label != null:
		_armed_label.text = ""


## Returns true when the click was consumed by an armed disaster.
func handle_tile_click(x: int, y: int) -> bool:
	if not armed_disaster.is_empty():
		var t := armed_disaster
		cancel_arm()
		sim.trigger_disaster(t, x, y, "player", "Unleashed by the player.")
		return true
	brain.inspect_tile(x, y)
	_tabs.current_tab = 3
	return false


func set_hover(x: int, y: int) -> void:
	if sim == null or not D.in_bounds(x, y):
		_hover_label.text = ""
		return
	var rep := sim.tile_report(x, y)
	var bits: Array[String] = ["(%d,%d) %s" % [x, y, rep["kind"]]]
	if int(rep["density"]) > 0:
		bits.append("density %d" % int(rep["density"]))
	bits.append(str(rep["district_mayor"]))
	if int(rep["residents"]) > 0:
		bits.append("%d residents" % int(rep["residents"]))
	if int(rep["jobs"]) > 0:
		bits.append("%d jobs" % int(rep["jobs"]))
	bits.append("power " + ("on" if rep["powered"] else "OFF"))
	bits.append("water " + ("on" if rep["watered"] else "off"))
	if rep["burning"]:
		bits.append("ON FIRE")
	var site: Dictionary = rep.get("construction", {})
	if not site.is_empty():
		bits.append("%s: %s (stage %d/%d, %d%%)" % [site["building"], site["stage_label"], int(site["stage_number"]), int(site["stages"]), int(site["percent_done"])])
	if not armed_disaster.is_empty():
		bits.push_front("[%s]" % armed_disaster.to_upper())
	_hover_label.text = "  ·  ".join(bits)


func toast(msg: String) -> void:
	_toast_label.text = msg
	_toast_t = 3.5


func banner(msg: String, color: Color = Color(1.0, 0.35, 0.35)) -> void:
	_banner_label.text = msg
	var sb := _banner.get_theme_stylebox("panel") as StyleBoxFlat
	if sb != null:
		sb.border_color = color
		sb.bg_color = Color(color.r * 0.3, color.g * 0.3, color.b * 0.3, 0.93)
	_banner.visible = true
	_banner_t = 7.0


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if _decree_edit != null and _decree_edit.has_focus():
		return
	match k.keycode:
		KEY_ESCAPE:
			cancel_arm()
		KEY_SPACE:
			speed_requested.emit(0 if sim.speed > 0 else 1)
		KEY_1:
			speed_requested.emit(1)
		KEY_2:
			speed_requested.emit(2)
		KEY_3:
			speed_requested.emit(4)
		KEY_4:
			speed_requested.emit(8)
		KEY_F5:
			save_requested.emit()
		KEY_F9:
			load_requested.emit()
		_:
			return
	get_viewport().set_input_as_handled()


# ------------------------------------------------------------------ actions

func _send_decree() -> void:
	var t := _decree_edit.text.strip_edges()
	if t.is_empty():
		return
	brain.send_decree(t)
	_decree_edit.text = ""
	_decree_edit.release_focus()
	toast("Decree sent. Mayors read it in their next GMI call.")


func _random_disaster() -> void:
	var spots: Array[int] = []
	for i in range(D.W * D.H):
		if D.is_zone(sim.kind[i]) and sim.level[i] > 0:
			spots.append(i)
	var keys: Array = D.DISASTERS.keys()
	var t: String = keys[randi() % keys.size()]
	var s := spots[randi() % spots.size()] if not spots.is_empty() else D.idx(16, 16)
	cancel_arm()
	var ev := sim.trigger_disaster(t, D.tx(s), D.ty(s), "player", "A surprise from the player.")
	if not ev.is_empty():
		focus_tile_requested.emit(int(ev["x"]), int(ev["y"]))


func _rebuild_ordinances() -> void:
	for c in _ord_box.get_children():
		c.queue_free()
	_ord_checks.clear()
	for key: String in D.ORDINANCES.keys():
		var o: Dictionary = D.ORDINANCES[key]
		var cb := CheckBox.new()
		cb.text = "%s ($%d/day)" % [o["label"], int(o["cost"])]
		cb.tooltip_text = str(o["desc"])
		cb.add_theme_font_size_override("font_size", 11)
		cb.set_pressed_no_signal(sim != null and sim.ordinances.has(key))
		cb.toggled.connect(func(on: bool) -> void:
			if on:
				sim.enact_ordinance(key)
			else:
				sim.repeal_ordinance(key)
			toast(("Enacted " if on else "Repealed ") + str(o["label"]))
			_render_council()
		)
		_ord_box.add_child(cb)
		_ord_checks[key] = cb


# ------------------------------------------------------------------ signal handlers

func _on_mayor_decided(mi: int, entry: Dictionary) -> void:
	_mayor_entries[mi] = entry
	_mayor_thinking[mi] = false
	_refresh_cards()
	if mi == selected_mayor:
		_render_mayor()


func _on_news(paper: Dictionary) -> void:
	_render_gazette()
	var h := str(paper.get("headline", ""))
	if not h.is_empty():
		banner("GAZETTE: " + h, Color(1.0, 0.82, 0.4))


func _on_council(ruling: Dictionary) -> void:
	_render_council()
	for key: String in _ord_checks.keys():
		(_ord_checks[key] as CheckBox).set_pressed_no_signal(sim.ordinances.has(key))
	var en: Array = ruling.get("enacted", [])
	if not en.is_empty():
		var names: Array[String] = []
		for k: Variant in en:
			names.append(str(D.ORDINANCES.get(str(k), {}).get("label", k)))
		banner("COUNCIL PASSES: " + ", ".join(names), Color(0.75, 0.65, 1.0))


func _on_chaos(dec: Dictionary) -> void:
	_render_council()
	if bool(dec.get("trigger", false)):
		var n := str(dec.get("narration", ""))
		banner("CHAOS DIRECTOR: " + (n if not n.is_empty() else str(dec.get("type", "")).to_upper()), Color(1.0, 0.45, 0.3))
		focus_tile_requested.emit(int(dec.get("x", 16)), int(dec.get("y", 16)))


func _on_event_started(ev: Dictionary) -> void:
	if str(ev.get("source", "")) == "player":
		banner("%s at (%d,%d)! The mayors are scrambling." % [ev["label"], int(ev["x"]), int(ev["y"])])


func _on_inspector(out: Dictionary) -> void:
	_last_inspect = out
	_render_inspector()


func _on_city_log(_line: String, _cat: String) -> void:
	_feed_dirty = true


# ------------------------------------------------------------------ rendering

func _process(delta: float) -> void:
	if _banner_t > 0.0:
		_banner_t -= delta
		_banner.modulate.a = clampf(_banner_t, 0.0, 1.0)
		if _banner_t <= 0.0:
			_banner.visible = false
	if _toast_t > 0.0:
		_toast_t -= delta
		_toast_label.modulate.a = clampf(_toast_t, 0.0, 1.0)
	if sim == null:
		return
	_refresh_t -= delta
	if _refresh_t <= 0.0:
		_refresh_t = 0.25
		_refresh_top()
		_refresh_cards()
		if _log_dirty and _tabs.current_tab == 4:
			_render_log()
		if _feed_dirty and _tabs.current_tab == 5:
			_render_feed()
	_people_t -= delta
	if _people_t <= 0.0 and _tabs.current_tab == 6:
		_people_t = 1.0
		_render_people()


func _render_all() -> void:
	_refresh_top()
	_refresh_cards()
	_render_mayor()
	_render_gazette()
	_render_council()
	_render_inspector()
	_render_log()
	_render_feed()
	set_speed_display(sim.speed)
	set_overlay(current_overlay)


func _refresh_top() -> void:
	var s := sim.stats
	var hr := fmod(6.0 + sim.day_progress() * 24.0, 24.0)
	_day_label.text = "Day %d  %02d:%02d" % [sim.day, int(hr), int(fmod(hr, 1.0) * 4.0) * 15]
	_day_bar.value = sim.day_progress() * 100.0
	_stat_labels["pop"].text = "Pop %s" % _fmt(int(s.get("population", 0)))
	_stat_labels["jobs"].text = "Jobs %s" % _fmt(int(s.get("jobs", 0)))
	_stat_labels["funds"].text = "Funds $%s" % _fmt(sim.total_funds())
	_stat_labels["happy"].text = "Happy %d%%" % int(round(float(s.get("happiness", 0.0)) * 100.0))
	_stat_labels["unemp"].text = "Jobless %d%%" % int(round(float(s.get("unemployment", 0.0)) * 100.0))
	var ev_n := sim.events.size()
	var ev_l: Label = _stat_labels["events"]
	ev_l.text = "Events %d" % ev_n
	ev_l.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4) if ev_n > 0 else Color(0.85, 0.92, 1.0))
	_rci.values = [float(sim.demand["r"]), float(sim.demand["c"]), float(sim.demand["i"])]
	_rci.queue_redraw()
	_set_util("power", float(s.get("power_need", 0)), float(s.get("power_cap", 0)), "MW")
	_set_util("water", float(s.get("water_need", 0)), float(s.get("water_cap", 0)), "")
	_set_util("sewage", float(s.get("sewage_need", 0)), float(s.get("sewage_cap", 0)), "")
	if float(s.get("waste_need", 0)) <= 25.0 and float(s.get("waste_cap", 0)) <= 0.0:
		(_util_bars["waste"] as ProgressBar).value = 0.0
		(_util_labels["waste"] as Label).text = "small town"
	else:
		_set_util("waste", float(s.get("waste_need", 0)), float(s.get("waste_cap", 0)), "")
	var cs := client.stats
	var pend := brain.pending_calls()
	var txt := ""
	if sim.waiting_for_ai:
		txt = "Mayors deliberating on GMI (%d)..." % brain.mayors_pending()
	elif pend > 0:
		txt = "GMI: %d calls in flight" % pend
	else:
		txt = "GMI: idle"
	txt += "  ·  live %d  cache %d  heur %d  avg %.1fs" % [int(cs["live_ok"]), int(cs["cache"]), int(cs["heuristic"]), float(client.avg_latency_ms()) / 1000.0]
	if not client.live_enabled:
		txt += "  [REPLAY]"
	_ai_label.text = txt
	_ai_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35) if pend > 0 else Color(0.6, 1.0, 0.75))
	set_speed_display(sim.speed)


func _set_util(key: String, need: float, cap: float, unit: String) -> void:
	var b: ProgressBar = _util_bars[key]
	var ratio := need / cap if cap > 0.0 else (1.5 if need > 0.0 else 0.0)
	b.value = clampf(ratio, 0.0, 1.0) * 100.0
	var sb := b.get_theme_stylebox("fill") as StyleBoxFlat
	if sb != null:
		sb.bg_color = Color(1.0, 0.3, 0.3) if ratio > 1.0 else (Color(1.0, 0.75, 0.25) if ratio > 0.85 else Color(0.35, 0.9, 0.5))
	(_util_labels[key] as Label).text = "%d/%d%s" % [int(need), int(cap), unit]


func _refresh_cards() -> void:
	if sim == null:
		return
	for mi in range(_cards.size()):
		var c: Dictionary = _cards[mi]
		var m: Dictionary = sim.mayors[mi]
		var e: Dictionary = _mayor_entries[mi]
		(c["stats"] as Label).text = "$%s  ·  pop %s  ·  %d%% happy" % [_fmt(int(m["treasury"])), _fmt(int(m["pop"])), int(round(float(m["happiness"]) * 100.0))]
		var st: Label = c["status"]
		if _mayor_thinking[mi]:
			st.text = "thinking on GMI..."
			st.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
		elif not e.is_empty():
			var src := str(e.get("source", ""))
			st.text = "%s %.1fs · %s" % [src, float(e.get("latency_ms", 0)) / 1000.0, str(e.get("mood", ""))]
			st.add_theme_color_override("font_color", Color(str(SOURCE_COLORS.get(src, "#CCCCCC"))))
		else:
			st.text = "ready"
		var post := str(e.get("post", ""))
		(c["post"] as Label).text = "\"%s\"" % post if not post.is_empty() else "Waiting for first decision..."


func _render_mayor() -> void:
	if sim == null:
		return
	var mi := selected_mayor
	var m: Dictionary = D.MAYORS[mi]
	var sm: Dictionary = sim.mayors[mi]
	var e: Dictionary = _mayor_entries[mi]
	var t := "[font_size=20][color=%s][b]%s[/b][/color][/font_size]\n" % [m["color"], m["name"]]
	t += "[color=#9AB]%s · %s\nModel: %s[/color]\n" % [m["district"], m["style"], m["model"]]
	t += "Treasury [b]$%s[/b]  ·  income $%d  ·  upkeep $%d\n" % [_fmt(int(sm["treasury"])), int(sm["last_income"]), int(sm["last_upkeep"])]
	t += "Taxes R%d C%d I%d  ·  pop %s  ·  jobs %s\n" % [int(sm["tax_r"]), int(sm["tax_c"]), int(sm["tax_i"]), _fmt(int(sm["pop"])), _fmt(int(sm["jobs"]))]
	t += "Actions accepted %d · rejected %d\n\n" % [int(sm["actions_ok"]), int(sm["actions_rejected"])]
	if e.is_empty():
		t += "[i]No decision yet.[/i]"
	else:
		var src := str(e.get("source", ""))
		t += "[b]Day %d decision[/b]  [color=%s]%s[/color] %.1fs\n" % [int(e["day"]), SOURCE_COLORS.get(src, "#CCC"), src.to_upper(), float(e.get("latency_ms", 0)) / 1000.0]
		if not str(e.get("error", "")).is_empty():
			t += "[color=#F98]live error: %s[/color]\n" % _esc(str(e["error"]).left(120))
		t += "\n[color=#FFD27F][b]Private thought[/b][/color]\n%s\n\n" % _esc(str(e.get("thought", "")))
		t += "[color=#7FD1FF][b]Public post[/b][/color]\n\"%s\"\n\n" % _esc(str(e.get("post", "")))
		t += "[b]Actions[/b]\n"
		for a: Dictionary in e.get("actions", []):
			var ok := bool(a.get("ok", false))
			t += "[color=%s]%s[/color] %s [color=#9AB]- %s[/color]\n" % ["#5CFF9D" if ok else "#FF7A6A", "OK" if ok else "NO", _esc(_action_text(a.get("action", {}))), _esc(str(a.get("reason", "")))]
	_mayor_rt.text = t


func _action_text(a: Dictionary) -> String:
	match str(a.get("type", "")):
		"road":
			return "road (%d,%d)->(%d,%d)" % [int(a.get("x", 0)), int(a.get("y", 0)), int(a.get("x2", 0)), int(a.get("y2", 0))]
		"zone":
			return "zone %s %dx%d at (%d,%d)" % [a.get("zone", "?"), int(a.get("w", 1)), int(a.get("h", 1)), int(a.get("x", 0)), int(a.get("y", 0))]
		"build":
			return "build %s at (%d,%d)" % [a.get("building", "?"), int(a.get("x", 0)), int(a.get("y", 0))]
		"set_tax":
			return "taxes R%d C%d I%d" % [int(a.get("r", 0)), int(a.get("c", 0)), int(a.get("i", 0))]
		"grant":
			return "grant $%d to %s" % [int(a.get("amount", 0)), a.get("to", "?")]
	return JSON.stringify(a).left(80)


func _render_gazette() -> void:
	var p: Dictionary = brain.last_paper if brain != null else {}
	if p.is_empty():
		_gazette_rt.text = "[i]The GridFall Gazette (%s) publishes from Day 2.[/i]" % D.SUPPORT_AGENTS["news"]["model"]
		return
	var src := str(p.get("source", ""))
	var t := "[font_size=11][color=#9AB]THE GRIDFALL GAZETTE · Day %d · %s · [color=%s]%s[/color][/color][/font_size]\n" % [int(p.get("day", 0)), D.SUPPORT_AGENTS["news"]["model"], SOURCE_COLORS.get(src, "#CCC"), src]
	t += "[font_size=19][b]%s[/b][/font_size]\n\n" % _esc(str(p.get("headline", "")))
	for s: Variant in p.get("stories", []):
		if typeof(s) == TYPE_DICTIONARY:
			t += "[color=#FFD27F][b]%s[/b][/color]\n%s\n\n" % [_esc(str(s.get("title", ""))), _esc(str(s.get("body", "")))]
	if p.has("editorial"):
		t += "[i][color=#C9B6FF]Editorial:[/color] %s[/i]\n" % _esc(str(p["editorial"]))
	_gazette_rt.text = t


func _render_council() -> void:
	if brain == null:
		return
	var t := "[b][color=#C9B6FF]City Council[/color][/b] [color=#9AB](%s)[/color]\n" % D.SUPPORT_AGENTS["council"]["model"]
	var c: Dictionary = brain.last_council
	if not c.is_empty():
		t += "Day %d: \"%s\"\n" % [int(c.get("day", 0)), _esc(str(c.get("statement", "")))]
	t += "\n[b]Active ordinances[/b]\n"
	if sim.ordinances.is_empty():
		t += "[i]none[/i]\n"
	for k: String in sim.ordinances.keys():
		t += "- %s [color=#9AB](%s)[/color]\n" % [D.ORDINANCES[k]["label"], D.ORDINANCES[k]["desc"]]
	t += "\n[b]Proposals on the floor[/b]\n"
	if brain.proposals.is_empty():
		t += "[i]none[/i]\n"
	for k: String in brain.proposals.keys():
		var pr: Dictionary = brain.proposals[k]
		var yes := 0
		var no := 0
		for v: Variant in (pr["votes"] as Dictionary).values():
			if str(v).begins_with("y"):
				yes += 1
			else:
				no += 1
		t += "- %s by %s  [color=#5CFF9D]%d yes[/color] [color=#FF7A6A]%d no[/color]\n" % [D.ORDINANCES.get(k, {}).get("label", k), pr.get("by", "?"), yes, no]
	var op: Dictionary = brain.last_operator
	t += "\n[b][color=#9CFF8F]Grid Operator[/color][/b] [color=#9AB](%s)[/color]\n" % D.SUPPORT_AGENTS["operator"]["model"]
	var names: Array[String] = []
	for d: Variant in sim.grid_priority:
		names.append(str(D.MAYORS[int(d)]["name"]))
	t += "Load-shed order (last loses power first): %s\n" % " > ".join(names)
	if not op.is_empty():
		t += "%s\n[i]%s[/i]\n" % [_esc(str(op.get("note", ""))), _esc(str(op.get("advice", "")))]
	var ch: Dictionary = brain.last_chaos
	t += "\n[b][color=#FF7A59]Chaos Director[/color][/b] [color=#9AB](%s)[/color]\n" % D.SUPPORT_AGENTS["chaos"]["model"]
	if ch.is_empty():
		t += "[i]Watching quietly (acts from Day 4).[/i]\n"
	else:
		t += "Day %d: %s\n%s\n" % [int(ch.get("day", 0)), ("struck with " + str(ch.get("type", ""))) if bool(ch.get("trigger", false)) else "held back", _esc(str(ch.get("reason", "")))]
	if sim.work_based():
		t += "\n[b][color=#7FD1FF]Resident voices[/color][/b] [color=#9AB](each resident's own GMI mind)[/color]\n"
	else:
		t += "\n[b][color=#7FD1FF]Citizen voices[/color][/b] [color=#9AB](%s)[/color]\n" % D.SUPPORT_AGENTS["citizens"]["model"]
	for v: Variant in brain.last_voices:
		if typeof(v) == TYPE_DICTIONARY:
			var mood := str(v.get("mood", "ok"))
			var col := "#9FE" if mood == "happy" else ("#FD8" if mood in ["ok", "upset"] else "#F87")
			t += "[color=%s]%s[/color] (%s, %s): \"%s\"\n" % [col, v.get("name", "?"), D.MAYORS[int(v.get("district", 0))]["name"], mood, _esc(str(v.get("thought", "")))]
	_council_rt.text = t


func _render_inspector() -> void:
	var o := _last_inspect
	if o.is_empty():
		_inspect_rt.text = "[i]Click any tile in the city. The Street Inspector (%s) role-plays whoever is standing there and diagnoses the problem.[/i]" % D.SUPPORT_AGENTS["inspector"]["model"]
		return
	var rep: Dictionary = o.get("report", {})
	var t := "[b]Tile (%d,%d) · %s[/b]\n[color=#9AB]%s's district[/color]\n" % [int(o["x"]), int(o["y"]), rep.get("kind", "?"), rep.get("district_mayor", "?")]
	t += "Residents %d · jobs %d · density %d\n" % [int(rep.get("residents", 0)), int(rep.get("jobs", 0)), int(rep.get("density", 0))]
	t += "Power %s · water %s · road access %s\n" % ["yes" if rep.get("powered", false) else "[color=#F87]NO[/color]", "yes" if rep.get("watered", false) else "no", "yes" if rep.get("road_access", false) else "[color=#F87]NO[/color]"]
	var site: Dictionary = rep.get("construction", {})
	if not site.is_empty():
		t += "[color=#FFB800]Construction: %s, %s (stage %d of %d, %d%% done)[/color]\nCrew: %s\n" % [_esc(str(site["building"])), site["stage_label"], int(site["stage_number"]), int(site["stages"]), int(site["percent_done"]), _esc(", ".join(PackedStringArray(site["crew"])))]
	t += "Pollution %.2f · crime %.2f · land value %.2f · traffic %.2f · happiness %.2f\n\n" % [float(rep.get("pollution", 0)), float(rep.get("crime", 0)), float(rep.get("land_value", 0)), float(rep.get("traffic", 0)), float(rep.get("happiness", 0))]
	if bool(o.get("pending", false)):
		t += "[color=#FFD27F]Asking the street inspector on GMI...[/color]"
	else:
		var src := str(o.get("source", ""))
		t += "[color=#7FD1FF][b]%s says[/b][/color] [color=%s](%s %.1fs)[/color]\n\"%s\"\n\n" % [_esc(str(o.get("speaker", "Local"))), SOURCE_COLORS.get(src, "#CCC"), src, float(o.get("latency_ms", 0)) / 1000.0, _esc(str(o.get("says", "")))]
		t += "[b]Diagnosis:[/b] %s\n[b]Suggestion:[/b] %s\n" % [_esc(str(o.get("diagnosis", ""))), _esc(str(o.get("suggestion", "")))]
	_inspect_rt.text = t


func _render_log() -> void:
	_log_dirty = false
	var t := "[b]GMI Cloud inference log[/b]  [color=#9AB]live %d · cache %d · heuristic %d · failed live %d[/color]\n" % [int(client.stats["live_ok"]), int(client.stats["cache"]), int(client.stats["heuristic"]), int(client.stats["live_fail"])]
	var recs := client.log_records
	for k in range(recs.size() - 1, maxi(-1, recs.size() - 61), -1):
		var r: Dictionary = recs[k]
		var src := str(r.get("source", ""))
		t += "[color=#9AB]D%d[/color] [b]%s/%s[/b] [color=%s]%s[/color] %dms [color=#9AB]%s[/color]\n" % [int(r.get("day", 0)), r.get("role", ""), r.get("agent", ""), SOURCE_COLORS.get(src, "#CCC"), src, int(r.get("latency_ms", 0)), str(r.get("model", "")).get_file()]
		var err := str(r.get("error", ""))
		if not err.is_empty():
			t += "   [color=#F98]%s[/color]\n" % _esc(err.left(100))
		t += "   %s\n" % _esc(str(r.get("summary", "")))
	_log_rt.text = t


func _render_feed() -> void:
	_feed_dirty = false
	var lines := sim.log_lines
	var t := ""
	for k in range(lines.size() - 1, maxi(-1, lines.size() - 80), -1):
		t += _esc(lines[k]) + "\n"
	_feed_rt.text = t


# ------------------------------------------------------------------ residents

func setup_people(p_people: Residents, p_minds: ResidentMinds) -> void:
	people = p_people
	minds = p_minds
	selected_resident = ""
	_render_people()


func show_resident(id: String) -> void:
	selected_resident = id
	_tabs.current_tab = 6
	_render_people()


func _on_people_meta(meta: Variant) -> void:
	var m := str(meta)
	if m == "back":
		selected_resident = ""
		resident_selected.emit("")
	elif m.begins_with("r:"):
		selected_resident = m.substr(2)
		resident_selected.emit(selected_resident)
	elif m.begins_with("focus:"):
		resident_selected.emit(m.substr(6))
	_render_people()


func _mood_col(m: float) -> String:
	return "#5CFF9D" if m >= 7.0 else ("#DDE6F0" if m >= 5.0 else ("#FFD27F" if m >= 3.0 else "#FF7A6A"))


func _render_people() -> void:
	if _people_rt == null:
		return
	if people == null or not people.enabled:
		_people_rt.text = "[i]AI residents are turned off (GRIDFALL_RESIDENTS=0).[/i]"
		return
	if not selected_resident.is_empty():
		var sel := people.find(selected_resident)
		if not sel.is_empty():
			_people_rt.text = _resident_detail(sel)
			return
		selected_resident = ""
	var t := "[b][color=#7FD1FF]GridFall residents[/color][/b] [color=#9AB]%d named people, each one speaks for about %d[/color]\n" % [people.people.size(), int(people.share)]
	if people.people.is_empty():
		_people_rt.text = t + "[i]Nobody lives here yet. Residents move in as homes get built.[/i]"
		return
	var s := people.sentiment
	t += "Mood %.1f/10 · would recommend %.1f/10 · %d%% thinking of leaving · %d%% went to work\n" % [float(s["mood"]) * 10.0, float(s["recommend"]), int(float(s["leaving"]) * 100.0), int(float(s["attendance"]) * 100.0)]
	if minds != null:
		t += "[color=#9AB]Minds: [color=#5CFF9D]live %d[/color] · [color=#FFD27F]cache %d[/color] · [color=#FF8A7A]heuristic %d[/color] · thinking now %d[/color]\n" % [int(minds.stats["live"]), int(minds.stats["cache"]), int(minds.stats["heuristic"]), minds.pending()]
		var ml: Array[String] = []
		for model: String in minds.model_stats.keys():
			var st: Dictionary = minds.model_stats[model]
			if int(st["ok"]) + int(st["fail"]) > 0:
				ml.append("%s %d/%d %.1fs" % [model.get_file(), int(st["ok"]), int(st["ok"]) + int(st["fail"]), float(st["ms"]) / 1000.0 / float(maxi(1, int(st["ok"])))])
		if not ml.is_empty():
			t += "[color=#9AB]%s[/color]\n" % " · ".join(PackedStringArray(ml))
	t += "\n[b]Districts[/b]\n"
	for d in range(D.MAYORS.size()):
		var dm := people.district_mood(d)
		t += "[color=%s]%s[/color]: %d people · mood [color=%s]%.1f[/color] · approval %.1f · %d may leave · %d protested\n" % [D.MAYORS[d]["color"], D.MAYORS[d]["name"], int(dm["residents"]), _mood_col(float(dm["avg_mood"])), float(dm["avg_mood"]), float(dm["approval"]), int(dm["thinking_of_leaving"]), int(dm["protested_yesterday"])]
	var helping: Array[String] = []
	for r in people.people:
		if int(r["helping"]) >= 0:
			helping.append("[url=r:%s]%s[/url] (%s) %s" % [r["id"], _esc(str(r["name"])), r["job_title"], _esc(str(r["state"]))])
	if not helping.is_empty():
		t += "\n[b][color=#FFB86B]Out fixing things right now[/color][/b]\n" + "\n".join(PackedStringArray(helping.slice(0, 12))) + "\n"
	var sorted: Array = people.people.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["mood"]) < float(b["mood"]))
	t += "\n[b]Everyone[/b] [color=#9AB](least happy first; click a name)[/color]\n"
	for r: Dictionary in sorted:
		var m := float(r["mood"])
		var flag := ""
		if str(r["intent"]) == "leaving":
			flag = " [color=#FF7A6A]leaving[/color]"
		elif str(r["intent"]) == "considering_leaving":
			flag = " [color=#FFD27F]may leave[/color]"
		t += "[url=r:%s]%s[/url] [color=#9AB]%s[/color] [color=%s]%.0f[/color]%s · %s\n" % [r["id"], _esc(str(r["name"])), r["job_title"], _mood_col(m), m, flag, _esc(str(r["state"]))]
	if not people.departed.is_empty():
		t += "\n[b][color=#FF8A7A]Moved away[/color][/b]\n"
		for k in range(people.departed.size() - 1, maxi(-1, people.departed.size() - 9), -1):
			var dr: Dictionary = people.departed[k]
			t += "%s (%s), day %d: %s\n" % [_esc(str(dr["name"])), dr["job_title"], int(dr.get("left_day", 0)), _esc(str(dr.get("left_reason", "")))]
	t += "\n[i][color=#9AB]Click a person walking in the city to read their mind.[/color][/i]"
	_people_rt.text = t


func _resident_detail(r: Dictionary) -> String:
	var h := int(r["home"])
	var w := int(r["work"])
	var t := "[url=back]< all residents[/url]   [url=focus:%s]show in city[/url]\n\n" % r["id"]
	t += "[b][font_size=17]%s[/font_size][/b], %d, [color=#7FD1FF]%s[/color]\n" % [_esc(str(r["name"])), int(r["age"]), r["job_title"]]
	var skills: Array = (r["skills"] as Array).map(func(sk: Variant) -> String: return str(D.SKILL_LABELS.get(str(sk), sk)))
	t += "[color=#9AB]Skills: %s · %s · %s · in GridFall %d days[/color]\n" % [", ".join(PackedStringArray(skills)) if not skills.is_empty() else "none in particular", ", ".join(PackedStringArray(r["traits"] as Array)), r["household"], sim.day - int(r["arrived"])]
	var work := "unemployed"
	if str(r["job_title"]) == "retiree":
		work = "retired"
	elif w >= 0:
		work = "works at (%d,%d), %s" % [D.tx(w), D.ty(w), str(D.KIND_NAMES[sim.kind[w]]).replace("_", " ")]
	t += "Lives at (%d,%d) in [color=%s]%s[/color]'s district · %s\n" % [D.tx(h), D.ty(h), D.MAYORS[sim.district[h]]["color"], D.MAYORS[sim.district[h]]["name"], work]
	t += "Right now: [b]%s[/b]\n" % _esc(str(r["state"]))
	var m := float(r["mood"])
	t += "Mood [color=%s][b]%.1f/10[/b][/color] %s · plans to [b]%s[/b] · recommends GridFall %.0f/10 · approves of mayor %.0f/10\n" % [_mood_col(m), m, ("(" + _esc(str(r["mood_reason"])) + ")") if not str(r["mood_reason"]).is_empty() else "", str(r["intent"]).replace("_", " "), float(r["recommend"]), float(r["approve"])]
	t += "Money: savings [b]$%d[/b] · wage $%d/day · rent $%d/day · spent $%d today\n" % [int(float(r["savings"])), int(r["wage"]), people.rent_for(r), int(r["spent"])]
	var src := str(r["source"])
	t += "\n[color=%s]Mind: %s%s, day %d[/color]\n" % [SOURCE_COLORS.get(src, "#CCC"), src if not src.is_empty() else "not consulted yet", (" via " + str(r["model"])) if not str(r["model"]).is_empty() else "", int(r.get("plan_day", 0))]
	if not str(r["thought"]).is_empty():
		t += "[i]Thinks: \"%s\"[/i]\n" % _esc(str(r["thought"]))
	if not str(r["say"]).is_empty():
		t += "Says: \"%s\"\n" % _esc(str(r["say"]))
	var p: Dictionary = r.get("plan", {})
	if not p.is_empty():
		t += "Today: %s by %s, spend $%d (%s), evening: %s\n" % ["goes to work" if bool(p.get("go_to_work", true)) else "skips work", p.get("commute", "car"), int(p.get("spend", 0)), p.get("spend_where", "local"), str(p.get("evening", "home")).replace("_", " ")]
	if not str(r["message"]).is_empty():
		t += "To the mayor: [color=#FFD27F]\"%s\"[/color]\n" % _esc(str(r["message"]))
	if not str(r.get("reaction", "")).is_empty():
		t += "Last emergency: chose to [b]%s[/b] at the %s. %s\n" % [r["reaction"], r.get("reaction_event", "incident"), ("\"" + _esc(str(r.get("reaction_thought", ""))) + "\"") if not str(r.get("reaction_thought", "")).is_empty() else ""]
	t += "\n[b]Memory[/b]\n"
	for line: Variant in r["memory"]:
		t += "- %s\n" % _esc(str(line))
	return t

# ------------------------------------------------------------------ widgets

func _panel(bg: Color, border: Color) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 9
	sb.content_margin_right = 9
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 4
	p.add_theme_stylebox_override("panel", sb)
	return p


func _label(t: String, size_px: int, col: Color) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", col)
	return l


func _wrap_label(t: String, size_px: int, col: Color) -> Label:
	var l := _label(t, size_px, col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(200, 0)
	return l


func _button(t: String, min_w: int) -> Button:
	var b := Button.new()
	b.text = t
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(min_w, 26)
	b.add_theme_font_size_override("font_size", 12)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.12, 0.16, 0.25, 0.95)
	normal.set_corner_radius_all(5)
	normal.set_border_width_all(1)
	normal.border_color = Color(0.3, 0.42, 0.6, 0.6)
	normal.content_margin_left = 7
	normal.content_margin_right = 7
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.17, 0.24, 0.37, 1.0)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.0, 0.45, 0.55, 1.0)
	pressed.border_color = ACCENT
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("hover_pressed", pressed)
	return b


func _bar(col: Color) -> ProgressBar:
	var b := ProgressBar.new()
	b.show_percentage = false
	b.max_value = 100.0
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.45)
	bg.set_corner_radius_all(3)
	var fill := StyleBoxFlat.new()
	fill.bg_color = col
	fill.set_corner_radius_all(3)
	b.add_theme_stylebox_override("background", bg)
	b.add_theme_stylebox_override("fill", fill)
	return b


static func _esc(s: String) -> String:
	return s.replace("[", "[lb]")


static func _fmt(n: int) -> String:
	var neg := n < 0
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return ("-" if neg else "") + s + out
