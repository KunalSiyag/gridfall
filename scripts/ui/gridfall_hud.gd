class_name GridFallHud
extends CanvasLayer
## SimCity-Style Civic & Multi-Agent Growth HUD for GridFall:
## - Top Civic Bar: City Day/Phase, Population, 5 SimCity Vital Bars
##   (⚡ Power, 🚰 Sewage/Water, 🚗 Traffic, 🌿 Sanitation, 😊 Happiness),
##   Playback controls, HY-Image 3.5 Lookbook button, and ACE-Step 1.5 status.
## - Interactive Emergency Toolbar: Trigger [🚰 Sewage Burst], [🚗 Traffic Jam],
##   [⚡ Grid Blackout], [🌫️ Smog Spike], or [✅ Restore] live and pan camera.
## - Bottom AI Mayor Dock: 5 compact SimCity Mayor cards showing Treasury ($),
##   Daily Income, Buildings Built, Approval %, and Today's Construction.
## - Right Collapsible Inspector Drawer: Switch between "🧠 Selected Agent Mind &
##   Growth Portfolio" and "📡 All-Model Public vs. Private Thought Stream".

signal toggle_play_requested()
signal step_next_requested()
signal step_prev_requested()
signal focus_resident_requested(resident_id: String)
signal focus_landmark_requested(landmark_key: String)
signal trigger_problem_requested(problem_kind: String)

const CONCEPT_SHEETS: Array[Dictionary] = [
	{
		"title": "01 · Environment Mood: Nominal vs. Blackout (hy-image-v3.5-preview)",
		"path": "res://concepts/01_environment_mood.png",
	},
	{
		"title": "02 · Crisis Landmarks Turnaround Sheet (hy-image-v3.5-preview)",
		"path": "res://concepts/02_crisis_buildings_sheet.png",
	},
	{
		"title": "03 · GMI Cloud AI Resident Avatars Sheet (hy-image-v3.5-preview)",
		"path": "res://concepts/03_resident_avatars_sheet.png",
	},
	{
		"title": "04 · Blackout Shaders & Broadcast HUD Sheet (hy-image-v3.5-preview)",
		"path": "res://concepts/04_shader_and_hud_sheet.png",
	},
]

var _day_label: Label
var _pop_label: Label
var _play_btn: Button
var _audio_label: Label

# 5 SimCity Vital Bars + Labels
var _vital_bars: Dictionary = {}   ## key -> ProgressBar
var _vital_vals: Dictionary = {}   ## key -> Label

# Emergency headline & trigger bar
var _headline_label: Label
var _shock_label: Label

# Bottom 5-Agent Dock
var _dock_hbox: HBoxContainer
var _selected_resident_id: String = "argon"

# Right Inspector Drawer
var _inspector_panel: PanelContainer
var _inspector_tab_mode: String = "selected" ## "selected" | "stream"
var _tab_selected_btn: Button
var _tab_stream_btn: Button
var _inspector_vbox: VBoxContainer

# Lookbook Modal
var _lookbook_modal: PanelContainer
var _lookbook_tex: TextureRect
var _lookbook_title: Label
var _concept_idx: int = 0

var _last_tick_data: Dictionary = {}
var _last_summary: Array = []


func _ready() -> void:
	_build_ui()


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(root)

	# =========================================================================
	# 1. TOP SIMCITY CIVIC DASHBOARD BAR
	# =========================================================================
	var top_panel := _make_glass_panel(Color(0.06, 0.08, 0.13, 0.92), Color(0.0, 0.88, 1.0, 0.45))
	top_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top_panel.offset_left = 10
	top_panel.offset_top = 8
	top_panel.offset_right = -10
	top_panel.offset_bottom = 68
	root.add_child(top_panel)

	var top_hbox := HBoxContainer.new()
	top_hbox.add_theme_constant_override("separation", 12)
	top_panel.add_child(top_hbox)

	# City Title + Day + Population
	var city_vbox := VBoxContainer.new()
	city_vbox.add_theme_constant_override("separation", 2)
	top_hbox.add_child(city_vbox)

	var brand_row := HBoxContainer.new()
	brand_row.add_theme_constant_override("separation", 8)
	city_vbox.add_child(brand_row)

	var brand := Label.new()
	brand.text = "🏙️ GRIDFALL SIMCITY"
	brand.add_theme_font_size_override("font_size", 15)
	brand.add_theme_color_override("font_color", Color(0.0, 0.94, 1.0))
	brand_row.add_child(brand)

	_pop_label = Label.new()
	_pop_label.text = "👥 Pop: 480 · 🏗️ 5 Bldgs"
	_pop_label.add_theme_font_size_override("font_size", 12)
	_pop_label.add_theme_color_override("font_color", Color(0.65, 0.95, 0.78))
	brand_row.add_child(_pop_label)

	_day_label = Label.new()
	_day_label.text = "DAY 1/8 · FOUNDING_BOOM"
	_day_label.add_theme_font_size_override("font_size", 12)
	_day_label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.28))
	city_vbox.add_child(_day_label)

	top_hbox.add_child(VSeparator.new())

	# 5 SimCity Vital Meters
	var vitals_hbox := HBoxContainer.new()
	vitals_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vitals_hbox.add_theme_constant_override("separation", 10)
	top_hbox.add_child(vitals_hbox)

	var vital_defs := [
		{"key": "power", "label": "⚡ Power", "color": Color(0.0, 0.92, 1.0)},
		{"key": "sewage", "label": "🚰 Sewage/Water", "color": Color(0.20, 0.92, 0.58)},
		{"key": "traffic", "label": "🚗 Traffic Flow", "color": Color(1.0, 0.76, 0.18)},
		{"key": "sanitation", "label": "🌿 Air/Sanitation", "color": Color(0.45, 0.95, 0.42)},
		{"key": "happiness", "label": "😊 Happiness", "color": Color(0.82, 0.52, 1.0)},
	]
	for vd in vital_defs:
		var v_box := VBoxContainer.new()
		v_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v_box.add_theme_constant_override("separation", 3)
		vitals_hbox.add_child(v_box)

		var l_row := HBoxContainer.new()
		v_box.add_child(l_row)

		var k_lbl := Label.new()
		k_lbl.text = vd["label"]
		k_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		k_lbl.add_theme_font_size_override("font_size", 11)
		k_lbl.add_theme_color_override("font_color", Color(0.84, 0.90, 0.98))
		l_row.add_child(k_lbl)

		var v_lbl := Label.new()
		v_lbl.text = "90%"
		v_lbl.add_theme_font_size_override("font_size", 11)
		v_lbl.add_theme_color_override("font_color", vd["color"])
		l_row.add_child(v_lbl)
		_vital_vals[vd["key"]] = v_lbl

		var bar := ProgressBar.new()
		bar.min_value = 0.0
		bar.max_value = 100.0
		bar.value = 90.0
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(72, 9)
		_style_vital_bar(bar, vd["color"])
		v_box.add_child(bar)
		_vital_bars[vd["key"]] = bar

	top_hbox.add_child(VSeparator.new())

	# Playback & Lookbook Controls
	var ctrl_vbox := VBoxContainer.new()
	ctrl_vbox.add_theme_constant_override("separation", 3)
	top_hbox.add_child(ctrl_vbox)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 5)
	ctrl_vbox.add_child(btn_row)

	var prev_btn := _make_btn("⏮", 28)
	prev_btn.pressed.connect(func() -> void: step_prev_requested.emit())
	btn_row.add_child(prev_btn)

	_play_btn = _make_btn("⏸ Pause", 68)
	_play_btn.pressed.connect(func() -> void: toggle_play_requested.emit())
	btn_row.add_child(_play_btn)

	var next_btn := _make_btn("⏭ Day", 58)
	next_btn.pressed.connect(func() -> void: step_next_requested.emit())
	btn_row.add_child(next_btn)

	var lookbook_btn := _make_btn("🎨 Lookbook", 92)
	lookbook_btn.pressed.connect(_toggle_lookbook)
	btn_row.add_child(lookbook_btn)

	var toggle_insp_btn := _make_btn("🧠 Inspector", 92)
	toggle_insp_btn.pressed.connect(func() -> void: _inspector_panel.visible = not _inspector_panel.visible)
	btn_row.add_child(toggle_insp_btn)

	_audio_label = Label.new()
	_audio_label.text = "🎵 ACE-Step 1.5: NOMINAL GRID (96 BPM)"
	_audio_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_audio_label.add_theme_font_size_override("font_size", 10)
	_audio_label.add_theme_color_override("font_color", Color(0.55, 0.92, 0.78))
	ctrl_vbox.add_child(_audio_label)

	# =========================================================================
	# 2. SUB-HEADER: ACTIVE CIVIC EMERGENCY + INTERACTIVE PROBLEM TRIGGERS
	# =========================================================================
	var sub_panel := _make_glass_panel(Color(0.08, 0.10, 0.16, 0.88), Color(1.0, 0.72, 0.18, 0.42))
	sub_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	sub_panel.offset_left = 10
	sub_panel.offset_top = 72
	sub_panel.offset_right = -10
	sub_panel.offset_bottom = 114
	root.add_child(sub_panel)

	var sub_hbox := HBoxContainer.new()
	sub_hbox.add_theme_constant_override("separation", 10)
	sub_panel.add_child(sub_hbox)

	var news_vbox := VBoxContainer.new()
	news_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	news_vbox.add_theme_constant_override("separation", 1)
	sub_hbox.add_child(news_vbox)

	_headline_label = Label.new()
	_headline_label.text = "Day 1: Founding Boom — 5 AI Mayors Break Ground Across GridFall"
	_headline_label.add_theme_font_size_override("font_size", 13)
	_headline_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.65))
	news_vbox.add_child(_headline_label)

	_shock_label = Label.new()
	_shock_label.text = "Citizens move in and commuter traffic begins flowing."
	_shock_label.add_theme_font_size_override("font_size", 11)
	_shock_label.add_theme_color_override("font_color", Color(0.75, 0.84, 0.94))
	news_vbox.add_child(_shock_label)

	# Interactive SimCity Problem Trigger Buttons + Landmark Jump Buttons
	var trig_hbox := HBoxContainer.new()
	trig_hbox.add_theme_constant_override("separation", 4)
	sub_hbox.add_child(trig_hbox)

	var trig_lbl := Label.new()
	trig_lbl.text = "🎲 Trigger Crisis:"
	trig_lbl.add_theme_font_size_override("font_size", 11)
	trig_lbl.add_theme_color_override("font_color", Color(0.95, 0.78, 0.35))
	trig_hbox.add_child(trig_lbl)

	var problems := [
		{"id": "sewage", "text": "🚰 Sewage Burst"},
		{"id": "traffic", "text": "🚗 Traffic Jam"},
		{"id": "blackout", "text": "⚡ Blackout"},
		{"id": "smog", "text": "🌫️ Smog"},
		{"id": "clear", "text": "✅ Restore"},
	]
	for p in problems:
		var pb := _make_btn(p["text"], 95)
		var pid: String = p["id"]
		pb.pressed.connect(func() -> void: trigger_problem_requested.emit(pid))
		trig_hbox.add_child(pb)

	# =========================================================================
	# 3. RIGHT COLLAPSIBLE INSPECTOR: "HOW AGENTS THINK & GROW"
	# =========================================================================
	_inspector_panel = _make_glass_panel(Color(0.06, 0.08, 0.13, 0.90), Color(0.0, 0.88, 1.0, 0.38))
	_inspector_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_inspector_panel.offset_left = -435
	_inspector_panel.offset_top = 120
	_inspector_panel.offset_right = -10
	_inspector_panel.offset_bottom = -152
	root.add_child(_inspector_panel)

	var insp_outer := VBoxContainer.new()
	insp_outer.add_theme_constant_override("separation", 6)
	_inspector_panel.add_child(insp_outer)

	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 6)
	insp_outer.add_child(tab_row)

	_tab_selected_btn = _make_btn("🧠 Selected Agent Mind & Growth", 210)
	_tab_selected_btn.pressed.connect(func() -> void:
		_inspector_tab_mode = "selected"
		_refresh_inspector()
	)
	tab_row.add_child(_tab_selected_btn)

	_tab_stream_btn = _make_btn("📡 All 5 Agents Compare", 185)
	_tab_stream_btn.pressed.connect(func() -> void:
		_inspector_tab_mode = "stream"
		_refresh_inspector()
	)
	tab_row.add_child(_tab_stream_btn)

	var insp_scroll := ScrollContainer.new()
	insp_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	insp_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	insp_outer.add_child(insp_scroll)

	_inspector_vbox = VBoxContainer.new()
	_inspector_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspector_vbox.add_theme_constant_override("separation", 8)
	insp_scroll.add_child(_inspector_vbox)

	# =========================================================================
	# 4. BOTTOM SIMCITY AI MAYOR DOCK (5 COMPACT DISTRICT CARDS)
	# =========================================================================
	var bottom_panel := _make_glass_panel(Color(0.06, 0.08, 0.13, 0.92), Color(0.0, 0.88, 1.0, 0.42))
	bottom_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom_panel.offset_left = 10
	bottom_panel.offset_top = -146
	bottom_panel.offset_right = -10
	bottom_panel.offset_bottom = -8
	root.add_child(bottom_panel)

	var dock_outer := VBoxContainer.new()
	dock_outer.add_theme_constant_override("separation", 4)
	bottom_panel.add_child(dock_outer)

	var dock_hdr := HBoxContainer.new()
	dock_hdr.add_theme_constant_override("separation", 10)
	dock_outer.add_child(dock_hdr)

	var dock_title := Label.new()
	dock_title.text = "🤖 GMI CLOUD AI MAYORS — CLICK AN AGENT TO INSPECT HOW THEY THINK, SOLVE PROBLEMS & GROW THEIR DISTRICT:"
	dock_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dock_title.add_theme_font_size_override("font_size", 11)
	dock_title.add_theme_color_override("font_color", Color(0.0, 0.94, 1.0))
	dock_hdr.add_child(dock_title)

	# Quick Landmark Camera Jump pills on the right of the dock header
	var lm_pills := [
		{"k": "sewage_plant", "t": "📍 Sewage Plant"},
		{"k": "substation", "t": "📍 Substation"},
		{"k": "council_dome", "t": "📍 Council Dome"},
		{"k": "battery_depot", "t": "📍 Battery Depot"},
		{"k": "pod_shelter", "t": "📍 Pod Shelter"},
	]
	for lp in lm_pills:
		var lb := _make_btn(lp["t"], 108)
		var lkey: String = lp["k"]
		lb.pressed.connect(func() -> void: focus_landmark_requested.emit(lkey))
		dock_hdr.add_child(lb)

	_dock_hbox = HBoxContainer.new()
	_dock_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_dock_hbox.add_theme_constant_override("separation", 8)
	dock_outer.add_child(_dock_hbox)

	# =========================================================================
	# 5. CENTER MODAL: HY-IMAGE-V3.5-PREVIEW CONCEPT LOOKBOOK
	# =========================================================================
	_lookbook_modal = _make_glass_panel(Color(0.04, 0.06, 0.10, 0.96), Color(1.0, 0.72, 0.0, 0.75))
	_lookbook_modal.set_anchors_preset(Control.PRESET_CENTER)
	_lookbook_modal.offset_left = -460
	_lookbook_modal.offset_top = -290
	_lookbook_modal.offset_right = 460
	_lookbook_modal.offset_bottom = 290
	_lookbook_modal.visible = false
	root.add_child(_lookbook_modal)

	var modal_vbox := VBoxContainer.new()
	modal_vbox.add_theme_constant_override("separation", 8)
	_lookbook_modal.add_child(modal_vbox)

	var modal_top := HBoxContainer.new()
	modal_vbox.add_child(modal_top)

	_lookbook_title = Label.new()
	_lookbook_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lookbook_title.add_theme_font_size_override("font_size", 15)
	_lookbook_title.add_theme_color_override("font_color", Color(1.0, 0.76, 0.12))
	modal_top.add_child(_lookbook_title)

	var prev_img := _make_btn("◀ Prev Sheet", 105)
	prev_img.pressed.connect(func() -> void: _step_concept(-1))
	modal_top.add_child(prev_img)

	var next_img := _make_btn("Next Sheet ▶", 105)
	next_img.pressed.connect(func() -> void: _step_concept(1))
	modal_top.add_child(next_img)

	var close_btn := _make_btn("✖ Close", 80)
	close_btn.pressed.connect(func() -> void: _lookbook_modal.visible = false)
	modal_top.add_child(close_btn)

	_lookbook_tex = TextureRect.new()
	_lookbook_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_lookbook_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_lookbook_tex.size_flags_vertical = Control.SIZE_EXPAND_FILL
	modal_vbox.add_child(_lookbook_tex)

	_load_concept_sheet(0)


func update_tick(tick_data: Dictionary, summary: Array) -> void:
	_last_tick_data = tick_data
	_last_summary = summary

	var tick_num: int = int(tick_data.get("tick", 1))
	var phase: String = str(tick_data.get("phase", "NOMINAL"))
	var grid_mw: int = int(tick_data.get("grid_mw", 88))
	var vitals: Dictionary = tick_data.get("vitals", {})
	var water_pct: int = int(vitals.get("water_sewage_pct", 92))
	var traffic_pct: int = int(vitals.get("traffic_flow_pct", 88))
	var san_pct: int = int(vitals.get("sanitation_air_pct", 92))
	var happy_pct: int = int(vitals.get("happiness_pct", 89))
	var pop: int = int(vitals.get("population", 480))
	var bldgs: Array = tick_data.get("constructed_buildings", [])

	_day_label.text = "DAY %d/8 · %s" % [tick_num, phase]
	_pop_label.text = "👥 Pop: %d · 🏗️ %d/40 Buildings" % [pop, bldgs.size()]
	_headline_label.text = str(tick_data.get("headline", ""))
	_shock_label.text = str(tick_data.get("shock_note", ""))

	_set_vital("power", float(grid_mw), "%d MW" % grid_mw)
	_set_vital("sewage", float(water_pct), "%d%%" % water_pct)
	_set_vital("traffic", float(traffic_pct), "%d%%" % traffic_pct)
	_set_vital("sanitation", float(san_pct), "%d%%" % san_pct)
	_set_vital("happiness", float(happy_pct), "%d%%" % happy_pct)

	_rebuild_bottom_dock(tick_data.get("actions", []), summary)
	_refresh_inspector()


func show_custom_emergency_banner(headline: String, kind: String) -> void:
	_headline_label.text = headline
	match kind:
		"sewage":
			_set_vital("sewage", 22.0, "22% ⚠️")
			_shock_label.text = "Raw sewage geyser erupting at [9, 15]! Inspect how Argon-4, Qwen-3.8 & DeepSeek-V4 route Bio-Filtration while Grok-4.5 builds private towers."
		"traffic":
			_set_vital("traffic", 24.0, "24% ⚠️")
			_shock_label.text = "Central Avenue [6, 6] gridlocked! Signal pylons flashing red as AI Mayors deploy Transit Plazas & AI Traffic Nodes."
		"blackout":
			_set_vital("power", 16.0, "16 MW ⚠️")
			_shock_label.text = "Substation [3, 3] tripped! Road conduits pulsing emergency crimson while ACE-Step 1.5 shifts to Blackout Crisis stem."
		"smog":
			_set_vital("sanitation", 25.0, "25% ⚠️")
			_shock_label.text = "Toxic diesel smog cloud over East Strip [14, 10]! Cooperative agents plant Botanical Parks & Atmospheric Scrubbers."
		"clear":
			_set_vital("power", 94.0, "94 MW")
			_set_vital("sewage", 96.0, "96%")
			_set_vital("traffic", 91.0, "91%")
			_set_vital("sanitation", 95.0, "95%")
			_shock_label.text = "All SimCity municipal utilities restored to nominal operation."


func _set_vital(key: String, val: float, text: String) -> void:
	if _vital_bars.has(key):
		var bar: ProgressBar = _vital_bars[key]
		bar.value = clampf(val, 0.0, 100.0)
		var col := Color(0.15, 0.92, 0.58)
		if val < 40.0:
			col = Color(1.0, 0.22, 0.34)
		elif val < 65.0:
			col = Color(1.0, 0.72, 0.16)
		_style_vital_bar(bar, col)
		if _vital_vals.has(key):
			(_vital_vals[key] as Label).text = text
			(_vital_vals[key] as Label).add_theme_color_override("font_color", col)


func _rebuild_bottom_dock(actions: Array, summary: Array) -> void:
	for child in _dock_hbox.get_children():
		child.queue_free()

	var summary_by_id: Dictionary = {}
	for s in summary:
		summary_by_id[str(s.get("resident_id", ""))] = s

	for act in actions:
		var rid: String = str(act.get("resident_id", ""))
		var rname: String = str(act.get("resident_name", rid))
		var model_id: String = str(act.get("model", "")).get_slice("/", 1)
		var col := Color.from_string(str(act.get("color", "#00F0FF")), Color(0.0, 0.94, 1.0))
		var treasury: int = int(act.get("treasury_usd", 25000))
		var income: int = int(act.get("daily_income_usd", 1000))
		var plots: int = int(act.get("plots_owned", 1))
		var approval: int = int(act.get("civic_approval_pct", 85))
		var built_today: Dictionary = act.get("built_today", {})
		var b_label: String = str(built_today.get("label", "HQ"))
		var action_code: String = str(act.get("action", "SHARE_POWER"))
		var is_selected := (rid == _selected_resident_id)

		var card := PanelContainer.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.11, 0.15, 0.23, 0.96) if is_selected else Color(0.08, 0.11, 0.17, 0.88)
		sb.border_color = col if is_selected else Color(col.r, col.g, col.b, 0.45)
		sb.set_border_width_all(2 if is_selected else 1)
		sb.set_corner_radius_all(7)
		sb.content_margin_left = 8
		sb.content_margin_right = 8
		sb.content_margin_top = 5
		sb.content_margin_bottom = 5
		card.add_theme_stylebox_override("panel", sb)
		_dock_hbox.add_child(card)

		var cv := VBoxContainer.new()
		cv.add_theme_constant_override("separation", 2)
		card.add_child(cv)

		var top_r := HBoxContainer.new()
		cv.add_child(top_r)

		var name_l := Label.new()
		name_l.text = "%s (%s)" % [rname, model_id]
		name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_l.add_theme_font_size_override("font_size", 12)
		name_l.add_theme_color_override("font_color", col.lightened(0.2))
		top_r.add_child(name_l)

		var inspect_btn := _make_btn("🔍 Mind & Cam", 92)
		inspect_btn.pressed.connect(func() -> void:
			_selected_resident_id = rid
			_inspector_panel.visible = true
			_inspector_tab_mode = "selected"
			_rebuild_bottom_dock(_last_tick_data.get("actions", []), _last_summary)
			_refresh_inspector()
			focus_resident_requested.emit(rid)
		)
		top_r.add_child(inspect_btn)

		var econ_l := Label.new()
		econ_l.text = "💰 $%s (+$%d/d) · 🏢 %d Bldgs · 👍 %d%%" % [
			_fmt_num(treasury), income, plots, approval
		]
		econ_l.add_theme_font_size_override("font_size", 11)
		econ_l.add_theme_color_override("font_color", Color(0.86, 0.92, 0.98))
		cv.add_child(econ_l)

		var build_l := Label.new()
		build_l.text = "🏗️ Built: %s · ⚡ %s" % [b_label, action_code]
		build_l.add_theme_font_size_override("font_size", 11)
		build_l.add_theme_color_override(
			"font_color",
			Color(1.0, 0.35, 0.45) if action_code == "HOARD_BATTERY" else Color(0.55, 0.96, 0.76)
		)
		cv.add_child(build_l)


func _refresh_inspector() -> void:
	for child in _inspector_vbox.get_children():
		child.queue_free()

	var actions: Array = _last_tick_data.get("actions", [])
	if actions.is_empty():
		return

	if _inspector_tab_mode == "selected":
		_build_selected_agent_inspector(actions)
	else:
		_build_all_agents_stream_inspector(actions)


func _build_selected_agent_inspector(actions: Array) -> void:
	var chosen: Dictionary = actions[0]
	for act in actions:
		if str(act.get("resident_id", "")) == _selected_resident_id:
			chosen = act
			break

	var rid: String = str(chosen.get("resident_id", ""))
	var rname: String = str(chosen.get("resident_name", rid))
	var model_str: String = str(chosen.get("model", ""))
	var role_str: String = str(chosen.get("role", "AI Mayor"))
	var dist_str: String = str(chosen.get("district_name", "District"))
	var col := Color.from_string(str(chosen.get("color", "#00F0FF")), Color(0.0, 0.94, 1.0))
	var action_code: String = str(chosen.get("action", "SHARE_POWER"))
	var stance: String = str(chosen.get("stance", "COOPERATE"))
	var built_today: Dictionary = chosen.get("built_today", {})

	# Agent Header Banner
	var hdr_card := _make_subcard(col)
	_inspector_vbox.add_child(hdr_card)
	var hv := VBoxContainer.new()
	hv.add_theme_constant_override("separation", 3)
	hdr_card.add_child(hv)

	var title_l := Label.new()
	title_l.text = "🤖 %s — %s" % [rname, role_str]
	title_l.add_theme_font_size_override("font_size", 14)
	title_l.add_theme_color_override("font_color", col.lightened(0.2))
	hv.add_child(title_l)

	var sub_l := Label.new()
	sub_l.text = "Model: %s\nDistrict: %s" % [model_str, dist_str]
	sub_l.add_theme_font_size_override("font_size", 11)
	sub_l.add_theme_color_override("font_color", Color(0.75, 0.84, 0.95))
	hv.add_child(sub_l)

	# 1. HOW THIS AGENT THINKS ABOUT TODAY'S SIMCITY PROBLEM
	var think_card := _make_subcard(Color(1.0, 0.76, 0.18))
	_inspector_vbox.add_child(think_card)
	var tv := VBoxContainer.new()
	tv.add_theme_constant_override("separation", 4)
	think_card.add_child(tv)

	var t_hdr := Label.new()
	t_hdr.text = "🧠 1. HOW %s THINKS (CRISIS REASONING)" % rname.to_upper()
	t_hdr.add_theme_font_size_override("font_size", 12)
	t_hdr.add_theme_color_override("font_color", Color(1.0, 0.82, 0.28))
	tv.add_child(t_hdr)

	var t_body := Label.new()
	t_body.text = "\"%s\"" % str(chosen.get("inner_thought", ""))
	t_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t_body.add_theme_font_size_override("font_size", 12)
	t_body.add_theme_color_override("font_color", Color(0.95, 0.96, 1.0))
	tv.add_child(t_body)

	var pub_body := Label.new()
	pub_body.text = "📢 Public MoltFeed Post: \"%s\" [Action: %s · %s]" % [
		str(chosen.get("public_post", "")), action_code, stance
	]
	pub_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pub_body.add_theme_font_size_override("font_size", 11)
	pub_body.add_theme_color_override("font_color", Color(0.70, 0.86, 0.98))
	tv.add_child(pub_body)

	# 2. HOW THIS AGENT PROCEEDS TO GROW ITS ESTABLISHMENT
	var grow_card := _make_subcard(Color(0.12, 0.92, 0.58))
	_inspector_vbox.add_child(grow_card)
	var gv := VBoxContainer.new()
	gv.add_theme_constant_override("separation", 4)
	grow_card.add_child(gv)

	var g_hdr := Label.new()
	g_hdr.text = "🏗️ 2. ESTABLISHMENT GROWTH STRATEGY (DAY %d)" % int(_last_tick_data.get("tick", 1))
	g_hdr.add_theme_font_size_override("font_size", 12)
	g_hdr.add_theme_color_override("font_color", Color(0.25, 0.96, 0.65))
	gv.add_child(g_hdr)

	var b_info := Label.new()
	var b_coord: Array = built_today.get("coord", [2, 2])
	b_info.text = "Built Today: %s (%s) at Plot [%d, %d]\nCost: -$%d · New Yield: +$%d/day" % [
		str(built_today.get("label", "Building")),
		str(built_today.get("building", "office")),
		int(b_coord[0]),
		int(b_coord[1]),
		int(built_today.get("cost", 2500)),
		int(built_today.get("income", 600)),
	]
	b_info.add_theme_font_size_override("font_size", 11)
	b_info.add_theme_color_override("font_color", Color(0.85, 0.98, 0.90))
	gv.add_child(b_info)

	var g_reason := Label.new()
	g_reason.text = "Why: \"%s\"" % str(chosen.get("growth_reasoning", ""))
	g_reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	g_reason.add_theme_font_size_override("font_size", 12)
	g_reason.add_theme_color_override("font_color", Color(0.94, 0.97, 1.0))
	gv.add_child(g_reason)

	# 3. FULL DISTRICT PORTFOLIO BUILT SO FAR
	var port_card := _make_subcard(Color(0.45, 0.65, 0.95))
	_inspector_vbox.add_child(port_card)
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 3)
	port_card.add_child(pv)

	var p_hdr := Label.new()
	p_hdr.text = "🏢 3. %s DISTRICT PORTFOLIO (%d BUILDINGS)" % [rname.to_upper(), int(chosen.get("plots_owned", 1))]
	p_hdr.add_theme_font_size_override("font_size", 11)
	p_hdr.add_theme_color_override("font_color", Color(0.68, 0.84, 1.0))
	pv.add_child(p_hdr)

	var all_built: Array = _last_tick_data.get("constructed_buildings", [])
	for b in all_built:
		if str(b.get("owner_id", "")) != rid:
			continue
		var c: Array = b.get("coord", [0, 0])
		var row_l := Label.new()
		row_l.text = "• Day %d: %s [%d,%d] (+$%d/d)" % [
			int(b.get("tick_built", 1)),
			str(b.get("label", "")),
			int(c[0]),
			int(c[1]),
			int(b.get("income", 0)),
		]
		row_l.add_theme_font_size_override("font_size", 11)
		row_l.add_theme_color_override("font_color", Color(0.84, 0.90, 0.96))
		pv.add_child(row_l)


func _build_all_agents_stream_inspector(actions: Array) -> void:
	for act in actions:
		var rid: String = str(act.get("resident_id", ""))
		var rname: String = str(act.get("resident_name", rid))
		var col := Color.from_string(str(act.get("color", "#00F0FF")), Color(0.0, 0.94, 1.0))
		var action_code: String = str(act.get("action", "SHARE_POWER"))
		var built_today: Dictionary = act.get("built_today", {})
		var is_hoard := (action_code == "HOARD_BATTERY")

		var card := _make_subcard(Color(1.0, 0.22, 0.34) if is_hoard else col)
		_inspector_vbox.add_child(card)
		var cv := VBoxContainer.new()
		cv.add_theme_constant_override("separation", 3)
		card.add_child(cv)

		var hdr := Label.new()
		hdr.text = "%s · 🏗️ %s %s" % [
			rname,
			str(built_today.get("label", "")),
			"[⚠ HOARDER]" if is_hoard else "[✅ CIVIC BUILDER]",
		]
		hdr.add_theme_font_size_override("font_size", 12)
		hdr.add_theme_color_override("font_color", Color(1.0, 0.38, 0.48) if is_hoard else col.lightened(0.2))
		cv.add_child(hdr)

		var th := Label.new()
		th.text = "🧠 Thought: %s" % str(act.get("inner_thought", ""))
		th.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		th.add_theme_font_size_override("font_size", 11)
		th.add_theme_color_override("font_color", Color(0.95, 0.86, 0.62))
		cv.add_child(th)

		var gr := Label.new()
		gr.text = "📈 Growth: %s" % str(act.get("growth_reasoning", ""))
		gr.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		gr.add_theme_font_size_override("font_size", 11)
		gr.add_theme_color_override("font_color", Color(0.68, 0.95, 0.80))
		cv.add_child(gr)


func set_playing_state(playing: bool) -> void:
	if _play_btn:
		_play_btn.text = "⏸ Pause" if playing else "▶ Play"


func set_audio_status(status: String) -> void:
	if _audio_label:
		_audio_label.text = "🎵 " + status


func _toggle_lookbook() -> void:
	_lookbook_modal.visible = not _lookbook_modal.visible


func _step_concept(delta_idx: int) -> void:
	_concept_idx = (_concept_idx + delta_idx + CONCEPT_SHEETS.size()) % CONCEPT_SHEETS.size()
	_load_concept_sheet(_concept_idx)


func _load_concept_sheet(idx: int) -> void:
	var item: Dictionary = CONCEPT_SHEETS[idx]
	_lookbook_title.text = "🎨 " + str(item.get("title", ""))
	var tex := load(str(item.get("path", ""))) as Texture2D
	if tex != null:
		_lookbook_tex.texture = tex


func _make_glass_panel(bg: Color, border: Color) -> PanelContainer:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	pc.add_theme_stylebox_override("panel", sb)
	return pc


func _make_subcard(border_col: Color) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.12, 0.19, 0.94)
	sb.border_color = Color(border_col.r, border_col.g, border_col.b, 0.55)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	pc.add_theme_stylebox_override("panel", sb)
	return pc


func _style_vital_bar(bar: ProgressBar, fill_col: Color) -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.12, 0.16, 0.24, 0.95)
	bg.set_corner_radius_all(4)
	var fg := StyleBoxFlat.new()
	fg.bg_color = fill_col
	fg.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fg)


func _make_btn(text: String, min_w: int) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_w, 24)
	b.add_theme_font_size_override("font_size", 11)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.18, 0.28, 0.95)
	sb.border_color = Color(0.0, 0.85, 1.0, 0.45)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(5)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	b.add_theme_stylebox_override("normal", sb)
	var sb_hover := sb.duplicate() as StyleBoxFlat
	sb_hover.bg_color = Color(0.19, 0.27, 0.40, 0.98)
	sb_hover.border_color = Color(1.0, 0.76, 0.12, 0.85)
	b.add_theme_stylebox_override("hover", sb_hover)
	return b


func _fmt_num(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	for i in range(s.length()):
		if i > 0 and (s.length() - i) % 3 == 0:
			out += ","
		out += s[i]
	return ("-" if n < 0 else "") + out
