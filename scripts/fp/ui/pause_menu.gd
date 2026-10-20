extends Control
## Pause menu (slice B), shown on pause_changed(true) over a frosted blur of the paused world:
## Resume, Save, Load, New city (press twice), Settings, Quit to orbit, Quit (saves first), a
## legend of the HUD icons, and tabbed
## settings (Camera, Controls, Display, Audio) written through mode.apply_settings(). FpMode owns
## the &"pause" modal; B never pushes or pops it. Keyboard navigable; Esc leaves the settings
## page, else resumes, and is consumed.

const D := preload("res://scripts/sim/sim_defs.gd")
const S := preload("res://scripts/fp/ui/hud_style.gd")
const HudIcon := preload("res://scripts/fp/ui/hud_icon.gd")
const BLUR := preload("res://ui/fp/blur.gdshader")

const FADE := 0.16
const LEFT_X := 96.0
const PANEL_W := 600.0
const ROW_H := 44.0
const BASE_SENS := 0.0022
const NEW_CITY := "New city"
const NEW_CITY_CONFIRM := "Press again to start over"
## Settings rows per tab: [key, label, kind, args]. kind "slider": [min, max, step, unit];
## "choice": [[label, value], ...].
const TABS := {
	"Camera": [
		["camera_mode", "View", "choice", [["Third person", "third"], ["First person", "first"]]],
		["tps_distance_m", "Camera distance", "slider", [1.6, 5.0, 0.1, "m"]],
		["shoulder", "Shoulder", "choice", [["Right", 1], ["Left", -1]]],
		["auto_shoulder", "Auto shoulder swap", "choice", [["Off", false], ["On", true]]],
		["tps_fov", "Third-person field of view", "slider", [50.0, 75.0, 1.0, "°"]],
		["hero", "Hero", "choice", [["Male", "m"], ["Female", "f"]]],
	],
	"Controls": [
		["mouse_sensitivity", "Mouse sensitivity", "slider", [0.3, 2.5, 0.05, "×"]],
		["invert_y", "Invert look", "choice", [["Off", false], ["On", true]]],
	],
	"Display": [
		["quality", "Quality", "choice", [["Low", "low"], ["Medium", "medium"], ["High", "high"]]],
		["fov", "First-person field of view", "slider", [60.0, 90.0, 1.0, "°"]],
		["head_bob", "Head bob", "choice", [["Off", false], ["On", true]]],
		["show_hud", "Show HUD", "choice", [["Off", false], ["On", true]]],
	],
	"Audio": [
		["music_volume_db", "Music", "slider", [0.0, 100.0, 1.0, "%"]],
		["sfx_volume_db", "Effects", "slider", [0.0, 100.0, 1.0, "%"]],
	],
}
const LEGEND := [
	["person", "Population", "People living in the city"],
	["face", "Mood", "How residents feel, 0 to 10 (tile happiness when residents are off)"],
	["coin", "Treasury", "The city's funds across every district"],
	["bolt", "Power", "Grid load: amber near capacity, red when buildings are cut off"],
	["drop", "Water", "Supply load, coloured like power"],
	["clock", "Time", "Day, time of day and game speed"],
	["alert", "Incidents", "How many are active, and the newest"],
]
const KEYS := [
	["M", "Map"], ["Tab", "City overview"], ["V", "Camera view"], ["Q", "Shoulder"], ["E", "Interact"], ["F", "Get in / out of a car"], ["B", "Build phone"],
	["Enter", "Chat"], ["J", "AI activity"], ["G", "Route to AI decision"],
	["[ ]", "Game speed"], ["T", "Skip to morning"], ["P", "Photo mode"], ["F1", "Hide HUD"],
	["F5", "Quick save"], ["F9", "Quick load"],
]

var ctx: FpContext
var hud: Node
## Every settings control by key: HSlider, or Array[Button] for a choice.
var controls: Dictionary = {}
var _backdrop: ColorRect
var _left: VBoxContainer
var _subtitle: Label
var _buttons: Dictionary = {}
var _legend: Control
var _settings: PanelContainer
var _tabs: Dictionary = {}
var _tab_buttons: Dictionary = {}
var _values: Dictionary = {}
var _dragging: String = ""
var _age: float = 0.0
var _grabber: ImageTexture


func setup(p_ctx: FpContext, p_hud: Node) -> void:
	ctx = p_ctx
	hud = p_hud
	name = "PauseMenu"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_grabber = _circle_texture(16, Color.WHITE)
	_backdrop = ColorRect.new()
	_backdrop.name = "Backdrop"
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = BLUR
	mat.set_shader_parameter("tint", Color(0.03, 0.04, 0.06, 0.5))
	mat.set_shader_parameter("side_shade", 0.32)
	_backdrop.material = mat
	add_child(_backdrop)
	_build_left()
	_build_legend()
	_build_settings()
	if ctx.bus != null:
		ctx.bus.pause_changed.connect(_on_pause_changed)


## True while the menu shows.
func is_open() -> bool:
	return visible


## True while the settings page shows.
func settings_open() -> bool:
	return _settings.visible


## The menu button with this text ("Resume", "Save", ...), or null.
func button(text: String) -> Button:
	return _buttons.get(text, null)


## Opens the settings page on a tab ("Camera", "Controls", "Display", "Audio").
func open_settings(tab: String = "Camera") -> void:
	_sync()
	_settings.visible = true
	_legend.visible = false
	_show_tab(tab)


## Back from the settings page to the menu list.
func close_settings() -> void:
	_settings.visible = false
	_legend.visible = true
	_dragging = ""
	var b := button("Settings")
	if b != null and b.is_inside_tree():
		b.grab_focus()


func _on_pause_changed(p: bool) -> void:
	if p:
		_open()
	else:
		visible = false
		_settings.visible = false
		_legend.visible = true


func _open() -> void:
	_sync()
	_refresh_subtitle()
	_settings.visible = false
	_legend.visible = true
	_buttons["Save"].disabled = ctx.main == null
	_buttons["Load"].disabled = ctx.main == null
	_buttons[NEW_CITY].disabled = ctx.main == null
	_buttons[NEW_CITY].text = NEW_CITY
	_buttons["Quit to orbit"].disabled = ctx.main == null
	visible = true
	_age = 0.0
	modulate.a = 0.0
	var r: Button = _buttons["Resume"]
	if r.is_inside_tree():
		r.grab_focus.call_deferred()


func _process(delta: float) -> void:
	if not visible:
		return
	if _age < FADE:
		_age = minf(FADE, _age + delta)
		var k := _age / FADE
		modulate.a = k
		_left.position.x = LEFT_X - 18.0 * (1.0 - k) * (1.0 - k)
		var m := _backdrop.material as ShaderMaterial
		m.set_shader_parameter("fade", k)


func _unhandled_input(event: InputEvent) -> void:
	if not visible or event.is_echo():
		return
	if event.is_action_pressed("pause_menu"):
		if _settings.visible:
			close_settings()
		elif ctx.mode != null:
			ctx.mode.set_paused(false)
		get_viewport().set_input_as_handled()


func _on_button(text: String) -> void:
	match text:
		"Resume":
			if ctx.mode != null:
				ctx.mode.set_paused(false)
		"Save":
			if ctx.main != null and ctx.main.has_method("save_game"):
				ctx.main.call("save_game")
		"Load":
			if ctx.main != null and ctx.main.has_method("load_game"):
				var ok: Variant = ctx.main.call("load_game")
				if typeof(ok) == TYPE_BOOL and ok and ctx.mode != null:
					ctx.mode.set_paused(false)
		NEW_CITY:
			_on_new_city()
		"Settings":
			if _settings.visible:
				close_settings()
			else:
				open_settings("Camera")
		"Quit to orbit":
			# exit_fp() frees this HUD; it cannot run inside the button's own pressed emission.
			if ctx.main != null:
				ctx.main.call_deferred("exit_fp")
		"Quit":
			if ctx.main != null and ctx.main.has_method("quit_game"):
				ctx.main.call("quit_game")
			else:
				get_tree().quit()


## The first press asks again; the second starts a new city and resumes.
func _on_new_city() -> void:
	var b: Button = _buttons[NEW_CITY]
	if b.text != NEW_CITY_CONFIRM:
		b.text = NEW_CITY_CONFIRM
	elif ctx.main != null and ctx.main.has_method("new_game"):
		b.text = NEW_CITY
		# new_game() rebuilds the world; not from inside the button's own pressed emission.
		ctx.main.call_deferred("new_game")
		if ctx.mode != null:
			ctx.mode.set_paused(false)


func _build_left() -> void:
	_left = VBoxContainer.new()
	_left.name = "Menu"
	_left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_left.anchor_top = 0.5
	_left.anchor_bottom = 0.5
	_left.position = Vector2(LEFT_X, 0)
	_left.offset_top = -250
	_left.offset_bottom = 250
	_left.custom_minimum_size = Vector2(320, 0)
	_left.add_theme_constant_override("separation", 4)
	add_child(_left)
	var title := S.label("Paused", 54, S.WHITE, S.title(), 0)
	title.name = "Title"
	title.add_theme_constant_override("shadow_offset_y", 2)
	_left.add_child(title)
	_subtitle = S.plain("", 15, S.TEXT_DIM, S.font())
	_subtitle.name = "Subtitle"
	_left.add_child(_subtitle)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 26)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_left.add_child(gap)
	for t: String in ["Resume", "Save", "Load", NEW_CITY, "Settings", "Quit to orbit", "Quit"]:
		if t == "Quit to orbit":
			var sep := Control.new()
			sep.custom_minimum_size = Vector2(0, 14)
			sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_left.add_child(sep)
		var b := S.menu_button(t, 20)
		b.name = t.replace(" ", "")
		b.custom_minimum_size = Vector2(300, 0)
		b.pressed.connect(_on_button.bind(t))
		_left.add_child(b)
		_buttons[t] = b
	var gap2 := Control.new()
	gap2.custom_minimum_size = Vector2(0, 30)
	gap2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_left.add_child(gap2)
	var hints := HBoxContainer.new()
	hints.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hints.add_theme_constant_override("separation", 8)
	_left.add_child(hints)
	for pair: Array in [["Esc", "Resume"], ["Enter", "Select"]]:
		var k := S.key_cap(str(pair[0]), 12)
		k.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		hints.add_child(k)
		hints.add_child(S.plain(str(pair[1]), 14, S.TEXT_DIM, S.font()))
		var sp := Control.new()
		sp.custom_minimum_size = Vector2(10, 0)
		sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hints.add_child(sp)


func _build_legend() -> void:
	var p := S.panel(Color(0.055, 0.07, 0.11, 0.55), S.RADIUS_PANEL, 22, 18)
	p.name = "Legend"
	_place_right(p, 560.0)
	add_child(p)
	_legend = p
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 10)
	p.add_child(v)
	v.add_child(_caps("HUD AT A GLANCE"))
	for row: Array in LEGEND:
		var h := HBoxContainer.new()
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_theme_constant_override("separation", 14)
		var ic := HudIcon.new(str(row[0]), S.TEXT, 20.0)
		ic.shadow = false
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(ic)
		var t := VBoxContainer.new()
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		t.add_theme_constant_override("separation", 0)
		t.add_child(S.plain(str(row[1]), 16, S.TEXT, S.bold()))
		var d := S.plain(str(row[2]), 14, S.TEXT_DIM, S.font())
		t.add_child(d)
		h.add_child(t)
		v.add_child(h)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 6)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(gap)
	v.add_child(_caps("KEYS"))
	var grid := GridContainer.new()
	grid.columns = 4
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 8)
	v.add_child(grid)
	for pair: Array in KEYS:
		var k := S.key_cap(str(pair[0]), 12)
		k.size_flags_horizontal = Control.SIZE_SHRINK_END
		k.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		grid.add_child(k)
		grid.add_child(S.plain(str(pair[1]), 14, S.TEXT_DIM, S.font()))


func _build_settings() -> void:
	var p := S.panel(S.PANEL_BG, S.RADIUS_PANEL, 24, 20)
	p.name = "Settings"
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	_place_right(p, PANEL_W)
	add_child(p)
	_settings = p
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 14)
	p.add_child(v)
	var head := HBoxContainer.new()
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_theme_constant_override("separation", 6)
	v.add_child(head)
	var title := S.plain("Settings", 24, S.WHITE, S.bold())
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var group := ButtonGroup.new()
	for tab: String in TABS:
		var b := S.pill_button(tab, 14)
		b.toggle_mode = true
		b.button_group = group
		b.pressed.connect(_show_tab.bind(tab))
		head.add_child(b)
		_tab_buttons[tab] = b
	var line := ColorRect.new()
	line.color = S.PANEL_LINE
	line.custom_minimum_size = Vector2(0, 1)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(line)
	for tab: String in TABS:
		var page := VBoxContainer.new()
		page.name = tab
		page.mouse_filter = Control.MOUSE_FILTER_IGNORE
		page.add_theme_constant_override("separation", 2)
		page.visible = false
		v.add_child(page)
		_tabs[tab] = page
		for row: Array in TABS[tab]:
			page.add_child(_row(row))
	var foot := HBoxContainer.new()
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	foot.add_theme_constant_override("separation", 8)
	v.add_child(foot)
	var k := S.key_cap("Esc", 12)
	k.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	foot.add_child(k)
	foot.add_child(S.plain("Back", 14, S.TEXT_DIM, S.font()))
	_settings.visible = false


func _row(row: Array) -> Control:
	var key := str(row[0])
	var h := HBoxContainer.new()
	h.name = key
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.custom_minimum_size = Vector2(0, ROW_H)
	h.add_theme_constant_override("separation", 12)
	var l := S.plain(str(row[1]), 16, S.TEXT, S.font())
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(l)
	var args: Array = row[3]
	if str(row[2]) == "slider":
		var s := HSlider.new()
		s.name = "Slider"
		s.min_value = float(args[0])
		s.max_value = float(args[1])
		s.step = float(args[2])
		s.custom_minimum_size = Vector2(220, 24)
		s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		s.focus_mode = Control.FOCUS_ALL
		s.mouse_filter = Control.MOUSE_FILTER_STOP
		_style_slider(s)
		h.add_child(s)
		var val := S.plain("", 15, S.TEXT, S.bold())
		val.custom_minimum_size = Vector2(60, 0)
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		h.add_child(val)
		_values[key] = val
		s.value_changed.connect(_on_slider.bind(key))
		s.drag_started.connect(func() -> void: _dragging = key)
		s.drag_ended.connect(func(_changed: bool) -> void: _on_drag_end(key))
		controls[key] = s
	else:
		var seg := HBoxContainer.new()
		seg.name = "Choice"
		seg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		seg.add_theme_constant_override("separation", 4)
		seg.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var group := ButtonGroup.new()
		var buttons: Array[Button] = []
		for opt: Array in args:
			var b := S.pill_button(str(opt[0]), 14)
			b.toggle_mode = true
			b.button_group = group
			b.custom_minimum_size = Vector2(76, 30)
			b.set_meta("value", opt[1])
			b.pressed.connect(_on_choice.bind(key, opt[1]))
			seg.add_child(b)
			buttons.append(b)
		h.add_child(seg)
		controls[key] = buttons
	return h


func _show_tab(tab: String) -> void:
	for t: String in _tabs:
		(_tabs[t] as Control).visible = t == tab
		(_tab_buttons[t] as Button).set_pressed_no_signal(t == tab)
	var page: Control = _tabs[tab]
	var first: Control = _first_focusable(page)
	if first != null and first.is_inside_tree():
		first.grab_focus.call_deferred()


func _first_focusable(n: Node) -> Control:
	for c in n.get_children():
		if c is Control and (c as Control).focus_mode == Control.FOCUS_ALL and (c as Control).visible:
			return c
		var r := _first_focusable(c)
		if r != null:
			return r
	return null


## Reads every control from ctx.settings without emitting.
func _sync() -> void:
	var st := ctx.settings
	for key: String in controls:
		var c: Variant = controls[key]
		if c is HSlider:
			var s: HSlider = c
			s.set_value_no_signal(_to_slider(key, st.get(key, FpMode.DEFAULT_SETTINGS.get(key, 0.0))))
			_show_value(key, s.value)
		else:
			for b: Button in c:
				b.set_pressed_no_signal(_same(b.get_meta("value"), st.get(key, FpMode.DEFAULT_SETTINGS.get(key))))


func _on_slider(v: float, key: String) -> void:
	_show_value(key, v)
	_apply(key, _from_slider(key, v), _dragging != key)


func _on_drag_end(key: String) -> void:
	_dragging = ""
	var s: HSlider = controls[key]
	_apply(key, _from_slider(key, s.value), true)


func _on_choice(key: String, value: Variant) -> void:
	_apply(key, value, true)


func _apply(key: String, value: Variant, persist: bool) -> void:
	if ctx.mode != null:
		ctx.mode.apply_settings({key: value}, persist)


func _to_slider(key: String, v: Variant) -> float:
	match key:
		"mouse_sensitivity":
			return float(v) / BASE_SENS
		"music_volume_db", "sfx_volume_db":
			return clampf(db_to_linear(float(v)), 0.0, 1.0) * 100.0
	return float(v)


func _from_slider(key: String, v: float) -> Variant:
	match key:
		"mouse_sensitivity":
			return snappedf(v * BASE_SENS, 0.00001)
		"music_volume_db", "sfx_volume_db":
			return -80.0 if v <= 0.0 else snappedf(linear_to_db(v / 100.0), 0.1)
	return v


func _show_value(key: String, v: float) -> void:
	var l: Label = _values.get(key, null)
	if l == null:
		return
	match key:
		"mouse_sensitivity":
			l.text = "%.2f×" % v
		"tps_distance_m":
			l.text = "%.1f m" % v
		"music_volume_db", "sfx_volume_db":
			l.text = "%d%%" % roundi(v)
		_:
			l.text = "%d°" % roundi(v)


func _refresh_subtitle() -> void:
	if ctx.sim == null:
		_subtitle.text = ""
		return
	var parts := PackedStringArray(["Day %d" % ctx.sim.day])
	if ctx.sky != null:
		parts.append(ctx.sky.clock_text())
	var t := ctx.player_tile() if ctx.player != null else -1
	if t >= 0 and ctx.directory != null:
		parts.append(ctx.directory.district_name(t))
	_subtitle.text = D.debrand(" · ".join(parts))


func _place_right(p: Control, w: float) -> void:
	p.anchor_left = 1.0
	p.anchor_right = 1.0
	p.anchor_top = 0.5
	p.anchor_bottom = 0.5
	p.offset_left = -w - 96.0
	p.offset_right = -96.0
	p.grow_vertical = Control.GROW_DIRECTION_BOTH
	p.offset_top = -10
	p.offset_bottom = 10


func _caps(t: String) -> Label:
	var l := S.plain(t, 12, S.TEXT_FAINT, S.caps())
	return l


func _style_slider(s: HSlider) -> void:
	var track := S.box(Color(1, 1, 1, 0.14), 3, 0, 2)
	var fill := S.box(Color(1, 1, 1, 0.85), 3, 0, 2)
	var fill_hi := S.box(S.ACCENT, 3, 0, 2)
	s.add_theme_stylebox_override("slider", track)
	s.add_theme_stylebox_override("grabber_area", fill)
	s.add_theme_stylebox_override("grabber_area_highlight", fill_hi)
	s.add_theme_icon_override("grabber", _grabber)
	s.add_theme_icon_override("grabber_highlight", _grabber)
	var focus := S.box(Color(0, 0, 0, 0), S.RADIUS, 0, 0, Color(1, 1, 1, 0.5), 1)
	s.add_theme_stylebox_override("focus", focus)


static func _same(a: Variant, b: Variant) -> bool:
	if typeof(a) in [TYPE_INT, TYPE_FLOAT] and typeof(b) in [TYPE_INT, TYPE_FLOAT]:
		return is_equal_approx(float(a), float(b))
	return typeof(a) == typeof(b) and a == b


static func _circle_texture(px: int, col: Color) -> ImageTexture:
	var img := Image.create_empty(px, px, false, Image.FORMAT_RGBA8)
	var c := (px - 1) * 0.5
	for y in range(px):
		for x in range(px):
			var d := Vector2(x - c, y - c).length()
			var a := clampf(c - d + 0.5, 0.0, 1.0)
			var rim := clampf(c - 1.5 - d + 0.5, 0.0, 1.0)
			img.set_pixel(x, y, Color(col.r, col.g, col.b, a).lerp(Color(0.9, 0.95, 1.0, a), 1.0 - rim))
	return ImageTexture.create_from_image(img)
