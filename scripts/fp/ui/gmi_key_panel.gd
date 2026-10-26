class_name GmiKeyPanel
extends VBoxContainer
## The "GMI Cloud" page of the pause menu settings (slice B): the opt-in "bring your own key"
## field. Without a key the mayors run on the recorded replay cache and the offline planners;
## pasting one routes every mayor, resident and agent call live, from the player's own browser
## straight to api.gmi-serving.com (CORS allows it), still only through GmiClient.
## The key itself is never logged (Redact owns it) and never written to a Godot file; "Remember
## on this device" (shown in the web build only) saves it in the player's own localStorage, and
## unchecking it erases that copy again. Esc leaves the field, not the settings page.

const S := preload("res://scripts/fp/ui/hud_style.gd")
const WebSupport := preload("res://scripts/ops/web_support.gd")

const ROW_H := 44.0
const FIELD_MAX := 128
## Owner tag for the whole settings page. Slice B's no-branding rule scans texts it owns
## (S.OWNER_META == S.OWNER); this page is the pause menu's one place that names the service it
## configures, like C's chat panel it is left out of that scan (the widgets are re-tagged in
## setup()).
const OWNER := "gmi_key"

var ctx: FpContext
var input: LineEdit
var apply: Button
var forget: Button
var status: Label
var remember: Array[Button] = []
var _remember_group := ButtonGroup.new()


func setup(p_ctx: FpContext) -> void:
	ctx = p_ctx
	name = "GMI"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 2)

	var intro := S.plain(
		(
			"Mayors run on GMI Cloud. Without a key the city runs on recorded days and offline "
			+ "planners. Paste your own GMI API key to play it live: it is sent only to "
			+ "api.gmi-serving.com, from this browser, and never logged."
		),
		14,
		S.TEXT_DIM,
		S.font()
	)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.custom_minimum_size = Vector2(0, 58)
	intro.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	intro.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(intro)

	var field := HBoxContainer.new()
	field.name = "Field"
	field.mouse_filter = Control.MOUSE_FILTER_IGNORE
	field.custom_minimum_size = Vector2(0, ROW_H)
	field.add_theme_constant_override("separation", 12)
	add_child(field)
	var l := S.plain("API key", 16, S.TEXT, S.font())
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	field.add_child(l)
	input = LineEdit.new()
	input.name = "KeyInput"
	input.placeholder_text = "gmi_…  (paste your key)"
	input.secret = true
	input.max_length = FIELD_MAX
	input.mouse_filter = Control.MOUSE_FILTER_STOP
	input.focus_mode = Control.FOCUS_ALL
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input.custom_minimum_size = Vector2(230, 34)
	_style_edit(input)
	input.text_submitted.connect(func(_t: String) -> void: apply_key())
	field.add_child(input)
	apply = S.pill_button("Apply", 14)
	apply.custom_minimum_size = Vector2(88, 32)
	apply.pressed.connect(apply_key)
	field.add_child(apply)

	var tools := HBoxContainer.new()
	tools.name = "Tools"
	tools.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tools.custom_minimum_size = Vector2(0, ROW_H)
	tools.add_theme_constant_override("separation", 12)
	add_child(tools)
	forget = S.pill_button("Forget", 14)
	forget.custom_minimum_size = Vector2(88, 32)
	forget.pressed.connect(forget_key)
	tools.add_child(forget)
	if WebSupport.is_web():
		# Desktop builds have nothing to remember across runs (the boot key comes from the
		# environment or ~/.factory/settings.json), so the switch only exists in the browser.
		var rl := S.plain("Remember on this device", 16, S.TEXT, S.font())
		rl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		tools.add_child(rl)
		var seg := HBoxContainer.new()
		seg.name = "RememberChoice"
		seg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		seg.add_theme_constant_override("separation", 4)
		seg.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		for pair: Array in [["Off", false], ["On", true]]:
			var b := S.pill_button(str(pair[0]), 14)
			b.toggle_mode = true
			b.button_group = _remember_group
			b.custom_minimum_size = Vector2(64, 30)
			b.set_meta("value", pair[1])
			b.pressed.connect(_on_remember.bind(pair[1]))
			seg.add_child(b)
			remember.append(b)
		tools.add_child(seg)

	status = S.plain("", 14, S.TEXT_DIM, S.font())
	status.name = "Status"
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.custom_minimum_size = Vector2(0, 34)
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(status)
	_reown(self)
	refresh()


## Moves the page's widgets out of slice B's ownership ("hud_widgets") so the no-branding scan
## over owned texts leaves the key page alone: naming GMI is the point of this page, as it is of
## C's chat panel.
func _reown(n: Node) -> void:
	if n.get_meta(S.OWNER_META, "") == S.OWNER:
		n.set_meta(S.OWNER_META, OWNER)
	for c in n.get_children():
		_reown(c)


## Re-reads the client state (status line and the Remember switch). No key text is ever shown.
func refresh() -> void:
	var client: GmiClient = ctx.client if ctx != null else null
	if client == null:
		status.text = "GMI client not available."
		return
	if client.has_key():
		status.text = (
			"Key in use. Live mayors: %s."
			% ("on" if client.live_enabled else "off (offline switch or flag)")
		)
	else:
		status.text = "No key: recorded days and offline planners."
	if not remember.is_empty():
		var on := client.has_remembered_key()
		for b: Button in remember:
			b.set_pressed_no_signal(bool(b.get_meta("value")) == on)


## Puts the field's key into the client (empty clears it) and, on the web, honours the Remember
## switch: checked saves it on this device, unchecked erases the saved copy.
func apply_key() -> void:
	var client: GmiClient = ctx.client if ctx != null else null
	if client == null:
		return
	var key := input.text.strip_edges()
	if not WebSupport.is_web():
		client.set_player_key(key)
	else:
		client.set_player_key(key)
		if _remember_on():
			if key.is_empty():
				client.forget_remembered_key()
			else:
				client.remember_player_key(key)
		else:
			client.forget_remembered_key()
	refresh()


## Drops the key from this session and the remembered copy from this device.
func forget_key() -> void:
	var client: GmiClient = ctx.client if ctx != null else null
	if client == null:
		return
	client.forget_remembered_key()
	client.set_player_key("")
	input.text = ""
	refresh()


func _remember_on() -> bool:
	for b: Button in remember:
		if bool(b.get_meta("value")) and b.button_pressed:
			return true
	return false


func _on_remember(on: bool) -> void:
	# Choosing Off right away erases the saved copy; On only saves with the next Apply.
	var client: GmiClient = ctx.client if ctx != null else null
	if client != null and not on:
		client.forget_remembered_key()
		refresh()


## A focused LineEdit swallows Esc before the pause menu's _unhandled_input; leave the field, not
## the settings page, on the first press.
func _input(event: InputEvent) -> void:
	if not visible or input == null or not input.has_focus() or event.is_echo():
		return
	if event.is_action_pressed("pause_menu"):
		input.release_focus()
		get_viewport().set_input_as_handled()


func _style_edit(le: LineEdit) -> void:
	le.add_theme_font_override("font", S.font())
	le.add_theme_font_size_override("font_size", 14)
	le.add_theme_color_override("font_color", S.TEXT)
	le.add_theme_color_override("font_placeholder_color", Color(S.TEXT_DIM, 0.75))
	le.add_theme_color_override("caret_color", S.ACCENT)
	le.add_theme_color_override("selection_color", Color(S.ACCENT, 0.3))
	var base := Color(1, 1, 1, 0.065)
	var edge := Color(1, 1, 1, 0.08)
	le.add_theme_stylebox_override("normal", S.box(base, S.RADIUS, 10, 5, edge, 1))
	var focus := S.box(Color(0, 0, 0, 0), S.RADIUS, 10, 5, Color(S.ACCENT, 0.7), 2)
	le.add_theme_stylebox_override("focus", focus)
